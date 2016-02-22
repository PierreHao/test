#include "layer.h"
#include "cuda_settings.h"

static const int num_threads = sizeof(unsigned long long) * 8;

__device__ inline real iou_kernel(const real* const a, const real* const b)
{
  const real left = max(a[0], b[0]);
  const real right = min(a[2], b[2]);
  const real top = max(a[1], b[1]);
  const real bottom = min(a[3], b[3]);
  const real width = max(right - left + 1, 0.0f);
  const real height = max(bottom - top + 1, 0.0f);
  const real interS = width * height;
  const real Sa = (a[2] - a[0] + 1) * (a[3] - a[1] + 1);
  const real Sb = (b[2] - b[0] + 1) * (b[3] - b[1] + 1);
  return interS / (Sa + Sb - interS);
}

__global__ void nms_kernel(const int n_boxes, const real nms_thresh,
                           const real* dev_boxes, unsigned long long* dev_mask)
{
  const int row_start = blockIdx.y;
  const int col_start = blockIdx.x;

  const int row_size =
        min(n_boxes - row_start * num_threads, num_threads);
  const int col_size =
        min(n_boxes - col_start * num_threads, num_threads);

  __shared__ real block_boxes[num_threads * 5];
  if (threadIdx.x < col_size) {
    block_boxes[threadIdx.x * 5 + 0] =
        dev_boxes[(num_threads * col_start + threadIdx.x) * 5 + 0];
    block_boxes[threadIdx.x * 5 + 1] =
        dev_boxes[(num_threads * col_start + threadIdx.x) * 5 + 1];
    block_boxes[threadIdx.x * 5 + 2] =
        dev_boxes[(num_threads * col_start + threadIdx.x) * 5 + 2];
    block_boxes[threadIdx.x * 5 + 3] =
        dev_boxes[(num_threads * col_start + threadIdx.x) * 5 + 3];
    block_boxes[threadIdx.x * 5 + 4] =
        dev_boxes[(num_threads * col_start + threadIdx.x) * 5 + 4];
  }
  __syncthreads();

  if (threadIdx.x < row_size) {
    const int cur_box_idx = num_threads * row_start + threadIdx.x;
    const real* cur_box = dev_boxes + cur_box_idx * 5;
    int i = 0;
    unsigned long long t = 0;
    int start = 0;
    if (row_start == col_start) {
      start = threadIdx.x + 1;
    }
    for (i = start; i < col_size; i++) {
      if (iou_kernel(cur_box, block_boxes + i * 5) > nms_thresh) {
        t |= 1ULL << i;
      }
    }
    const int col_blocks = (n_boxes + num_threads - 1) / num_threads;
    dev_mask[cur_box_idx * col_blocks + col_start] = t;
  }
}

void _nms_gpu(int* keep_out, int* num_out, const real* boxes_host,
              const int boxes_num, const int boxes_dim, const real nms_thresh)
{
  real* boxes_dev = NULL;
  unsigned long long* mask_dev = NULL;

  const int col_blocks = (boxes_num + num_threads - 1) / num_threads;

  CUDA_CHECK(cudaMalloc(&boxes_dev, boxes_num * boxes_dim * sizeof(real)));
  CUDA_CHECK(cudaMemcpy(boxes_dev,
                        boxes_host,
                        boxes_num * boxes_dim * sizeof(real),
                        cudaMemcpyHostToDevice));

  CUDA_CHECK(cudaMalloc(&mask_dev, boxes_num * col_blocks * sizeof(unsigned long long)));

  dim3 blocks(col_blocks, col_blocks);
  dim3 threads(num_threads);
  nms_kernel<<<blocks, threads>>>(boxes_num, nms_thresh, boxes_dev, mask_dev);

  unsigned long long* mask_host
      = (unsigned long long*)malloc(boxes_num * col_blocks * sizeof(unsigned long long));
  CUDA_CHECK(cudaMemcpy(&mask_host[0],
                        mask_dev,
                        sizeof(unsigned long long) * boxes_num * col_blocks,
                        cudaMemcpyDeviceToHost));

  CUDA_CHECK(cudaFree(boxes_dev));
  CUDA_CHECK(cudaFree(mask_dev));

  unsigned long long* remv
      = (unsigned long long*)malloc(col_blocks * sizeof(unsigned long long));
  memset(&remv[0], 0, sizeof(unsigned long long) * col_blocks);

  int num_to_keep = 0;
  for (int i = 0; i < boxes_num; i++) {
    int nblock = i / num_threads;
    int inblock = i % num_threads;

    if (!(remv[nblock] & (1ULL << inblock))) {
      keep_out[num_to_keep++] = i;
      unsigned long long* p = &mask_host[0] + i * col_blocks;
      for (int j = nblock; j < col_blocks; j++) {
        remv[j] |= p[j];
      }
    }
  }
  *num_out = num_to_keep;

  free(mask_host);
  free(remv);
}

typedef struct BoundingBox_
{
  real x1, y1, x2, y2;
  real score;
} BoundingBox;

bool transform_box(BoundingBox* box,
                   real dx, real dy, real dw, real dh,
                   real im_w, real im_h, real min_w, real min_h)
{
  real w = box->x2 - box->x1 + 1.0f;
  real h = box->y2 - box->y1 + 1.0f;
  real ctr_x = box->x1 + 0.5f * w;
  real ctr_y = box->y1 + 0.5f * h;

  real pred_ctr_x = dx * w + ctr_x;
  real pred_ctr_y = dy * h + ctr_y;
  real pred_w = exp(dw) * w;
  real pred_h = exp(dh) * h;

  box->x1 = pred_ctr_x - 0.5f * pred_w;
  box->y1 = pred_ctr_y - 0.5f * pred_h;
  box->x2 = pred_ctr_x + 0.5f * pred_w;
  box->y2 = pred_ctr_y + 0.5f * pred_h;

  box->x1 = max(min(box->x1, im_w - 1.0f), 0.0f);
  box->y1 = max(min(box->y1, im_h - 1.0f), 0.0f);
  box->x2 = max(min(box->x2, im_w - 1.0f), 0.0f);
  box->y2 = max(min(box->y2, im_h - 1.0f), 0.0f);

  w = box->x2 - box->x1 + 1.0f;
  h = box->y2 - box->y1 + 1.0f;

  if (w >= min_w && h >= min_h) return true;
  return false;
}

typedef struct ProposalOption_
{
  int num_concats;
  real* ratios;
  int num_ratios;
  real* scales;
  int num_scales;
  int base_size;
  int feat_stride;
  int min_size;
  int pre_nms_topn;
  int post_nms_topn;
  real nms_thresh;
} ProposalOption;

#define MAX_NUM_RATIO_SCALE 10
#define MAX_DATA_WIDTH 80
#define MAX_DATA_HEIGHT 80
#define MAX_NUM_PROPOSAL 6000

void generate_anchors(real* const anchors, const ProposalOption* option)
{
  real base_area = option->base_size * option->base_size;
  real ctr = 0.5f * (option->base_size - 1.0f);
  real wr[MAX_NUM_RATIO_SCALE];
  real hr[MAX_NUM_RATIO_SCALE];
  for (int i = 0; i < option->num_ratios; ++i) {
    wr[i] = round(sqrt(base_area / option->ratios[i]));
    hr[i] = round(wr[i] * option->ratios[i]);
  }
 { // anchor generation
  real* p_anchors = &anchors[0];
  for (int c = 0; c < option->num_concats; ++c) {
    for (int i = 0; i < option->num_ratios; ++i) {
      for (int j = 0; j < option->num_scales; ++j) {
        const real ws = 0.5f * (wr[i] * option->scales[j] - 1.0f);
        const real hs = 0.5f * (hr[i] * option->scales[j] - 1.0f);
        p_anchors[0] = ctr - ws;
        p_anchors[1] = ctr - hs;
        p_anchors[2] = ctr + ws;
        p_anchors[3] = ctr + hs;
        p_anchors += 4;
      }
    }
  }
 } // end anchor generation
}

void sort_box(BoundingBox *list, int start, int end, const int num_top)
{
  int left = start + 1, right = end;
  real pivot_score = list[start].score;
  BoundingBox temp;
  while (left <= right) {
    while (left <= end && list[left].score >= pivot_score) ++left;
    while (right > start && list[right].score <= pivot_score) --right;
    if (left <= right) {
      temp = list[left];
      list[left] = list[right];
      list[right] = temp;
      ++left;
      --right;
    }
  }
  if (right > start) {
    temp = list[right];
    list[right] = list[start];
    list[start] = temp;
  }
  if (start < right - 1) {
    sort_box(list, start, right - 1, num_top);
  }
  if (right + 1 < num_top && right + 1 < end) {
    sort_box(list, right + 1, end, num_top);
  }
}

void forward(const Tensor* bottom4d, const Tensor* pred_box4d, const Tensor* img_info1d,
             Tensor* const top2d, const real* anchors, const ProposalOption* option)
{
  BoundingBox* proposals
      = (BoundingBox*)malloc(MAX_NUM_RATIO_SCALE * MAX_NUM_RATIO_SCALE *
                             MAX_DATA_WIDTH * MAX_DATA_HEIGHT * sizeof(BoundingBox));
  real* sorted_dets = (real*)malloc(MAX_NUM_PROPOSAL * 5 * sizeof(real));
  int* keep = (int*)malloc(MAX_NUM_PROPOSAL * sizeof(int));

  // bottom4d: N x 2 x num_anchors x H x W
  // pred_box4d: N x num_anchors x 4 x H x W
  // img_info1d: N x 4
  // top2d: N x num_rois x 4
  real* p_bottom_data = bottom4d->data;
  real* p_pred_box_data = pred_box4d->data;
  real* p_img_info = img_info1d->data;
  real* p_top_data = top2d->data;
  const int num_anchors = option->num_concats * option->num_ratios * option->num_scales;
  for (int n = 0; n < bottom4d->num_items; ++n) {
    const int H = bottom4d->shape[n][2];
    const int W = bottom4d->shape[n][3];
    const int HW = H * W;
    const real im_w = p_img_info[1];
    const real im_h = p_img_info[0];
    const real min_w = option->min_size * p_img_info[2];
    const real min_h = option->min_size * p_img_info[3];

    // enumerate all proposals
    int num_proposals = 0;
    for (int h = 0; h < H; ++h) {
      for (int w = 0; w < W; ++w) {
        const real x = w * option->feat_stride;
        const real y = h * option->feat_stride;
        const real* p_box = &p_pred_box_data[h * W + w];
        const real* p_score = &p_bottom_data[num_anchors * HW + h * W + w];
        for (int k = 0; k < num_anchors; ++k) {
          const real dx = p_box[(k * 4 + 0) * HW];
          const real dy = p_box[(k * 4 + 1) * HW];
          const real dw = p_box[(k * 4 + 2) * HW];
          const real dh = p_box[(k * 4 + 3) * HW];
          proposals[num_proposals].x1 = x + anchors[k * 4 + 0];
          proposals[num_proposals].y1 = y + anchors[k * 4 + 1];
          proposals[num_proposals].x2 = x + anchors[k * 4 + 2];
          proposals[num_proposals].y2 = y + anchors[k * 4 + 3];
          proposals[num_proposals].score = p_score[k * HW];
          const bool box_created = transform_box(&proposals[num_proposals],
                                                 dx, dy, dw, dh,
                                                 im_w, im_h, min_w, min_h);
          if (box_created) ++num_proposals;
        }
      }
    }

    // choose candidates according to scores
    sort_box(proposals, 0, num_proposals - 1, option->pre_nms_topn);
    if (num_proposals > option->pre_nms_topn)
      num_proposals = option->pre_nms_topn;
    for (int i = 0; i < num_proposals; ++i) {
      sorted_dets[i * 5 + 0] = proposals[i].x1;
      sorted_dets[i * 5 + 1] = proposals[i].y1;
      sorted_dets[i * 5 + 2] = proposals[i].x2;
      sorted_dets[i * 5 + 3] = proposals[i].y2;
      sorted_dets[i * 5 + 4] = proposals[i].score;
    }

   { // roi retrieval
    int num_rois = 0;
    _nms_gpu(keep, &num_rois, sorted_dets, num_proposals, 5, option->nms_thresh);

    if (num_rois > option->post_nms_topn)
      num_rois = option->post_nms_topn;
    top2d->shape[n][0] = num_rois;
    top2d->shape[n][1] = 4;
    for (int i = 0; i < num_rois; ++i) {
      p_top_data[i * 4 + 0] = proposals[keep[i]].x1;
      p_top_data[i * 4 + 1] = proposals[keep[i]].y1;
      p_top_data[i * 4 + 2] = proposals[keep[i]].x2;
      p_top_data[i * 4 + 3] = proposals[keep[i]].y2;
    }
   } // end roi retrieval

    // locate next item
    p_top_data += 4 * top2d->shape[n][0];
    p_bottom_data += 2 * num_anchors * HW;
    p_pred_box_data += 4 * num_anchors * HW;
    p_img_info += 4;
  } // endfor num_items

  top2d->ndim = 2;

  free(proposals);
  free(sorted_dets);
  free(keep);
}

#include <stdlib.h>

int main(void)
{
  real anchors[100];
  real scales[5] = {3, 6, 9, 16, 32};
  real ratios[5] = {0.5, 0.666, 1.0, 1.5, 2.0};
  ProposalOption option;
  option.num_concats = 3;
  option.base_size = 16;
  option.feat_stride = 16;
  option.pre_nms_topn = 6000;
  option.post_nms_topn = 300;
  option.nms_thresh = 0.7;
  option.min_size = 16;
  option.scales = &scales[0];
  option.ratios = &ratios[0];
  option.num_scales = 5;
  option.num_ratios = 5;
  generate_anchors(anchors, &option);
  int num_anchors = option.num_concats * option.num_scales * option.num_ratios;

#ifdef PASS
  BoundingBox box[5000];
  for (int i = 0; i < 5000; ++i) {
    box[i].score = rand() % 1000;
  }
  int num_top = 200;
  sort_box(box, 0, 5000 - 1, num_top);
  for (int i = 1; i < num_top; ++i) {
    if (box[i-1].score < box[i].score)
    printf("%d:%.2f > %d:%.2f\n", i-1, box[i-1].score, i, box[i].score);
  }
  for (int i = num_top; i < 5000; ++i) {
    if (box[i].score > box[num_top-1].score)
      printf("%d:%.2f > %d:%.2f\n", i, box[i].score, num_top-1, box[num_top-1].score);
  }
#endif

  Tensor score, bbox, im_info, roi;
  real score_data[150*36*46], bbox_data[300*36*46], im_info_data[4], roi_data[300*4];
  score.ndim = 4; score.num_items = 1; score.data = &score_data[0];
  for (int i = 0; i < score.num_items; ++i) {
    score.shape[i][0] = 2;
    score.shape[i][1] = num_anchors;
    score.shape[i][2] = 36;
    score.shape[i][3] = 46;
  }
  bbox.ndim = 4; bbox.num_items = score.num_items; bbox.data = &bbox_data[0];
  for (int i = 0; i < bbox.num_items; ++i) {
    bbox.shape[i][0] = num_anchors;
    bbox.shape[i][1] = 4;
    bbox.shape[i][2] = 36;
    bbox.shape[i][3] = 46;
  }
  im_info.ndim = 1; im_info.num_items = score.num_items; im_info.data = &im_info_data[0];
  for (int i = 0; i < im_info.num_items; ++i) {
    im_info.shape[i][0] = 4;
  }
  roi.ndim = 2; roi.num_items = score.num_items; roi.data = &roi_data[0];

  FILE* fp = fopen("bottom.txt", "r");
  for (int i = 0; i < flatten_size(&score); ++i)
    fscanf(fp, "%f", &score_data[i]);
  fclose(fp);
  fp = fopen("bbox.txt", "r");
  for (int i = 0; i < flatten_size(&bbox); ++i)
    fscanf(fp, "%f", &bbox_data[i]);
  fclose(fp);
  fp = fopen("im_info.txt", "r");
  for (int i = 0; i < flatten_size(&im_info); ++i)
    fscanf(fp, "%f", &im_info_data[i]);
  fclose(fp);

  forward(&score, &bbox, &im_info, &roi, anchors, &option);

  real* p_roi_data = roi.data;
  for (int n = 0; n < roi.num_items; ++n) {
    printf("batch %d: %d x %d\n", n, roi.shape[n][0], roi.shape[n][1]);
    for (int i = 0; i < roi.shape[n][0]; ++i) {
      for (int j = 0; j < roi.shape[n][1]; ++j) {
        printf("%.2f ", *(p_roi_data++));
      }
      printf("\n");
    }
  }

  return 0;
}

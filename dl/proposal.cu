#include "layer.h"
#include <stdlib.h>
#include <math.h>

#ifdef GPU
#include "cuda_settings.h"
#endif

// data structure for a bounding-box in a given image
//   (x1, y1): upper-left corner location of the box in the image
//   (x2, y2): lower-right corner location of the box in the image
//   score: objectness score of the region bounded by the box
typedef struct BoundingBox_
{
  real x1, y1, x2, y2;
  real score;
} BoundingBox;


/*
 * functions for NMS operation:
 *   iou: compute overlap between two boxes
 *   nms_mask: given a set of boxes, compute overlap between all box pairs
 *   nms: given a set of boxes, discard significantly-overlapped boxes
 */

// "IoU = intersection area / union area" of two boxes A, B
//   A, B: 4-dim array (x1, y1, x2, y2)
#ifdef GPU
__device__
#endif
inline real iou(const real* const A, const real* const B)
{
  // overlapped region (= box)
  const real x1 = MAX(A[0], B[0]);
  const real y1 = MAX(A[1], B[1]);
  const real x2 = MIN(A[2], B[2]);
  const real y2 = MIN(A[3], B[3]);

  // intersection area
  const real width = MAX(0.0f,  x2 - x1 + 1.0f);
  const real height = MAX(0.0f,  y2 - y1 + 1.0f);
  const real area = width * height;

  // area of A, B
  const real A_area = (A[2] - A[0] + 1.0f) * (A[3] - A[1] + 1.0f);
  const real B_area = (B[2] - B[0] + 1.0f) * (B[3] - B[1] + 1.0f);

  // IoU
  return area / (A_area + B_area - area);
}

// given box proposals, compute overlap between all box pairs
// (overlap = intersection area / union area)
// and then set mask-bit to 1 if a pair is significantly overlapped
//   num_boxes: number of box proposals given
//   boxes: "num_boxes x 5" array (x1, y1, x2, y2, score)
//   nms_thresh: threshold for determining "significant overlap"
//               if "intersection area / union area > nms_thresh",
//               two boxes are thought of as significantly overlapped
// the all-pair computation (num_boxes x num_boxes) is done by
// divide-and-conquer:
//   each GPU block (bj, bi) computes for "64 x 64" box pairs (j, i),
//     j = bj * 64 + { 0, 1, ..., 63 }
//     i = bi * 64 + { 0, 1, ..., 63 },
//   and each "1 x 64" results is saved into a 64-bit mask
//     mask: "num_boxes x num_blocks" array
//     for mask[j][bi], "di-th bit = 1" means:
//       box j is significantly overlapped with box i,
//       where i = bi * 64 + di
typedef unsigned long long uint64;
#define NMS_BLOCK_SIZE 64
#ifdef GPU
__global__
void nms_mask_gpu(const real* const boxes,
                  uint64* const mask,
                  const int num_boxes, const real nms_thresh)
{
  // block region
  //   j = j_start + { 0, ..., dj_end - 1 }
  //   i = i_start + { 0, ..., di_end - 1 }
  const int i_start = blockIdx.x * NMS_BLOCK_SIZE;
  const int di_end = MIN(num_boxes - i_start,  NMS_BLOCK_SIZE);
  const int j_start = blockIdx.y * NMS_BLOCK_SIZE;
  const int dj_end = MIN(num_boxes - j_start,  NMS_BLOCK_SIZE);

  // copy all i-th boxes to GPU cache
  //   i = i_start + { 0, ..., di_end - 1 }
  __shared__ real boxes_i[NMS_BLOCK_SIZE * 5];
  {
    const int di = threadIdx.x;
    if (di < di_end) {
      boxes_i[di * 5 + 0] = boxes[(i_start + di) * 5 + 0];
      boxes_i[di * 5 + 1] = boxes[(i_start + di) * 5 + 1];
      boxes_i[di * 5 + 2] = boxes[(i_start + di) * 5 + 2];
      boxes_i[di * 5 + 3] = boxes[(i_start + di) * 5 + 3];
      boxes_i[di * 5 + 4] = boxes[(i_start + di) * 5 + 4];
    }
  }
  __syncthreads();

  // given j = j_start + dj,
  //   check whether box i is significantly overlapped with box j
  //   (i.e., IoU(box j, box i) > threshold)
  //   for all i = i_start + { 0, ..., di_end - 1 } except for i == j
  {
    const int dj = threadIdx.x;
    if (dj < dj_end) {
      // box j
      const real* const box_j = boxes + (j_start + dj) * 5;

      // mask for significant overlap
      //   if IoU(box j, box i) > threshold,  di-th bit = 1
      uint64 mask_j = 0;

      // check for all i = i_start + { 0, ..., di_end - 1 }
      // except for i == j
      const int di_start = (i_start == j_start) ? (dj + 1) : 0;
      for (int di = di_start; di < di_end; ++di) {
        // box i
        const real* const box_i = boxes_i + di * 5;

        // if IoU(box j, box i) > threshold,  di-th bit = 1
        if (iou(box_j, box_i) > nms_thresh) {
          mask_j |= 1ULL << di;
        }
      }

      // mask: "num_boxes x num_blocks" array
      //   for mask[j][bi], "di-th bit = 1" means:
      //     box j is significantly overlapped with box i = i_start + di,
      //     where i_start = bi * block_size
      {
        const int num_blocks = DIV_THEN_CEIL(num_boxes, NMS_BLOCK_SIZE);
        const int bi = blockIdx.x;
        mask[(j_start + dj) * num_blocks + bi] = mask_j;
      }
    } // endif dj < dj_end
  }
}
#else
void nms_mask_cpu(const real* const boxes,
                  uint64* const mask,
                  const int num_boxes, const real nms_thresh)
{
  // number of blocks along each dimension
  const int num_blocks = DIV_THEN_CEIL(num_boxes, NMS_BLOCK_SIZE);

  // the whole 2-dim computations "num_boxes x num_boxes" is done by
  // sweeping all "64 x 64"-sized blocks
  for (int j_start = 0; j_start < num_boxes; j_start += NMS_BLOCK_SIZE) {
    for (int i_start = 0; i_start < num_boxes; i_start += NMS_BLOCK_SIZE) {
      // block region
      //   j = j_start + { 0, ..., dj_end - 1 }
      //   i = i_start + { 0, ..., di_end - 1 }
      const int di_end = MIN(num_boxes - i_start,  NMS_BLOCK_SIZE);
      const int dj_end = MIN(num_boxes - j_start,  NMS_BLOCK_SIZE);

      // check whether box i is significantly overlapped with box j
      // for all j = j_start + { 0, ..., dj_end - 1 },
      //         i = i_start + { 0, ..., di_end - 1 },
      // except for i == j
      for (int dj = 0; dj < dj_end; ++dj) {
        // box j & overlap mask
        const real* const box_j = boxes + (j_start + dj) * 5;
        uint64 mask_j = 0;

        // check for all i = i_start + { 0, ..., di_end - 1 }
        // except for i == j
        const int di_start = (i_start == j_start) ? (dj + 1) : 0;
        for (int di = di_start; di < di_end; ++di) {
          // box i
          const real* const box_i = boxes + (i_start + di) * 5;

          // if IoU(box j, box i) > threshold,  di-th bit = 1
          if (iou(box_j, box_i) > nms_thresh) {
            mask_j |= 1ULL << di;
          }
        }

        // mask: "num_boxes x num_blocks" array
        //   for mask[j][bi], "di-th bit = 1" means:
        //     box j is significantly overlapped with box i = i_start + di,
        //     where i_start = bi * block_size
        {
          const int bi = i_start / NMS_BLOCK_SIZE;
          mask[(j_start + dj) * num_blocks + bi] = mask_j;
        }
      } // endfor dj
    } // endfor j_start
  } // endfor i_start
}
#endif

// given box proposals (sorted in descending order of their scores),
// discard a box if it is significantly overlapped with
// one or more previous (= scored higher) boxes
//   num_boxes: number of box proposals given
//   boxes: "num_boxes x 5" array (x1, y1, x2, y2, score)
//          sorted in descending order of scores
//   num_out: number of remaining boxes
//   keep_out: "num_out x 1" array
//             indices of remaining boxes
//   nms_thresh: threshold for determining "significant overlap"
//               if "intersection area / union area > nms_thresh",
//               two boxes are thought of as significantly overlapped
void nms(const int num_boxes, const real* const boxes,
         int* const num_out, int* const keep_out,
         const real nms_thresh)
{
  const int num_blocks = DIV_THEN_CEIL(num_boxes, NMS_BLOCK_SIZE);
  uint64* const mask
      = (uint64*)malloc(num_boxes * num_blocks * sizeof(uint64));

  #ifdef GPU
  {
    uint64* mask_dev;
    real* boxes_dev;
    const dim3 blocks(num_blocks, num_blocks);

    // GPU memory allocation & copy box data
    CUDA_CHECK(cudaMalloc(&boxes_dev, num_boxes * 5 * sizeof(real)));
    CUDA_CHECK(cudaMemcpy(boxes_dev, boxes, num_boxes * 5 * sizeof(real),
                          cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMalloc(&mask_dev,
                          num_boxes * num_blocks * sizeof(uint64)));

    // find all significantly-overlapped pairs of boxes
    nms_mask_gpu<<<blocks, NMS_BLOCK_SIZE>>>(
        boxes_dev, mask_dev, num_boxes, nms_thresh);

    // copy mask data to main memory
    CUDA_CHECK(cudaMemcpy(mask, mask_dev,
                          sizeof(uint64) * num_boxes * num_blocks,
                          cudaMemcpyDeviceToHost));

    // GPU memory deallocation
    CUDA_CHECK(cudaFree(boxes_dev));
    CUDA_CHECK(cudaFree(mask_dev));
  }
  #else
  {
    // find all significantly-overlapped pairs of boxes
    nms_mask_cpu(boxes, mask, num_boxes, nms_thresh);
  }
  #endif

  // discard i-th box if it is significantly overlapped with
  // one or more previous (= scored higher) boxes
  {
    int num_to_keep = 0;
    uint64* const remv = (uint64*)calloc(num_blocks, sizeof(uint64));

    for (int i = 0; i < num_boxes; ++i) {
      const int nblock = i / NMS_BLOCK_SIZE;
      const int inblock = i % NMS_BLOCK_SIZE;

      if (!(remv[nblock] & (1ULL << inblock))) {
        keep_out[num_to_keep++] = i;
        uint64* p = mask + i * num_blocks;
        for (int j = nblock; j < num_blocks; ++j) {
          remv[j] |= p[j];
        }
      }
    }
    *num_out = num_to_keep;

    free(remv);
  }

  free(mask);
}


/*
 * functions for box data structure
 *   transform_box: transform a box according to a given gradient
 *   generate_anchors: generate anchor boxes of varying sizes and ratios
 *   sort_box: sort a list of boxes in descending order of their scores
 */

// transform a box according to a given gradient
//   box: (x1, y1, x2, y2)
//   gradient: dx, dy, d(log w), d(log h)
int transform_box(BoundingBox* const box,
                  const real dx, const real dy,
                  const real d_log_w, const real d_log_h,
                  const real im_w, const real im_h,
                  const real min_w, const real min_h)
{
  // width & height of box
  const real w = box->x2 - box->x1 + 1.0f;
  const real h = box->y2 - box->y1 + 1.0f;
  // center location of box
  const real ctr_x = box->x1 + 0.5f * w;
  const real ctr_y = box->y1 + 0.5f * h;

  // new center location according to gradient (dx, dy)
  const real pred_ctr_x = dx * w + ctr_x;
  const real pred_ctr_y = dy * h + ctr_y;
  // new width & height according to gradient d(log w), d(log h)
  const real pred_w = exp(d_log_w) * w;
  const real pred_h = exp(d_log_h) * h;

  // update upper-left corner location
  box->x1 = pred_ctr_x - 0.5f * pred_w;
  box->y1 = pred_ctr_y - 0.5f * pred_h;
  // update lower-right corner location
  box->x2 = pred_ctr_x + 0.5f * pred_w;
  box->y2 = pred_ctr_y + 0.5f * pred_h;

  // adjust new corner locations to be within the image region,
  box->x1 = MAX(0.0f,  MIN(box->x1,  im_w - 1.0f));
  box->y1 = MAX(0.0f,  MIN(box->y1,  im_h - 1.0f));
  box->x2 = MAX(0.0f,  MIN(box->x2,  im_w - 1.0f));
  box->y2 = MAX(0.0f,  MIN(box->y2,  im_h - 1.0f));

  // recompute new width & height
  const real box_w = box->x2 - box->x1 + 1.0f;
  const real box_h = box->y2 - box->y1 + 1.0f;

  // check if new box's size >= threshold
  if (box_w >= min_w && box_h >= min_h) return 1;
  return 0;
}

// given a base box, enumerate transformed boxes of varying sizes and ratios
//   option->base_size: base box's width & height (i.e., base box is square)
//   option->scales: "option->num_scales x 1" array
//                   varying scale factor for base box
//   option->ratios: "option->num_ratios x 1" array
//                   varying height-width ratio
//   option->num_concats: repeat count of anchor set generation
//                        (required for separated RPN)
//   anchors: "num_boxes x 4" array,  (x1, y1, x2, y2) for each box
//     num_boxes = total number of transformations
//         = option->num_scales * option->num_ratios * option->num_concats
#define MAX_NUM_RATIO_SCALE 10
void generate_anchors(real* const anchors,
                      const ProposalOption* const option)
{
  // base box's width & height & center location
  const real base_area = option->base_size * option->base_size;
  const real ctr = 0.5f * (option->base_size - 1.0f);

  // transformed width & height for given ratios
  real wr[MAX_NUM_RATIO_SCALE];
  real hr[MAX_NUM_RATIO_SCALE];
  for (int i = 0; i < option->num_ratios; ++i) {
    wr[i] = ROUND(sqrt(base_area / option->ratios[i]));
    hr[i] = ROUND(wr[i] * option->ratios[i]);
  }

  // enumerate all transformed boxes
  {
    real* p_anchors = anchors;
    for (int c = 0; c < option->num_concats; ++c) {
      for (int i = 0; i < option->num_ratios; ++i) {
        for (int j = 0; j < option->num_scales; ++j) {
          // transformed width & height for given ratios & scales
          const real ws = 0.5f * (wr[i] * option->scales[j] - 1.0f);
          const real hs = 0.5f * (hr[i] * option->scales[j] - 1.0f);
          // (x1, y1, x2, y2) for transformed box
          p_anchors[0] = ctr - ws;
          p_anchors[1] = ctr - hs;
          p_anchors[2] = ctr + ws;
          p_anchors[3] = ctr + hs;
          p_anchors += 4;
        } // endfor j
      } // endfor i
    } // endfor c
  }
}

// quick-sort a list of boxes in descending order of their scores
//   if num_top <= end,  only top-k results are guaranteed to be sorted
//   (for efficient computation)
void sort_box(BoundingBox* const list, const int start, const int end,
              const int num_top)
{
  const real pivot_score = list[start].score;
  int left = start + 1, right = end;
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


/*
 * finally, proposal operator
 */

// proposal: bottom -> top
//   bottom: 2 x num_anchors x H x W tensor
//     bottom[0, n, h, w] = foreground score of anchor n at node (h, w)
//     bottom[1, n, h, w] = background score of anchor n at node (h, w)
//   pred_box: num_anchors x 4 x H x W tensor
//     pred_box[n, :, h, w] = predicted box (d x1, d y1, d log w, d log h)
//                            of anchor n at pixel (h, w)
//   img_info: 4 x 1 tensor,  (w, h, min_w, min_h) of raw image
//     min_w: minimum box width in raw image
//     min_h: minimum box height in raw image
//   top: num_RoIs x 4 tensor,  (x1, y1, x2, y2) of each RoI
//   anchors: num_anchors * 4 array,  (x1, y1, x2, y2) of each anchor
#define MAX_DATA_WIDTH 80
#define MAX_DATA_HEIGHT 80
#define MAX_NUM_PROPOSAL 6000
void proposal_forward(const Tensor* const bottom4d,
                      const Tensor* const pred_box4d,
                      const Tensor* const img_info1d,
                      Tensor* const top2d,
                      const real* const anchors,
                      const ProposalOption* const option)
{
  BoundingBox* const proposals
      = (BoundingBox*)malloc(MAX_NUM_RATIO_SCALE * MAX_NUM_RATIO_SCALE *
                             MAX_DATA_WIDTH * MAX_DATA_HEIGHT *
                             sizeof(BoundingBox));
  real* const sorted_dets
      = (real*)malloc(MAX_NUM_PROPOSAL * 5 * sizeof(real));
  int* const keep = (int*)malloc(MAX_NUM_PROPOSAL * sizeof(int));

  // bottom4d: N x 2 x num_anchors x H x W
  // pred_box4d: N x num_anchors x 4 x H x W
  // img_info1d: N x 4
  // top2d: N x num_rois x 4
  const real* p_bottom_item = bottom4d->data;
  const real* p_pred_box_item = pred_box4d->data;
  const real* p_img_info = img_info1d->data;
  real* p_top_item = top2d->data;
  const int num_anchors
      = option->num_concats * option->num_ratios * option->num_scales;
  for (int n = 0; n < bottom4d->num_items; ++n) {
    const int bottom_H = bottom4d->shape[n][2];
    const int bottom_W = bottom4d->shape[n][3];
    const int bottom_area = bottom_H * bottom_W;
    const real im_w = p_img_info[1];
    const real im_h = p_img_info[0];
    const real min_w = option->min_size * p_img_info[2];
    const real min_h = option->min_size * p_img_info[3];

    // enumerate all proposals
    // TODO: GPU code
    int num_proposals = 0;
    for (int h = 0; h < bottom_H; ++h) {
      for (int w = 0; w < bottom_W; ++w) {
        const real x = w * option->feat_stride;
        const real y = h * option->feat_stride;
        const real* p_box = p_pred_box_item + h * bottom_W + w;
        const real* p_score
            = p_bottom_item + num_anchors * bottom_area + h * bottom_W + w;
        for (int k = 0; k < num_anchors; ++k) {
          const real dx = p_box[(k * 4 + 0) * bottom_area];
          const real dy = p_box[(k * 4 + 1) * bottom_area];
          const real dw = p_box[(k * 4 + 2) * bottom_area];
          const real dh = p_box[(k * 4 + 3) * bottom_area];
          proposals[num_proposals].x1 = x + anchors[k * 4 + 0];
          proposals[num_proposals].y1 = y + anchors[k * 4 + 1];
          proposals[num_proposals].x2 = x + anchors[k * 4 + 2];
          proposals[num_proposals].y2 = y + anchors[k * 4 + 3];
          proposals[num_proposals].score = p_score[k * bottom_area];
          {
            const int box_created = transform_box(&proposals[num_proposals],
                                                  dx, dy, dw, dh,
                                                  im_w, im_h, min_w, min_h);
            if (box_created) ++num_proposals;
          }
        } // endfor k
      } // endfor w
    } // endfor h

    // choose candidates according to scores
    // TODO: copy proposals to GPU memory directly
    sort_box(proposals, 0, num_proposals - 1, option->pre_nms_topn);
    if (num_proposals > option->pre_nms_topn) {
      num_proposals = option->pre_nms_topn;
    }
    for (int i = 0; i < num_proposals; ++i) {
      sorted_dets[i * 5 + 0] = proposals[i].x1;
      sorted_dets[i * 5 + 1] = proposals[i].y1;
      sorted_dets[i * 5 + 2] = proposals[i].x2;
      sorted_dets[i * 5 + 3] = proposals[i].y2;
      sorted_dets[i * 5 + 4] = proposals[i].score;
    }

    // NMS & RoI retrieval
    {
      int num_rois = 0;
      nms(num_proposals, sorted_dets, &num_rois, keep, option->nms_thresh);

      if (num_rois > option->post_nms_topn) {
        num_rois = option->post_nms_topn;
      }
      top2d->shape[n][0] = num_rois;
      top2d->shape[n][1] = 4;
      for (int i = 0; i < num_rois; ++i) {
        p_top_item[i * 4 + 0] = proposals[keep[i]].x1;
        p_top_item[i * 4 + 1] = proposals[keep[i]].y1;
        p_top_item[i * 4 + 2] = proposals[keep[i]].x2;
        p_top_item[i * 4 + 3] = proposals[keep[i]].y2;
      }
    }

    // locate next item
    p_top_item += 4 * top2d->shape[n][0];
    p_bottom_item += 2 * num_anchors * bottom_area;
    p_pred_box_item += 4 * num_anchors * bottom_area;
    p_img_info += 4;
  } // endfor num_items

  top2d->ndim = 2;
  top2d->num_items = bottom4d->num_items;

  free(proposals);
  free(sorted_dets);
  free(keep);
}

// test code
#ifdef TEST
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[])
{
  // variable declaration & memory allocation
  Tensor score, bbox, im_info, roi;
  real score_data[150*36*46], bbox_data[300*36*46], im_info_data[4];
  real roi_data[300*4], roi_true_data[300*5];
  int num_rois_true;
  real anchors[3*5*5*4];
  real scales[5] = {3, 6, 9, 16, 32};
  real ratios[5] = {0.5, 0.666, 1.0, 1.5, 2.0};
  int num_anchors;
  ProposalOption option;

  // set option
  {
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
  }

  // generate anchors
  {
    generate_anchors(anchors, &option);
    num_anchors = option.num_concats * option.num_scales * option.num_ratios;
  }

  // set data shapes
  {
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
      bbox.shape[i][2] = score.shape[i][2];
      bbox.shape[i][3] = score.shape[i][3];
    }

    im_info.ndim = 1; im_info.num_items = score.num_items; im_info.data = &im_info_data[0];
    for (int i = 0; i < im_info.num_items; ++i) {
      im_info.shape[i][0] = 4;
    }

    roi.ndim = 2; roi.num_items = score.num_items; roi.data = &roi_data[0];
    for (int i = 0; i < roi.num_items; ++i) {
      roi.shape[i][0] = option.post_nms_topn;
      roi.shape[i][1] = 4;
    }
  }

  // load data
  {
    FILE* fp;
    const int score_size = flatten_size(&score);
    const int bbox_size = flatten_size(&bbox);
    const int im_info_size = flatten_size(&im_info);

    printf("data loading\n");

    fp = fopen("../data/temp/proposal_bottom0.bin", "rb");
    if ((int)fread(score_data, sizeof(real), score_size, fp) != score_size) {
      printf("Error occurred while reading proposal_bottom0\n");
    }
    fclose(fp);

    fp = fopen("../data/temp/proposal_bottom1.bin", "rb");
    if ((int)fread(bbox_data, sizeof(real), bbox_size, fp) != bbox_size) {
      printf("Error occurred while reading proposal_bottom1\n");
    }
    fclose(fp);

    fp = fopen("../data/temp/proposal_bottom2.bin", "rb");
    if ((int)fread(im_info_data, sizeof(real), im_info_size, fp)
        != im_info_size) {
      printf("Error occurred while reading proposal_bottom2\n");
    }
    fclose(fp);

    fp = fopen("../data/temp/proposal_top0.bin", "rb");
    if ((int)fread(&num_rois_true, sizeof(int), 1, fp) != 1) {
      printf("Error occurred while reading proposal_top0_size\n");
    }
    if ((int)fread(roi_true_data, sizeof(real), num_rois_true * 5, fp)
        != num_rois_true * 5) {
      printf("Error occurred while reading proposal_top0\n");
    }
    fclose(fp);
  }

  // CUDA initialization
  #ifdef GPU
  {
    printf("set device\n");
    CUDA_CHECK(cudaSetDevice(0));
  }
  #endif

  // do forward operation
  {
    printf("do forward\n");
    proposal_forward(&score, &bbox, &im_info, &roi, anchors, &option);
  }

  // verify results
  {
    const int roi_size = flatten_size(&roi);
    const int roi_true_size = num_rois_true * 5;
    int i = 0, i_true = 1; // for true data, 0-th element = batch index
    for (; i < roi_size && i_true < roi_true_size; i += 4, i_true += 5) {
      real diff = 0.0f;
      for (int di = 0; di < 4; ++di) {
        diff += ABS(roi_data[i + di] - roi_true_data[i_true + di]) /
                (1e-10f + MIN(roi_data[i + di], roi_true_data[i_true + di]));
      }
      if (diff > 1e-3f) {
        real diff1 = 0.0f;
        for (int di = 0; i_true + 5 + di < roi_true_size && di < 4; ++di) {
          diff1 += ABS(roi_data[i + di] - roi_true_data[i_true + 5 + di]) /
            (1e-10f + MIN(roi_data[i + di], roi_true_data[i_true + 5 + di]));
        }
        if (diff1 < 1e-3f) {
          printf("[False Negative] RoI_true[%d]: %.2f %.2f %.2f %.2f\n",
                 i_true / 5,
                 roi_true_data[i_true + 0], roi_true_data[i_true + 1],
                 roi_true_data[i_true + 2], roi_true_data[i_true + 3]);
          i_true += 5;
          continue;
        }
        real diff2 = 0.0f;
        for (int di = 0; i + 4 + di < roi_size && di < 4; ++di) {
          diff1 += ABS(roi_data[i + 4 + di] - roi_true_data[i_true + di]) /
            (1e-10f + MIN(roi_data[i + 4 + di], roi_true_data[i_true + di]));
        }
        if (diff2 < 1e-3f) {
          printf("[False Positive] RoI[%d]: %.2f %.2f %.2f %.2f\n",
                 i / 4, roi_data[i + 0], roi_data[i + 1],
                 roi_data[i + 2], roi_data[i + 3]);
          i += 4;
          continue;
        }
        printf("RoI[%d]: %.2f %.2f %.2f %.2f  ",
               i / 4, roi_data[i + 0], roi_data[i + 1],
               roi_data[i + 2], roi_data[i + 3]);
        printf("RoI_true[%d]: %.2f %.2f %.2f %.2f\n",
               i_true / 5,
               roi_true_data[i_true + 0], roi_true_data[i_true + 1],
               roi_true_data[i_true + 2], roi_true_data[i_true + 3]);
      }
    }
    for (; i < roi_size; i += 4) {
      printf("[False Positive] RoI[%d]: %.2f %.2f %.2f %.2f\n",
             i / 4, roi_data[i + 0], roi_data[i + 1],
             roi_data[i + 2], roi_data[i + 3]);
    }
    for (; i_true < roi_true_size; i_true += 5) {
      printf("[False Negative] RoI_true[%d]: %.2f %.2f %.2f %.2f\n",
             i_true / 5,
             roi_true_data[i_true + 0], roi_true_data[i_true + 1],
             roi_true_data[i_true + 2], roi_true_data[i_true + 3]);
    }
  }

  return 0;
}
#endif // endifdef TEST

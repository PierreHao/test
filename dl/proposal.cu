/*
  Original version (25.8ms)
    1. [1ms] memcpy, D->H
      1-1. scores (75*2*36*46*float = 993.6KB)
      1-2. bbox (75*4*36*46*float = 1987.2KB)
    2. [15ms] all candidate enumeration & sort
    3. [0ms] memcpy, H->D, 6000*5*float = 120KB
    4. [3.3ms] nms kernel
    5. [1.8ms] memcpy, D->H, 6000*94*uint64 = 4512KB
    6. [0.7ms] nms post processing (bitwise calculations)
    7. [4ms] roi -> top

  Improved version (6.3ms)
    1. [0ms] no memcpy required
    2. [2.6ms] all candidate enumeration & sort
      2-1. [0.3ms] all candidate enumeration
      2-2. [0.6ms] memcpy, D->H, all candidates (75*36*46*5*float = 2484KB)
      2-3. [1.6ms] partial quick-sort
    3. [0ms] memcpy, H->D, 6000*5*float = 120KB
    4. [1.1ms] nms kernel
    5. [1.8ms] memcpy, D->H, 6000*94*uint64 = 4512KB
    6. [0.7ms] nms post processing
    7. [0.1ms] roi -> top

  TODO
    - GPU sort (improve 2-2, 2-3) - speedup
    - GPU nms post processing (remove 5)
*/

#include "layer.h"

#include <time.h>

static float a_time[8] = { 0, };
static clock_t tick0, tick1, tick00;

// --------------------------------------------------------------------------
// kernel code
//   generate_anchors: generate anchor boxes of varying sizes and ratios
//   transform_box: transform a box according to a given gradient
//   sort_box: sort a list of boxes in descending order of their scores
//   enumerate_proposals: generate all candidate boxes with their scores
//   retrieve_rois: retrieve boxes that are determined to be kept by NMS
// --------------------------------------------------------------------------

// given a base box, enumerate transformed boxes of varying sizes and ratios
//   option->base_size: base box's width & height (i.e., base box is square)
//   option->scales: "option->num_scales x 1" array
//                   varying scale factor for base box
//   option->ratios: "option->num_ratios x 1" array
//                   varying height-width ratio
//   anchors: "num_anchors x 4" array,  (x1, y1, x2, y2) for each box
//   num_anchors: total number of transformations
//                = option->num_scales * option->num_ratios
#define MAX_NUM_RATIO_SCALE 10
void generate_anchors(real anchors[],
                      const LayerOption* const option)
{
  // base box's width & height & center location
  const real base_area = (real)(option->base_size * option->base_size);
  const real ctr = 0.5f * (option->base_size - 1.0f);

  // transformed width & height for given ratios
  real wr[MAX_NUM_RATIO_SCALE];
  real hr[MAX_NUM_RATIO_SCALE];
  for (int i = 0; i < option->num_ratios; ++i) {
    wr[i] = (real)ROUND(sqrt(base_area / option->ratios[i]));
    hr[i] = (real)ROUND(wr[i] * option->ratios[i]);
  }

  // enumerate all transformed boxes
  {
    real* p_anchors = anchors;
    for (int j0 = 0; j0 < option->num_scales; j0 += option->num_ratios) {
      for (int i = 0; i < option->num_ratios; ++i) {
        for (int j = 0; j < option->num_ratios; ++j) {
          // transformed width & height for given ratios & scales
          const real ws = 0.5f * (wr[i] * option->scales[j0 + j] - 1.0f);
          const real hs = 0.5f * (hr[i] * option->scales[j0 + j] - 1.0f);
          // (x1, y1, x2, y2) for transformed box
          p_anchors[0] = ctr - ws;
          p_anchors[1] = ctr - hs;
          p_anchors[2] = ctr + ws;
          p_anchors[3] = ctr + hs;
          p_anchors += 4;
        } // endfor j
      } // endfor i
    } // endfor j0
  }
}

// transform a box according to a given gradient
//   box: (x1, y1, x2, y2)
//   gradient: dx, dy, d(log w), d(log h)
#ifdef GPU
__device__
#endif
static
int transform_box(real box[],
                  const real dx, const real dy,
                  const real d_log_w, const real d_log_h,
                  const real img_W, const real img_H,
                  const real min_box_W, const real min_box_H)
{
  // width & height of box
  const real w = box[2] - box[0] + 1.0f;
  const real h = box[3] - box[1] + 1.0f;
  // center location of box
  const real ctr_x = box[0] + 0.5f * w;
  const real ctr_y = box[1] + 0.5f * h;

  // new center location according to gradient (dx, dy)
  const real pred_ctr_x = dx * w + ctr_x;
  const real pred_ctr_y = dy * h + ctr_y;
  // new width & height according to gradient d(log w), d(log h)
  const real pred_w = exp(d_log_w) * w;
  const real pred_h = exp(d_log_h) * h;

  // update upper-left corner location
  box[0] = pred_ctr_x - 0.5f * pred_w;
  box[1] = pred_ctr_y - 0.5f * pred_h;
  // update lower-right corner location
  box[2] = pred_ctr_x + 0.5f * pred_w;
  box[3] = pred_ctr_y + 0.5f * pred_h;

  // adjust new corner locations to be within the image region,
  box[0] = MAX(0.0f,  MIN(box[0],  img_W - 1.0f));
  box[1] = MAX(0.0f,  MIN(box[1],  img_H - 1.0f));
  box[2] = MAX(0.0f,  MIN(box[2],  img_W - 1.0f));
  box[3] = MAX(0.0f,  MIN(box[3],  img_H - 1.0f));

  // recompute new width & height
  const real box_w = box[2] - box[0] + 1.0f;
  const real box_h = box[3] - box[1] + 1.0f;

  // check if new box's size >= threshold
  return (box_w >= min_box_W) * (box_h >= min_box_H);
}

// bitonic sort a list of boxes in descending order of their scores (GPU)
//   list: num_boxes x 5 array,  (x1, y1, x2, y2, score) for each box
//     in bitoninc sort, total space allocated for list should be
//     a power of 2 >= num_boxes,
//     and scores of virtually-padded boxes { num_boxes, ..., 2^n - 1 }
//     should be set smaller than mininum score of actual boxes
#ifdef GPU
__global__
void bitonic_sort_step(real list[], const int idx_major, const int idx_minor)
{
  const int index = blockIdx.x * blockDim.x + threadIdx.x;
  const int index_xor = index ^ idx_minor;
  real temp[5];

  // the threads with the lowest ids sort the array
  if (index_xor > index) {
    if (index & idx_major) {
      // sort ascending
      if (list[index * 5 + 4] > list[index_xor * 5 + 4]) {
        for (int i = 0; i < 5; ++i) {
          temp[i] = list[index * 5 + i];
        }
        for (int i = 0; i < 5; ++i) {
          list[index * 5 + i] = list[index_xor * 5 + i];
        }
        for (int i = 0; i < 5; ++i) {
          list[index_xor * 5 + i] = temp[i];
        }
      }
    }
    else {
      // sort descending
      if (list[index * 5 + 4] < list[index_xor * 5 + 4]) {
        for (int i = 0; i < 5; ++i) {
          temp[i] = list[index * 5 + i];
        }
        for (int i = 0; i < 5; ++i) {
          list[index * 5 + i] = list[index_xor * 5 + i];
        }
        for (int i = 0; i < 5; ++i) {
          list[index_xor * 5 + i] = temp[i];
        }
      }
    }
  }
}
void bitonic_sort_box(real list[], const int num_boxes)
{
  int num_power_of_2 = 1;
  while (num_power_of_2 < num_boxes) num_power_of_2 *= 2;
  const int num_threads = num_power_of_2;
  const int threads_per_block = 512;
  const int num_blocks = DIV_THEN_CEIL(num_threads,  threads_per_block);

  // major step
  for (int idx_major = 2; idx_major <= num_threads; idx_major *= 2) {
    // minor step
    for (int idx_minor = idx_major / 2; idx_minor > 0; idx_minor /= 2) {
      bitonic_sort_step<<<num_blocks, threads_per_block>>>(
          list, idx_major, idx_minor);
    }
  }
}
#endif

// quick-sort a list of boxes in descending order of their scores (CPU)
//   list: num_boxes x 5 array,  (x1, y1, x2, y2, score) for each box
//   if num_top <= end,  only top-k results are guaranteed to be sorted
//   (for efficient computation)
static
void sort_box(real list[], const int start, const int end,
              const int num_top)
{
  const real pivot_score = list[start * 5 + 4];
  int left = start + 1, right = end;
  real temp[5];
  while (left <= right) {
    while (left <= end && list[left * 5 + 4] >= pivot_score) ++left;
    while (right > start && list[right * 5 + 4] <= pivot_score) --right;
    if (left <= right) {
      for (int i = 0; i < 5; ++i) {
        temp[i] = list[left * 5 + i];
      }
      for (int i = 0; i < 5; ++i) {
        list[left * 5 + i] = list[right * 5 + i];
      }
      for (int i = 0; i < 5; ++i) {
        list[right * 5 + i] = temp[i];
      }
      ++left;
      --right;
    }
  }

  if (right > start) {
    for (int i = 0; i < 5; ++i) {
      temp[i] = list[start * 5 + i];
    }
    for (int i = 0; i < 5; ++i) {
      list[start * 5 + i] = list[right * 5 + i];
    }
    for (int i = 0; i < 5; ++i) {
      list[right * 5 + i] = temp[i];
    }
  }

  if (start < right - 1) {
    sort_box(list, start, right - 1, num_top);
  }
  if (right + 1 < num_top && right + 1 < end) {
    sort_box(list, right + 1, end, num_top);
  }
}

// generate all candidate boxes with their scores
//   bottom: 1 x num_anchors x H x W tensor
//     bottom[0, k, h, w] = foreground score of anchor k at node (h, w)
//   d_anchor: num_anchors x 4 x H x W tensor
//     d_anchor[k, :, h, w] = gradient (dx, dy, d(log w), d(log h))
//                            of anchor k at center location (h, w)
//   num_anchors: number of anchors  (= # scales * # ratios)
//   anchors: num_anchors * 4 array,  (x1, y1, x2, y2) for each anchor
//   img_H, img_W: scaled image height & width
//   min_box_H, min_box_W: minimum box height & width
//   feat_stride: scaled image height (width) / bottom height (width)
//   proposals: num_proposals * 5 array
//     num_proposals = num_anchors * H * W
//     (x1, y1, x2, y2, score) for each proposal
#ifdef GPU
__global__
void enumerate_proposals_gpu(const real bottom4d[],
                             const real d_anchor4d[],
                             const real anchors[],
                             const int num_anchors,
                             const int bottom_H, const int bottom_W,
                             const real img_H, const real img_W,
                             const real min_box_H, const real min_box_W,
                             const int feat_stride,
                             real proposals[])
{
  const int bottom_area = bottom_H * bottom_W;
  const int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index < num_anchors * bottom_area) {
    const int h = index / num_anchors / bottom_W;
    const int w = (index / num_anchors) % bottom_W;
    const int k = index % num_anchors;
    const real x = w * feat_stride;
    const real y = h * feat_stride;
    const real* p_box = d_anchor4d + h * bottom_W + w;
    const real* p_score = bottom4d + h * bottom_W + w;

    const real dx = p_box[(k * 4 + 0) * bottom_area];
    const real dy = p_box[(k * 4 + 1) * bottom_area];
    const real d_log_w = p_box[(k * 4 + 2) * bottom_area];
    const real d_log_h = p_box[(k * 4 + 3) * bottom_area];

    proposals[index * 5 + 0] = x + anchors[k * 4 + 0];
    proposals[index * 5 + 1] = y + anchors[k * 4 + 1];
    proposals[index * 5 + 2] = x + anchors[k * 4 + 2];
    proposals[index * 5 + 3] = y + anchors[k * 4 + 3];

    proposals[index * 5 + 4]
        = transform_box(&proposals[index * 5],
                        dx, dy, d_log_w, d_log_h,
                        img_W, img_H, min_box_W, min_box_H)
          * p_score[k * bottom_area];
  }
  else {
    // in GPU mode, total space allocated for proposals should be
    // a power of 2 >= actual number of proposals,
    // thus, scores of virtually-padded boxes should be set smaller than
    // mininum score of actual boxes
    // (in RPN, 0 is the smallest possible score)
    proposals[index * 5 + 0] = 0;
    proposals[index * 5 + 1] = 0;
    proposals[index * 5 + 2] = 0;
    proposals[index * 5 + 3] = 0;
    proposals[index * 5 + 4] = 0;
  }
}
#else
void enumerate_proposals_cpu(const real bottom4d[],
                             const real d_anchor4d[],
                             const real anchors[],
                             const int num_anchors,
                             const int bottom_H, const int bottom_W,
                             const real img_H, const real img_W,
                             const real min_box_H, const real min_box_W,
                             const int feat_stride,
                             real proposals[])
{
  const int bottom_area = bottom_H * bottom_W;
  for (int h = 0; h < bottom_H; ++h) {
    for (int w = 0; w < bottom_W; ++w) {
      const real x = w * feat_stride;
      const real y = h * feat_stride;
      const real* p_box = d_anchor4d + h * bottom_W + w;
      const real* p_score = bottom4d + h * bottom_W + w;
      for (int k = 0; k < num_anchors; ++k) {
        const real dx = p_box[(k * 4 + 0) * bottom_area];
        const real dy = p_box[(k * 4 + 1) * bottom_area];
        const real d_log_w = p_box[(k * 4 + 2) * bottom_area];
        const real d_log_h = p_box[(k * 4 + 3) * bottom_area];

        const int index = (h * bottom_W + w) * num_anchors + k;
        proposals[index * 5 + 0] = x + anchors[k * 4 + 0];
        proposals[index * 5 + 1] = y + anchors[k * 4 + 1];
        proposals[index * 5 + 2] = x + anchors[k * 4 + 2];
        proposals[index * 5 + 3] = y + anchors[k * 4 + 3];

        proposals[index * 5 + 4]
            = transform_box(&proposals[index * 5],
                            dx, dy, d_log_w, d_log_h,
                            img_W, img_H, min_box_W, min_box_H)
              * p_score[k * bottom_area];
      } // endfor k
    } // endfor w
  } // endfor h
}
#endif

// retrieve proposals that are determined to be kept as RoIs by NMS
//   proposals : "num_boxes x 5" array,  (x1, y1, x2, y2, score) for each box
//   num_rois: number of RoIs to be retrieved
//   keep: "num_rois x 1" array
//     keep[i]: index of i-th RoI in proposals
//   rois: "num_rois x 5" array,  (x1, y1, x2, y2, score) for each RoI
#ifdef GPU
__global__
void retrieve_rois_gpu(const real proposals[],
                       const int keep[],
                       real rois[],
                       const int num_rois)
{
  const int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index < num_rois) {
    const real* const proposals_index = proposals + keep[index] * 5;
    rois[index * 5 + 0] = proposals_index[0];
    rois[index * 5 + 1] = proposals_index[1];
    rois[index * 5 + 2] = proposals_index[2];
    rois[index * 5 + 3] = proposals_index[3];
    rois[index * 5 + 4] = proposals_index[4];
  }
}
#else
void retrieve_rois_cpu(const real proposals[],
                       const int keep[],
                       real rois[],
                       const int num_rois)
{
  for (int i = 0; i < num_rois; ++i) {
    const real* const proposals_index = proposals + keep[i] * 5;
    rois[i * 5 + 0] = proposals_index[0];
    rois[i * 5 + 1] = proposals_index[1];
    rois[i * 5 + 2] = proposals_index[2];
    rois[i * 5 + 3] = proposals_index[3];
    rois[i * 5 + 4] = proposals_index[4];
  }
}
#endif



// --------------------------------------------------------------------------
// layer operator code
//   proposal_forward
// --------------------------------------------------------------------------

// proposal: bottom -> top
//   bottom: 2 x num_anchors x H x W tensor
//     bottom[0, k, h, w] = background score of anchor k at node (h, w)
//     bottom[1, k, h, w] = foreground score of anchor k at node (h, w)
//   d_anchor: num_anchors x 4 x H x W tensor
//     d_anchor[k, :, h, w] = gradient (dx, dy, d(log w), d(log h))
//                            of anchor k at center location (h, w)
//   img_info: 6 x 1 tensor,  (img_H, img_W, scale_H, scale_W, raw_H, raw_W)
//     img_H, img_W: scaled image height & width
//     scale_H: height scale factor
//              img_H = raw image height * scale_H
//     scale_W: width scale factor
//              img_W = raw image width * scale_W
//     raw_H, raw_W: raw image height & width
//   top: num_RoIs x 5 tensor,  (x1, y1, x2, y2, score) of each RoI
//   anchors: num_anchors * 4 array,  (x1, y1, x2, y2) for each anchor
//   4 temporary arrays
//     proposals: all box proposals with their scores
//       "num_boxes x 5" array,  (x1, y1, x2, y2, score) for each box
//       in GPU mode, if proposals = NULL, use bitonic sort in GPU
//       if proposals != NULL & allocated in main memory, quicksort in CPU
//     keep: indices of proposals to be retrieved as RoIs
//       "num_rois x 1" array,  keep[i]: index of i-th RoI in proposals
//       TODO: always stored in main memory due to implementation issue
//     proposals_dev: GPU memory space, required in GPU mode
//       in GPU mode, total space allocated for proposals should be
//       a power of 2 >= num_boxes
//     keep_dev: GPU memory space, required in GPU mode
void proposal_forward(const Tensor* const bottom4d,
                      const Tensor* const d_anchor4d,
                      const Tensor* const img_info1d,
                      Tensor* const top2d,
                      const real anchors[],
                      real proposals[],
                      int keep[],
                      real proposals_dev[],
                      int keep_dev[],
                      const LayerOption* const option)
{
  // number of anchors  (= number of scales * ratios)
  const int num_anchors = option->num_ratios * option->num_scales;

  // do forward-pass for each item in the batch
  const real* p_bottom_item = bottom4d->data;
  const real* p_d_anchor_item = d_anchor4d->data;
  const real* p_img_info = img_info1d->data;
  real* p_top_item = top2d->data;
  int total_top_size = 0;

  tick00 = clock();

  for (int n = 0; n < bottom4d->num_items; ++n) {
    // bottom shape: 2 x num_anchors x H x W
    const int bottom_H = bottom4d->shape[n][2];
    const int bottom_W = bottom4d->shape[n][3];
    const int bottom_area = bottom_H * bottom_W;
    // input image height & width
    const real img_H = p_img_info[0];
    const real img_W = p_img_info[1];
    // scale factor for height & width
    const real scale_H = p_img_info[2];
    const real scale_W = p_img_info[3];
    // minimum box width & height
    const real min_box_H = option->min_size * scale_H;
    const real min_box_W = option->min_size * scale_W;

    tick0 = clock();
    // enumerate all proposals
    //   num_proposals = num_anchors * H * W
    //   (x1, y1, x2, y2, score) for each proposal
    // NOTE: for bottom, only foreground scores are passed
    #ifdef GPU
    {
      // in GPU mode, total space allocated for proposals is
      // a power of 2 >= num_proposals (due to bitonic sort algorithm)
      // thus, scores of virtually-padded boxes should be set smaller than
      // mininum score of actual boxes
      const int num_proposals = num_anchors * bottom_area;
      int num_power_of_2 = 1;
      while (num_power_of_2 < num_proposals) num_power_of_2 *= 2;
      const int num_threads = num_power_of_2;
      const int threads_per_block = 512;
      const int num_blocks = DIV_THEN_CEIL(num_threads,  threads_per_block);
      enumerate_proposals_gpu<<<num_blocks, threads_per_block>>>(
          p_bottom_item + num_anchors * bottom_area,
          p_d_anchor_item,  anchors,  num_anchors,
          bottom_H,  bottom_W,  img_H,  img_W,  min_box_H,  min_box_W,
          option->feat_stride,
          proposals_dev);
    }
    #else
    {
      enumerate_proposals_cpu(
          p_bottom_item + num_anchors * bottom_area,
          p_d_anchor_item,  anchors,  num_anchors,
          bottom_H,  bottom_W,  img_H,  img_W,  min_box_H,  min_box_W,
          option->feat_stride,
          proposals);
    }
    #endif
    tick1 = clock();
    a_time[0] = (float)(tick1 - tick0) / CLOCKS_PER_SEC;

    tick0 = clock();
    // choose candidates according to scores
    #ifdef GPU
    {
      const int num_proposals = num_anchors * bottom_area;
      if (!proposals) {
        // in GPU mode, if proposals = NULL, use bitonic sort in GPU
        bitonic_sort_box(proposals_dev, num_proposals);
      }
      else {
        // if proposals != NULL & allocated in main memory, quicksort in CPU
        cudaMemcpyAsync(proposals, proposals_dev,
                        num_proposals * 5 * sizeof(real),
                        cudaMemcpyDeviceToHost);
        sort_box(proposals, 0, num_proposals - 1, option->pre_nms_topn);
        cudaMemcpyAsync(proposals_dev, proposals,
                        num_proposals * 5 * sizeof(real),
                        cudaMemcpyHostToDevice);
      }
    }
    #else
    {
      const int num_proposals = num_anchors * bottom_area;
      sort_box(proposals, 0, num_proposals - 1, option->pre_nms_topn);
    }
    #endif
    tick1 = clock();
    a_time[1] = (float)(tick1 - tick0) / CLOCKS_PER_SEC;

    tick0 = clock();
    // NMS & RoI retrieval
    {
      // NMS
      const int num_proposals
          = MIN(num_anchors * bottom_area,  option->pre_nms_topn);
      int num_rois = 0;
      nms(num_proposals,  proposals,  &num_rois,  keep,  0,
          option->nms_thresh,  option->post_nms_topn,
          option->bbox_vote,  option->vote_thresh);

      // RoI retrieval
      #ifdef GPU
      {
        const int num_threads = num_rois;
        const int threads_per_block = 128;
        const int num_blocks
            = DIV_THEN_CEIL(num_threads,  threads_per_block);

        cudaMemcpyAsync(keep_dev, keep, num_rois * sizeof(int),
                        cudaMemcpyHostToDevice);

        retrieve_rois_gpu<<<num_blocks, threads_per_block>>>(
            proposals_dev,  keep_dev,  p_top_item,  num_rois);
      }
      #else
      {
        retrieve_rois_cpu(
            proposals,  keep,  p_top_item,  num_rois);
      }
      #endif

      // set top shape: num_rois x 5,  (x1, y1, x2, y2, score) for each RoI
      top2d->shape[n][0] = num_rois;
      top2d->shape[n][1] = 5;
      top2d->start[n] = total_top_size;
      total_top_size += num_rois * 5;
    }
    tick1 = clock();
    a_time[2] = (float)(tick1 - tick0) / CLOCKS_PER_SEC;

    // locate next item
    {
      const int bottom_size = 2 * num_anchors * bottom_area;
      const int d_anchor_size = 4 * num_anchors * bottom_area;
      const int img_info_size = 6;
      const int top_size = 5 * top2d->shape[n][0];
      p_bottom_item += bottom_size;
      p_d_anchor_item += d_anchor_size;
      p_img_info += img_info_size;
      p_top_item += top_size;
    }
  } // endfor batch

  top2d->ndim = 2;
  top2d->num_items = bottom4d->num_items;

  tick1 = clock();
  a_time[3] = (float)(tick1 - tick00) / CLOCKS_PER_SEC;
  a_time[7] += (float)(tick1 - tick00) / CLOCKS_PER_SEC;
}



// --------------------------------------------------------------------------
// layer shape calculator code
// --------------------------------------------------------------------------
void proposal_shape(const Tensor* const bottom4d,
                    Tensor* const top2d,
                    int* const proposals_size,
                    int* const keep_size,
                    const LayerOption* const option)
{
  int max_area = 0;

  // calculate shape for each item in the batch
  top2d->ndim = 2;
  top2d->num_items = bottom4d->num_items;
  for (int n = 0; n < bottom4d->num_items; ++n) {
    // calculate maximum area size for determining temporary space size
    const int bottom_H = bottom4d->shape[n][2];
    const int bottom_W = bottom4d->shape[n][3];
    const int bottom_area = bottom_H * bottom_W;
    max_area = MAX(max_area,  bottom_area);

    // top shape <= post_nms_topn x 5
    //   exact row size will be determined after forward-pass
    top2d->shape[n][0] = option->post_nms_topn;
    top2d->shape[n][1] = 5;
    top2d->start[n] = top2d->shape[n][0] * top2d->shape[n][1];
  }

  // temporary space size
  //   in GPU mode, total space allocated for proposals should be
  //   a power of 2 >= actual number of proposals
  {
    const int num_anchors = option->num_ratios * option->num_scales;
    const int num_proposals = num_anchors * max_area;
    int num_power_of_2 = 1;
    while (num_power_of_2 < num_proposals) num_power_of_2 *= 2;
    *proposals_size = num_power_of_2 * 5;
    *keep_size = option->post_nms_topn;
  }
}



// --------------------------------------------------------------------------
// API code
// --------------------------------------------------------------------------

void init_proposal_layer(void* const net_, void* const layer_)
{
  Net* const net = (Net*)net_;
  Layer* const layer = (Layer*)layer_;

  const int num_anchors
      = layer->option.num_scales * layer->option.num_ratios;

  #ifdef GPU
  {
    if (layer->p_aux_data[0]) {
      cudaFree(layer->p_aux_data[0]);
    }
    cudaMalloc(&layer->p_aux_data[0], num_anchors * 4 * sizeof(real));
    generate_anchors(net->param_cpu_data, &layer->option);
    cudaMemcpyAsync(layer->p_aux_data[0], net->param_cpu_data,
                    num_anchors * 4 * sizeof(real),
                    cudaMemcpyHostToDevice);
  }
  #else
  {
    if (layer->p_aux_data[0]) {
      free(layer->p_aux_data[0]);
    }
    layer->p_aux_data[0] = (real*)malloc(num_anchors * 4 * sizeof(real));
    generate_anchors(layer->p_aux_data[0], &layer->option);
  }
  #endif

  net->space += num_anchors * 4 * sizeof(real);
}

void forward_proposal_layer(void* const net_, void* const layer_)
{
  Net* const net = (Net*)net_;
  Layer* const layer = (Layer*)layer_;

  proposal_forward(layer->p_bottoms[0], layer->p_bottoms[1],
                   layer->p_bottoms[2],
                   layer->p_tops[0], layer->p_aux_data[0],
                   net->temp_cpu_data, net->tempint_cpu_data,
                   net->temp_data, net->tempint_data,
                   &layer->option);

  #ifdef DEBUG
  {
    printf("%s:  ", layer->name);
    for (int i = 0; i < 8; ++i) {
      printf("%4.2f\t", a_time[i] * 1000);
    }
    printf("\n");
  }
  #endif
}

void shape_proposal_layer(void* const net_, void* const layer_)
{
  Net* const net = (Net*)net_;
  Layer* const layer = (Layer*)layer_;

  int temp_size, tempint_size;

  proposal_shape(layer->p_bottoms[0], layer->p_tops[0],
                 &temp_size, &tempint_size, &layer->option);

  update_net_size(net, layer, temp_size, tempint_size, 0);
}

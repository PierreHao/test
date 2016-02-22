#include "layer.h"
#include "cuda_settings.h"

// convert top5d (C x kernel_h x kernel_w x H5 x W5)
//         -> top3d (C x H x W)
//   TODO: detailed description
__global__ void convert_top(const real* top5d, real* const top3d,
                            const int C, const int H, const int W,
                            const int H5, const int W5,
                            const int kernel_h, const int kernel_w,
                            const int pad_h, const int pad_w,
                            const int stride_h, const int stride_w)
{
  const int top_HW = H * W;
  const int top_CHW = top_HW * C;

  // thread index: (c, h, w) = c*H*W + h*W + w
  for (int index = blockIdx.x * blockDim.x + threadIdx.x;
       index < top_CHW;
       index += blockDim.x) {
    // parse thread index -> (c, h, w)
    const int c = index / top_HW;
    const int h = (index / W) % H + pad_h;
    const int w = index % W + pad_w;

    // range of summation
    // top3d[c][h][w] = sum_{h5,w5} top5d[]
    //   0 <= h5 <= 0
    //   0 <= w5 <= 0
    //   TODO: optimization & description
    const int h5_start = (h < kernel_h) ? 0 : (h - kernel_h) / stride_h + 1;
    const int h5_end = min(h / stride_h + 1, H5);
    const int w5_start = (w < kernel_w) ? 0 : (w - kernel_w) / stride_w + 1;
    const int w5_end = min(w / stride_w + 1, W5);
    const real* p_top5d = top5d + (c * kernel_h * kernel_w + h * kernel_w + w) * H5 * W5;
    const int h5_coef = (1 - stride_h * kernel_w * H5) * W5;
    const int w5_coef = 1 - stride_w * H5 * W5;

    // top3d[c][h][w] = sum_{h5,w5} top5d[]
    real val = 0;
    for (int h5 = h5_start; h5 < h5_end; ++h5) {
      for (int w5 = w5_start; w5 < w5_end; ++w5) {
        val += p_top5d[h5 * h5_coef + w5 * w5_coef];
      }
    }
    top3d[index] = val;
  }
}

void forward(const Tensor* bottom4d, Tensor* const top4d,
             const Tensor* weight5d, const Tensor* bias2d,
             real* const temp_data, const real* const_data,
             const ConvOption* option)
{
  // weight shape: G x C' x C x kernel_h x kernel_w
  //   G: number of groups
  const int num_groups = weight5d->shape[0][0]; // G
  const int bottom_C = weight5d->shape[0][1];  // C'
  const int top_C = weight5d->shape[0][2];  // C
  const int kernel_h = weight5d->shape[0][3];
  const int kernel_w = weight5d->shape[0][4];
  const int kernel_size = top_C * kernel_h * kernel_w;

  // padding size & stride size
  const int pad_h = option->pad_h;
  const int pad_w = option->pad_w;
  const int stride_h = option->stride_h;
  const int stride_w = option->stride_w;

  const cublasHandle_t* cublas_handle = (cublasHandle_t*)option->handle;
  const real one = 1.0, zero = 0.0;

  // do forward-pass for each item in the batch
  const real* p_bottom_data = bottom4d->data;
  real* p_top_data = top4d->data;
  const int num_items = bottom4d->num_items;
  for (int n = 0; n < num_items; ++n) {
    // bottom shape: G x C' x H' x W'
    const int bottom_H = bottom4d->shape[n][2];  // H'
    const int bottom_W = bottom4d->shape[n][3];  // W'
    const int bottom_area = bottom_H * bottom_W;

    // set top shape: G x C x H x W
    //   H' = 1 + (H + 2 * pad_h - kernel_h) / stride_h
    //   -> H = stride_h * (H' - 1) - 2 * pad_h + kernel_h
    const int top_H = stride_h * (bottom_H - 1) - 2 * pad_h + kernel_h;
    const int top_W = stride_w * (bottom_W - 1) - 2 * pad_w + kernel_w;
    const int top_size = num_groups * top_C * top_H * top_W;
    top4d->shape[n][0] = num_groups;
    top4d->shape[n][1] = top_C;
    top4d->shape[n][2] = top_H;
    top4d->shape[n][3] = top_W;

   { // do matrix computation
    // top[g] = dot(weight[g].trans(), bottom[g])
    //   weight[g].trans(): (C * kernel_h * kernel_w) x C'
    //   bottom[g]: C' x (H' * W')
    //   top[g]: (C * kernel_h * kernel_w) x (H' * W')
    for (int g = 0; g < num_groups; ++g) {
      cublasSgemm(*cublas_handle, CUBLAS_OP_N, CUBLAS_OP_T,
                  bottom_area, kernel_size, bottom_C,
                  &one, p_bottom_data + g * bottom_C * bottom_area, bottom_area,
                  weight5d->data + g * bottom_C * kernel_size, kernel_size,
                  &zero, temp_data + g * kernel_size * bottom_area, bottom_area);
    }
   } // end matrix computation

   { // convert top shape: (C * kernel_h * kernel_w) x (H' * W') -> C x H x W
    const int num_threads = 1024;
    const int num_blocks = (num_threads - 1 + top_size) / num_threads;
    convert_top<<<num_blocks, num_threads>>>(temp_data, p_top_data,
                                             num_groups * top_C, top_H, top_W,
                                             bottom_H, bottom_W,
                                             kernel_h, kernel_w,
                                             pad_h, pad_w,
                                             stride_h, stride_w);
   } // end convert top shape

    // top = top + bias
    if (option->bias) {
      cublasSgemm(*cublas_handle, CUBLAS_OP_N, CUBLAS_OP_N,
                  top_H * top_W, num_groups * top_C, 1,
                  &one, const_data, top_H * top_W,
                  bias2d->data, 1,
                  &one, p_top_data, top_H * top_W);
    }

    // locate next data
    p_bottom_data += num_groups * bottom_C * bottom_area;
    p_top_data += top_size;
  } // endfor batch

  top4d->ndim = 4;
  top4d->num_items = num_items;
}

// TODO
void backward(Tensor *top_grad, Tensor *bottom_grad, Tensor *top_layer, Tensor *bottom_layer, ConvOption *option)
{
  return;
}

#define DATA_SIZE 512*18*23*4
#define WEIGHT_SIZE 512*1*1*4*4
#define BIAS_SIZE 512

int main(int argc, char **argv)
{
  Tensor X, Y, W, b;
  real* X_data = (real*)malloc(DATA_SIZE * sizeof(real));
  real* Y_data = (real*)malloc(DATA_SIZE * sizeof(real));
  real* W_data = (real*)malloc(WEIGHT_SIZE * sizeof(real));
  real* b_data = (real*)malloc(BIAS_SIZE * sizeof(real));
  real* const_data = (real*)malloc(BIAS_SIZE * sizeof(real));
  real* p_temp_data;
  real* p_const_data;
  ConvOption option;
  cublasHandle_t cublas_handle;
 {
  X.ndim = 4; X.num_items = 1;
  for (int i = 0; i < X.num_items; ++i) {
    X.shape[i][0] = 512;
    X.shape[i][1] = 1;
    X.shape[i][2] = 18;
    X.shape[i][3] = 23;
  }
  W.ndim = 5; W.num_items = 1;
  W.shape[0][0] = 512; W.shape[0][1] = 1; W.shape[0][2] = 1; W.shape[0][3] = 4; W.shape[0][4] = 4;
  b.ndim = 2; b.num_items = 1; b.shape[0][0] = 512; b.shape[0][1] = 1;
  option.kernel_h = 4;
  option.kernel_w = 4;
  option.pad_h = 1;
  option.pad_w = 1;
  option.stride_h = 2;
  option.stride_w = 2;
  option.bias = 0;
 }
 {
  FILE* fp;
  int X_size = flatten_size(&X);
  int W_size = flatten_size(&W);
  int b_size = flatten_size(&b);
  printf("data loading\n");
  fp = fopen("../data/temp/deconv_bottom0.txt", "r");
  for (int i = 0; i < X_size; ++i)
    fscanf(fp, "%f", &X_data[i]);
  fclose(fp);
  fp = fopen("../data/temp/deconv_param0.txt", "r");
  for (int i = 0; i < W_size; ++i)
    fscanf(fp, "%f", &W_data[i]);
  fclose(fp);
  if (option.bias) {
    fp = fopen("../data/temp/deconv_param1.txt", "r");
    for (int i = 0; i < b_size; ++i)
      fscanf(fp, "%f", &b_data[i]);
    fclose(fp);
    for (int i = 0; i < b_size; ++i) {
      const_data[i] = 1;
    }
  }

  printf("set device\n");
  CUDA_CHECK(cudaSetDevice(1));
  //printf("get device\n");
  //CUDA_CHECK(cudaGetDevice(0));
  printf("cublas initialization\n");
  if (cublasCreate(&cublas_handle) != CUBLAS_STATUS_SUCCESS) {
    printf("cublas creation failed\n");
  }
  option.handle = &cublas_handle;

  printf("cuda malloc\n");
  CUDA_CHECK(cudaMalloc(&X.data, DATA_SIZE*sizeof(real)));
  CUDA_CHECK(cudaMalloc(&Y.data, DATA_SIZE*sizeof(real)));
  CUDA_CHECK(cudaMalloc(&W.data, WEIGHT_SIZE*sizeof(real)));
  CUDA_CHECK(cudaMalloc(&b.data, BIAS_SIZE*sizeof(real)));
  CUDA_CHECK(cudaMalloc(&p_temp_data, 4*4*DATA_SIZE*sizeof(real)));
  CUDA_CHECK(cudaMalloc(&p_const_data, BIAS_SIZE*sizeof(real)));

  printf("memcopy\n");
  CUDA_CHECK(cudaMemcpy(X.data, X_data, X_size*sizeof(real), cudaMemcpyHostToDevice));
  CUDA_CHECK(cudaMemcpy(W.data, W_data, W_size*sizeof(real), cudaMemcpyHostToDevice));
  CUDA_CHECK(cudaMemcpy(b.data, b_data, b_size*sizeof(real), cudaMemcpyHostToDevice));
  CUDA_CHECK(cudaMemcpy(p_const_data, const_data, b_size*sizeof(real), cudaMemcpyHostToDevice));
 }
 {
  printf("do forward\n");
  forward(&X, &Y, &W, &b, p_temp_data, p_const_data, &option);
 }
 {
  int Y_size = flatten_size(&Y);
  printf("memcpy\n");
  CUDA_CHECK(cudaMemcpy(Y_data, Y.data, Y_size*sizeof(real), cudaMemcpyDeviceToHost));
 }
 {
  real* p_Y_data = &Y_data[0];
  for (int n = 0; n < Y.num_items; ++n) {
    for (int g = 0; g < Y.shape[n][0]; ++g) {
      for (int c = 0; c < Y.shape[n][1]; ++c) {
        for (int h = 0; h < Y.shape[n][2]; ++h) {
          for (int w = 0; w < Y.shape[n][3]; ++w) {
            printf("%.4f\n", *(p_Y_data++));
          }
        }
      }
    }
  }
 }
 {
  printf("cuda free\n");
  CUDA_CHECK(cudaFree(X.data));
  CUDA_CHECK(cudaFree(Y.data));
  CUDA_CHECK(cudaFree(W.data));
  CUDA_CHECK(cudaFree(b.data));
  CUDA_CHECK(cudaFree(p_temp_data));
  CUDA_CHECK(cudaFree(p_const_data));
  printf("cublas finalization\n");
  if (cublasDestroy(cublas_handle) != CUBLAS_STATUS_SUCCESS) {
    printf("cublas destruction failed\n");
  }
  printf("free\n");
  free(X_data);
  free(Y_data);
  free(W_data);
  free(b_data);
  free(const_data);
  return 0;
 }
}

/*************************************************************************
 * Copyright (c) 2022-2023, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 *
 * See LICENSE for license information.
 ************************************************************************/

#include <type_traits>
#include <transformer_engine/transformer_engine.h>
#include <transformer_engine/logging.h>
#include <transformer_engine/gemm.h>
#ifndef __HIP_PLATFORM_HCC__
#include <cublasLt.h>
#include <cublas_v2.h>
#else
#define ROCBLAS_BETA_FEATURES_API 
#include <rocblas/rocblas.h>
#ifdef USE_HIPBLASLT
#include <hipblaslt/hipblaslt.h>
#endif // #ifdef USE_HIPBLASLT
#endif
#include "../common.h"
#include "../util/vectorized_pointwise.h"
#ifdef __HIP_PLATFORM_HCC__
#include <hipcub/hipcub.hpp>
#include <iostream>
#include <cstdlib>
#include <string>
#endif

namespace {

#ifdef __HIP_PLATFORM_HCC__
#ifdef USE_HIPBLASLT
hipblasltDatatype_t get_cuda_dtype(const transformer_engine::DType t) {
  using namespace transformer_engine;
  switch (t) {
    case DType::kFloat16:
      return HIPBLASLT_R_16F;
    case DType::kFloat32:
      return HIPBLASLT_R_32F;
    case DType::kBFloat16:
      return HIPBLASLT_R_16B;
    case DType::kFloat8E4M3:
      return HIPBLASLT_R_8F_E4M3;
    case DType::kFloat8E5M2:
      return HIPBLASLT_R_8F_E5M2;
    default:
      NVTE_ERROR("Invalid type");
  }
}
#else
rocblas_datatype get_cuda_dtype(const transformer_engine::DType t) {
  using namespace transformer_engine;
  switch (t) {
    case DType::kFloat16:
      return rocblas_datatype_f16_r;
    case DType::kFloat32:
      return rocblas_datatype_f32_r;
    case DType::kBFloat16:
      return rocblas_datatype_bf16_r;
    case DType::kFloat8E4M3:
      return rocblas_datatype_f8_r;
    case DType::kFloat8E5M2:
      return rocblas_datatype_bf8_r;
    default:
      NVTE_ERROR("Invalid type");
  }
}
#endif //#ifdef USE_HIPBLASLT
#else
cudaDataType_t get_cuda_dtype(const transformer_engine::DType t) {
  using namespace transformer_engine;
  switch (t) {
    case DType::kFloat16:
      return CUDA_R_16F;
    case DType::kFloat32:
      return CUDA_R_32F;
    case DType::kBFloat16:
      return CUDA_R_16BF;
    case DType::kFloat8E4M3:
      return CUDA_R_8F_E4M3;
    case DType::kFloat8E5M2:
      return CUDA_R_8F_E5M2;
    default:
      NVTE_ERROR("Invalid type");
  }
}
#endif //#ifdef __HIP_PLATFORM_HCC__
}  // namespace


namespace transformer_engine {

#ifdef __HIP_PLATFORM_HCC__
#ifndef USE_HIPBLASLT

#define TRANSFORMER_ENGINE_TYPE_SWITCH_ROCM_SIM(dtype, type, ...) \
    switch (dtype) { \
        using namespace transformer_engine; \
        case DType::kFloat32: \
            { \
                using type = float; \
                {__VA_ARGS__} \
            } \
        break; \
        case DType::kFloat16: \
            { \
                using type = fp16; \
                {__VA_ARGS__} \
            } \
        break; \
        case DType::kBFloat16: \
            { \
                using type = bf16; \
                {__VA_ARGS__} \
            } \
        break; \
        case DType::kFloat8E5M2: \
        case DType::kFloat8E4M3: \
            { \
                NVTE_ERROR("FP8 type not instantiated"); \
            } \
        break; \
        default: \
            NVTE_ERROR("Invalid type."); \
    }


namespace detail {

struct Empty {};

__device__ inline fp32 identity(fp32 value, const Empty&) {
  return value;
}

__inline__ __device__
float gelu(float x, const Empty&)
{
  float cdf = 0.5f * (1.0f + tanhf((0.7978845608028654f * (x + 0.044715f * x * x * x))));
  return x * cdf;
}


__inline__ __device__
float gelu_forward(float x)
{
  float cdf = 0.5f * (1.0f + tanhf((0.7978845608028654f * (x + 0.044715f * x * x * x))));
  return x * cdf;
}


template <typename Tin, typename T>
__global__
void gelu_forward_kernel(const Tin* in, T* out, int m, int n) {
  for(int id = blockIdx.x * blockDim.x + threadIdx.x; id < m * n; id += blockDim.x * gridDim.x)
  {
    Tin x = in[id];
    float y = gelu_forward((float)x); 
    out[id] = (T)(y);
  }

}


template <typename Tin, typename T>
void gelu_forward_kernelLauncher(const Tin* in, T* out, int m, int n, hipStream_t stream) {
  int blocks_per_row = ceil(float(n)/1024);
  dim3 grid(min(m * blocks_per_row, 65536));
  dim3 block(min(n, 1024));
  hipLaunchKernelGGL(( gelu_forward_kernel<Tin, T>), dim3(grid), dim3(block), 0, stream, in, out, m, n);
}


__inline__ __device__
float gelu_backward(float x, float dy)
{
  constexpr float kBeta = 0.7978845608028654f; 
  constexpr float kKappa = 0.044715f;
  float x_sq = x * x;
  float x_cube = x_sq * x;
  float tanh_inner = tanhf((kBeta * (x + kKappa * x_cube)));

  float left = 0.5 * x;
  float right = 1.0f + tanh_inner;

  float left_derivative = 0.5 * right;

  float tanh_derivative = 1 - tanh_inner * tanh_inner;
  float inner_derivative = kBeta * (1.0f + 3.0 * kKappa * x_sq);
  float right_derivative = left * tanh_derivative * inner_derivative;

  return dy * (left_derivative + right_derivative);
}

template <typename Tin, typename T>
__global__ 
void gelu_backward_kernel(const Tin* dy, T* out, const T* __restrict pre_gelu_out, int m, int n) {
  for(int id = blockIdx.x * blockDim.x + threadIdx.x; id < m * n; id += blockDim.x * gridDim.x)
  {
    Tin x = (Tin)pre_gelu_out[id];
    Tin dx = (Tin)gelu_backward((float)x, (float)dy[id]); 
    out[id] = (T)(dx);
  }
}

template <typename Tin, typename T>
void gelu_backward_kernelLauncher(const Tin* in, T* out, const T* pre_gelu_out, int m, int n, hipStream_t stream) {
  int blocks_per_row = ceil(float(n)/1024);
  dim3 grid(min(m * blocks_per_row, 65536));
  dim3 block(min(n, 1024));
  hipLaunchKernelGGL(( gelu_backward_kernel<Tin, T>), dim3(grid), dim3(block), 0, stream, in, out, pre_gelu_out, m, n);
}

template <typename Tin, typename T, typename Tb>
__global__ 
void add_bias_kernel(const Tin* in, T* out, const Tb* __restrict bias, int m, int n)
{
  for(int id = blockIdx.x * blockDim.x + threadIdx.x; id < m * n; id += blockDim.x * gridDim.x)
  {
    Tin reg_bias = (Tin)bias[id % n];
    Tin val = in[id] + reg_bias;
    out[id] = (T)(val);
  }
}


template <typename Tin, typename T, typename Tb>
void add_bias_kernelLauncher(const Tin* in, T* out, const Tb* __restrict bias, int m, int n, hipStream_t stream) {
  dim3 block, grid;
  block.x = 1024;
  grid.x = ceil(m * n / 1024.);
  hipLaunchKernelGGL(( add_bias_kernel<Tin, T, Tb>), dim3(grid), dim3(block), 0, stream, in, out, bias, m, n);

}

template <typename Tin, typename T, typename Tb>
__global__ 
void add_bias_gelu_kernel(const Tin* in, T* out, T* pre_gelu_out, const Tb* __restrict bias, int m, int n)
{
  for(int id = blockIdx.x * blockDim.x + threadIdx.x; id < m * n; id += blockDim.x * gridDim.x)
  {
    Tin reg_bias = (Tin)bias[id % n];
    Tin val = in[id] + reg_bias;
    pre_gelu_out[id] = (T)(val);
    out[id] = (T)(gelu_forward(val));
  }
}

template <typename Tin, typename T, typename Tb>
void add_bias_gelu_kernelLauncher(const Tin* in, T* out, T* pre_gelu_out, const Tb* __restrict bias, int m, int n, hipStream_t stream) {
  dim3 block, grid;
  block.x = 1024;
  grid.x = ceil(m * n / 1024.);
  hipLaunchKernelGGL(( add_bias_gelu_kernel<Tin, T, Tb>), dim3(grid), dim3(block), 0, stream, in, out, pre_gelu_out, bias, m, n );

}

template <typename Tin, typename T>
__global__ 
void identity_kernel(const Tin* in, T* out, int n) {
  for(int id = blockIdx.x * blockDim.x + threadIdx.x; id < n; id += blockDim.x * gridDim.x)
  {
    Tin val = in[id];
    out[id] = (T)(val);
  }
}


template <typename Tin, typename T>
void identity_kernelLauncher(const Tin* in, T* out, int n, hipStream_t stream) {
  dim3 block, grid;
  block.x = 1024;
  grid.x = ceil( n / 1024.);
  hipLaunchKernelGGL(( identity_kernel<Tin, T>), dim3(grid), dim3(block), 0, stream, in, out, n );
}

template <typename Tin, int THREADS_PER_BLOCK>
__global__
void bias_gradient_kernel(const Tin* in, float* out, int m, int n) {
  typedef hipcub::BlockReduce<float, THREADS_PER_BLOCK> BlockReduce;
  __shared__ typename BlockReduce::TempStorage block_temp_storage;

  int BLOCKS_PER_COL = ceil(float(m)/THREADS_PER_BLOCK);
  int THREADS_PER_COL = BLOCKS_PER_COL * THREADS_PER_BLOCK;
  int idx = threadIdx.x + blockIdx.x * blockDim.x;
  int col_idx = idx / THREADS_PER_COL;
  int row_idx = idx % THREADS_PER_COL;
  float thread_data;
  if (row_idx < m)
    thread_data = (float)in[row_idx * n + col_idx];
  float local_sum;
  if (row_idx < (BLOCKS_PER_COL-1) * THREADS_PER_BLOCK) {
    local_sum = BlockReduce(block_temp_storage).Sum(thread_data);
  }
  else {
    local_sum = BlockReduce(block_temp_storage).Sum(thread_data, m-(BLOCKS_PER_COL-1)*THREADS_PER_BLOCK);
  }
  if (threadIdx.x == 0)
    atomicAdd(&out[col_idx], local_sum);
}

template <typename Tin>
void bias_gradient_kernelLauncher(const Tin* in, float* out, int m, int n, hipStream_t stream) { 
  dim3 block, grid;
  constexpr int THREADS_PER_BLOCK = 1024;
  int BLOCKS_PER_COL = ceil(float(m)/THREADS_PER_BLOCK);
  block.x = THREADS_PER_BLOCK;
  grid.x = BLOCKS_PER_COL*n;
  NVTE_CHECK_CUDA( hipMemset(out, 0, n*sizeof(float)) );
  hipLaunchKernelGGL(( bias_gradient_kernel<Tin, THREADS_PER_BLOCK>), dim3(grid), dim3(block), 0, stream, in, out, m, n);
}

} // namespace detail

transformer_engine::DType get_transformer_engine_dtype(const rocblas_datatype t) {
  using namespace transformer_engine;
  switch (t) {
    case rocblas_datatype_f16_r:
      return DType::kFloat16;
    case rocblas_datatype_f32_r:
      return DType::kFloat32;
    case rocblas_datatype_bf16_r:
      return DType::kBFloat16;
    case rocblas_datatype_f8_r:
      return DType::kFloat8E4M3;
    case rocblas_datatype_bf8_r:
      return DType::kFloat8E5M2;
    default:
      NVTE_ERROR("Invalid type");
  }
}
#endif //#ifndef USE_HIPBLASLT

#ifdef USE_HIPBLASLT
void cublas_gemm(const Tensor *inputA,
                 const Tensor *inputB,
                 Tensor *outputD,
                 const Tensor *inputBias,
                 Tensor *outputPreGelu,
                 int m, int n, int k,
                 int lda, int ldb, int ldd,
                 hipblasOperation_t transa,
                 hipblasOperation_t transb,
                 bool grad,
                 void* workspace,
                 size_t workspaceSize,
                 bool accumulate,
                 bool use_split_accumulator,
                 int math_sm_count,
                 hipStream_t stream
) {
  void *A = inputA->data.dptr;
  void *A_scale_inverse = inputA->scale_inv.dptr;
  void *B = inputB->data.dptr;
  void *B_scale_inverse = inputB->scale_inv.dptr;
  void *D = outputD->data.dptr;
  void *bias_ptr = inputBias->data.dptr;
  const bool bias = bias_ptr != nullptr;
  void *pre_gelu_out = outputPreGelu->data.dptr;
  const bool gelu = pre_gelu_out != nullptr;
  const bool use_fp8 = is_fp8_dtype(inputA->data.dtype) ||
                       is_fp8_dtype(inputB->data.dtype);
  const hipblasltDatatype_t A_type = get_cuda_dtype(inputA->data.dtype);
  const hipblasltDatatype_t B_type = get_cuda_dtype(inputB->data.dtype);
  const hipblasltDatatype_t D_type = get_cuda_dtype(outputD->data.dtype);
  const hipblasltDatatype_t bias_type = get_cuda_dtype(inputBias->data.dtype);

  NVTE_CHECK(!is_fp8_dtype(inputA->data.dtype) || A_scale_inverse != nullptr,
             "FP8 input to GEMM requires inverse of scale!");
  NVTE_CHECK(!is_fp8_dtype(inputB->data.dtype) || B_scale_inverse != nullptr,
             "FP8 input to GEMM requires inverse of scale!");

  // check consistency of arguments:
  // if fp8 is desired, context cannot be null
  // fp8 + gelu fusion + fp8 aux is unavailable right now.
  if (use_fp8) {
    NVTE_CHECK(!gelu, "fp8 gemm + gelu fusion is unavailable right now!");
  }
  float one = 1.0;
  float zero = 0.0;
  float beta = (accumulate) ? one : zero;

  hipblasLtHandle_t handle;
  NVTE_CHECK_CUBLAS(hipblasLtCreate(&handle));

  hipblasLtMatmulDesc_t       operationDesc = nullptr;
  hipblasLtMatrixLayout_t     Adesc = nullptr, Bdesc = nullptr, Cdesc = nullptr, Ddesc = nullptr;
  hipblasLtMatmulPreference_t preference = nullptr;
  int                             returnedResults = 0;
  hipblasLtMatmulHeuristicResult_t heuristicResult = {}; //TODO: Is this Okay?
  hipblasLtEpilogue_t epilogue = HIPBLASLT_EPILOGUE_DEFAULT;

  int64_t ld_gelumat = (int64_t) ldd;

  // default to tf32 except for e5m2 inputs where the config is not supported
  hipblasLtComputeType_t gemm_compute_type = HIPBLASLT_COMPUTE_F32;

  // Create matrix descriptors. Not setting any extra attributes.
  NVTE_CHECK_CUBLAS(hipblasLtMatrixLayoutCreate(&Adesc, A_type,
                                               transa == HIPBLAS_OP_N ? m : k,
                                               transa == HIPBLAS_OP_N ? k : m,
                                               lda));
  NVTE_CHECK_CUBLAS(hipblasLtMatrixLayoutCreate(&Bdesc, B_type,
                                               transb == HIPBLAS_OP_N ? k : n,
                                               transb == HIPBLAS_OP_N ? n : k,
                                               ldb));
  NVTE_CHECK_CUBLAS(hipblasLtMatrixLayoutCreate(&Ddesc, D_type, m, n, ldd));

  NVTE_CHECK_CUBLAS(hipblasLtMatmulDescCreate(&operationDesc, gemm_compute_type, HIPBLASLT_R_32F));
  NVTE_CHECK_CUBLAS(hipblasLtMatmulDescSetAttribute(operationDesc, HIPBLASLT_MATMUL_DESC_TRANSA,
                                                   &transa, sizeof(transa)));
  NVTE_CHECK_CUBLAS(hipblasLtMatmulDescSetAttribute(operationDesc, HIPBLASLT_MATMUL_DESC_TRANSB,
                                                   &transb, sizeof(transb)));

  // set fp8 attributes -- input and output types should already be set to fp8 as appropriate
  // Note: gelu fusion isn't available right now, and we don't need
  // amax(D) either (next op is high precision).
  if (use_fp8) {
    // Split accumulator.
    const int8_t fastAccuMode = (use_split_accumulator) ? 0 : 1;
    /*
    NVTE_CHECK_CUBLAS(hipblasLtMatmulDescSetAttribute(operationDesc,
                                                     HIPBLASLT_MATMUL_DESC_FAST_ACCUM, //TODO: We don't have fast accum mode yet
                                                     &fastAccuMode,
                                                     sizeof(fastAccuMode)));
    */
    NVTE_CHECK_CUBLAS(hipblasLtMatmulDescSetAttribute(operationDesc,
                                                     HIPBLASLT_MATMUL_DESC_A_SCALE_POINTER,
                                                     &A_scale_inverse,
                                                     sizeof(A_scale_inverse)));
    NVTE_CHECK_CUBLAS(hipblasLtMatmulDescSetAttribute(operationDesc,
                                                     HIPBLASLT_MATMUL_DESC_B_SCALE_POINTER,
                                                     &B_scale_inverse,
                                                     sizeof(B_scale_inverse)));
    if (bias) {
      NVTE_CHECK_CUBLAS(hipblasLtMatmulDescSetAttribute(operationDesc,
                                                       HIPBLASLT_MATMUL_DESC_BIAS_DATA_TYPE,
                                                       &bias_type, sizeof(bias_type)));
    }
  }

  if (bias && gelu) {
    if (grad) {
      epilogue = HIPBLASLT_EPILOGUE_DGELU_BGRAD;
    } else {
      epilogue = HIPBLASLT_EPILOGUE_GELU_AUX_BIAS;
    }
    NVTE_CHECK_CUBLAS(hipblasLtMatmulDescSetAttribute(operationDesc,
                                                      HIPBLASLT_MATMUL_DESC_BIAS_POINTER,
                                                      &bias_ptr, sizeof(bias_ptr)));
    NVTE_CHECK_CUBLAS(hipblasLtMatmulDescSetAttribute(
                            operationDesc, HIPBLASLT_MATMUL_DESC_EPILOGUE_AUX_POINTER,
                            &pre_gelu_out, sizeof(pre_gelu_out)));
    NVTE_CHECK_CUBLAS(hipblasLtMatmulDescSetAttribute(operationDesc,
                                                      HIPBLASLT_MATMUL_DESC_EPILOGUE_AUX_LD,
                                                      &ld_gelumat, sizeof(ld_gelumat)));
  } else if (bias) {
    if (grad) {
      // grad output is always input B
      epilogue = HIPBLASLT_EPILOGUE_BGRADB;
    } else {
      epilogue = HIPBLASLT_EPILOGUE_BIAS;
    }
    NVTE_CHECK_CUBLAS(hipblasLtMatmulDescSetAttribute(operationDesc,
                                                      HIPBLASLT_MATMUL_DESC_BIAS_POINTER,
                                                      &bias_ptr, sizeof(bias_ptr)));
  } else if (gelu) {
    if (grad) {
      epilogue = HIPBLASLT_EPILOGUE_DGELU;
    } else {
      epilogue = HIPBLASLT_EPILOGUE_GELU_AUX;
    }
    NVTE_CHECK_CUBLAS(hipblasLtMatmulDescSetAttribute(
                            operationDesc, HIPBLASLT_MATMUL_DESC_EPILOGUE_AUX_POINTER,
                            &pre_gelu_out, sizeof(pre_gelu_out)));
    NVTE_CHECK_CUBLAS(hipblasLtMatmulDescSetAttribute(operationDesc,
                                                     HIPBLASLT_MATMUL_DESC_EPILOGUE_AUX_LD,
                                                     &ld_gelumat, sizeof(ld_gelumat)));
  }

  NVTE_CHECK_CUBLAS(hipblasLtMatmulDescSetAttribute(operationDesc,
                                                   HIPBLASLT_MATMUL_DESC_EPILOGUE,
                                                   &epilogue, sizeof(epilogue)));

  NVTE_CHECK_CUBLAS(hipblasLtMatmulPreferenceCreate(&preference));
  NVTE_CHECK_CUBLAS(hipblasLtMatmulPreferenceSetAttribute(
                          preference, HIPBLASLT_MATMUL_PREF_MAX_WORKSPACE_BYTES,
                          &workspaceSize, sizeof(workspaceSize)));

  NVTE_CHECK_CUBLAS(hipblasLtMatmulAlgoGetHeuristic(handle, operationDesc, Adesc, Bdesc, Ddesc,
                                                   Ddesc, preference, 1, &heuristicResult,
                                                   &returnedResults));

  if (returnedResults == 0) throw std::runtime_error("Unable to find any suitable algorithms");

  // D = alpha * (A * B) + beta * C
  NVTE_CHECK_CUBLAS(hipblasLtMatmul(handle,
                                   operationDesc,
                                   static_cast<const void*>(&one),         /* alpha */
                                   A,                                      /* A */
                                   Adesc,
                                   B,                                      /* B */
                                   Bdesc,
                                   static_cast<const void*>(&beta),        /* beta */
                                   D,                                      /* C */
                                   Ddesc,
                                   D,                                      /* D */
                                   Ddesc,
                                   &heuristicResult.algo,                  /* algo */
                                   workspace,                              /* workspace */
                                   workspaceSize,
                                   stream));                               /* stream */


  NVTE_CHECK_CUBLAS(hipblasLtMatmulPreferenceDestroy(preference));
  NVTE_CHECK_CUBLAS(hipblasLtMatrixLayoutDestroy(Ddesc));
  NVTE_CHECK_CUBLAS(hipblasLtMatrixLayoutDestroy(Bdesc));
  NVTE_CHECK_CUBLAS(hipblasLtMatrixLayoutDestroy(Adesc));
  NVTE_CHECK_CUBLAS(hipblasLtMatmulDescDestroy(operationDesc));
  NVTE_CHECK_CUBLAS(hipblasLtDestroy(handle));
}
#else // Use rocblas + kernel, no fusion
void cublas_gemm(const Tensor *inputA,
                 const Tensor *inputB,
                 Tensor *outputD,
                 const Tensor *inputBias,
                 Tensor *outputPreGelu,
                 int m, int n, int k,
                 int lda, int ldb, int ldd,
                 rocblas_operation transa,
                 rocblas_operation transb,
                 bool grad,
                 void* workspace,
                 size_t workspaceSize,
                 bool accumulate,
                 bool use_split_accumulator,
                 int math_sm_count,
                 cudaStream_t stream
) { 
  void *A = inputA->data.dptr;
  void *A_scale_inverse = inputA->scale_inv.dptr;
  void *B = inputB->data.dptr;
  void *B_scale_inverse = inputB->scale_inv.dptr;
  void *C = outputD->data.dptr;
  void *D = outputD->data.dptr;
  void *D_scale = outputD->scale.dptr;
  void *D_amax = outputD->amax.dptr;
  void *bias_ptr = inputBias->data.dptr;
  const bool bias = bias_ptr != nullptr;
  void *pre_gelu_out = outputPreGelu->data.dptr;
  const bool gelu = pre_gelu_out != nullptr;
  const bool use_fp8 = is_fp8_dtype(inputA->data.dtype) ||
                       is_fp8_dtype(inputB->data.dtype);
  const rocblas_datatype A_type = get_cuda_dtype(inputA->data.dtype);
  const rocblas_datatype B_type = get_cuda_dtype(inputB->data.dtype);
  const rocblas_datatype D_type = get_cuda_dtype(outputD->data.dtype);
  const rocblas_datatype bias_type = get_cuda_dtype(inputBias->data.dtype);
  
  // check consistency of arguments:
  // if fp8 is desired, context cannot be null
  // fp8 + gelu fusion + fp8 aux is unavailable right now.
  if (use_fp8 && gelu) {
    NVTE_CHECK(!is_fp8_dtype(outputPreGelu->data.dtype),
             "fp8 Aux output for gemm + gelu fusion not supported!");
  }
  if (is_fp8_dtype(outputD->data.dtype)) {
    NVTE_CHECK(!accumulate,
             "Accumulation mode not supported with FP8 GEMM output!");
  }

  float one = 1.0;
  float zero = 0.0;
  float beta = (accumulate) ? one : zero;

  float alpha = 1.0;
  if (use_fp8) {
     float A_scale_inv, B_scale_inv;
     hipMemcpy(&A_scale_inv, A_scale_inverse, sizeof(float), hipMemcpyDeviceToHost);
     hipMemcpy(&B_scale_inv, B_scale_inverse, sizeof(float), hipMemcpyDeviceToHost);
     alpha = A_scale_inv * B_scale_inv;
  }

  rocblas_handle handle;
  NVTE_CHECK_CUBLAS(rocblas_create_handle(&handle));

  int64_t ld_gelumat = (int64_t) ldd;


  NVTE_CHECK((A_type==rocblas_datatype_f16_r && B_type==rocblas_datatype_f16_r && D_type==rocblas_datatype_f16_r) || 
       (A_type==rocblas_datatype_f32_r && B_type==rocblas_datatype_f32_r && D_type==rocblas_datatype_f32_r) ||
       (A_type==rocblas_datatype_f8_r && B_type==rocblas_datatype_f8_r && D_type==rocblas_datatype_f32_r) ||
       (A_type==rocblas_datatype_f8_r && B_type==rocblas_datatype_f8_r && D_type==rocblas_datatype_f16_r) ||
       (A_type==rocblas_datatype_f8_r && B_type==rocblas_datatype_bf8_r && D_type==rocblas_datatype_f32_r) ||
       (A_type==rocblas_datatype_f8_r && B_type==rocblas_datatype_bf8_r && D_type==rocblas_datatype_f16_r) ||
       (A_type==rocblas_datatype_bf8_r && B_type==rocblas_datatype_f8_r && D_type==rocblas_datatype_f32_r) ||
       (A_type==rocblas_datatype_bf8_r && B_type==rocblas_datatype_f8_r && D_type==rocblas_datatype_f16_r),
       /*
       (A_type==rocblas_datatype_f8_r && B_type==rocblas_datatype_f8_r && D_type==rocblas_datatype_f8_r) ||
       (A_type==rocblas_datatype_f8_r && B_type==rocblas_datatype_bf8_r && D_type==rocblas_datatype_bf8_r) ||
       (A_type==rocblas_datatype_bf8_r && B_type==rocblas_datatype_f8_r && D_type==rocblas_datatype_bf8_r),
       */
       //Currently does not support output of fp8 tensors
      "Only the following combinations of data types are enabled now!\n 1. input: fp16, output: fp16.\n \
      2. input: fp32, output: fp32.\n 3. input: fp8, output: fp16, fp32");


  //If D is not fp32, then we need a temp buffer for GEMM result before applying epilogues. Otherwise, we can apply epilogues in-place.
  void* D_temp;
  if ((bias || gelu) && (D_type==rocblas_datatype_f16_r || D_type==rocblas_datatype_f8_r || D_type==rocblas_datatype_bf8_r)) {
    NVTE_CHECK_CUDA( hipMalloc(&D_temp, sizeof(float)*m*n) );
  }else {
    D_temp = D;
  }

  // When Ti=To=fp16 and there is no bias or gelu, D_temp points to D and we would like it to be fp16
  rocblas_datatype D_temp_type = rocblas_datatype_f32_r;
  if (!(bias || gelu) && (A_type==rocblas_datatype_f16_r && B_type==rocblas_datatype_f16_r && D_type==rocblas_datatype_f16_r)) {
    D_temp_type = rocblas_datatype_f16_r;
  }
  // When Ti in fp8 or bf8, To=fp16, there is no bias or gelu, D_temp points to D and we would like it to be fp16
  if ((!(bias||gelu))&& ((A_type==rocblas_datatype_f8_r or A_type==rocblas_datatype_bf8_r) && (B_type==rocblas_datatype_f8_r or B_type==rocblas_datatype_bf8_r)&& D_type==rocblas_datatype_f16_r)) {
    D_temp_type = rocblas_datatype_f16_r;
  }

  // D = alpha * (A * B) + beta * C
  // TODO: Can we search for rocblas_gemm_algo??
  if (use_fp8) {
    rocblas_computetype computeType = rocblas_compute_type_f32;
    NVTE_CHECK_CUBLAS(rocblas_gemm_ex3(handle, transa, transb, m, n, k, &alpha,
                                       A, A_type, lda,
                                       B, B_type, ldb,
                                       &beta, D_temp, D_temp_type, ldd, D_temp, D_temp_type, ldd,
                                       computeType, rocblas_gemm_algo::rocblas_gemm_algo_standard,0,0));
  }else {
    rocblas_datatype computeType = rocblas_datatype_f32_r;
    NVTE_CHECK_CUBLAS(rocblas_gemm_ex(handle, transa, transb, m, n, k, &alpha,
                                      A, A_type, lda,
                                      B, B_type, ldb,
                                      &beta, D_temp, D_temp_type, ldd, D_temp, D_temp_type, ldd,
                                      computeType, rocblas_gemm_algo::rocblas_gemm_algo_standard,0,0));
  }

  NVTE_CHECK_CUBLAS(rocblas_destroy_handle(handle));

  int batch_size, input_dim, output_dim;
  if (bias && gelu) {
    if (grad) {
      // epilogue = CUBLASLT_EPILOGUE_DGELU_BGRAD;
      // Apply GELU gradient to D_temp and store in D 
      // Apply bias gradient to D (D is already the result of GELU gradient) and store in bias_ptr; 
      // This case is NN
      // D_temp is of shape is (m, n) in column major and thus is of shape (n, m) in row major
      // The bias vector length is m. So it will be reduced along axis 0 in row major
      // (TODO): The cublasLt doc is not very clear wrt the bias gradient here.
      // It does not explicitly say that it goes through GELU gradient first. We will need to
      // confirm in the future. As of now, my implementation for the bias gradient takes
      // the GELU gradient result in lower precision (D). It might be better to take the GELU
      // gradient result in fp32 but as it requires some kernel changes I would only do that
      // once we confirm that this is the right form of the epilogue.
      // This is for linear1 -> gelu -> linear2 
      // compute dX = dY * W for linear2
      // gemm_ex(A=W, B=dY)
      batch_size = n;
      input_dim = m; // input dimension of the second linear layer is the output dimension of the first linear layer
      output_dim = k;
      DType input_dtype = get_transformer_engine_dtype(rocblas_datatype_f32_r);
      DType output_dtype = get_transformer_engine_dtype(D_type);
      DType bias_dtype = get_transformer_engine_dtype(bias_type);
      TRANSFORMER_ENGINE_TYPE_SWITCH_ROCM_SIM(input_dtype, IType,
        TRANSFORMER_ENGINE_TYPE_SWITCH_ROCM_SIM(output_dtype, OType, 
          detail::gelu_backward_kernelLauncher<IType, OType>(reinterpret_cast<const IType*>(D_temp), 
                                                             reinterpret_cast<OType*>(D), 
                                                             reinterpret_cast<const OType*>(pre_gelu_out), 
                                                             batch_size, 
                                                             input_dim,
                                                             0);
        );  
      ); 

      void* bias_tmp;
      if (bias_type != rocblas_datatype_f32_r) {
        NVTE_CHECK_CUDA( hipMalloc(&bias_tmp, sizeof(float)*input_dim) ); // The bias gradient is for the first linear layer
      }else {
        bias_tmp = bias_ptr;
      }

      TRANSFORMER_ENGINE_TYPE_SWITCH_ROCM_SIM(output_dtype, OType,
        detail::bias_gradient_kernelLauncher<OType>(reinterpret_cast<const OType*>(D), 
                                                    reinterpret_cast<float*>(bias_tmp), 
                                                    batch_size, 
                                                    input_dim,
                                                    0);
      );

      if (bias_type != rocblas_datatype_f32_r) {
        TRANSFORMER_ENGINE_TYPE_SWITCH_ROCM_SIM(bias_dtype, OType,
          detail::identity_kernelLauncher<float, OType>(reinterpret_cast<const float*>(bias_tmp), 
                                                        reinterpret_cast<OType*>(bias_ptr),
                                                        input_dim,
                                                        0);
        );  
        NVTE_CHECK_CUDA( hipDeviceSynchronize() );
        NVTE_CHECK_CUDA( hipFree(bias_tmp) ); 
      }

    } else {
      // epilogue = CUBLASLT_EPILOGUE_GELU_AUX_BIAS;
      // Add bias_ptr to D_temp and store in pre_gelu_out, and apply GELU to the pre_gelu_output and then store in D
      // D_temp is of shape is (m, n) in column major and thus is of shape (n, m) in row major
      // gemm_ex(A=W, B=X, transA=T)
      batch_size = n;
      input_dim = k;
      output_dim = m;
      DType input_dtype = get_transformer_engine_dtype(rocblas_datatype_f32_r);
      DType output_dtype = get_transformer_engine_dtype(D_type);
      DType bias_dtype = get_transformer_engine_dtype(bias_type);
      TRANSFORMER_ENGINE_TYPE_SWITCH_ROCM_SIM(input_dtype, IType,
        TRANSFORMER_ENGINE_TYPE_SWITCH_ROCM_SIM(output_dtype, OType,
          TRANSFORMER_ENGINE_TYPE_SWITCH_ROCM_SIM(bias_dtype, BType,
            detail::add_bias_gelu_kernelLauncher<IType, OType>(reinterpret_cast<const IType*>(D_temp), 
                                                               reinterpret_cast<OType*>(D), 
                                                               reinterpret_cast<OType*>(pre_gelu_out), 
                                                               reinterpret_cast<const BType*>(bias_ptr), 
                                                               batch_size, 
                                                               output_dim,
                                                               0);
          );
        );
      );
    }
  }else if (bias) {
    if (grad) {
      // grad output is always input B
      // epilogue = CUBLASLT_EPILOGUE_BGRADB;
      // Apply bias gradient to matrix B and store in bias_ptr, reduce along the k dimension, output bias length is n
      // As B is transposed, is of shape (n, k) in column major, and is of shape (k, n) in row major.
      // bias gradient vector length is n. So it will be reduced along axis 0 in row major.
      // The backward pass calculate the bias gradient along with dW = dY^T * X
      // gemm_ex(A=X, B = dY, transB=T)
      batch_size = k;
      input_dim = m;
      output_dim = n;
      void * bias_tmp;
      if (bias_type != rocblas_datatype_f32_r) {
        NVTE_CHECK_CUDA( hipMalloc(&bias_tmp, sizeof(float)*output_dim) );
      }else {
        bias_tmp = bias_ptr;
      }

      DType input_dtype = get_transformer_engine_dtype(B_type);
      DType output_dtype = get_transformer_engine_dtype(D_type);
      DType bias_dtype = get_transformer_engine_dtype(bias_type);
      TRANSFORMER_ENGINE_TYPE_SWITCH_ROCM_SIM(input_dtype, IType,
        detail::bias_gradient_kernelLauncher<IType>(reinterpret_cast<const IType*>(B), 
                                                    reinterpret_cast<float*>(bias_tmp), 
                                                    batch_size, 
                                                    output_dim,
                                                    0);
      );
      if (bias_type != rocblas_datatype_f32_r) {
        TRANSFORMER_ENGINE_TYPE_SWITCH_ROCM_SIM(bias_dtype, OType,
          detail::identity_kernelLauncher<float, OType>(reinterpret_cast<const float*>(bias_tmp), 
                                                        reinterpret_cast<OType*>(bias_ptr),
                                                        output_dim,
                                                        0);
        );  
        NVTE_CHECK_CUDA( hipDeviceSynchronize() );
        NVTE_CHECK_CUDA( hipFree(bias_tmp) ); 
      }
      if (D_type == rocblas_datatype_f16_r) {
        TRANSFORMER_ENGINE_TYPE_SWITCH_ROCM_SIM(output_dtype, OType,
          detail::identity_kernelLauncher<float, OType>(reinterpret_cast<const float*>(D_temp), 
                                                        reinterpret_cast<OType*>(D),
                                                        input_dim*output_dim,
                                                        0);
        );  
      }
    } else {
      // epilogue = CUBLASLT_EPILOGUE_BIAS;
      // Broadcast bias and add it to D_temp and store in D. The bias vector length is m 
      // D_temp is of shape is (m, n) in column major and thus is of shape (n, m) in row major
      // gemm_ex(A=W, B=X, transA=T)
      batch_size = n;
      input_dim = k;
      output_dim = m;
      DType input_dtype = get_transformer_engine_dtype(rocblas_datatype_f32_r);
      DType output_dtype = get_transformer_engine_dtype(D_type);
      DType bias_dtype = get_transformer_engine_dtype(bias_type);
      TRANSFORMER_ENGINE_TYPE_SWITCH_ROCM_SIM(input_dtype, IType,
        TRANSFORMER_ENGINE_TYPE_SWITCH_ROCM_SIM(output_dtype, OType,
          TRANSFORMER_ENGINE_TYPE_SWITCH_ROCM_SIM(bias_dtype, BType,
            detail::add_bias_kernelLauncher<IType, OType, BType>(reinterpret_cast<const IType*>(D_temp), 
                                                                 reinterpret_cast<OType*>(D), 
                                                                 reinterpret_cast<const BType*>(bias_ptr), 
                                                                 batch_size, 
                                                                 output_dim,
                                                                 0);
          );
        );
      );
    }
  }else if (gelu) {
    if (grad) {
      // epilogue = CUBLASLT_EPILOGUE_DGELU;
      // Take input from pre_gelu_out and apply GELU gradients to D_temp and store result in D
      // D_temp is of shape is (m, n) in column major and thus is of shape (n, m) in row major
      // gemm_ex(A=W, B=dY) 
      batch_size = n;
      input_dim = m;
      output_dim = k;
      DType input_dtype = get_transformer_engine_dtype(rocblas_datatype_f32_r);
      DType output_dtype = get_transformer_engine_dtype(D_type);
      TRANSFORMER_ENGINE_TYPE_SWITCH_ROCM_SIM(input_dtype, IType,
        TRANSFORMER_ENGINE_TYPE_SWITCH_ROCM_SIM(output_dtype, OType,
          detail::gelu_backward_kernelLauncher<IType, OType>(reinterpret_cast<const IType*>(D_temp), 
                                                             reinterpret_cast<OType*>(D), 
                                                             reinterpret_cast<const OType*>(pre_gelu_out), 
                                                             batch_size, 
                                                             input_dim,
                                                             0);
        );  
      ); 
    } else {
      // epilogue = CUBLASLT_EPILOGUE_GELU_AUX;
      // Store (quantized) D_temp in pre_gelu_out, and apply GELU to D_temp then store in D
      // D_temp is of shape is (m, n) in column major and thus is of shape (n, m) in row major
      // gemm_ex(A=W, B=X, transA=T)
      batch_size = n;
      input_dim = k;
      output_dim = m;
      DType input_dtype = get_transformer_engine_dtype(rocblas_datatype_f32_r);
      DType output_dtype = get_transformer_engine_dtype(D_type);
      TRANSFORMER_ENGINE_TYPE_SWITCH_ROCM_SIM(input_dtype, IType,
        TRANSFORMER_ENGINE_TYPE_SWITCH_ROCM_SIM(output_dtype, OType,
          detail::gelu_forward_kernelLauncher<IType, OType>(reinterpret_cast<const IType*>(D_temp), 
                                                            reinterpret_cast<OType*>(D), 
                                                            batch_size,
                                                            output_dim, 
                                                            0);
        );  
      ); 
      TRANSFORMER_ENGINE_TYPE_SWITCH_ROCM_SIM(input_dtype, IType,
        TRANSFORMER_ENGINE_TYPE_SWITCH_ROCM_SIM(output_dtype, OType,
          detail::identity_kernelLauncher<IType, OType>(reinterpret_cast<const IType*>(D_temp), 
                                                        reinterpret_cast<OType*>(pre_gelu_out), 
                                                        batch_size*output_dim, 
                                                        0);
        );  
      ); 
    }
  }
  if ((bias || gelu) && (D_type==rocblas_datatype_f16_r || D_type==rocblas_datatype_f8_r || D_type==rocblas_datatype_bf8_r)) {
    NVTE_CHECK_CUDA( hipFree(D_temp) );
  }
}

#endif // #ifdef USE_HIPBLASLT
#else // Use cublasLt
void cublas_gemm(const Tensor *inputA,
                 const Tensor *inputB,
                 Tensor *outputD,
                 const Tensor *inputBias,
                 Tensor *outputPreGelu,
                 int m, int n, int k,
                 int lda, int ldb, int ldd,
                 cublasOperation_t transa,
                 cublasOperation_t transb,
                 bool grad,
                 void* workspace,
                 size_t workspaceSize,
                 bool accumulate,
                 bool use_split_accumulator,
                 int math_sm_count,
                 cudaStream_t stream
) {
  void *A = inputA->data.dptr;
  void *A_scale_inverse = inputA->scale_inv.dptr;
  void *B = inputB->data.dptr;
  void *B_scale_inverse = inputB->scale_inv.dptr;
  void *C = outputD->data.dptr;
  void *D = outputD->data.dptr;
  void *D_scale = outputD->scale.dptr;
  void *D_amax = outputD->amax.dptr;
  void *bias_ptr = inputBias->data.dptr;
  const bool bias = bias_ptr != nullptr;
  void *pre_gelu_out = outputPreGelu->data.dptr;
  const bool gelu = pre_gelu_out != nullptr;
  const bool use_fp8 = is_fp8_dtype(inputA->data.dtype) ||
                       is_fp8_dtype(inputB->data.dtype);
  const cudaDataType_t A_type = get_cuda_dtype(inputA->data.dtype);
  const cudaDataType_t B_type = get_cuda_dtype(inputB->data.dtype);
  const cudaDataType_t D_type = get_cuda_dtype(outputD->data.dtype);
  const cudaDataType_t bias_type = get_cuda_dtype(inputBias->data.dtype);

  NVTE_CHECK(!is_fp8_dtype(inputA->data.dtype) || A_scale_inverse != nullptr,
             "FP8 input to GEMM requires inverse of scale!");
  NVTE_CHECK(!is_fp8_dtype(inputB->data.dtype) || B_scale_inverse != nullptr,
             "FP8 input to GEMM requires inverse of scale!");

  // check consistency of arguments:
  // if fp8 is desired, context cannot be null
  // fp8 + gelu fusion + fp8 aux is unavailable right now.
  if (use_fp8 && gelu) {
    NVTE_CHECK(!is_fp8_dtype(outputPreGelu->data.dtype),
             "fp8 Aux output for gemm + gelu fusion not supported!");
  }
  if (is_fp8_dtype(outputD->data.dtype)) {
    NVTE_CHECK(!accumulate,
             "Accumulation mode not supported with FP8 GEMM output!");
  }

  float one = 1.0;
  float zero = 0.0;
  float beta = (accumulate) ? one : zero;

  cublasLtHandle_t handle;
  NVTE_CHECK_CUBLAS(cublasLtCreate(&handle));

  cublasLtMatmulDesc_t       operationDesc = nullptr;
  cublasLtMatrixLayout_t     Adesc = nullptr, Bdesc = nullptr, Cdesc = nullptr, Ddesc = nullptr;
  cublasLtMatmulPreference_t preference = nullptr;
  int                             returnedResults = 0;
  cublasLtMatmulHeuristicResult_t heuristicResult = {};
  cublasLtEpilogue_t epilogue = CUBLASLT_EPILOGUE_DEFAULT;

  int64_t ld_gelumat = (int64_t) ldd;

  // Use TF32 only for pure FP32 GEMM.
  cublasComputeType_t gemm_compute_type = CUBLAS_COMPUTE_32F;
  if (A_type == CUDA_R_32F && B_type == CUDA_R_32F && D_type == CUDA_R_32F) {
    gemm_compute_type = CUBLAS_COMPUTE_32F_FAST_TF32;
  }

  // Create matrix descriptors. Not setting any extra attributes.
  NVTE_CHECK_CUBLAS(cublasLtMatrixLayoutCreate(&Adesc, A_type,
                                               transa == CUBLAS_OP_N ? m : k,
                                               transa == CUBLAS_OP_N ? k : m,
                                               lda));
  NVTE_CHECK_CUBLAS(cublasLtMatrixLayoutCreate(&Bdesc, B_type,
                                               transb == CUBLAS_OP_N ? k : n,
                                               transb == CUBLAS_OP_N ? n : k,
                                               ldb));
  NVTE_CHECK_CUBLAS(cublasLtMatrixLayoutCreate(&Ddesc, D_type, m, n, ldd));

  NVTE_CHECK_CUBLAS(cublasLtMatmulDescCreate(&operationDesc, gemm_compute_type, CUDA_R_32F));
  NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc, CUBLASLT_MATMUL_DESC_TRANSA,
                                                   &transa, sizeof(transa)));
  NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc, CUBLASLT_MATMUL_DESC_TRANSB,
                                                   &transb, sizeof(transb)));
  // Set math SM count
  if (math_sm_count != 0) {
      NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(
          operationDesc, CUBLASLT_MATMUL_DESC_SM_COUNT_TARGET,
          &math_sm_count, sizeof(math_sm_count)));
  }


  // set fp8 attributes -- input and output types should already be set to fp8 as appropriate
  // Note: gelu fusion isn't available right now, and we don't need
  // amax(D) either (next op is high precision).
  if (use_fp8) {
    // Split accumulator.
    const int8_t fastAccuMode = (use_split_accumulator) ? 0 : 1;
    NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                     CUBLASLT_MATMUL_DESC_FAST_ACCUM,
                                                     &fastAccuMode,
                                                     sizeof(fastAccuMode)));
    NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                     CUBLASLT_MATMUL_DESC_A_SCALE_POINTER,
                                                     &A_scale_inverse,
                                                     sizeof(A_scale_inverse)));
    NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                     CUBLASLT_MATMUL_DESC_B_SCALE_POINTER,
                                                     &B_scale_inverse,
                                                     sizeof(B_scale_inverse)));
    if (is_fp8_dtype(outputD->data.dtype)) {
      // Accumulation mode not supported for FP8 output
      C = nullptr;
      NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                       CUBLASLT_MATMUL_DESC_D_SCALE_POINTER,
                                                       &D_scale,
                                                       sizeof(D_scale)));
      NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                       CUBLASLT_MATMUL_DESC_AMAX_D_POINTER,
                                                       &D_amax,
                                                       sizeof(D_amax)));
      // For FP8 output, cuBLAS requires C_type to be same as bias_type
      NVTE_CHECK_CUBLAS(cublasLtMatrixLayoutCreate(&Cdesc, bias_type, m, n, ldd));
    } else {
      NVTE_CHECK_CUBLAS(cublasLtMatrixLayoutCreate(&Cdesc, D_type, m, n, ldd));
    }
    if (bias) {
      NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                       CUBLASLT_MATMUL_DESC_BIAS_DATA_TYPE,
                                                       &bias_type, sizeof(bias_type)));
    }
  } else {
    NVTE_CHECK_CUBLAS(cublasLtMatrixLayoutCreate(&Cdesc, D_type, m, n, ldd));
  }

  if (bias && gelu) {
    if (grad) {
      epilogue = CUBLASLT_EPILOGUE_DGELU_BGRAD;
    } else {
      epilogue = CUBLASLT_EPILOGUE_GELU_AUX_BIAS;
    }
    NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                     CUBLASLT_MATMUL_DESC_BIAS_POINTER,
                                                     &bias_ptr, sizeof(bias_ptr)));
    NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(
            operationDesc, CUBLASLT_MATMUL_DESC_EPILOGUE_AUX_POINTER,
            &pre_gelu_out, sizeof(pre_gelu_out)));
    NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                     CUBLASLT_MATMUL_DESC_EPILOGUE_AUX_LD,
                                                     &ld_gelumat, sizeof(ld_gelumat)));
    const cudaDataType_t aux_type = get_cuda_dtype(outputPreGelu->data.dtype);
    NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                     CUBLASLT_MATMUL_DESC_EPILOGUE_AUX_DATA_TYPE,
                                                     &aux_type, sizeof(aux_type)));
  } else if (bias) {
    if (grad) {
      // grad output is always input B
      epilogue = CUBLASLT_EPILOGUE_BGRADB;
    } else {
      epilogue = CUBLASLT_EPILOGUE_BIAS;
    }
    NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                     CUBLASLT_MATMUL_DESC_BIAS_POINTER,
                                                     &bias_ptr, sizeof(bias_ptr)));
  } else if (gelu) {
    if (grad) {
      epilogue = CUBLASLT_EPILOGUE_DGELU;
    } else {
      epilogue = CUBLASLT_EPILOGUE_GELU_AUX;
    }
    NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(
            operationDesc, CUBLASLT_MATMUL_DESC_EPILOGUE_AUX_POINTER,
            &pre_gelu_out, sizeof(pre_gelu_out)));
    NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                     CUBLASLT_MATMUL_DESC_EPILOGUE_AUX_LD,
                                                     &ld_gelumat, sizeof(ld_gelumat)));
  }

  NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                   CUBLASLT_MATMUL_DESC_EPILOGUE,
                                                   &epilogue, sizeof(epilogue)));

  NVTE_CHECK_CUBLAS(cublasLtMatmulPreferenceCreate(&preference));
  NVTE_CHECK_CUBLAS(cublasLtMatmulPreferenceSetAttribute(
          preference, CUBLASLT_MATMUL_PREF_MAX_WORKSPACE_BYTES,
          &workspaceSize, sizeof(workspaceSize)));

  NVTE_CHECK_CUBLAS(cublasLtMatmulAlgoGetHeuristic(handle, operationDesc, Adesc, Bdesc, Cdesc,
                                                   Ddesc, preference, 1, &heuristicResult,
                                                   &returnedResults));

  if (returnedResults == 0) throw std::runtime_error("Unable to find any suitable algorithms");

  // D = alpha * (A * B) + beta * C

  NVTE_CHECK_CUBLAS(cublasLtMatmul(handle,
                                   operationDesc,
                                   static_cast<const void*>(&one),         /* alpha */
                                   A,                                      /* A */
                                   Adesc,
                                   B,                                      /* B */
                                   Bdesc,
                                   static_cast<const void*>(&beta),        /* beta */
                                   C,                                      /* C */
                                   Cdesc,
                                   D,                                      /* D */
                                   Ddesc,
                                   &heuristicResult.algo,                  /* algo */
                                   workspace,                              /* workspace */
                                   workspaceSize,
                                   stream));                               /* stream */


  NVTE_CHECK_CUBLAS(cublasLtMatmulPreferenceDestroy(preference));
  NVTE_CHECK_CUBLAS(cublasLtMatrixLayoutDestroy(Ddesc));
  NVTE_CHECK_CUBLAS(cublasLtMatrixLayoutDestroy(Cdesc));
  NVTE_CHECK_CUBLAS(cublasLtMatrixLayoutDestroy(Bdesc));
  NVTE_CHECK_CUBLAS(cublasLtMatrixLayoutDestroy(Adesc));
  NVTE_CHECK_CUBLAS(cublasLtMatmulDescDestroy(operationDesc));
}
#endif //#ifdef __HIP_PLATFORM_HCC__

}  // namespace transformer_engine

void nvte_cublas_gemm(const NVTETensor A,
                      const NVTETensor B,
                      NVTETensor D,
                      const NVTETensor bias,
                      NVTETensor pre_gelu_out,
                      bool transa,
                      bool transb,
                      bool grad,
                      NVTETensor workspace,
                      bool accumulate,
                      bool use_split_accumulator,
                      int math_sm_count,
                      cudaStream_t stream) {
#ifndef __HIP_PLATFORM_HCC__
  NVTE_API_CALL(nvte_cublas_gemm);
#endif //#ifndef __HIP_PLATFORM_HCC__
  using namespace transformer_engine;
  const Tensor *inputA = reinterpret_cast<const Tensor*>(A);
  const Tensor *inputB = reinterpret_cast<const Tensor*>(B);
  Tensor *outputD = reinterpret_cast<Tensor*>(D);
  const Tensor *biasTensor = reinterpret_cast<const Tensor*>(bias);
  Tensor *outputGelu = reinterpret_cast<Tensor*>(pre_gelu_out);
  Tensor *wspace = reinterpret_cast<Tensor*>(workspace);

  const int m = transa ? inputA->data.shape[0] : inputA->data.shape[1];
  const int k = transa ? inputA->data.shape[1] : inputA->data.shape[0];
  const int n = transb ? inputB->data.shape[1] : inputB->data.shape[0];
  int lda, ldb, ldd;
  if (transa && !transb) {  // TN
    lda = k;
    ldb = k;
    ldd = m;
  } else if (!transa && !transb) {  // NN
    lda = m;
    ldb = k;
    ldd = m;
  } else if (!transa && transb) {  // NT
    lda = m;
    ldb = n;
    ldd = m;
  } else {  // TT
    NVTE_ERROR("TT layout not allowed.");
  }

  bool nvte_log_gemm_config = false;
  if (const char* env_p = std::getenv("NVTE_LOG_GEMM_CONFIG") ) {
    if (env_p != nullptr && std::string(env_p) == "1")
      nvte_log_gemm_config = true;
  }

  if (nvte_log_gemm_config) {
    float A_scale_inv, B_scale_inv;
    hipMemcpy(&A_scale_inv, inputA->scale_inv.dptr, sizeof(float), hipMemcpyDeviceToHost);
    hipMemcpy(&B_scale_inv, inputB->scale_inv.dptr, sizeof(float), hipMemcpyDeviceToHost);
    std::cout << "m=" << m << " k=" << k << " n=" << n 
        << " transa=" << (transa?"T":"N")
        << " transb=" << (transb?"T":"N")
        << " A_type=" << (int)inputA->data.dtype
        << " B_type=" << (int)inputB->data.dtype
        << " D_type=" << (int)outputD->data.dtype
        << " bias_type=" << (int)biasTensor->data.dtype
        << " grad=" << grad
        << " bias=" << (biasTensor->data.dptr != nullptr)
        << " gelu=" << (outputGelu->data.dptr != nullptr)
        << " use_fp8=" << ( is_fp8_dtype(inputA->data.dtype) || is_fp8_dtype(inputB->data.dtype) )
        << " A_scale_inverse = " <<  A_scale_inv
        << " B_scale_inverse = " <<  B_scale_inv
        << " accumulate=" << accumulate
        << std::endl;
  }
#ifdef USE_HIPBLASLT
  cublas_gemm(inputA,
              inputB,
              outputD, 
              biasTensor,
              outputGelu,
              m, n, k,
              lda, ldb, ldd,
              (transa) ? HIPBLAS_OP_T : HIPBLAS_OP_N,
              (transb) ? HIPBLAS_OP_T : HIPBLAS_OP_N,
              grad, wspace->data.dptr,
              wspace->data.shape[0],
              accumulate, use_split_accumulator,
              math_sm_count,
              stream);
#else
  cublas_gemm(inputA,
              inputB,
              outputD,
              biasTensor,
              outputGelu,
              m, n, k,
              lda, ldb, ldd,
              (transa) ? CUBLAS_OP_T : CUBLAS_OP_N,
              (transb) ? CUBLAS_OP_T : CUBLAS_OP_N,
              grad, wspace->data.dptr,
              wspace->data.shape[0],
              accumulate, use_split_accumulator,
              math_sm_count,
              stream);
#endif
}

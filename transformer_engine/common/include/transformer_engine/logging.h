/*************************************************************************
 * Copyright (c) 2022-2023, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 *                    2023 Advanced Micro Devices, Inc. All rights reserved.
 *
 * See LICENSE for license information.
 ************************************************************************/

#ifndef TRANSFORMER_ENGINE_LOGGING_H_
#define TRANSFORMER_ENGINE_LOGGING_H_

#include <cuda_runtime_api.h>
#ifdef __HIP_PLATFORM_HCC__
#define ROCBLAS_BETA_FEATURES_API
#include <rocblas/rocblas.h>
#ifdef USE_HIPBLASLT
#include <hipblaslt/hipblaslt.h>
#endif // #ifdef USE_HIPBLASLT
#include <hip/hiprtc.h>
#else
#include <cublas_v2.h>
#include <cudnn.h>
#include <nvrtc.h>
#endif //#ifdef __HIP_PLATFORM_HCC__
#include <string>
#include <stdexcept>

#define NVTE_ERROR(x) \
    do { \
        throw std::runtime_error(std::string(__FILE__ ":") + std::to_string(__LINE__) +            \
                                 " in function " + __func__ + ": " + x);                           \
    } while (false)

#define NVTE_CHECK(x, ...)                                                                         \
    do {                                                                                           \
        if (!(x)) {                                                                                \
            NVTE_ERROR(std::string("Assertion failed: "  #x ". ") + std::string(__VA_ARGS__));     \
        }                                                                                          \
    } while (false)

namespace {

inline void check_cuda_(cudaError_t status) {
    if ( status != cudaSuccess ) {
        NVTE_ERROR("CUDA Error: " + std::string(cudaGetErrorString(status)));
    }
}

#ifdef __HIP_PLATFORM_HCC__
#ifdef USE_HIPBLASLT
inline void check_cublas_(hipblasStatus_t status) {
    if ( status != HIPBLAS_STATUS_SUCCESS ) {
        NVTE_ERROR("HIPBLASLT Error: " + std::to_string((int)status) );
    }
}
#else
inline void check_cublas_(cublasStatus_t status) {
    if ( status != rocblas_status_success ) {
        NVTE_ERROR("ROCBLAS Error: " + std::string(rocblas_status_to_string(status)));
    }
}
#endif
#else
inline void check_cublas_(cublasStatus_t status) {
    if ( status != CUBLAS_STATUS_SUCCESS ) {
        NVTE_ERROR("CUBLAS Error: " + std::string(cublasGetStatusString(status)));
    }
}
#endif

#ifndef __HIP_PLATFORM_HCC__
inline void check_cudnn_(cudnnStatus_t status) {
    if ( status != CUDNN_STATUS_SUCCESS ) {
        std::string message;
        message.reserve(1024);
        message += "CUDNN Error: ";
        message += cudnnGetErrorString(status);
        message += (". "
                    "For more information, enable cuDNN error logging "
                    "by setting CUDNN_LOGERR_DBG=1 and "
                    "CUDNN_LOGDEST_DBG=stderr in the environment.");
        NVTE_ERROR(message);
    }
}
#endif // __HIP_PLATFORM_HCC__

inline void check_nvrtc_(nvrtcResult status) {
    if ( status != NVRTC_SUCCESS ) {
        NVTE_ERROR("NVRTC Error: " + std::string(nvrtcGetErrorString(status)));
    }
}
//TODO: check_miopen

}  // namespace

#define NVTE_CHECK_CUDA(ans) { check_cuda_(ans); }

#define NVTE_CHECK_CUBLAS(ans) { check_cublas_(ans); }

#ifndef __HIP_PLATFORM_HCC__
#define NVTE_CHECK_CUDNN(ans) { check_cudnn_(ans); }
#endif // __HIP_PLATFORM_HCC__

#define NVTE_CHECK_NVRTC(ans) { check_nvrtc_(ans); }

#endif  // TRANSFORMER_ENGINE_LOGGING_H_

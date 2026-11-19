#!/bin/bash
# This file is part of the OpenMV project.
#
# Copyright (C) 2026 OpenMV, LLC.
#
# This work is licensed under the MIT license, see the file LICENSE for details.

# Install ARM GCC.
########################################################################################
ET_REPO_PATH=executorch
ET_SUBMODULES="third-party/json third-party/gflags third-party/flatbuffers third-party/flatcc backends/xnnpack/third-party/FXdiv"
CMSIS_NN_VERSION=v8.0.0
ETHOSU_DRIVER_URL="https://gitlab.arm.com/artificial-intelligence/ethos-u/ethos-u-core-driver.git"
ETHOSU_DRIVER_TAG=26.08
ETHOS_SDK_PATH=ethos-u-sdk
ETHOSU_DRIVER_PATH=${ETHOS_SDK_PATH}/core_software/core_driver
TOOLCHAIN_PATH=${HOME}/cache/gcc
export PATH=${TOOLCHAIN_PATH}/bin:${PATH}
TOOLCHAIN_URL="https://developer.arm.com/-/media/Files/downloads/gnu/14.3.rel1/binrel/arm-gnu-toolchain-14.3.rel1-x86_64-arm-none-eabi.tar.xz"

# Operators registered in the firmware. Models are loaded at runtime, so this is a
# fixed superset. A model using an operator not listed here fails to load with
# OperatorMissing. Float layers (convolution, linear, pooling) are left out since
# models are expected to be quantized; mean is lowered to avg_pool2d by the Cortex-M
# passes; sum and topk are left out for size.
TORCH_OPS=(
    # Cortex-M (CMSIS-NN) quantized operators.
    cortex_m::quantize_per_tensor.out
    cortex_m::dequantize_per_tensor.out
    cortex_m::quantized_add.out
    cortex_m::quantized_mul.out
    cortex_m::quantized_div.out
    cortex_m::quantized_activation.out
    cortex_m::minimum.out
    cortex_m::maximum.out
    cortex_m::quantized_linear.out
    cortex_m::softmax.out
    cortex_m::transpose.out
    cortex_m::pad.out
    cortex_m::quantized_conv2d.out
    cortex_m::quantized_conv2d_nhwc.out
    cortex_m::quantized_depthwise_conv2d.out
    cortex_m::quantized_depthwise_conv2d_nhwc.out
    cortex_m::quantized_transpose_conv2d.out
    cortex_m::quantized_transpose_conv2d_nhwc.out
    cortex_m::quantized_avg_pool2d.out
    cortex_m::quantized_avg_pool2d_nhwc.out
    cortex_m::quantized_max_pool2d.out
    cortex_m::quantized_max_pool2d_nhwc.out
    cortex_m::quantized_batch_matmul.out
    # Quantize/dequantize left on the CPU at the boundary of NPU delegated graphs
    # and of partially lowered models.
    quantized_decomposed::quantize_per_tensor.out
    quantized_decomposed::dequantize_per_tensor.out
    quantized_decomposed::quantize_per_tensor.Tensor_out
    quantized_decomposed::dequantize_per_tensor.Tensor_out
    quantized_decomposed::quantize_per_channel.out
    quantized_decomposed::dequantize_per_channel.out
    # Shape and data movement. dim_order_ops are required: the Cortex-M lowering
    # emits _clone_dim_order for channels-last models.
    aten::view_copy.out
    aten::permute_copy.out
    aten::transpose_copy.int_out
    aten::squeeze_copy.dims_out
    aten::unsqueeze_copy.out
    aten::expand_copy.out
    aten::clone.out
    aten::cat.out
    aten::slice_copy.Tensor_out
    aten::select_copy.int_out
    aten::split_with_sizes_copy.out
    aten::index_select.out
    aten::gather.out
    aten::repeat.out
    aten::flip.out
    aten::constant_pad_nd.out
    aten::pixel_shuffle.out
    aten::upsample_nearest2d.vec_out
    aten::upsample_bilinear2d.vec_out
    aten::full.out
    aten::full_like.out
    dim_order_ops::_clone_dim_order.out
    dim_order_ops::_to_dim_order_copy.out
    # Elementwise.
    aten::add.out
    aten::sub.out
    aten::mul.out
    aten::div.out
    aten::neg.out
    aten::abs.out
    aten::sqrt.out
    aten::rsqrt.out
    aten::exp.out
    aten::log.out
    aten::pow.Tensor_Scalar_out
    aten::minimum.out
    aten::maximum.out
    aten::clamp.out
    # Activations.
    aten::relu.out
    aten::hardtanh.out
    aten::leaky_relu.out
    aten::sigmoid.out
    aten::tanh.out
    aten::gelu.out
    aten::_softmax.out
    aten::_log_softmax.out
    # Reductions and post-processing.
    aten::amax.out
    aten::argmax.out
    aten::max.dim_max
)

ci_install_arm_gcc() {
    mkdir -p ${TOOLCHAIN_PATH}
    wget --no-check-certificate -O - ${TOOLCHAIN_URL} | tar --strip-components=1 -Jx -C ${TOOLCHAIN_PATH}
    export PATH=${TOOLCHAIN_PATH}/bin:${PATH}
    arm-none-eabi-gcc --version
}

# Update Submodules.
########################################################################################
ci_update_submodules() {
    git -C ${ET_REPO_PATH} submodule update --init --depth=1 ${ET_SUBMODULES}
}

# Clone the Ethos-U core driver. Only its headers are used, the driver is provided by
# the firmware. The version must match the firmware's.
########################################################################################
ci_clone_ethosu_driver() {
    git clone --depth=1 --branch ${ETHOSU_DRIVER_TAG} ${ETHOSU_DRIVER_URL} ${ETHOSU_DRIVER_PATH}
}

# Apply ExecuTorch patches.
########################################################################################
ci_apply_patches() {
    for patch in patches/*.patch; do
        git -C ${ET_REPO_PATH} apply -v ../${patch}
    done
}

# Build Targets.
########################################################################################
ci_build_target() {
    TARGET_NAME=${1}
    TARGET_CPU=${2}
    TARGET_FPU=${3}
    TARGET_NPU=${4}

    BUILD_DIR=$(pwd)/build/${TARGET_NAME}
    GEN_DIR=${BUILD_DIR}/gen
    ET_DIR=$(pwd)/${ET_REPO_PATH}
    PYTHON=${PYTHON:-python3}

    TARGET_FLAGS="-mthumb -mcpu=${TARGET_CPU} -mtune=${TARGET_CPU} -mfpu=${TARGET_FPU} -mfloat-abi=hard \
-fdata-sections -ffunction-sections -Wno-psabi"

    # The Ethos-U delegate is built against the core driver headers, with the same
    # configuration as the firmware's driver.
    NPU_ARGS="-DEXECUTORCH_BUILD_ARM_BAREMETAL=OFF"
    NPU_LIBS=""
    if [ "${TARGET_NPU}" == "ethos-u" ]; then
        TARGET_FLAGS="${TARGET_FLAGS} -DETHOSU -DETHOSU_MULTI_VARIANT"
        NPU_ARGS="-DEXECUTORCH_BUILD_ARM_BAREMETAL=ON -DETHOS_SDK_PATH=$(pwd)/${ETHOS_SDK_PATH}"
        NPU_LIBS="executorch_delegate_ethos_u"
    fi
    TARGET_CXXFLAGS="${TARGET_FLAGS} -fno-rtti -fno-exceptions -fno-unwind-tables \
-fno-use-cxa-atexit -fno-threadsafe-statics"

    # Build the runtime, the prim ops (executorch) and the kernel libraries. CMSIS-NN
    # is provided by the firmware; it is only downloaded here for its headers, and its
    # version must match the firmware's.
    # Kernel registration is generated below (manual registration), so the upstream
    # ops_lib targets, which register from static initializers, are not built.
    cmake -S ${ET_DIR} -B ${BUILD_DIR} \
        -DCMAKE_SYSTEM_NAME=Generic \
        -DCMAKE_SYSTEM_PROCESSOR=${TARGET_CPU} \
        -DCMAKE_C_COMPILER=arm-none-eabi-gcc \
        -DCMAKE_CXX_COMPILER=arm-none-eabi-g++ \
        -DCMAKE_ASM_COMPILER=arm-none-eabi-gcc \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DCMAKE_C_FLAGS="${TARGET_FLAGS}" \
        -DCMAKE_CXX_FLAGS="${TARGET_CXXFLAGS}" \
        -DCMAKE_C_FLAGS_RELEASE="-O2 -DNDEBUG" \
        -DCMAKE_CXX_FLAGS_RELEASE="-O2 -DNDEBUG" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=OFF \
        -DPYTHON_EXECUTABLE=${PYTHON} \
        -DEXECUTORCH_BUILD_PRESET_FILE=${ET_DIR}/tools/cmake/preset/arm_baremetal.cmake \
        ${NPU_ARGS} \
        -DEXECUTORCH_BUILD_PTHREADPOOL=OFF \
        -DEXECUTORCH_BUILD_CPUINFO=OFF \
        -DEXECUTORCH_BUILD_EXTENSION_RUNNER_UTIL=OFF \
        -DEXECUTORCH_BUILD_CORTEX_M=ON \
        -DEXECUTORCH_BUILD_KERNELS_QUANTIZED=ON \
        -DEXECUTORCH_ENABLE_LOGGING=OFF \
        -DEXECUTORCH_ENABLE_PROGRAM_VERIFICATION=OFF \
        -DEXECUTORCH_OPTIMIZE_SIZE=OFF \
        -DEXECUTORCH_PAL_DEFAULT=minimal \
        -DCMSIS_NN_VERSION=${CMSIS_NN_VERSION}
    cmake --build ${BUILD_DIR} -j$(nproc) --target \
        executorch_core executorch portable_kernels kernels_util_all_deps \
        quantized_kernels cortex_m_kernels ${NPU_LIBS}

    # Generate one manual registration function per kernel library. The libraries are
    # generated separately because the codegen indexes kernels by name without the
    # namespace (cortex_m:: and quantized_decomposed:: operators collide).
    rm -rf ${GEN_DIR}
    mkdir -p ${GEN_DIR}
    TORCHGEN=$(${PYTHON} -c "import torchgen, os; print(os.path.dirname(torchgen.__file__))")
    TORCH_OPS_LIST=$(IFS=,; echo "${TORCH_OPS[*]}")

    pushd ${ET_DIR}
    ${PYTHON} -m codegen.tools.gen_oplist \
        --output_path=${GEN_DIR}/selected_operators.yaml --root_ops="${TORCH_OPS_LIST}"

    for lib in portable:--functions-yaml-path=kernels/portable/functions.yaml \
               quantized:--custom-ops-yaml-path=kernels/quantized/quantized.yaml \
               cortex_m:--custom-ops-yaml-path=backends/cortex_m/ops/operators.yaml; do
        LIB_NAME=${lib%%:*}
        mkdir -p ${GEN_DIR}/${LIB_NAME}
        ${PYTHON} -m codegen.gen \
            --source-path=codegen --install-dir=${GEN_DIR}/${LIB_NAME} \
            --tags-path=${TORCHGEN}/packaged/ATen/native/tags.yaml \
            --aten-yaml-path=${TORCHGEN}/packaged/ATen/native/native_functions.yaml \
            --op-selection-yaml-path=${GEN_DIR}/selected_operators.yaml \
            --manual_registration ${lib#*:}
        sed "s/register_all_kernels()/register_${LIB_NAME}_kernels()/" \
            ${GEN_DIR}/${LIB_NAME}/RegisterKernelsEverything.cpp > ${GEN_DIR}/${LIB_NAME}/register.cpp
    done
    popd

    # Entry point called by the firmware to register all kernels and backends.
    REGISTER_NPU_DECL=""
    REGISTER_NPU_CALL=""
    if [ "${TARGET_NPU}" == "ethos-u" ]; then
        REGISTER_NPU_DECL="namespace executorch::backends::arm { executorch::runtime::Error register_ethos_u_backend(); }"
        REGISTER_NPU_CALL="if (err == Error::Ok) { err = executorch::backends::arm::register_ethos_u_backend(); }"
    fi
    cat > ${GEN_DIR}/register_all.cpp << EOF
#include <executorch/runtime/core/error.h>

using executorch::runtime::Error;

namespace torch {
namespace executor {
Error register_portable_kernels();
Error register_quantized_kernels();
Error register_cortex_m_kernels();
namespace function {
Error register_prim_ops();
} // namespace function
} // namespace executor
} // namespace torch

${REGISTER_NPU_DECL}

extern "C" int et_register_all(void) {
    static bool registered = false;
    if (registered) {
        return 0;
    }

    Error err = torch::executor::function::register_prim_ops();
    if (err == Error::Ok) {
        err = torch::executor::register_portable_kernels();
    }
    if (err == Error::Ok) {
        err = torch::executor::register_quantized_kernels();
    }
    if (err == Error::Ok) {
        err = torch::executor::register_cortex_m_kernels();
    }
    ${REGISTER_NPU_CALL}

    registered = (err == Error::Ok);
    return static_cast<int>(err);
}
EOF

    REGISTER_OBJS=""
    for src in ${GEN_DIR}/*/register.cpp ${GEN_DIR}/register_all.cpp; do
        obj=${src%.cpp}.o
        arm-none-eabi-g++ ${TARGET_CXXFLAGS} -O2 -DNDEBUG -std=gnu++17 \
            -DC10_USING_CUSTOM_GENERATED_MACROS -DET_LOG_ENABLED=0 \
            -DET_ENABLE_PROGRAM_VERIFICATION=0 -DET_ENABLE_DEPRECATED_CONSTANT_BUFFER=0 \
            -I${ET_DIR}/.. -I${ET_DIR}/runtime/core/portable_type/c10 -I${BUILD_DIR}/include \
            -I$(dirname ${src}) -c ${src} -o ${obj}
        REGISTER_OBJS="${REGISTER_OBJS} ${obj}"
    done
    arm-none-eabi-ar rcs ${GEN_DIR}/libregister.a ${REGISTER_OBJS}

    # Merge everything into a single archive.
    {
        echo "CREATE libtorch-${TARGET_NAME}.a"
        for lib in libexecutorch_core.a \
                   libexecutorch.a \
                   kernels/portable/libportable_kernels.a \
                   kernels/portable/cpu/util/libkernels_util_all_deps.a \
                   kernels/quantized/libquantized_kernels.a \
                   backends/cortex_m/libcortex_m_kernels.a \
                   gen/libregister.a; do
            echo "ADDLIB ${BUILD_DIR}/${lib}"
        done
        if [ "${TARGET_NPU}" == "ethos-u" ]; then
            echo "ADDLIB ${BUILD_DIR}/backends/arm/libexecutorch_delegate_ethos_u.a"
        fi
        echo "SAVE"
        echo "END"
    } | arm-none-eabi-ar -M
}

# Build Headers.
########################################################################################
ci_build_headers() {
    TARGET_NAME=${1}

    BUILD_DIR=$(pwd)/build/${TARGET_NAME}
    ET_DIR=$(pwd)/${ET_REPO_PATH}
    HEADERS_DIR=${TARGET_NAME}-headers

    # Runtime headers needed to load and run programs, the buffer data loader and
    # the c10 headers the runtime includes.
    mkdir -p ${HEADERS_DIR}/executorch/extension/data_loader
    rsync -a --prune-empty-dirs --exclude='test/' --include='*/' --include='*.h' --exclude='*' \
        ${ET_DIR}/runtime ${HEADERS_DIR}/executorch/
    cp ${ET_DIR}/extension/data_loader/buffer_data_loader.h ${HEADERS_DIR}/executorch/extension/data_loader/
    cp ${BUILD_DIR}/include/executorch/runtime/core/version.h ${HEADERS_DIR}/executorch/runtime/core/
    rsync -a ${ET_DIR}/runtime/core/portable_type/c10/c10 ${ET_DIR}/runtime/core/portable_type/c10/torch ${HEADERS_DIR}/
    cp ${ET_DIR}/LICENSE ${HEADERS_DIR}/
}

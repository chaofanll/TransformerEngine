#!/bin/sh
# Copyright (c) 2024, Advanced Micro Devices, Inc. All rights reserved.
#
# See LICENSE for license information.

DIR=`dirname $0`

. $DIR/_utils.sh

install_praxis() {
    git clone https://github.com/google/praxis.git && cd praxis || return $?
    git checkout $_praxis_commit || return $?
    #Remove unnecessary dependencies for testing and make sure JAX is not upgraded
    sed -i -e 's/^flax/#flax/;s/^jax /#jax /;s/^opt/#opt/;s/^tensorflow/#tensorflow/' requirements.in || return $?
    pip list | awk '/jax/ { print $1"=="$2}' >> requirements.in
    pip install . --log build.log
    rc=$?
    if [ $rc -ne 0 ]; then
        script_error "Failed to install praxis from sources"
        cat build.log
        return $rc
    fi
}

install_prerequisites() {
    _praxis_commit="3f4cbb4bcda366db"
    _typing_exttensions_ver="4.11.0"
    pip show jaxlib | grep Version | grep -q 0.4.23
    if [ $? -eq 0 ]; then
        echo "JAX lib 0.4.23 is detected"
        _praxis_commit="2ebe1cf6a3d89"
    fi

    pip show praxis >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "Pre-installed Praxis is detected"
    else
        _tmp_dir=`mktemp -d`
        _curr_dir=`pwd`
        cd "$_tmp_dir" || exit $?
        install_praxis; rc=$?
        cd "$_curr_dir"
        rm -rf $_tmp_dir
        test $rc -eq 0 || exit $rc
    fi

    pip install 'ml-dtypes>=0.2.0' 'typing_extensions>=4.11.0'
    rc=$?
    if [ $rc -ne 0 ]; then
        script_error "Failed to install test prerequisites"
        exit $rc
    fi
}

TEST_DIR=${TE_PATH}tests/jax

run() {
    check_level $1 || return
    shift
    _test_name_tag=`get_test_name_tag $1 $_fus_attn`
    check_test_filter $_test_name_tag || return
    echo "Run [$_fus_attn] $*"
    pytest -v `get_pytest_junitxml $_test_name_tag` "$TEST_DIR/$@" || test_run_error
    echo "Done [$_fus_attn] $1"
}

run_test_config() {
    echo ====== Run with Fused attention backend: $_fus_attn =====
    run 1 test_custom_call_compute.py
    run 1 test_functions.py
    run 1 test_fused_attn.py
    run 1 test_helper.py
    if [ $_fus_attn != "unfused" ]; then
        #Layer tests control Fused attn so we can only play with backend
        run 1 test_layer.py
        run 1 test_praxis_layers.py
    fi
    run 1 test_sharding.py
    run 1 test_softmax.py
}

run_test_config_mgpu() {
    echo ====== Run mGPU with Fused attention backend: $_fus_attn =====
    run 3 test_distributed_fused_attn.py
    run 3 test_distributed_layernorm.py
    run 3 test_distributed_layernorm_mlp.py
    run 3 test_distributed_softmax.py
}

# Single config mode, run it synchroniously and return result
if [ -n "$SINGLE_CONFIG" ]; then
    _fus_attn="$SINGLE_CONFIG"
    configure_fused_attn_env $_fus_attn && run_test_config
    return_run_results
    exit $?
fi

#Master script mode: prepares testing prerequisites
echo "Started with TEST_LEVEL=$TEST_LEVEL at `date`"
install_prerequisites
check_test_jobs_requested
test $? -eq 0 && init_test_jobs `python -c "import jax; print(len([d for d in jax.devices() if 'rocm' in d.client.platform_version]))"`

for _fus_attn in auto ck aotriton unfused; do
    configure_fused_attn_env $_fus_attn || continue

    #On basic (1) level tests are run with ck/aotriton/unfused
    #On full (3) level they are run with auto/aotriton/unfused
    if [ $TEST_LEVEL -ge 3 ]; then
        test $_fus_attn = "ck" && continue
    else
        test $_fus_attn = "auto" && continue
    fi

    if [ -n "$TEST_JOBS_MODE" ]; then
        run_test_job "$_fus_attn"
    else
        run_test_config
        run_test_config_mgpu
    fi
done

if [ -n "$TEST_JOBS_MODE" ]; then
    finish_test_jobs
    for _fus_attn in $(get_test_config_list); do
        configure_fused_attn_env $_fus_attn && run_test_config_mgpu
    done
fi
return_run_results

#!/bin/bash

set -euo pipefail

make -C ../host bench_throughput.exe
cp ../host/bench_throughput.exe ./

# xsim requires xrt.ini requires absolute directory for pre-run tcl scripts.
sed -e "s#CURRENT_DIRECTORY#$PWD#g" xrt.template.ini >xrt.ini

# Performs [num_rounds * 8] evaluations concurrently.
./bench_throughput.exe \
    --xclbin ../fpga/ntt-2_24/build/build_dir.hw.xilinx_u55n_gen3x4_xdma_2_202110_1/ntt_fpga.xclbin \
    --num-rounds 10 \
    --core-type NTT-2_24

#!/bin/bash

set -x

../../../libs/vitis_infrastructure/scripts/run_build.py \
	--top-level-name msm_pippenger \
	--platform aws \
	--build-dir build \
	--build-target hw_emu \
	--cfg msm_pippenger.cfg \
	krnl_mm2s:cpp \
	krnl_msm_pippenger \
	krnl_s2mm:cpp 

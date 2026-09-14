#!/bin/bash
# Builds the full-SoC Verilator testbench used for the pre-silicon toggle counts (Verilator 5.037).
set -e
cd "$(dirname "$0")"
verilator --cc --exe --build -j 4 -sv -Wno-fatal -Wno-lint -Wno-style -Wno-BLKANDNBLK \
  --trace-fst --trace-structs --Mdir obj_e40x -f e40x_files.f tb_e40x_profile.cpp \
  --top-module sca_pqc_cw305_top -o tb_e40x_profile
echo "built obj_e40x/tb_e40x_profile"

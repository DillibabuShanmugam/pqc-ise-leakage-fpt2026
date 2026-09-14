#!/bin/bash
set -e
V=${V:-$(cd "$(dirname "$0")/.." && pwd)}   # repository root; set V to an external RTL tree if needed
INC="-I$V/rtl/sca_pqc -I$V/rtl/sca_pqc/ise -I$V/rtl/sca_pqc/obi"
verilator --cc --exe --build -j 4 -Wno-fatal --trace \
  $INC --Mdir obj_mod $V/rtl/sca_pqc/ise/ise_mod_reduce.sv \
  --top-module ise_mod_reduce tb_mod_reduce.cpp -o tb_mod_reduce
echo "built obj_mod/tb_mod_reduce"

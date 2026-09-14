#!/bin/bash
# Bitstream for the fixed-versus-random TVLA campaign, open flow only, same
# recipe as build_bitstream10.sh (HW_KECCAK=0, build dir build10t). The SRAM
# image is read from build/ by $readmemh whatever BUILD is, so the hex is written
# to both directories and compared before synthesis.
# Output: board/sca_pqc_cw305_ise10_tvla3.bit, to be captured with
#   python3 board/capture_ten_instr.py --bit board/sca_pqc_cw305_ise10_tvla3.bit \
#       --fpga-id 100t --interleaved -n 1000 --samples 500 --gain 15 \
#       --freq 16000000 --out board/traces_tvla3
set -e
P=$(cd "$(dirname "$0")/.." && pwd)
D=$P/flow
B=build10s
HEX=$P/firmware/firmware_bram_init_tvla3.hex

cd "$D"
mkdir -p "$B"
rm -f "$P/BITSTREAM10S_DONE" "$P/campaign/board/sca_pqc_cw305_ise10_tvla3.bit"
cp "$HEX" "$B/firmware_bram_init.hex"
cp "$HEX" build/firmware_bram_init.hex
touch "$B/firmware_bram_init.hex" build/firmware_bram_init.hex
cmp -s "$HEX" build/firmware_bram_init.hex || { echo "image mismatch"; exit 1; }

{ echo "=== synth start $(date +%H:%M)"; make BUILD=$B HW_KECCAK=0 synth; echo "=== synth exit $? $(date +%H:%M)"; } > "$P/synth10s.log" 2>&1
{ echo "=== pnr start $(date +%H:%M)";   make BUILD=$B HW_KECCAK=0 pnr;   echo "=== pnr exit $? $(date +%H:%M)"; }   > "$P/pnr10s.log" 2>&1
{ echo "=== bit start $(date +%H:%M)";   make BUILD=$B HW_KECCAK=0 bitstream; echo "=== bit exit $? $(date +%H:%M)"; } > "$P/bit10s.log" 2>&1

cp "$D/$B/sca_pqc_cw305.bit" "$P/campaign/board/sca_pqc_cw305_ise10_tvla3.bit"
echo DONE > "$P/BITSTREAM10S_DONE"
ls -la "$P/campaign/board/sca_pqc_cw305_ise10_tvla3.bit"

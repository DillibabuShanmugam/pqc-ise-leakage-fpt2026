#!/bin/bash
# Board firmware for a TVLA campaign directory: FW=<dir> TAG=<name> ./build_fw_tvla_any.sh
# Compiles $FW/instr_board10.c against $FW/operands10.h, emits $FW/firmware_bram_init_$TAG.hex.
set -e
cd "$(dirname "$0")"
FW=${FW:-.}; TAG=${TAG:-tvla3}; export FW TAG
R=$(cd "$(dirname "$0")/.." && pwd)
SW=$R/sw/include
LD=$R/presilicon/link_64k.ld
CRT=$R/presilicon/crt0_64k.S
riscv64-unknown-elf-gcc -O2 -march=rv32imc -mabi=ilp32 -nostdlib -ffreestanding \
    -I"$SW" -I$FW -T "$LD" "$CRT" $FW/instr_board10.c -o $FW/instr_board_$TAG.elf -lgcc
riscv64-unknown-elf-size $FW/instr_board_$TAG.elf
riscv64-unknown-elf-objcopy -O binary $FW/instr_board_$TAG.elf $FW/instr_board_$TAG.bin
python3 - <<'PY'
import struct, os
FW, TAG = os.environ["FW"], os.environ["TAG"]
data = open(f'{FW}/instr_board_{TAG}.bin', 'rb').read()
data += b'\x00' * ((4 - len(data) % 4) % 4)
words = len(data) // 4
assert words <= 16384, f"firmware is {words} words, the 64 KB SRAM holds 16384"
with open(f'{FW}/firmware_bram_init_{TAG}.hex', 'w') as f:
    for i in range(0, len(data), 4):
        f.write('{:08X}\n'.format(struct.unpack('<I', data[i:i+4])[0]))
    for _ in range(16384 - words):
        f.write('00000000\n')
print(f"  {len(data)} bytes -> {words} words of 16384 ({100*words/16384:.1f}% of SRAM)")
PY
python3 - <<'PY'
import subprocess, re, collections, os
FW, TAG = os.environ["FW"], os.environ["TAG"]
NAME = {(1,1):"MONT_K",(1,0):"BARRETT_K",(6,6):"AND_LATCH",(1,2):"CADDQ",(2,3):"NTT_BFLY_GS_MUL",(4,0):"COMPRESS_1",
        (3,0):"CBD2_1",(1,3):"BARRETT_D",(1,4):"MONT_D_REDUCE64",(5,1):"DECOMPOSE",(7,0):"SEED_PRNG"}
out = subprocess.run(["riscv64-unknown-elf-objdump","-d",f"{FW}/instr_board_{TAG}.elf"], capture_output=True, text=True).stdout
c = collections.Counter()
for ln in out.splitlines():
    m = re.match(r'^[0-9a-f]+:\s+([0-9a-f]{8})\s', ln)
    if not m: continue
    w = int(m.group(1), 16)
    if (w & 0x7f) == 0x7b: c[((w >> 12) & 7, (w >> 25) & 0x7f)] += 1
missing = [n for k, n in NAME.items() if k not in c]
if missing: raise SystemExit(f"  MISSING: {missing}")
print("  all ten target instructions present;", {NAME[k]: v for k, v in c.items() if k in NAME and k != (7,0)})
PY

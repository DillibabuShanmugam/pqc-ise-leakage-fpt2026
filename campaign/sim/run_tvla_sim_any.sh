#!/bin/bash
# Pre-silicon half of the fixed-versus-random TVLA: one full-SoC Verilator run
# per instruction on the fw_tvla operand tables (500 fixed, 500 random rows,
# interleaved). Same firmware source, same harness, same extractor as the
# varying-secret campaign; only the tables differ.
# Writes ${PFX:-SIMT}_block<k>.npy (rows x 12 toggle counts) and ${PFX:-SIMT}_block<k>_idx.npy.
set -e
cd "$(dirname "$0")"
R=$(cd "$(dirname "$0")/../.." && pwd)
TB=$R/presilicon/obj_e40x/tb_e40x_profile   # built by presilicon/build.sh
SW=$R/sw/include
LD=$R/presilicon/link_64k.ld
CRT=$R/presilicon/crt0_64k.S
NCYC=${NCYC:-220000}
N=${N:-1000}
BLOCKS=${BLOCKS:-"1 2 3 4 5 6 7 8 9 10"}

for k in $BLOCKS; do
    O=sim_b$k; mkdir -p $O/build
    riscv64-unknown-elf-gcc -O2 -march=rv32imc -mabi=ilp32 -nostdlib -ffreestanding \
        -DONLY_BLOCK=$k -DNSIM=${N}u -DGAP=2u \
        -I"$SW" -I$R/${FW:-firmware} -T "$LD" "$CRT" $R/${FW:-firmware}/instr_board10.c -o $O/fw.elf -lgcc
    riscv64-unknown-elf-objcopy -O binary $O/fw.elf $O/fw.bin
    python3 - "$O" <<'PY'
import struct, sys
o = sys.argv[1]
data = open(f'{o}/fw.bin', 'rb').read(); data += b'\x00' * ((4 - len(data) % 4) % 4)
words = len(data) // 4; assert words <= 16384
with open(f'{o}/build/firmware_bram_init.hex', 'w') as f:
    for i in range(0, len(data), 4): f.write('{:08X}\n'.format(struct.unpack('<I', data[i:i+4])[0]))
    for _ in range(16384 - words): f.write('00000000\n')
PY
    cd $O
    t0=$(date +%s)
    $TB $NCYC run.fst 0 > /dev/null 2>&1
    fst2vcd run.fst -o run.vcd > /dev/null 2>&1
    python3 ../extract10.py run.vcd $k 12
    mv SIM_block$k.npy ../${PFX:-SIMT}_block$k.npy
    mv SIM_block${k}_idx.npy ../${PFX:-SIMT}_block${k}_idx.npy
    rm -f run.vcd run.fst
    echo "block $k done ($(( $(date +%s) - t0 )) s)"
    cd ..
done
echo "tvla pre-silicon done"

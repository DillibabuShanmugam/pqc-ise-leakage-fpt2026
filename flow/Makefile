# ============================================================================
# SCA_Pro_PQC — Complete Open-Source FPGA Flow
# ============================================================================
#
# Full automated pipeline:
#   make all = firmware → synth → pnr → bitstream → program → verify
#
# Flow:
#   1. Compile firmware (riscv64-gcc → .hex)
#   2. Synthesis (Yosys 0.50 + slang plugin → .json)
#   3. Place & Route (nextpnr-xilinx → .fasm)
#   4. Bitstream (fasm2frames + xc7frames2bit → .bit)
#   5. Program CW305 (chipwhisperer Python API)
#   6. Verify (USB register read + JTAG readback)
#
# Target: CW305 (XC7A35T-2FTG256) @ 20 MHz
# ============================================================================

# --------------------------------------------------------------------------
# Tool paths (all open-source except Vivado for JTAG readback)
# --------------------------------------------------------------------------
TOOLS       ?= /media/dillibabu/PortableSSD/claudecode/PQC/tools
YOSYS       := $(TOOLS)/oss-cad-suite/bin/yosys
NEXTPNR     := $(TOOLS)/nextpnr-xilinx/build/nextpnr-xilinx
# xc7a100t retarget (HW masked Keccak): chipdb built locally from prjxray-db
# via nextpnr-xilinx/xilinx/python/bbaexport.py + bbasm (see doc/REPRODUCE.md).
CHIPDB      := ../chipdb/xc7a100tftg256-2.bin
PRJXRAY_DB  := $(TOOLS)/nextpnr-xilinx/xilinx/external/prjxray-db/artix7
XC7FRAMES2BIT ?= xc7frames2bit
VIVADO      := /tools/Xilinx/Vivado/2020.2/bin/vivado
CROSS_CC    := riscv64-unknown-elf-gcc
CROSS_OBJCOPY := riscv64-unknown-elf-objcopy
CROSS_SIZE  := riscv64-unknown-elf-size

# --------------------------------------------------------------------------
# Directories
# --------------------------------------------------------------------------
BUILD       := build
RTL         := ../rtl
FW_DIR      := firmware/mlkem1024
READBACK    := readback
SCRIPTS     := scripts

# BRAM init hex consumed by sca_pqc_cw305_top.sv $readmemh
FW_HEX      := $(BUILD)/firmware_bram_init.hex

# --------------------------------------------------------------------------
# Greyhound SoC source paths
# --------------------------------------------------------------------------
GH_IHP      ?= ./greyhound
GH_IP       := greyhound/ip
GH_SRC      := greyhound/src
GH_INC      := greyhound/include

# --------------------------------------------------------------------------
# Source file lists
# --------------------------------------------------------------------------

# Greyhound SoC SystemVerilog
GH_SV := \
	$(GH_SRC)/soc_pkg.sv $(GH_SRC)/cf_math_pkg.sv \
	$(GH_SRC)/cv32e40x_pkg.sv $(GH_SRC)/obi_pkg.sv \
	$(GH_IP)/obi_intf.sv $(GH_IP)/obi_mux.sv $(GH_IP)/obi_demux.sv \
	$(GH_IP)/obi_err_sbr.sv $(GH_IP)/obi_sram_shim.sv \
	$(GH_IP)/fifo_v3.sv $(GH_IP)/rr_arb_tree.sv \
	$(GH_IP)/delta_counter.sv $(GH_IP)/lzc.sv \
	$(wildcard $(GH_IP)/cv32e40x/*.sv) \
	$(GH_SRC)/greyhound_soc.sv $(GH_SRC)/fabric_extension.sv \
	$(GH_SRC)/dummy_extension.sv $(GH_SRC)/obi2ahbm_adapter.sv \
	$(GH_SRC)/cv32e40x_clock_gate.sv

# Greyhound peripheral Verilog
GH_V := \
	$(GH_IP)/EF_QSPI_XIP_CTRL.v $(GH_IP)/DMC.v $(GH_IP)/EF_QSPI_XIP_CTRL_AHBL.v \
	$(GH_IP)/EF_PSRAM_CTRL.v $(GH_IP)/EF_PSRAM_CTRL_AHBL.v \
	$(GH_IP)/EF_UART.v $(GH_IP)/EF_UART_AHBL.v $(GH_IP)/ef_util_lib.v

# SCA_PQC coprocessor
SCA_PQC := \
	$(RTL)/sca_pqc_pkg.sv $(RTL)/ise/ise_keccak_ops.sv $(RTL)/ise/ise_mod_reduce.sv \
	$(RTL)/ise/ise_ntt_butterfly.sv $(RTL)/ise/ise_cbd.sv \
	$(RTL)/ise/ise_compress.sv $(RTL)/ise/ise_mldsa_ops.sv \
	$(RTL)/ise/ise_mask_ops.sv $(RTL)/ise/ise_prng.sv \
	$(RTL)/sca_pqc_coprocessor_top.sv $(RTL)/sca_pqc_greyhound_adapter.sv \
	$(RTL)/obi/obi_a2b_b2a_peripheral.sv $(RTL)/obi/a2b_core.sv $(RTL)/obi/b2a_core.sv \
	$(RTL)/obi/sec_add.sv $(RTL)/obi/sec_and.sv $(RTL)/obi/sec_ops.sv

# v1 HW lane-serial DOM-masked Keccak-f[1600] (xc7a100t retarget). These use
# SystemVerilog packages/typedefs (pkg_keccak) that yosys's built-in Verilog
# frontend cannot parse, so they are elaborated with read_slang (see synth recipe).
SCA_KECCAK := \
	$(RTL)/keccak/pkg_keccak.sv \
	$(RTL)/keccak/keccak_round_masked.sv $(RTL)/keccak/keccak_round_masked_serial.sv \
	$(RTL)/keccak/keccak_round_constants_gen.sv $(RTL)/keccak/keccak_f_masked_serial.sv

# FPGA stubs and CW305 wrapper
FPGA_SRC := \
	sca_pqc_cw305_top.sv \
	$(GH_SRC)/cw305_usb_reg_fe.sv \
	greyhound/fpga_stubs_minimal.sv \
	greyhound/tc_sram_openflow.sv

# Part name
# The CW305 ships with the -2 speed-grade XC7A35T in FTG256 package
# (XC7A35T-2FTG256). Build the bit for the physical chip's speed grade
# so the reverse-disassembly flow (bit -> frames -> fasm) and any
# future prjxray-based analyses use the db that matches what's in the
# bit header.
PART := xc7a100tftg256-2

# ============================================================================
# PHONY TARGETS
# ============================================================================
.PHONY: all firmware synth pnr bitstream program verify verify-kat-masked \
        verify-kat verify-minimal verify-bench \
        readback-bt0 readback-bt1 verify-readback split-readback verify-split \
        essential-bits \
        bit-to-frames frames-to-fasm bit-to-fasm \
        kat-flow \
        clean help

# Re-split an existing readback bin into BT0/BT1 without hitting JTAG.
split-readback:
	@python3 $(SCRIPTS)/split_readback.py \
		$(READBACK)/sca_pqc_bt0.bin $(READBACK)/sca_pqc

# Evidence-based verification that the BT0/BT1 split byte offsets
# match the four independent sources (UG908, prjxray-db, prjxray
# bitread on the .bit, and readback non-zero density shape).
verify-split: $(BUILD)/sca_pqc_cw305.bit
	@python3 $(SCRIPTS)/verify_split.py \
		$(BUILD)/sca_pqc_cw305.bit $(READBACK)/sca_pqc_bt0.bin

# Static silent-bit analysis from the FASM produced by nextpnr.
# No hardware, no Vivado, just the FASM file.
essential-bits: $(BUILD)/sca_pqc.fasm | $(READBACK)
	@python3 $(SCRIPTS)/essential_bits.py \
		$(BUILD)/sca_pqc.fasm $(READBACK)/essential_bits.json

# ============================================================================
# Reverse disassembly: .bit -> .frames -> golden .fasm
#
# Round-trips the bitstream back through prjxray bitread (for
# bit->frames) and the prjxray fasm_disassembler (for frames->fasm).
# The resulting "golden" FASM is a second-source reference for the
# forward FASM produced by nextpnr, useful for:
#   - sanity-checking the fasm2frames/xc7frames2bit bitstream step,
#   - diffing which features nextpnr vs bitread agree on,
#   - downstream static analyses that want to work from the bit file
#     alone (e.g. after a Vivado-produced bitfile).
# ============================================================================
#
# Note: PART and PRJXRAY_DB are exported to the reverse-disassembly
# scripts so the .bit -> .frames -> .fasm round-trip uses the exact
# same part and prjxray-db as the forward fasm2frames step above.
# Mismatching db versions (or speed grade) would yield FASM feature
# names that silently disagree with nextpnr's output.
bit-to-frames: $(READBACK)/sca_pqc.frames

$(READBACK)/sca_pqc.frames: $(BUILD)/sca_pqc_cw305.bit | $(READBACK)
	@echo "=== Reverse: .bit -> .frames (prjxray bitread) ==="
	@PART=$(PART) PRJXRAY_DB=$(PRJXRAY_DB) \
		python3 $(SCRIPTS)/bitstream_to_frames.py $< $@

frames-to-fasm: $(READBACK)/sca_pqc_golden.fasm

$(READBACK)/sca_pqc_golden.fasm: $(READBACK)/sca_pqc.frames
	@echo "=== Reverse: .frames -> golden .fasm (prjxray disassembler) ==="
	@PART=$(PART) PRJXRAY_DB=$(PRJXRAY_DB) \
		python3 $(SCRIPTS)/frames_to_fasm.py $< $@

bit-to-fasm: $(READBACK)/sca_pqc_golden.fasm

# ============================================================================
# DEFAULT: Full pipeline
# ============================================================================
all: firmware synth pnr bitstream
	@echo ""
	@echo "╔══════════════════════════════════════════════════════╗"
	@echo "║  SCA_Pro_PQC — Build Complete                       ║"
	@echo "║  Bitstream: $(BUILD)/sca_pqc_cw305.bit              ║"
	@echo "║  Next: make program verify                          ║"
	@echo "╚══════════════════════════════════════════════════════╝"

# ============================================================================
# Step 1: Compile firmware
#
# Two firmwares are supported:
#   FW=minimal  (default) -- minimal_uart.c, ISE smoke-test
#   FW=fips203            -- full ML-KEM-1024 FIPS-203 KAT runner
# ============================================================================
FW ?= fips203

firmware: $(FW_HEX)

FW_SRC := $(wildcard $(FW_DIR)/*.c firmware/hello_world/*.c)

FIPS203_DIR := firmware/mlkem1024_fips203
# Each FW variant pulls in exactly one of the main_*.c files; the others
# must be filtered out of the *.c glob so we don't end up with multiple
# main() definitions at link time.
FIPS203_MAINS := $(FIPS203_DIR)/src/main.c \
                 $(FIPS203_DIR)/src/main_masked.c \
                 $(FIPS203_DIR)/src/main_saarinen_naive.c \
                 $(FIPS203_DIR)/src/main_saarinen_masked.c
FIPS203_ALL_C := $(wildcard $(FIPS203_DIR)/src/*.c)
FIPS203_NONMAIN := $(filter-out $(FIPS203_MAINS),$(FIPS203_ALL_C))

# Default: original main.c (unmasked KAT runner).
FIPS203_SRCS := $(FIPS203_DIR)/src/main.c $(FIPS203_NONMAIN)

# Masked KAT variant (v1 base-of-truth). The v1 masked sources now live in
# $(FIPS203_DIR)/src/, so FIPS203_NONMAIN already covers masked_poly.c /
# masked_ntt.c / masked_indcpa.c / masked_keccak.c / freestanding_mem.c —
# do NOT re-add ../sw/src/masked_*.c or you get duplicate-symbol link errors.
FIPS203_MASKED_SRCS := $(FIPS203_DIR)/src/main_masked.c $(FIPS203_NONMAIN)

# Saarinen CCA-PC TVLA streaming variants (single T_COMPARE trigger).
FIPS203_SAARINEN_NAIVE_SRCS  := $(FIPS203_DIR)/src/main_saarinen_naive.c $(FIPS203_NONMAIN)
FIPS203_SAARINEN_MASKED_SRCS := $(FIPS203_DIR)/src/main_saarinen_masked.c $(FIPS203_NONMAIN) \
                                ../sw/src/masked_poly.c \
                                ../sw/src/masked_ntt.c

# ----------------------------------------------------------------------------
# mlkem-native baseline (FW=mlkem_native)
#
# Compiles pq-code-package/mlkem-native (portable C backend only) for the
# SAME CV32E40X RV32IMC core, with ZERO custom instructions. This is the
# "no-ISE" performance baseline the advisor asked for. Cycle counts ship
# via MBOX[1..3] (KeyGen/Encap/Decap), final pass/fail in MBOX[0].
#
# Critical invariant: the resulting ELF must not contain Custom-3 opcode
# 0x7B anywhere. The recipe runs objdump and fails the build if it does.
# ----------------------------------------------------------------------------
MLKN_DIR        := ../tvla_mlkem_sw/firmware
MLKN_UPSTREAM   := $(MLKN_DIR)/upstream/mlkem
MLKN_WRAPPER    := $(MLKN_DIR)/src/main_sw_cw305.c
MLKN_TVLA_WRAPPER := $(MLKN_DIR)/src/main_sw_cw305_widetrig.c
MLKN_CRT0       := $(MLKN_DIR)/src/crt0_mlkem_sw.S
# Upstream ships mlkem_native.c as a Single Compilation Unit (SCU) that
# #include's every other .c file in the library. We compile that one file
# only; listing the constituent sources alongside would cause duplicate-
# definition link errors. Portable-C backend is selected by default (no
# MLK_CONFIG_USE_NATIVE_BACKEND_* flags passed via CFLAGS).
MLKN_CORE_SRCS  := $(MLKN_UPSTREAM)/mlkem_native.c
MLKN_SRCS       := $(MLKN_WRAPPER) $(MLKN_CORE_SRCS)
MLKN_TVLA_SRCS  := $(MLKN_TVLA_WRAPPER) $(MLKN_CORE_SRCS)
MLKN_CFLAGS     := -O2 -march=rv32imc -mabi=ilp32 -nostdlib -ffreestanding \
                   -ffunction-sections -fdata-sections -w \
                   -std=c99 \
                   -mstrict-align \
                   -DMLK_CONFIG_PARAMETER_SET=1024 \
                   -DMLK_CONFIG_FILE='"reduce_ram_config.h"' \
                   -DMLK_INSTRUMENT_MBOX -DMLK_INDCPA_STUB \
                   -I$(MLKN_DIR)/src \
                   -I$(MLKN_UPSTREAM) \
                   -I$(MLKN_UPSTREAM)/src \
                   -I$(MLKN_UPSTREAM)/src/fips202 \
                   -I$(FIPS203_DIR)/include
# MLK_INSTRUMENT_MBOX enables the progressive MBOX(3)=0xCAFExxxx markers in
# tvla_mlkem_sw/firmware/upstream/mlkem/src/{kem,indcpa}.c so the probe can
# identify which KeyGen subroutine hangs. Remove this flag (or leave it off
# by undefining MLK_INSTRUMENT_MBOX) to get a binary identical to upstream.
# Flags reverted 2026-05-16 after relaxed-build wedged before main(). The
# strict+REDUCE_RAM combination is the only one that reaches main() at all;
# the hang inside crypto_kem_keypair_derand() is being diagnosed via a trap
# handler in crt0.S that captures mcause/mepc/mtval to MBOX[0..2].
# -mstrict-align forces gcc to emit aligned-only loads/stores for pointers
# whose alignment cannot be statically proven. RV32IMC traps on misaligned
# accesses (no Zicclsm), and the upstream pq-code-package/mlkem-native
# library issues 32-bit loads from byte streams in several spots that fault
# on this core. With -mstrict-align the same source compiles to a sequence
# of byte loads + shifts and the firmware runs through.
# Note: intentionally NO -I../sw/include. That path contains sca_pqc_ise.h
# and including it accidentally is the most likely way to pollute the
# baseline with custom instructions. We block it at the include-path level.

ifeq ($(FW),bench)
$(FW_HEX): firmware/hello_world/ise_bench.c $(FW_DIR)/crt0.S $(FW_DIR)/link.ld | $(BUILD)
	@echo "=== Step 1: Compile firmware (ISE per-component bench) ==="
	$(CROSS_CC) -O2 -march=rv32imc -mabi=ilp32 -nostdlib -ffreestanding \
		-I../sw/include -T $(FW_DIR)/link.ld $(FW_DIR)/crt0.S $< \
		-o $(BUILD)/firmware.elf -lgcc
	$(CROSS_SIZE) $(BUILD)/firmware.elf
	$(CROSS_OBJCOPY) -O binary $(BUILD)/firmware.elf $(BUILD)/firmware.bin
	@python3 -c "\
	import struct; \
	data = open('$(BUILD)/firmware.bin', 'rb').read(); \
	pad = (4 - len(data) % 4) % 4; data += b'\x00' * pad; \
	f = open('$@', 'w'); \
	[f.write('{:08X}\n'.format(struct.unpack('<I', data[i:i+4])[0])) for i in range(0, len(data), 4)]; \
	[f.write('00000000\n') for _ in range(16384 - len(data)//4)]; \
	f.close(); print(f'  {len(data)} bytes -> 16384 words (64KB)')"
else ifeq ($(FW),fips203)
$(FW_HEX): $(FIPS203_SRCS) $(FW_DIR)/crt0.S $(FW_DIR)/link.ld | $(BUILD)
	@echo "=== Step 1: Compile firmware (FIPS-203 KAT) ==="
	$(CROSS_CC) -O2 -march=rv32imc -mabi=ilp32 -nostdlib -ffreestanding \
		-ffunction-sections -fdata-sections -w \
		-I$(FIPS203_DIR)/include -I../sw/include \
		-T $(FW_DIR)/link.ld $(FW_DIR)/crt0.S $(FIPS203_SRCS) \
		-Wl,--gc-sections -lgcc \
		-o $(BUILD)/firmware.elf
	$(CROSS_SIZE) $(BUILD)/firmware.elf
	$(CROSS_OBJCOPY) -O binary $(BUILD)/firmware.elf $(BUILD)/firmware.bin
	@python3 -c "\
	import struct; \
	data = open('$(BUILD)/firmware.bin', 'rb').read(); \
	pad = (4 - len(data) % 4) % 4; data += b'\x00' * pad; \
	f = open('$@', 'w'); \
	[f.write('{:08X}\n'.format(struct.unpack('<I', data[i:i+4])[0])) for i in range(0, len(data), 4)]; \
	[f.write('00000000\n') for _ in range(16384 - len(data)//4)]; \
	f.close(); print(f'  {len(data)} bytes -> 16384 words (64KB)')"
else ifeq ($(FW),fips203_masked)
$(FW_HEX): $(FIPS203_MASKED_SRCS) $(FW_DIR)/crt0.S $(FW_DIR)/link.ld | $(BUILD)
	@echo "=== Step 1: Compile firmware (FIPS-203 KAT, MASKED via ISE; MKECCAK=$(MKECCAK_DEF)) ==="
	$(CROSS_CC) -O2 -march=rv32imc -mabi=ilp32 -nostdlib -ffreestanding \
		-ffunction-sections -fdata-sections -w $(MKECCAK_DEF) \
		-I$(FIPS203_DIR)/include -I../sw/include \
		-T $(FW_DIR)/link.ld $(FW_DIR)/crt0.S $(FIPS203_MASKED_SRCS) \
		-Wl,--gc-sections -lgcc \
		-o $(BUILD)/firmware.elf
	$(CROSS_SIZE) $(BUILD)/firmware.elf
	$(CROSS_OBJCOPY) -O binary $(BUILD)/firmware.elf $(BUILD)/firmware.bin
	@python3 -c "\
	import struct; \
	data = open('$(BUILD)/firmware.bin', 'rb').read(); \
	pad = (4 - len(data) % 4) % 4; data += b'\x00' * pad; \
	f = open('$@', 'w'); \
	[f.write('{:08X}\n'.format(struct.unpack('<I', data[i:i+4])[0])) for i in range(0, len(data), 4)]; \
	[f.write('00000000\n') for _ in range(16384 - len(data)//4)]; \
	f.close(); print(f'  {len(data)} bytes -> 16384 words (64KB)')"
else ifeq ($(FW),fips203_saarinen)
$(FW_HEX): $(FIPS203_SAARINEN_NAIVE_SRCS) $(FW_DIR)/crt0.S $(FW_DIR)/link.ld | $(BUILD)
	@echo "=== Step 1: Compile firmware (FIPS-203 Saarinen CCA-PC, NAIVE) ==="
	$(CROSS_CC) -O2 -march=rv32imc -mabi=ilp32 -nostdlib -ffreestanding \
		-ffunction-sections -fdata-sections -w \
		-I$(FIPS203_DIR)/include -I../sw/include -I.. \
		-T $(FW_DIR)/link.ld $(FW_DIR)/crt0.S $(FIPS203_SAARINEN_NAIVE_SRCS) \
		-Wl,--gc-sections -lgcc \
		-o $(BUILD)/firmware.elf
	$(CROSS_SIZE) $(BUILD)/firmware.elf
	$(CROSS_OBJCOPY) -O binary $(BUILD)/firmware.elf $(BUILD)/firmware.bin
	@python3 -c "\
	import struct; \
	data = open('$(BUILD)/firmware.bin', 'rb').read(); \
	pad = (4 - len(data) % 4) % 4; data += b'\x00' * pad; \
	f = open('$@', 'w'); \
	[f.write('{:08X}\n'.format(struct.unpack('<I', data[i:i+4])[0])) for i in range(0, len(data), 4)]; \
	[f.write('00000000\n') for _ in range(16384 - len(data)//4)]; \
	f.close(); print(f'  {len(data)} bytes -> 16384 words (64KB)')"
else ifeq ($(FW),fips203_saarinen_masked)
$(FW_HEX): $(FIPS203_SAARINEN_MASKED_SRCS) $(FW_DIR)/crt0.S $(FW_DIR)/link.ld | $(BUILD)
	@echo "=== Step 1: Compile firmware (FIPS-203 Saarinen CCA-PC, MASKED) ==="
	$(CROSS_CC) -O2 -march=rv32imc -mabi=ilp32 -nostdlib -ffreestanding \
		-ffunction-sections -fdata-sections -w \
		-I$(FIPS203_DIR)/include -I../sw/include -I.. \
		-T $(FW_DIR)/link.ld $(FW_DIR)/crt0.S $(FIPS203_SAARINEN_MASKED_SRCS) \
		-Wl,--gc-sections -lgcc \
		-o $(BUILD)/firmware.elf
	$(CROSS_SIZE) $(BUILD)/firmware.elf
	$(CROSS_OBJCOPY) -O binary $(BUILD)/firmware.elf $(BUILD)/firmware.bin
	@python3 -c "\
	import struct; \
	data = open('$(BUILD)/firmware.bin', 'rb').read(); \
	pad = (4 - len(data) % 4) % 4; data += b'\x00' * pad; \
	f = open('$@', 'w'); \
	[f.write('{:08X}\n'.format(struct.unpack('<I', data[i:i+4])[0])) for i in range(0, len(data), 4)]; \
	[f.write('00000000\n') for _ in range(16384 - len(data)//4)]; \
	f.close(); print(f'  {len(data)} bytes -> 16384 words (64KB)')"
else ifeq ($(FW),mlkem_native_stub)
$(FW_HEX): $(MLKN_DIR)/src/stub_mbox.c $(FW_DIR)/crt0.S $(FW_DIR)/link.ld | $(BUILD)
	@echo "=== Step 1: Compile firmware (mlkem-native STUB diagnostic) ==="
	$(CROSS_CC) -O0 -march=rv32imc -mabi=ilp32 -nostdlib -ffreestanding \
		-T $(FW_DIR)/link.ld $(FW_DIR)/crt0.S $(MLKN_DIR)/src/stub_mbox.c \
		-Wl,--gc-sections -lgcc \
		-o $(BUILD)/firmware.elf
	$(CROSS_SIZE) $(BUILD)/firmware.elf
	$(CROSS_OBJCOPY) -O binary $(BUILD)/firmware.elf $(BUILD)/firmware.bin
	@python3 -c "\
	import struct; \
	data = open('$(BUILD)/firmware.bin', 'rb').read(); \
	pad = (4 - len(data) % 4) % 4; data += b'\x00' * pad; \
	f = open('$@', 'w'); \
	[f.write('{:08X}\n'.format(struct.unpack('<I', data[i:i+4])[0])) for i in range(0, len(data), 4)]; \
	[f.write('00000000\n') for _ in range(16384 - len(data)//4)]; \
	f.close(); print(f'  {len(data)} bytes -> 16384 words (64KB)')"
else ifeq ($(FW),mlkem_sw)
$(FW_HEX): $(MLKN_SRCS) $(MLKN_CRT0) $(FW_DIR)/link.ld | $(BUILD)
	@echo "=== Step 1: Compile firmware (mlkem-sw baseline, NO ISE; private trap-diagnostic crt0) ==="
	$(CROSS_CC) $(MLKN_CFLAGS) \
		-T $(FW_DIR)/link.ld $(MLKN_CRT0) $(MLKN_SRCS) \
		-Wl,--gc-sections -lgcc \
		-o $(BUILD)/firmware.elf
	$(CROSS_SIZE) $(BUILD)/firmware.elf
	@echo "=== Step 1b: Verify NO Custom-3 instructions (opcode 0x7B) in .text ==="
	@# Match only 32-bit instruction lines whose word column ends in `7b`
	@# (the RISC-V Custom-3 opcode). Data-section dumps use a 16-bit-pair
	@# format and are correctly ignored by this pattern.
	@hits=$$(riscv64-unknown-elf-objdump -d $(BUILD)/firmware.elf \
	         | awk '/^[[:space:]]+[0-9a-f]+:\t[0-9a-f]{8}[[:space:]]/ { if ($$2 ~ /7b$$/) c++ } \
	                END { print c+0 }'); \
	echo "  Custom-3 (opcode 0x7B) instructions in .text: $$hits"; \
	if [ "$$hits" != "0" ]; then \
	    echo "ERROR: baseline ELF contains $$hits Custom-3 instruction(s)."; \
	    echo "       The baseline must be plain RV32IMC; aborting."; \
	    riscv64-unknown-elf-objdump -d $(BUILD)/firmware.elf \
	        | awk '/^[[:space:]]+[0-9a-f]+:\t[0-9a-f]{8}[[:space:]]/ { if ($$2 ~ /7b$$/) print }' \
	        | head -20; \
	    exit 1; \
	fi
	$(CROSS_OBJCOPY) -O binary $(BUILD)/firmware.elf $(BUILD)/firmware.bin
	@python3 -c "\
	import struct; \
	data = open('$(BUILD)/firmware.bin', 'rb').read(); \
	pad = (4 - len(data) % 4) % 4; data += b'\x00' * pad; \
	f = open('$@', 'w'); \
	[f.write('{:08X}\n'.format(struct.unpack('<I', data[i:i+4])[0])) for i in range(0, len(data), 4)]; \
	[f.write('00000000\n') for _ in range(16384 - len(data)//4)]; \
	f.close(); print(f'  {len(data)} bytes -> 16384 words (64KB)')"
else ifeq ($(FW),mlkem_sw_widetrig)
$(FW_HEX): $(MLKN_TVLA_SRCS) $(MLKN_CRT0) $(FW_DIR)/link.ld | $(BUILD)
	@echo "=== Step 1: Compile firmware (mlkem-sw v2-widetrig TVLA, NO ISE; private trap-diagnostic crt0) ==="
	$(CROSS_CC) $(MLKN_CFLAGS) \
		-T $(FW_DIR)/link.ld $(MLKN_CRT0) $(MLKN_TVLA_SRCS) \
		-Wl,--gc-sections -lgcc \
		-o $(BUILD)/firmware.elf
	$(CROSS_SIZE) $(BUILD)/firmware.elf
	@echo "=== Step 1b: Verify NO Custom-3 instructions (opcode 0x7B) in .text ==="
	@hits=$$(riscv64-unknown-elf-objdump -d $(BUILD)/firmware.elf \
	         | awk '/^[[:space:]]+[0-9a-f]+:\t[0-9a-f]{8}[[:space:]]/ { if ($$2 ~ /7b$$/) c++ } \
	                END { print c+0 }'); \
	echo "  Custom-3 (opcode 0x7B) instructions in .text: $$hits"; \
	if [ "$$hits" != "0" ]; then \
	    echo "ERROR: mlkem-sw widetrig ELF contains $$hits Custom-3 instruction(s)."; \
	    echo "       The mlkem-sw baseline must be plain RV32IMC; aborting."; \
	    riscv64-unknown-elf-objdump -d $(BUILD)/firmware.elf \
	        | awk '/^[[:space:]]+[0-9a-f]+:\t[0-9a-f]{8}[[:space:]]/ { if ($$2 ~ /7b$$/) print }' \
	        | head -20; \
	    exit 1; \
	fi
	$(CROSS_OBJCOPY) -O binary $(BUILD)/firmware.elf $(BUILD)/firmware.bin
	@python3 -c "\
	import struct; \
	data = open('$(BUILD)/firmware.bin', 'rb').read(); \
	pad = (4 - len(data) % 4) % 4; data += b'\x00' * pad; \
	f = open('$@', 'w'); \
	[f.write('{:08X}\n'.format(struct.unpack('<I', data[i:i+4])[0])) for i in range(0, len(data), 4)]; \
	[f.write('00000000\n') for _ in range(16384 - len(data)//4)]; \
	f.close(); print(f'  {len(data)} bytes -> 16384 words (64KB)')"
else ifeq ($(FW),mldsa44)
$(FW_HEX): | $(BUILD)
	@echo "=== Step 1: Compile firmware (ML-DSA-44 FIPS-204 KAT, NAIVE) ==="
	$(MAKE) -C ../mldsa_work/fw MASKED=0
	cp ../mldsa_work/fw/build/firmware_bram_init.hex $@
else ifeq ($(FW),mldsa44_masked)
$(FW_HEX): | $(BUILD)
	@echo "=== Step 1: Compile firmware (ML-DSA-44 FIPS-204 KAT, MASKED via ISE) ==="
	$(MAKE) -C ../mldsa_work/fw MASKED=1
	cp ../mldsa_work/fw/build/firmware_bram_init.hex $@
else ifeq ($(FW),aes128)
$(FW_HEX): | $(BUILD)
	@echo "=== Step 1: Compile firmware (AES-128 FIPS-197 KAT, NAIVE) ==="
	bash firmware/aes128/build_fw_hex.sh naive $@
else ifeq ($(FW),aes128_masked)
$(FW_HEX): | $(BUILD)
	@echo "=== Step 1: Compile firmware (AES-128 first-order MASKED via ISE PRNG) ==="
	bash firmware/aes128/build_fw_hex.sh masked $@
else ifeq ($(FW),combined)
$(FW_HEX): | $(BUILD)
	@echo "=== Step 1: Compile firmware (UNIFIED multi-primitive image; mode via MBOX[0]) ==="
	bash firmware/combined/build_fw_hex.sh $@
else
$(FW_HEX): firmware/hello_world/minimal_uart.c $(FW_DIR)/crt0.S $(FW_DIR)/link.ld | $(BUILD)
	@echo "=== Step 1: Compile firmware (minimal_uart) ==="
	$(CROSS_CC) -O0 -march=rv32imc -mabi=ilp32 -nostdlib -ffreestanding \
		-I../sw/include -T $(FW_DIR)/link.ld $(FW_DIR)/crt0.S $< \
		-o $(BUILD)/firmware.elf -lgcc
	$(CROSS_SIZE) $(BUILD)/firmware.elf
	$(CROSS_OBJCOPY) -O binary $(BUILD)/firmware.elf $(BUILD)/firmware.bin
	@python3 -c "\
	import struct; \
	data = open('$(BUILD)/firmware.bin', 'rb').read(); \
	pad = (4 - len(data) % 4) % 4; data += b'\x00' * pad; \
	f = open('$@', 'w'); \
	[f.write('{:08X}\n'.format(struct.unpack('<I', data[i:i+4])[0])) for i in range(0, len(data), 4)]; \
	[f.write('00000000\n') for _ in range(16384 - len(data)//4)]; \
	f.close(); print(f'  {len(data)} bytes -> 16384 words (64KB)')"
endif

# ============================================================================
# Step 2: Yosys + slang synthesis
# ============================================================================
# Strategy: Single read_slang for Greyhound SoC (native SV parsing)
# + read_verilog for CW305 top (handles $readmemh for BRAM init)
# + read_verilog for SCA_PQC (uses `define macros)
#
# Key slang flags (from working v2.0 flow):
#   --ignore-assertions        : skip SVA
#   --allow-use-before-declare : forward references in packages
#   --ignore-unknown-modules   : stub unresolved modules
# ============================================================================
# HW_KECCAK=1 (default): tightly-coupled HW lane-serial DOM-masked Keccak-f[1600]
#   (~33k cells). Synth/Verilator/host-KAT verified; firmware uses -DUSE_HW_MKECCAK.
#   Its open-source nextpnr P&R on xc7a100t is heavy: the HeAP analytical solve is
#   very slow on the Keccak's 1600-bit high-fanout buses, and the SA placer cannot
#   legalize the carry chains -> needs a large-RAM machine / long run.
# HW_KECCAK=0: stub the HW core (-DNO_HW_KECCAK) and use the software DOM Keccak in
#   firmware (omit -DUSE_HW_MKECCAK) -> ~33k fewer cells, places fast open-source.
HW_KECCAK ?= 1
ifeq ($(HW_KECCAK),0)
  KECCAK_SLANG :=
  SCA_PQC_DEF  := -DNO_HW_KECCAK
  MKECCAK_DEF  :=
else
  KECCAK_SLANG := read_slang -I $(RTL)/keccak --top keccak_f_masked_serial --ignore-assertions --allow-use-before-declare $(SCA_KECCAK);
  SCA_PQC_DEF  :=
  MKECCAK_DEF  := -DUSE_HW_MKECCAK
endif

synth: $(BUILD)/sca_pqc.json

$(BUILD)/sca_pqc.json: $(SCA_PQC) $(SCA_KECCAK) $(FPGA_SRC) $(FW_HEX) | $(BUILD)
	@echo "=== Step 2: Yosys + slang synthesis (HW_KECCAK=$(HW_KECCAK)) ==="
	$(YOSYS) -p " \
		plugin -i slang; \
		read_verilog -sv -lib sca_pqc_cw305_top.sv; \
		$(KECCAK_SLANG) \
		read_slang \
			-I $(GH_INC) \
			-I $(GH_INC)/obi \
			-I $(GH_INC)/common_cells \
			-I $(RTL) \
			-DSYNTHESIS=1 -DFUNCTIONAL -DCLKG_GENERIC \
			--top greyhound_soc \
			--ignore-assertions \
			--allow-use-before-declare \
			--ignore-unknown-modules \
			$(GH_SV) $(GH_V); \
		read_verilog -sv $(GH_SRC)/cw305_usb_reg_fe.sv \
			greyhound/fpga_stubs_minimal.sv greyhound/tc_sram_openflow.sv; \
		read_verilog -sv -I $(RTL) $(SCA_PQC_DEF) $(SCA_PQC); \
		read_verilog -sv sca_pqc_cw305_top.sv; \
		synth_xilinx -top sca_pqc_cw305_top -family xc7 -nowidelut; \
		stat; \
		write_json $(BUILD)/sca_pqc.json" \
		-l $(BUILD)/yosys.log 2>&1
	@echo "  Synthesis complete. Log: $(BUILD)/yosys.log"
	@grep -E "LUT|DSP|RAMB|Number of cell" $(BUILD)/yosys.log | tail -5

# ============================================================================
# Step 3: Place and Route (nextpnr-xilinx)
# ============================================================================
# --ignore-loops: OBI crossbar has combinational priority-encoding loops
# --timing-allow-fail: generate output even if timing not met
#
# PLACER=heap (default): nextpnr analytical placer. REQUIRED for the HW
# lane-serial masked Keccak design — its long CARRY4 chains cannot be legalised
# by the SA placer ("failed to place chain"). HeAP needs the -nowidelut netlist
# (no MUXF chains, set in synth_xilinx above) and a quiet machine; it then places
# + routes the full design in ~11 min (SLICE_LUTX 53%, soc_clk 28 MHz).
# PLACER=sa is bounded-memory (~1.1 GB RSS) but only legalises chain-free designs
# (e.g. HW_KECCAK=0); it FAILS chain legalisation on the HW-Keccak build.
# ============================================================================
PLACER ?= heap
pnr: $(BUILD)/sca_pqc.fasm

$(BUILD)/sca_pqc.fasm: $(BUILD)/sca_pqc.json
	@echo "=== Step 3: nextpnr-xilinx place and route (placer=$(PLACER)) ==="
	$(NEXTPNR) \
		--chipdb $(CHIPDB) \
		--xdc greyhound/cw305_nextpnr.xdc \
		--json $< \
		--fasm $@ \
		--write $(BUILD)/sca_pqc.routed.json \
		--log $(BUILD)/nextpnr.log \
		--freq 20 \
		--timing-allow-fail \
		--ignore-loops \
		--placer $(PLACER) \
		--seed 42
	@echo "  PnR complete."
	@grep -E "Max freq|SLICE_LUT|RAMB36" $(BUILD)/nextpnr.log 2>/dev/null | tail -5 || true

# ============================================================================
# Step 4: Bitstream generation (fasm2frames + xc7frames2bit)
# ============================================================================
bitstream: $(BUILD)/sca_pqc_cw305.bit

$(BUILD)/sca_pqc_cw305.bit: $(BUILD)/sca_pqc.fasm
	@echo "=== Step 4: Bitstream generation ==="
	fasm2frames --part $(PART) --db-root $(PRJXRAY_DB) $< > $(BUILD)/sca_pqc.frames
	$(XC7FRAMES2BIT) \
		--part_file $(PRJXRAY_DB)/$(PART)/part.yaml \
		--part_name $(PART) \
		--frm_file $(BUILD)/sca_pqc.frames \
		--output_file $@
	@echo "  Bitstream: $@ ($$(wc -c < $@) bytes)"

# ============================================================================
# Step 5: Program CW305
# ============================================================================
program: $(BUILD)/sca_pqc_cw305.bit
	@echo "=== Step 5: Program CW305 ==="
	@python3 -c "\
	import chipwhisperer as cw; import time; \
	t = cw.target(None, cw.targets.CW305, fpga_id='35t', bsfile='$<', force=True); \
	t.pll.pll_enable_set(True); t.pll.pll_outenable_set(True, 1); \
	t.pll.pll_outfreq_set(20e6, 1); time.sleep(1); \
	m = int.from_bytes(t.fpga_read(0x06, 4), 'little'); \
	d = int.from_bytes(t.fpga_read(0x0A, 4), 'little'); \
	print(f'  Magic: 0x{m:08X} ({\"SP01\" if m==0x53503031 else \"???\"})');\
	print(f'  Debug: 0x{d:08X} (core_sleep={d&1})'); \
	t.dis(); \
	print('  Programming OK')" 2>&1 | grep -v WARNING

# ============================================================================
# Step 6: Verify (USB registers + optional JTAG readback)
# ============================================================================
# --- KAT mailbox poll (FW=fips203) ---
verify-kat: program
	@python3 $(SCRIPTS)/verify_mailbox.py kat 2>&1 | grep -v WARNING

# --- Masked KAT mailbox poll (FW=fips203_masked) ---
# Expects sentinel 0xCAFE0011 = ALL required masked-path checks PASS.
# Same six checks as `verify-kat` but the decap path uses the SCA-resistant
# masked code (DOM-paired SECMUL_LATCH/REUSE on every cp·s_i, masked NTT/INTT,
# A2B-secured unmask) -- every secret op lowers to a Custom-3 ISE instruction.
verify-kat-masked: program
	@python3 $(SCRIPTS)/verify_mailbox.py kat_masked 2>&1 | grep -v WARNING

# --- ML-DSA-44 KAT mailbox polls (firmware hex from mldsa_work/fw/build/) ---
# Naive: sentinel 0xCAFED5A1.  Masked: sentinel 0xCAFED5B1.
verify-kat-dsa: program
	@python3 $(SCRIPTS)/verify_mailbox.py kat_dsa 2>&1 | grep -v WARNING

verify-kat-dsa-masked: program
	@python3 $(SCRIPTS)/verify_mailbox.py kat_dsa_masked 2>&1 | grep -v WARNING

# --- AES-128 KAT mailbox polls (software-only primitive) ---
# Naive: sentinel 0xCAFEAE51 PASS / 0xCAFEAE52 FAIL ; MBOX[0]==16 bytes match.
# Masked: sentinel 0xCAFEAE61 PASS / 0xCAFEAE62 FAIL ; MBOX[0]==16.
verify-kat-aes: program
	@python3 $(SCRIPTS)/verify_mailbox.py kat_aes 2>&1 | grep -v WARNING

verify-kat-aes-masked: program
	@python3 $(SCRIPTS)/verify_mailbox.py kat_aes_masked 2>&1 | grep -v WARNING

# --- Minimal ISE per-group regression (FW=minimal) ---
verify-minimal: program
	@python3 $(SCRIPTS)/verify_mailbox.py minimal 2>&1 | grep -v WARNING

# --- Per-component cycle benchmark (FW=bench) ---
verify-bench: program
	@python3 $(SCRIPTS)/verify_mailbox.py bench 2>&1 | grep -v WARNING

verify: program
	@echo "=== Step 6: Verify ==="
	@python3 -c "\
	import chipwhisperer as cw; import time; \
	t = cw.target(None, cw.targets.CW305, fpga_id='35t'); \
	m = int.from_bytes(t.fpga_read(0x06, 4), 'little'); \
	i = int.from_bytes(t.fpga_read(0x07, 4), 'little'); \
	d = int.from_bytes(t.fpga_read(0x0A, 4), 'little'); \
	ok = m == 0x53503031 and i == 0x43573035 and (d >> 8) == 0x42ADDE; \
	print(f'  Magic:    0x{m:08X} ({\"PASS\" if m==0x53503031 else \"FAIL\"})'); \
	print(f'  Identify: 0x{i:08X} ({\"PASS\" if i==0x43573035 else \"FAIL\"})'); \
	print(f'  Debug:    0x{d:08X} (core_sleep={d&1})'); \
	print(f'  Sentinel: 0x{(d>>8)&0xFFFFFF:06X} ({\"PASS\" if (d>>8)==0x42ADDE else \"FAIL\"})'); \
	print(f'  OVERALL:  {\"PASS\" if ok else \"FAIL\"}'); \
	t.dis()" 2>&1 | grep -v WARNING

# ============================================================================
# Readback: BT0 via JTAG (requires Vivado + JTAG-HS3 on J4)
# ============================================================================
readback-bt0: | $(READBACK)
	@echo "=== Readback full config (BT0+BT1) via JTAG ==="
	$(VIVADO) -mode tcl -nolog -nojournal \
		-source $(SCRIPTS)/readback_bt0.tcl \
		-tclargs $(READBACK)/sca_pqc
	@echo "  raw: $(READBACK)/sca_pqc_bt0.bin ($$(wc -c < $(READBACK)/sca_pqc_bt0.bin) bytes)"
	@python3 $(SCRIPTS)/split_readback.py \
		$(READBACK)/sca_pqc_bt0.bin $(READBACK)/sca_pqc

# ============================================================================
# Readback: BT1 from FASM (BRAM content extraction)
# ============================================================================
readback-bt1: $(BUILD)/sca_pqc.fasm | $(READBACK)
	@echo "=== Readback BT1 (BRAM Content) from FASM ==="
	python3 $(SCRIPTS)/readback_bt1.py $(BUILD)/sca_pqc.fasm $(READBACK)/sca_pqc

# ============================================================================
# Verify readback against expected values
# ============================================================================
verify-readback: readback-bt0 readback-bt1
	@echo "=== Verify Readback ==="
	python3 $(SCRIPTS)/verify_readback.py \
		$(READBACK)/sca_pqc_bt0.bin \
		$(BUILD)/sca_pqc.fasm \
		$(FW_HEX)

# ============================================================================
# KAT flow: build → program → execute → verify → JTAG bitfile readback
# Single command for the "port + execute + readback" loop.
# ============================================================================
kat-flow:
	$(MAKE) all FW=fips203
	$(MAKE) verify-kat
	$(MAKE) readback-bt0
	@echo ""
	@echo "╔══════════════════════════════════════════════════════╗"
	@echo "║  KAT flow complete                                  ║"
	@echo "║   bitfile : $(BUILD)/sca_pqc_cw305.bit       ║"
	@echo "║   readback: $(READBACK)/sca_pqc_bt0.bin                ║"
	@echo "╚══════════════════════════════════════════════════════╝"

# ============================================================================
# Full pipeline with readback verification
# ============================================================================
full: all program verify-readback
	@echo ""
	@echo "╔══════════════════════════════════════════════════════╗"
	@echo "║  SCA_Pro_PQC — Full Pipeline Complete               ║"
	@echo "║  ✓ Firmware compiled                                ║"
	@echo "║  ✓ Synthesis (Yosys + slang)                        ║"
	@echo "║  ✓ Place & Route (nextpnr-xilinx)                   ║"
	@echo "║  ✓ Bitstream (fasm2frames + xc7frames2bit)          ║"
	@echo "║  ✓ CW305 programmed                                 ║"
	@echo "║  ✓ BT0 + BT1 readback verified                     ║"
	@echo "╚══════════════════════════════════════════════════════╝"

# ============================================================================
# Utility
# ============================================================================
$(BUILD):
	mkdir -p $(BUILD)

$(READBACK):
	mkdir -p $(READBACK)

clean:
	rm -rf $(BUILD) $(READBACK)
	rm -f *.jou *.log .Xil

help:
	@echo "╔══════════════════════════════════════════════════════╗"
	@echo "║  SCA_Pro_PQC — Open-Source FPGA Flow                ║"
	@echo "║  Target: CW305 (XC7A35T-2FTG256) @ 20 MHz          ║"
	@echo "╚══════════════════════════════════════════════════════╝"
	@echo ""
	@echo "Build Pipeline:"
	@echo "  make all              Full build (firmware→synth→pnr→bit)"
	@echo "  make firmware         Compile RISC-V firmware (.hex)"
	@echo "  make synth            Yosys + slang synthesis (.json)"
	@echo "  make pnr              nextpnr-xilinx PnR (.fasm)"
	@echo "  make bitstream        Generate bitstream (.bit)"
	@echo ""
	@echo "Hardware:"
	@echo "  make program          Program CW305 via USB"
	@echo "  make verify           Verify Magic/Debug registers"
	@echo "  make verify-kat       Run FIPS-203 KAT firmware, poll mailbox"
	@echo "  make verify-minimal   Run minimal ISE regression, poll mailbox"
	@echo "  make verify-bench     Run per-component cycle benchmark"
	@echo "  make essential-bits   Static silent-bit analysis from FASM"
	@echo "  make split-readback   Re-split a readback bin into BT0/BT1"
	@echo "  make verify-split     Evidence-based BT0/BT1 split check"
	@echo "  make bit-to-frames    Reverse: .bit -> prjxray .frames"
	@echo "  make frames-to-fasm   Reverse: .frames -> golden .fasm"
	@echo "  make bit-to-fasm      Reverse: .bit -> .frames -> golden .fasm"
	@echo "  make kat-flow         Build + program + execute + JTAG readback"
	@echo ""
	@echo "Readback & Verification:"
	@echo "  make readback-bt0     BT0 config readback via JTAG"
	@echo "  make readback-bt1     BT1 BRAM content from FASM"
	@echo "  make verify-readback  Compare BT0+BT1 against expected"
	@echo ""
	@echo "Full Pipeline:"
	@echo "  make full             Build + program + readback + verify"
	@echo ""
	@echo "  make clean            Remove all build artifacts"
	@echo "  make help             This message"

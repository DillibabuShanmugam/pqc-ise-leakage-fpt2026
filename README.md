# pqc-ise-leakage-fpt2026

Artefact of *Fully Open-Source Accelerator for Unified and Protected ML-KEM-1024 and ML-DSA-44* (FPT 2026):
a 62-instruction CV-X-IF PQC coprocessor on a CV32E40X core, an open Yosys / nextpnr-xilinx / Project X-Ray
flow to a ChipWhisperer CW305 (XC7A100T), and a pre-silicon and post-silicon fixed-versus-random leakage
test of ten selected secret-relevant instructions. Every number of the paper regenerates from the stored traces.

## Layout

| path | content |
|---|---|
| `rtl/` | coprocessor RTL (ISE units, Keccak, masking gadgets, CV-X-IF adapter) |
| `flow/` | SoC sources (`greyhound/`, CV32E40X + OBI), CW305 top, nextpnr constraints, `Makefile` for synth / pnr / bitstream |
| `sw/include/` | instruction macros (`sca_pqc_ise.h`) and MMIO map |
| `firmware/` | operand generator, ten-instruction test firmware, firmware and bitstream build scripts |
| `presilicon/` | Verilator SoC testbench and its build script, boot code and linker script |
| `campaign/sim/` | pre-silicon run script, VCD extractor, stored toggle counts (`SIMS_block*.npy`, 1000 x 12) |
| `campaign/board/` | CW305 capture script and the two stored passes (`traces_tvla3`, `traces_tvla3_pass2`, 1000 x 500 per instruction) |
| `campaign/analysis/` | fixed-versus-random test, controls, cross-domain correlation, `run_all.sh` |
| `protected/` | six-block capture of the protected forms (Table V, Fig. 5) |
| `paper/` | table and figure generators and their outputs |

Tools: Yosys 0.50 (+slang), nextpnr-xilinx with a locally built XC7A100T chip database, Project X-Ray,
Verilator 5.037, riscv64-unknown-elf-gcc, ChipWhisperer 5.6.1, Python 3 with numpy, scipy, matplotlib.

## Capture (one command)

Program the CW305 with the bitstream and record 1000 traces per instruction, ten instructions interleaved:

```
python3 campaign/board/capture_ten_instr.py --bit campaign/board/sca_pqc_cw305_ise10_tvla3.bit \
    --fpga-id 100t --interleaved -n 1000 --samples 500 --gain 15 --freq 16000000 --out campaign/board/traces_tvla3
```

Add `--no-program --out campaign/board/traces_tvla3_pass2` for the second pass. The bitstream is rebuilt with
`firmware/build_fw_tvla_any.sh` (firmware) and `firmware/build_bitstream_tvla3.sh` (synthesis, place and route,
bitstream, about 15 minutes); the firmware image with all ten instruction blocks enters at synthesis.
Pre-silicon traces: `presilicon/build_e40x.sh` once, then `FW=firmware PFX=SIMS campaign/sim/run_tvla_sim_any.sh`
(about one minute per instruction).

## Analysis (one command)

```
campaign/analysis/run_all.sh
```

This prints the fixed-versus-random peaks per domain (Table IV), the four controls per instruction (Table VIII),
the cross-domain correlation with its re-pairing null, and writes the paper tables and figures into `paper/`.
The threshold is 4.5 per column; the shuffled-label null over 500 columns is reported alongside.

## Test design

Per instruction 1000 runs, 500 with a fixed operand and 500 with a random operand, one of each per consecutive
pair in random order. Single-operand instructions vary the secret itself; two-operand instructions hold the secret
constant and vary the public operand. An unmeasured run on one constant operand precedes every measured run.
Welch's t per simulated cycle and per CW305 sample; two board passes scored separately.

## Citation

If you use this design, flow, traces, or analysis, please cite the FPT 2026 paper:

```bibtex
@inproceedings{shanmugam2026fpt,
  author    = {Dillibabu Shanmugam and Patrick Schaumont},
  title     = {Fully Open-Source Accelerator for Unified and Protected {ML-KEM-1024} and {ML-DSA-44}},
  booktitle = {Proc. International Conference on Field Programmable Technology (FPT)},
  publisher = {IEEE},
  address   = {Honolulu, HI, USA},
  month     = dec,
  year      = {2026},
  note      = {To appear},
}
```

D. Shanmugam and P. Schaumont, "Fully open-source accelerator for unified and protected ML-KEM-1024 and ML-DSA-44,"
in Proc. International Conference on Field Programmable Technology (FPT), Honolulu, HI, USA, Dec. 2026, to appear.
A `CITATION.cff` is included; GitHub's "Cite this repository" button gives the same entry.

## Licence

MIT, see `LICENSE`. CV32E40X and the OBI IP under `flow/greyhound/` keep their upstream licences.

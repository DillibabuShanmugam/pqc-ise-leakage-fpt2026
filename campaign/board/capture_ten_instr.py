#!/usr/bin/env python3
"""CW305 capture of the ten custom instructions, ChipWhisperer-Lite.

The design has no host-to-SoC write path, so the firmware sequences itself and
publishes what it is about to execute in the mailbox. The host arms the scope,
waits for the trigger, then reads the mailbox back to label the trace. Every
trace is therefore self-describing and no trigger has to be counted.

  mailbox[0] = block identifier, 1 to 10
  mailbox[2] = operand index within the block
  mailbox[3] = 0xB0A5D0xx, running sentinel with the completed-block count

Ten blocks make the obvious capture order the wrong one. Asking for block k and
discarding everything else means waiting up to a whole firmware cycle -- nine
other blocks of a thousand traces each -- before block k comes round, so
capturing the ten sequentially costs ten cycles instead of one. The interleaved
mode keeps every trace instead and files it under whichever block the mailbox
names, so one pass through the firmware collects all ten at once.

Usage:
  python3 capture_ten_instr.py --bit <bitstream> --interleaved -n 1000 --out traces
  python3 capture_ten_instr.py --bit <bitstream> --block 1 -n 1000 --out traces_b1
  python3 capture_ten_instr.py --bit <bitstream> --all -n 1000 --out traces   (slow)
"""
import argparse, json, os, time
import numpy as np
import chipwhisperer as cw

BLOCK_NAME = {1: "mont_k", 2: "barrett_k", 3: "and_latch", 4: "caddq",
              5: "ntt_bfly_gs_mul", 6: "compress_1", 7: "cbd2_1",
              8: "barrett_d", 9: "mont_d", 10: "decompose"}
REG_MBOX = {0: 0x0B, 1: 0x0C, 2: 0x0D, 3: 0x0E}

def rd(target, n):
    return int.from_bytes(target.fpga_read(REG_MBOX[n], 4), "little")

def setup(a):
    scope = cw.scope()
    scope.gain.db = a.gain
    scope.adc.samples = a.samples
    scope.adc.offset = a.offset
    scope.adc.decimate = a.decimate
    scope.adc.basic_mode = "rising_edge"
    scope.clock.adc_src = "extclk_x4"
    scope.clock.clkgen_freq = a.freq
    scope.trigger.triggers = "tio4"
    scope.io.hs2 = "disabled"
    target = cw.target(None, cw.targets.CW305, fpga_id=a.fpga_id,
                       force=a.program, bsfile=a.bit)
    target.vccint_set(1.0)
    target.pll.pll_enable_set(True)
    target.pll.pll_outenable_set(False, 0)
    target.pll.pll_outenable_set(True, 1)
    target.pll.pll_outenable_set(False, 2)
    target.pll.pll_outfreq_set(a.freq, 1)
    time.sleep(0.5)
    # The ADC clock is derived from the target clock. Programming the FPGA
    # drops that clock, so relock the ADC DCM and verify before any capture;
    # a zero adc_freq here would otherwise fault the first capture.
    for _ in range(20):
        scope.clock.reset_adc()
        time.sleep(0.5)
        if scope.clock.adc_locked and scope.clock.adc_freq > 0:
            break
    print(f"adc locked: {scope.clock.adc_locked}, adc_freq: {scope.clock.adc_freq}")
    assert scope.clock.adc_freq > 0, "ADC clock not locked to the target clock"
    return scope, target

def capture_block(scope, target, want, n, verbose=True):
    """Collect n traces whose mailbox label says they belong to block `want`."""
    traces, idx, t0, miss = [], [], time.time(), 0
    while len(traces) < n:
        scope.arm()
        if scope.capture():
            miss += 1
            if miss > 200:
                raise RuntimeError("no trigger; is the firmware running and TIO4 wired?")
            continue
        blk = rd(target, 0)
        if blk != want:
            continue                      # the firmware is in another block
        traces.append(scope.get_last_trace())
        idx.append(rd(target, 2))
        if verbose and len(traces) % 100 == 0:
            r = len(traces) / max(time.time() - t0, 1e-9)
            print(f"  block {want}: {len(traces)}/{n}  {r:.1f} traces/s", flush=True)
    return np.asarray(traces, np.float32), np.asarray(idx, np.int32)

def capture_interleaved(scope, target, want_per_block, expect=None, verbose=True):
    """Collect every trigger and file it under the block the mailbox names.

    Stops when every expected block has its quota, or when the target stops
    producing traces we can still use.

    `expect` is the set of blocks this firmware actually issues. It matters
    because a firmware that issues a subset, as the fixed-secret build does with
    blocks 1, 3, 5 and 9, would otherwise leave the loop waiting forever on
    blocks that are never going to arrive. Left as None, every block is
    expected, which is the ten-block campaign's behaviour.
    """
    traces = {b: [] for b in BLOCK_NAME}
    idx = {b: [] for b in BLOCK_NAME}
    want = set(BLOCK_NAME) if expect is None else set(expect)
    t0, miss, stale = time.time(), 0, 0
    total_before = 0
    # Triggers that arrive for a block already at quota are counted here. Once
    # the expected blocks are full this is the only thing still happening, so it
    # is what tells us the capture is finished rather than slow.
    idle = 0
    while any(len(traces[b]) < want_per_block for b in want):
        scope.arm()
        if scope.capture():
            miss += 1
            if miss > 500:
                raise RuntimeError("no trigger; is the firmware running and TIO4 wired?")
            continue
        miss = 0
        blk = rd(target, 0)
        if blk not in traces or len(traces[blk]) >= want_per_block:
            idle += 1
            if idle > 2000 and any(len(traces[b]) for b in want):
                if verbose:
                    print("  target is only issuing blocks that are already "
                          "full; stopping with what has been collected",
                          flush=True)
                break
            continue
        idle = 0
        traces[blk].append(scope.get_last_trace())
        idx[blk].append(rd(target, 2))
        total = sum(len(v) for v in traces.values())
        if total % 250 == 0:
            if verbose:
                r = total / max(time.time() - t0, 1e-9)
                done = sum(1 for b in want if len(traces[b]) >= want_per_block)
                print(f"  {total}/{want_per_block * len(want)}  {r:.1f} traces/s  "
                      f"{done}/{len(want)} blocks complete  "
                      + " ".join(f"{b}:{len(traces[b])}" for b in sorted(want)),
                      flush=True)
            stale = 0 if total > total_before else stale + 1
            total_before = total
            if stale > 200:
                raise RuntimeError("no block is gaining traces; target appears stalled")
    return traces, idx


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bit", required=True)
    # 100t, not the 35t default of the six-block script: the campaign bitstream
    # targets xc7a100tftg256-2 and programming it as a 35t silently fails
    ap.add_argument("--fpga-id", default="100t", dest="fpga_id")
    ap.add_argument("--block", type=int, choices=list(BLOCK_NAME))
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--expect", type=int, nargs="*", default=None,
                    help="blocks this firmware issues; defaults to all ten. "
                         "The fixed-secret build issues 1 3 5 9.")
    ap.add_argument("--interleaved", action="store_true",
                    help="one pass, every block filled at once (preferred)")
    ap.add_argument("-n", type=int, default=1000)
    ap.add_argument("--samples", type=int, default=500)
    ap.add_argument("--decimate", type=int, default=1)
    ap.add_argument("--offset", type=int, default=0)
    ap.add_argument("--freq", type=int, default=16000000)
    ap.add_argument("--gain", type=int, default=20)
    ap.add_argument("--no-program", dest="program", action="store_false")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    if not a.all and not a.interleaved and a.block is None:
        ap.error("pass --block N, --all, or --interleaved")
    os.makedirs(a.out, exist_ok=True)
    scope, target = setup(a)
    print("magic:", target.fpga_read(0x06, 4), " ident:", target.fpga_read(0x07, 4))
    sent = rd(target, 3)
    print("sentinel:", hex(sent))
    if (sent & 0xFFFFFF00) not in (0xB0A5D000, 0xA11FE000):
        raise SystemExit(
            "the firmware is not running: the mailbox sentinel should be "
            "0xA11FE0xx or 0xB0A5D0xx. Check that the fetch-enable DIP (K15) is "
            "on and that the bitstream is the ten-block one.")
    if a.interleaved:
        print("capturing all ten blocks in one interleaved pass", flush=True)
        TT, II = capture_interleaved(scope, target, a.n, expect=a.expect)
        for bnum in sorted(TT):
            if not TT[bnum]:
                continue
            T = np.asarray(TT[bnum], np.float32)
            I = np.asarray(II[bnum], np.int32)
            name = BLOCK_NAME[bnum]
            d = os.path.join(a.out, f"block{bnum}_{name}")
            os.makedirs(d, exist_ok=True)
            np.save(os.path.join(d, "traces.npy"), T)
            np.save(os.path.join(d, "operand_index.npy"), I)
            json.dump({"block": bnum, "name": name, "n": int(len(T)),
                       "samples": a.samples, "decimate": a.decimate,
                       "offset": a.offset, "freq": a.freq, "gain": a.gain,
                       "bit": a.bit, "mode": "interleaved"},
                      open(os.path.join(d, "capture.json"), "w"), indent=1)
            print(f"  saved {T.shape} to {d}  ({len(np.unique(I))} distinct operands)")
        scope.dis(); target.dis()
        return

    blocks = list(BLOCK_NAME) if a.all else [a.block]
    for bnum in blocks:
        name = BLOCK_NAME[bnum]
        print(f"capturing block {bnum} ({name})", flush=True)
        T, I = capture_block(scope, target, bnum, a.n)
        d = os.path.join(a.out, f"block{bnum}_{name}")
        os.makedirs(d, exist_ok=True)
        np.save(os.path.join(d, "traces.npy"), T)
        np.save(os.path.join(d, "operand_index.npy"), I)
        json.dump({"block": bnum, "name": name, "n": int(len(T)),
                   "samples": a.samples, "decimate": a.decimate, "offset": a.offset,
                   "freq": a.freq, "gain": a.gain, "bit": a.bit},
                  open(os.path.join(d, "capture.json"), "w"), indent=1)
        print(f"  saved {T.shape} to {d}")
    scope.dis(); target.dis()

if __name__ == "__main__":
    main()

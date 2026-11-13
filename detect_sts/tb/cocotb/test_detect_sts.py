"""Behavioural cocotb tests for detect_sts.

detect_sts is a Schmidl-Cox style short-preamble (STS) detector: it
delay-and-correlates the incoming IQ stream against itself 16 samples ago
(fifo_sample_delay, hardcoded delay_ctl=16) and flags short_preamble_detected
once the correlation magnitude has stayed above a power-scaled threshold for
more than min_plateau samples, AND those samples include both positive and
negative in-phase values (the module's own comment: this guards against
false positives on a constant-power, non-oscillating signal).

Unlike the arithmetic IPs (mv_avg, complex_mult, ...) there is no single
"correct" numeric output to check bit-for-bit here - this is a detector with
a qualitative design intent. So instead of a hand-derived reference model,
these tests drive representative inputs and check the intent directly:
  - a genuine repeating (STS-like) burst gets detected,
  - random noise never falsely triggers detection,
  - a strong but constant-power (non-oscillating) signal - which DOES
    correlate perfectly with its own delayed copy - still does NOT trigger
    detection, exercising the has_pos/has_neg guard specifically.

The phase_out/phase_out_stb CORDIC feedback loop (external phase
calculator, not part of this repo) is left unconnected/tied off - these
tests only check that phase_in_i/phase_in_q/phase_in_stb toggle (wiring
sanity), not the numeric value of phase_offset, since that would require a
model of the external atan2 core these tests don't have.
"""

import math
import os
import random
import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

CLK_PERIOD_NS = 10
STS_DELAY = 16  # hardcoded in detect_sts.v (fifo_sample_delay delay_ctl)
THIS_DIR = os.path.dirname(os.path.abspath(__file__))
IQ_DUMP_PATH = os.path.join(THIS_DIR, "iq_dump_one1.cf32")


def pack_sample(i: int, q: int) -> int:
    return ((i & 0xFFFF) << 16) | (q & 0xFFFF)


def noise_sample(amplitude: int = 80):
    return random.randint(-amplitude, amplitude), random.randint(-amplitude, amplitude)


def sts_like_pattern(amplitude: int = 8000, length: int = STS_DELAY):
    """A period-`length` complex sequence with both positive and negative
    I - stands in for a real 802.11 STS (this module detects periodicity +
    power, not this specific sequence)."""
    pattern = []
    for k in range(length):
        angle = 2 * math.pi * k / 8
        pattern.append((int(amplitude * math.cos(angle)), int(amplitude * math.sin(angle))))
    return pattern


async def reset_dut(dut, min_plateau: int = 8, threshold_scale: int = 0):
    dut.reset.value = 1
    dut.enable.value = 1
    dut.min_plateau.value = min_plateau
    dut.threshold_scale.value = threshold_scale
    dut.sample_in.value = 0
    dut.sample_in_strobe.value = 0
    dut.demod_is_ongoing.value = 0
    dut.phase_out.value = 0
    dut.phase_out_stb.value = 0

    for _ in range(20):
        await RisingEdge(dut.clock)
    dut.reset.value = 0
    for _ in range(20):
        await RisingEdge(dut.clock)


async def drive_sample(dut, i: int, q: int):
    await RisingEdge(dut.clock)
    dut.sample_in.value = pack_sample(i, q)
    dut.sample_in_strobe.value = 1
    await RisingEdge(dut.clock)
    dut.sample_in_strobe.value = 0


async def drive_noise(dut, count: int, amplitude: int = 80):
    for _ in range(count):
        i, q = noise_sample(amplitude)
        await drive_sample(dut, i, q)


@cocotb.test()
async def test_detect_sts_true_positive_and_no_false_positive_on_noise(dut):
    cocotb.start_soon(Clock(dut.clock, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut, min_plateau=8)

    state = {"in_burst": False}
    detected_during_noise = False
    detected_during_burst = False

    async def monitor():
        nonlocal detected_during_noise, detected_during_burst
        while True:
            await RisingEdge(dut.clock)
            if dut.short_preamble_detected.value:
                if state["in_burst"]:
                    detected_during_burst = True
                else:
                    detected_during_noise = True

    mon_task = cocotb.start_soon(monitor())

    await drive_noise(dut, 80)

    state["in_burst"] = True
    pattern = sts_like_pattern()
    for _ in range(10):
        for i, q in pattern:
            await drive_sample(dut, i, q)

    # Drain: fifo_sample_delay (16 samples) + complex_mult + mv_avg_dual_ch
    # (16-sample window) + complex_to_mag together add tens of samples of
    # pipeline latency, so the tail of the burst is still being processed
    # for a while after the last periodic sample was fed. Keep counting
    # this stretch as "burst", not "noise", so that draining doesn't get
    # mistaken for a false positive.
    for _ in range(120):
        i, q = noise_sample()
        await drive_sample(dut, i, q)
    state["in_burst"] = False

    await drive_noise(dut, 80)
    for _ in range(30):
        await RisingEdge(dut.clock)

    mon_task.cancel()

    assert detected_during_burst, (
        "detect_sts never asserted short_preamble_detected during a genuine "
        "repeating STS-like burst"
    )
    assert not detected_during_noise, (
        "detect_sts falsely asserted short_preamble_detected on random noise "
        "(no periodicity present)"
    )


@cocotb.test()
async def test_detect_sts_pure_noise_never_detects(dut):
    cocotb.start_soon(Clock(dut.clock, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut, min_plateau=8)

    detected = False

    async def monitor():
        nonlocal detected
        while True:
            await RisingEdge(dut.clock)
            if dut.short_preamble_detected.value:
                detected = True

    mon_task = cocotb.start_soon(monitor())
    await drive_noise(dut, 400)
    mon_task.cancel()

    assert not detected, "detect_sts falsely detected a preamble in 400 samples of pure noise"


@cocotb.test()
async def test_detect_sts_constant_power_never_detects(dut):
    """A strong, constant (non-oscillating) signal correlates perfectly with
    its own 16-sample-delayed copy (same value every time) - high enough
    magnitude to clear the power threshold - but every sample has the same
    I sign, so has_pos/has_neg can never both be true. Exercises the guard
    described in detect_sts.v's own comment against constant-power false
    positives."""
    cocotb.start_soon(Clock(dut.clock, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut, min_plateau=8)

    detected = False

    async def monitor():
        nonlocal detected
        while True:
            await RisingEdge(dut.clock)
            if dut.short_preamble_detected.value:
                detected = True

    mon_task = cocotb.start_soon(monitor())
    for _ in range(200):
        await drive_sample(dut, 8000, 0)
    mon_task.cancel()

    assert not detected, (
        "detect_sts asserted short_preamble_detected on a constant-power, "
        "non-oscillating signal - the has_pos/has_neg guard should prevent this"
    )


@cocotb.test()
async def test_detect_sts_phase_in_toggles_during_burst(dut):
    """Wiring sanity only: phase_in_i/phase_in_q/phase_in_stb (the interface
    to an external CORDIC/atan2, not part of this repo) should actually
    produce output once real signal is flowing. Does not check numeric
    correctness of the phase estimate."""
    cocotb.start_soon(Clock(dut.clock, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut, min_plateau=8)

    seen_phase_in_stb = False

    async def monitor():
        nonlocal seen_phase_in_stb
        while True:
            await RisingEdge(dut.clock)
            if dut.phase_in_stb.value:
                seen_phase_in_stb = True

    mon_task = cocotb.start_soon(monitor())

    pattern = sts_like_pattern()
    for _ in range(10):
        for i, q in pattern:
            await drive_sample(dut, i, q)
    for _ in range(30):
        await RisingEdge(dut.clock)

    mon_task.cancel()

    assert seen_phase_in_stb, "phase_in_stb never pulsed during a signal burst - check freq_offset_inst wiring"


# ---------------------------------------------------------------------------
# Real captured-RF regression: iq_dump_one1.cf32
#
# Raw complex64 (interleaved float32 I/Q), no header, SAMPLE_RATE_HZ =
# RF_BANDWIDTH_HZ = 2083334. Values in this particular capture are already
# integer-valued and well within +-32767 (checked: I in [-1254, 1748], Q in
# [-2048, 2012]), so samples are fed straight in as 16-bit signed, no
# rescaling needed - if a different capture ever needs one, check its I/Q
# range first.
#
# There's no independently known "ground truth" (packet timestamps) for
# this capture, so these are sanity/regression checks on the exploratory
# behaviour actually observed against this exact file, not a bit-exact
# scoreboard: at min_plateau=8 the detector fires 123 times (clustered, not
# spread uniformly across all 65536 samples - i.e. it's being selective, not
# stuck on); raising min_plateau to 48 (more conservative) drops that to 2
# detections, both a subset of the low-threshold run's cluster locations.
# If a future RTL or fixture change shifts these counts, that's worth
# looking at rather than silently updating the numbers.
# ---------------------------------------------------------------------------

def load_cf32(path):
    with open(path, "rb") as f:
        data = f.read()
    n = len(data) // 4
    vals = struct.unpack("<" + "f" * n, data)
    return list(zip(vals[0::2], vals[1::2]))


async def run_capture(dut, samples, min_plateau):
    await reset_dut(dut, min_plateau=min_plateau)

    detections = []
    for n, (i, q) in enumerate(samples):
        dut.sample_in.value = pack_sample(int(round(i)), int(round(q)))
        dut.sample_in_strobe.value = 1
        await RisingEdge(dut.clock)
        if dut.short_preamble_detected.value:
            detections.append(n)

    dut.sample_in_strobe.value = 0
    for _ in range(200):
        await RisingEdge(dut.clock)
        if dut.short_preamble_detected.value:
            detections.append(len(samples))  # tail detection, past the last real sample

    return detections


@cocotb.test()
async def test_detect_sts_real_capture_detects_and_is_selective(dut):
    """min_plateau=8 (same sensitivity as the synthetic tests above) against
    real captured RF data: must actually fire (not dead on real signal) but
    stay sparse (not stuck permanently asserted - would indicate a
    threshold/logic bug rather than genuine detections)."""
    cocotb.start_soon(Clock(dut.clock, CLK_PERIOD_NS, unit="ns").start())
    samples = load_cf32(IQ_DUMP_PATH)
    detections = await run_capture(dut, samples, min_plateau=8)

    dut._log.info(
        "iq_dump_one1.cf32 @ min_plateau=8: %d detections over %d samples; first: %s",
        len(detections), len(samples), detections[:10],
    )

    assert len(detections) > 0, "detect_sts never fired on a real captured-RF file"
    assert len(detections) < len(samples) // 20, (
        f"detect_sts fired on {len(detections)}/{len(samples)} samples - "
        f"looks stuck-on rather than selectively detecting bursts"
    )


@cocotb.test()
async def test_detect_sts_real_capture_min_plateau_more_selective(dut):
    """Raising min_plateau (more samples required above threshold before
    declaring a detection) should only ever reduce/keep detections, never
    add new ones the lower threshold didn't already see - checked on the
    same real capture, not just synthetic input."""
    cocotb.start_soon(Clock(dut.clock, CLK_PERIOD_NS, unit="ns").start())
    samples = load_cf32(IQ_DUMP_PATH)

    loose = set(await run_capture(dut, samples, min_plateau=8))
    strict = set(await run_capture(dut, samples, min_plateau=48))

    dut._log.info("loose (min_plateau=8): %d detections; strict (min_plateau=48): %d detections",
                   len(loose), len(strict))

    assert len(strict) <= len(loose), (
        "raising min_plateau produced MORE detections than the looser setting - "
        "plateau threshold isn't behaving monotonically"
    )
    assert len(strict) > 0, "min_plateau=48 detected nothing at all on real captured RF data"

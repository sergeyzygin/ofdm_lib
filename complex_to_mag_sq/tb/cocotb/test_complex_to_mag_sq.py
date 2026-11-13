"""Self-checking cocotb test for complex_to_mag_sq.

complex_to_mag_sq computes mag_sq = i^2 + q^2 by feeding (i, q) and
(i, -q) into complex_mult and taking the real part of the product:
    (i + j*q) * (i - j*q) = i^2 + q^2

q = -32768 (INT16_MIN) has no positive 16-bit representation, so the DUT
saturates the negation to +32767 for that one value (see
complex_to_mag_sq.v: `(q == -16'sh8000) ? 16'sh7FFF : (~q+1)`), losing 1 LSB
of precision only in that corner. expected_mag_sq() below mirrors that
saturation so the test verifies the intended (saturated) behaviour rather
than the unreachable exact i^2+q^2.

Same scoreboard-queue approach as test_complex_mult.py: push the expected
value on input_strobe, pop and compare on mag_sq_strobe, independent of the
actual pipeline latency (complex_to_mag_sq's own register stage plus
complex_mult/cmpy_0's latency).

Runs against complex_mult.v and its Verilator-only cmpy_0 stand-in (see
complex_mult/sim_models/cmpy_0.v) - no Vivado license required.
"""

import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cocotb.triggers import with_timeout

CLK_PERIOD_NS = 10
NUM_RANDOM_TX = 300

DIRECTED_CASES = [
    (0, 0),
    (1, 0),
    (0, 1),
    (3, 4),                # 3-4-5 triangle -> 25
    (0x7FFF, 0x7FFF),       # max positive
    (-0x8000, -0x8000),    # q saturates: exercises the INT16_MIN negation corner
    (0x7FFF, -0x8000),     # same corner, mixed sign
]


def to_u16(value: int) -> int:
    return value & 0xFFFF


def to_s32(value: int) -> int:
    value &= 0xFFFF_FFFF
    return value - 0x1_0000_0000 if value & 0x8000_0000 else value


def expected_mag_sq(i: int, q: int) -> int:
    q_neg = 0x7FFF if q == -0x8000 else -q
    return (i * i - q * q_neg) & 0xFFFF_FFFF


async def reset_dut(dut):
    dut.reset.value = 1
    dut.enable.value = 1
    dut.input_strobe.value = 0
    dut.i.value = 0
    dut.q.value = 0

    for _ in range(10):
        await RisingEdge(dut.clock)
    dut.reset.value = 0
    for _ in range(5):
        await RisingEdge(dut.clock)


async def warm_up_dut(dut, beats: int = 5, drain_cycles: int = 8):
    """complex_mult.v (used internally here) masks output_strobe for the
    first few beats after reset, since cmpy_0 has no ARESETN/ACLKEN and its
    DSP48 pipeline powers up undefined - see complex_mult.v's warmup_cnt.
    Feed and discard dummy beats, then wait a few extra cycles: `beats` is
    sized close to where warmed_up flips true (one extra here vs
    test_complex_mult.py, since this DUT's own register stage delays
    input_strobe reaching complex_mult by a cycle), so a trailing dummy beat
    can itself produce a real (unmasked) mag_sq_strobe; without the drain
    wait that strobe arrives after this returns but before the scoreboard
    has anything queued, and check_results() compares it against the wrong
    (first real) expected value."""
    for _ in range(beats):
        await RisingEdge(dut.clock)
        dut.i.value = 0
        dut.q.value = 0
        dut.input_strobe.value = 1
        await RisingEdge(dut.clock)
        dut.input_strobe.value = 0
    for _ in range(drain_cycles):
        await RisingEdge(dut.clock)


async def apply_sample(dut, i: int, q: int, scoreboard: deque):
    await RisingEdge(dut.clock)
    dut.i.value = to_u16(i)
    dut.q.value = to_u16(q)
    dut.input_strobe.value = 1
    scoreboard.append(expected_mag_sq(i, q))

    await RisingEdge(dut.clock)
    dut.input_strobe.value = 0


async def drive_directed(dut, scoreboard: deque):
    for i, q in DIRECTED_CASES:
        await apply_sample(dut, i, q, scoreboard)


async def drive_random(dut, scoreboard: deque, count: int):
    for _ in range(count):
        i = random.randint(-32768, 32767)
        q = random.randint(-32768, 32767)
        await apply_sample(dut, i, q, scoreboard)

        gap = random.randint(0, 3)
        for _ in range(gap):
            await RisingEdge(dut.clock)


async def check_results(dut, scoreboard: deque, expected_count: int):
    checked = 0
    while checked < expected_count:
        await RisingEdge(dut.clock)
        if dut.mag_sq_strobe.value:
            assert scoreboard, "mag_sq_strobe asserted with an empty scoreboard (spurious result)"
            exp = scoreboard.popleft()
            got = int(dut.mag_sq.value) & 0xFFFF_FFFF
            assert got == exp, (
                f"mismatch #{checked}: got mag_sq={to_s32(got)}, expected mag_sq={to_s32(exp)}"
            )
            checked += 1
    return checked


@cocotb.test()
async def test_complex_to_mag_sq_random(dut):
    cocotb.start_soon(Clock(dut.clock, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    await warm_up_dut(dut)

    scoreboard: deque = deque()
    total_tx = len(DIRECTED_CASES) + NUM_RANDOM_TX

    async def driver():
        await drive_directed(dut, scoreboard)
        await drive_random(dut, scoreboard, NUM_RANDOM_TX)

    cocotb.start_soon(driver())
    # Safety timeout: a mis-sized total_tx or a DUT that stops producing
    # results would otherwise hang check_results() forever.
    checked = await with_timeout(
        check_results(dut, scoreboard, total_tx),
        timeout_time=(20 + total_tx * 10) * CLK_PERIOD_NS,
        timeout_unit="ns",
    )

    dut._log.info("complex_to_mag_sq: %d transactions checked, 0 errors", checked)

"""Self-checking cocotb test for complex_mult.

Drives random (and a few directed corner-case) complex samples into the DUT
with randomised gaps between input_strobe pulses, and scoreboards every
result that comes back on output_strobe against a behavioural
(a_i + j*a_q) * (b_i + j*b_q) model computed with 32-bit signed (wrapping)
arithmetic - matching the core's Truncate rounding mode.

Runs against sim_models/cmpy_0.v (a Verilator-only stand-in for the real
Xilinx cmpy_0 IP, see that file's header) so this test needs no Vivado
license and can run in CI. It only exercises the complex_mult wrapper logic
(bit packing/slicing) plus the stand-in's arithmetic - final sign-off against
the real vendor core still happens via tb/complex_mult_tb.v in Vivado/xsim.
"""

import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

CLK_PERIOD_NS = 10
NUM_RANDOM_TX = 300


def to_u16(value: int) -> int:
    return value & 0xFFFF


def to_s16(value: int) -> int:
    value &= 0xFFFF
    return value - 0x10000 if value & 0x8000 else value


def to_s32(value: int) -> int:
    value &= 0xFFFF_FFFF
    return value - 0x1_0000_0000 if value & 0x8000_0000 else value


def expected_product(a_i: int, a_q: int, b_i: int, b_q: int) -> tuple[int, int]:
    p_i = (a_i * b_i - a_q * b_q) & 0xFFFF_FFFF
    p_q = (a_i * b_q + a_q * b_i) & 0xFFFF_FFFF
    return p_i, p_q


async def reset_dut(dut):
    dut.reset.value = 1
    dut.enable.value = 1
    dut.input_strobe.value = 0
    dut.a_i.value = 0
    dut.a_q.value = 0
    dut.b_i.value = 0
    dut.b_q.value = 0

    for _ in range(10):
        await RisingEdge(dut.clock)
    dut.reset.value = 0
    for _ in range(5):
        await RisingEdge(dut.clock)


async def warm_up_dut(dut, beats: int = 4, drain_cycles: int = 8):
    """cmpy_0 has no ARESETN/ACLKEN, so its DSP48 pipeline powers up
    undefined; complex_mult.v masks output_strobe for the first few beats
    after reset until enough valid input has flushed that pipeline (see the
    warmup_cnt/warmed_up logic there). Feed and discard that many dummy
    beats, then wait a few extra cycles - `beats` is chosen to be exactly
    where warmed_up flips true, so the trailing dummy beat(s) right around
    that boundary can themselves produce a real (unmasked) output_strobe;
    without the drain wait that strobe arrives after this returns but before
    the scoreboard has anything queued, and check_results() sees it as a
    spurious result."""
    for _ in range(beats):
        await RisingEdge(dut.clock)
        dut.a_i.value = 0
        dut.a_q.value = 0
        dut.b_i.value = 0
        dut.b_q.value = 0
        dut.input_strobe.value = 1
        await RisingEdge(dut.clock)
        dut.input_strobe.value = 0
    for _ in range(drain_cycles):
        await RisingEdge(dut.clock)


async def apply_sample(dut, a_i: int, a_q: int, b_i: int, b_q: int, scoreboard: deque):
    await RisingEdge(dut.clock)
    dut.a_i.value = to_u16(a_i)
    dut.a_q.value = to_u16(a_q)
    dut.b_i.value = to_u16(b_i)
    dut.b_q.value = to_u16(b_q)
    dut.input_strobe.value = 1
    scoreboard.append(expected_product(a_i, a_q, b_i, b_q))

    await RisingEdge(dut.clock)
    dut.input_strobe.value = 0


async def drive_directed(dut, scoreboard: deque):
    cases = [
        (1, 0, 1, 0),                  # 1 * 1
        (0, 1, 0, 1),                  # j * j = -1
        (0x7FFF, 0x7FFF, 0x7FFF, 0x7FFF),  # max positive
        (0x8000, 0x8000, 0x8000, 0x8000),  # max negative (overflow-prone)
        (0, 0, 0x7FFF, 0x8000),        # zero operand
    ]
    for a_i, a_q, b_i, b_q in cases:
        await apply_sample(dut, a_i, a_q, b_i, b_q, scoreboard)


async def drive_random(dut, scoreboard: deque, count: int):
    for _ in range(count):
        a_i = random.randint(-32768, 32767)
        a_q = random.randint(-32768, 32767)
        b_i = random.randint(-32768, 32767)
        b_q = random.randint(-32768, 32767)
        await apply_sample(dut, a_i, a_q, b_i, b_q, scoreboard)

        gap = random.randint(0, 3)
        for _ in range(gap):
            await RisingEdge(dut.clock)


async def check_results(dut, scoreboard: deque, expected_count: int):
    checked = 0
    while checked < expected_count:
        await RisingEdge(dut.clock)
        if dut.output_strobe.value:
            assert scoreboard, "output_strobe asserted with an empty scoreboard (spurious result)"
            exp_p_i, exp_p_q = scoreboard.popleft()
            got_p_i = int(dut.p_i.value) & 0xFFFF_FFFF
            got_p_q = int(dut.p_q.value) & 0xFFFF_FFFF
            assert got_p_i == exp_p_i and got_p_q == exp_p_q, (
                f"mismatch #{checked}: got p_i={to_s32(got_p_i)} p_q={to_s32(got_p_q)}, "
                f"expected p_i={to_s32(exp_p_i)} p_q={to_s32(exp_p_q)}"
            )
            checked += 1
    return checked


@cocotb.test()
async def test_complex_mult_random(dut):
    cocotb.start_soon(Clock(dut.clock, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    await warm_up_dut(dut)

    scoreboard: deque = deque()
    total_tx = 5 + NUM_RANDOM_TX

    async def driver():
        await drive_directed(dut, scoreboard)
        await drive_random(dut, scoreboard, NUM_RANDOM_TX)

    cocotb.start_soon(driver())
    checked = await check_results(dut, scoreboard, total_tx)

    dut._log.info("complex_mult: %d transactions checked, 0 errors", checked)

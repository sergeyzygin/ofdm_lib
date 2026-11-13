"""Self-checking cocotb tests for complex_to_mag.

complex_to_mag estimates magnitude with the alpha-max-plus-beta-min
approximation (alpha=1, beta=0.25):
    mag = max(|i|, |q|) + (min(|i|, |q|) >> 2)

Pipeline is 3 cycles deep (abs -> max/min -> mag, with input_strobe shifted
through two extra registers to line up with mag_stb). The main test uses the
same scoreboard-queue approach as the other IPs' cocotb tests: push the
expected value on input_strobe, pop and compare on mag_stb, independent of
the exact latency.

A second test specifically checks reset behaviour: complex_to_mag.v's reset
branch clears every pipeline register except `mag_stb` itself, so a reset
asserted while a result is in flight may leave mag_stb stuck at its last
value instead of dropping to 0.
"""

import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly
from cocotb.triggers import RisingEdge
from cocotb.triggers import with_timeout

CLK_PERIOD_NS = 10
NUM_RANDOM_TX = 300
DATA_WIDTH = 16
MASK = (1 << DATA_WIDTH) - 1

DIRECTED_CASES = [
    (0, 0),
    (100, 0),
    (0, 100),
    (100, 100),
    (3, 4),
    (-0x8000, 0),           # INT16_MIN operand - abs() fits unsigned 16 bits fine
    (-0x8000, -0x8000),
    (0x7FFF, 0x7FFF),       # max positive on both
]


def to_u16(value: int) -> int:
    return value & MASK


def abs_u16(value: int) -> int:
    return (-value) & MASK if value < 0 else value


def expected_mag(i: int, q: int) -> int:
    ai = abs_u16(i)
    aq = abs_u16(q)
    mx = max(ai, aq)
    mn = min(ai, aq)
    return (mx + (mn >> 2)) & MASK


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


async def drive_sample(dut, i: int, q: int):
    await RisingEdge(dut.clock)
    dut.i.value = to_u16(i)
    dut.q.value = to_u16(q)
    dut.input_strobe.value = 1

    await RisingEdge(dut.clock)
    dut.input_strobe.value = 0


async def apply_sample(dut, i: int, q: int, scoreboard: deque):
    scoreboard.append(expected_mag(i, q))
    await drive_sample(dut, i, q)


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
        if dut.mag_stb.value:
            assert scoreboard, "mag_stb asserted with an empty scoreboard (spurious result)"
            exp = scoreboard.popleft()
            got = int(dut.mag.value) & MASK
            assert got == exp, f"mismatch #{checked}: got mag={got}, expected mag={exp}"
            checked += 1
    return checked


@cocotb.test()
async def test_complex_to_mag_random(dut):
    cocotb.start_soon(Clock(dut.clock, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    scoreboard: deque = deque()
    total_tx = len(DIRECTED_CASES) + NUM_RANDOM_TX

    async def driver():
        await drive_directed(dut, scoreboard)
        await drive_random(dut, scoreboard, NUM_RANDOM_TX)

    cocotb.start_soon(driver())
    checked = await with_timeout(
        check_results(dut, scoreboard, total_tx),
        timeout_time=(20 + total_tx * 10) * CLK_PERIOD_NS,
        timeout_unit="ns",
    )

    dut._log.info("complex_to_mag: %d transactions checked, 0 errors", checked)


@cocotb.test()
async def test_complex_to_mag_reset_clears_mag_stb(dut):
    """reset should force every pipeline register - including mag_stb - to 0."""
    cocotb.start_soon(Clock(dut.clock, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    # A single one-cycle strobe produces a single one-cycle mag_stb pulse
    # that ends on its own - that wouldn't distinguish "reset cleared it"
    # from "the pulse just ended naturally". Stream input_strobe back-to-back
    # instead so mag_stb settles into a continuous steady state, then assert
    # reset while it's unambiguously still high.
    dut.i.value = to_u16(100)
    dut.q.value = to_u16(100)
    dut.input_strobe.value = 1
    for _ in range(10):
        await RisingEdge(dut.clock)
        if dut.mag_stb.value:
            break
    else:
        raise AssertionError("mag_stb never asserted - can't exercise reset-while-valid")

    await RisingEdge(dut.clock)
    assert dut.mag_stb.value == 1, "test setup issue: mag_stb did not reach a continuous steady state"

    dut.input_strobe.value = 0
    dut.reset.value = 1
    for cycle in range(3):
        await RisingEdge(dut.clock)
        # ReadOnly() waits until this edge's register updates have settled -
        # reading right after RisingEdge alone can race the DUT's own NBA
        # update for the same edge and observe a stale (pre-update) value.
        await ReadOnly()
        assert dut.mag_stb.value == 0, (
            f"mag_stb still asserted {cycle + 1} cycle(s) after reset was raised "
            f"(complex_to_mag.v's reset branch does not clear mag_stb)"
        )
    await RisingEdge(dut.clock)
    dut.reset.value = 0

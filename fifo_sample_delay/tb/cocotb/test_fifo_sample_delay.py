"""Self-checking cocotb tests for fifo_sample_delay.

Pure delay line: once at least `delay_ctl` samples have been written,
every accepted data_in_valid pulse produces exactly one data_out_valid
pulse carrying the sample from `delay_ctl` pushes ago (FIFO-backed shift
register). data_out is treated as an opaque bit pattern here (this module
does no arithmetic on it, unlike mv_avg), so the scoreboard compares raw
values rather than signed ones.

Same scoreboard-queue approach as the other IPs, plus a continuous
(gap-free) streaming test - fifo_sample_delay feeds detect_sts's STS
autocorrelator, which is driven directly from ADC samples (AD9361-style),
so sustained full-rate throughput matters here too.
"""

import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cocotb.triggers import with_timeout

CLK_PERIOD_NS = 10
DATA_WIDTH = 32
LOG2_FIFO_DEPTH = 5
FIFO_DEPTH = 1 << LOG2_FIFO_DEPTH
MASK = (1 << DATA_WIDTH) - 1
NUM_RANDOM_TX = 300


def to_mask(value: int) -> int:
    return value & MASK


class DelayLineModel:
    def __init__(self, delay_ctl: int):
        self.delay_ctl = delay_ctl
        self.history = []

    def push(self, value: int):
        i = len(self.history)
        self.history.append(value)
        if i >= self.delay_ctl:
            return self.history[i - self.delay_ctl]
        return None


async def reset_dut(dut, delay_ctl: int):
    dut.rst.value = 1
    dut.data_in_valid.value = 0
    dut.data_in.value = 0
    dut.delay_ctl.value = delay_ctl

    for _ in range(10):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)


async def apply_sample(dut, value: int, model: DelayLineModel, scoreboard: deque):
    await RisingEdge(dut.clk)
    dut.data_in.value = to_mask(value)
    dut.data_in_valid.value = 1
    expected = model.push(value)
    if expected is not None:
        scoreboard.append(to_mask(expected))

    await RisingEdge(dut.clk)
    dut.data_in_valid.value = 0


async def drive_random(dut, model: DelayLineModel, scoreboard: deque, count: int, gap_max: int = 3):
    for _ in range(count):
        v = random.randint(0, MASK)
        await apply_sample(dut, v, model, scoreboard)

        gap = random.randint(0, gap_max)
        for _ in range(gap):
            await RisingEdge(dut.clk)


async def check_results(dut, scoreboard: deque, expected_count: int):
    checked = 0
    while checked < expected_count:
        await RisingEdge(dut.clk)
        if dut.data_out_valid.value:
            assert scoreboard, "data_out_valid asserted with an empty scoreboard (spurious result)"
            exp = scoreboard.popleft()
            got = to_mask(int(dut.data_out.value))
            assert got == exp, f"mismatch #{checked}: got=0x{got:x} expected=0x{exp:x}"
            checked += 1
    return checked


async def run_random_test(dut, delay_ctl: int, count: int = NUM_RANDOM_TX):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut, delay_ctl)

    model = DelayLineModel(delay_ctl)
    scoreboard: deque = deque()

    # directed: a distinct, easy-to-eyeball ramp before the random stream
    directed = list(range(1, 21))

    async def driver():
        for v in directed:
            await apply_sample(dut, v, model, scoreboard)
        await drive_random(dut, model, scoreboard, count)

    cocotb.start_soon(driver())
    total_tx = len(directed) + count - delay_ctl  # first delay_ctl pushes produce no output
    checked = await with_timeout(
        check_results(dut, scoreboard, total_tx),
        timeout_time=(200 + (total_tx + delay_ctl) * 60) * CLK_PERIOD_NS,
        timeout_unit="ns",
    )
    dut._log.info("fifo_sample_delay (delay_ctl=%d): %d transactions checked, 0 errors", delay_ctl, checked)


@cocotb.test()
async def test_fifo_sample_delay_random_delay16(dut):
    """delay_ctl=16 - matches detect_sts's STS autocorrelation usage."""
    await run_random_test(dut, delay_ctl=16)


@cocotb.test()
async def test_fifo_sample_delay_edge_delays(dut):
    """delay_ctl=1 (minimum) and delay_ctl=FIFO_DEPTH-1 (maximum representable)."""
    await run_random_test(dut, delay_ctl=1, count=100)


@cocotb.test()
async def test_fifo_sample_delay_max_delay(dut):
    await run_random_test(dut, delay_ctl=FIFO_DEPTH - 1, count=100)


@cocotb.test()
async def test_fifo_sample_delay_back_to_back(dut):
    """Stream data_in_valid with zero gaps - continuous ADC-style feed."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    delay_ctl = 16
    await reset_dut(dut, delay_ctl)

    model = DelayLineModel(delay_ctl)
    scoreboard: deque = deque()
    count = FIFO_DEPTH * 4

    async def driver():
        for n in range(count):
            v = (n * 2654435761) & MASK  # cheap deterministic spread
            await RisingEdge(dut.clk)
            dut.data_in.value = to_mask(v)
            dut.data_in_valid.value = 1
            expected = model.push(v)
            if expected is not None:
                scoreboard.append(to_mask(expected))
        await RisingEdge(dut.clk)
        dut.data_in_valid.value = 0

    cocotb.start_soon(driver())
    total_tx = count - delay_ctl
    checked = await with_timeout(
        check_results(dut, scoreboard, total_tx),
        timeout_time=(200 + count * 10) * CLK_PERIOD_NS,
        timeout_unit="ns",
    )
    dut._log.info("fifo_sample_delay back-to-back: %d transactions checked, 0 errors", checked)

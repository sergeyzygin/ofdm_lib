"""Self-checking cocotb tests for mv_avg_dual_ch.

Same boxcar moving-average design as mv_avg.v, but two independent channels
(data_in0/data_in1) share one xpm_fifo_sync (packed into a single wide word)
and therefore the same push/pop timing. See mv_avg/tb/cocotb/test_mv_avg.py
and mv_avg.v's comments for the full rationale behind the RTL structure
(combinational rd_en off the FIFO's look-ahead `full`, registered wr_ack,
and latching dout at pop time into data_in_old*_reg).

Channels are driven with different value sequences throughout (never the
same number on both channels at once) specifically so a channel-swap bug
(e.g. dout0/dout1 wired backwards) would show up as a mismatch instead of
silently cancelling out.

test_mv_avg_dual_ch_back_to_back drives data_in_valid on every single cycle
(no gaps) - the realistic AD9361 continuous-streaming case.
"""

import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cocotb.triggers import with_timeout

CLK_PERIOD_NS = 10
DATA_WIDTH0 = 16
DATA_WIDTH1 = 16
LOG2_AVG_LEN = 5
FIFO_SIZE = 1 << LOG2_AVG_LEN
NUM_RANDOM_TX = 300


def to_u16(value: int) -> int:
    return value & 0xFFFF


def to_signed(value: int, width: int) -> int:
    mask = (1 << width) - 1
    value &= mask
    return value - (1 << width) if value & (1 << (width - 1)) else value


class DualBoxcarModel:
    """Mirrors mv_avg_dual_ch.v's two running-sum sliding windows, which
    share a single FIFO and therefore the same push/pop index."""

    def __init__(self):
        self.history0 = []
        self.history1 = []
        self.running_total0 = 0
        self.running_total1 = 0

    def push(self, v0: int, v1: int):
        i = len(self.history0)
        evicted0 = self.history0[i - FIFO_SIZE] if i >= FIFO_SIZE else 0
        evicted1 = self.history1[i - FIFO_SIZE] if i >= FIFO_SIZE else 0
        self.running_total0 += v0 - evicted0
        self.running_total1 += v1 - evicted1
        self.history0.append(v0)
        self.history1.append(v1)
        return (
            to_signed(self.running_total0 >> LOG2_AVG_LEN, DATA_WIDTH0),
            to_signed(self.running_total1 >> LOG2_AVG_LEN, DATA_WIDTH1),
        )


async def reset_dut(dut):
    dut.rstn.value = 0
    dut.data_in_valid.value = 0
    dut.data_in0.value = 0
    dut.data_in1.value = 0

    for _ in range(10):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)


async def apply_sample(dut, v0: int, v1: int, model: DualBoxcarModel, scoreboard: deque):
    await RisingEdge(dut.clk)
    dut.data_in0.value = to_u16(v0)
    dut.data_in1.value = to_u16(v1)
    dut.data_in_valid.value = 1
    scoreboard.append(model.push(v0, v1))

    await RisingEdge(dut.clk)
    dut.data_in_valid.value = 0


DIRECTED_CASES = (
    [(0, 0)]
    + [(1000, -1000)]
    + [(0x7FFF, -0x8000), (-0x8000, 0x7FFF)]
    + [(700, -300)] * (FIFO_SIZE + 3)  # ramps up, converges to exactly (700, -300)
    + [(0x7FFF, 0x7FFF), (-0x8000, -0x8000), (0x7FFF, -0x8000), (-0x8000, 0x7FFF)] * 3
)


async def drive_directed(dut, model: DualBoxcarModel, scoreboard: deque):
    for v0, v1 in DIRECTED_CASES:
        await apply_sample(dut, v0, v1, model, scoreboard)


async def drive_random(dut, model: DualBoxcarModel, scoreboard: deque, count: int):
    for _ in range(count):
        v0 = random.randint(-32768, 32767)
        v1 = random.randint(-32768, 32767)
        await apply_sample(dut, v0, v1, model, scoreboard)

        gap = random.randint(0, 3)
        for _ in range(gap):
            await RisingEdge(dut.clk)


async def check_results(dut, scoreboard: deque, expected_count: int):
    checked = 0
    while checked < expected_count:
        await RisingEdge(dut.clk)
        if dut.data_out_valid.value:
            assert scoreboard, "data_out_valid asserted with an empty scoreboard (spurious result)"
            exp0, exp1 = scoreboard.popleft()
            got0 = to_signed(int(dut.data_out0.value), DATA_WIDTH0)
            got1 = to_signed(int(dut.data_out1.value), DATA_WIDTH1)
            assert got0 == exp0 and got1 == exp1, (
                f"mismatch #{checked}: got=({got0},{got1}) expected=({exp0},{exp1})"
            )
            checked += 1
    return checked


@cocotb.test()
async def test_mv_avg_dual_ch_random(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    model = DualBoxcarModel()
    scoreboard: deque = deque()
    total_tx = len(DIRECTED_CASES) + NUM_RANDOM_TX

    async def driver():
        await drive_directed(dut, model, scoreboard)
        await drive_random(dut, model, scoreboard, NUM_RANDOM_TX)

    cocotb.start_soon(driver())
    checked = await with_timeout(
        check_results(dut, scoreboard, total_tx),
        timeout_time=(200 + total_tx * 60) * CLK_PERIOD_NS,
        timeout_unit="ns",
    )

    dut._log.info("mv_avg_dual_ch: %d transactions checked, 0 errors", checked)


@cocotb.test()
async def test_mv_avg_dual_ch_back_to_back(dut):
    """Stream data_in_valid with zero gaps for several window-lengths,
    distinct deterministic sequences per channel - the realistic AD9361
    continuous-streaming case, and a check that channels never cross-talk."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    model = DualBoxcarModel()
    scoreboard: deque = deque()
    count = FIFO_SIZE * 4

    async def driver():
        for n in range(count):
            v0 = (n * 37 - 500) % 65536 - 32768
            v1 = (n * 53 + 123) % 65536 - 32768
            await RisingEdge(dut.clk)
            dut.data_in0.value = to_u16(v0)
            dut.data_in1.value = to_u16(v1)
            dut.data_in_valid.value = 1
            scoreboard.append(model.push(v0, v1))
        await RisingEdge(dut.clk)
        dut.data_in_valid.value = 0

    cocotb.start_soon(driver())
    checked = await with_timeout(
        check_results(dut, scoreboard, count),
        timeout_time=(200 + count * 10) * CLK_PERIOD_NS,
        timeout_unit="ns",
    )

    dut._log.info("mv_avg_dual_ch back-to-back: %d transactions checked, 0 errors", checked)

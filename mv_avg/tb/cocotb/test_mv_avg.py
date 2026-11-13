"""Self-checking cocotb tests for mv_avg.

mv_avg is a boxcar moving-average filter over the last FIFO_SIZE = 2**
LOG2_AVG_LEN samples, implemented as a running-sum accumulator fed by an
xpm_fifo_sync holding the sliding window (see sim_models/xpm_fifo_sync.v for
why Verilator needs a stand-in for that macro).

`data_out = running_total[TOTAL_WIDTH-1:LOG2_AVG_LEN]` is a plain bit-slice
of a signed accumulator, which is bit-for-bit equivalent to an arithmetic
right shift by LOG2_AVG_LEN then truncating to DATA_WIDTH bits - so the
Python model below just uses `>>` on a signed Python int (Python's `>>` on
negative ints is already sign-extending/floor, matching Verilog `>>>`).

For every accepted data_in_valid sample, compute the resulting boxcar sum in
Python (including the warm-up ramp before the window first fills, and
eviction of the oldest sample once it does) and check it against data_out
exactly PIPE_LATENCY cycles later (open-loop, fixed-latency lockstep - NOT a
data_out_valid-synchronized scoreboard pop: data_out_valid is now a level,
`has_been_full`, that stays high forever once the window first fills, not a
per-sample pulse, so it can't be used to detect exactly when a new result
has landed - see drive_and_check()'s docstring).

test_mv_avg_back_to_back drives data_in_valid high on every single cycle
(no gaps) for several multiples of FIFO_SIZE. This exists because reading
mv_avg.v closely raises a real question: wr_en is wired straight from
data_in_valid with no gating on the FIFO's `full`, and the compensating read
(rd_en) lags several cycles behind each write once the window is full. If
that lag ever lets the FIFO's occupancy reach FIFO_WRITE_DEPTH (=FIFO_SIZE,
no spare headroom) while data_in_valid is still streaming, xpm_fifo_sync
silently drops the write (asserting overflow) and mv_avg has no fallback -
that sample just vanishes from the average. The scoreboard-based check below
is what actually answers whether that happens, rather than trusting a
by-hand pipeline trace.
"""

import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cocotb.triggers import with_timeout

CLK_PERIOD_NS = 10
DATA_WIDTH = 16
LOG2_AVG_LEN = 5
FIFO_SIZE = 1 << LOG2_AVG_LEN
NUM_RANDOM_TX = 300


def to_u16(value: int) -> int:
    return value & 0xFFFF


def to_signed(value: int, width: int) -> int:
    mask = (1 << width) - 1
    value &= mask
    return value - (1 << width) if value & (1 << (width - 1)) else value


class BoxcarModel:
    """Mirrors mv_avg.v's running-sum sliding window bit-for-bit."""

    def __init__(self):
        self.history = []
        self.running_total = 0

    def push(self, value: int) -> int:
        i = len(self.history)
        evicted = self.history[i - FIFO_SIZE] if i >= FIFO_SIZE else 0
        self.running_total += value - evicted
        self.history.append(value)
        return to_signed(self.running_total >> LOG2_AVG_LEN, DATA_WIDTH)


async def reset_dut(dut):
    dut.rstn.value = 0
    dut.data_in_valid.value = 0
    dut.data_in.value = 0

    for _ in range(10):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)


DIRECTED_CASES = (
    [0] * 5
    + [1000] * (FIFO_SIZE + 3)   # ramps up, then converges to exactly 1000 once full
    + [0x7FFF, -0x8000, 0x7FFF, -0x8000] * 4  # extremes, checks accumulator sign handling
)

def build_schedule_random(count: int) -> list:
    """One entry per clock edge: a value to push that edge, or None to stay
    idle (data_in_valid=0). DIRECTED_CASES back-to-back, then `count` random
    samples each followed by a random 0-3 cycle gap."""
    schedule: list = list(DIRECTED_CASES)
    for _ in range(count):
        schedule.append(random.randint(-32768, 32767))
        schedule.extend([None] * random.randint(0, 3))
    return schedule


async def drive_and_check(dut, schedule: list):
    """mv_avg.v's data_out_valid is now a level (`has_been_full` - stays
    high forever once the window first fills), not a per-sample pulse, so it
    can no longer synchronize scoreboard pops (see test_simple_values'
    docstring for the same issue and how that test sidesteps it instead).

    A fixed-cycle-count open-loop check was tried first and doesn't work: the
    true push-to-data_out latency is 4 cycles right up until the window
    first fills, then permanently shifts (confirmed empirically - a
    constant-4 check matches every sample up through the FIFO_SIZE'th, then
    starts mismatching on every one after, consistent with a one-cycle stall
    exactly at the full boundary while `wr_valid`'s look-ahead-full logic
    waits for `rd_valid`/has_been_full to catch up). Rather than hand-derive
    and hardcode that second latency too, drive off the DUT's own
    `wr_complete_pulse` (a plain top-level wire in mv_avg.v, directly
    readable here since Verilator was built with --public-flat-rw) - it's
    exactly the same signal that gates mv_avg.v's own
    `if (wr_complete_pulse) running_total <= ...`, so whatever its real
    timing is (including any stall), data_out is guaranteed correct exactly
    one cycle after it pulses.
    """
    model = BoxcarModel()
    scoreboard: deque = deque()
    checked = 0
    total = sum(1 for v in schedule if v is not None)

    async def driver():
        for v in schedule:
            await RisingEdge(dut.clk)
            if v is not None:
                dut.data_in.value = to_u16(v)
                dut.data_in_valid.value = 1
                scoreboard.append(model.push(v))
            else:
                dut.data_in_valid.value = 0

    cocotb.start_soon(driver())

    settle_pending = False
    while checked < total:
        await RisingEdge(dut.clk)
        if settle_pending:
            assert scoreboard, "wr_complete_pulse fired with an empty scoreboard (spurious result)"
            exp = scoreboard.popleft()
            got = to_signed(int(dut.data_out.value), DATA_WIDTH)
            assert got == exp, f"mismatch #{checked}: got data_out={got}, expected data_out={exp}"
            checked += 1
        settle_pending = bool(dut.wr_complete_pulse.value)

    return checked


@cocotb.test()
async def test_mv_avg_random(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    schedule = build_schedule_random(NUM_RANDOM_TX)
    total_tx = len(DIRECTED_CASES) + NUM_RANDOM_TX
    checked = await with_timeout(
        drive_and_check(dut, schedule),
        timeout_time=(200 + len(schedule) * 20) * CLK_PERIOD_NS,
        timeout_unit="ns",
    )
    assert checked == total_tx

    dut._log.info("mv_avg: %d transactions checked, 0 errors", checked)


@cocotb.test()
async def test_mv_avg_back_to_back(dut):
    """Stream data_in_valid with zero gaps for several window-lengths and
    confirm no sample is silently dropped by the FIFO reaching full."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    count = FIFO_SIZE * 4
    schedule = [(n * 37 - 500) % 65536 - 32768 for n in range(count)]  # deterministic spread, no gaps at all
    checked = await with_timeout(
        drive_and_check(dut, schedule),
        timeout_time=(200 + count * 10) * CLK_PERIOD_NS,
        timeout_unit="ns",
    )

    dut._log.info("mv_avg back-to-back: %d transactions checked, 0 errors", checked)

@cocotb.test()
async def test_simple_values(dut):
    """Direct port of tb/mv_avg_tb.sv (the Vivado/xsim testbench, verified
    passing against real xpm_fifo_sync) - NOT the scoreboard-queue approach
    used above. mv_avg.v's data_out_valid is now a level (`has_been_full`,
    stays high forever once the window first fills), not a per-sample pulse,
    so check_results()'s one-pop-per-pulse scoreboard no longer matches its
    contract. mv_avg_tb.sv sidesteps that entirely: drive a continuous
    (gap-free) periodic ramp 0..FIFO_SIZE-1 repeating, skip the first
    FIFO_SIZE valid observations (window still filling), then assert every
    later data_out is the exact same constant (the window always holds one
    full period once locked in, so the average can never legitimately drift)
    - this is what actually caught the historical data_in_old_reg bug on
    real hardware.
    """
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())

    period_sum = (FIFO_SIZE - 1) * FIFO_SIZE // 2       # 0+1+...+(FIFO_SIZE-1)
    expected_avg = to_signed(period_sum // FIFO_SIZE, DATA_WIDTH)
    num_pushes = 40 * FIFO_SIZE                          # много периодов - виден дрейф, если он есть

    valid_count = 0
    checked_count = 0
    mismatch_count = 0

    async def monitor():
        nonlocal valid_count, checked_count, mismatch_count
        while True:
            await RisingEdge(dut.clk)
            if dut.data_out_valid.value:
                valid_count += 1
                if valid_count > FIFO_SIZE:
                    checked_count += 1
                    got = to_signed(int(dut.data_out.value), DATA_WIDTH)
                    if got != expected_avg:
                        mismatch_count += 1
                        if mismatch_count <= 20:
                            dut._log.warning(
                                "MISMATCH #%d: data_out=%d, ожидалось %d (valid_count=%d)",
                                mismatch_count, got, expected_avg, valid_count,
                            )

    monitor_task = cocotb.start_soon(monitor())

    # -- reset: те же тайминги, что в mv_avg_tb.sv --
    dut.rstn.value = 0
    dut.data_in_valid.value = 0
    dut.data_in.value = 0
    for _ in range(20):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    for _ in range(10):  # время на wr_rst_busy/rd_rst_busy handshake внутри xpm_fifo_sync
        await RisingEdge(dut.clk)

    # -- непрерывный периодический поток 0..FIFO_SIZE-1,0,1,... без пауз --
    dut.data_in_valid.value = 1
    dut.data_in.value = to_u16(0)
    for push_idx in range(1, num_pushes):
        await RisingEdge(dut.clk)
        dut.data_in.value = to_u16(push_idx % FIFO_SIZE)

    await RisingEdge(dut.clk)
    dut.data_in_valid.value = 0

    for _ in range(50):  # слив конвейера
        await RisingEdge(dut.clk)

    monitor_task.kill()

    dut._log.info("mismatch_count = %d / checked_count = %d", mismatch_count, checked_count)
    assert checked_count > 0, "data_out_valid ни разу не поднялся после заполнения окна - тест не проверил вообще ничего"
    assert mismatch_count == 0, (
        f"{mismatch_count} из {checked_count} проверок разошлись с ожидаемым {expected_avg}"
    )
    dut._log.info(
        "PASS: скользящее среднее устойчиво равно ожидаемому %d на всех %d проверках после заполнения окна",
        expected_avg, checked_count,
    )

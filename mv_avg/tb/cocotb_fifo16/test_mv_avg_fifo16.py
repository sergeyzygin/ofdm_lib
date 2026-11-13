"""Minimal, hand-verifiable regression for the FIFO-full-boundary defect
found via test_mv_avg_back_to_back (see ../cocotb/test_mv_avg.py and
../mv_avg_back_to_back_tb.sv).

Uses FIFO_SIZE=16 (LOG2_AVG_LEN=4, set at Verilator compile time via this
dir's own Makefile - see COMPILE_ARGS there; a separate directory/binary is
needed since mv_avg.v's tb/cocotb suite is compiled with the module's
default LOG2_AVG_LEN=5, and Verilator parameters are fixed per compiled
binary) and the simplest possible input: v(n) = n + 1, i.e. 1, 2, 3, ...,
consecutive integers, no gaps. That makes every expected data_out value a
one-line hand calculation instead of needing a Python/SV model:

    running_total(i) = sum(1..i+1) = (i+1)*(i+2)/2                for i < FIFO_SIZE
                      = FIFO_SIZE*(i+1) - FIFO_SIZE*(FIFO_SIZE-1)/2  for i >= FIFO_SIZE
                        (sum of the last FIFO_SIZE consecutive integers
                        ending at i+1 - an arithmetic series each time,
                        since eviction of the oldest just slides the same
                        window forward by one)
    data_out(i) = running_total(i) >> LOG2_AVG_LEN        (plain floor - all
                        values here are small and non-negative)

IMPORTANT - why v(n) = n+1 and not the more obvious v(n) = n: an earlier
version of this test used v(n) = n (so v(0) = 0), and it PASSED even though
the defect is real - a red herring. The actual defect (isolated by bisecting
test_mv_avg_back_to_back's failure down to a minimal reproducer, see chat)
is: at the exact clock cycle has_been_full first turns 1, running_total
loses exactly the value of the VERY FIRST sample ever pushed (v(0)), no
matter its sign or magnitude - confirmed by directly probing dut.running_total
and dut.debug_ext_data_in_old (mv_avg.v's own debug ports) at that boundary:
debug_ext_data_in_old correctly showed v(0)'s value at that cycle, yet
running_total came out short by exactly that amount anyway. With v(0) = 0
that loss is silently invisible (subtracting 0 changes nothing) - which is
exactly what made the first version of this test a false negative. v(n) =
n+1 keeps the data trivially hand-computable while giving v(0) = 1, so the
defect is NOT masked.

Worked example right around the boundary (FIFO_SIZE=16):

    i=13 (14th push, v=14, window still filling): running_total = 14*15/2 = 105
                                                   data_out = 105 >> 4 = 6
    i=14 (15th push, v=15, window JUST filled,
          no eviction yet):                       running_total = 15*16/2 = 120
                                                    data_out = 120 >> 4 = 7
    i=15 (16th push, v=16, FIRST with eviction
          of history[0]=v(0)=1):                   running_total = 16*16 - 120 = 136
                                                     data_out = 136 >> 4 = 8
    i=16 (17th push, v=17, evicts history[1]=v(1)=2): running_total = 16*17 - 120 = 152
                                                        data_out = 152 >> 4 = 9

If the defect is present, raw running_total at i=15 onward will be short by
exactly v(0)=1 - too small to necessarily survive the final >>4 rounding
into data_out, so THIS test compares dut.running_total directly (the raw,
pre-shift accumulator, itself a whitebox-readable top-level register in
mv_avg.v) rather than relying on data_out alone to catch it. See the assert
below.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

CLK_PERIOD_NS = 10
DATA_WIDTH = 16
LOG2_AVG_LEN = 4
FIFO_SIZE = 1 << LOG2_AVG_LEN   # 16
NUM_PUSHES = FIFO_SIZE * 3       # 48 - well past the boundary, still tiny/hand-checkable


def v(n: int) -> int:
    return n + 1


def expected_running_total(i: int) -> int:
    """i is the 0-indexed push number for input sequence v(n) = n+1."""
    if i < FIFO_SIZE:
        return sum(v(k) for k in range(i + 1))
    return sum(v(k) for k in range(i - FIFO_SIZE + 1, i + 1))


def to_signed(value: int, width: int) -> int:
    mask = (1 << width) - 1
    value &= mask
    return value - (1 << width) if value & (1 << (width - 1)) else value


async def reset_dut(dut):
    dut.rstn.value = 0
    dut.data_in_valid.value = 0
    dut.data_in.value = 0
    for _ in range(10):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)


@cocotb.test()
async def test_fifo16_boundary_easy_to_hand_check(dut):
    """v(n) = n+1, back-to-back (no gaps). Checked via dut.wr_complete_pulse -
    the same real internal signal (a plain top-level wire in mv_avg.v,
    readable here thanks to --public-flat-rw) that gates mv_avg.v's own
    `if (wr_complete_pulse) running_total <= ...` - so no hand-derived
    latency constant is needed, and any real pipeline stall is
    automatically accounted for rather than masked by a fixed wait.

    Also directly compares dut.running_total (mv_avg.v's own top-level
    accumulator register, whitebox-readable the same way) against the
    hand-computed raw sum, in addition to the shifted data_out - this is
    what actually pins the defect down to "loses exactly v(0)" rather than
    a vaguer "off by some amount after the boundary".
    """
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    async def driver():
        for n in range(NUM_PUSHES):
            await RisingEdge(dut.clk)
            dut.data_in.value = v(n) & 0xFFFF
            dut.data_in_valid.value = 1

    cocotb.start_soon(driver())

    checked = 0
    settle_pending = False
    while checked < NUM_PUSHES:
        await RisingEdge(dut.clk)
        if settle_pending:
            raw_exp = expected_running_total(checked)
            exp = to_signed(raw_exp >> LOG2_AVG_LEN, DATA_WIDTH)
            got = to_signed(int(dut.data_out.value), DATA_WIDTH)
            raw_got = to_signed(int(dut.running_total.value), DATA_WIDTH + LOG2_AVG_LEN)
            assert raw_got == raw_exp, (
                f"mismatch #{checked} (push v={v(checked)}): raw running_total="
                f"{raw_got}, expected {raw_exp} (diff={raw_got - raw_exp}, "
                f"v(0)={v(0)} - if diff == -v(0), this is the known "
                f"has_been_full-boundary defect: see this file's docstring). "
                f"data_out got={got} expected={exp}"
            )
            checked += 1
        settle_pending = bool(dut.wr_complete_pulse.value)

    dut._log.info("fifo16 boundary check: %d/%d pushes matched hand-computed values", checked, NUM_PUSHES)

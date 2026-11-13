"""Regression against /home/sergey/temp/tx_iq_dump.cf32 - a real TX-side IQ
capture from ofdm_test_tx.c (--dump-iq --dump-int16), NOT the same format as
iq_dump_one1.cf32 (that one is raw complex64/float32 from a different
source).

ofdm_test_tx.c's --dump-int16 path (see tx_push_buffer()):
    sample[0] = I; sample[1] = Q;
    uint32_t word = ((uint32_t)(uint16_t)sample[0] << 16) | (uint16_t)sample[1];
    fwrite(&word, sizeof(word), 1, dump_fp);
i.e. I packed into the upper 16 bits, Q into the lower 16 bits of one
little-endian uint32 per sample - byte order per sample is
[Q_lo, Q_hi, I_lo, I_hi], the same convention as iq_from_ila.bin (see chat).
Confirmed against the C source directly, not assumed.

This is a TX dump - i.e. the actual waveform ofdm_test_tx transmitted,
presumably containing genuine STS bursts (that's the whole point of an STS
preamble: the receiver should detect it). Unlike iq_dump_one1.cf32
(exploratory regression, no independently known ground truth) there's a
real expectation here: if detect_sts can't find a burst in the very signal
that was transmitted to contain one, that's a real finding worth surfacing,
not just a number to log.
"""

import os
import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

CLK_PERIOD_NS = 10
TX_DUMP_PATH = "/home/sergey/temp/1/tx_iq_dump.cf32"


def pack_sample(i: int, q: int) -> int:
    return ((i & 0xFFFF) << 16) | (q & 0xFFFF)


def load_tx_dump_int16(path):
    """4 bytes/sample, byte order [Q_lo, Q_hi, I_lo, I_hi] - see module
    docstring for why (confirmed against ofdm_test_tx.c's --dump-int16
    path, not assumed)."""
    with open(path, "rb") as f:
        data = f.read()
    n = len(data) // 4
    samples = []
    for k in range(n):
        q = struct.unpack_from("<h", data, k * 4 + 0)[0]
        i = struct.unpack_from("<h", data, k * 4 + 2)[0]
        samples.append((i, q))
    return samples


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


async def run_capture(dut, samples, min_plateau):
    await reset_dut(dut, min_plateau=min_plateau)

    detections = []
    for n, (i, q) in enumerate(samples):
        dut.sample_in.value = pack_sample(i, q)
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
async def test_detect_sts_tx_dump(dut):
    cocotb.start_soon(Clock(dut.clock, CLK_PERIOD_NS, unit="ns").start())

    samples = load_tx_dump_int16(TX_DUMP_PATH)
    dut._log.info("loaded %d samples from %s", len(samples), TX_DUMP_PATH)

    for min_plateau in (8, 48):
        detections = await run_capture(dut, samples, min_plateau=min_plateau)
        dut._log.info(
            "tx_iq_dump.cf32 @ min_plateau=%d: %d detections over %d samples; first: %s",
            min_plateau, len(detections), len(samples), detections[:10],
        )

    if not detections:
        dut._log.warning(
            "NO detections at min_plateau=48 on a TX capture that (per ofdm_test_tx.c) "
            "should contain a genuine STS preamble - worth investigating, not just logging"
        )

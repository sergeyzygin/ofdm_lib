TOPLEVEL := fifo_sample_delay
COCOTB_TEST_MODULES := test_fifo_sample_delay

# fifo_sample_delay.v инстанцирует xpm_fifo_sync - настоящий XPM-макрос
# Verilator не соберёт, используем ту же поведенческую замену, что и для
# mv_avg (идентичный файл).
VERILOG_SOURCES := \
    $(abspath ../../src/fifo_sample_delay.v) \
    $(abspath ../../sim_models/xpm_fifo_sync.v)

# module defaults (DATA_WIDTH=8, LOG2_FIFO_DEPTH=7) don't match how
# detect_sts actually instantiates this IP - override to match real usage.
EXTRA_ARGS += -GDATA_WIDTH=32 -GLOG2_FIFO_DEPTH=5

include ../../../scripts/cocotb_common.mk

TOPLEVEL := mv_avg
COCOTB_TEST_MODULES := test_mv_avg

# mv_avg.v инстанцирует xpm_fifo_sync - настоящий XPM-макрос Verilator не
# соберёт (см. заголовок sim_models/xpm_fifo_sync.v), используем
# поведенческую замену для теста.
VERILOG_SOURCES := \
    $(abspath ../../src/mv_avg.v) \
    $(abspath ../../sim_models/xpm_fifo_sync.v)

include ../../../scripts/cocotb_common.mk

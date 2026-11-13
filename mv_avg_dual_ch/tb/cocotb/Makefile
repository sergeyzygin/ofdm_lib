TOPLEVEL := mv_avg_dual_ch
COCOTB_TEST_MODULES := test_mv_avg_dual_ch

# mv_avg_dual_ch.v инстанцирует xpm_fifo_sync - настоящий XPM-макрос
# Verilator не соберёт, используем поведенческую замену (тот же файл, что и
# для mv_avg - логика идентична, отличаются только ширины на стороне
# mv_avg_dual_ch.v).
VERILOG_SOURCES := \
    $(abspath ../../src/mv_avg_dual_ch.v) \
    $(abspath ../../sim_models/xpm_fifo_sync.v)

include ../../../scripts/cocotb_common.mk

TOPLEVEL := mv_avg
COCOTB_TEST_MODULES := test_mv_avg_fifo16

# mv_avg.v инстанцирует xpm_fifo_sync - настоящий XPM-макрос Verilator не
# соберёт, используем поведенческую замену (см. sim_models/xpm_fifo_sync.v).
VERILOG_SOURCES := \
    $(abspath ../../src/mv_avg.v) \
    $(abspath ../../sim_models/xpm_fifo_sync.v)

# Отдельная директория именно из-за этой строки: LOG2_AVG_LEN - параметр
# elaboration-времени Verilator'а, единый на весь скомпилированный бинарник,
# так что его нельзя переопределить только для одного теста внутри уже
# существующего tb/cocotb (там весь набор собран под LOG2_AVG_LEN=5, default
# самого mv_avg.v). FIFO_SIZE=16 выбран специально маленьким и легко
# пересчитываемым вручную - см. docstring test_mv_avg_fifo16.py.
COMPILE_ARGS += -GLOG2_AVG_LEN=4

include ../../../scripts/cocotb_common.mk

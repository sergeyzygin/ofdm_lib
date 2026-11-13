# Общий Makefile-фрагмент для cocotb+Verilator тестов.
# Подключается из <ip_name>/tb/cocotb/Makefile через:
#   include ../../../scripts/cocotb_common.mk
#
# Каждый IP задаёт перед include только:
#   TOPLEVEL         - имя top-модуля для симуляции
#   MODULE           - имя python-модуля с тестами (test_<ip_name>.py)
#   VERILOG_SOURCES  - список .v файлов (src/ + sim_models/)

SIM ?= verilator
TOPLEVEL_LANG ?= verilog

EXTRA_ARGS += --trace --trace-structs -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE

COCOTB_HDL_TIMEUNIT ?= 1ns
COCOTB_HDL_TIMEPRECISION ?= 1ps

include $(shell cocotb-config --makefiles)/Makefile.sim

TOPLEVEL := complex_to_mag_sq
COCOTB_TEST_MODULES := test_complex_to_mag_sq

# complex_to_mag_sq инстанцирует complex_mult напрямую - исходники
# переиспользуются по пути (не копия: копия нужна только при упаковке IP,
# см. scripts/package_ip.tcl), а cmpy_0 внутри complex_mult подменяется
# той же Verilator-моделью, что и в тестах complex_mult.
VERILOG_SOURCES := \
    $(abspath ../../src/complex_to_mag_sq.v) \
    $(abspath ../../../complex_mult/src/complex_mult.v) \
    $(abspath ../../../complex_mult/sim_models/cmpy_0.v)

include ../../../scripts/cocotb_common.mk

TOPLEVEL := complex_to_mag_sq
COCOTB_TEST_MODULES := test_complex_to_mag_sq

# complex_to_mag_sq инстанцирует complex_mult напрямую - исходники
# переиспользуются по пути (не копия: копия нужна только при упаковке IP,
# см. scripts/package_ip.tcl). complex_mult - чистый RTL, vendor-моделей
# (cmpy_0) не требует.
VERILOG_SOURCES := \
    $(abspath ../../src/complex_to_mag_sq.v) \
    $(abspath ../../../complex_mult/src/complex_mult.v)

include ../../../scripts/cocotb_common.mk

TOPLEVEL := detect_sts
COCOTB_TEST_MODULES := test_detect_sts

# detect_sts.v сшивает несколько уже готовых IP этого репозитория. Берём их
# исходники напрямую по пути (не копии - копии нужны только при упаковке,
# см. scripts/package_ip.tcl) плюс ОДИН экземпляр каждой поведенческой
# Verilator-модели вендорских ядер (cmpy_0, xpm_fifo_sync) - несколько копий
# с одинаковым именем модуля Verilator не даст слинковать.
VERILOG_SOURCES := \
    $(abspath ../../src/detect_sts.v) \
    $(abspath ../../../complex_to_mag_sq/src/complex_to_mag_sq.v) \
    $(abspath ../../../complex_mult/src/complex_mult.v) \
    $(abspath ../../../complex_mult/sim_models/cmpy_0.v) \
    $(abspath ../../../mv_avg/src/mv_avg.v) \
    $(abspath ../../../mv_avg_dual_ch/src/mv_avg_dual_ch.v) \
    $(abspath ../../../mv_avg/sim_models/xpm_fifo_sync.v) \
    $(abspath ../../../fifo_sample_delay/src/fifo_sample_delay.v) \
    $(abspath ../../../complex_to_mag/src/complex_to_mag.v)

include ../../../scripts/cocotb_common.mk

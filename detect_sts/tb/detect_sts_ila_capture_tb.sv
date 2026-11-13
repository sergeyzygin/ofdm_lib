`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Vivado/xsim-тестбенч для detect_sts на РЕАЛЬНОМ IQ, снятом через ILA на
// живом железе (/home/sergey/work/modem_dev/PL_test1/AD936X_PL/razn/
// iq_from_ila.bin, см. чат) - в отличие от detect_sts_real_capture_tb.sv
// (iq_dump_one1.cf32, raw complex64/float32) формат ДРУГОЙ: сырой бинарник,
// БЕЗ заголовка, 4 байта на комплексный отсчёт, little-endian, порядок байт
// [Q_lo, Q_hi, I_lo, I_hi] - т.е. уже готовые signed [15:0] значения прямо
// из data_0/data_1 АЦП, никакого float->int пересчёта не нужно (несмотря на
// то что похожий загрузчик в system_zn_modem_tools_0_0_tb.sv тоже так
// делает - тот же формат байт, тот же приём).
//
// В этом файле нет независимо известного числа срабатываний (в отличие от
// iq_dump_one1.cf32, где cocotb дал эталон 123/2) - это ПЕРВЫЙ прогон на
// этих данных, поэтому тест не проверяет конкретное число, а только:
//   - вообще ли срабатывает при щадящем пороге (min_plateau=8, тот же, что
//     и "loose"-порог в остальных тестах на этом репозитории);
//   - остаётся ли выборочным (не залипает "всегда 1");
//   - монотонность: min_plateau=48 не должен дать БОЛЬШЕ срабатываний, чем
//     min_plateau=8.
// Числа просто печатаются в лог - интерпретация (совпадает ли с тем, что
// реально ожидалось увидеть при захвате через ILA) - на усмотрение
// пользователя, у теста для этого недостаточно контекста.
//////////////////////////////////////////////////////////////////////////////////

module detect_sts_ila_capture_tb;

    localparam CLK_PERIOD = 10;                  // 100 MHz, как в остальных detect_sts тестбенчах
    //localparam IQ_FILE = "/home/sergey/work/modem_dev/PL_test1/AD936X_PL/razn/iq_from_ila.bin";
    //localparam IQ_FILE = "/home/sergey/temp/tx_iq_dump.cf32";
    localparam IQ_FILE = "/home/sergey/temp/1/tx_iq_dump.cf32"; // ofdm_test_tx -M 32 (see chat: period-16 STS, matches detect_sts.v's hardcoded delay_ctl=16)
    localparam NUM_SAMPLES_MAX = 65536;           // с запасом - реальный файл здесь всего 2516 отсчётов

    reg clock = 0;
    always #(CLK_PERIOD/2) clock = ~clock;

    reg         reset = 1;
    reg         enable = 1;
    reg  [31:0] min_plateau = 8;
    reg         threshold_scale = 0;
    reg  [31:0] sample_in = 0;
    reg         sample_in_strobe = 0;
    reg         demod_is_ongoing = 0;
    wire        short_preamble_detected;
    reg  [15:0] phase_out = 0;
    reg         phase_out_stb = 0;
    wire [31:0] phase_in_i;
    wire [31:0] phase_in_q;
    wire        phase_in_stb;
    wire signed [15:0] phase_offset;
    
    wire [31:0] debug_mag_sq;
    wire [31:0] debug_mag_sq_avg;
    wire [31:0] debug_sample_delayed;
    wire [63:0] debug_prod;
    wire [63:0] debug_prod_avg;
    wire [31:0] debug_sample_delayed_conj;


    detect_sts dut (
        .clock(clock),
        .reset(reset),
        .enable(enable),
        .min_plateau(min_plateau),
        .threshold_scale(threshold_scale),
        .sample_in(sample_in),
        .sample_in_strobe(sample_in_strobe),
        .demod_is_ongoing(demod_is_ongoing),
        .short_preamble_detected(short_preamble_detected),
        .phase_out(phase_out),
        .phase_out_stb(phase_out_stb),
        .phase_in_i(phase_in_i),
        .phase_in_q(phase_in_q),
        .phase_in_stb(phase_in_stb),
        .phase_offset(phase_offset),
        ////
        .debug_mag_sq(debug_mag_sq),
        .debug_mag_sq_avg(debug_mag_sq_avg),
        .debug_sample_delayed(debug_sample_delayed),
        .debug_prod(debug_prod),
        .debug_prod_avg(debug_prod_avg),
        .debug_sample_delayed_conj(debug_sample_delayed_conj)
        
    );

    // -----------------------------------------------------------------
    // Загрузка iq_from_ila.bin: сырые int16, БЕЗ float-конвертации.
    // Порядок байт на комплексный отсчёт (4 байта): [Q_lo, Q_hi, I_lo, I_hi].
    // -----------------------------------------------------------------
    reg  [7:0]        file_bytes [0:NUM_SAMPLES_MAX*4-1];
    reg signed [15:0] sample_i   [0:NUM_SAMPLES_MAX-1];
    reg signed [15:0] sample_q   [0:NUM_SAMPLES_MAX-1];
    integer           num_samples;

    initial begin : load_iq_file
        integer fd, bytes_read, n;

        fd = $fopen(IQ_FILE, "rb");
        if (fd == 0) begin
            $display("ERROR: не удалось открыть %s", IQ_FILE);
            $finish;
        end
        bytes_read = $fread(file_bytes, fd);
        $fclose(fd);

        num_samples = bytes_read / 4;
        if (num_samples > NUM_SAMPLES_MAX)
            num_samples = NUM_SAMPLES_MAX;

        for (n = 0; n < num_samples; n = n + 1) begin
            sample_q[n] = {file_bytes[n*4+1], file_bytes[n*4+0]}; // Q = {hi,lo}
            sample_i[n] = {file_bytes[n*4+3], file_bytes[n*4+2]}; // I = {hi,lo}
        end

        $display("[%0t] загружено %0d байт = %0d комплексных отсчётов из %s",
                  $time, bytes_read, num_samples, IQ_FILE);
    end

    // -----------------------------------------------------------------
    // Один прогон файла целиком при заданном min_plateau - см.
    // detect_sts_real_capture_tb.sv для полного пояснения методики
    // (1:1 повтор run_capture() из cocotb: непрерывный поток, 200 тактов
    // слива в конце, каждый такт с высоким short_preamble_detected -
    // отдельное "срабатывание").
    // -----------------------------------------------------------------
    integer detections_count;

    // DIAG: печатаем внутренние сигналы detect_sts.v (white-box иерархические
    // ссылки - тестбенч инстанцирует detect_sts напрямую) каждый такт для
    // первых DIAG_SAMPLES отсчётов, только если verbose=1 - чтобы понять,
    // ПОЧЕМУ нет срабатывания при том, что сырая автокорреляция на этом
    // файле отличная (0.96 на лаге 16, см. чат).
    localparam DIAG_SAMPLES = 300;

    task automatic run_capture(input integer plateau, input integer verbose);
        integer k;
        begin
            reset = 1;
            enable = 1;
            min_plateau = plateau;
            threshold_scale = 0;
            sample_in = 0;
            sample_in_strobe = 0;
            demod_is_ongoing = 0;
            phase_out = 0;
            phase_out_stb = 0;
            repeat (20) @(posedge clock);
            reset = 0;
            repeat (20) @(posedge clock);

            detections_count = 0;

            for (k = 0; k < num_samples; k = k + 1) begin
                sample_in = {sample_i[k], sample_q[k]};
                sample_in_strobe = 1;
                @(posedge clock);
                if (short_preamble_detected)
                    detections_count = detections_count + 1;
                if (verbose && k < DIAG_SAMPLES)
                    $display("[%0t] DIAG k=%0d i=%0d q=%0d mag_sq_avg=%0d delay_prod_avg_mag=%0d delay_prod_avg_mag_stb=%0d prod_thres=%0d has_pos=%0d has_neg=%0d pos_count=%0d neg_count=%0d min_pos=%0d min_neg=%0d plateau_count=%0d sts=%0d",
                              $time, k, $signed(sample_i[k]), $signed(sample_q[k]),
                              dut.mag_sq_avg, dut.delay_prod_avg_mag, dut.delay_prod_avg_mag_stb,
                              dut.prod_thres, dut.has_pos, dut.has_neg, dut.pos_count, dut.neg_count,
                              dut.min_pos, dut.min_neg, dut.plateau_count, short_preamble_detected);
            end

            sample_in_strobe = 0;
            for (k = 0; k < 200; k = k + 1) begin
                @(posedge clock);
                if (short_preamble_detected)
                    detections_count = detections_count + 1;
            end
        end
    endtask

    integer loose_count, strict_count;

    initial begin
        wait (num_samples > 0);

        $display("[%0t] прогон @ min_plateau=8 (%0d отсчётов)...", $time, num_samples);
        run_capture(8, 1);
        loose_count = detections_count;
        $display("[%0t] min_plateau=8: %0d срабатываний", $time, loose_count);

        $display("[%0t] прогон @ min_plateau=48 (%0d отсчётов)...", $time, num_samples);
        run_capture(48, 0);
        strict_count = detections_count;
        $display("[%0t] min_plateau=48: %0d срабатываний", $time, strict_count);

        $display("-----------------------------------------------------");
        if (loose_count == 0)
            $display("FAIL: min_plateau=8 не дал ни одного срабатывания на iq_from_ila.bin");
        else if (loose_count >= num_samples / 20)
            $display("FAIL: min_plateau=8 сработал %0d/%0d раз - похоже на залипание, а не на выборочное детектирование", loose_count, num_samples);
        else if (strict_count > loose_count)
            $display("FAIL: min_plateau=48 (%0d) дал БОЛЬШЕ срабатываний, чем min_plateau=8 (%0d) - монотонность нарушена", strict_count, loose_count);
        else
            $display("OK: min_plateau=8 -> %0d, min_plateau=48 -> %0d (выборочно, монотонно) - смотрите сами, соответствует ли ожиданиям с живого захвата", loose_count, strict_count);
        $display("-----------------------------------------------------");
        $finish;
    end

    initial begin
        #(50_000_000);
        $display("[%0t] TIMEOUT - симуляция не завершилась штатно", $time);
        $finish;
    end

endmodule

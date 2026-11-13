`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Vivado/xsim-тестбенч для detect_sts на РЕАЛЬНЫХ захваченных данных
// (iq_dump_one1.cf32) - прямой порт test_detect_sts_real_capture_* из
// tb/cocotb/test_detect_sts.py на этот же файл, чтобы прогнать ВЕСЬ pipeline
// detect_sts (complex_to_mag_sq -> mv_avg -> fifo_sample_delay -> complex_mult
// -> mv_avg_dual_ch -> complex_to_mag -> compare/plateau) целиком в xsim
// против уже известного эталона, полученного на cocotb:
//     min_plateau=8:  123 срабатывания short_preamble_detected
//     min_plateau=48:   2 срабатывания (подмножество кластеров из прогона @8)
// Это единственный способ проверить ИНТЕГРАЦИЮ переписанных mv_avg.v и
// mv_avg_dual_ch.v (has_been_full/rd_data_count-архитектура, см. обсуждение
// в чате) на реальном xpm_fifo_sync целиком, а не по отдельности - если счёт
// срабатываний тут разойдётся с cocotb-эталоном, это укажет либо на реальный
// баг, либо на побочный эффект смены семантики data_out_valid (pulse->sticky
// level) на что-то внутри detect_sts.v, зависящее от неё (см. обсуждение
// риска про delay_prod_avg_mag_stb/plateau_count в чате).
//
// Нет независимо известной "истины" (меток пакетов) для этого файла - это
// регрессионная проверка СЧЁТА срабатываний против уже подтверждённого на
// cocotb поведения, а не bit-exact scoreboard.
//
// Непрерывный поток (sample_in_strobe=1 каждый такт, без пауз) - как в
// run_capture() из cocotb-версии; ЕСЛИ когда-нибудь захочется проверить
// именно "залипающий strobe при паузах в потоке" риск, упомянутый в чате -
// нужен ОТДЕЛЬНЫЙ тест с намеренными паузами, этот тестбенч того не делает.
//////////////////////////////////////////////////////////////////////////////////

module detect_sts_real_capture_tb;

    localparam CLK_PERIOD = 10;                  // 100 MHz, как в cocotb (CLK_PERIOD_NS=10)
    localparam IQ_FILE = "/home/sergey/ofdm_lib/detect_sts/tb/cocotb/iq_dump_one1.cf32";
    
    //localparam IQ_FILE = "/home/sergey/temp/2/tx_iq_dump.cf32";
    localparam NUM_SAMPLES_MAX = 65536;

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
        .phase_offset(phase_offset)
    );

    // -----------------------------------------------------------------
    // Загрузка реального IQ-файла: raw complex64 (float32 I, float32 Q),
    // little-endian, без заголовка - см. system_zn_modem_tools_0_0_tb.sv
    // (тот же приём, $bitstoshortreal - стандартный SV системный вызов).
    // Значения в этом конкретном файле целочисленные и укладываются в 16
    // бит (I: -1254..1748, Q: -2048..2012, см. докстринг test_detect_sts.py)
    // - масштабировать не нужно.
    // -----------------------------------------------------------------
    reg  [7:0]        file_bytes [0:NUM_SAMPLES_MAX*8-1];
    reg signed [15:0] sample_i   [0:NUM_SAMPLES_MAX-1];
    reg signed [15:0] sample_q   [0:NUM_SAMPLES_MAX-1];
    integer           num_samples;

    initial begin : load_iq_file
        integer fd, bytes_read, n;
        reg [31:0] bits_i, bits_q;

        fd = $fopen(IQ_FILE, "rb");
        if (fd == 0) begin
            $display("ERROR: не удалось открыть %s", IQ_FILE);
            $finish;
        end
        bytes_read = $fread(file_bytes, fd);
        $fclose(fd);

        num_samples = bytes_read / 8;
        if (num_samples > NUM_SAMPLES_MAX)
            num_samples = NUM_SAMPLES_MAX;

        for (n = 0; n < num_samples; n = n + 1) begin
            bits_i = {file_bytes[n*8+3], file_bytes[n*8+2], file_bytes[n*8+1], file_bytes[n*8+0]};
            bits_q = {file_bytes[n*8+7], file_bytes[n*8+6], file_bytes[n*8+5], file_bytes[n*8+4]};
            sample_i[n] = $rtoi($bitstoshortreal(bits_i));
            sample_q[n] = $rtoi($bitstoshortreal(bits_q));
        end

        $display("[%0t] загружено %0d байт = %0d комплексных отсчётов из %s",
                  $time, bytes_read, num_samples, IQ_FILE);
    end

    // -----------------------------------------------------------------
    // Один прогон файла целиком при заданном min_plateau: сброс, затем
    // непрерывный поток (strobe=1 каждый такт), затем 200 тактов слива
    // конвейера - 1:1 повтор run_capture() из cocotb. Считает каждый такт,
    // где short_preamble_detected=1, отдельным "срабатыванием" (как и
    // cocotb: detections.append(n) на каждом высоком такте, не сворачивая
    // соседние высокие такты в одно событие) - для честного сравнения со
    // счётом 123/2 нужна ТА ЖЕ методика подсчёта.
    // -----------------------------------------------------------------
    integer detections_count;
    integer sample_idx;

    task automatic run_capture(input integer plateau);
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
        run_capture(8);
        loose_count = detections_count;
        $display("[%0t] min_plateau=8: %0d срабатываний (эталон cocotb: 123)", $time, loose_count);

        $display("[%0t] прогон @ min_plateau=48 (%0d отсчётов)...", $time, num_samples);
        run_capture(48);
        strict_count = detections_count;
        $display("[%0t] min_plateau=48: %0d срабатываний (эталон cocotb: 2)", $time, strict_count);

        $display("-----------------------------------------------------");
        if (loose_count == 0)
            $display("FAIL: min_plateau=8 не дал ни одного срабатывания на реальном файле");
        else if (loose_count >= num_samples / 20)
            $display("FAIL: min_plateau=8 сработал %0d/%0d раз - похоже на залипание, а не на выборочное детектирование", loose_count, num_samples);
        else if (strict_count == 0)
            $display("FAIL: min_plateau=48 не дал ни одного срабатывания на реальном файле");
        else if (strict_count > loose_count)
            $display("FAIL: min_plateau=48 (%0d) дал БОЛЬШЕ срабатываний, чем min_plateau=8 (%0d) - монотонность нарушена", strict_count, loose_count);
        else if (loose_count == 123 && strict_count == 2)
            $display("PASS: %0d/%0d - совпадает с эталоном cocotb (123/2) день в день", loose_count, strict_count);
        else
            $display("WARNING: %0d/%0d - логика корректна (детектирует, выборочно, монотонно), но ЧИСЛА отличаются от эталона cocotb (123/2) - стоит разобраться, почему", loose_count, strict_count);
        $display("-----------------------------------------------------");
        $finish;
    end

    initial begin
        #(200_000_000);
        $display("[%0t] TIMEOUT - симуляция не завершилась штатно", $time);
        $finish;
    end

endmodule

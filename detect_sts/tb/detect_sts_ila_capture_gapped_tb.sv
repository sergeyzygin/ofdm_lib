`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// То же самое, что detect_sts_ila_capture_tb.sv (тот же файл
// tx_iq_dump.cf32, та же методика 1:1), но с ПРЕРЫВИСТЫМ потоком отсчётов
// вместо непрерывного - см. чат: реальный АЦП (AD9361) отдаёт отсчёты не
// каждый такт FPGA-клока (100 МГц), а с паузами (в этом тесте - 20 МГц,
// т.е. 1 валидный sample_in_strobe раз в 5 тактов).
//
// Все сегодняшние фиксы (delay_ctl-2 в fifo_sample_delay.v, sample_in_reg
// в detect_sts.v) были подтверждены ТОЛЬКО на непрерывном потоке - этот
// тест нужен, чтобы убедиться, что итоговое детектирование (28/7 на
// непрерывном потоке) не ломается при реалистичных паузах между отсчётами.
//////////////////////////////////////////////////////////////////////////////////

module detect_sts_ila_capture_gapped_tb;

    localparam CLK_PERIOD = 10;                  // 100 МГц FPGA-клок
    localparam SAMPLE_PERIOD = 5;                // 100 МГц / 20 МГц = 1 отсчёт раз в 5 тактов
    localparam IQ_FILE = "/home/sergey/temp/3/tx_iq_dump_11.cf32"; // тот же файл, что в непрерывном тесте
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
    // Загрузка tx_iq_dump.cf32 - тот же формат/порядок байт, что в
    // detect_sts_ila_capture_tb.sv.
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
            sample_q[n] = {file_bytes[n*4+1], file_bytes[n*4+0]};
            sample_i[n] = {file_bytes[n*4+3], file_bytes[n*4+2]};
        end

        $display("[%0t] загружено %0d байт = %0d комплексных отсчётов из %s (прерывистый поток, SAMPLE_PERIOD=%0d)",
                  $time, bytes_read, num_samples, IQ_FILE, SAMPLE_PERIOD);
    end

    // -----------------------------------------------------------------
    // Тот же run_capture, что в непрерывном тесте, но между отсчётами
    // вставляются SAMPLE_PERIOD-1 холостых тактов (sample_in_strobe=0) -
    // т.е. на каждый отсчёт уходит SAMPLE_PERIOD тактов вместо одного.
    // -----------------------------------------------------------------
    integer detections_count;
    localparam DIAG_SAMPLES = 300;

    task automatic run_capture(input integer plateau, input integer verbose);
        integer k, g;
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

                sample_in_strobe = 0;
                for (g = 0; g < SAMPLE_PERIOD - 1; g = g + 1) begin
                    @(posedge clock);
                    if (short_preamble_detected)
                        detections_count = detections_count + 1;
                end
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

        $display("[%0t] прогон @ min_plateau=8 (%0d отсчётов, прерывистый поток)...", $time, num_samples);
        run_capture(8, 1);
        loose_count = detections_count;
        $display("[%0t] min_plateau=8: %0d срабатываний", $time, loose_count);

        $display("[%0t] прогон @ min_plateau=70 (%0d отсчётов, прерывистый поток)...", $time, num_samples);
        run_capture(70, 0);
        strict_count = detections_count;
        $display("[%0t] min_plateau=70: %0d срабатываний", $time, strict_count);

        $display("-----------------------------------------------------");
        //$display("Непрерывный поток (эталон, см. чат): min_plateau=8 -> 28, min_plateau=48 -> 7");
        $display("Прерывистый поток (этот тест): min_plateau=8 -> %0d, min_plateau=70 -> %0d", loose_count, strict_count);
        //if (loose_count == 28 && strict_count == 7)
        //    $display("PASS: прерывистый поток даёт ТЕ ЖЕ числа, что непрерывный - паузы между отсчётами не ломают детектирование");
        //else
        //    $display("FAIL: числа отличаются от непрерывного потока - см. DIAG выше, где именно расходится");
        //$display("-----------------------------------------------------");
        $finish;
    end

    initial begin
        #(250_000_000); // с запасом - в SAMPLE_PERIOD раз дольше непрерывного теста
        $display("[%0t] TIMEOUT - симуляция не завершилась штатно", $time);
        $finish;
    end

endmodule

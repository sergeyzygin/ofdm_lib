`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Прямое, однозначное измерение задержки complex_mult (реальный cmpy_0 -
// закрытая Xilinx Complex Multiplier IP) на реальном железе - без всякой
// алгебры и подбора индексов вручную (см. чат: попытка вычислить точный
// сдвиг через сопоставление prod_i/prod_q с сырыми отсчётами tx_iq_dump.cf32
// не дала ни одного совпадения даже с запасом ±45 тактов - подозрение, что
// локальная Verilator-заглушка sim_models/cmpy_0.v просто не повторяет
// реальную задержку конвейера настоящей IP).
//
// Идея предельно простая: a_i = n (номер такта push, 0,1,2,...), a_q = 0,
// b_i = 1 (тождественный множитель), b_q = 0, input_strobe = 1 каждый такт.
// Тогда p_i = a_i*b_i - a_q*b_q = n*1 - 0 = n, p_q = a_i*b_q+a_q*b_i = 0 -
// то есть НА ВЫХОДЕ p_i НАПРЯМУЮ показывает, какой именно push (номер n)
// сейчас появился на выходе. Задержка = (номер такта, на котором p_i=n
// появился с output_strobe=1) - n. Читается прямо из лога, без вычислений.
//////////////////////////////////////////////////////////////////////////////////

module complex_mult_latency_tb;

    localparam CLK_PERIOD = 4;
    localparam NUM_PUSHES = 32;

    reg clock = 0;
    always #(CLK_PERIOD/2) clock = ~clock;

    reg reset = 1;
    reg enable = 1;
    reg signed [15:0] a_i = 0;
    reg signed [15:0] a_q = 0;
    reg signed [15:0] b_i = 0;
    reg signed [15:0] b_q = 0;
    reg input_strobe = 0;
    wire signed [31:0] p_i;
    wire signed [31:0] p_q;
    wire output_strobe;

    complex_mult dut (
        .clock(clock),
        .enable(enable),
        .reset(reset),
        .a_i(a_i),
        .a_q(a_q),
        .b_i(b_i),
        .b_q(b_q),
        .input_strobe(input_strobe),
        .p_i(p_i),
        .p_q(p_q),
        .output_strobe(output_strobe)
    );



    integer push_idx;
    reg     driving;
    integer first_output_idx;
    integer first_output_cycle;
    integer cycle_count;
    integer mismatch_count;
    integer checked_count;

    initial begin
        reset = 1;
        enable = 1;
        a_i = 0; a_q = 0;
        b_i = 0; b_q = 0;
        input_strobe = 0;
        push_idx = 0;
        driving = 0;
        cycle_count = 0;
        first_output_idx = -1;
        first_output_cycle = -1;
        mismatch_count = 0;
        checked_count = 0;

        repeat (10) @(posedge clock);
        reset = 0;
        repeat (5) @(posedge clock);

        driving = 1;

        wait (push_idx == NUM_PUSHES);
        input_strobe = 0;

        repeat (30) @(posedge clock); // слив конвейера cmpy_0

        $display("-----------------------------------------------------");
        if (first_output_idx < 0) begin
            $display("FAIL: output_strobe ни разу не взвёлся");
        end else begin
            $display("Первый валидный выход: p_i=%0d (это был push #%0d) на такте cycle_count=%0d",
                      first_output_idx, first_output_idx, first_output_cycle);
            $display("Задержка complex_mult (cmpy_0) = %0d тактов (cycle_count - p_i при первом output_strobe)",
                      first_output_cycle - first_output_idx);
        end
        $display("checked_count=%0d, mismatch_count=%0d (p_q != 0 или порядок нарушен)", checked_count, mismatch_count);
        $display("-----------------------------------------------------");
        $finish;
    end

    initial begin
        #(50_000);
        $display("[%0t] TIMEOUT - симуляция не завершилась штатно", $time);
        $finish;
    end

    integer expected_next;
    initial expected_next = 0;

    always @(posedge clock) begin
        cycle_count <= cycle_count + 1;

        if (output_strobe) begin
            checked_count = checked_count + 1;
            if (first_output_idx < 0) begin
                first_output_idx = p_i;
                first_output_cycle = cycle_count;
                expected_next = p_i + 1;
            end else begin
                if (p_i !== expected_next || p_q !== 0) begin
                    mismatch_count = mismatch_count + 1;
                    if (mismatch_count <= 10)
                        $display("[%0t] MISMATCH: cycle=%0d p_i=%0d (ожидалось %0d) p_q=%0d (ожидалось 0)",
                                  $time, cycle_count, p_i, expected_next, p_q);
                end
                expected_next = p_i + 1;
            end
            $display("[%0t] OUT cycle=%0d p_i=%0d p_q=%0d (задержка от push = %0d тактов)",
                      $time, cycle_count, p_i, p_q, cycle_count - p_i);
        end

        if (driving && push_idx < NUM_PUSHES) begin
            a_i <= push_idx[15:0];
            a_q <= 16'sd0;
            b_i <= 16'sd1;
            b_q <= 16'sd0;
            input_strobe <= 1'b1;
            push_idx <= push_idx + 1;
        end else begin
            input_strobe <= 1'b0;
        end
    end

endmodule

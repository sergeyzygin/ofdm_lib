`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Тестбенч для Vivado/xsim для complex_to_mag_sq - на первых 10 отсчётах
// /tmp/detect_sts_diag.csv (вывод detect_sts_py/detect_sts.py по
// /home/sergey/temp/1/tx_iq_dump.cf32, см. чат) - i/q оттуда же, mag_sq
// пересчитан в Python-модели тем же способом (mag_sq = i*i + q*q), здесь
// просто сверяется с тем, что даёт реальное железо.
//
// Проверка - через очередь ожидаемых значений (push при каждой поданной
// паре i/q, pop при каждом mag_sq_strobe), а не через жёстко зашитую
// задержку в тактах: complex_to_mag_sq внутри использует complex_mult,
// чья задержка/поведение в этой сессии не раз менялись (см. чат про
// cmpy_0) - очередь корректно ловит расхождение по ЗНАЧЕНИЮ и ПОРЯДКУ
// независимо от того, сколько тактов реально занимает конвейер.
//////////////////////////////////////////////////////////////////////////////////

module complex_to_mag_sq_tb;

    localparam CLK_PERIOD = 10;
    localparam NUM_PUSHES = 10;

    reg clock = 0;
    always #(CLK_PERIOD/2) clock = ~clock;

    reg                     reset = 1;
    reg                     enable = 1;
    reg  signed [15:0]      i_in = 0;
    reg  signed [15:0]      q_in = 0;
    reg                     input_strobe = 0;
    wire [31:0]             mag_sq;
    wire                    mag_sq_strobe;

    complex_to_mag_sq dut (
        .clock(clock),
        .enable(enable),
        .reset(reset),
        .i(i_in),
        .q(q_in),
        .input_strobe(input_strobe),
        .mag_sq(mag_sq),
        .mag_sq_strobe(mag_sq_strobe)
    );

    // первые 10 (i, q, mag_sq) из /tmp/detect_sts_diag.csv
    reg signed [15:0] test_i   [0:NUM_PUSHES-1];
    reg signed [15:0] test_q   [0:NUM_PUSHES-1];
    reg        [31:0] test_mag [0:NUM_PUSHES-1];

    initial begin
        test_i[0]=-703;   test_q[0]=0;     test_mag[0]=494209;
        test_i[1]=3725;   test_q[1]=-217;  test_mag[1]=13922714;
        test_i[2]=9031;   test_q[2]=4515;  test_mag[2]=101944186;
        test_i[3]=-4809;  test_q[3]=5485;  test_mag[3]=53211706;
        test_i[4]=18475;  test_q[4]=-9237; test_mag[4]=426647794;
        test_i[5]=4999;   test_q[5]=-12772;test_mag[5]=188113985;
        test_i[6]=-13063; test_q[6]=6531;  test_mag[6]=213295930;
        test_i[7]=-12069; test_q[7]=17772; test_mag[7]=461504745;
        test_i[8]=-18475; test_q[8]=0;     test_mag[8]=341325625;
        test_i[9]=-12069; test_q[9]=-17772;test_mag[9]=461504745;
    end

    integer push_idx;
    reg     driving;
    integer q_head, q_tail;
    reg [31:0] expected_q [0:NUM_PUSHES-1];

    integer checked_count;
    integer mismatch_count;
    reg [31:0] exp;

    initial begin
        reset = 1;
        enable = 1;
        i_in = 0;
        q_in = 0;
        input_strobe = 0;
        push_idx = 0;
        driving = 0;
        q_head = 0;
        q_tail = 0;
        checked_count = 0;
        mismatch_count = 0;

        repeat (10) @(posedge clock);
        reset = 0;
        repeat (5) @(posedge clock);

        driving = 1;

        wait (push_idx == NUM_PUSHES);
        input_strobe = 0;

        repeat (30) @(posedge clock); // слив конвейера

        $display("-----------------------------------------------------");
        $display("mismatch_count = %0d / checked_count = %0d (ожидалось %0d проверок)",
                  mismatch_count, checked_count, NUM_PUSHES);
        if (checked_count == 0)
            $display("FAIL: ни одной проверки не выполнено");
        else if (mismatch_count == 0 && checked_count == NUM_PUSHES)
            $display("PASS: все %0d проверок совпали с эталоном из /tmp/detect_sts_diag.csv", checked_count);
        else
            $display("FAIL: см. MISMATCH выше (или checked_count != NUM_PUSHES)");
        $display("-----------------------------------------------------");
        $finish;
    end

    initial begin
        #(50_000);
        $display("[%0t] TIMEOUT - симуляция не завершилась штатно", $time);
        $finish;
    end

    always @(posedge clock) begin
        if (mag_sq_strobe) begin
            if (q_head >= q_tail) begin
                $display("[%0t] FAIL: mag_sq_strobe взвёлся, а очередь ожидаемых значений пуста", $time);
                mismatch_count = mismatch_count + 1;
            end else begin
                exp = expected_q[q_head];
                q_head = q_head + 1;
                if (mag_sq !== exp) begin
                    mismatch_count = mismatch_count + 1;
                    $display("[%0t] MISMATCH #%0d: mag_sq=%0d, ожидалось %0d",
                              $time, checked_count, mag_sq, exp);
                end
                checked_count = checked_count + 1;
            end
        end

        if (driving && push_idx < NUM_PUSHES) begin
            i_in <= test_i[push_idx];
            q_in <= test_q[push_idx];
            input_strobe <= 1'b1;
            expected_q[q_tail] <= test_mag[push_idx];
            q_tail <= q_tail + 1;
            push_idx <= push_idx + 1;
        end else begin
            input_strobe <= 1'b0;
        end
    end

endmodule

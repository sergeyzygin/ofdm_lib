`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// То же самое измерение задержки fifo_sample_delay, что и
// fifo_sample_delay_latency_tb.sv, но с ПРЕРЫВИСТЫМ потоком вместо
// непрерывного - см. чат: реальный АЦП (AD9361) отдаёт отсчёты не каждый
// такт FPGA-клока, а с паузами (частота клока 100 МГц, частота отсчётов
// в этом тесте - 20 МГц, т.е. 1 валидный data_in_valid раз в 5 тактов).
// Все замеры этой сессии (включая найденную сегодня поправку delay_ctl-2
// в fifo_sample_delay.v) делались ТОЛЬКО на непрерывном потоке - этот тест
// нужен, чтобы убедиться, что задержка (=16) не "плывёт" при паузах между
// отсчётами, т.е. что она зависит от числа ПРИНЯТЫХ отсчётов, а не от
// числа прошедших тактов.
//
// Методика идентична fifo_sample_delay_latency_tb.sv: v(n)=n (значение =
// номер push'а, читается напрямую с выхода), измеренная задержка = (число
// принятых push'ей к моменту pop) - 1 - data_out.
//////////////////////////////////////////////////////////////////////////////////

module fifo_sample_delay_latency_gapped_tb;

    localparam DATA_WIDTH      = 32;   // как в detect_sts.v (sample_delayed_inst)
    localparam LOG2_FIFO_DEPTH = 5;    // как в detect_sts.v
    localparam DELAY_CTL       = 16;   // как в detect_sts.v (жёстко зашито там же)
    localparam CLK_PERIOD      = 10;   // 100 МГц FPGA-клок
    localparam SAMPLE_PERIOD   = 5;    // 100 МГц / 20 МГц = 1 отсчёт раз в 5 тактов
    localparam NUM_PUSHES      = 64;

    reg clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg                            rst = 1;
    reg  [LOG2_FIFO_DEPTH-1:0]     delay_ctl = DELAY_CTL;
    reg  signed [DATA_WIDTH-1:0]   data_in = 0;
    reg                            data_in_valid = 0;
    wire signed [DATA_WIDTH-1:0]   data_out;
    wire                           data_out_valid;

    fifo_sample_delay #(
        .DATA_WIDTH(DATA_WIDTH),
        .LOG2_FIFO_DEPTH(LOG2_FIFO_DEPTH)
    ) dut (
        .clk(clk),
        .rst(rst),
        .delay_ctl(delay_ctl),
        .data_in(data_in),
        .data_in_valid(data_in_valid),
        .data_out(data_out),
        .data_out_valid(data_out_valid)
    );

    integer push_idx;        // следующий индекс для push (0,1,2,...)
    integer accepted_pushes; // сколько push'ей реально принято
    integer gap_counter;     // 0..SAMPLE_PERIOD-1 - взводит push раз в SAMPLE_PERIOD тактов
    reg     driving;

    integer pop_count;
    integer first_pop_accepted_pushes;
    integer first_pop_value;
    integer measured_delay;
    integer mismatch_count;

    initial begin
        rst = 1;
        data_in_valid = 0;
        data_in = 0;
        push_idx = 0;
        accepted_pushes = 0;
        gap_counter = 0;
        driving = 0;
        pop_count = 0;
        first_pop_accepted_pushes = -1;
        first_pop_value = -1;
        measured_delay = -1;
        mismatch_count = 0;

        repeat (10) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk); // время на wr_rst_busy/rd_rst_busy handshake внутри xpm_fifo_sync

        driving = 1;

        wait (push_idx == NUM_PUSHES);
        data_in_valid = 0;

        repeat (SAMPLE_PERIOD * 20) @(posedge clk); // слив конвейера - с запасом на паузы

        $display("-----------------------------------------------------");
        $display("SAMPLE_PERIOD=%0d тактов (100 МГц / 20 МГц)", SAMPLE_PERIOD);
        if (first_pop_accepted_pushes < 0) begin
            $display("FAIL: ни одного data_out_valid не зафиксировано");
        end else begin
            $display("Первый pop: data_out=%0d, к этому такту принято push'ей=%0d (ожидалось DELAY_CTL=%0d)",
                      first_pop_value, first_pop_accepted_pushes, DELAY_CTL);
            $display("Измеренная задержка (push'ей ДО этого конкретного значения на момент его pop) = %0d",
                      measured_delay);
            if (measured_delay == DELAY_CTL)
                $display("PASS: задержка равна DELAY_CTL=%0d даже с паузами между отсчётами", DELAY_CTL);
            else
                $display("FAIL: задержка = %0d, ожидалось DELAY_CTL=%0d (diff=%0d) - поправка delay_ctl-2 могла оказаться специфична для непрерывного потока",
                          measured_delay, DELAY_CTL, measured_delay - DELAY_CTL);
        end
        $display("Всего pop-событий: %0d (ожидалось %0d)", pop_count, NUM_PUSHES);
        $display("mismatch_count (текущий pop-value отличался от предыдущего+1, т.е. порядок нарушен) = %0d", mismatch_count);
        $display("-----------------------------------------------------");
        $finish;
    end

    initial begin
        #(200_000);
        $display("[%0t] TIMEOUT - симуляция не завершилась штатно", $time);
        $finish;
    end

    integer prev_popped_value;
    initial prev_popped_value = -1;

    always @(posedge clk) begin
        if (data_out_valid) begin
            pop_count = pop_count + 1;
            if (first_pop_accepted_pushes < 0) begin
                first_pop_accepted_pushes = accepted_pushes + ((driving && push_idx < NUM_PUSHES && gap_counter == 0) ? 1 : 0);
                first_pop_value = data_out;
                measured_delay = first_pop_accepted_pushes - 1 - data_out;
            end
            if (prev_popped_value >= 0 && data_out !== prev_popped_value + 1) begin
                mismatch_count = mismatch_count + 1;
                if (mismatch_count <= 10)
                    $display("[%0t] ПОРЯДОК НАРУШЕН: data_out=%0d, ожидался %0d",
                              $time, data_out, prev_popped_value + 1);
            end
            prev_popped_value = data_out;
        end

        if (driving && push_idx < NUM_PUSHES) begin
            if (gap_counter == 0) begin
                data_in <= push_idx;
                data_in_valid <= 1'b1;
                push_idx <= push_idx + 1;
                accepted_pushes <= accepted_pushes + 1;
            end else begin
                data_in_valid <= 1'b0;
            end
            gap_counter <= (gap_counter == SAMPLE_PERIOD - 1) ? 0 : gap_counter + 1;
        end else begin
            data_in_valid <= 1'b0;
        end
    end

endmodule

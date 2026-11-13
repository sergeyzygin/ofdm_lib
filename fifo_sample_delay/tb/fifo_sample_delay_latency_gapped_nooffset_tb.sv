`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Проверка гипотезы (см. чат): отставание wr_data_count внутри реального
// xpm_fifo_sync - фиксированное небольшое число ТАКТОВ (не push'ей). При
// непрерывном потоке (1 push/такт) это даёт ровно 2 "пропущенных" push'а
// (отсюда найденная сегодня поправка delay_ctl-2 в fifo_sample_delay.v -
// подтверждено: delay_ctl-2 -> задержка 16 на непрерывном потоке). При
// ЛЮБОМ прерывистом потоке, где пауза между push'ами БОЛЬШЕ этих ~2
// тактов (что верно для любой реальной частоты АЦП - она всегда намного
// медленнее 100 МГц клока FPGA), эти 2 такта отставания не должны набегать
// даже на один лишний push - т.е. поправка вообще не нужна.
//
// Проверено прямым измерением на прерывистом потоке (20 МГц,
// fifo_sample_delay_latency_gapped_tb.sv) с ТЕКУЩЕЙ поправкой delay_ctl-2:
// получена задержка 14 (на 2 МЕНЬШЕ желаемых 16) - подтверждает, что
// поправка -2 не просто "не нужна", а АКТИВНО ВРЕДИТ на прерывистом
// потоке. Значит для прерывистого потока нужен порог БЕЗ поправки, т.е.
// wr_data_count >= delay_ctl (без -2).
//
// Не трогая RTL fifo_sample_delay.v (там сейчас "delay_ctl - 2" зашито в
// формулу), этот тест ПРОВЕРЯЕТ ИМЕННО "delay_ctl без поправки" хитрым
// способом: на порт delay_ctl подаётся 18 вместо 16 - тогда внутри модуля
// "18 - 2 = 16", т.е. РЕАЛЬНОЕ сравнение получается "wr_data_count >= 16" -
// именно та комбинация, которую нужно проверить, без единой правки RTL.
// TARGET_DELAY=16 - это то, с чем сравнивается ИЗМЕРЕННАЯ задержка (цель),
// DELAY_CTL_PORT=18 - то, что реально подаётся на вход DUT.
//////////////////////////////////////////////////////////////////////////////////

module fifo_sample_delay_latency_gapped_nooffset_tb;

    localparam DATA_WIDTH      = 32;
    localparam LOG2_FIFO_DEPTH = 5;
    localparam TARGET_DELAY    = 16;   // желаемая задержка (как в detect_sts.v)
    localparam DELAY_CTL_PORT  = 18;   // подаём delay_ctl=18, чтобы "18-2=16" внутри RTL
    localparam CLK_PERIOD      = 10;   // 100 МГц FPGA-клок
    localparam SAMPLE_PERIOD   = 5;    // 100 МГц / 20 МГц = 1 отсчёт раз в 5 тактов
    localparam NUM_PUSHES      = 64;

    reg clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg                            rst = 1;
    reg  [LOG2_FIFO_DEPTH-1:0]     delay_ctl = DELAY_CTL_PORT;
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

    integer push_idx;
    integer accepted_pushes;
    integer gap_counter;
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
        repeat (5) @(posedge clk);

        driving = 1;

        wait (push_idx == NUM_PUSHES);
        data_in_valid = 0;

        repeat (SAMPLE_PERIOD * 20) @(posedge clk);

        $display("-----------------------------------------------------");
        $display("SAMPLE_PERIOD=%0d тактов (100 МГц / 20 МГц), delay_ctl (порт)=%0d, цель=%0d",
                  SAMPLE_PERIOD, DELAY_CTL_PORT, TARGET_DELAY);
        if (first_pop_accepted_pushes < 0) begin
            $display("FAIL: ни одного data_out_valid не зафиксировано");
        end else begin
            $display("Первый pop: data_out=%0d, к этому такту принято push'ей=%0d (ожидалась цель=%0d)",
                      first_pop_value, first_pop_accepted_pushes, TARGET_DELAY);
            $display("Измеренная задержка (push'ей ДО этого конкретного значения на момент его pop) = %0d",
                      measured_delay);
            if (measured_delay == TARGET_DELAY)
                $display("PASS: задержка равна %0d - гипотеза подтверждена, на прерывистом потоке поправка не нужна (delay_ctl без -2)", TARGET_DELAY);
            else
                $display("FAIL: задержка = %0d, ожидалось %0d (diff=%0d) - гипотеза НЕ подтверждена, зависимость сложнее",
                          measured_delay, TARGET_DELAY, measured_delay - TARGET_DELAY);
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

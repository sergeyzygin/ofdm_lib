`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Точное измерение задержки fifo_sample_delay (сколько ТАКТОВ ПУШЕЙ
// реально накапливается перед первым pop) - в отличие от
// fifo_sample_delay_tb.sv (проверяет только ПОРЯДОК значений через
// FIFO-очередь, что НЕ ловит равномерный сдвиг на N тактов сразу у ВСЕХ
// значений), этот тест напрямую читает ЗНАЧЕНИЕ на выходе (v(n)=n, т.е.
// data_out САМ говорит, какой это был push) и считает, сколько push'ей уже
// было принято к моменту каждого pop - реальная задержка = (число push'ей
// к моменту pop) - 1 - data_out.
//
// Мотивация (см. чат): на реальном Vivado detect_sts.v застревает с
// delay_prod_avg_mag на ФИКСИРОВАННОМ, но ЗАНИЖЕННОМ (~15% от mag_sq_avg)
// значении именно в том окне, где mag_sq_avg абсолютно неизменен (т.е.
// сигнал идеально периодичен с периодом 16) - это выглядит так, как будто
// sample_delayed = fifo_sample_delay(sample_in, delay_ctl=16) даёт НЕ
// x[n-16], а какой-то ДРУГОЙ отсчёт периода (напр. x[n-15]) - для periodic
// сигнала это даёт фиксированную, но неверную корреляцию.
//
// В src/fifo_sample_delay.v:53 - `wire primed = (wr_data_count >=
// delay_ctl-1);` - выглядит как реальный off-by-one: primed (и, значит,
// rd_en) взводится уже при delay_ctl-1 накопленных отсчётах, а не
// delay_ctl - т.е. РЕАЛЬНАЯ задержка должна быть delay_ctl-1, а не
// delay_ctl. Этот тест должен это подтвердить/опровергнуть НА РЕАЛЬНОМ
// железе (сама формула читается по исходнику однозначно, но семантика
// wr_data_count в РЕАЛЬНОМ xpm_fifo_sync уже не раз преподносила сюрпризы
// в этой сессии - см. mv_avg.v/wr_ack).
//
// DELAY_CTL=16 (та же величина, что в detect_sts.v), непрерывный поток без
// пауз, v(n)=n (значение = порядковый номер push'а, читается напрямую).
//////////////////////////////////////////////////////////////////////////////////

module fifo_sample_delay_latency_tb;

    localparam DATA_WIDTH      = 32;   // как в detect_sts.v (sample_delayed_inst)
    localparam LOG2_FIFO_DEPTH = 5;    // как в detect_sts.v
    localparam DELAY_CTL       = 16;   // как в detect_sts.v (жёстко зашито там же)
    localparam CLK_PERIOD      = 4;
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

    integer push_idx;      // следующий индекс для push (0,1,2,...)
    integer accepted_pushes; // сколько push'ей реально принято (data_in_valid было 1 на предыдущем такте)
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

        repeat (60) @(posedge clk); // слив конвейера

        $display("-----------------------------------------------------");
        if (first_pop_accepted_pushes < 0) begin
            $display("FAIL: ни одного data_out_valid не зафиксировано");
        end else begin
            $display("Первый pop: data_out=%0d, к этому такту принято push'ей=%0d (ожидалось DELAY_CTL=%0d)",
                      first_pop_value, first_pop_accepted_pushes, DELAY_CTL);
            $display("Измеренная задержка (push'ей ДО этого конкретного значения на момент его pop) = %0d",
                      measured_delay);
            if (measured_delay == DELAY_CTL)
                $display("PASS: задержка равна DELAY_CTL=%0d, как и ожидалось", DELAY_CTL);
            else
                $display("FAIL: задержка = %0d, ожидалось DELAY_CTL=%0d (diff=%0d) - см. чат про primed=(wr_data_count>=delay_ctl-1) в fifo_sample_delay.v",
                          measured_delay, DELAY_CTL, measured_delay - DELAY_CTL);
        end
        $display("Всего pop-событий: %0d (ожидалось %0d)", pop_count, NUM_PUSHES);
        $display("mismatch_count (текущий pop-value отличался от предыдущего+1, т.е. порядок сломан) = %0d", mismatch_count);
        $display("-----------------------------------------------------");
        $finish;
    end

    initial begin
        #(50_000);
        $display("[%0t] TIMEOUT - симуляция не завершилась штатно", $time);
        $finish;
    end

    integer prev_popped_value;
    initial prev_popped_value = -1;

    always @(posedge clk) begin
        // data_out_valid в ЭТОТ такт: сколько push'ей уже накоплено к этому
        // такту (включая тот, что принимается ПРЯМО СЕЙЧАС, если
        // data_in_valid тоже 1 - primed комбинационная, значит push и pop
        // могут случиться в один и тот же такт).
        if (data_out_valid) begin
            pop_count = pop_count + 1;
            if (first_pop_accepted_pushes < 0) begin
                // accepted_pushes ЕЩЁ не учитывает push этого такта (тот
                // применяется ниже, после этого блока) - добавляем его,
                // если он произойдёт (driving && push_idx<NUM_PUSHES).
                first_pop_accepted_pushes = accepted_pushes + ((driving && push_idx < NUM_PUSHES) ? 1 : 0);
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
            data_in <= push_idx;
            data_in_valid <= 1'b1;
            push_idx <= push_idx + 1;
            accepted_pushes <= accepted_pushes + 1;
        end
    end

endmodule

`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Минимальный, легко пересчитываемый вручную тестбенч для fifo_sample_delay,
// по духу mv_avg/tb/mv_avg_fifo16_tb.sv - для Vivado/xsim, чтобы проверить
// на РЕАЛЬНОМ xpm_fifo_sync.
//
// В отличие от mv_avg.v (аккумулятор, гейтится wr_ack/wr_complete_pulse -
// см. обсуждение "-v(0)" бага в чате), fifo_sample_delay - простая линия
// задержки: data_out = dout читается НАПРЯМУЮ из xpm_fifo_sync, rd_en
// вычисляется из wr_data_count/primed, БЕЗ wr_ack-компенсации задержки в
// пути. Наша Verilator-заглушка (sim_models/xpm_fifo_sync.v) была
// доработана добавлением ЕЩЁ ОДНОГО регистра dout_r <= stage_a
// (безусловно, каждый такт) специально под mv_avg.v's нужды - у mv_avg.v
// это компенсируется тем, что wr_ack (и всё, что на него завязано) САМ
// задержан на 1 такт, так что и там, и там +1 такт, фаза совпадает. У
// fifo_sample_delay такой компенсации НЕТ - rd_en вычисляется "вживую"
// каждый такт из wr_data_count, без какой-либо задержки. Если dout_r
// действительно вносит лишний такт задержки, которого не было бы у
// НАСТОЯЩЕГО xpm_fifo_sync (см. диагностику в чате: реальный FWFT там,
// судя по факту, синхронизирован иначе), здесь это должно проявиться как
// систематический сдвиг данных на 1 позицию - именно это тест и должен
// поймать.
//
// DATA_WIDTH=16, LOG2_FIFO_DEPTH=5 (физическая ёмкость FIFO - просто с
// запасом, не путать с проверяемой задержкой), DELAY_CTL=4 - маленькая,
// легко прослеживаемая задержка. Вход v(n) = 100+n (простая, узнаваемая
// последовательность, v(0)=100=/=0 - см. чат про то, почему v(0)=0
// маскирует реальные дефекты).
//
// fifo_sample_delay - чистая линия задержки (FIFO order, без арифметики),
// поэтому модель тривиальна: k-й выход ДОЛЖЕН РАВНЯТЬСЯ k-му входу (тому
// же значению v(k) - delay_ctl только определяет, СКОЛЬКО тактов копится
// перед началом выдачи, не меняет порядок/значения). Проверка - просто
// FIFO-очередь ожидаемых значений: push при каждой принятой записи, pop
// при каждом импульсе data_out_valid.
//////////////////////////////////////////////////////////////////////////////////

module fifo_sample_delay_tb;

    localparam DATA_WIDTH      = 16;
    localparam LOG2_FIFO_DEPTH = 5;     // физическая ёмкость FIFO (32) - запас, не задержка
    localparam DELAY_CTL       = 4;     // сама проверяемая задержка - маленькая, легко вручную
    localparam CLK_PERIOD      = 4;
    localparam NUM_PUSHES      = 48;

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

    function automatic integer v(input integer n);
        v = 100 + n;
    endfunction

    integer push_idx;
    reg     driving;

    reg signed [DATA_WIDTH-1:0] expected_q [0:NUM_PUSHES-1];
    integer q_head, q_tail;

    integer checked_count;
    integer mismatch_count;
    reg signed [DATA_WIDTH-1:0] exp;

    initial begin
        rst = 1;
        data_in_valid = 0;
        data_in = 0;
        push_idx = 0;
        driving = 0;
        q_head = 0;
        q_tail = 0;
        checked_count = 0;
        mismatch_count = 0;

        repeat (10) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk); // время на wr_rst_busy/rd_rst_busy handshake внутри xpm_fifo_sync

        driving = 1;

        wait (push_idx == NUM_PUSHES);
        data_in_valid = 0;

        repeat (50) @(posedge clk); // слив конвейера

        $display("-----------------------------------------------------");
        $display("mismatch_count = %0d / checked_count = %0d (ожидалось %0d проверок)",
                  mismatch_count, checked_count, NUM_PUSHES);
        if (checked_count == 0)
            $display("FAIL: ни одной проверки не выполнено");
        else if (mismatch_count == 0 && checked_count == NUM_PUSHES)
            $display("PASS: все %0d проверок совпали (delay_ctl=%0d)", checked_count, DELAY_CTL);
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

    always @(posedge clk) begin
        if (data_out_valid) begin
            if (q_head >= q_tail) begin
                $display("[%0t] FAIL: data_out_valid взвёлся, а очередь ожидаемых значений пуста", $time);
                mismatch_count = mismatch_count + 1;
            end else begin
                exp = expected_q[q_head];
                q_head = q_head + 1;
                if (data_out !== exp) begin
                    mismatch_count = mismatch_count + 1;
                    if (mismatch_count <= 20)
                        $display("[%0t] MISMATCH #%0d: data_out=%0d, ожидалось %0d",
                                  $time, checked_count, $signed(data_out), $signed(exp));
                end
                checked_count = checked_count + 1;
            end
        end

        if (driving && push_idx < NUM_PUSHES) begin
            data_in <= v(push_idx);
            data_in_valid <= 1'b1;
            expected_q[q_tail] <= v(push_idx);
            q_tail <= q_tail + 1;
            push_idx <= push_idx + 1;
        end
    end

endmodule

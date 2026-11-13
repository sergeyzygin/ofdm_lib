`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Прицельный тестбенч для mv_avg: повторяет ТЕ ЖЕ данные и тот же
// per-sample scoreboard-подход, что нашёл расхождение в cocotb
// (test_mv_avg_back_to_back в tb/cocotb/test_mv_avg.py, прогон на
// поведенческой Verilator-заглушке xpm_fifo_sync) - непериодический "разброс"
// v(n) = (n*37-500) mod 65536 - 32768, непрерывный поток без пауз
// (data_in_valid=1 каждый такт, как при реальном потоке с АЦП).
//
// ПОЧЕМУ именно НЕпериодические данные, а не 0..FIFO_SIZE-1 как в
// mv_avg_tb.sv: периодический сигнал с периодом ровно FIFO_SIZE
// СТРУКТУРНО НЕ МОЖЕТ поймать баг вида "вытесняется не тот (сдвинутый на
// 1 позицию) элемент окна" - любое окно из FIFO_SIZE подряд идущих
// отсчётов периодического сигнала суммируется в одно и то же число
// независимо от фазы, так что mv_avg_tb.sv слеп именно к этому классу
// ошибок. cocotb на этих данных поймал СТАБИЛЬНОЕ расхождение ровно на
// границе первого заполнения окна (переход push-индекса FIFO_SIZE-1 ->
// FIFO_SIZE), см. обсуждение в чате - величина расхождения (-1008) точно
// совпадает со значением самого первого отправленного отсчёта, что похоже
// на вытеснение "соседней" позиции вместо самой старой ровно в момент
// первого заполнения.
//
// ЦЕЛЬ этого тестбенча: подтвердить или опровергнуть, что это баг именно в
// RTL (mv_avg.v/реальный xpm_fifo_sync), а не артефакт Verilator-заглушки
// (sim_models/xpm_fifo_sync.v) - тестбенч ниже гоняет ТЕ ЖЕ данные против
// НАСТОЯЩЕГО xpm_fifo_sync в Vivado/xsim.
//
// Синхронизация проверки - через dut.wr_complete_pulse: это тот самый
// внутренний сигнал mv_avg.v, который гейтит его собственное обновление
// running_total (`if (wr_complete_pulse) running_total <= ...`), напрямую
// доступен как white-box иерархическая ссылка, поскольку тестбенч
// инстанцирует mv_avg напрямую (не через IP-XACT). Снимаем data_out ровно
// через 1 такт после того, как этот сигнал взведён - тем самым не нужно
// вручную подбирать/угадывать задержку конвейера, а любой реальный сдвиг
// (в т.ч. однотактный "затор" ровно на границе full, если он есть) учтётся
// автоматически, той же логикой, что использует сам DUT.
//
// ВСЁ (драйв стимула + модель + проверка) - в ОДНОМ always-блоке. Раньше
// стимул жил в отдельном initial-блоке, а проверка - в отдельном always,
// оба чувствительны к тому же posedge clk; относительный порядок
// исполнения ДВУХ разных процессов на одном фронте в Verilog не
// гарантирован спецификацией, и первая версия этого тестбенча из-за этого
// давала растущее расхождение с самого первого отсчёта - артефакт гонки
// между процессами, а не реальное поведение DUT. Один процесс = один
// детерминированный порядок исполнения, гонки нет.
//////////////////////////////////////////////////////////////////////////////////

module mv_avg_back_to_back_tb;

    localparam DATA_WIDTH   = 16;
    localparam LOG2_AVG_LEN = 5;                 // FIFO_SIZE=32, как в cocotb test_mv_avg_back_to_back
    localparam FIFO_SIZE    = 1 << LOG2_AVG_LEN;
    localparam TOTAL_WIDTH  = DATA_WIDTH + LOG2_AVG_LEN;

    localparam CLK_PERIOD  = 4;
    localparam NUM_PUSHES  = FIFO_SIZE * 4;      // 128 - как в cocotb

    reg clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg rstn = 0;
    reg  signed [DATA_WIDTH-1:0] data_in = 0;
    reg                          data_in_valid = 0;
    wire signed [DATA_WIDTH-1:0] data_out;
    wire                         data_out_valid;
    //debug 
    wire [4:0] rd_data_count;
    wire has_been_full;
    wire signed [DATA_WIDTH-1:0] debug_ext_data_in_old;
    wire debug_wr_enable;
    

    mv_avg #(
        .DATA_WIDTH(DATA_WIDTH),
        .LOG2_AVG_LEN(LOG2_AVG_LEN)
    ) dut (
        .clk(clk),
        .rstn(rstn),
        .data_in(data_in),
        .data_in_valid(data_in_valid),
        .data_out(data_out),
        .data_out_valid(data_out_valid),
        //debug 
        .rd_data_count(rd_data_count),
        .has_been_full(has_been_full),
        .debug_ext_data_in_old(debug_ext_data_in_old),
        .debug_wr_enable(debug_wr_enable)
        
    );

    // Verilog/SV "%" сохраняет знак ДЕЛИМОГО (в отличие от Python "%",
    // который всегда даёт результат со знаком ДЕЛИТЕЛЯ, т.е. неотрицательный
    // для положительного модуля) - raw=(n*37-500) отрицательно для первых
    // push_idx, так что голый "%" тут дал бы другую последовательность,
    // чем cocotb. Явно приводим к диапазону [0, 65536) как в Python.
    function automatic integer py_mod65536(input integer x);
        integer r;
        begin
            r = x % 65536;
            if (r < 0) r = r + 65536;
            py_mod65536 = r;
        end
    endfunction

    // -----------------------------------------------------------------
    // Python-модель (BoxcarModel в test_mv_avg.py) 1:1 в SV: скользящее
    // окно (полный лог отправленных значений, тестовый прогон короткий,
    // так что не мудрим с кольцевым буфером) + бегущая сумма РОВНО в
    // TOTAL_WIDTH бит, чтобы точно повторить 2's complement wraparound
    // самого mv_avg.v (data_out - обычный bit-slice [TOTAL_WIDTH-1:LOG2_AVG_LEN]).
    // -----------------------------------------------------------------
    reg signed [DATA_WIDTH-1:0]  history [0:NUM_PUSHES-1];
    reg signed [TOTAL_WIDTH-1:0] running_total_model;
    reg signed [DATA_WIDTH-1:0]  expected_q [0:NUM_PUSHES-1];
    integer q_head, q_tail;

    integer push_idx;
    reg     driving;

    integer checked_count;
    integer mismatch_count;
    reg     settle_pending;
    reg signed [DATA_WIDTH-1:0] exp;

    // Скретч-переменные для вычислений внутри always-блока ниже (blocking,
    // локальные для этого же такта - не самостоятельное состояние).
    integer raw;
    reg signed [DATA_WIDTH-1:0] v;
    reg signed [DATA_WIDTH-1:0] evicted;
    reg signed [TOTAL_WIDTH-1:0] next_total;

    initial begin
        rstn = 0;
        data_in_valid = 0;
        data_in = 0;
        push_idx = 0;
        driving = 0;
        q_head = 0;
        q_tail = 0;
        running_total_model = 0;
        checked_count = 0;
        mismatch_count = 0;
        settle_pending = 0;

        repeat (10) @(posedge clk);
        rstn = 1;
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
            $display("PASS: все %0d проверок совпали с моделью", checked_count);
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

    // -----------------------------------------------------------------
    // Единый процесс: сначала проверка (по settle_pending, выставленному
    // на ПРОШЛОМ такте), потом драйв следующего отсчёта - оба в одном
    // always-блоке, порядок между ними детерминирован самим Verilog'ом
    // (последовательные операторы одного process'а), гонки нет.
    // -----------------------------------------------------------------
    always @(posedge clk) begin
        if (settle_pending) begin
            if (q_head >= q_tail) begin
                $display("[%0t] FAIL: wr_complete_pulse взвёлся, а очередь ожидаемых значений пуста", $time);
                mismatch_count = mismatch_count + 1;
            end else begin
                exp = expected_q[q_head];
                q_head = q_head + 1;
                if (data_out !== exp) begin
                    mismatch_count = mismatch_count + 1;
                    if (mismatch_count <= 30)
                        $display("[%0t] MISMATCH #%0d: got data_out=%0d, ожидалось %0d",
                                  $time, checked_count, $signed(data_out), $signed(exp));
                end
                checked_count = checked_count + 1;
            end
        end
        settle_pending <= dut.wr_complete_pulse;

        if (driving && push_idx < NUM_PUSHES) begin
            raw = push_idx * 37 - 500;
            v = py_mod65536(raw) - 32768;
            evicted = (push_idx >= FIFO_SIZE) ? history[push_idx - FIFO_SIZE] : 16'sd0;
            next_total = running_total_model + v - evicted;

            data_in <= v;
            data_in_valid <= 1'b1;
            running_total_model <= next_total;
            history[push_idx] <= v;
            expected_q[q_tail] <= next_total[TOTAL_WIDTH-1:LOG2_AVG_LEN];
            q_tail <= q_tail + 1;
            push_idx <= push_idx + 1;
        end
    end

endmodule

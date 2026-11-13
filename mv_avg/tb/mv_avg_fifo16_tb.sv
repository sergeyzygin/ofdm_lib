`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Минимальный, легко пересчитываемый вручную тестбенч для того же дефекта,
// что и cocotb-версия tb/cocotb_fifo16/test_mv_avg_fifo16.py (см. её
// докстринг и обсуждение в чате) - зеркальный SV-тестбенч для Vivado/xsim,
// чтобы подтвердить/опровергнуть баг на НАСТОЯЩЕМ xpm_fifo_sync.
//
// FIFO_SIZE=16 (LOG2_AVG_LEN=4), вход v(n) = n+1 (1,2,3,...), непрерывный
// поток без пауз. Формула - обычная арифметическая прогрессия, поэтому
// ожидаемое значение running_total считается в одну строку:
//
//     running_total(i) = sum(v(0)..v(i))              для i < FIFO_SIZE
//                       = sum(v(i-FIFO_SIZE+1)..v(i))  для i >= FIFO_SIZE
//                         (сумма последних FIFO_SIZE подряд идущих v(n) -
//                         арифметическая прогрессия в обоих случаях, т.к.
//                         вытеснение самого старого просто сдвигает то же
//                         окно на 1 позицию)
//
// ПОЧЕМУ v(n)=n+1, а не просто v(n)=n: более ранняя версия этого теста
// (см. чат) использовала v(n)=n, то есть v(0)=0 - и тест ЛОЖНО проходил,
// хотя дефект реально присутствует. Найденный механизм (изолирован через
// бисекцию данных test_mv_avg_back_to_back до минимального репродюсера):
// РОВНО в тот такт, когда has_been_full первый раз становится 1,
// running_total теряет ровно значение САМОГО ПЕРВОГО когда-либо
// отправленного отсчёта (v(0)) - независимо от его знака и величины.
// Подтверждено прямым сравнением dut.running_total с dut.debug_ext_data_in_old
// в cocotb: debug_ext_data_in_old корректно показывал v(0) в этот момент,
// но running_total всё равно оказывался меньше ровно на v(0). При v(0)=0
// эта потеря невидима (вычитание нуля ничего не меняет) - именно поэтому
// v(n)=n был ложноположительным тестом. v(n)=n+1 даёт v(0)=1≠0, и дефект
// перестаёт маскироваться, оставаясь при этом тривиально пересчитываемым
// вручную.
//
// Пример вручную вокруг границы (FIFO_SIZE=16):
//     i=13 (14-й push, v=14, окно ещё заполняется): running_total=14*15/2=105
//     i=14 (15-й push, v=15, окно ТОЛЬКО ЧТО заполнилось,
//           вытеснения ещё нет):                    running_total=15*16/2=120
//     i=15 (16-й push, v=16, ПЕРВЫЙ раз вытесняется
//           history[0]=v(0)=1):                      running_total=16*16-120=136
//     i=16 (17-й push, v=17, вытесняется history[1]=v(1)=2): running_total=16*17-120=152
//
// Если дефект присутствует, на i=15 (и далее) running_total будет МЕНЬШЕ
// ожидаемого ровно на v(0)=1 - сравниваем именно СЫРОЙ (до сдвига)
// dut.running_total (обычный top-level регистр mv_avg.v, доступен
// напрямую как white-box иерархическая ссылка), а не только data_out,
// т.к. потеря всего в 1 после >>4 может не пережить округление сдвигом.
//
// Синхронизация проверки - через dut.wr_complete_pulse (тот же самый
// внутренний сигнал, что гейтит собственное обновление running_total в
// mv_avg.v: `if (wr_complete_pulse) running_total <= ...`), как и в
// mv_avg_back_to_back_tb.sv - никакой ручной задержки подбирать не нужно.
//
// ВСЁ (драйв стимула + проверка) - в ОДНОМ always-блоке, чтобы избежать
// гонки между независимыми процессами на одном фронте (см. историю
// доработки mv_avg_back_to_back_tb.sv в чате - первая версия С ДВУМЯ
// процессами давала ложное расхождение с самого первого отсчёта).
//////////////////////////////////////////////////////////////////////////////////

module mv_avg_fifo16_tb;

    localparam DATA_WIDTH   = 16;
    localparam LOG2_AVG_LEN = 4;                 // FIFO_SIZE=16
    localparam FIFO_SIZE    = 1 << LOG2_AVG_LEN;
    localparam TOTAL_WIDTH  = DATA_WIDTH + LOG2_AVG_LEN;

    localparam CLK_PERIOD  = 4;
    localparam NUM_PUSHES  = FIFO_SIZE * 3;      // 48 - далеко за границей, всё ещё тривиально пересчитывается

    reg clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg rstn = 0;
    reg  signed [DATA_WIDTH-1:0] data_in = 0;
    reg                          data_in_valid = 0;
    wire signed [DATA_WIDTH-1:0] data_out;
    wire                         data_out_valid;
//debug
    wire [LOG2_AVG_LEN:0] rd_data_count;
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

    function automatic integer v(input integer n);
        v = n + 1;
    endfunction

    // Сумма v(lo)..v(hi) - арифметическая прогрессия, cnt*(first+last)/2.
    function automatic integer signed expected_running_total(input integer i);
        integer lo, hi, cnt;
        begin
            if (i < FIFO_SIZE) begin
                lo = 0;
                hi = i;
            end else begin
                lo = i - FIFO_SIZE + 1;
                hi = i;
            end
            cnt = hi - lo + 1;
            expected_running_total = (cnt * (lo + hi + 2)) / 2;
        end
    endfunction

    integer push_idx;
    reg     driving;

    integer checked_count;
    integer mismatch_count;
    reg     settle_pending;
    integer signed raw_exp;
    integer signed raw_got;

    initial begin
        rstn = 0;
        data_in_valid = 0;
        data_in = 0;
        push_idx = 0;
        driving = 0;
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
            $display("PASS: все %0d проверок совпали с ручным расчётом", checked_count);
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
        if (settle_pending) begin
            raw_exp = expected_running_total(checked_count);
            raw_got = $signed(dut.running_total);
            if (raw_got !== raw_exp) begin
                mismatch_count = mismatch_count + 1;
                if (mismatch_count <= 20)
                    $display("[%0t] MISMATCH #%0d (push v=%0d): raw running_total=%0d, ожидалось %0d (diff=%0d, v(0)=%0d - если diff==-v(0), это тот самый дефект)",
                              $time, checked_count, v(checked_count), raw_got, raw_exp, raw_got - raw_exp, v(0));
            end
            checked_count = checked_count + 1;
        end
        settle_pending <= dut.wr_complete_pulse;

        if (driving && push_idx < NUM_PUSHES) begin
            data_in <= v(push_idx);
            data_in_valid <= 1'b1;
            push_idx <= push_idx + 1;
        end
    end

endmodule

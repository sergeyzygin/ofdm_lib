`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Минимальный, легко пересчитываемый вручную тестбенч для mv_avg_dual_ch,
// по образцу mv_avg/tb/mv_avg_fifo16_tb.sv (см. её докстринг и обсуждение
// в чате про найденный дефект "-v(0) при первом has_been_full").
//
// ВАЖНО: написан НЕ под текущий интерфейс mv_avg_dual_ch.v, а под тот же
// паттерн, что уже используется в mv_avg.v ПОСЛЕ переделки (has_been_full/
// rd_data_count-подход) - mv_avg_dual_ch.v планируется переписать так же
// (см. чат), и этот тестбенч должен остаться валиден и ПОСЛЕ этой переделки,
// а не только для текущей (старой, data_out_valid=wr_complete_pulse_reg)
// версии модуля. Поэтому:
//   - синхронизация проверки идёт через dut.wr_complete_pulse (уже сейчас
//     существующий top-level wire в mv_avg_dual_ch.v: `assign
//     wr_complete_pulse = wr_ack;`) - этот сигнал и его роль (гейтит
//     `if (wr_complete_pulse) running_total0/1 <= ...`) сохранились в
//     mv_avg.v в неизменном виде после переделки, значит имя и семантика
//     переживут аналогичную переделку и здесь;
//   - проверяется СЫРОЙ dut.running_total0/dut.running_total1 (whitebox,
//     top-level регистры), а не data_out0/1/data_out_valid - поскольку
//     ИМЕННО семантика data_out_valid поменяется при переделке (сейчас
//     pulse через wr_complete_pulse_reg, после - вероятно sticky level
//     через has_been_full, как в mv_avg.v), а running_total - это
//     внутренняя истина, не зависящая от того, как её потом выставляют
//     наружу;
//   - проверка идёт РОВНО через 1 такт ПОСЛЕ wr_complete_pulse (через
//     settle_pending), как в mv_avg_fifo16_tb.sv - это тайминг, который
//     сохранился после переделки mv_avg.v (data_in_reg/wr_ack оба
//     регистрируются на 1 такт, running_total обновляется тем же тактом,
//     что wr_complete_pulse, видно с следующего такта).
//
// На ТЕКУЩЕЙ (пока не переделанной) версии mv_avg_dual_ch.v этот тест
// тоже должен корректно работать как baseline "до" - даёт возможность
// сравнить поведение до/после переделки на одних и тех же данных.
//
// FIFO_SIZE=16 (LOG2_AVG_LEN=4), два независимых канала:
//   v0(n) = n+1  (1,2,3,...)
//   v1(n) = n+2  (2,3,4,...)
// оба заведомо ненулевые при n=0 - см. mv_avg_fifo16_tb.sv про то, почему
// v(0)=0 маскирует реальный дефект (там же обнаружено: РОВНО в момент
// первого has_been_full=1 running_total теряет ровно значение самого
// первого отправленного отсчёта). Разные по величине последовательности на
// двух каналах - чтобы заодно проверить, не путаются ли каналы местами
// (data_in0/data_in1 <-> data_out0/data_out1) где-нибудь внутри.
//
// Ожидаемые значения - обычные арифметические прогрессии:
//     running_total0(i) = sum(v0 по последним FIFO_SIZE отсчётам, включая i)
//     running_total1(i) = sum(v1 по последним FIFO_SIZE отсчётам, включая i)
//
// Пример вручную вокруг границы (FIFO_SIZE=16):
//     i=14 (15-й push, окно ТОЛЬКО ЧТО заполнилось, вытеснения ещё нет):
//         running_total0 = sum(1..15) = 120
//         running_total1 = sum(2..16) = 135
//     i=15 (16-й push, ПЕРВЫЙ раз вытесняется history[0]):
//         running_total0 = sum(1..16) = 136   (v0(0)=1 ещё внутри)
//         running_total1 = sum(2..17) = 152   (v1(0)=2 ещё внутри)
//     i=16 (17-й push, вытесняется history[1]):
//         running_total0 = sum(2..17) = 152   (v0(0)=1 вытеснен)
//         running_total1 = sum(3..18) = 168   (v1(0)=2 вытеснен)
//
// Если дефект (потеря v(0) при первом has_been_full) присутствует, на
// i=16 (или где бы граница ни оказалась после переделки) running_total0
// будет меньше ожидаемого ровно на v0(0)=1, running_total1 - ровно на
// v1(0)=2.
//////////////////////////////////////////////////////////////////////////////////

module mv_avg_dual_ch_fifo16_tb;

    localparam DATA_WIDTH0  = 16;
    localparam DATA_WIDTH1  = 16;
    localparam LOG2_AVG_LEN = 4;                  // FIFO_SIZE=16
    localparam FIFO_SIZE    = 1 << LOG2_AVG_LEN;
    localparam TOTAL_WIDTH0 = DATA_WIDTH0 + LOG2_AVG_LEN;
    localparam TOTAL_WIDTH1 = DATA_WIDTH1 + LOG2_AVG_LEN;

    localparam CLK_PERIOD = 4;
    localparam NUM_PUSHES = FIFO_SIZE * 3;        // 48 - далеко за границей, всё ещё тривиально пересчитывается

    reg clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg rstn = 0;
    reg  signed [DATA_WIDTH0-1:0] data_in0 = 0;
    reg  signed [DATA_WIDTH1-1:0] data_in1 = 0;
    reg                           data_in_valid = 0;
    wire signed [DATA_WIDTH0-1:0] data_out0;
    wire signed [DATA_WIDTH1-1:0] data_out1;
    wire                          data_out_valid;

    mv_avg_dual_ch #(
        .DATA_WIDTH0(DATA_WIDTH0),
        .DATA_WIDTH1(DATA_WIDTH1),
        .LOG2_AVG_LEN(LOG2_AVG_LEN)
    ) dut (
        .clk(clk),
        .rstn(rstn),
        .data_in0(data_in0),
        .data_in1(data_in1),
        .data_in_valid(data_in_valid),
        .data_out0(data_out0),
        .data_out1(data_out1),
        .data_out_valid(data_out_valid)
    );

    function automatic integer v0(input integer n);
        v0 = n + 1;
    endfunction

    function automatic integer v1(input integer n);
        v1 = n + 2;
    endfunction

    // Сумма арифметической прогрессии по последним FIFO_SIZE (или меньше,
    // пока окно ещё заполняется) отсчётам, оканчивающейся на индексе i.
    // first_offset - смещение первого члена последовательности (1 для v0,
    // 2 для v1), т.к. v0(n)=n+1 и v1(n)=n+2 отличаются только этим.
    function automatic integer signed expected_running_total(input integer i, input integer first_offset);
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
            // sum(v(lo)..v(hi)) = cnt * (first_term + last_term) / 2
            //                   = cnt * ((lo+first_offset) + (hi+first_offset)) / 2
            expected_running_total = (cnt * (lo + hi + 2 * first_offset)) / 2;
        end
    endfunction

    integer push_idx;
    reg     driving;

    integer checked_count;
    integer mismatch_count;
    reg     settle_pending;
    integer signed raw_exp0, raw_exp1;
    integer signed raw_got0, raw_got1;

    initial begin
        rstn = 0;
        data_in_valid = 0;
        data_in0 = 0;
        data_in1 = 0;
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
            $display("PASS: все %0d проверок совпали с ручным расчётом (оба канала)", checked_count);
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
            raw_exp0 = expected_running_total(checked_count, 1);
            raw_exp1 = expected_running_total(checked_count, 2);
            raw_got0 = $signed(dut.running_total0);
            raw_got1 = $signed(dut.running_total1);
            if (raw_got0 !== raw_exp0 || raw_got1 !== raw_exp1) begin
                mismatch_count = mismatch_count + 1;
                if (mismatch_count <= 20)
                    $display("[%0t] MISMATCH #%0d (push v0=%0d v1=%0d): ch0 got=%0d exp=%0d (diff=%0d) | ch1 got=%0d exp=%0d (diff=%0d) [v0(0)=%0d v1(0)=%0d]",
                              $time, checked_count, v0(checked_count), v1(checked_count),
                              raw_got0, raw_exp0, raw_got0 - raw_exp0,
                              raw_got1, raw_exp1, raw_got1 - raw_exp1,
                              v0(0), v1(0));
            end
            checked_count = checked_count + 1;
        end
        settle_pending <= dut.wr_complete_pulse;

        if (driving && push_idx < NUM_PUSHES) begin
            data_in0 <= v0(push_idx);
            data_in1 <= v1(push_idx);
            data_in_valid <= 1'b1;
            push_idx <= push_idx + 1;
        end
    end

endmodule

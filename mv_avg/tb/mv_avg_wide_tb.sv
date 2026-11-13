`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Тест mv_avg НА ТОЙ ЖЕ ШИРИНЕ, что реально используется в detect_sts.v для
// mag_sq_avg_inst: DATA_WIDTH=33, LOG2_AVG_LEN=4 (WINDOW_SHIFT) - см. чат.
//
// mv_avg_fifo16_tb.sv (DATA_WIDTH=16) уже подтверждён PASS на реальном
// Vivado (через mv_avg_back_to_back_tb.sv, тот же движок), но detect_sts.v
// использует mv_avg СОВСЕМ на другой ширине (33 бита, TOTAL_WIDTH=37) -
// эта конкретная конфигурация НИКОГДА не проверялась на реальном железе.
//
// Мотивация: detect_sts на реальном Vivado подтверждённо РАБОТАЕТ на
// iq_dump_one1.cf32 (114/123 срабатываний, почти как эталон cocotb - см.
// чат), где amplitude маленькая (|x| до ~2334, mag_sq до ~5.4M) - но ДАЁТ
// 0 срабатываний на tx_iq_dump.cf32 (M=32), где amplitude намного больше
// (|x| до ~29000, mag_sq до ~1.1 млрд) - при этом сырая периодичность в
// tx_iq_dump.cf32 подтверждена Python-анализом как ПОЧТИ ИДЕАЛЬНАЯ
// (x[n]==x[n-16] точно, ratio=1.000, с n~20 и далее). Раз сам пайплайн
// (complex_mult/complex_to_mag_sq - проверено побитово в Python) считает
// корректно на ЭТИХ амплитудах, подозрение падает на аккумулятор mv_avg
// именно на ЭТОЙ (широкой, непроверенной) конфигурации ширины - возможно,
// с большими 32/33-битными значениями что-то в xpm_fifo_sync/running_total
// ведёт себя иначе, чем на маленьких 16-битных значениях, на которых тест
// был подтверждён раньше.
//
// v(n) = 100_000_000 + n*7_000_000 - тот же порядок величины, что реальный
// mag_sq на tx_iq_dump.cf32 (сотни миллионов), простая арифметическая
// прогрессия (легко пересчитывается вручную), v(0)=100_000_000 =/= 0 (см.
// чат про то, почему v(0)=0 маскирует реальный дефект).
//
// ВАЖНО: значения выходят за диапазон 32-битного Verilog `integer` (сумма
// 16 отсчётов ~4.2 млрд) - используем SystemVerilog `longint` для
// ожидаемых сумм и сравнения, иначе сам тестбенч был бы некорректен.
//
// Методика (единый always-блок, синхронизация через dut.wr_complete_pulse,
// сравнение raw dut.running_total) - 1:1 повтор mv_avg_fifo16_tb.sv.
//////////////////////////////////////////////////////////////////////////////////

module mv_avg_wide_tb;

    localparam DATA_WIDTH   = 33;                // как mag_sq_avg_inst в detect_sts.v
    localparam LOG2_AVG_LEN = 4;                 // FIFO_SIZE=16, как WINDOW_SHIFT в detect_sts.v
    localparam FIFO_SIZE    = 1 << LOG2_AVG_LEN;
    localparam TOTAL_WIDTH  = DATA_WIDTH + LOG2_AVG_LEN; // 37

    localparam CLK_PERIOD  = 4;
    localparam NUM_PUSHES  = FIFO_SIZE * 3;      // 48

    reg clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg rstn = 0;
    reg  signed [DATA_WIDTH-1:0] data_in = 0;
    reg                          data_in_valid = 0;
    wire signed [DATA_WIDTH-1:0] data_out;
    wire                         data_out_valid;
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
        .rd_data_count(rd_data_count),
        .has_been_full(has_been_full),
        .debug_ext_data_in_old(debug_ext_data_in_old),
        .debug_wr_enable(debug_wr_enable)
    );

    function automatic longint v(input integer n);
        v = longint'(100_000_000) + longint'(n) * longint'(7_000_000);
    endfunction

    // Сумма v(lo)..v(hi) - арифметическая прогрессия, cnt*(first+last)/2.
    function automatic longint expected_running_total(input integer i);
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
            expected_running_total = (longint'(cnt) * (v(lo) + v(hi))) / 2;
        end
    endfunction

    integer push_idx;
    reg     driving;

    integer checked_count;
    integer mismatch_count;
    reg     settle_pending;
    longint raw_exp;
    longint raw_got;

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
            $display("PASS: все %0d проверок совпали с ручным расчётом (DATA_WIDTH=%0d, как в detect_sts.v)", checked_count, DATA_WIDTH);
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
            raw_got = longint'($signed(dut.running_total));
            if (raw_got !== raw_exp) begin
                mismatch_count = mismatch_count + 1;
                if (mismatch_count <= 20)
                    $display("[%0t] MISMATCH #%0d (push v=%0d): raw running_total=%0d, ожидалось %0d (diff=%0d)",
                              $time, checked_count, v(checked_count), raw_got, raw_exp, raw_got - raw_exp);
            end
            checked_count = checked_count + 1;
        end
        settle_pending <= dut.wr_complete_pulse;

        if (driving && push_idx < NUM_PUSHES) begin
            data_in <= DATA_WIDTH'(v(push_idx));
            data_in_valid <= 1'b1;
            push_idx <= push_idx + 1;
        end
    end

endmodule

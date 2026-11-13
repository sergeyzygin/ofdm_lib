`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Тест mv_avg_dual_ch НА ТОЙ ЖЕ ШИРИНЕ, что реально используется в
// detect_sts.v для delay_prod_avg_inst: DATA_WIDTH0=DATA_WIDTH1=32,
// LOG2_AVG_LEN=4 - см. mv_avg/tb/mv_avg_wide_tb.sv (парный тест для
// mv_avg/mag_sq_avg_inst) и обсуждение в чате для полной мотивации.
//
// Коротко: detect_sts на реальном Vivado подтверждённо работает на
// iq_dump_one1.cf32 (амплитуда маленькая, |x| до ~2334), но даёт 0
// срабатываний на tx_iq_dump.cf32 (амплитуда намного больше, |x| до
// ~29000), при том что периодичность сигнала в tx_iq_dump.cf32 подтверждена
// Python-анализом как ПОЧТИ ИДЕАЛЬНАЯ. mv_avg_dual_ch.v (delay_prod_avg_inst)
// раньше проверялся на реальном железе ТОЛЬКО на 16-битной ширине
// (mv_avg_dual_ch_fifo16_tb.sv) - широкая (32-битная) конфигурация,
// РЕАЛЬНО используемая в detect_sts.v для усреднения комплексного продукта
// корреляции (который на tx_iq_dump.cf32 достигает сотен миллионов по
// модулю), никогда не проверялась на реальном железе.
//
// В отличие от mag_sq (всегда >=0), продукт корреляции prod_i/prod_q может
// быть ОТРИЦАТЕЛЬНЫМ - поэтому здесь канал 1 (v1) знакопеременный, чтобы
// заодно проверить накопление отрицательных широких значений (чего
// mv_avg_wide_tb.sv не проверяет - там только положительные v(n)).
//
// v0(n) = 100_000_000 + n*5_000_000                (всегда положительный)
// v1(n) = +-(50_000_000 + n*3_000_000), знак чередуется по чётности n
//
// Ожидаемая сумма считается ПРОСТЫМ ЦИКЛОМ по последним FIFO_SIZE
// отсчётам (не закрытой формулой арифметической прогрессии, т.к. v1
// знакопеременный) - тривиально проверяется по построению, не требует
// арифметики в уме. `longint`, т.к. сумма (до ~2.5 млрд) не помещается в
// 32-битный Verilog `integer`.
//
// Методика (единый always-блок, синхронизация через dut.wr_complete_pulse,
// сравнение raw dut.running_total0/1) - 1:1 повтор
// mv_avg_dual_ch_fifo16_tb.sv.
//////////////////////////////////////////////////////////////////////////////////

module mv_avg_dual_ch_wide_tb;

    localparam DATA_WIDTH0  = 32;                 // как delay_prod_avg_inst в detect_sts.v
    localparam DATA_WIDTH1  = 32;
    localparam LOG2_AVG_LEN = 4;                  // FIFO_SIZE=16, как WINDOW_SHIFT в detect_sts.v
    localparam FIFO_SIZE    = 1 << LOG2_AVG_LEN;

    localparam CLK_PERIOD = 4;
    localparam NUM_PUSHES = FIFO_SIZE * 3;        // 48

    reg clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg rstn = 0;
    reg  signed [DATA_WIDTH0-1:0] data_in0 = 0;
    reg  signed [DATA_WIDTH1-1:0] data_in1 = 0;
    reg                           data_in_valid = 0;
    wire signed [DATA_WIDTH0-1:0] data_out0;
    wire signed [DATA_WIDTH1-1:0] data_out1;
    wire                          data_out_valid;
    wire [LOG2_AVG_LEN:0] rd_data_count;
    wire has_been_full;
    wire signed [DATA_WIDTH0-1:0] debug_ext_data_in_old0;
    wire signed [DATA_WIDTH1-1:0] debug_ext_data_in_old1;
    wire debug_wr_enable;

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
        .data_out_valid(data_out_valid),
        .rd_data_count(rd_data_count),
        .has_been_full(has_been_full),
        .debug_ext_data_in_old0(debug_ext_data_in_old0),
        .debug_ext_data_in_old1(debug_ext_data_in_old1),
        .debug_wr_enable(debug_wr_enable)
    );

    function automatic longint v0(input integer n);
        v0 = longint'(100_000_000) + longint'(n) * longint'(5_000_000);
    endfunction

    function automatic longint v1(input integer n);
        longint mag;
        begin
            mag = longint'(50_000_000) + longint'(n) * longint'(3_000_000);
            v1 = (n % 2 == 0) ? mag : -mag;
        end
    endfunction

    // Сумма последних FIFO_SIZE (или меньше, пока окно заполняется)
    // отсчётов, оканчивающихся на индексе i - простой цикл, работает для
    // любой последовательности (в т.ч. знакопеременной v1).
    function automatic longint expected_running_total(input integer i, input int use_ch1);
        integer lo, hi, k;
        longint sum;
        begin
            if (i < FIFO_SIZE) begin lo = 0; hi = i; end
            else begin lo = i - FIFO_SIZE + 1; hi = i; end
            sum = 0;
            for (k = lo; k <= hi; k = k + 1)
                sum = sum + (use_ch1 ? v1(k) : v0(k));
            expected_running_total = sum;
        end
    endfunction

    integer push_idx;
    reg     driving;

    integer checked_count;
    integer mismatch_count;
    reg     settle_pending;
    longint raw_exp0, raw_exp1;
    longint raw_got0, raw_got1;

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
            $display("PASS: все %0d проверок совпали с ручным расчётом (оба канала, DATA_WIDTH=%0d/%0d, как в detect_sts.v)", checked_count, DATA_WIDTH0, DATA_WIDTH1);
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
            raw_exp0 = expected_running_total(checked_count, 0);
            raw_exp1 = expected_running_total(checked_count, 1);
            raw_got0 = longint'($signed(dut.running_total0));
            raw_got1 = longint'($signed(dut.running_total1));
            if (raw_got0 !== raw_exp0 || raw_got1 !== raw_exp1) begin
                mismatch_count = mismatch_count + 1;
                if (mismatch_count <= 20)
                    $display("[%0t] MISMATCH #%0d (push v0=%0d v1=%0d): ch0 got=%0d exp=%0d (diff=%0d) | ch1 got=%0d exp=%0d (diff=%0d)",
                              $time, checked_count, v0(checked_count), v1(checked_count),
                              raw_got0, raw_exp0, raw_got0 - raw_exp0,
                              raw_got1, raw_exp1, raw_got1 - raw_exp1);
            end
            checked_count = checked_count + 1;
        end
        settle_pending <= dut.wr_complete_pulse;

        if (driving && push_idx < NUM_PUSHES) begin
            data_in0 <= DATA_WIDTH0'(v0(push_idx));
            data_in1 <= DATA_WIDTH1'(v1(push_idx));
            data_in_valid <= 1'b1;
            push_idx <= push_idx + 1;
        end
    end

endmodule

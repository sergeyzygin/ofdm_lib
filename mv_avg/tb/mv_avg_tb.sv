`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Прицельный тестбенч для mv_avg (см. обсуждение в чате: подозрение на баг
// в data_in_old_reg - защёлкивается БЕЗУСЛОВНО каждый такт из живого dout
// FIFO, а не именно в момент pop'а, из-за чего при непрерывном full-rate
// потоке (rd_en взводится каждый такт) к моменту фактического использования
// (wr_complete_pulse_reg, это на 2 такта позже rd_en) в data_in_old_reg уже
// лежит СЛЕДУЮЩЕЕ значение dout, а не то, что реально было вытолкнуто из
// окна для этой конкретной пары push/evict).
//
// Тестовый сигнал специально выбран так, чтобы баг было легко поймать:
// периодическая последовательность 0,1,2,...,FIFO_SIZE-1,0,1,2,... с
// периодом ровно FIFO_SIZE. После первого полного заполнения окна
// ПРАВИЛЬНОЕ скользящее среднее обязано стать константой (окно всегда
// содержит ровно один полный период {0..15}, сумма = 120, avg = 7) и
// больше никогда не меняться, независимо от фазы. Если пары push/evict
// в железе спутаны, среднее либо не устаканится в 7, либо продолжит
// "плыть" - именно то поведение, что видно на реальной ИЛА (mag_sq_avg
// плавно и монотонно растёт, а не замирает на true-среднем).
//
// Непрерывный поток (data_in_valid=1 каждый такт, без пауз) - намеренно,
// чтобы full=1 держался стабильно и rd_en/wr_en взводились каждый такт,
// точно как в реальной системе при непрерывном потоке отсчётов с АЦП.
//////////////////////////////////////////////////////////////////////////////////

module mv_avg_tb;

    localparam DATA_WIDTH   = 16;
    localparam LOG2_AVG_LEN = 4;                 // FIFO_SIZE = 16, как mag_sq_avg_inst в detect_sts.v
    localparam FIFO_SIZE    = 1 << LOG2_AVG_LEN;

    localparam signed [31:0] PERIOD_SUM  = (FIFO_SIZE-1)*FIFO_SIZE/2; // 0+1+...+15 = 120
    localparam signed [31:0] EXPECTED_AVG = PERIOD_SUM / FIFO_SIZE;    // 120/16 = 7 (без остатка)

    localparam CLK_PERIOD = 4;
    localparam NUM_PUSHES = 40 * FIFO_SIZE; // много периодов - если баг накопительный, будет видно по дрейфу

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

    // -----------------------------------------------------------------
    // Драйвер: непрерывный периодический паттерн 0..FIFO_SIZE-1, без пауз.
    // -----------------------------------------------------------------
    integer push_idx;
    integer valid_count = 0;
    integer checked_count = 0;
    integer mismatch_count = 0;

    initial begin
        push_idx = 0;
        data_in = 0;
        data_in_valid = 0;

        rstn = 0;
        repeat (20) @(posedge clk);
        rstn = 1;
        repeat (10) @(posedge clk); // время на wr_rst_busy/rd_rst_busy handshake внутри xpm_fifo_sync

        data_in_valid <= 1'b1;
        data_in       <= push_idx % (FIFO_SIZE*4);

        for (push_idx = 1; push_idx < NUM_PUSHES; push_idx = push_idx + 1) begin
            @(posedge clk);
            data_in <= push_idx % (FIFO_SIZE*4);
        end

        @(posedge clk);
        data_in_valid <= 1'b0;

        repeat (50) @(posedge clk); // слив конвейера
        $display("-----------------------------------------------------");
        $display("mismatch_count = %0d / checked_count = %0d", mismatch_count, checked_count);
        if (checked_count == 0)
            $display("FAIL: data_out_valid ни разу не поднялся - тест не проверил вообще ничего");
        else if (mismatch_count == 0)
            $display("PASS: скользящее среднее устойчиво равно ожидаемому %0d на всех %0d проверках после заполнения окна",
                      EXPECTED_AVG, checked_count);
        else
            $display("FAIL: %0d из %0d проверок разошлись с ожидаемым %0d - см. лог выше",
                      mismatch_count, checked_count, EXPECTED_AVG);
        $display("-----------------------------------------------------");
        $finish;
    end

    initial begin
        #(200_000);
        $display("[%0t] TIMEOUT - симуляция не завершилась штатно", $time);
        $finish;
    end

    // -----------------------------------------------------------------
    // Самопроверка: пропускаем первые FIFO_SIZE успешных выдач (пока окно
    // ещё не видело ни одного полного периода целиком), дальше каждая
    // выдача обязана быть ровно EXPECTED_AVG.
    // -----------------------------------------------------------------

    always @(posedge clk) begin
        if (data_out_valid) begin
            valid_count = valid_count + 1;
            if (valid_count > FIFO_SIZE) begin
                checked_count = checked_count + 1;
                if (data_out !== EXPECTED_AVG[DATA_WIDTH-1:0]) begin
                    mismatch_count = mismatch_count + 1;
                    if (mismatch_count <= 20)
                        $display("[%0t] MISMATCH #%0d: data_out=%0d (0x%0h), ожидалось %0d, running_total=%0d (valid_count=%0d)",
                                  $time, mismatch_count, $signed(data_out), data_out, EXPECTED_AVG,
                                  $signed(dut.running_total), valid_count);
                end
            end
        end
    end

endmodule

`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// ВНИМАНИЕ: это НЕ настоящий Xilinx xpm_fifo_sync.
//
// В отличие от cmpy_0 (LogiCORE, требует .xci), xpm_fifo_sync - это XPM-макрос:
// открытый (не зашифрованный) SystemVerilog из поставки Vivado
// ($XILINX_VIVADO/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv), который Vivado
// резолвит напрямую и при синтезе, и при xsim-симуляции - отдельный .xci не
// нужен. Но файл на ~5100 строк, поддерживает множество режимов (async/sync,
// ECC, разные memory primitives) и не рассчитан на сборку Verilator'ом.
//
// Эта модель - лёгкая поведенческая замена ТОЛЬКО для cocotb/Verilator,
// реализующая именно ту конфигурацию, которую использует mv_avg.v:
//   READ_MODE  = "fwft"  (dout уже готов ДО rd_en - настоящий prefetch,
//                         а не комбинационное чтение mem[rd_ptr] "вживую")
//   FIFO_READ_LATENCY = 0 (без ДОПОЛНИТЕЛЬНОГО выходного регистра поверх
//                         FWFT - но сам FWFT в реальном xpm_fifo.sv все
//                         равно реализован как 2-ступенчатый prefetch-буфер
//                         (см. gen_fwft/curr_fwft_state FSM в исходнике),
//                         НЕ как голое mem[rd_ptr]!)
//   один клок (wr_clk = rd_clk), синхронный rst
//   wr_data_count/rd_data_count - зарегистрированный счётчик заполнения,
//                         виден через 1 такт после wr_en/rd_en (mv_avg.v сам
//                         на это рассчитан: wr_complete_pulse сравнивает
//                         wr_data_count с его версией на такт назад)
//
// ВАЖНО (найдено эмпирически, см. чат): ранняя версия этой модели читала
// dout КОМБИНАЦИОННО как mem[rd_ptr], с rd_ptr, продвигающимся сразу по
// rd_en - то есть к моменту, когда потребитель (mv_avg.v) использует
// ЗАДЕРЖАННЫЙ на 1 такт wr_ack для гейта running_total, dout УЖЕ успевал
// уйти на СЛЕДУЮЩИЙ элемент очереди, а не тот, что реально был вытолкнут
// для ЭТОЙ пары push/evict. На реальном xpm_fifo_sync (проверено live в
// Vivado/xsim через mv_avg_tb.sv) этого расхождения нет - там FWFT честно
// реализован как prefetch-буфер на 2 ступени, и dout синхронизирован с
// wr_ack иначе. Модель ниже реализует такой же 2-ступенчатый prefetch
// (stage_a/stage_b), а не голое комбинационное чтение памяти.
//
// full/wr_en гейтятся как в реальном FIFO (запись при full молча
// блокируется, overflow=1 на 1 такт) - если mv_avg.v умудрится держать FIFO
// в состоянии full при непрерывном потоке valid-сэмплов, эта модель это
// честно повторит (включая потерю данных), а не скроет.
//
// prog_full/prog_empty/almost_full/almost_empty/ECC - не реализованы (не
// используются ни в одном из потребителей этого файла).
//
// USE_ADV_FEATURES реально декодируется (см. hex_nibble/EN_ADV_FEATURE
// ниже) и гейтит wr_ack/wr_data_count/rd_data_count ТОЧНО как в настоящем
// xpm_fifo.sv (assign wr_ack = EN_ADV_FEATURE[4] ? wr_ack_i : 1'b0; и т.п.).
// Раньше эта модель безусловно выдавала рабочий wr_ack независимо от
// параметра - из-за этого реальный баг (mv_avg держится на wr_ack, а
// USE_ADV_FEATURES="0404" бит 4 не включал) прошёл через все cocotb-тесты
// незамеченным и проявился только на живом железе. Модель исправлена задним
// числом ровно под этот случай - не гарантирует более широкой точности
// декодирования USE_ADV_FEATURES для конфигураций за пределами того, что
// реально используется в этом репозитории.
// Итоговое поведение всегда нужно подтверждать в Vivado/xsim с настоящим
// xpm_fifo_sync.
//////////////////////////////////////////////////////////////////////////////////

module xpm_fifo_sync #(
    parameter FIFO_MEMORY_TYPE     = "auto",
    parameter ECC_MODE             = "no_ecc",
    parameter integer SIM_ASSERT_CHK = 0,
    parameter integer CASCADE_HEIGHT = 0,

    parameter integer FIFO_WRITE_DEPTH = 2048,
    parameter integer WRITE_DATA_WIDTH = 32,
    parameter integer WR_DATA_COUNT_WIDTH = 1,
    parameter integer PROG_FULL_THRESH = 10,
    parameter integer FULL_RESET_VALUE = 0,
    parameter USE_ADV_FEATURES     = "0707",

    parameter READ_MODE            = "std",
    parameter integer FIFO_READ_LATENCY = 1,
    parameter integer READ_DATA_WIDTH = WRITE_DATA_WIDTH,
    parameter integer RD_DATA_COUNT_WIDTH = 1,
    parameter integer PROG_EMPTY_THRESH = 10,
    parameter DOUT_RESET_VALUE     = "0",

    parameter WAKEUP_TIME          = 0
) (
    input  wire sleep,
    input  wire rst,

    input  wire wr_clk,
    input  wire wr_en,
    input  wire [WRITE_DATA_WIDTH-1:0] din,
    output wire full,
    output wire prog_full,
    output wire [WR_DATA_COUNT_WIDTH-1:0] wr_data_count,
    output wire overflow,
    output wire wr_rst_busy,
    output wire almost_full,
    output wire wr_ack,

    input  wire rd_en,
    output wire [READ_DATA_WIDTH-1:0] dout,
    output wire empty,
    output wire prog_empty,
    output wire [RD_DATA_COUNT_WIDTH-1:0] rd_data_count,
    output wire underflow,
    output wire rd_rst_busy,
    output wire almost_empty,
    output wire data_valid,

    input  wire injectsbiterr,
    input  wire injectdbiterr,
    output wire sbiterr,
    output wire dbiterr
);

    // USE_ADV_FEATURES - 4-символьная hex-строка, как в xpm_fifo.sv
    // (hstr2bin): 1-й символ -> EN_ADV_FEATURE[15:12], ..., 4-й символ ->
    // EN_ADV_FEATURE[3:0]. Только то подмножество бит, что реально нужно
    // потребителям этого файла (2=wr_data_count, 4=wr_ack, 10=rd_data_count).
    function [3:0] hex_nibble;
        input [7:0] c;
        begin
            case (c)
                "0": hex_nibble = 4'h0; "1": hex_nibble = 4'h1;
                "2": hex_nibble = 4'h2; "3": hex_nibble = 4'h3;
                "4": hex_nibble = 4'h4; "5": hex_nibble = 4'h5;
                "6": hex_nibble = 4'h6; "7": hex_nibble = 4'h7;
                "8": hex_nibble = 4'h8; "9": hex_nibble = 4'h9;
                "a", "A": hex_nibble = 4'hA; "b", "B": hex_nibble = 4'hB;
                "c", "C": hex_nibble = 4'hC; "d", "D": hex_nibble = 4'hD;
                "e", "E": hex_nibble = 4'hE; "f", "F": hex_nibble = 4'hF;
                default:  hex_nibble = 4'h0;
            endcase
        end
    endfunction

    localparam [15:0] EN_ADV_FEATURE = {
        hex_nibble(USE_ADV_FEATURES[31:24]), hex_nibble(USE_ADV_FEATURES[23:16]),
        hex_nibble(USE_ADV_FEATURES[15:8]),  hex_nibble(USE_ADV_FEATURES[7:0])
    };
    localparam EN_WR_DATA_COUNT = EN_ADV_FEATURE[2];
    localparam EN_WACK          = EN_ADV_FEATURE[4];
    localparam EN_RD_DATA_COUNT = EN_ADV_FEATURE[10];

    localparam ADDR_WIDTH = (FIFO_WRITE_DEPTH <= 1) ? 1 : $clog2(FIFO_WRITE_DEPTH);

    reg [WRITE_DATA_WIDTH-1:0] mem [0:FIFO_WRITE_DEPTH-1];
    reg [ADDR_WIDTH-1:0] wr_ptr;      // следующий слот RAM для записи
    reg [ADDR_WIDTH-1:0] mem_rd_ptr;  // следующий НЕ ЗАСТЕЙДЖЕННЫЙ слот RAM (fetch-указатель, отдельно от логического pop)
    reg [ADDR_WIDTH:0]   fifo_count;  // логическая занятость (push +1 / pop -1) - full/empty/rd_data_count/wr_data_count завязаны на неё, стейджинг ниже её не трогает
    reg                   wr_ack_r;

    // 2-ступенчатый prefetch-буфер под dout - см. пояснение в шапке файла.
    // stage_a - то, что реально показывает dout (голова очереди, уже
    // готова ДО rd_en); stage_b - следующий элемент, подгружается из RAM
    // заранее, пока stage_a ещё не выдан.
    reg [WRITE_DATA_WIDTH-1:0] stage_a, stage_b;
    reg stage_a_valid, stage_b_valid;

    // Real xpm_fifo_sync holds wr_rst_busy/rd_rst_busy high for several
    // cycles after rst deasserts (WRST_IDLE->IN->OUT->EXIT handshake in
    // xpm_fifo.sv). wr_en/rd_en asserted during that window is a protocol
    // violation Xilinx docs call out explicitly (PG057) - on real hardware
    // it can permanently corrupt the FIFO's internal pointers, not just
    // glitch for a cycle. This model used to tie both busy outputs to 0,
    // which let mv_avg.v/mv_avg_dual_ch.v/fifo_sample_delay.v leave the
    // real busy outputs dangling unconnected without any test ever
    // noticing - invisible in Verilator/cocotb while still breaking xsim
    // and real hardware. RST_BUSY_CYCLES is an arbitrary small number (the
    // real IP's exact duration isn't being reproduced) - it only needs to
    // be >0 so an unguarded consumer gets caught.
    localparam RST_BUSY_CYCLES = 4;
    reg [2:0] busy_cnt;
    reg       busy_r;

    reg [ADDR_WIDTH:0] unstaged_count; // элементов в mem[], ещё не подтянутых в stage_a/stage_b

    wire full_i  = (fifo_count == FIFO_WRITE_DEPTH);
    // empty означает "dout ещё не готов", а не просто "логически пусто" -
    // сразу после первого push'а в пустой FIFO stage_a готовится 1 такт
    // (настоящий prefetch-latency), это отражает реальный FWFT честно.
    wire empty_i = !stage_a_valid;

    wire rd_valid = rd_en && !empty_i && !busy_r;
    // Real XPM uses a look-ahead full flag (going_full/leaving_full in
    // xpm_fifo.sv) that accounts for a same-cycle read: a simultaneous
    // wr_en+rd_en at "full" occupancy is allowed, since the read frees the
    // slot the write needs in the same cycle. A plain "!full_i" gate here
    // (ignoring rd_valid) is stricter than the real IP and silently caps
    // sustained full-rate streaming at half throughput once the FIFO fills.
    wire wr_valid = wr_en && (!full_i || rd_valid) && !busy_r;

    // Стейджинг: stage_a освобождается по pop (rd_valid) или если она ещё
    // пустая (сразу после старта/reset) - в обоих случаях "нужно заполнить
    // a", и если что-то есть в stage_b (или подгружается туда в этом же
    // такте), оно сдвигается в a. stage_b аналогично подпитывается из RAM,
    // пока там есть неподтянутые элементы (unstaged_count).
    wire shift_b_to_a = rd_valid || !stage_a_valid;
    // fetch_b гейтится СТАРЫМ (до этого такта) unstaged_count, а не с учётом
    // wr_valid этого же такта - иначе на первом же push'е mem[mem_rd_ptr]
    // читалось бы в ТОМ ЖЕ такте, что и mem[wr_ptr]<=din его пишет, и out of
    // non-blocking семантики Verilog получило бы СТАРОЕ (мусорное)
    // содержимое слота, а не только что записанное значение.
    wire [ADDR_WIDTH:0] unstaged_after_wr = unstaged_count + (wr_valid ? 1'b1 : 1'b0);
    wire fetch_b = (unstaged_count != 0) && (!stage_b_valid || shift_b_to_a);

    // dout - ЕЩЁ один регистр поверх stage_a, а не stage_a напрямую. Причина
    // (найдено эмпирически, подтверждено на реальном xpm_fifo_sync через
    // mv_avg_tb.sv): wr_ack (а с ним data_in_reg в mv_avg.v) отстаёт РОВНО
    // на 1 такт от самой транзакции (регистрируется). Если dout=stage_a
    // напрямую, к моменту, когда wr_ack наконец сообщает "предыдущая
    // транзакция прошла", stage_a уже успевает сдвинуться на СЛЕДУЮЩИЙ
    // элемент (при непрерывном pop каждый такт) - dout и wr_ack оказываются
    // не в фазе ровно на 1 такт, и running_total вычитает не тот элемент.
    // dout_r<=stage_a БЕЗУСЛОВНО каждый такт даёт dout ту же фазовую
    // задержку в 1 такт, что и у wr_ack - синхронно с data_in_reg.
    reg [WRITE_DATA_WIDTH-1:0] dout_r;
    always @(posedge wr_clk) begin
        if (rst)
            dout_r <= 0;
        else
            dout_r <= stage_a;
    end

    assign full          = full_i;
    assign empty         = empty_i;
    assign dout           = dout_r;
    assign data_valid    = !empty_i;
    assign wr_data_count = EN_WR_DATA_COUNT ? fifo_count[WR_DATA_COUNT_WIDTH-1:0] : {WR_DATA_COUNT_WIDTH{1'b0}};
    assign rd_data_count = EN_RD_DATA_COUNT ? fifo_count[RD_DATA_COUNT_WIDTH-1:0] : {RD_DATA_COUNT_WIDTH{1'b0}};
    assign overflow      = wr_en && full_i;
    assign underflow      = rd_en && empty_i;
    // Real XPM: wr_ack is registered - "write request during the PRIOR
    // clock cycle succeeded" (xpm_fifo.sv: wr_ack_i <= ram_wr_en_i;), not
    // combinational with wr_en - AND gated off entirely (tied to 0) unless
    // USE_ADV_FEATURES bit4 is set (xpm_fifo.sv: assign wr_ack = EN_WACK==1
    // ? wr_ack_i : 1'b0;). This gate is exactly what bit us on real hardware.
    assign wr_ack         = EN_WACK ? wr_ack_r : 1'b0;

    assign prog_full     = 1'b0;
    assign prog_empty    = 1'b0;
    assign almost_full   = 1'b0;
    assign almost_empty  = 1'b0;
    assign wr_rst_busy   = busy_r;
    assign rd_rst_busy   = busy_r;
    assign sbiterr        = 1'b0;
    assign dbiterr         = 1'b0;

    always @(posedge wr_clk) begin
        if (rst) begin
            busy_r   <= 1'b1;
            busy_cnt <= RST_BUSY_CYCLES;
        end else if (busy_r) begin
            if (busy_cnt == 0)
                busy_r <= 1'b0;
            else
                busy_cnt <= busy_cnt - 1'b1;
        end

        if (!rst && busy_r && wr_en)
            $error("%m: wr_en asserted while wr_rst_busy is high - real xpm_fifo_sync treats this as a protocol violation (see PG057), gate wr_en with !wr_rst_busy");
        if (!rst && busy_r && rd_en)
            $error("%m: rd_en asserted while rd_rst_busy is high - real xpm_fifo_sync treats this as a protocol violation (see PG057), gate rd_en with !rd_rst_busy");
    end

    always @(posedge wr_clk) begin
        if (rst) begin
            wr_ptr         <= 0;
            mem_rd_ptr     <= 0;
            fifo_count     <= 0;
            unstaged_count <= 0;
            stage_a        <= 0;
            stage_a_valid  <= 0;
            stage_b        <= 0;
            stage_b_valid  <= 0;
            wr_ack_r       <= 0;
        end else begin
            wr_ack_r <= wr_valid;

            if (wr_valid) begin
                mem[wr_ptr] <= din;
                wr_ptr <= wr_ptr + 1'b1;
            end

            // Fetch RAM -> stage_b: читаем mem[mem_rd_ptr] - слот, записанный
            // в СТРОГО более раннем такте (mem_rd_ptr отстаёт от wr_ptr,
            // пока unstaged_count>0), поэтому конфликта с записью выше в
            // ЭТОМ ЖЕ такте нет, даже если wr_valid тоже сейчас взведён.
            if (fetch_b) begin
                stage_b    <= mem[mem_rd_ptr];
                mem_rd_ptr <= mem_rd_ptr + 1'b1;
            end
            stage_b_valid <= fetch_b ? 1'b1 : (shift_b_to_a ? 1'b0 : stage_b_valid);
            unstaged_count <= unstaged_after_wr - (fetch_b ? 1'b1 : 1'b0);

            // Shift stage_b -> stage_a. Использует ТЕКУЩЕЕ (до этого такта)
            // значение stage_b благодаря неблокирующим присваиваниям - даже
            // если fetch_b тоже взведён в этом же такте, в a попадёт именно
            // старое содержимое b, а не то, что только что туда подгрузилось.
            if (shift_b_to_a) begin
                stage_a       <= stage_b;
                stage_a_valid <= stage_b_valid;
            end

            case ({wr_valid, rd_valid})
                2'b10:   fifo_count <= fifo_count + 1'b1;
                2'b01:   fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count;
            endcase
        end
    end

endmodule

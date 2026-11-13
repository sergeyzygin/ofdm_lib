//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Company: ZNAutomation
// Engineer: Sergey Zygin
//
// Create Date: 14.05.2026
// Design Name: mv_avg_dual_ch
// Module Name: mv_avg_dual_ch
// Project Name: ofdm_lib
// Target Devices:
// Tool Versions:
// Description: Two-channel (I/Q) moving average with shared valid.
//              Port-compatible with OpenOFDM's mv_avg_dual_ch.
//              Original implementation, not derived from OpenOFDM source code.
//
// Dependencies: xpm_fifo_sync
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
module mv_avg_dual_ch
#(
    parameter DATA_WIDTH0 = 16,
    parameter DATA_WIDTH1 = 16,
    parameter LOG2_AVG_LEN = 5
)
(
    input clk,
    input rstn,

    input signed [DATA_WIDTH0-1:0] data_in0,
    input signed [DATA_WIDTH1-1:0] data_in1,
    input data_in_valid,

    output signed [DATA_WIDTH0-1:0] data_out0,
    output signed [DATA_WIDTH1-1:0] data_out1,
    output data_out_valid
);

localparam FIFO_SIZE = 1<<LOG2_AVG_LEN;
localparam TOTAL_WIDTH0 = DATA_WIDTH0 + LOG2_AVG_LEN;
localparam TOTAL_WIDTH1 = DATA_WIDTH1 + LOG2_AVG_LEN;

reg signed [(TOTAL_WIDTH0-1):0] running_total0;
reg signed [(TOTAL_WIDTH1-1):0] running_total1;

reg  signed [DATA_WIDTH0-1:0] data_in0_reg; // to lock data_in by data_in_valid in case it changes in between two valid strobes
reg  signed [DATA_WIDTH0-1:0] data_in1_reg; // to lock data_in by data_in_valid in case it changes in between two valid strobes
wire signed [DATA_WIDTH0-1:0] data_in_old0;
wire signed [DATA_WIDTH1-1:0] data_in_old1;

wire signed [TOTAL_WIDTH0-1:0] ext_data_in_old0 = {{LOG2_AVG_LEN{data_in_old0[DATA_WIDTH0-1]}}, data_in_old0};
wire signed [TOTAL_WIDTH0-1:0] ext_data_in0     = {{LOG2_AVG_LEN{data_in0_reg[DATA_WIDTH0-1]}}, data_in0_reg};
wire signed [TOTAL_WIDTH1-1:0] ext_data_in_old1 = {{LOG2_AVG_LEN{data_in_old1[DATA_WIDTH1-1]}}, data_in_old1};
wire signed [TOTAL_WIDTH1-1:0] ext_data_in1     = {{LOG2_AVG_LEN{data_in1_reg[DATA_WIDTH1-1]}}, data_in1_reg};

reg rd_en, rd_en_start;
wire [LOG2_AVG_LEN:0] wr_data_count;
reg [LOG2_AVG_LEN:0]  wr_data_count_reg;
wire wr_complete_pulse;
reg  wr_complete_pulse_reg;

assign wr_complete_pulse = (wr_data_count > wr_data_count_reg);
assign data_out_valid = wr_complete_pulse_reg;
assign data_out0 = running_total0[TOTAL_WIDTH0-1:LOG2_AVG_LEN];
assign data_out1 = running_total1[TOTAL_WIDTH1-1:LOG2_AVG_LEN];

xpm_fifo_sync #(
    .DOUT_RESET_VALUE("0"),    // String
    .ECC_MODE("no_ecc"),       // String
    .FIFO_MEMORY_TYPE("auto"), // String
    .FIFO_READ_LATENCY(0),     // DECIMAL
    .FIFO_WRITE_DEPTH(FIFO_SIZE),   // DECIMAL minimum 16!
    .FULL_RESET_VALUE(0),      // DECIMAL
    .PROG_EMPTY_THRESH(10),    // DECIMAL
    .PROG_FULL_THRESH(10),     // DECIMAL
    .RD_DATA_COUNT_WIDTH(LOG2_AVG_LEN+1),   // DECIMAL
    .READ_DATA_WIDTH(DATA_WIDTH0+DATA_WIDTH1),      // DECIMAL
    .READ_MODE("fwft"),         // String
    .USE_ADV_FEATURES("0404"), // only enable rd_data_count and wr_data_count
    .WAKEUP_TIME(0),           // DECIMAL
    .WRITE_DATA_WIDTH(DATA_WIDTH0+DATA_WIDTH1),     // DECIMAL
    .WR_DATA_COUNT_WIDTH(LOG2_AVG_LEN+1)    // DECIMAL
) fifo_1clk_for_mv_avg_dual_ch_i (
    .almost_empty(),
    .almost_full(),
    .data_valid(),
    .dbiterr(),
    .dout({data_in_old1, data_in_old0}),
    .empty(empty),
    .full(full),
    .overflow(),
    .prog_empty(),
    .prog_full(),
    .rd_data_count(),
    .rd_rst_busy(),
    .sbiterr(),
    .underflow(),
    .wr_ack(),
    .wr_data_count(wr_data_count),
    .wr_rst_busy(),
    .din({data_in1, data_in0}),
    .injectdbiterr(),
    .injectsbiterr(),
    .rd_en(rd_en),
    .rst(~rstn),
    .sleep(),
    .wr_clk(clk),
    .wr_en(data_in_valid)
  );

always @(posedge clk) begin
    if (~rstn) begin
        data_in0_reg <= 0;
        data_in1_reg <= 0;
        wr_complete_pulse_reg <= 0;
        wr_data_count_reg <= 0;
        running_total0 <= 0;
        running_total1 <= 0;
        rd_en <= 0;
        rd_en_start <= 0;
    end else begin
        data_in0_reg <= (data_in_valid?data_in0:data_in0_reg);
        data_in1_reg <= (data_in_valid?data_in1:data_in1_reg);
        wr_complete_pulse_reg <= wr_complete_pulse;
        wr_data_count_reg <= wr_data_count;
        rd_en_start <= ((wr_data_count == (FIFO_SIZE))?1:rd_en_start);
        rd_en <= (rd_en_start?wr_complete_pulse:rd_en);
        if (wr_complete_pulse) begin
            running_total0 <= running_total0 + ext_data_in0 - (rd_en_start?ext_data_in_old0:0);
            running_total1 <= running_total1 + ext_data_in1 - (rd_en_start?ext_data_in_old1:0);
        end
    end
end

endmodule


/*
module mv_avg_dual_ch
#(
    parameter DATA_WIDTH0 = 16,
    parameter DATA_WIDTH1 = 16,
    parameter LOG2_AVG_LEN = 5
)
(
    input clk,
    input rstn,

    input signed [DATA_WIDTH0-1:0] data_in0,
    input signed [DATA_WIDTH1-1:0] data_in1,
    input data_in_valid,

    output wire signed [DATA_WIDTH0-1:0] data_out0,
    output wire signed [DATA_WIDTH1-1:0] data_out1,
    output wire data_out_valid,

    wire [LOG2_AVG_LEN:0] rd_data_count,
    wire has_been_full,
    wire signed [DATA_WIDTH0-1:0] debug_ext_data_in_old0,
    wire signed [DATA_WIDTH1-1:0] debug_ext_data_in_old1,
    output wire debug_wr_enable
);

localparam FIFO_SIZE = 1<<LOG2_AVG_LEN;
localparam TOTAL_WIDTH0 = DATA_WIDTH0 + LOG2_AVG_LEN;
localparam TOTAL_WIDTH1 = DATA_WIDTH1 + LOG2_AVG_LEN;


(* mark_debug = "true" *) reg signed [(TOTAL_WIDTH0-1):0] running_total0;
(* mark_debug = "true" *) reg signed [(TOTAL_WIDTH1-1):0] running_total1;

(* mark_debug = "true" *) reg  signed [DATA_WIDTH0-1:0] data_in0_reg; // to lock data_in by data_in_valid in case it changes in between two valid strobes
(* mark_debug = "true" *) reg  signed [DATA_WIDTH1-1:0] data_in1_reg; // to lock data_in by data_in_valid in case it changes in between two valid strobes
wire signed [DATA_WIDTH0-1:0] data_in_old0;
wire signed [DATA_WIDTH1-1:0] data_in_old1;

assign debug_ext_data_in_old0 = data_in_old0;
assign debug_ext_data_in_old1 = data_in_old1;


(* mark_debug = "true" *) wire full;


(* mark_debug = "true" *) wire wr_rst_busy;
(* mark_debug = "true" *) wire rd_rst_busy;
(* mark_debug = "true" *) reg  fifo_ready;

(* mark_debug = "true" *) wire rd_en;
assign rd_en = full && data_in_valid && fifo_ready;
wire wr_complete_pulse;



assign data_out0 = running_total0[TOTAL_WIDTH0-1:LOG2_AVG_LEN];
assign data_out1 = running_total1[TOTAL_WIDTH1-1:LOG2_AVG_LEN];

assign has_been_full =  rd_data_count > FIFO_SIZE-1;
wire wr_enable;
assign wr_enable = data_in_valid && fifo_ready;
assign debug_wr_enable = wr_enable;
assign data_out_valid = has_been_full;

xpm_fifo_sync #(
    .DOUT_RESET_VALUE("0"),    // String
    .ECC_MODE("no_ecc"),       // String
    .FIFO_MEMORY_TYPE("auto"), // String
    .FIFO_READ_LATENCY(0),     // DECIMAL
    .FIFO_WRITE_DEPTH(FIFO_SIZE),   // DECIMAL minimum 16!
    .FULL_RESET_VALUE(0),      // DECIMAL
    .PROG_EMPTY_THRESH(10),    // DECIMAL
    .PROG_FULL_THRESH(10),     // DECIMAL
    .RD_DATA_COUNT_WIDTH(LOG2_AVG_LEN+1),   // DECIMAL
    .READ_DATA_WIDTH(DATA_WIDTH0+DATA_WIDTH1),      // DECIMAL
    .READ_MODE("fwft"),         // String
    // bit4 (wr_ack) обязателен - см. mv_avg.v для полного объяснения
    .USE_ADV_FEATURES("0414"), // rd_data_count + wr_data_count + wr_ack
    .WAKEUP_TIME(0),           // DECIMAL
    .WRITE_DATA_WIDTH(DATA_WIDTH0+DATA_WIDTH1),     // DECIMAL
    .WR_DATA_COUNT_WIDTH(LOG2_AVG_LEN+1)    // DECIMAL
  ) fifo_1clk_for_mv_avg_dual_ch_i (
    .almost_empty(),
    .almost_full(),
    .data_valid(),
    .dbiterr(),
    .dout({data_in_old1, data_in_old0}),
    .empty(empty),
    .full(full),
    .overflow(),
    .prog_empty(),
    .prog_full(),
    .rd_data_count(rd_data_count),
    .rd_rst_busy(rd_rst_busy),
    .sbiterr(),
    .underflow(),
    .wr_ack(wr_complete_pulse),
    .wr_data_count(),
    .wr_rst_busy(wr_rst_busy),
    .din({data_in1, data_in0}),
    .injectdbiterr(),
    .injectsbiterr(),
//    .rd_en(rd_en),
    .rd_en(has_been_full),
    .rst(~rstn),
    .sleep(),
    .wr_clk(clk),
    .wr_en(wr_enable)
  );

always @(posedge clk) begin
    if (~rstn) begin
        data_in0_reg <= 0;
        data_in1_reg <= 0;

        running_total0 <= 0;
        running_total1 <= 0;
        fifo_ready <= 0;
    end else begin
        if (!wr_rst_busy && !rd_rst_busy)
            fifo_ready <= 1'b1;

        data_in0_reg <= (data_in_valid?data_in0:data_in0_reg);
        data_in1_reg <= (data_in_valid?data_in1:data_in1_reg);
        if (wr_complete_pulse) begin
            running_total0 <= running_total0 + data_in0_reg - (has_been_full?data_in_old0:0);
            running_total1 <= running_total1 + data_in1_reg - (has_been_full?data_in_old1:0);
        end
    end
end

endmodule
*/

/*
module mv_avg_dual_ch
#(
    parameter DATA_WIDTH0 = 16,
    parameter DATA_WIDTH1 = 16,
    parameter LOG2_AVG_LEN = 5
)
(
    input clk,
    input rstn,

    input signed [DATA_WIDTH0-1:0] data_in0,
    input signed [DATA_WIDTH1-1:0] data_in1,
    input data_in_valid,

    output signed [DATA_WIDTH0-1:0] data_out0,
    output signed [DATA_WIDTH1-1:0] data_out1,
    output data_out_valid
);

localparam FIFO_SIZE = 1<<LOG2_AVG_LEN;
localparam TOTAL_WIDTH0 = DATA_WIDTH0 + LOG2_AVG_LEN;
localparam TOTAL_WIDTH1 = DATA_WIDTH1 + LOG2_AVG_LEN;

reg signed [(TOTAL_WIDTH0-1):0] running_total0;
reg signed [(TOTAL_WIDTH1-1):0] running_total1;

reg  signed [DATA_WIDTH0-1:0] data_in0_reg; // to lock data_in by data_in_valid in case it changes in between two valid strobes
reg  signed [DATA_WIDTH0-1:0] data_in1_reg; // to lock data_in by data_in_valid in case it changes in between two valid strobes
wire signed [DATA_WIDTH0-1:0] data_in_old0;
wire signed [DATA_WIDTH1-1:0] data_in_old1;
reg  signed [DATA_WIDTH0-1:0] data_in_old0_reg; // latch dout at pop time - see mv_avg.v for why: by the time wr_ack fires (1 cycle later) rd_ptr has already advanced past this entry
reg  signed [DATA_WIDTH1-1:0] data_in_old1_reg;

wire signed [TOTAL_WIDTH0-1:0] ext_data_in_old0 = {{LOG2_AVG_LEN{data_in_old0_reg[DATA_WIDTH0-1]}}, data_in_old0_reg};
wire signed [TOTAL_WIDTH0-1:0] ext_data_in0     = {{LOG2_AVG_LEN{data_in0_reg[DATA_WIDTH0-1]}}, data_in0_reg};
wire signed [TOTAL_WIDTH1-1:0] ext_data_in_old1 = {{LOG2_AVG_LEN{data_in_old1_reg[DATA_WIDTH1-1]}}, data_in_old1_reg};
wire signed [TOTAL_WIDTH1-1:0] ext_data_in1     = {{LOG2_AVG_LEN{data_in1_reg[DATA_WIDTH1-1]}}, data_in1_reg};

wire full;
reg  full_reg;

// See mv_avg.v for the full rationale on wr_rst_busy/rd_rst_busy: the real
// xpm_fifo_sync holds them high for several cycles after reset, and issuing
// wr_en/rd_en during that window permanently corrupts the FIFO's internal
// pointers. Our Verilator stand-in never modeled busy, so this was invisible
// there while still breaking xsim and real hardware.
wire wr_rst_busy;
wire rd_rst_busy;
reg  fifo_ready;

// See mv_avg.v for the full rationale: rd_en must be combinational (not
// registered) and gated directly off the FIFO's own look-ahead `full`, or
// the original wr_data_count-compare + registered-rd_en scheme deadlocks
// permanently the first time the window fills, and even once patched to
// avoid that, staggers push/pop onto alternating cycles - halving
// throughput under continuous (gap-free) streaming.
wire rd_en = full && data_in_valid && fifo_ready;
wire wr_ack;
wire wr_complete_pulse;
reg  wr_complete_pulse_reg;

assign wr_complete_pulse = wr_ack;
assign data_out_valid = wr_complete_pulse_reg;
assign data_out0 = running_total0[TOTAL_WIDTH0-1:LOG2_AVG_LEN];
assign data_out1 = running_total1[TOTAL_WIDTH1-1:LOG2_AVG_LEN];

xpm_fifo_sync #(
    .DOUT_RESET_VALUE("0"),    // String
    .ECC_MODE("no_ecc"),       // String
    .FIFO_MEMORY_TYPE("auto"), // String
    .FIFO_READ_LATENCY(0),     // DECIMAL
    .FIFO_WRITE_DEPTH(FIFO_SIZE),   // DECIMAL minimum 16!
    .FULL_RESET_VALUE(0),      // DECIMAL
    .PROG_EMPTY_THRESH(10),    // DECIMAL
    .PROG_FULL_THRESH(10),     // DECIMAL
    .RD_DATA_COUNT_WIDTH(LOG2_AVG_LEN+1),   // DECIMAL
    .READ_DATA_WIDTH(DATA_WIDTH0+DATA_WIDTH1),      // DECIMAL
    .READ_MODE("fwft"),         // String
    // bit4 (wr_ack) обязателен - см. mv_avg.v для полного объяснения
    .USE_ADV_FEATURES("0414"), // rd_data_count + wr_data_count + wr_ack
    .WAKEUP_TIME(0),           // DECIMAL
    .WRITE_DATA_WIDTH(DATA_WIDTH0+DATA_WIDTH1),     // DECIMAL
    .WR_DATA_COUNT_WIDTH(LOG2_AVG_LEN+1)    // DECIMAL
) fifo_1clk_for_mv_avg_dual_ch_i (
    .almost_empty(),
    .almost_full(),
    .data_valid(),
    .dbiterr(),
    .dout({data_in_old1, data_in_old0}),
    .empty(empty),
    .full(full),
    .overflow(),
    .prog_empty(),
    .prog_full(),
    .rd_data_count(),
    .rd_rst_busy(rd_rst_busy),
    .sbiterr(),
    .underflow(),
    .wr_ack(wr_ack),
    .wr_data_count(),
    .wr_rst_busy(wr_rst_busy),
    .din({data_in1, data_in0}),
    .injectdbiterr(),
    .injectsbiterr(),
    .rd_en(rd_en),
    .rst(~rstn),
    .sleep(),
    .wr_clk(clk),
    .wr_en(data_in_valid && fifo_ready)
  );

always @(posedge clk) begin
    if (~rstn) begin
        data_in0_reg <= 0;
        data_in1_reg <= 0;
        data_in_old0_reg <= 0;
        data_in_old1_reg <= 0;
        full_reg <= 0;
        wr_complete_pulse_reg <= 0;
        running_total0 <= 0;
        running_total1 <= 0;
        fifo_ready <= 0;
    end else begin
        if (!wr_rst_busy && !rd_rst_busy)
            fifo_ready <= 1'b1;
        data_in0_reg <= (data_in_valid?data_in0:data_in0_reg);
        data_in1_reg <= (data_in_valid?data_in1:data_in1_reg);
        data_in_old0_reg <= data_in_old0;
        data_in_old1_reg <= data_in_old1;
        full_reg <= full;
        wr_complete_pulse_reg <= wr_complete_pulse;
        if (wr_complete_pulse) begin
            running_total0 <= running_total0 + ext_data_in0 - (full_reg?ext_data_in_old0:0);
            running_total1 <= running_total1 + ext_data_in1 - (full_reg?ext_data_in_old1:0);
        end
    end
end

endmodule
*/

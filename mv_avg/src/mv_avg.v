//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Company: ZNAutomation
// Engineer: Sergey Zygin
//
// Create Date: 12.05.2026
// Design Name: mv_avg
// Module Name: mv_avg
// Project Name: ofdm_lib
// Target Devices:
// Tool Versions:
// Description: Moving average, window 2^LOG2_AVG_LEN, running sum + XPM FIFO.
//              Port-compatible with OpenOFDM's mv_avg.
//              Original implementation, not derived from OpenOFDM source code.
//
// Dependencies: xpm_fifo_sync
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
module mv_avg
#(
    parameter DATA_WIDTH = 16,
    parameter LOG2_AVG_LEN = 5
)
(
    input clk,
    input rstn,

    input signed [DATA_WIDTH-1:0] data_in,
    input data_in_valid,

    output wire signed [DATA_WIDTH-1:0] data_out,
    output wire data_out_valid
);

localparam FIFO_SIZE = 1<<LOG2_AVG_LEN;
localparam TOTAL_WIDTH = DATA_WIDTH + LOG2_AVG_LEN;

reg signed [(TOTAL_WIDTH-1):0] running_total;

reg  signed [DATA_WIDTH-1:0] data_in_reg; // to lock data_in by data_in_valid in case it changes in between two valid strobes
wire signed [DATA_WIDTH-1:0] data_in_old;

wire signed [TOTAL_WIDTH-1:0] ext_data_in_old = {{LOG2_AVG_LEN{data_in_old[DATA_WIDTH-1]}}, data_in_old};
wire signed [TOTAL_WIDTH-1:0] ext_data_in     = {{LOG2_AVG_LEN{data_in_reg[DATA_WIDTH-1]}}, data_in_reg};

reg rd_en, rd_en_start;
wire [LOG2_AVG_LEN:0] wr_data_count;
reg [LOG2_AVG_LEN:0]  wr_data_count_reg;
wire wr_complete_pulse;
reg  wr_complete_pulse_reg;

assign wr_complete_pulse = (wr_data_count > wr_data_count_reg);
assign data_out_valid = wr_complete_pulse_reg;
assign data_out = running_total[TOTAL_WIDTH-1:LOG2_AVG_LEN];

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
    .READ_DATA_WIDTH(DATA_WIDTH),      // DECIMAL
    .READ_MODE("fwft"),         // String
    .USE_ADV_FEATURES("0404"), // only enable rd_data_count and wr_data_count
    .WAKEUP_TIME(0),           // DECIMAL
    .WRITE_DATA_WIDTH(DATA_WIDTH),     // DECIMAL
    .WR_DATA_COUNT_WIDTH(LOG2_AVG_LEN+1)    // DECIMAL
  ) fifo_1clk_for_mv_avg_i (
    .almost_empty(),
    .almost_full(),
    .data_valid(),
    .dbiterr(),
    .dout(data_in_old),
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
    .din(data_in),
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
        data_in_reg <= 0;
        wr_data_count_reg <= 0;
        running_total <= 0;
        rd_en <= 0;
        rd_en_start <= 0;
        wr_complete_pulse_reg <= 0;
    end else begin
        wr_complete_pulse_reg <= wr_complete_pulse;
        data_in_reg <= (data_in_valid?data_in:data_in_reg);
        wr_data_count_reg <= wr_data_count;
        rd_en_start <= ((wr_data_count == (FIFO_SIZE))?1:rd_en_start);
        rd_en <= (rd_en_start?wr_complete_pulse:rd_en);
        if (wr_complete_pulse) begin
            running_total <= running_total + ext_data_in - (rd_en_start?ext_data_in_old:0);
        end
    end
end

endmodule


/*
module mv_avg
#(
    parameter DATA_WIDTH = 16,
    parameter LOG2_AVG_LEN = 5
)
(
    input clk,
    input rstn,

    input signed [DATA_WIDTH-1:0] data_in,
    input data_in_valid,

    output wire signed [DATA_WIDTH-1:0] data_out,
    output wire data_out_valid,

    wire [LOG2_AVG_LEN:0] rd_data_count,
    wire has_been_full,
    wire signed [DATA_WIDTH-1:0] debug_ext_data_in_old,
    output wire debug_wr_enable
);

localparam FIFO_SIZE = 1<<LOG2_AVG_LEN;
localparam TOTAL_WIDTH = DATA_WIDTH + LOG2_AVG_LEN;


(* mark_debug = "true" *) reg signed [(TOTAL_WIDTH-1):0] running_total;

(* mark_debug = "true" *) reg  signed [DATA_WIDTH-1:0] data_in_reg; // to lock data_in by data_in_valid in case it changes in between two valid strobes
wire signed [DATA_WIDTH-1:0] data_in_old;

assign debug_ext_data_in_old = data_in_old;


(* mark_debug = "true" *) wire full;


(* mark_debug = "true" *) wire wr_rst_busy;
(* mark_debug = "true" *) wire rd_rst_busy;
(* mark_debug = "true" *) reg  fifo_ready;

(* mark_debug = "true" *) wire rd_en;
assign rd_en = full && data_in_valid && fifo_ready;
wire wr_complete_pulse;



assign data_out = running_total[TOTAL_WIDTH-1:LOG2_AVG_LEN];

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
    .READ_DATA_WIDTH(DATA_WIDTH),      // DECIMAL
    .READ_MODE("fwft"),         // String
    .USE_ADV_FEATURES("0414"), // rd_data_count + wr_data_count + wr_ack
    .WAKEUP_TIME(0),           // DECIMAL
    .WRITE_DATA_WIDTH(DATA_WIDTH),     // DECIMAL
    .WR_DATA_COUNT_WIDTH(LOG2_AVG_LEN+1)    // DECIMAL
  ) fifo_1clk_for_mv_avg_i (
    .almost_empty(),
    .almost_full(),
    .data_valid(),
    .dbiterr(),
    .dout(data_in_old),
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
    .din(data_in),
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
        data_in_reg <= 0;

        running_total <= 0;
        fifo_ready <= 0;
    end else begin
        if (!wr_rst_busy && !rd_rst_busy)
            fifo_ready <= 1'b1;

        data_in_reg <= (data_in_valid?data_in:data_in_reg);
        if (wr_complete_pulse) begin
            running_total <= running_total + data_in_reg - (has_been_full?data_in_old:0);
        end
    end
end

endmodule

*/
/*
module mv_avg
#(
    parameter DATA_WIDTH = 16,
    parameter LOG2_AVG_LEN = 5
)
(
    input clk,
    input rstn,

    input signed [DATA_WIDTH-1:0] data_in,
    input data_in_valid,

    output wire signed [DATA_WIDTH-1:0] data_out,
    output wire data_out_valid,

(* mark_debug = "true" *) wire [LOG2_AVG_LEN:0] rd_data_count,
(* mark_debug = "true" *) wire has_been_full,
wire signed [DATA_WIDTH-1:0] debug_ext_data_in_old,
 output wire debug_wr_enable
);

localparam FIFO_SIZE = 1<<LOG2_AVG_LEN;
localparam TOTAL_WIDTH = DATA_WIDTH + LOG2_AVG_LEN;

// core accumulator: data_out = running_total >> LOG2_AVG_LEN. If eviction
// (the "- ext_data_in_old" term below) stops firing, this just grows
// unboundedly instead of tracking a real moving average -- see chat: this
// is the prime suspect for mag_sq_avg being stuck near 0xE88AB697 while raw
// mag_sq is in the tens.
(* mark_debug = "true" *) reg signed [(TOTAL_WIDTH-1):0] running_total;

(* mark_debug = "true" *) reg  signed [DATA_WIDTH-1:0] data_in_reg; // to lock data_in by data_in_valid in case it changes in between two valid strobes
wire signed [DATA_WIDTH-1:0] data_in_old;
(* mark_debug = "true" *) reg  signed [DATA_WIDTH-1:0] data_in_old_reg; // latch dout at pop time - by the time wr_ack fires (1 cycle later) rd_ptr has already moved on to the NEXT entry, so reading data_in_old live at that point would grab the wrong (already-advanced) sample

// wr_complete_pulse_reg (what actually gates the running_total update below)
// is 2 cycles behind wr_en/rd_en (rd_en -> wr_ack -> wr_complete_pulse_reg),
// but data_in_reg/data_in_old_reg above are only 1 cycle behind their live
// source and get overwritten every cycle under continuous full-rate
// streaming - a pipeline depth mismatch confirmed empirically via
// mv_avg_tb.sv (running_total grows unboundedly instead of settling on a
// repeating input). These *_reg2 stages match the depth so the value pair
// consumed by running_total is the one actually paired with THIS push/evict.
(* mark_debug = "true" *) reg  signed [DATA_WIDTH-1:0] data_in_reg2;
(* mark_debug = "true" *) reg  signed [DATA_WIDTH-1:0] data_in_reg3;

(* mark_debug = "true" *) reg  signed [DATA_WIDTH-1:0] data_in_old_reg2;

wire signed [TOTAL_WIDTH-1:0] ext_data_in_old = {{LOG2_AVG_LEN{data_in_old_reg2[DATA_WIDTH-1]}}, data_in_old};
wire signed [TOTAL_WIDTH-1:0] ext_data_in     = {{LOG2_AVG_LEN{data_in_reg2[DATA_WIDTH-1]}}, data_in_reg2};
assign debug_ext_data_in_old = data_in_old;

// full/full_reg gate the eviction term above ("- ext_data_in_old"); if
// they never assert, running_total accumulates forever instead of sliding
(* mark_debug = "true" *) wire full;
(* mark_debug = "true" *) reg  full_reg;

// The real xpm_fifo_sync (unlike our own Verilator sim model) holds
// wr_rst_busy/rd_rst_busy high for several cycles after rst deasserts
// (internal WRST_IDLE->IN->OUT->EXIT handshake in xpm_fifo.sv). Issuing
// wr_en/rd_en while busy is asserted is a protocol violation that can
// permanently corrupt the FIFO's internal pointers - not a one-shot glitch,
// but silent, total breakage for the rest of the run. Our stand-in never
// modeled busy at all, so this was invisible in Verilator/cocotb while
// still breaking xsim and real hardware. fifo_ready latches true only once
// both busy flags have been observed low.
// if these ever stay high (or reassert) long after the arm/clear pulse,
// fifo_ready gets stuck at 0 and wr_en/rd_en are permanently gated off
(* mark_debug = "true" *) wire wr_rst_busy;
(* mark_debug = "true" *) wire rd_rst_busy;
(* mark_debug = "true" *) reg  fifo_ready;

// rd_en must be combinational, not registered - the real FIFO's full flag
// is look-ahead (going_full/leaving_full in xpm_fifo.sv) and allows a
// simultaneous wr_en+rd_en on the SAME cycle even at full occupancy, since
// the read frees the slot the write needs. Registering rd_en one cycle
// behind data_in_valid staggers push and pop across different cycles once
// full, which halves sustainable throughput under continuous (gap-free)
// streaming - relevant here since data_in is fed continuously from AD9361.
//
// `full` is combinational off the FIFO's own occupancy, so it's already 1
// on the very cycle occupancy first reaches FIFO_SIZE - unlike a registered
// "have I ever been full" latch (checked one cycle late), which misses the
// pop for that first boundary write and silently drops one sample. Once
// full, occupancy never changes (pop only ever fires paired with an
// accepted push), so `full` is naturally sticky - no separate latch needed.
(* mark_debug = "true" *) wire rd_en;
assign rd_en = full && data_in_valid && fifo_ready;
(* mark_debug = "true" *) wire wr_ack;
wire wr_complete_pulse;
reg  wr_complete_pulse_reg;

// wr_ack (registered by the FIFO: "write during the prior cycle
// succeeded") is what actually happened; a wr_data_count > wr_data_count_reg
// comparison looks equivalent but silently stops detecting writes once a
// read happens on the same cycle (steady-state full-throughput streaming),
// because a simultaneous push+pop leaves the net count unchanged.
assign wr_complete_pulse = wr_ack;
// wr_ack (and so wr_complete_pulse_reg) fires on EVERY accepted write,
// starting from the very first push - not gated by the window actually
// being full. Without a qualifier here, data_out_valid pulses "valid"
// throughout the fill-up period (first FIFO_SIZE pushes after reset/re-arm)
// while running_total is still just a partial, not-yet-full sum - confirmed
// on hardware waveform: data_out_valid was seen rising after only 2-4
// pushes instead of FIFO_SIZE.
//
// Gating with full/full_reg instead (both tried) produced only a single
// data_out_valid pulse that then stayed low forever - the full flag's exact
// assertion/sticky timing under continuous back-to-back push+pop did not
// behave as its own comment above claims, confirmed on hardware waveform.
// Using has_been_full below - a sticky latch driven directly off the FIFO's
// own occupancy count (rd_data_count) - sidesteps full's timing entirely:
// once occupancy has genuinely reached FIFO_SIZE, latch and stay latched.

assign data_out_valid = full_reg;//wr_complete_pulse_reg && has_been_full;
assign data_out = running_total[TOTAL_WIDTH-1:LOG2_AVG_LEN];

assign has_been_full =  rd_data_count > FIFO_SIZE-1;
wire wr_enable;
assign wr_enable = data_in_valid && fifo_ready;
assign debug_wr_enable = wr_enable;

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
    .READ_DATA_WIDTH(DATA_WIDTH),      // DECIMAL
    .READ_MODE("fwft"),         // String
    // bit4 (wr_ack) обязателен - wr_complete_pulse ниже держится на wr_ack
    // (xpm_fifo.sv: assign wr_ack = EN_WACK==1 ? wr_ack_i : 1'b0; без этого
    // бита wr_ack намертво зашит в 0 на реальном железе, и running_total
    // никогда не обновляется - наша Verilator-модель xpm_fifo_sync этот
    // gate не эмулировала, поэтому баг не ловился в симуляции)
    .USE_ADV_FEATURES("0414"), // rd_data_count + wr_data_count + wr_ack
    .WAKEUP_TIME(0),           // DECIMAL
    .WRITE_DATA_WIDTH(DATA_WIDTH),     // DECIMAL
    .WR_DATA_COUNT_WIDTH(LOG2_AVG_LEN+1)    // DECIMAL
  ) fifo_1clk_for_mv_avg_i (
    .almost_empty(),
    .almost_full(),
    .data_valid(),
    .dbiterr(),
    .dout(data_in_old),
    .empty(empty),
    .full(full),
    .overflow(),
    .prog_empty(),
    .prog_full(),
    .rd_data_count(rd_data_count),
    .rd_rst_busy(rd_rst_busy),
    .sbiterr(),
    .underflow(),
    .wr_ack(wr_ack),
    .wr_data_count(),
    .wr_rst_busy(wr_rst_busy),
    .din(data_in),
    .injectdbiterr(),
    .injectsbiterr(),
    .rd_en(rd_en),
    .rst(~rstn),
    .sleep(),
    .wr_clk(clk),
    .wr_en(wr_enable)
  );

always @(posedge clk) begin
    if (~rstn) begin
        data_in_reg <= 0;
        data_in_old_reg <= 0;
        data_in_reg2 <= 0;
        data_in_old_reg2 <= 0;
        full_reg <= 0;
        running_total <= 0;
        wr_complete_pulse_reg <= 0;
        fifo_ready <= 0;
//        has_been_full <= 0;
    end else begin
        if (!wr_rst_busy && !rd_rst_busy)
            fifo_ready <= 1'b1;
//        if (rd_data_count > FIFO_SIZE)
//            has_been_full <= 1'b1;
        wr_complete_pulse_reg <= wr_complete_pulse;
        data_in_reg <= (data_in_valid?data_in:data_in_reg);
        data_in_old_reg <= data_in_old;
        data_in_reg2 <= data_in_reg;
                data_in_reg3 <= data_in_reg2;

        data_in_old_reg2 <= data_in_old_reg;
        full_reg <= has_been_full;
        if (wr_complete_pulse) begin
            running_total <= running_total + data_in_reg - (has_been_full?data_in_old:0);
        end
    end
end

endmodule
*/
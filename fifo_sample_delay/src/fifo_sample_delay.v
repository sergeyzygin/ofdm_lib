//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Company: ZNAutomation
// Engineer: Sergey Zygin
//
// Create Date: 08.05.2026
// Design Name: fifo_sample_delay
// Module Name: fifo_sample_delay
// Project Name: ofdm_lib
// Target Devices:
// Tool Versions:
// Description: Programmable sample delay (delay_ctl) on XPM FIFO, strobe-gated.
//              Port-compatible with OpenOFDM's fifo_sample_delay.
//              Original implementation, not derived from OpenOFDM source code.
//
// Dependencies: xpm_fifo_sync
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
`timescale 1 ns / 1 ps

module fifo_sample_delay #
(
    parameter integer DATA_WIDTH	= 8,
    parameter integer LOG2_FIFO_DEPTH	= 7
)
(
      input wire clk,
      input wire rst,

      input wire [(LOG2_FIFO_DEPTH-1):0] delay_ctl,

      input wire [(DATA_WIDTH-1):0] data_in,
      input wire data_in_valid,
      output wire [(DATA_WIDTH-1):0] data_out,
      output wire data_out_valid
);

wire [LOG2_FIFO_DEPTH:0] rd_data_count;
wire [LOG2_FIFO_DEPTH:0] wr_data_count;
wire full;
wire empty;

// See mv_avg.v for the full rationale on wr_rst_busy/rd_rst_busy: the real
// xpm_fifo_sync holds them high for several cycles after reset, and issuing
// wr_en/rd_en during that window permanently corrupts the FIFO's internal
// pointers. Our Verilator stand-in never modeled busy, so this was invisible
// there while still breaking xsim and real hardware.
wire wr_rst_busy;
wire rd_rst_busy;
reg  fifo_ready;

always @(posedge clk) begin
    if (rst)
        fifo_ready <= 1'b0;
    else if (!wr_rst_busy && !rd_rst_busy)
        fifo_ready <= 1'b1;
end

// primed is combinational off the FIFO's own live occupancy (wr_data_count,
// registered inside the FIFO - reflects occupancy as of the start of this
// cycle), not a registered "saw wr_data_count==delay_ctl once" latch: a
// registered-compare + wr_complete_pulse-gated rd_en scheme silently stops
// working once a read and write land on the same cycle in steady state
// (net occupancy doesn't change, so a naive count-delta compare stops
// detecting new writes) - see mv_avg.v for the full writeup of this bug
// class. Once primed, occupancy stays pinned at delay_ctl forever (pop only
// ever fires paired with an accepted push), so no extra sticky register is
// needed - "primed" is naturally sticky already. delay_ctl can be at most
// (2**LOG2_FIFO_DEPTH - 1) (its own bit width), always below the physical
// FIFO_WRITE_DEPTH, so the FIFO itself never actually reaches full here.
//
// Measured directly on real hardware (fifo_sample_delay_latency_tb.sv /
// fifo_sample_delay_latency_gapped_tb.sv, see chat) under TWO streaming
// patterns: continuous (data_in_valid every cycle) and gapped (realistic -
// data_in_valid once every few cycles, matching an actual ADC sample rate
// far below the FPGA clock). Under continuous streaming, threshold
// delay_ctl-2 gives the correct achieved delay (16); threshold delay_ctl
// (no offset) overshoots by 2 (18). But under gapped streaming, it's the
// OPPOSITE: threshold delay_ctl gives the correct achieved delay (16);
// threshold delay_ctl-2 undershoots by 2 (14). The root cause is that
// wr_data_count's registered latency inside the real xpm_fifo_sync is a
// small, fixed number of CLOCK CYCLES (not "pushes") - under continuous
// streaming (1 push/cycle) that shows up as a 2-push deficit worth
// compensating for, but under ANY realistic gapped streaming (gap between
// pushes wider than that handful of cycles - true for every real ADC rate,
// always far below the FPGA clock) the same few cycles of lag never even
// accumulates to one extra push, so no correction is needed. Since the
// real system always streams with gaps (never back-to-back every cycle),
// `delay_ctl` (no offset) is the correct formula here - the delay_ctl-2
// correction was only valid for the unrealistic continuous-streaming test
// condition it was measured under.
wire primed = (wr_data_count >= delay_ctl);
wire rd_en = primed & data_in_valid & fifo_ready;

assign data_out_valid = rd_en;

xpm_fifo_sync #(
  .DOUT_RESET_VALUE("0"),    // String
  .ECC_MODE("no_ecc"),       // String
  .FIFO_MEMORY_TYPE("auto"), // String
  .FIFO_READ_LATENCY(0),     // DECIMAL
  .FIFO_WRITE_DEPTH(1<<LOG2_FIFO_DEPTH),   // DECIMAL
  .FULL_RESET_VALUE(0),      // DECIMAL
  .PROG_EMPTY_THRESH(10),    // DECIMAL
  .PROG_FULL_THRESH(10),     // DECIMAL
  .RD_DATA_COUNT_WIDTH(LOG2_FIFO_DEPTH+1),   // DECIMAL
  .READ_DATA_WIDTH(DATA_WIDTH),      // DECIMAL
  .READ_MODE("fwft"),         // String
  .USE_ADV_FEATURES("0404"), // only enable rd_data_count and wr_data_count
  .WAKEUP_TIME(0),           // DECIMAL
  .WRITE_DATA_WIDTH(DATA_WIDTH),     // DECIMAL
  .WR_DATA_COUNT_WIDTH(LOG2_FIFO_DEPTH+1)    // DECIMAL
) fifo_1clk_i (
  .almost_empty(),
  .almost_full(),
  .data_valid(),
  .dbiterr(),
  .dout(data_out),
  .empty(empty),
  .full(full),
  .overflow(),
  .prog_empty(),
  .prog_full(),
  .rd_data_count(rd_data_count),
  .rd_rst_busy(rd_rst_busy),
  .sbiterr(),
  .underflow(),
  .wr_ack(),
  .wr_data_count(wr_data_count),
  .wr_rst_busy(wr_rst_busy),
  .din(data_in),
  .injectdbiterr(),
  .injectsbiterr(),
  .rd_en(rd_en),
  .rst(rst),
  .sleep(),
  .wr_clk(clk),
  .wr_en(data_in_valid && fifo_ready)
);

endmodule



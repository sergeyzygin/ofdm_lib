//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Company: ZNAutomation
// Engineer: Sergey Zygin
//
// Create Date: 06.05.2026
// Design Name: complex_to_mag_sq
// Module Name: complex_to_mag_sq
// Project Name: ofdm_lib
// Target Devices:
// Tool Versions:
// Description: Squared magnitude |z|^2 = z*conj(z) via complex_mult (Q saturated on negation).
//              Port-compatible with OpenOFDM's complex_to_mag_sq.
//              Original implementation, not derived from OpenOFDM source code.
//
// Dependencies: complex_mult
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
module complex_to_mag_sq (
    input clock,
    input enable,
    input reset,

    input signed [15:0] i,
    input signed [15:0] q,
    input input_strobe,

    output [31:0] mag_sq,
    output mag_sq_strobe
);

reg valid_in;
reg [15:0] input_i;
reg [15:0] input_q;
reg [15:0] input_q_neg;

complex_mult mult_inst (
    .clock(clock),
    .reset(reset),
    .enable(enable),
    
    .a_i(input_i),
    .a_q(input_q),
    .b_i(input_i),
    .b_q(input_q_neg),
    .input_strobe(valid_in),

    .p_i(mag_sq),
    .output_strobe(mag_sq_strobe)
);

always @(posedge clock) begin
    if (reset) begin
        input_i <= 0;
        input_q <= 0;
        input_q_neg <= 0;
        valid_in <= 0;
    end else if (enable) begin
        valid_in <= input_strobe;
        input_i <= i;
        input_q <= q;
        input_q_neg <= (q == -16'sh8000) ? 16'sh7FFF : (~q+1);
    end
end
endmodule
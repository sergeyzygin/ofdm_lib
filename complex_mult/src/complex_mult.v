//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Company: ZNAutomation
// Engineer: Sergey Zygin
//
// Create Date: 01.05.2026 
// Design Name: complex_mult
// Module Name: complex_mult
// Project Name: ofdm_lib
// Target Devices:
// Tool Versions:
// Description: Complex multiplier, port-compatible with OpenOFDM's complex_mult.
//              Original implementation, not derived from OpenOFDM source code.
//
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
module complex_mult #(
    parameter WIDTH_IN  = 16,
    parameter WIDTH_OUT = 32   // WIDTH_IN*2 
)(
    input  wire                         clock,
    input  wire                         reset,
    input wire                          enable,
    input  wire signed [WIDTH_IN-1:0]   a_i,
    input  wire signed [WIDTH_IN-1:0]   a_q,
    input  wire signed [WIDTH_IN-1:0]   b_i,
    input  wire signed [WIDTH_IN-1:0]   b_q,
    input  wire                         input_strobe,

    output reg  signed [WIDTH_OUT-1:0]  p_i,
    output reg  signed [WIDTH_OUT-1:0]  p_q,
    output reg                          output_strobe
);

    // ---- Стадия 1: регистрируем входы и считаем 4 произведения ----
    (* use_dsp = "yes" *)
    reg signed [2*WIDTH_IN-1:0] mul_ai_bi, mul_aq_bq, mul_ai_bq, mul_aq_bi;
    reg stage1_valid;

    always @(posedge clock) begin
        if (reset) begin
            stage1_valid <= 1'b0;
        end else begin
            mul_ai_bi <= a_i * b_i;
            mul_aq_bq <= a_q * b_q;
            mul_ai_bq <= a_i * b_q;
            mul_aq_bi <= a_q * b_i;
            stage1_valid <= input_strobe;
        end
    end

    // ---- Стадия 2: складываем/вычитаем и выдаём результат ----
    always @(posedge clock) begin
        if (reset) begin
            output_strobe <= 1'b0;
        end else begin
            p_i <= mul_ai_bi - mul_aq_bq;   // Re(a*b) = ai*bi - aq*bq
            p_q <= mul_ai_bq + mul_aq_bi;   // Im(a*b) = ai*bq + aq*bi
            output_strobe <= stage1_valid;
        end
    end

endmodule
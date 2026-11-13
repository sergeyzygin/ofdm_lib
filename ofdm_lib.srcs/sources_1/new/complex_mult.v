`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: Sergey Zygin
// 
// Create Date: 07/07/2026 02:52:55 PM
// Design Name: 
// Module Name: complex_mult
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module complex_mult
(
    input clock,
    input enable,
    input reset,

    input [15:0] a_i,
    input [15:0] a_q,
    input [15:0] b_i,
    input [15:0] b_q,
    input input_strobe,

    output [31:0] p_i,
    output [31:0] p_q,
    output output_strobe
);

wire [63:0] m_axis_dout_tdata;
assign p_q = m_axis_dout_tdata[63:32];
assign p_i = m_axis_dout_tdata[31:0];
cmpy_0 mult_inst (
  .aclk(clock),                                 // input wire aclk
  .s_axis_a_tvalid(input_strobe),        	// input wire s_axis_a_tvalid
  .s_axis_a_tdata({a_q, a_i}),         	// input wire [31 : 0] s_axis_a_tdata
  .s_axis_b_tvalid(input_strobe),        	// input wire s_axis_b_tvalid
  .s_axis_b_tdata({b_q, b_i}),          	// input wire [31 : 0] s_axis_b_tdata
  .m_axis_dout_tvalid(output_strobe),  	// output wire m_axis_dout_tvalid
  .m_axis_dout_tdata(m_axis_dout_tdata)    	// output wire [63 : 0] m_axis_dout_tdata
);

endmodule

`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer: Sergey Zygin
//
// Create Date: 07/07/2026
// Module Name: complex_mult_tb
// Description: Self-checking testbench for complex_mult.
//   Drives random complex samples into the DUT with randomised gaps between
//   input_strobe pulses and scoreboards every result that comes back on
//   output_strobe against a behavioural (a+jb)*(c+jd) model computed in
//   32-bit signed arithmetic (matches the core's Truncate rounding mode,
//   since Verilog's 32-bit reg arithmetic wraps the same way as the IP).
//////////////////////////////////////////////////////////////////////////////////

module complex_mult_tb;

    localparam CLK_PERIOD   = 10;      // 100 MHz
    localparam NUM_TX       = 500;     // number of complex multiplications to check
    localparam QUEUE_DEPTH  = 256;     // must be >= pipeline latency, power of 2

    reg clock;
    reg reset;
    reg enable;

    reg  [15:0] a_i, a_q;
    reg  [15:0] b_i, b_q;
    reg         input_strobe;

    wire [31:0] p_i, p_q;
    wire        output_strobe;

    // ---------------------------------------------------------------
    // DUT
    // ---------------------------------------------------------------
    complex_mult dut (
        .clock          (clock),
        .enable         (enable),
        .reset          (reset),

        .a_i            (a_i),
        .a_q            (a_q),
        .b_i            (b_i),
        .b_q            (b_q),
        .input_strobe   (input_strobe),

        .p_i            (p_i),
        .p_q            (p_q),
        .output_strobe  (output_strobe)
    );

    // ---------------------------------------------------------------
    // Clock
    // ---------------------------------------------------------------
    initial clock = 1'b0;
    always #(CLK_PERIOD/2) clock = ~clock;

    // ---------------------------------------------------------------
    // Scoreboard: FIFO of expected results, pushed on input_strobe,
    // popped and compared on output_strobe. Depth is a power of two so
    // the pointers wrap naturally without extra logic.
    // ---------------------------------------------------------------
    reg signed [31:0] exp_i_q [0:QUEUE_DEPTH-1];
    reg signed [31:0] exp_q_q [0:QUEUE_DEPTH-1];
    reg [7:0] wr_ptr;
    reg [7:0] rd_ptr;

    integer sent_count;
    integer checked_count;
    integer error_count;

    wire signed [15:0] a_i_s = a_i;
    wire signed [15:0] a_q_s = a_q;
    wire signed [15:0] b_i_s = b_i;
    wire signed [15:0] b_q_s = b_q;

    // push expected values whenever a sample is accepted
    always @(posedge clock) begin
        if (reset) begin
            wr_ptr <= 8'd0;
        end else if (enable && input_strobe) begin
            exp_i_q[wr_ptr] <= a_i_s * b_i_s - a_q_s * b_q_s;
            exp_q_q[wr_ptr] <= a_i_s * b_q_s + a_q_s * b_i_s;
            wr_ptr <= wr_ptr + 8'd1;
        end
    end

    // pop and compare whenever the DUT produces a result
    always @(posedge clock) begin
        if (reset) begin
            rd_ptr        <= 8'd0;
            checked_count <= 0;
            error_count   <= 0;
        end else if (output_strobe) begin
            if (rd_ptr == wr_ptr) begin
                $display("[%0t] ERROR: output_strobe with empty scoreboard (spurious result)", $time);
                error_count <= error_count + 1;
            end else begin
                if (p_i !== exp_i_q[rd_ptr] || p_q !== exp_q_q[rd_ptr]) begin
                    $display("[%0t] MISMATCH #%0d: got p_i=%0d p_q=%0d, expected p_i=%0d p_q=%0d",
                              $time, checked_count, $signed(p_i), $signed(p_q),
                              exp_i_q[rd_ptr], exp_q_q[rd_ptr]);
                    error_count <= error_count + 1;
                end
                rd_ptr        <= rd_ptr + 8'd1;
                checked_count <= checked_count + 1;
            end
        end
    end

    // ---------------------------------------------------------------
    // Stimulus
    // ---------------------------------------------------------------
    integer gap;

    task apply_sample(input [15:0] ai, input [15:0] aq, input [15:0] bi, input [15:0] bq);
        begin
            @(posedge clock);
            a_i          <= ai;
            a_q          <= aq;
            b_i          <= bi;
            b_q          <= bq;
            input_strobe <= 1'b1;
            sent_count = sent_count + 1;
            @(posedge clock);
            input_strobe <= 1'b0;
        end
    endtask

    initial begin
        reset        = 1'b1;
        enable       = 1'b1;
        input_strobe = 1'b0;
        a_i = 16'sd0; a_q = 16'sd0; b_i = 16'sd0; b_q = 16'sd0;
        sent_count   = 0;

        repeat (10) @(posedge clock);
        reset = 1'b0;
        repeat (5) @(posedge clock);

        // Directed corner cases first: max/min values and simple unity checks
        apply_sample(16'sd1,      16'sd0,      16'sd1,      16'sd0);      // 1 * 1
        apply_sample(16'sd0,      16'sd1,      16'sd0,      16'sd1);      // j * j = -1
        apply_sample(16'sh7FFF,   16'sh7FFF,   16'sh7FFF,   16'sh7FFF);   // max positive
        apply_sample(16'sh8000,   16'sh8000,   16'sh8000,   16'sh8000);   // max negative (overflow-prone)
        apply_sample(16'sd0,      16'sd0,      16'sh7FFF,   16'sh8000);   // zero operand

        // Random samples with randomised gaps between strobes
        for (gap = 0; gap < NUM_TX; gap = gap + 1) begin
            apply_sample($random, $random, $random, $random);
            repeat ($urandom_range(0, 3)) @(posedge clock);
        end

        // Let the pipeline drain
        repeat (50) @(posedge clock);

        if (checked_count == 0) begin
            $display("TESTBENCH FAILED: no results were ever checked (output_strobe never asserted)");
            $finish;
        end else if (error_count == 0) begin
            $display("TESTBENCH PASSED: %0d transactions checked, 0 errors", checked_count);
        end else begin
            $display("TESTBENCH FAILED: %0d transactions checked, %0d errors", checked_count, error_count);
        end

        $finish;
    end

    // Safety timeout in case output_strobe never fires
    initial begin
        #(CLK_PERIOD * 20000);
        $display("TESTBENCH FAILED: global timeout reached (checked=%0d, sent=%0d)", checked_count, sent_count);
        $finish;
    end

endmodule

//------------------------------------------------------------------------------
// pe.v
//
// Signed 8-bit by signed 8-bit processing element for the Foundry systolic
// array. On each valid clock cycle the PE accumulates a_in * b_in into a
// signed 32-bit accumulator and registers a_in, b_in, and valid_in for the
// neighboring PEs. rst_n is active low. clear_acc clears only the accumulator
// so the array can be reused between inferences without resetting the fabric.
//------------------------------------------------------------------------------
`timescale 1ns/1ps

module pe (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               clear_acc,
    input  wire signed [7:0]  a_in,
    input  wire signed [7:0]  b_in,
    input  wire               valid_in,
    output reg  signed [7:0]  a_out,
    output reg  signed [7:0]  b_out,
    output reg  signed [31:0] acc,
    output reg                valid_out
);
    wire signed [15:0] product;

    assign product = a_in * b_in;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out     <= 8'sd0;
            b_out     <= 8'sd0;
            acc       <= 32'sd0;
            valid_out <= 1'b0;
        end else begin
            a_out     <= a_in;
            b_out     <= b_in;
            valid_out <= valid_in;

            if (clear_acc) begin
                acc <= 32'sd0;
            end else if (valid_in) begin
                acc <= acc + {{16{product[15]}}, product};
            end
        end
    end
endmodule

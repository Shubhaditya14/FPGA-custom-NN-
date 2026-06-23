//------------------------------------------------------------------------------
// systolic_array_core.v
//
// 16x16 signed INT8 systolic array made from 256 PE instances. A values enter
// from the left and move right. B values enter from the top and move down.
// valid_in is supplied per input row and is pipelined rightward through each
// row, matching the A data path. All 256 signed 32-bit accumulators are exposed
// as one flattened row-major bus: acc_flat[(i*16+j)*32 +: 32] is C[i][j].
//------------------------------------------------------------------------------
`timescale 1ns/1ps

module systolic_array_core (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              clear_acc,
    input  wire [16*8-1:0]   a_in,
    input  wire [16*8-1:0]   b_in,
    input  wire [15:0]       valid_in,
    output wire [16*16*32-1:0] acc_flat
);
    wire [16*17*8-1:0] a_pipe;
    wire [17*16*8-1:0] b_pipe;
    wire [16*17-1:0]   valid_pipe;

    genvar boundary_idx;
    generate
        for (boundary_idx = 0; boundary_idx < 16; boundary_idx = boundary_idx + 1) begin : boundary
            assign a_pipe[(boundary_idx*17)*8 +: 8] = a_in[boundary_idx*8 +: 8];
            assign b_pipe[boundary_idx*8 +: 8] = b_in[boundary_idx*8 +: 8];
            assign valid_pipe[boundary_idx*17] = valid_in[boundary_idx];
        end
    endgenerate

    genvar row;
    genvar col;
    generate
        for (row = 0; row < 16; row = row + 1) begin : pe_row
            for (col = 0; col < 16; col = col + 1) begin : pe_col
                pe u_pe (
                    .clk(clk),
                    .rst_n(rst_n),
                    .clear_acc(clear_acc),
                    .a_in(a_pipe[(row*17 + col)*8 +: 8]),
                    .b_in(b_pipe[(row*16 + col)*8 +: 8]),
                    .valid_in(valid_pipe[row*17 + col]),
                    .a_out(a_pipe[(row*17 + col + 1)*8 +: 8]),
                    .b_out(b_pipe[((row + 1)*16 + col)*8 +: 8]),
                    .acc(acc_flat[(row*16 + col)*32 +: 32]),
                    .valid_out(valid_pipe[row*17 + col + 1])
                );
            end
        end
    endgenerate
endmodule

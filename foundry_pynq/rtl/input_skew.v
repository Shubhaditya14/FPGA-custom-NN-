//------------------------------------------------------------------------------
// input_skew.v
//
// Converts two stored 16x16 INT8 matrices into the wavefront required by the
// systolic array. A[i][k] enters from the left side of row i, and B[k][j]
// enters from the top of column j. To make PE[i][j] receive A[i][k] and B[k][j]
// in the same cycle, row i of A is delayed by i cycles and column j of B is
// delayed by j cycles.
//
// 3x3 wavefront example:
//   Cycle 0: A[0][0], B[0][0] enter array.
//   Cycle 1: A[0][1] and A[1][0] enter; B[0][1] and B[1][0] enter.
//   Cycle 2: A[0][2], A[1][1], A[2][0] enter simultaneously;
//            B[0][2], B[1][1], B[2][0] enter simultaneously.
//
// That diagonal pattern is the wavefront. The shift-register chains below are
// the hardware implementation of the row and column delays.
//------------------------------------------------------------------------------
`timescale 1ns/1ps

module input_skew (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              start,
    input  wire [16*16*8-1:0] A_flat,
    input  wire [16*16*8-1:0] B_flat,
    output reg  [16*8-1:0]   a_skewed,
    output reg  [16*8-1:0]   b_skewed,
    output reg  [15:0]       valid_rows
);
    reg [4:0] cycle_ctr;
    reg       running;

    reg signed [7:0] a_delay [0:15][0:15];
    reg signed [7:0] b_delay [0:15][0:15];

    integer r;
    integer c;
    integer d;
    reg signed [7:0] src_a;
    reg signed [7:0] src_b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_ctr  <= 5'd0;
            running    <= 1'b0;
            a_skewed   <= 128'd0;
            b_skewed   <= 128'd0;
            valid_rows <= 16'd0;
            for (r = 0; r < 16; r = r + 1) begin
                for (d = 0; d < 16; d = d + 1) begin
                    a_delay[r][d] <= 8'sd0;
                    b_delay[r][d] <= 8'sd0;
                end
            end
        end else begin
            if (start) begin
                cycle_ctr <= 5'd0;
                running   <= 1'b1;
                for (r = 0; r < 16; r = r + 1) begin
                    for (d = 0; d < 16; d = d + 1) begin
                        a_delay[r][d] <= 8'sd0;
                        b_delay[r][d] <= 8'sd0;
                    end
                end
            end else if (running) begin
                if (cycle_ctr == 5'd31) begin
                    running <= 1'b0;
                end
                cycle_ctr <= cycle_ctr + 5'd1;
            end

            for (r = 0; r < 16; r = r + 1) begin
                if (running && cycle_ctr < 5'd16) begin
                    src_a = A_flat[(r*16 + cycle_ctr)*8 +: 8];
                end else begin
                    src_a = 8'sd0;
                end

                a_delay[r][0] <= src_a;
                for (d = 1; d < 16; d = d + 1) begin
                    a_delay[r][d] <= a_delay[r][d-1];
                end

                // Row r is delayed by exactly r cycles. Row 0 bypasses the
                // delay chain; row 15 uses the 15th registered delay element.
                if (r == 0) begin
                    a_skewed[r*8 +: 8] <= src_a;
                end else begin
                    a_skewed[r*8 +: 8] <= a_delay[r][r-1];
                end

                if (running && cycle_ctr >= r && cycle_ctr < (r + 16)) begin
                    valid_rows[r] <= 1'b1;
                end else begin
                    valid_rows[r] <= 1'b0;
                end
            end

            for (c = 0; c < 16; c = c + 1) begin
                if (running && cycle_ctr < 5'd16) begin
                    src_b = B_flat[(cycle_ctr*16 + c)*8 +: 8];
                end else begin
                    src_b = 8'sd0;
                end

                b_delay[c][0] <= src_b;
                for (d = 1; d < 16; d = d + 1) begin
                    b_delay[c][d] <= b_delay[c][d-1];
                end

                // Column c is delayed by exactly c cycles, so B[k][c] reaches
                // the top of column c on the same wavefront as A[*][k].
                if (c == 0) begin
                    b_skewed[c*8 +: 8] <= src_b;
                end else begin
                    b_skewed[c*8 +: 8] <= b_delay[c][c-1];
                end
            end
        end
    end
endmodule

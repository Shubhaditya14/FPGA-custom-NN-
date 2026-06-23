//------------------------------------------------------------------------------
// systolic_top.v
//
// AXI-Lite/AXI-Stream wrapper for the Foundry 16x16 systolic array. The
// AXI-Lite slave exposes control, status, cycle-count, and matrix-size
// registers. Two 128-bit AXI-Stream slaves load A and B as sixteen 16-byte
// rows. A 128-bit AXI-Stream master returns 256 INT32 results as 64 beats.
//
// Register map:
//   0x00 CONTROL        bit0=start, bit1=clear accumulators
//   0x04 STATUS         bit0=done, bit1=busy
//   0x08 CYCLE_COUNT_LO lower 32 bits
//   0x0C CYCLE_COUNT_HI upper 32 bits
//   0x10 MATRIX_SIZE    hardcoded 16
//------------------------------------------------------------------------------
`timescale 1ns/1ps

module systolic_top (
    input  wire         s_axi_aclk,
    input  wire         s_axi_aresetn,

    input  wire [5:0]   s_axi_awaddr,
    input  wire         s_axi_awvalid,
    output reg          s_axi_awready,
    input  wire [31:0]  s_axi_wdata,
    input  wire [3:0]   s_axi_wstrb,
    input  wire         s_axi_wvalid,
    output reg          s_axi_wready,
    output reg  [1:0]   s_axi_bresp,
    output reg          s_axi_bvalid,
    input  wire         s_axi_bready,

    input  wire [5:0]   s_axi_araddr,
    input  wire         s_axi_arvalid,
    output reg          s_axi_arready,
    output reg  [31:0]  s_axi_rdata,
    output reg  [1:0]   s_axi_rresp,
    output reg          s_axi_rvalid,
    input  wire         s_axi_rready,

    input  wire [127:0] s_axis_a_tdata,
    input  wire         s_axis_a_tvalid,
    output wire         s_axis_a_tready,
    input  wire         s_axis_a_tlast,

    input  wire [127:0] s_axis_b_tdata,
    input  wire         s_axis_b_tvalid,
    output wire         s_axis_b_tready,
    input  wire         s_axis_b_tlast,

    output reg  [127:0] m_axis_result_tdata,
    output reg          m_axis_result_tvalid,
    input  wire         m_axis_result_tready,
    output reg          m_axis_result_tlast
);
    localparam ST_IDLE      = 2'd0;
    localparam ST_LOADING   = 2'd1;
    localparam ST_COMPUTING = 2'd2;
    localparam ST_DONE      = 2'd3;

    localparam COMPUTE_CYCLES = 8'd50;

    reg [1:0] state;
    reg [4:0] a_load_count;
    reg [4:0] b_load_count;
    reg [7:0] compute_count;
    reg [5:0] result_count;

    reg [16*16*8-1:0] matrix_a;
    reg [16*16*8-1:0] matrix_b;
    wire [16*8-1:0]   a_skewed;
    wire [16*8-1:0]   b_skewed;
    wire [15:0]       valid_rows;
    wire [16*16*32-1:0] acc_flat;

    reg [63:0] cycle_count;
    reg        done_reg;
    reg        clear_acc_reg;
    reg        skew_start;

    reg        aw_seen;
    reg        w_seen;
    reg [5:0]  awaddr_latched;
    reg [31:0] wdata_latched;
    reg [3:0]  wstrb_latched;

    assign s_axis_a_tready = (state == ST_LOADING) && (a_load_count < 5'd16);
    assign s_axis_b_tready = (state == ST_LOADING) && (b_load_count < 5'd16);

    input_skew u_input_skew (
        .clk(s_axi_aclk),
        .rst_n(s_axi_aresetn),
        .start(skew_start),
        .A_flat(matrix_a),
        .B_flat(matrix_b),
        .a_skewed(a_skewed),
        .b_skewed(b_skewed),
        .valid_rows(valid_rows)
    );

    systolic_array_core u_core (
        .clk(s_axi_aclk),
        .rst_n(s_axi_aresetn),
        .clear_acc(clear_acc_reg),
        .a_in(a_skewed),
        .b_in(b_skewed),
        .valid_in(valid_rows),
        .acc_flat(acc_flat)
    );

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            s_axi_bvalid  <= 1'b0;
            s_axi_arready <= 1'b0;
            s_axi_rdata   <= 32'd0;
            s_axi_rresp   <= 2'b00;
            s_axi_rvalid  <= 1'b0;
            aw_seen       <= 1'b0;
            w_seen        <= 1'b0;
            awaddr_latched <= 6'd0;
            wdata_latched  <= 32'd0;
            wstrb_latched  <= 4'd0;
        end else begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_arready <= 1'b0;

            if (!aw_seen && !s_axi_bvalid && s_axi_awvalid) begin
                s_axi_awready  <= 1'b1;
                awaddr_latched <= s_axi_awaddr;
                aw_seen        <= 1'b1;
            end

            if (!w_seen && !s_axi_bvalid && s_axi_wvalid) begin
                s_axi_wready  <= 1'b1;
                wdata_latched <= s_axi_wdata;
                wstrb_latched <= s_axi_wstrb;
                w_seen        <= 1'b1;
            end

            if (aw_seen && w_seen && !s_axi_bvalid) begin
                s_axi_bresp  <= 2'b00;
                s_axi_bvalid <= 1'b1;
                aw_seen      <= 1'b0;
                w_seen       <= 1'b0;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end

            if (!s_axi_rvalid && s_axi_arvalid) begin
                s_axi_arready <= 1'b1;
                s_axi_rresp   <= 2'b00;
                s_axi_rvalid  <= 1'b1;
                case (s_axi_araddr[5:0])
                    6'h04: s_axi_rdata <= {30'd0, (state != ST_IDLE), done_reg};
                    6'h08: s_axi_rdata <= cycle_count[31:0];
                    6'h0c: s_axi_rdata <= cycle_count[63:32];
                    6'h10: s_axi_rdata <= 32'd16;
                    default: s_axi_rdata <= 32'd0;
                endcase
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            state                <= ST_IDLE;
            a_load_count         <= 5'd0;
            b_load_count         <= 5'd0;
            compute_count        <= 8'd0;
            result_count         <= 6'd0;
            matrix_a             <= 2048'd0;
            matrix_b             <= 2048'd0;
            cycle_count          <= 64'd0;
            done_reg             <= 1'b0;
            clear_acc_reg        <= 1'b0;
            skew_start           <= 1'b0;
            m_axis_result_tdata  <= 128'd0;
            m_axis_result_tvalid <= 1'b0;
            m_axis_result_tlast  <= 1'b0;
        end else begin
            clear_acc_reg <= 1'b0;
            skew_start    <= 1'b0;

            if (aw_seen && w_seen && !s_axi_bvalid && awaddr_latched[5:0] == 6'h00) begin
                if (wdata_latched[1]) begin
                    clear_acc_reg <= 1'b1;
                    done_reg      <= 1'b0;
                end
                if (wdata_latched[0] && state == ST_IDLE) begin
                    state        <= ST_LOADING;
                    a_load_count <= 5'd0;
                    b_load_count <= 5'd0;
                    result_count <= 6'd0;
                    cycle_count  <= 64'd0;
                    done_reg     <= 1'b0;
                    clear_acc_reg <= 1'b1;
                end
            end

            if (state != ST_IDLE && !done_reg) begin
                cycle_count <= cycle_count + 64'd1;
            end

            case (state)
                ST_IDLE: begin
                    m_axis_result_tvalid <= 1'b0;
                    m_axis_result_tlast  <= 1'b0;
                end

                ST_LOADING: begin
                    if (s_axis_a_tvalid && s_axis_a_tready) begin
                        matrix_a[a_load_count*128 +: 128] <= s_axis_a_tdata;
                        a_load_count <= a_load_count + 5'd1;
                    end
                    if (s_axis_b_tvalid && s_axis_b_tready) begin
                        matrix_b[b_load_count*128 +: 128] <= s_axis_b_tdata;
                        b_load_count <= b_load_count + 5'd1;
                    end
                    if ((a_load_count == 5'd16) && (b_load_count == 5'd16)) begin
                        state         <= ST_COMPUTING;
                        compute_count <= 8'd0;
                        skew_start    <= 1'b1;
                    end
                end

                ST_COMPUTING: begin
                    compute_count <= compute_count + 8'd1;
                    if (compute_count == (COMPUTE_CYCLES - 1)) begin
                        state                <= ST_DONE;
                        done_reg             <= 1'b1;
                        result_count         <= 6'd0;
                        m_axis_result_tvalid <= 1'b1;
                        m_axis_result_tdata  <= acc_flat[0 +: 128];
                        m_axis_result_tlast  <= 1'b0;
                    end
                end

                ST_DONE: begin
                    if (m_axis_result_tvalid && m_axis_result_tready) begin
                        if (result_count == 6'd63) begin
                            m_axis_result_tvalid <= 1'b0;
                            m_axis_result_tlast  <= 1'b0;
                            state                <= ST_IDLE;
                        end else begin
                            result_count <= result_count + 6'd1;
                            m_axis_result_tdata <= acc_flat[(result_count + 6'd1)*128 +: 128];
                            m_axis_result_tlast <= (result_count == 6'd62);
                        end
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule

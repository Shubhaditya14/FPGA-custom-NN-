//------------------------------------------------------------------------------
// tb_systolic_top.v
//
// Verilog testbench for systolic_top. It performs AXI-Lite writes/reads,
// streams two 16x16 INT8 matrices into the design, receives all 256 INT32
// results, checks them against C[i][j] = 16*(i+1)*(j+1), prints the hardware
// cycle count, and terminates with PASS or FAIL. Timeout is 50000 cycles.
//------------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_systolic_top;
    reg clk;
    reg rst_n;

    reg [5:0] awaddr;
    reg awvalid;
    wire awready;
    reg [31:0] wdata;
    reg [3:0] wstrb;
    reg wvalid;
    wire wready;
    wire [1:0] bresp;
    wire bvalid;
    reg bready;

    reg [5:0] araddr;
    reg arvalid;
    wire arready;
    wire [31:0] rdata;
    wire [1:0] rresp;
    wire rvalid;
    reg rready;

    reg [127:0] a_tdata;
    reg a_tvalid;
    wire a_tready;
    reg a_tlast;

    reg [127:0] b_tdata;
    reg b_tvalid;
    wire b_tready;
    reg b_tlast;

    wire [127:0] result_tdata;
    wire result_tvalid;
    reg result_tready;
    wire result_tlast;

    reg signed [31:0] result_words [0:255];
    reg signed [31:0] expected;
    reg [31:0] status_value;
    reg [31:0] cycles_lo;
    reg [31:0] cycles_hi;
    reg [127:0] row_word;

    integer i;
    integer j;
    integer beat;
    integer lane;
    integer mismatch;
    integer timeout_counter;

    systolic_top dut (
        .s_axi_aclk(clk),
        .s_axi_aresetn(rst_n),
        .s_axi_awaddr(awaddr),
        .s_axi_awvalid(awvalid),
        .s_axi_awready(awready),
        .s_axi_wdata(wdata),
        .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid),
        .s_axi_wready(wready),
        .s_axi_bresp(bresp),
        .s_axi_bvalid(bvalid),
        .s_axi_bready(bready),
        .s_axi_araddr(araddr),
        .s_axi_arvalid(arvalid),
        .s_axi_arready(arready),
        .s_axi_rdata(rdata),
        .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid),
        .s_axi_rready(rready),
        .s_axis_a_tdata(a_tdata),
        .s_axis_a_tvalid(a_tvalid),
        .s_axis_a_tready(a_tready),
        .s_axis_a_tlast(a_tlast),
        .s_axis_b_tdata(b_tdata),
        .s_axis_b_tvalid(b_tvalid),
        .s_axis_b_tready(b_tready),
        .s_axis_b_tlast(b_tlast),
        .m_axis_result_tdata(result_tdata),
        .m_axis_result_tvalid(result_tvalid),
        .m_axis_result_tready(result_tready),
        .m_axis_result_tlast(result_tlast)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task axi_write;
        input [5:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            awaddr  <= addr;
            awvalid <= 1'b1;
            wdata   <= data;
            wstrb   <= 4'hf;
            wvalid  <= 1'b1;
            bready  <= 1'b1;
            #1;
            while (!awready || !wready) begin
                @(posedge clk);
                #1;
            end
            awvalid <= 1'b0;
            wvalid  <= 1'b0;
            while (!bvalid) begin
                @(posedge clk);
                #1;
            end
            @(posedge clk);
            bready <= 1'b0;
        end
    endtask

    task axi_read;
        input [5:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            araddr  <= addr;
            arvalid <= 1'b1;
            rready  <= 1'b1;
            #1;
            while (!arready) begin
                @(posedge clk);
                #1;
            end
            arvalid <= 1'b0;
            while (!rvalid) begin
                @(posedge clk);
                #1;
            end
            data = rdata;
            @(posedge clk);
            rready <= 1'b0;
        end
    endtask

    task stream_a_matrix;
        integer row_idx;
        integer col_idx;
        reg [127:0] local_row;
        begin
            for (row_idx = 0; row_idx < 16; row_idx = row_idx + 1) begin
                local_row = 128'd0;
                for (col_idx = 0; col_idx < 16; col_idx = col_idx + 1) begin
                    local_row[col_idx*8 +: 8] = row_idx + 1;
                end
                @(posedge clk);
                a_tdata  <= local_row;
                a_tvalid <= 1'b1;
                a_tlast  <= (row_idx == 15);
                #1;
                while (!a_tready) begin
                    @(posedge clk);
                    #1;
                end
            end
            @(posedge clk);
            a_tvalid <= 1'b0;
            a_tlast  <= 1'b0;
        end
    endtask

    task stream_b_matrix;
        integer row_idx;
        integer col_idx;
        reg [127:0] local_row;
        begin
            for (row_idx = 0; row_idx < 16; row_idx = row_idx + 1) begin
                local_row = 128'd0;
                for (col_idx = 0; col_idx < 16; col_idx = col_idx + 1) begin
                    local_row[col_idx*8 +: 8] = col_idx + 1;
                end
                @(posedge clk);
                b_tdata  <= local_row;
                b_tvalid <= 1'b1;
                b_tlast  <= (row_idx == 15);
                #1;
                while (!b_tready) begin
                    @(posedge clk);
                    #1;
                end
            end
            @(posedge clk);
            b_tvalid <= 1'b0;
            b_tlast  <= 1'b0;
        end
    endtask

    initial begin
        timeout_counter = 0;
        while (timeout_counter < 50000) begin
            @(posedge clk);
            timeout_counter = timeout_counter + 1;
        end
        $display("FAIL: timeout after 50000 cycles");
        $finish;
    end

    initial begin
        rst_n = 1'b0;
        awaddr = 6'd0;
        awvalid = 1'b0;
        wdata = 32'd0;
        wstrb = 4'd0;
        wvalid = 1'b0;
        bready = 1'b0;
        araddr = 6'd0;
        arvalid = 1'b0;
        rready = 1'b0;
        a_tdata = 128'd0;
        a_tvalid = 1'b0;
        a_tlast = 1'b0;
        b_tdata = 128'd0;
        b_tvalid = 1'b0;
        b_tlast = 1'b0;
        result_tready = 1'b0;
        mismatch = 0;

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        axi_write(6'h00, 32'h00000002);
        axi_write(6'h00, 32'h00000001);

        fork
            stream_a_matrix();
            stream_b_matrix();
        join

        status_value = 32'd0;
        while (status_value[0] == 1'b0) begin
            axi_read(6'h04, status_value);
        end

        result_tready <= 1'b1;
        beat = 0;
        while (beat < 64) begin
            @(posedge clk);
            if (result_tvalid) begin
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    result_words[beat*4 + lane] = result_tdata[lane*32 +: 32];
                end
                beat = beat + 1;
            end
        end
        result_tready <= 1'b0;

        axi_read(6'h08, cycles_lo);
        axi_read(6'h0c, cycles_hi);
        $display("CYCLE_COUNT = 0x%08h%08h", cycles_hi, cycles_lo);

        for (i = 0; i < 16; i = i + 1) begin
            for (j = 0; j < 16; j = j + 1) begin
                expected = 16 * (i + 1) * (j + 1);
                if (result_words[i*16 + j] !== expected && mismatch == 0) begin
                    mismatch = 1;
                    $display("FAIL: first mismatch C[%0d][%0d], got %0d expected %0d",
                             i, j, result_words[i*16 + j], expected);
                end
            end
        end

        if (mismatch == 0) begin
            $display("PASS");
        end
        $finish;
    end
endmodule

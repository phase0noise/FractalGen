`timescale 1ns/1ps
// Pin-level SDR SDRAM model: BL2, CL3, and delayed output data. Exercise the
// actual controller at 75 MHz with the half-cycle forwarded clock.
module tb_sdram_boot;
    parameter real DATA_DELAY = 5.4;
    reg clk = 0;
    always #6.667 clk = ~clk;
    reg chip_clk = 0;
    initial begin
        #13.334;
        forever begin chip_clk = 1; #6.667; chip_clk = 0; #6.667; end
    end
    reg reset_n = 0;
    reg rd = 0, wr = 0;
    reg [23:0] address = 0;
    reg [31:0] data = 0;
    reg [3:0] mask = 15;
    reg [7:0] burst = 0;
    wire [31:0] q;
    wire busy, valid, cke, cas_n, ras_n, we_n;
    wire [12:0] a;
    wire [1:0] ba, dqm;
    tri [15:0] dq;
    io_sdram dut(.controller_clk(clk), .chip_clk(chip_clk), .clk_90(chip_clk),
        .reset_n(reset_n), .phy_cke(cke), .phy_clk(), .phy_cas(cas_n),
        .phy_ras(ras_n), .phy_we(we_n), .phy_ba(ba), .phy_a(a),
        .phy_dq(dq), .phy_dqm(dqm), .burst_rd(1'b0), .burst_addr(25'd0),
        .burst_len(11'd0), .burst_32bit(1'b1), .burst_data(),
        .burst_data_valid(), .burst_data_done(), .burstwr(1'b0),
        .burstwr_addr(25'd0), .burstwr_ready(), .burstwr_strobe(1'b0),
        .burstwr_data(16'd0), .burstwr_done(1'b0), .word_rd(rd),
        .word_wr(wr), .word_addr(address), .word_data(data), .word_wstrb(mask),
        .word_burst_len(burst), .word_q(q), .word_busy(busy), .word_q_valid(valid));

    // Sparse storage retains the full bank/row/column tag to detect aliasing.
    reg [15:0] mem [0:8191];
    reg [24:0] tags [0:8191];
    reg [12:0] rows [0:3];
    reg [3:0] opened = 0;
    reg [15:0] drive_data;
    reg drive = 0;
    assign dq = drive ? drive_data : 16'hzzzz;
    integer mode_count = 0, refreshes = 0;
    reg second_write = 0;
    reg [24:0] write_addr;
    reg [4:0] read_pipe = 0;
    reg [24:0] read_addr [0:4];
    integer j;
    reg [24:0] location;
    function integer slot(input [24:0] x);
        slot = {x[24:23], x[10:0]};
    endfunction
    task store_half(input [24:0] x);
        integer s;
        begin
            s = slot(x);
            tags[s] = x;
            if (!dqm[0]) mem[s][7:0] = dq[7:0];
            if (!dqm[1]) mem[s][15:8] = dq[15:8];
        end
    endtask
    always @(posedge chip_clk) if (cke) begin
        // CL3 measured from the edge accepting READ; tAC = 5.4 ns.
        drive <= #(DATA_DELAY) read_pipe[3];
        if (read_pipe[3]) begin
            if (tags[slot(read_addr[3])] !== read_addr[3])
                $fatal(1, "read of unwritten/aliased SDRAM %h", read_addr[3]);
            drive_data <= #(DATA_DELAY) mem[slot(read_addr[3])];
        end
        for (j = 4; j > 0; j = j - 1) begin
            read_pipe[j] = read_pipe[j-1];
            read_addr[j] = read_addr[j-1];
        end
        read_pipe[0] = 0;
        if (second_write) begin
            store_half(write_addr);
            second_write = 0;
        end
        case ({ras_n, cas_n, we_n})
            3'b000: begin
                mode_count = mode_count + 1;
                if (ba !== 0 || a !== 13'h031)
                    $fatal(1, "invalid SDR mode command BA=%h A=%h", ba, a);
            end
            3'b011: begin rows[ba] = a; opened[ba] = 1; end
            3'b010: begin
                if (a[10]) opened = 0; else opened[ba] = 0;
            end
            3'b001: begin
                if (opened) $fatal(1, "refresh with an open bank");
                refreshes = refreshes + 1;
            end
            3'b100: begin
                if (!opened[ba]) $fatal(1, "write to closed bank");
                location = {ba, rows[ba], a[9:0]};
                store_half(location);
                write_addr = location ^ 25'd1;
                second_write = 1;
            end
            3'b101: begin
                if (!opened[ba]) $fatal(1, "read from closed bank");
                location = {ba, rows[ba], a[9:0]};
                read_pipe[1:0] = 2'b11;
                read_addr[1] = location;
                read_addr[0] = location ^ 25'd1;
                // First beat in stage 1 reaches the output after three
                // edges; preserve pending beats from earlier READ commands.
            end
        endcase
    end

    task write_word(input [23:0] addr, input [31:0] value, input [3:0] strobe);
        begin
            wait (!busy);
            @(negedge clk); address = addr; data = value; mask = strobe; wr = 1;
            @(negedge clk); wr = 0;
            if (!busy) $fatal(1, "write request queued without asserting busy");
            wait (busy); wait (!busy);
        end
    endtask
    task read_words(input [23:0] addr, input [7:0] len, input [31:0] base);
        integer n;
        begin
            wait (!busy);
            @(negedge clk); address = addr; burst = len; rd = 1;
            @(negedge clk); rd = 0;
            for (n = 0; n <= len; n = n + 1) begin
                @(negedge clk);
                while (!valid) @(negedge clk);
                if (q !== base + n)
                    $fatal(1, "read %h beat %0d expected %h got %h", addr, n, base+n, q);
            end
            wait (!busy);
        end
    endtask
    integer i;
    initial begin
        #100; reset_n = 1;
        repeat (31000) @(negedge clk);
        write_word(24'hc00000, 32'h44415749, 15); // WAD at 0x53000000
        read_words(24'hc00000, 0, 32'h44415749);
        write_word(24'hc00000, 32'h00000050, 1);
        read_words(24'hc00000, 0, 32'h44415750);
        for (i = 0; i < 8; i = i + 1)
            write_word(24'h0801fc+i, 32'h12345600+i, 15);
        read_words(24'h0801fc, 7, 32'h12345600); // cache fill across row
        for (i = 0; i < 128; i = i + 1)
            write_word(24'h0801f0+i, 32'habcdef00+i, 15);
        read_words(24'h0801f0, 127, 32'habcdef00); // bounded video burst across row
        repeat (1100) @(negedge clk);
        read_words(24'hc00000, 0, 32'h44415750);
        if (mode_count != 1 || refreshes < 3) $fatal(1, "initialization/refresh missing");
        $display("PASS SDRAM (data delay %0.1f ns): mode, WAD header, byte writes, burst/row crossing, refresh", DATA_DELAY);
        $finish;
    end
    initial begin #2000000; $fatal(1, "SDRAM test timeout"); end
endmodule

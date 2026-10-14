`timescale 1ns/1ps
// Pin-level BL2/CL3 SDRAM model preloaded with a known full-screen pattern.
// Decodes the controller's actual bank/row/column commands, including refresh.
module VideoSdramModel #(parameter real DATA_DELAY=5.4,parameter ALLOW_WRITES=0,
    parameter CHECK_WRITES=1,parameter MEMORY_HALFWORDS=983040,parameter INITIAL_PATTERN=0,
    parameter real RELEASE_DELAY=DATA_DELAY,parameter PATTERN_BASE=0,parameter ROW_WORDS=480,
    parameter real REPEAT_READ_DELAY=DATA_DELAY) (
    input clk,cke,cas_n,ras_n,we_n,
    input [12:0] a,input [1:0] ba,input [1:0] dqm,inout [15:0] dq
);
reg [12:0] rows[0:3];
reg [3:0] opened=0;
reg [3:0] read_pipe=0;
reg [24:0] read_addr[0:3];
reg [3:0] repeat_pipe=0;
reg [24:0] previous_read=25'h1ffffff;
reg drive=0;
reg [15:0] drive_data;
integer j;
integer refreshes=0;
reg [24:0] location;
reg write_pending=0;
reg [24:0] write_location;
reg [15:0] stored[0:(ALLOW_WRITES?MEMORY_HALFWORDS:1)-1];
reg stored_valid[0:(ALLOW_WRITES?MEMORY_HALFWORDS:1)-1];
integer init_index;
initial for(init_index=0;init_index<(ALLOW_WRITES?MEMORY_HALFWORDS:1);init_index=init_index+1)
    stored_valid[init_index]=0;
assign dq=drive ? drive_data : 16'hzzzz;
function [15:0] pattern_half;
    input [24:0] half_addr;
    integer addr,row,col,group_number,k;
    reg [95:0] packed_pixels;
    reg [31:0] word_data;
    begin
        addr=(half_addr>>1)-PATTERN_BASE; row=addr/ROW_WORDS; col=addr%ROW_WORDS; group_number=col/3;
        for(k=0;k<8;k=k+1)
            packed_pixels[k*12 +:12]={4'((group_number*8+k+row)&15),
                                      4'(((group_number*8+k)>>4)&15),4'((row>>3)&15)};
        word_data=packed_pixels[(col%3)*32 +:32];
        pattern_half=half_addr[0] ? word_data[31:16] : word_data[15:0];
    end
endfunction
function [15:0] memory_half;
    input [24:0] half_addr;
    begin
        if(ALLOW_WRITES && half_addr<MEMORY_HALFWORDS && stored_valid[half_addr]) memory_half=stored[half_addr];
        else memory_half=(ALLOW_WRITES && !INITIAL_PATTERN) ? 16'hcafe : pattern_half(half_addr);
    end
endfunction
task capture_half;
    input [24:0] addr;
    reg [15:0] updated;
    begin
        if(addr>=MEMORY_HALFWORDS || dqm!==2'b00 || (CHECK_WRITES && dq!==pattern_half(addr)))
            $fatal(1,"Live SDRAM write mismatch at halfword %0d: data=%h wanted=%h mask=%b",addr,dq,pattern_half(addr),dqm);
        updated=dq; stored[addr]=updated; stored_valid[addr]=1;
    end
endtask
always @(posedge clk) if(cke) begin
    if(write_pending) begin capture_half(write_location^25'd1); write_pending=0; end
    // Ending a burst can release DQ earlier than the next data transition.
    // Use a separate tHZ to exercise the final halfword's hold window.
    if(read_pipe[3]) drive <= #(DATA_DELAY) 1'b1;
    else drive <= #(RELEASE_DELAY) 1'b0;
    if(read_pipe[3]) drive_data <= #(repeat_pipe[3] ? REPEAT_READ_DELAY : DATA_DELAY) memory_half(read_addr[3]);
    for(j=3;j>0;j=j-1) begin
        read_pipe[j]=read_pipe[j-1]; read_addr[j]=read_addr[j-1]; repeat_pipe[j]=repeat_pipe[j-1];
    end
    read_pipe[0]=0;
    repeat_pipe[0]=0;
    case({ras_n,cas_n,we_n})
        3'b000: if(ba!==0 || a!==13'h031) $fatal(1,"Invalid video SDRAM mode");
        3'b011: begin rows[ba]=a; opened[ba]=1; end
        3'b010: if(a[10]) opened=0; else opened[ba]=0;
        3'b001: begin
            if(opened) $fatal(1,"Video refresh with open row");
            refreshes=refreshes+1;
        end
        3'b100: begin
            if(!ALLOW_WRITES || !opened[ba]) $fatal(1,"Unexpected/closed-row video SDRAM write");
            write_location={ba,rows[ba],a[9:0]}; capture_half(write_location); write_pending=1;
        end
        3'b101: begin
            if(!opened[ba]) $fatal(1,"Video read from closed row");
            location={ba,rows[ba],a[9:0]};
            read_pipe[1:0]=2'b11; read_addr[1]=location; read_addr[0]=location^25'd1;
            // A repeated column can return sooner than a preceding access.
            // Exercise the hold window when a drain READ overlaps the last
            // requested halfword, without changing CAS or the burst length.
            repeat_pipe[1:0]={2{location==previous_read}};
            previous_read=location;
        end
    endcase
end
endmodule

// SDHC/SDSC sector transactions over the DOOM SPI byte engine. No CPU or RAM.
module SdCard #(parameter INIT_DIV=188, FAST_DIV=2, POLL_LIMIT=2000000) (
    input clk,reset,initialize,request,write_sector,input [31:0] lba,
    output reg ready,busy,accepted,done,output reg [7:0] error,
    output reg read_valid,output reg [8:0] read_index,output reg [7:0] read_data,
    input read_ready,input write_valid,input [7:0] write_data,output reg write_ready,
    output sd_clk,sd_cmd,sd_cs_n,input sd_miso
);
localparam IDLE=0,POWER=1,POWER_NEXT=2,CMD0=3,CMD0_END=4,CMD8=5,CMD8_END=6,
    R7=7,R7_BYTE=8,CMD55=9,CMD55_END=10,ACMD41=11,ACMD41_END=12,
    OCR=13,OCR_END=14,OCR_BYTES=15,OCR_BYTE=16,CMD16=17,CMD16_END=18,
    INIT_END=19,DESELECT=20,SELECT=21,COMMAND=22,COMMAND_NEXT=23,
    RESPONSE=24,RESPONSE_NEXT=25,BLOCK=26,BLOCK_END=27,READ_TOKEN=28,
    READ_TOKEN_NEXT=29,READ_BYTES=30,READ_BYTE=31,CRC1=32,CRC2=33,
    CLOSE=34,COMPLETE=35,WRITE_TOKEN=36,WRITE_BYTES=37,WRITE_BYTE=38,
    WRITE_CRC1=39,WRITE_CRC2=40,WRITE_RESPONSE=41,WRITE_RESPONSE_NEXT=42,
    WRITE_BUSY=43,WRITE_BUSY_NEXT=44,TRANSFER=200;
reg [7:0] state,return_state,command_return,rx_byte,response;
reg [47:0] command_packet;
reg [2:0] command_index;
reg [1:0] extra_index;
reg [31:0] extra_data,block_lba;
reg [20:0] polls;
reg [13:0] attempts;
reg [5:0] reset_attempts;
reg [8:0] position,power_bytes;
reg version2,block_addressed,job_write,cs_n,spi_start,transfer_seen;
reg [15:0] divider;
reg [7:0] spi_tx;
wire [7:0] spi_rx;
wire spi_busy,spi_done;
sd_spi spi (.clk(clk),.reset_n(!reset),.cs_n(cs_n),.clk_div(divider),
    .start(spi_start),.tx_data(spi_tx),.rx_data(spi_rx),.busy(spi_busy),
    .done(spi_done),.spi_cs_n(sd_cs_n),.spi_clk(sd_clk),.spi_mosi(sd_cmd),.spi_miso(sd_miso));
task byte_transfer;
    input [7:0] value,next_state;
    begin spi_tx<=value; spi_start<=1; transfer_seen<=0; return_state<=next_state; state<=TRANSFER; end
endtask
task command;
    input [5:0] index; input [31:0] argument; input [7:0] crc,next_state;
    begin command_packet<={2'b01,index,argument,crc}; command_index<=0;
        command_return<=next_state; polls<=0; state<=DESELECT; end
endtask
task fail;
    input [7:0] code;
    begin error<=code; cs_n<=1; busy<=0; done<=1; state<=IDLE; end
endtask
always @(posedge clk or posedge reset) begin
    if(reset) begin
        state<=IDLE; ready<=0; busy<=0; accepted<=0; done<=0; error<=0;
        read_valid<=0; read_index<=0; read_data<=0; write_ready<=0;
        cs_n<=1; spi_start<=0; spi_tx<=8'hff; divider<=INIT_DIV;
        return_state<=0; command_return<=0; rx_byte<=0; response<=0;
        command_packet<=0; command_index<=0; extra_index<=0; extra_data<=0;
        block_lba<=0; polls<=0; attempts<=0; reset_attempts<=0;
        position<=0; power_bytes<=0; version2<=0; block_addressed<=0;
        job_write<=0; transfer_seen<=0;
    end else begin
        spi_start<=0; accepted<=0; done<=0; read_valid<=0; write_ready<=0;
        case(state)
            IDLE: if(initialize) begin
                ready<=0; busy<=1; error<=0; divider<=INIT_DIV; cs_n<=1;
                power_bytes<=0; attempts<=0; reset_attempts<=0;
                version2<=0; block_addressed<=0; state<=POWER;
            end else if(request && ready) begin
                accepted<=1; busy<=1; error<=0; job_write<=write_sector;
                block_lba<=lba; position<=0; state<=BLOCK;
            end
            TRANSFER: begin
                if(spi_busy) transfer_seen<=1;
                if(transfer_seen && spi_done && !spi_busy) begin rx_byte<=spi_rx; state<=return_state; end
            end
            POWER: byte_transfer(8'hff,POWER_NEXT);
            POWER_NEXT: if(power_bytes==255) state<=CMD0;
                else begin power_bytes<=power_bytes+1'b1; state<=POWER; end
            CMD0: command(0,0,8'h95,CMD0_END);
            CMD0_END: if(response==1) state<=CMD8;
                else if(reset_attempts==31) fail(8'h01);
                else begin reset_attempts<=reset_attempts+1'b1; state<=CMD0; end
            CMD8: command(8,32'h1aa,8'h87,CMD8_END);
            CMD8_END: if(response==1) begin version2<=1; extra_index<=0; extra_data<=0; state<=R7; end
                else if(response[2]) state<=CMD55; else fail(8'h02);
            R7: byte_transfer(8'hff,R7_BYTE);
            R7_BYTE: begin
                extra_data<={extra_data[23:0],rx_byte};
                if(extra_index==3) begin
                    if(extra_data[7:0]!=1 || rx_byte!=8'haa) fail(8'h02); else state<=CMD55;
                end else begin extra_index<=extra_index+1'b1; state<=R7; end
            end
            CMD55: command(55,0,8'h01,CMD55_END);
            CMD55_END: if(response<=1) state<=ACMD41; else fail(8'h03);
            ACMD41: command(41,version2 ? 32'h40000000 : 32'd0,8'h01,ACMD41_END);
            ACMD41_END: if(response==0) state<=OCR;
                else if(response!=1 || attempts==9999) fail(8'h03);
                else begin attempts<=attempts+1'b1; state<=CMD55; end
            OCR: command(58,0,8'h01,OCR_END);
            OCR_END: if(response==0) begin extra_index<=0; extra_data<=0; state<=OCR_BYTES; end else fail(8'h04);
            OCR_BYTES: byte_transfer(8'hff,OCR_BYTE);
            OCR_BYTE: begin
                extra_data<={extra_data[23:0],rx_byte};
                if(extra_index==3) begin
                    block_addressed<=version2 && extra_data[22];
                    state<=version2 && extra_data[22] ? INIT_END : CMD16;
                end else begin extra_index<=extra_index+1'b1; state<=OCR_BYTES; end
            end
            CMD16: command(16,512,8'h01,CMD16_END);
            CMD16_END: if(response==0) state<=INIT_END; else fail(8'h04);
            INIT_END: begin divider<=FAST_DIV; ready<=1; state<=CLOSE; end
            DESELECT: begin cs_n<=1; byte_transfer(8'hff,SELECT); end
            SELECT: begin cs_n<=0; byte_transfer(8'hff,COMMAND); end
            COMMAND: byte_transfer(command_packet[47:40],COMMAND_NEXT);
            COMMAND_NEXT: begin
                command_packet<={command_packet[39:0],8'hff};
                if(command_index==5) begin polls<=0; state<=RESPONSE; end
                else begin command_index<=command_index+1'b1; state<=COMMAND; end
            end
            RESPONSE: byte_transfer(8'hff,RESPONSE_NEXT);
            RESPONSE_NEXT: if(!rx_byte[7]) begin response<=rx_byte; state<=command_return; end
                else if(polls==15) begin
                    // CMD0 may be ignored while a powered card wakes up.
                    if(command_return==CMD0_END) begin response<=8'hff; state<=CMD0_END; end
                    else fail(8'h05);
                end else begin polls<=polls+1'b1; state<=RESPONSE; end
            BLOCK: command(job_write ? 24 : 17,block_addressed ? block_lba : block_lba<<9,8'h01,BLOCK_END);
            BLOCK_END: if(response!=0) fail(8'h06);
                else begin polls<=0; state<=job_write ? WRITE_TOKEN : READ_TOKEN; end
            READ_TOKEN: byte_transfer(8'hff,READ_TOKEN_NEXT);
            READ_TOKEN_NEXT: if(rx_byte==8'hfe) state<=READ_BYTES;
                else if(rx_byte!=8'hff || polls==POLL_LIMIT-1) fail(8'h07);
                else begin polls<=polls+1'b1; state<=READ_TOKEN; end
            READ_BYTES: if(read_ready) byte_transfer(8'hff,READ_BYTE);
            READ_BYTE: begin
                read_valid<=1; read_index<=position; read_data<=rx_byte;
                if(position==511) state<=CRC1;
                else begin position<=position+1'b1; state<=READ_BYTES; end
            end
            CRC1: byte_transfer(8'hff,CRC2);
            CRC2: byte_transfer(8'hff,CLOSE);
            WRITE_TOKEN: byte_transfer(8'hfe,WRITE_BYTES);
            WRITE_BYTES: if(write_valid) begin write_ready<=1; byte_transfer(write_data,WRITE_BYTE); end
            WRITE_BYTE: if(position==511) state<=WRITE_CRC1;
                else begin position<=position+1'b1; state<=WRITE_BYTES; end
            WRITE_CRC1: byte_transfer(8'hff,WRITE_CRC2);
            WRITE_CRC2: begin polls<=0; byte_transfer(8'hff,WRITE_RESPONSE); end
            WRITE_RESPONSE: byte_transfer(8'hff,WRITE_RESPONSE_NEXT);
            WRITE_RESPONSE_NEXT: if((rx_byte&8'h1f)==5) begin polls<=0; state<=WRITE_BUSY; end
                else if(rx_byte!=8'hff || polls==POLL_LIMIT-1) fail(8'h08);
                else begin polls<=polls+1'b1; state<=WRITE_RESPONSE; end
            WRITE_BUSY: byte_transfer(8'hff,WRITE_BUSY_NEXT);
            WRITE_BUSY_NEXT: if(rx_byte==8'hff) state<=CLOSE;
                else if(polls==POLL_LIMIT-1) fail(8'h09);
                else begin polls<=polls+1'b1; state<=WRITE_BUSY; end
            CLOSE: begin cs_n<=1; byte_transfer(8'hff,COMPLETE); end
            COMPLETE: begin busy<=0; done<=1; state<=IDLE; end
            default: fail(8'hff);
        endcase
    end
end
endmodule

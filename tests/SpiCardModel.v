`timescale 1ns/1ps
// Card at the physical SPI pins: commands, initialization, sectors, busy,
// SDSC byte addressing, and rejected writes. Storage is bounded in this model.
module SpiCardModel #(parameter SDSC=0, SECTORS=2048, IGNORE_FIRST_CMD0=1) (
    input cs_n,sclk,mosi,reject_write,output reg miso=1
);
reg [7:0] memory[0:SECTORS*512-1];
reg [7:0] queue[0:1023];
integer head=0,tail=0,command_bytes=0,write_mode=0,position=0,crc_bytes=0;
integer resets=0,acmds=0,reads=0,writes=0,block_address=0,i;
reg initialized=0;
reg [47:0] packet=0;
reg [7:0] incoming=0,outgoing=8'hff,next_byte=8'hff;
reg [2:0] bit_count=0;
task enqueue;
    input [7:0] value;
    begin queue[tail]=value;tail=tail+1;end
endtask
task received;
    input [7:0] value;
    integer cmd,address;
    reg [31:0] argument;
    begin
        next_byte=head<tail ? queue[head] : 8'hff;
        if(head<tail) head=head+1;
        if(write_mode==1) begin
            if(value==8'hfe) begin write_mode=2;position=0;end
        end else if(write_mode==2) begin
            memory[block_address*512+position]=value;
            if(position==511) begin write_mode=3;crc_bytes=0;end else position=position+1;
        end else if(write_mode==3) begin
            if(crc_bytes==1) begin
                write_mode=0;writes=writes+1;enqueue(reject_write ? 8'h0b : 8'h05);
                enqueue(0);enqueue(0);enqueue(0);enqueue(8'hff);
            end else crc_bytes=crc_bytes+1;
        end else if(command_bytes!=0 || value[7:6]==2'b01) begin
            packet={packet[39:0],value};command_bytes=command_bytes+1;
            if(command_bytes==6) begin
                command_bytes=0;cmd=packet[45:40];argument=packet[39:8];
                case(cmd)
                    0: begin resets=resets+1;initialized=0;
                        if(packet[7:0]!=8'h95) $fatal(1,"CMD0 CRC");
                        if(!IGNORE_FIRST_CMD0 || resets!=1) enqueue(1);end
                    8: begin if(packet[7:0]!=8'h87 || argument!=32'h1aa) $fatal(1,"CMD8");
                        enqueue(1);enqueue(0);enqueue(0);enqueue(1);enqueue(8'haa);end
                    55: enqueue(initialized ? 0 : 1);
                    41: begin acmds=acmds+1;if(acmds>=3) initialized=1;enqueue(initialized ? 0 : 1);end
                    58: begin enqueue(0);enqueue(SDSC ? 8'h80 : 8'hc0);enqueue(8'hff);enqueue(8'h80);enqueue(0);end
                    16: begin if(argument!=512) $fatal(1,"SDSC block length");enqueue(0);end
                    17,24: begin
                        if(!initialized) $fatal(1,"Transfer before init");
                        if(SDSC && argument[8:0]!=0) $fatal(1,"Incorrect byte addressing");
                        address=SDSC ? argument>>9 : argument;
                        if(address>=SECTORS) $fatal(1,"Model sector outside range: %0d",address);
                        enqueue(0);
                        if(cmd==17) begin
                            reads=reads+1;enqueue(8'hfe);for(i=0;i<512;i=i+1) enqueue(memory[address*512+i]);enqueue(8'hff);enqueue(8'hff);
                        end else begin block_address=address;write_mode=1;end
                    end
                    default:$fatal(1,"Unexpected SD command %0d",cmd);
                endcase
            end
        end
    end
endtask
always @(posedge cs_n) begin head=0;tail=0;command_bytes=0;write_mode=0;bit_count=0;incoming=0;outgoing=8'hff;next_byte=8'hff;miso=1;end
always @(negedge cs_n) begin bit_count=0;incoming=0;outgoing=8'hff;next_byte=8'hff;miso=1;end
always @(posedge sclk) if(!cs_n) begin
    incoming={incoming[6:0],mosi};
    if(bit_count==7) begin bit_count=0;received(incoming);end else bit_count=bit_count+1'b1;
end
always @(negedge sclk) if(!cs_n) begin
    if(bit_count==0) begin outgoing=next_byte;miso=outgoing[7];end
    else begin outgoing={outgoing[6:0],1'b1};miso=outgoing[7];end
end
endmodule

// Create a new root-directory BMP on FAT16/FAT32. The image is streamed into
// free contiguous clusters, then FAT links and the directory are committed.
// A cancelled data transfer leaves the clusters free and existing files intact.
module FatScreenshot (
    input clk,reset,start,cancel,input [31:0] file_size,
    output reg busy,done,output reg [7:0] error,output reg [15:0] file_number,
    output allocation_ready,input begin_payload,
    output reg payload_start,input payload_valid,input [7:0] payload_data,output payload_ready,
    output sd_clk,sd_cmd,sd_cs_n,input sd_miso
);
localparam IDLE=0,INIT=1,INIT_WAIT=2,BOOT=3,PARSE=4,LAYOUT=5,TYPE=6,
    ROOT=7,DIR_READ=8,DIR_LOAD=9,DIR_CHECK=10,DIR_NEXT=11,ROOT_NEXT=12,
    LOOKUP_LOAD=13,LOOKUP_DONE=14,FREE_BEGIN=15,FREE_READ=16,FREE_LOAD=17,
    FREE_CHECK=18,DATA_BEGIN=19,DATA_WRITE=20,DATA_NEXT=21,ZERO_ROOT=22,
    ZERO_NEXT=23,FAT_BEGIN=24,FAT_READ=25,FAT_PATCH=26,FAT_WRITE=27,FAT_NEXT=28,
    DIRECTORY_READ=29,DIRECTORY_PATCH=30,DIRECTORY_WRITE=31,DIRECTORY_DONE=32,
    INFO_READ=33,INFO_PATCH=34,INFO_WRITE=35,INFO_DONE=36,SUCCESS=37,
    INFO_CLEAR=38,DIRECTORY_END_MARK=39,DIR_CAPTURE=40,LOOKUP_CAPTURE=41,
    FREE_CAPTURE=42,FAT_APPLY=43,
    IO_ACCEPT=100,IO_WAIT=101;
reg [7:0] state,io_return,lookup_return,write_kind;
(* ramstyle="MLAB, no_rw_check" *) reg [7:0] sector[0:511];
// One registered read port and one write port fit in distributed memory.
// Read/modify/write states prime the read before consuming it. SPI sector
// writes leave many clocks between byte requests, so their read is ready.
reg [8:0] sector_read_address,sector_write_address;
reg [7:0] sector_write_data,directory_byte;
reg sector_write_enable;
reg [7:0] sector_byte;
// Capture the few fixed-offset fields as the card streams a boot/FSInfo
// sector. This avoids parallel read ports on the shared sector cache.
reg [327:0] bpb_bytes;
reg [15:0] bpb_signature;
reg [31:0] bpb_partition,info_lead,info_struct,info_trailer;
wire [7:0] bpb_spc=bpb_bytes[(13-11)*8 +:8];
wire [7:0] bpb_fats=bpb_bytes[(16-11)*8 +:8];
wire [7:0] bpb_flags=bpb_bytes[(40-11)*8 +:8];
reg [255:0] entry;
reg [4:0] entry_byte;
reg [3:0] entry_index;
reg [8:0] patch_index,write_index;
reg [31:0] partition,reserved,fat_sectors,total_sectors,root_sectors;
reg [31:0] fat_start,root_start,data_start,cluster_count,last_cluster;
reg [31:0] root_cluster,current_root,root_last,dir_lba,empty_lba;
reg [31:0] root_visits;
reg [8:0] empty_offset;
reg [7:0] sectors_per_cluster,root_sector_index;
reg [3:0] cluster_shift;
reg [1:0] fat_count,copy_index;
reg fat32,active_only,active_fat,partition_read,empty_found,empty_end,root_extend,root_only;
reg [15:0] maximum_name,info_sector,backup_sector;
reg [31:0] image_bytes,image_sectors,file_clusters,needed_clusters;
reg [31:0] scan_sector,scan_cluster,free_count,free_first,first_cluster,new_root;
reg [31:0] data_sector_index,root_zero_index,fat_sector_index,fat_sector_end;
reg [31:0] lookup_cluster,entry_value,info_lba;
reg [1:0] lookup_byte;
reg [8:0] lookup_offset;
reg info_backup,cancel_pending,metadata_started;
reg card_init,card_request,card_write;
assign allocation_ready=state==DATA_BEGIN;
reg [31:0] card_lba;
wire card_ready,card_busy,card_accepted,card_done,read_valid,write_ready;
wire [8:0] read_index;
wire [7:0] read_data,card_error;
wire [7:0] card_data=write_kind==0 ? (cancel_pending ? 8'd0 : payload_data) :
    write_kind==2 ? 8'd0 : sector_byte;
assign payload_ready=write_ready && write_kind==0 && !cancel_pending;
SdCard card (.clk(clk),.reset(reset),.initialize(card_init),.request(card_request),
    .write_sector(card_write),.lba(card_lba),.ready(card_ready),.busy(card_busy),
    .accepted(card_accepted),.done(card_done),.error(card_error),
    .read_valid(read_valid),.read_index(read_index),.read_data(read_data),.read_ready(1'b1),
    .write_valid(write_kind!=0 || payload_valid || cancel_pending),.write_data(card_data),
    .write_ready(write_ready),.sd_clk(sd_clk),.sd_cmd(sd_cmd),.sd_cs_n(sd_cs_n),.sd_miso(sd_miso));
function [15:0] le16;
    input integer offset;
    begin case(offset)
        11:le16=bpb_bytes[(11-11)*8 +:16];14:le16=bpb_bytes[(14-11)*8 +:16];
        17:le16=bpb_bytes[(17-11)*8 +:16];19:le16=bpb_bytes[(19-11)*8 +:16];
        22:le16=bpb_bytes[(22-11)*8 +:16];42:le16=bpb_bytes[(42-11)*8 +:16];
        48:le16=bpb_bytes[(48-11)*8 +:16];50:le16=bpb_bytes[(50-11)*8 +:16];
        510:le16=bpb_signature;
        default:le16=0;
    endcase end
endfunction
function [31:0] le32;
    input integer offset;
    begin case(offset)
        0:le32=info_lead;32:le32=bpb_bytes[(32-11)*8 +:32];
        36:le32=bpb_bytes[(36-11)*8 +:32];44:le32=bpb_bytes[(44-11)*8 +:32];
        454:le32=bpb_partition;
        484:le32=info_struct;508:le32=info_trailer;
        default:le32=0;
    endcase end
endfunction
function [3:0] spc_shift;
    input [7:0] value;
    begin case(value) 1:spc_shift=0;2:spc_shift=1;4:spc_shift=2;8:spc_shift=3;
        16:spc_shift=4;32:spc_shift=5;64:spc_shift=6;128:spc_shift=7;default:spc_shift=15;endcase end
endfunction
function [15:0] next_name;
    input [15:0] value;
    begin next_name=value+1;
        if(value[3:0]==9) begin next_name[3:0]=0; next_name[7:4]=value[7:4]+1;
            if(value[7:4]==9) begin next_name[7:4]=0; next_name[11:8]=value[11:8]+1;
                if(value[11:8]==9) begin next_name[11:8]=0; next_name[15:12]=value[15:12]+1; end
            end
        end
    end
endfunction
wire [15:0] entry_name={entry[4*8 +:4],entry[5*8 +:4],entry[6*8 +:4],entry[7*8 +:4]};
wire name_match=entry[31:0]==32'h43415246 && entry[87:64]==24'h504d42 &&
    entry[39:32]>=8'h30 && entry[39:32]<=8'h39 && entry[47:40]>=8'h30 && entry[47:40]<=8'h39 &&
    entry[55:48]>=8'h30 && entry[55:48]<=8'h39 && entry[63:56]>=8'h30 && entry[63:56]<=8'h39;
wire [31:0] normalized_entry=fat32 ? entry_value&32'h0fffffff : entry_value&32'h0000ffff;
wire end_chain=fat32 ? normalized_entry>=32'h0ffffff8 : normalized_entry>=32'hfff8;
wire [31:0] root_lba=data_start+((current_root-2)<<cluster_shift);
wire [31:0] file_last=first_cluster+file_clusters-1;
wire [31:0] patch_cluster=(fat_sector_index<<(fat32 ? 7 : 8))+(patch_index>>(fat32 ? 2 : 1));
wire patch_file=patch_cluster>=first_cluster && patch_cluster<=file_last;
wire patch_root=root_extend && (patch_cluster==new_root || patch_cluster==root_last);
wire [31:0] end_value=fat32 ? 32'h0fffffff : 32'hffff;
wire [31:0] link_value=patch_cluster==root_last && root_extend ? new_root :
    patch_cluster==file_last || patch_cluster==new_root ? end_value : patch_cluster+1;
wire [4:0] link_shift=fat32 ? {patch_index[1:0],3'd0} : {1'b0,patch_index[0],3'd0};
wire [7:0] link_byte=link_value>>link_shift;
wire [31:0] copy_base=fat_start+(copy_index[0] ? fat_sectors : 32'd0);
wire [32:0] mount_overhead={1'b0,reserved}+(fat_count==2 ? {fat_sectors,1'b0} : {1'b0,fat_sectors})+{1'b0,root_sectors};
wire [32:0] mount_end={1'b0,partition}+{1'b0,total_sectors};
wire [39:0] table_capacity={8'd0,fat_sectors}<<(cluster_count>=65525 ? 7 : 8);
task finish_error;
    input [7:0] code;
    begin busy<=0;done<=1;error<=code;state<=IDLE; end
endtask
task read_sector;
    input [31:0] address;input [7:0] next_state;
    begin card_write<=0;card_lba<=address;card_request<=1;io_return<=next_state;state<=IO_ACCEPT; end
endtask
task write_sector;
    input [31:0] address;input [7:0] kind,next_state;
    begin card_write<=1;write_kind<=kind;write_index<=0;card_lba<=address;
        card_request<=1;io_return<=next_state;state<=IO_ACCEPT;end
endtask
task lookup;
    input [31:0] cluster;input [7:0] next_state;
    begin lookup_cluster<=cluster;lookup_byte<=0;entry_value<=0;lookup_return<=next_state;
        lookup_offset<=fat32 ? {cluster[6:0],2'b00} : {cluster[7:0],1'b0};
        read_sector(fat_start+(active_fat ? fat_sectors : 32'd0)+(cluster>>(fat32 ? 7 : 8)),LOOKUP_LOAD);end
endtask
always @* begin
    sector_read_address=write_index;
    case(state)
        DIR_LOAD,DIR_CAPTURE:sector_read_address={entry_index,5'd0}+entry_byte;
        LOOKUP_LOAD,LOOKUP_CAPTURE,FREE_LOAD,FREE_CAPTURE:sector_read_address=lookup_offset+lookup_byte;
        FAT_PATCH,FAT_APPLY:sector_read_address=patch_index;
        default:;
    endcase
    directory_byte=0;
    case(patch_index)
        0:directory_byte=8'h46;1:directory_byte=8'h52;2:directory_byte=8'h41;3:directory_byte=8'h43;
        4:directory_byte={4'h3,file_number[15:12]};5:directory_byte={4'h3,file_number[11:8]};
        6:directory_byte={4'h3,file_number[7:4]};7:directory_byte={4'h3,file_number[3:0]};
        8:directory_byte=8'h42;9:directory_byte=8'h4d;10:directory_byte=8'h50;11:directory_byte=8'h20;
        16,18,24:directory_byte=8'h21; // valid 1980-01-01 date
        20:directory_byte=fat32 ? first_cluster[23:16] : 8'd0;
        21:directory_byte=fat32 ? first_cluster[31:24] : 8'd0;
        26:directory_byte=first_cluster[7:0];27:directory_byte=first_cluster[15:8];
        28:directory_byte=image_bytes[7:0];29:directory_byte=image_bytes[15:8];
        30:directory_byte=image_bytes[23:16];31:directory_byte=image_bytes[31:24];
        default:;
    endcase
    sector_write_enable=0;sector_write_address=read_index;sector_write_data=read_data;
    if(read_valid) sector_write_enable=1;
    else case(state)
        FAT_APPLY:if(patch_file || patch_root) begin
            sector_write_enable=1;sector_write_address=patch_index;
            sector_write_data=fat32 && patch_index[1:0]==3 ? {sector_byte[7:4],link_byte[3:0]} : link_byte;
        end
        DIRECTORY_PATCH:begin
            sector_write_enable=1;sector_write_address=empty_offset+patch_index;sector_write_data=directory_byte;
        end
        DIRECTORY_END_MARK:begin
            sector_write_enable=1;sector_write_address=empty_offset+9'd32;sector_write_data=0;
        end
        INFO_CLEAR:begin
            sector_write_enable=1;sector_write_address=9'd488+patch_index[2:0];sector_write_data=8'hff;
        end
        default:;
    endcase
end
always @(posedge clk) begin
    if(sector_write_enable && !reset) sector[sector_write_address]<=sector_write_data;
    sector_byte<=sector[sector_read_address];
end
always @(posedge clk or posedge reset) begin
    if(reset) begin
        state<=IDLE;busy<=0;done<=0;error<=0;file_number<=0;payload_start<=0;
        card_init<=0;card_request<=0;card_write<=0;card_lba<=0;write_kind<=1;write_index<=0;
        io_return<=0;lookup_return<=0;entry<=0;entry_byte<=0;entry_index<=0;patch_index<=0;
        partition<=0;reserved<=0;fat_sectors<=0;total_sectors<=0;root_sectors<=0;
        fat_start<=0;root_start<=0;data_start<=0;cluster_count<=0;last_cluster<=0;
        root_cluster<=0;current_root<=0;root_last<=0;dir_lba<=0;empty_lba<=0;empty_offset<=0;
        root_visits<=0;
        sectors_per_cluster<=1;root_sector_index<=0;cluster_shift<=0;fat_count<=0;copy_index<=0;
        fat32<=0;active_only<=0;active_fat<=0;partition_read<=0;empty_found<=0;empty_end<=0;
        root_extend<=0;root_only<=0;maximum_name<=16'hffff;info_sector<=0;backup_sector<=0;
        image_bytes<=0;image_sectors<=0;file_clusters<=0;needed_clusters<=0;
        scan_sector<=0;scan_cluster<=0;free_count<=0;free_first<=0;first_cluster<=0;new_root<=0;
        data_sector_index<=0;root_zero_index<=0;fat_sector_index<=0;fat_sector_end<=0;
        lookup_cluster<=0;entry_value<=0;lookup_byte<=0;lookup_offset<=0;
        info_backup<=0;info_lba<=0;cancel_pending<=0;metadata_started<=0;
        bpb_bytes<=0;bpb_signature<=0;bpb_partition<=0;info_lead<=0;info_struct<=0;info_trailer<=0;
    end else begin
        done<=0;payload_start<=0;card_init<=0;card_request<=0;
        if(read_valid) begin
            if(io_return==PARSE) begin
                if(read_index>=11 && read_index<=51) bpb_bytes[(read_index-11)*8 +:8]<=read_data;
                if(read_index>=454 && read_index<=457) bpb_partition[(read_index-454)*8 +:8]<=read_data;
                if(read_index>=510) bpb_signature[read_index[0]*8 +:8]<=read_data;
            end
            if(io_return==INFO_PATCH) begin
                if(read_index<4) info_lead[read_index[1:0]*8 +:8]<=read_data;
                if(read_index>=484 && read_index<=487) info_struct[read_index[1:0]*8 +:8]<=read_data;
                if(read_index>=508) info_trailer[read_index[1:0]*8 +:8]<=read_data;
            end
        end
        if(write_ready) write_index<=write_index+1'b1;
        if(cancel && busy && !metadata_started) cancel_pending<=1;
        case(state)
            IDLE: if(start) begin
                busy<=1;error<=0;partition<=0;partition_read<=0;empty_found<=0;empty_end<=0;
                root_extend<=0;root_only<=0;maximum_name<=16'hffff;image_bytes<=file_size;
                image_sectors<=({1'b0,file_size}+33'd511)>>9;cancel_pending<=0;metadata_started<=0;root_visits<=1;
                if(file_size==0) finish_error(8'h11);else state<=INIT;
            end
            INIT: begin card_init<=1;state<=INIT_WAIT;end
            INIT_WAIT: if(card_done) begin if(cancel_pending) finish_error(8'h40);
                else if(card_error!=0 || !card_ready) finish_error(card_error|8'h80);else state<=BOOT;end
            IO_ACCEPT: if(card_accepted) state<=IO_WAIT;
            IO_WAIT: if(card_done) begin if(cancel_pending && !metadata_started) finish_error(8'h40);
                else if(card_error!=0) finish_error(card_error|8'h80);else state<=io_return;end
            BOOT: read_sector(partition,PARSE);
            PARSE: if(le16(510)!=16'haa55) finish_error(8'h10);
                else if(le16(11)!=512 || spc_shift(bpb_spc)==15) begin
                    if(partition_read || le32(454)==0) finish_error(8'h10);
                    else begin partition<=le32(454);partition_read<=1;state<=BOOT;end
                end else if(le16(14)==0 || (bpb_fats!=1 && bpb_fats!=2) ||
                    (le16(22)!=0 && (le16(17)==0 || (le16(17)&15)!=0)) ||
                    (le16(22)==0 && (le16(17)!=0 || le16(42)!=0 ||
                        (bpb_flags[7] && (bpb_flags&15)>=bpb_fats)))) finish_error(8'h11);
                else begin
                    reserved<=le16(14);fat_count<=bpb_fats;sectors_per_cluster<=bpb_spc;cluster_shift<=spc_shift(bpb_spc);
                    fat_sectors<=le16(22)!=0 ? {16'd0,le16(22)} : le32(36);
                    total_sectors<=le16(19)!=0 ? {16'd0,le16(19)} : le32(32);
                    root_sectors<=({16'd0,le16(17)}+15)>>4;
                    root_cluster<=le32(44)&32'h0fffffff;
                    active_only<=le16(22)==0 && bpb_flags[7];active_fat<=le16(22)==0 && bpb_flags[7] && bpb_flags[0];
                    info_sector<=le16(48);backup_sector<=le16(50);state<=LAYOUT;
                end
            LAYOUT: begin
                fat_start<=partition+reserved;
                root_start<=partition+reserved+(fat_count==2 ? fat_sectors<<1 : fat_sectors);
                data_start<=partition+reserved+(fat_count==2 ? fat_sectors<<1 : fat_sectors)+root_sectors;
                cluster_count<=(total_sectors-reserved-(fat_count==2 ? fat_sectors<<1 : fat_sectors)-root_sectors)>>cluster_shift;
                file_clusters<=(image_sectors+sectors_per_cluster-1)>>cluster_shift;state<=TYPE;
            end
            TYPE: if(fat_sectors==0 || {1'b0,total_sectors}<=mount_overhead || mount_end[32] ||
                    cluster_count<4085 || cluster_count>=32'h0ffffff5 ||
                    table_capacity<{8'd0,cluster_count}+40'd2 ||
                    (cluster_count>=65525)!=(le16(22)==0))
                    finish_error(8'h11);
                else begin fat32<=cluster_count>=65525;last_cluster<=cluster_count+1;current_root<=root_cluster;root_last<=root_cluster;
                    if(cluster_count>=65525 && (root_cluster<2 || root_cluster>cluster_count+1)) finish_error(8'h11);
                    else state<=ROOT;end
            ROOT: begin entry_byte<=0;entry_index<=0;root_sector_index<=0;dir_lba<=fat32 ? root_lba : root_start;state<=DIR_READ;end
            DIR_READ: read_sector(dir_lba,DIR_LOAD);
            DIR_LOAD:state<=DIR_CAPTURE;
            DIR_CAPTURE:begin entry[entry_byte*8 +:8]<=sector_byte;
                if(entry_byte==31) begin entry_byte<=0;state<=DIR_CHECK;end
                else begin entry_byte<=entry_byte+1'b1;state<=DIR_LOAD;end end
            DIR_CHECK: begin
                if((entry[7:0]==0 || entry[7:0]==8'he5) && !empty_found) begin
                    empty_found<=1;empty_end<=entry[7:0]==0;empty_lba<=dir_lba;empty_offset<={entry_index,5'd0};end
                if(entry[7:0]==0) state<=FREE_BEGIN;
                else begin
                    if(entry[7:0]!=8'he5 && entry[95:88]!=8'h0f && name_match &&
                        (maximum_name==16'hffff || entry_name>maximum_name)) maximum_name<=entry_name;
                    state<=DIR_NEXT;
                end
            end
            DIR_NEXT: if(entry_index!=15) begin entry_index<=entry_index+1'b1;state<=DIR_LOAD;end
                else begin entry_index<=0;
                    if(!fat32) begin
                        if(dir_lba-root_start+1==root_sectors) state<=FREE_BEGIN;
                        else begin dir_lba<=dir_lba+1'b1;state<=DIR_READ;end
                    end else if(root_sector_index+1<sectors_per_cluster) begin
                        root_sector_index<=root_sector_index+1'b1;dir_lba<=dir_lba+1'b1;state<=DIR_READ;
                    end else lookup(current_root,ROOT_NEXT);
                end
            ROOT_NEXT: if(end_chain) begin root_extend<=!empty_found;root_last<=current_root;state<=FREE_BEGIN;end
                else if(normalized_entry<2 || normalized_entry>last_cluster || normalized_entry==current_root || root_visits>=cluster_count) finish_error(8'h12);
                else begin current_root<=normalized_entry;root_last<=normalized_entry;root_sector_index<=0;
                    root_visits<=root_visits+1'b1;
                    dir_lba<=data_start+((normalized_entry-2)<<cluster_shift);state<=DIR_READ;end
            LOOKUP_LOAD:state<=LOOKUP_CAPTURE;
            LOOKUP_CAPTURE:begin entry_value[lookup_byte*8 +:8]<=sector_byte;
                if(lookup_byte==(fat32 ? 3 : 1)) state<=LOOKUP_DONE;
                else begin lookup_byte<=lookup_byte+1'b1;state<=LOOKUP_LOAD;end end
            LOOKUP_DONE: state<=lookup_return;
            FREE_BEGIN: if(cancel_pending) finish_error(8'h40);
                else if(maximum_name==16'h9999) finish_error(8'h13);
                else if(!empty_found && !fat32) finish_error(8'h14);
                else begin
                    file_number<=maximum_name==16'hffff ? 16'd0 : next_name(maximum_name);
                    needed_clusters<=file_clusters+(root_extend ? 1 : 0);scan_sector<=0;scan_cluster<=0;
                    free_count<=0;free_first<=0;lookup_offset<=0;lookup_byte<=0;entry_value<=0;state<=FREE_READ;
                end
            FREE_READ: read_sector(fat_start+(active_fat ? fat_sectors : 32'd0)+scan_sector,FREE_LOAD);
            FREE_LOAD:state<=FREE_CAPTURE;
            FREE_CAPTURE:begin entry_value[lookup_byte*8 +:8]<=sector_byte;
                if(lookup_byte==(fat32 ? 3 : 1)) begin lookup_byte<=0;state<=FREE_CHECK;end
                else begin lookup_byte<=lookup_byte+1'b1;state<=FREE_LOAD;end end
            FREE_CHECK: if(cancel_pending) finish_error(8'h40);
                else if(scan_cluster>last_cluster) finish_error(8'h15);
                else if(scan_cluster>=2 && normalized_entry==0 && free_count+1>=needed_clusters) begin
                    first_cluster<=free_count==0 ? scan_cluster : free_first;
                    new_root<=(free_count==0 ? scan_cluster : free_first)+file_clusters;state<=DATA_BEGIN;
                end else if(scan_cluster==last_cluster) finish_error(8'h15);
                else begin
                    if(scan_cluster>=2 && normalized_entry==0) begin
                        if(free_count==0) free_first<=scan_cluster;free_count<=free_count+1'b1;end else free_count<=0;
                    scan_cluster<=scan_cluster+1'b1;entry_value<=0;
                    if(lookup_offset==(fat32 ? 508 : 510)) begin lookup_offset<=0;scan_sector<=scan_sector+1'b1;state<=FREE_READ;end
                    else begin lookup_offset<=lookup_offset+(fat32 ? 4 : 2);state<=FREE_LOAD;end
                end
            DATA_BEGIN: if(cancel_pending) finish_error(8'h40);else if(begin_payload) begin data_sector_index<=0;payload_start<=1;
                if(root_extend) begin empty_lba<=data_start+((new_root-2)<<cluster_shift);empty_offset<=0;empty_end<=1;end
                state<=DATA_WRITE;end
            DATA_WRITE: write_sector(data_start+((first_cluster-2)<<cluster_shift)+data_sector_index,0,DATA_NEXT);
            DATA_NEXT: if(cancel_pending) finish_error(8'h40);
                else if(data_sector_index+1==image_sectors) begin root_zero_index<=0;state<=root_extend ? ZERO_ROOT : FAT_BEGIN;end
                else begin data_sector_index<=data_sector_index+1'b1;state<=DATA_WRITE;end
            ZERO_ROOT: write_sector(data_start+((new_root-2)<<cluster_shift)+root_zero_index,2,ZERO_NEXT);
            ZERO_NEXT: if(cancel_pending) finish_error(8'h40);
                else if(root_zero_index+1==sectors_per_cluster) state<=FAT_BEGIN;
                else begin root_zero_index<=root_zero_index+1'b1;state<=ZERO_ROOT;end
            FAT_BEGIN: if(cancel_pending || cancel) finish_error(8'h40);else begin metadata_started<=1;fat_sector_index<=first_cluster>>(fat32 ? 7 : 8);
                fat_sector_end<=(root_extend ? new_root : file_last)>>(fat32 ? 7 : 8);
                copy_index<=active_only ? {1'b0,active_fat} : 0;root_only<=0;state<=FAT_READ;end
            FAT_READ: begin patch_index<=0;read_sector(copy_base+fat_sector_index,FAT_PATCH);end
            FAT_PATCH:state<=FAT_APPLY;
            FAT_APPLY:if(patch_index==511) state<=FAT_WRITE;
                else begin patch_index<=patch_index+1'b1;state<=FAT_PATCH;end
            FAT_WRITE: write_sector(copy_base+fat_sector_index,1,FAT_NEXT);
            FAT_NEXT: if(!active_only && copy_index+1<fat_count) begin copy_index<=copy_index+1'b1;state<=FAT_READ;end
                else begin copy_index<=active_only ? {1'b0,active_fat} : 0;
                    if(root_only) state<=DIRECTORY_READ;
                    else if(fat_sector_index<fat_sector_end) begin fat_sector_index<=fat_sector_index+1'b1;state<=FAT_READ;end
                    else if(root_extend && ((root_last>>(fat32 ? 7 : 8))<(first_cluster>>(fat32 ? 7 : 8)) ||
                            (root_last>>(fat32 ? 7 : 8))>fat_sector_end)) begin
                        root_only<=1;fat_sector_index<=root_last>>(fat32 ? 7 : 8);state<=FAT_READ;end
                    else state<=DIRECTORY_READ;
                end
            DIRECTORY_READ: begin patch_index<=0;read_sector(empty_lba,DIRECTORY_PATCH);end
            DIRECTORY_PATCH: begin
                if(patch_index==31) begin
                    state<=empty_end && empty_offset<480 ? DIRECTORY_END_MARK : DIRECTORY_WRITE;
                end else patch_index<=patch_index+1'b1;
            end
            DIRECTORY_END_MARK:state<=DIRECTORY_WRITE;
            DIRECTORY_WRITE: write_sector(empty_lba,1,DIRECTORY_DONE);
            DIRECTORY_DONE: if(fat32 && info_sector!=0 && info_sector!=16'hffff && info_sector<reserved) begin
                info_backup<=0;info_lba<=partition+info_sector;state<=INFO_READ;
                end else state<=SUCCESS;
            INFO_READ: read_sector(info_lba,INFO_PATCH);
            INFO_PATCH: if(le32(0)!=32'h41615252 || le32(484)!=32'h61417272 || le32(508)!=32'haa550000) state<=INFO_DONE;
                else begin
                    // Unknown free count forces host software to count FAT entries.
                    patch_index<=0;state<=INFO_CLEAR;
                end
            INFO_CLEAR:if(patch_index==7) state<=INFO_WRITE;else patch_index<=patch_index+1'b1;
            INFO_WRITE: write_sector(info_lba,1,INFO_DONE);
            INFO_DONE: if(!info_backup && backup_sector!=0 && backup_sector!=16'hffff && backup_sector+info_sector<reserved) begin
                info_backup<=1;info_lba<=partition+backup_sector+info_sector;state<=INFO_READ;
                end else state<=SUCCESS;
            SUCCESS: begin busy<=0;done<=1;error<=0;state<=IDLE;end
            default:finish_error(8'hff);
        endcase
    end
end
endmodule

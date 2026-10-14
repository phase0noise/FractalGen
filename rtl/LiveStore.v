// Publish eight completed RGB444 pixels, while pending scanlines have priority.
// Only this 96-bit register is needed; staging/line RAM capacity is unchanged.
// The Gray-coded frontier hides unwritten SDRAM during the first pass and
// remains full while deeper passes replace the image in place.
module LiveStore #(
    parameter TILE_WIDTH = 640, TILE_HEIGHT = 240, TILE_COLUMNS = 2,
    parameter STARTUP_CYCLES = 40000, GLOBAL_RASTER = 0,
    parameter CORRUPTION_INTERVAL = 7500, EXTERNAL_CLIENT = 0, QUEUED_UPLOAD = 0
) (
    input clk, reset, render_active,
    input capture_done, corruption_enable,
    input pixel_valid, input [2:0] pixel_offset, input [11:0] pixel_rgb,
    input group_done, input [2:0] tile_index,
    input [95:0] queued_pixels,input [23:0] queued_address,
    input [7:0] group_x, input [9:0] group_y, output reg group_ack,
    output reg display_ready, output reg [17:0] progress_gray,
    input line_request, input [9:0] line_y, input line_bank,
    output reg line_ack, line_write,
    output reg [9:0] line_write_address, output reg [31:0] line_write_data,
    output reg word_rd, word_wr, output reg [23:0] word_addr,
    output reg [31:0] word_data, output [3:0] word_wstrb,
    output reg [7:0] word_burst_len,
    input word_busy, word_valid, input [31:0] word_q,
    input dma_request,dma_write,input [23:0] dma_address,input [31:0] dma_data,
    input [7:0] dma_length,output reg dma_accepted,dma_done,
    output dma_valid,output [31:0] dma_q
);
localparam ROW_WORDS = TILE_WIDTH * TILE_COLUMNS * 12 / 32;
localparam TILE_WORDS = TILE_WIDTH * 12 / 32;
localparam GROUPS = TILE_WIDTH * TILE_HEIGHT;
localparam S_INIT=0, S_IDLE=1, S_WRITE=2, S_WRITE_BUSY=3,
    S_WRITE_DONE=4, S_GROUP_END=5, S_READ=6, S_READ_BUSY=7,
    S_READ_DATA=8, S_READ_NEXT=9, S_CORRUPT_READ=10,
    S_CORRUPT_READ_BUSY=11, S_CORRUPT_READ_DATA=12, S_CORRUPT_EDIT=13,
    S_CORRUPT_WRITE=14, S_CORRUPT_WRITE_BUSY=15, S_CORRUPT_WRITE_DONE=16,
    S_DMA=17,S_DMA_BUSY=18,S_DMA_DONE=19;
reg held_dma_write;
reg [23:0] held_dma_address;
reg [31:0] held_dma_data;
reg [7:0] held_dma_length;
assign dma_valid=EXTERNAL_CLIENT && (state==S_DMA_BUSY || state==S_DMA_DONE) && word_valid;
assign dma_q=word_q;
reg [4:0] state;
reg [15:0] startup;
reg startup_complete;
reg [95:0] packed_pixels;
reg [7:0] pixels_seen;
reg [1:0] write_index;
reg upload_pending;
reg [23:0] upload_base, line_base;
reg request_meta, request_sync, held_request, held_bank;
reg [9:0] words_received;
reg [17:0] progress;
wire [17:0] next_progress = progress + 1'b1;
wire [9:0] remaining = ROW_WORDS - words_received;
localparam COLUMN_BITS = $clog2(TILE_COLUMNS);
wire [2:0] tile_column = tile_index & (TILE_COLUMNS-1);
wire [2:0] tile_row = tile_index >> COLUMN_BITS;
wire [9:0] global_y = GLOBAL_RASTER ? group_y : tile_row * TILE_HEIGHT + group_y;
wire [23:0] group_base = global_y * ROW_WORDS +
    (GLOBAL_RASTER ? 0 : tile_column * TILE_WORDS) + ({16'd0,group_x} << 1) + group_x;
reg corruption_meta, corruption_sync;
reg [13:0] corruption_counter;
reg [31:0] random_bits;
reg [15:0] color_noise;
reg [95:0] corrupt_pixels;
reg [23:0] corrupt_base;
reg [2:0] corrupt_lane;
reg [11:0] corrupt_color;
reg [1:0] corrupt_received;
wire line_reading = state>=S_READ && state<=S_READ_NEXT;
wire corrupt_reading = state>=S_CORRUPT_READ && state<=S_CORRUPT_READ_DATA;
wire [17:0] random_group = random_bits[17:0];
assign word_wstrb = 4'b1111;

always @(posedge clk or posedge reset) begin
    if (reset) begin
        state<=S_INIT; startup<=0; startup_complete<=0; display_ready<=0;
        dma_accepted<=0;dma_done<=0;held_dma_write<=0;held_dma_address<=0;held_dma_data<=0;held_dma_length<=0;
        packed_pixels<=0; pixels_seen<=0;
        write_index<=0; upload_pending<=0; upload_base<=0;
        progress<=0; progress_gray<=0; group_ack<=0;
        request_meta<=0; request_sync<=0; held_request<=0; held_bank<=0;
        line_ack<=0; line_base<=0; words_received<=0;
        line_write<=0; line_write_address<=0; line_write_data<=0;
        word_rd<=0; word_wr<=0; word_addr<=0; word_data<=0; word_burst_len<=0;
        corruption_meta<=0; corruption_sync<=0; corruption_counter<=0;
        random_bits<=32'h6d2b79f5; color_noise<=16'hb4d3; corrupt_pixels<=0; corrupt_base<=0;
        corrupt_lane<=0; corrupt_color<=0; corrupt_received<=0;
    end else begin
        // A multi-bit state decoder must never control the VGA clock mux.
        // This registered level stays steady through reads/writes/corruption.
        display_ready<=render_active && startup_complete;
        request_meta<=line_request; request_sync<=request_meta;
        group_ack<=0; word_rd<=0; word_wr<=0; line_write<=0;
        dma_accepted<=0;dma_done<=0;
        corruption_meta<=corruption_enable; corruption_sync<=corruption_meta;
        random_bits<={random_bits[30:0],random_bits[31]^random_bits[21]^random_bits[1]^random_bits[0]};
        color_noise<={color_noise[14:0],color_noise[15]^color_noise[13]^color_noise[12]^color_noise[10]};
        if(!render_active || progress==0 || !corruption_sync) corruption_counter<=0;
        else if(corruption_counter<CORRUPTION_INTERVAL-1) corruption_counter<=corruption_counter+1'b1;
        if (!render_active) begin progress<=0; progress_gray<=0; pixels_seen<=0; end
        if (!display_ready && !line_reading) line_ack<=request_sync;
        if (!QUEUED_UPLOAD && pixel_valid && render_active) begin
            packed_pixels[pixel_offset*12 +: 12]<=pixel_rgb;
            pixels_seen[pixel_offset]<=1'b1;
        end
        if (line_reading && word_valid) begin
            line_write<=1'b1;
            line_write_address<={held_bank,words_received[8:0]};
            line_write_data<=word_q; words_received<=words_received+1'b1;
        end
        if(corrupt_reading && word_valid) begin
            corrupt_pixels[corrupt_received*32 +:32]<=word_q;
            corrupt_received<=corrupt_received+1'b1;
        end
        case (state)
            S_INIT: if (startup==STARTUP_CYCLES-1) begin state<=S_IDLE; startup_complete<=1; end
                    else startup<=startup+1'b1;
            S_IDLE: if (!word_busy) begin
                if (display_ready && request_sync!=line_ack) begin
                    held_request<=request_sync; held_bank<=line_bank;
                    line_base<=line_y*ROW_WORDS; words_received<=0; state<=S_READ;
                end else if (upload_pending) state<=S_WRITE;
                else if (render_active && group_done && (QUEUED_UPLOAD || &pixels_seen)) begin
                    upload_base<=QUEUED_UPLOAD ? queued_address : group_base; write_index<=0;
                    if(QUEUED_UPLOAD) packed_pixels<=queued_pixels;
                    upload_pending<=1'b1; state<=S_WRITE;
                end else if(EXTERNAL_CLIENT && dma_request) begin
                    held_dma_write<=dma_write;held_dma_address<=dma_address;
                    held_dma_data<=dma_data;held_dma_length<=dma_length;
                    dma_accepted<=1;state<=S_DMA;
                end else if(render_active && progress!=0 && corruption_sync &&
                            corruption_counter==CORRUPTION_INTERVAL-1 && random_group<progress) begin
                    // Read/modify/write one packed group. Seven adjacent pixels
                    // are preserved, including pixels crossing 32-bit words.
                    corrupt_base<=({6'd0,random_group}<<1)+random_group;
                    // Address rejection must not bias the pixel lane. A
                    // separate generator selects position/color independently.
                    corrupt_lane<=color_noise[2:0]; corrupt_color<=color_noise[15:4];
                    corrupt_received<=0; corruption_counter<=0; state<=S_CORRUPT_READ;
                end
            end
            S_WRITE: if(!render_active) begin upload_pending<=0; state<=S_IDLE; end
            else if (!word_busy) begin
                word_addr<=upload_base+write_index;
                case (write_index)
                    0: word_data<=packed_pixels[31:0];
                    1: word_data<=packed_pixels[63:32];
                    default: word_data<=packed_pixels[95:64];
                endcase
                word_wr<=1'b1; state<=S_WRITE_BUSY;
            end
            S_WRITE_BUSY: if (word_busy) state<=S_WRITE_DONE;
            S_WRITE_DONE: if (!word_busy) begin
                if (!render_active) begin upload_pending<=0; state<=S_IDLE; end
                else if (write_index==2) begin
                    upload_pending<=0; pixels_seen<=0; group_ack<=1;
                    if (progress<GROUPS) begin
                        progress<=next_progress;
                        progress_gray<=next_progress ^ (next_progress>>1);
                    end
                    state<=S_GROUP_END;
                end else begin
                    write_index<=write_index+1'b1;
                    // Finish all three words before admitting a read, so an
                    // in-place refinement cannot expose a partially packed
                    // group. Reads have priority before the next short group.
                    state<=S_WRITE;
                end
            end
            S_GROUP_END: if (QUEUED_UPLOAD || !group_done || !render_active) state<=S_IDLE;
            S_READ: if (!word_busy) begin
                word_addr<=line_base+words_received;
                word_burst_len<=(remaining>128)?8'd127:remaining-1'b1;
                word_rd<=1'b1; state<=S_READ_BUSY;
            end
            S_READ_BUSY: if (word_busy) state<=S_READ_DATA;
            S_READ_DATA: if (!word_busy) state<=S_READ_NEXT;
            S_READ_NEXT: begin
                if (words_received==ROW_WORDS || !display_ready) begin
                    line_ack<=held_request; state<=S_IDLE;
                end else state<=S_READ;
            end
            S_CORRUPT_READ: if(!render_active) state<=S_IDLE;
                else if(!word_busy) begin
                    word_addr<=corrupt_base; word_burst_len<=8'd2;
                    word_rd<=1; state<=S_CORRUPT_READ_BUSY;
                end
            S_CORRUPT_READ_BUSY: if(word_busy) state<=S_CORRUPT_READ_DATA;
            S_CORRUPT_READ_DATA: if(!word_busy) begin
                if(!render_active) state<=S_IDLE;
                else if(corrupt_received==3) state<=S_CORRUPT_EDIT;
            end
            S_CORRUPT_EDIT: begin
                corrupt_pixels[corrupt_lane*12 +:12]<=corrupt_color;
                write_index<=0; state<=S_CORRUPT_WRITE;
            end
            S_CORRUPT_WRITE: if(!render_active) state<=S_IDLE;
                else if(!word_busy) begin
                    word_addr<=corrupt_base+write_index; word_burst_len<=0;
                    case(write_index)
                        0: word_data<=corrupt_pixels[31:0];
                        1: word_data<=corrupt_pixels[63:32];
                        default: word_data<=corrupt_pixels[95:64];
                    endcase
                    word_wr<=1; state<=S_CORRUPT_WRITE_BUSY;
                end
            S_CORRUPT_WRITE_BUSY: if(word_busy) state<=S_CORRUPT_WRITE_DONE;
            S_CORRUPT_WRITE_DONE: if(!word_busy) begin
                if(!render_active || write_index==2) state<=S_IDLE;
                else begin write_index<=write_index+1'b1; state<=S_CORRUPT_WRITE; end
            end
            S_DMA: if(!word_busy) begin
                word_addr<=held_dma_address;word_data<=held_dma_data;word_burst_len<=held_dma_length;
                word_wr<=held_dma_write;word_rd<=!held_dma_write;state<=S_DMA_BUSY;
            end
            S_DMA_BUSY: if(word_busy) state<=S_DMA_DONE;
            S_DMA_DONE: if(!word_busy) begin dma_done<=1;state<=S_IDLE;end
            default: state<=S_INIT;
        endcase
    end
end
endmodule

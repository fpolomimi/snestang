/*
Enhanced loader with a menu and loads smc images directly from FAT32. 
*/
module loader #(
    parameter FREQ = 10_800_000         // Frequency of wclk, for SD clock divider
) (
    input wclk,
    input resetn,

    output reg overlay,                 // Menu loader is working. This override display
    input hclk,                         // overlay here is driven by the display in pixel clock
                                        // input overlay_x and overlay_y, and next cycle 
                                        // overlay_color will be available
    output reg [14:0] overlay_color,
    input [10:0] overlay_x,             // hdmi 720p x
    input [9:0] overlay_y,              // hdmi 720p y

    input [11:0] btns,                  // press A (btns[8]) or B (btns[0]) to start rom

    output reg [7:0] dout,              // ROM data is streamed out through dout.  
    output reg dout_valid,              // pulse 1 when dout is valid
    output reg loading,                 // 1: for the loading process. 
                                        // rising edge resets SNES, falling edge starts SNES
    output reg fail,

    output reg [7:0] map_ctrl,          // 0x15 of SNES header, `mapper_header` in mist-snes
    output reg [7:0] rom_type_header,   // 0x16
    output reg [3:0] rom_size,          // 0x17, actual size is (1024 << rom_size)
    output reg [3:0] ram_size,          // 0x18
    output reg [23:0] rom_mask,
    output reg [23:0] ram_mask,

    input serial_reset,                 // pulse to start serial transmission
    input [7:0] serial_data,            // 32 bytes of SNES header, then actual ROM
    input serial_data_valid,            // serial data strobe

    // SD card physical interface
    output sd_clk,
    inout  sd_cmd,                      // MOSI
    input  sd_dat0,                     // MISO
    output sd_dat1,                     // 1
    output sd_dat2,                     // 1
    output sd_dat3,                     // 1

    output [2:0] dbg_state,
    output dbg_sd_list_en,
    output [7:0] dbg_sd_list_namelen,
    output dbg_list_char_en,
    output [7:0] dbg_list_char,
    output [23:0] dbg_rom_addr,
    output [31:0] dbg_read_sector_no,
    output [2:0] dbg_sd_state
);

`include "font.vh"

// BGR
localparam [14:0] COLOR_BACK    = 15'b00000_00000_00000;
localparam [14:0] COLOR_TEXT    = 15'b10000_11111_11111;    // yellow
localparam [14:0] COLOR_CURSOR  = 15'b10000_11000_11111;    // orange
localparam [14:0] COLOR_LOGO    = 15'b00000_10101_00000;    // green
reg [4:0] menu_x, menu_y;           // menu X (0~31) and Y (0~27) to 
reg [6:0] menu_char;                // char to write to menu
reg menu_wr;                        // menu text write strobe

reg [11:0] file_total;              // max 4095 files
reg [11:0] file_start = 1;          // file number is 1-based
wire [4:0] total = file_total < file_start ? 0 :        // number of files in this page
                   file_total >= file_start + 19 ? 20 : file_total - file_start + 1;

reg[2:0] pad;  // de-bounced pulse for joypad 
localparam [2:0] PAD_CENTER = 3'd0;
localparam [2:0] PAD_UP = 3'd1;
localparam [2:0] PAD_DOWN = 3'd2;
localparam [2:0] PAD_LEFT = 3'd3;
localparam [2:0] PAD_RIGHT = 3'd4;

assign sd_dat1 = 1;
assign sd_dat2 = 1;
assign sd_dat3 = 1;
assign dbg_sd_list_en = sd_list_en;

reg [23:0] sd_romlen;               // max 32K sectors (16MB)
wire sd_outen;
wire [7:0] sd_outbyte;
reg sd_op = 0;
wire sd_done /* XX synthesis syn_keep=1 */;
reg sd_restart = 0;
reg [11:0] sd_file;
wire sd_list_en;
wire [7:0] sd_list_namelen;
assign dbg_sd_list_namelen = sd_list_namelen;
wire list_char_en;
wire [7:0] list_char;
assign dbg_list_char_en = list_char_en;
assign dbg_list_char = list_char;

wire [11:0] sd_list_file;
wire [31:0] sd_file_size;
reg [9:0] smc_header_cnt;           // skip this many bytes of SMC header (512 or 0)

sd_file_list_reader #(
    .CLK_DIV(3'd0), .SIMULATE(0)
) sd_reader_i (
    .rstn(resetn & ~sd_restart), .clk(wclk),
    .sdclk(sd_clk), .sdcmd(sd_cmd), .sddat0(sd_dat0),
    .card_stat(),.card_type(),.filesystem_type(),
    .op(sd_op), .read_file(sd_file), .done(sd_done),
    .list_en(sd_list_en), .list_namelen(sd_list_namelen), 
    .list_file_num(sd_list_file), .list_file_size(sd_file_size), 
    .list_char_en(list_char_en), .list_char(list_char),
    .outen(sd_outen), .outbyte(sd_outbyte),
    .debug_read_done(), .debug_read_sector_no(dbg_read_sector_no),
    .debug_filesystem_state(dbg_sd_state)
);

// SD card loading process
reg [2:0] state;
localparam [2:0] SD_START = 3'd0;
localparam [2:0] SD_CLEAR_SCREEN = 3'd1;
localparam [2:0] SD_READ_DIR = 3'd2;        // getting meta-data, starting from sector 0
localparam [2:0] SD_UI = 3'd3;              // process user input
localparam [2:0] SD_READ_ROM = 3'd4;
localparam [2:0] SD_FAIL = 3'd5;
localparam [2:0] SD_DONE = 3'd6;
assign dbg_state = state;


reg [4:0] active;                           // selected file within the page
reg [4:0] ch;                               // current character to print to screen
reg [4:0] cursor;                           // cursor position to update, loops between 0-19
reg name_end;
reg [19:0] smc_header;                      // whether the rom at this pos has 512-byte SMC header

reg [23:0] rom_addr;                        // raw address including smc header
wire [23:0] addr = rom_addr - smc_header_cnt;
assign dbg_rom_addr = rom_addr;

always @(posedge wclk) begin
    if (~resetn) begin
        sd_op <= 0;                         // list root dir
        state <= SD_START;
        loading <= 0;
        overlay <= 0;
        file_start <= 1;
    end else begin
        sd_restart <= 0;
        overlay <= 0;
        dout_valid <= 0;
        menu_wr <= 0;
        menu_char = 8'd0;
        case (state)
        SD_START: begin
            menu_wr <= 1;
            menu_x <= 5'd2;
            menu_y <= 5'd0;
            state <= SD_CLEAR_SCREEN;            
        end
        SD_CLEAR_SCREEN: begin
            if (menu_y == 5'd27)
                state <= SD_READ_DIR;
            else begin
                menu_wr <= 1;
                // menu_char <= 7'h2D;     // fill ':' for debug
                if (menu_x == 5'd31) begin
                    menu_x <= 5'd2;
                    menu_y <= menu_y + 5'd1;
                end else
                    menu_x <= menu_x + 5'd1;
            end
        end
        SD_READ_DIR: begin
            overlay <= 1;
            if (sd_list_en) begin       // found a dir entry, draw onto screen
                // starting from col=2, row=5, 8x8 chars, 20 lines, 30 wide
                file_total <= sd_list_file;                       // update file count
                if (sd_list_file >= file_start && sd_list_file < file_start + 20) begin
                    ch <= 0;            // start copying name to menu buffer
                    smc_header[sd_list_file - file_start] <= sd_file_size[9];
                end
            end else if (sd_done) begin
                state <= SD_UI;
            end else if (ch < 30 && list_char_en) begin
                menu_wr <= 1;
                menu_x <= 5'd2 + ch;
                menu_y <= 5'd4 + sd_list_file - file_start;
                menu_char <= list_char;
                ch <= ch + 5'd1;
            end
        end
        SD_UI: begin                    // UP and DOWN to choose rom and A to load
            overlay <= 1;
            if (pad == PAD_UP && active != 0)
                active = active - 1;
            else if (pad == PAD_DOWN && active != total-1)
                active = active + 1;
            else if (pad == PAD_RIGHT && file_start + 20 <= file_total) begin // navigate to next/prev menu
                file_start <= file_start + 20;
                sd_restart <= 1;
                state <= SD_START;
            end else if (pad == PAD_LEFT && file_start > 1) begin
                file_start <= file_start - 20;
                sd_restart <= 1;
                state <= SD_START;
            end

            // draw cursor char
            cursor <= cursor < 19 ? cursor + 1 : 0;         // 0 ~ 19 loop
            menu_wr <= 1;
            menu_y <= 4 + cursor;
            menu_x <= 0;
            menu_char <= active == cursor ? 7'h3E : 7'h20;  // '>'

            // select ROM and start loading
            if ((btns[0] || btns[8]) && total != 0) begin   
                sd_op <= 1;
                sd_file <= active + file_start;
                sd_restart <= 1;                            // restart controller to exec read command
                smc_header_cnt <= smc_header[active] ? 10'd512 : 0; // file_size % 1024. (512 or 0)
                loading <= 1;
                menu_x <= 0;
                menu_y <= 26;
                state <= SD_READ_ROM;
            end
        end
        SD_READ_ROM: begin
            overlay <= 1;
            loading <= 1;
            if (sd_outen) begin
                if (rom_addr >= smc_header_cnt) begin   // skipping SMC header
                    dout <= sd_outbyte;
                    dout_valid <= 1;
                end
                // display progress, one dot per 64KB
                menu_y <= 27;
                menu_x <= rom_addr[19:16] + 8;
                if (rom_addr[15:0] == 16'hffff) begin
                    menu_wr <= 1;
                    menu_char <= 7'h2D;      // -
                end else if (rom_addr[15:0] == 16'd0) begin
                    menu_wr <= 1;
                    menu_char <= 7'h3E;      // >
                end
            end else if (rom_addr != 0 && sd_done) begin
                loading <= 0;                    // loading is finished
                state <= SD_DONE;
            end
        end
        endcase
    end
end

reg loading_r;
reg [7:0] map_ctrl_new;
reg [7:0] rom_type_header_new;
reg [7:0] rom_size_new;
reg [7:0] ram_size_new;
reg loading_r;

// ROM detection for map_ctrl, rom_size...
always @(posedge wclk) begin
    loading_r <= loading;
    if (loading && ~loading_r) begin
        rom_addr <= 0;
        ram_size <= 0;
        {map_ctrl, rom_type_header, rom_size, ram_size} <= 0;
    end
    if (loading && sd_outen) begin
        // a rom byte in sd_outbyte
        rom_addr <= rom_addr + 24'd1;
        if (addr[23:15] == 0 || addr[23:15] == 1 || addr[23:15] == {8'h40, 1'b1}) begin
            // LoROM, HiROM & ExHiROM
            if (addr[14:0] == 15'h7FD5) map_ctrl_new <= sd_outbyte;
            if (addr[14:0] == 15'h7FD6) rom_type_header_new <= sd_outbyte;
            if (addr[14:0] == 15'h7FD7) rom_size_new <= sd_outbyte;
            if (addr[14:0] == 15'h7FD8) ram_size_new <= sd_outbyte;
            if (addr[14:0] == 15'h7FDF) begin
                // heuristics for whether this is the actual SNES header
                if (   rom_size_new <= 8'd14        // rom size <= 16MB
                    && ram_size_new <= 8'd7         // ram size <= 128KB
                    && ((map_ctrl_new[1:0] == 2'd0 && addr[23:15] == 0) // normal LoROM
                    || (map_ctrl_new == 8'h53 && addr[23:15] == 0)  // contra 3 has map_ctrl 0x53 and is LoROM
                    || (map_ctrl_new[1:0] == 2'd1 && addr[23:15] == 1)  // HiROM
                    || (map_ctrl_new[1:0] == 2'd2 && addr[23:15] == {8'h40, 1'b1})))    // ExHiRom
                begin
                    map_ctrl <= map_ctrl_new;
                    rom_type_header <= rom_type_header_new;
                    rom_size <= rom_size_new[3:0];
                    ram_size <= ram_size_new[3:0];
                end
            end
        end
        rom_mask <= (24'd1024 << ((rom_size < 4'd7) ? 4'hC : rom_size)) - 1'd1;
        ram_mask <= ram_size != 0 ? (24'd1024 << ram_size) - 1'd1 : 24'd0;        
    end
end

// process keyboard input
// (R L D U START SELECT B A)
reg [$clog2(FREQ/5+1)-1:0] debounce;    // 50ms debounce
wire deb = debounce == 0;
always @(posedge wclk) begin
    pad <= PAD_CENTER;                  // pulse
    if (~resetn) begin
        pad <= 0;
        debounce = 0;
    end else begin
        debounce = debounce == 0 ? 0 : debounce-1;
        if (btns[7] && deb) begin 
            pad <= PAD_RIGHT;
            debounce <= FREQ/5;
        end
        if (btns[6] && deb) begin 
            pad <= PAD_LEFT;
            debounce <= FREQ/5;
        end
        if (btns[5] && deb) begin 
            pad <= PAD_DOWN;
            debounce <= FREQ/5;
        end
        if (btns[4] && deb) begin 
            pad <= PAD_UP;
            debounce <= FREQ/5;
        end
    end
end

//
// Pixel output logic for characters and logo:
// 1. To improve timing, output logic is broken into 3 cycles.
// 2. Char buffer, font rom, logo rom are all stored in the same bram 
//    block to save LUTs.
//
reg [10:0] mem_addr_b;
reg [7:0] mem_do_b;
reg [1:0] mem_cnt;
reg is_cursor;
reg [2:0] xoff, yoff;
reg [14:0] overlay_color_buf;

// Char buffer, font and logo rom backed by Dual-port BRAM (total 2KB)
// this is initialized with font.mi (font.vh + logo.vh)
// $000-$37F: Character buffer RAM (32*28)
// $380-$3FF: Logo ROM (14*9 bytes)
// $400-$800: Font ROM
gowin_dpb_menu menu_mem (
    .clka(wclk), .reseta(1'b0), .ocea(), .cea(1'b1), 
    .ada({1'b0, menu_y, menu_x}), .wrea(menu_wr),
    .dina({1'b0, menu_char}), .douta(), 

    .clkb(hclk), .resetb(1'b0), .oceb(), .ceb(1'b1), 
    .adb(mem_addr_b), .wreb(1'b0), 
    .dinb(), .doutb(mem_do_b)
);

localparam overlay_x_start = 256 - 3;
reg [7:0] px;   // = (overlay_x - overlay_x_start) / 3;
reg [7:0] py;   // = (overlay_y - 24) / 3;
reg [9:0] overlay_y_r;
reg [1:0] y_cnt;

// 72x14 pixels 1bpp logo
// `include "logo.vh"
localparam LOGO_X = 128-36;
localparam LOGO_Y = 201;

reg [6:0] logo_addr;
reg [2:0] logo_xoff;
reg logo_active;

always @* begin
    case (mem_cnt)
    2'd0: mem_addr_b <= {1'b0, py[7:3], px[7:3]};       // fetch next character
    2'd1: mem_addr_b <= logo_active ? 
                        {4'b0111, logo_addr} :          // fetch logo byte
                        {1'b1, mem_do_b[6:0], yoff};    // fetch font byte
    default: mem_addr_b <= 0;
    endcase
end

always @(posedge hclk) begin

    // mem_cnt: cycle counter (0,1,2)
    mem_cnt <= mem_cnt + 2'd1;
    if (mem_cnt == 2'd2) begin
        mem_cnt <= 0;
        px <= px + 8'd1;
    end
    if (overlay_x == overlay_x_start-1) begin
        mem_cnt <= 0;
        px <= 0;
    end
    overlay_y_r <= overlay_y;
    if (overlay_y != overlay_y_r) begin
        if (overlay_y == 10'd24) begin
            py <= 0;
            y_cnt <= 0;
        end else begin
            y_cnt <= y_cnt + 2'd1;
            if (y_cnt == 2'd2) begin
                py <= py + 10'd1;
                y_cnt <= 0;
            end
        end
    end

    // address generation
    case (mem_cnt)
    2'd0: begin
        reg [6:0] logo_x;
        reg [3:0] logo_y;

        // output color from last cycle
        overlay_color <= overlay_color_buf;

        // for next character
        is_cursor <= px[7:4] == 0;
        xoff <= px[2:0];
        yoff <= py[2:0];

        if (px >= LOGO_X && px < LOGO_X+71 && py >= LOGO_Y && py < LOGO_Y + 14)
            logo_active <= 1;
        else
            logo_active <= 0;
        logo_x = px - LOGO_X;
        logo_y = py - LOGO_Y;
        logo_addr <= logo_y * 9 + logo_x[6:3];
        logo_xoff <= logo_x[2:0];

        // mem_do_b is character after cycle 0
    end
    2'd1: begin
        // bram fetches font or logo byte to mem_do_b 
    end  
    2'd2: begin
        // compute output color
        overlay_color_buf <= COLOR_BACK;
        if (logo_active) begin
            if (mem_do_b[logo_xoff])
                overlay_color_buf <= COLOR_LOGO;
            else
                overlay_color_buf <= COLOR_BACK;
        end else if (mem_do_b[xoff]) begin
            if (is_cursor)
                overlay_color_buf <= COLOR_CURSOR;
            else
                overlay_color_buf <= COLOR_TEXT;
        end
    end
    endcase
end
endmodule

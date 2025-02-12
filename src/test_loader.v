// this is basically hello.img but takes up less space

module test_loader (
    input wclk,
    input resetn,

    output reg [7:0] dout,
    output reg dout_valid,

    output [7:0] map_ctrl,
    output [3:0] rom_size,
    output [23:0] rom_mask,
    output [23:0] ram_mask,
    output loading,
    output fail
);

// PeterLemon tests, 32KB
// localparam SIZE = 33280;
// localparam string FILE = "roms/CPUADC.hex";

// 96KB ROMS
// localparam SIZE = 98816;
///localparam string FILE = "roms/HiColor575Myst.hex";
// localparam string FILE = "roms/MosaicMode3.hex";

// 128KB ROMS
// localparam SIZE = 131584;
// localparam string FILE = "roms/hello.hex";
// localparam string FILE = "roms/hello2.hex";
// localparam string FILE = "roms/textbuffer-hello-world.hex";  // not working
// localparam string FILE = "roms/Perspective.hex";

// 512KB roms
// localparam SIZE = 524800;
// localparam string FILE = "roms/inidisp_extend_vblank.hex";

// 256KB ROMS
localparam SIZE = 262656;
localparam string FILE = "roms/snes_10.hex";
// localparam string FILE = "roms/window-precalculated-symmetrical.hex";
// localparam string FILE = "roms/gradient-test.hex";

// examples
// localparam string FILE = "roms/window-shapes-single.hex";
// localparam string FILE = "roms/hdma-double-buffered-indirect-shear.hex";
// localparam string FILE = "roms/hdma-double-buffered-parallax.hex";
// localparam string FILE = "roms/hdma-indirect-repeating-pattern.hex";
// localparam string FILE = "roms/hdma-to-cgram.hex";
// localparam string FILE = "roms/vram-writes-without-dma.hex";

// effects
// localparam string FILE = "roms/vmain-vertical-scrolling.hex";
// localparam string FILE = "roms/hdma-textbox-wipe.hex";
// localparam string FILE = "roms/repeating_hdma_pattern.hex";
// localparam string FILE = "roms/window-shapes-single.hex";    
// localparam string FILE = "roms/window-precalculated-single.hex";
// localparam string FILE = "roms/window-precalculated-symmetrical.hex";

// glitches
// localparam string FILE = "roms/setini-early-read-obj.hex";

// vmain-address-remapping
// localparam string FILE = "roms/vmain-1bpp-no-remapping.hex";
// localparam string FILE = "roms/vmain-8bpp-with-remapping.hex";


reg [7:0] rom [0:SIZE-1];
initial begin
   $readmemh(FILE, rom);
end

assign map_ctrl = rom[21];
assign rom_size = rom[23][3:0];
wire [7:0] ram_size = rom[24];
assign rom_mask = (24'h400 << rom_size) - 24'b1;
assign ram_mask = (24'h400 << ram_size) - 24'b1;

reg [$clog2(SIZE)-1:0] addr = 512;
assign fail = 1'b0;
assign loading = addr != SIZE;

always @(posedge wclk) begin
    if (~resetn) begin
        addr <= 512;
    end else begin
        dout_valid <= 1'b0;
        if (~dout_valid && addr < SIZE) begin
            dout_valid <= 1'b1;
            /* xxverilator lint_off WIDTHTRUNC */
            dout <= rom[addr];      
            /* xxverilator lint_on WIDTHTRUNC */
        end else if (dout_valid)
            addr <= addr + 1;
    end
end

endmodule
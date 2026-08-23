/*  This file is part of JTCORES1.
    JTCORES1 program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTCORES1 program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTCORES1.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 18-9-2021 */

module jtcps2_game(
    `include "jtframe_game_ports.inc" // see $JTFRAME/hdl/inc/jtframe_game_ports.inc
);

// ---------------------------------------------------------------------------
// CPS-2 WIDE (Vampire Saved) OVERRIDE of cores/cps2/hdl/jtcps2_game.v.
// Copied at jtcores v1.7.3 because the game top has to carry the profile gate
// and the widened QSound address, and the file is SHARED with cores/cps2 —
// editing it in place would change the reference core. The diff against the
// original IS the trust surface (CLAUDE.md rule 1 v2) and is frozen by
// tests/test_mister_wide_gate.sh. FOUR deltas:
//   1. `qsnd_addr` 23 -> 24 bits;
//   2. `wide_en` decoded from the ROM header by jtcps2w_profile;
//   3. that wire routed into jtcps15_sound;
//   4. the full 24-bit qsnd_addr handed to jtcps1_sdram, which SPLITS it.
// On (4) — and it CORRECTS the design note that said `PCM_AW` 23 -> 24:
// jtframe's 8-bit SDRAM slot CANNOT be widened past SDRAMW. `sdram_addr =
// offset + { {SDRAMW-AW{1'b0}}, addr_req>>(DW==8) }`
// (jtframe_romrq_bcache.v:74) becomes a replication of -1 at AW=24, SDRAMW=23,
// which is a hard Verilator error, not a warning. That is also why the
// placement map splits QSound across two banks rather than growing one slot:
// bank 1 keeps the stock 8 MB at 23 bits and the 0x80+ extension gets its own
// 1 MB window in bank 0. SLICE D2 IS WHERE THAT SPLIT LANDED: the game top
// now passes all 24 bits and cores/cps2w/hdl/jtcps1_sdram.v routes bit 23.
//
// SLICE D2 adds three more deltas, all of them one line each:
//   5. `wide_en` routed into jtcps1_sdram (the download redirects and the two
//      read-side selects all take it there);
//   6. the SDRAM instance resolves to cores/cps2w/hdl/jtcps1_sdram.v;
//   7. `rom0_bank` widened to 3 bits at the SDRAM port, with bit 2 TIED LOW —
//      that bit is the CPS-2 Turbo obj promote and it is slice D3's. Until
//      then the two group-C read slots are provably unreachable and D2's
//      evidence is the SDRAM image census, not a fetch.
// ---------------------------------------------------------------------------

wire        clk_gfx, rst_gfx;
wire        snd_cs, qsnd_cs,
            main_ram_cs, main_vram_cs, main_oram_cs, main_rom_cs,
            rom0_cs, rom1_cs,
            vram_dma_cs;
wire        obank;  // OBJ bank
wire [15:0] oram_base;
wire [18:0] snd_addr;
wire [23:0] qsnd_addr;   // CPS-2 WIDE: [23] = DSP sample bank 0x80+
wire        prog_qsnd;
wire [ 7:0] snd_data, qsnd_data;
wire [17:1] ram_addr;
wire [21:1] main_rom_addr;
wire [15:0] main_ram_data, main_rom_data, main_dout, mmr_dout;
wire        main_rom_ok, main_ram_ok;
wire        ppu1_cs, ppu2_cs, ppu_rstn, objcfg_cs;
wire        raster;
wire [19:0] rom1_addr, rom0_addr;
wire [ 1:0] rom0_bank;
// CPS-2 WIDE: the SDRAM side takes THREE bank bits. Bit 2 selects GFX group C
// and is driven by the obj promote in slice D3; it is tied low here so D2
// changes no fetch at all.
wire [ 2:0] rom0_bank_sdram = { 1'b0, rom0_bank };
wire [31:0] rom0_data, rom1_data;
// Video RAM interface
wire [17:1] vram_dma_addr;
wire [15:0] vram_dma_data;
wire        vram_dma_ok, rom0_ok, rom1_ok, snd_ok, qsnd_ok;
wire [15:0] cpu_dout;
wire        cpu_speed;
wire        z80_rstn, star_bank;

wire        main_rnw, busreq, busack;

wire        vram_clr, vram_rfsh_en;
wire [ 8:0] hdump;
wire [ 8:0] vdump, vrender;

wire        rom0_half, rom1_half;
wire        cfg_we, key_we;
wire [ 1:0] joymode;
wire        wide_en;   // CPS-2 WIDE profile, from the ROM header

// CPS2 Objects
wire [12:0] gfx_oram_addr;
wire [15:0] gfx_oram_data;
wire        gfx_oram_ok, gfx_oram_clr, gfx_oram_cs;

// M68k - Sound subsystem communication
wire [ 7:0] main2qs_din;
wire [23:1] main2qs_addr;
wire        main2qs_cs, main_busakn, main_waitn;
wire [12:0] volume;

// EEPROM
wire        sclk, sdi, sdo, scs;

wire [ 1:0] dsn;
wire        cen16, cen16b, cen12, cen8, cen10b;
wire        cpu_cen, cpu_cenb;
wire        turbo, skip_en, video_flip;

`ifdef JTCPS_TURBO
assign turbo = 1;
`else
assign turbo = status[6];
`endif

assign skip_en = status[7];

assign ba1_din=0, ba2_din=0, ba3_din=0,
       ba1_dsn=3, ba2_dsn=3, ba3_dsn=3;

// CPU clock enable signals come from 48MHz domain
jtframe_cen48 u_cen48(
    .clk        ( clk48         ),
    .cen16      (               ),
    .cen16b     (               ),
    .cen12      ( cen12         ),
    .cen8       ( cen8          ),
    .cen6       (               ),
    .cen4       (               ),
    .cen4_12    (               ),
    .cen3       (               ),
    .cen3q      (               ),
    .cen1p5     (               ),
    // 180 shifted signals
    .cen12b     (               ),
    .cen6b      (               ),
    .cen3b      (               ),
    .cen3qb     (               ),
    .cen1p5b    (               )
);

jtframe_cen96 u_pxl_cen(
    .clk    ( clk96     ),    // 96 MHz
    .cen16  ( pxl2_cen  ),
    .cen12  (           ),
    .cen8   ( pxl_cen   ),
    // Unused:
    .cen6   (           ),
    .cen6b  (           )
);

assign clk_gfx = clk96;
assign rst_gfx = rst96;
// reg [1:0] aux;
// assign cpu_cen = cen12;
// always @(posedge clk48 ) aux<={ aux[0], cen12};
// assign cpu_cenb = aux==2'b10;


localparam REGSIZE=24;

// Turbo speed disables DMA
wire busreq_cpu = busreq & ~turbo;
wire busack_cpu;

`ifndef NOMAIN
jtcps2_main u_main(
    .rst        ( rst48             ),
    .clk_rom    ( clk96             ),
    .clk        ( clk48             ),
    .cpu_cen    ( cpu_cen           ),
    // Timing
    .V          ( vdump             ),
    .LVBL       ( LVBL              ),
    .LHBL       ( LHBL              ),
    .skip_en    ( skip_en           ),
    // PPU
    .ppu1_cs    ( ppu1_cs           ),
    .ppu2_cs    ( ppu2_cs           ),
    .objcfg_cs  ( objcfg_cs         ),
    .ppu_rstn   ( ppu_rstn          ),
    .mmr_dout   ( mmr_dout          ),
    .raster     ( raster            ),
    //.raster     ( 1'b0            ),
    // Keys
    .prog_din   ( prog_data[7:0]    ),
    .key_we     ( key_we            ),
    // Sound
    .z80_rstn    ( z80_rstn         ),
    .main2qs_din ( main2qs_din      ),
    .main2qs_addr( main2qs_addr     ),
    .main2qs_cs  ( main2qs_cs       ),
    .main2qs_busakn( main_busakn    ),
    .main2qs_waitn( main_waitn      ),
    .UDSWn      ( dsn[1]            ),
    .LDSWn      ( dsn[0]            ),
    .volume     ( volume            ),
    // cabinet I/O
    // Cabinet input
    .cab_1p      ( cab_1p           ),
    .coin        ( coin             ),
    .joymode     ( joymode          ),
    .joystick1   ( joystick1        ),
    .joystick2   ( joystick2        ),
    .joystick3   ( joystick3        ),
    .joystick4   ( joystick4        ),
    .service     ( service          ),
    .tilt        ( 1'b1             ),
    .dipsw       ( dipsw            ),
    .dial_x      ( dial_x           ),
    .dial_y      ( dial_y           ),
    // BUS sharing
    .busreq      ( busreq_cpu       ),
    .busack      ( busack_cpu       ),
    .RnW         ( main_rnw         ),
    // RAM/VRAM access
    .addr        ( ram_addr         ),
    .cpu_dout    ( main_dout        ),
    .ram_cs      ( main_ram_cs      ),
    .vram_cs     ( main_vram_cs     ),
    .oram_cs     ( main_oram_cs     ),
    .obank       ( obank            ),
    .oram_base   ( oram_base        ),
    .ram_data    ( main_ram_data    ),
    .ram_ok      ( main_ram_ok      ),
    // ROM access
    .rom_cs      ( main_rom_cs      ),
    .rom_addr    ( main_rom_addr    ),
    .rom_data    ( main_rom_data    ),
    .rom_ok      ( main_rom_ok      ),
    // DIP switches
    .dip_pause   ( dip_pause        ),
    .dip_test    ( dip_test         ),
    // EEPROM
    .eeprom_sclk ( sclk             ),
    .eeprom_sdi  ( sdi              ),
    .eeprom_sdo  ( sdo              ),
    .eeprom_scs  ( scs              ),
    // Debug
    .debug_bus   ( debug_bus        ),
    .st_dout     ( debug_view       )
);

assign busack = busack_cpu | turbo;

`else
    assign ram_addr      = 0;
    assign main_ram_cs   = 0;
    assign main_vram_cs  = 0;
    assign main_rom_cs   = 0;
    assign oram_base     = 0;
    assign main_oram_cs  = 0;
    assign main_rom_addr = 0;
    assign main_dout     = 0;
    assign z80_rstn      = 1;
    assign dsn           = 2'b11;
    assign main_rnw      = 1;
    assign sclk          = 0;
    assign sdi           = 0;
    assign scs           = 0;
    assign obank         = 0;
    assign busack        = 1;
    assign ppu1_cs       = 0;
    assign ppu2_cs       = 0;
    assign objcfg_cs     = 0;
    assign ppu_rstn      = 1;
    assign cpu_dout      = 0;
`endif

reg rst_video, rst_sdram;

always @(negedge clk_gfx) begin
    rst_video <= rst_gfx;
end

always @(negedge clk) begin
    rst_sdram <= rst;
end

assign dip_flip = video_flip;

jtcps1_video #(REGSIZE) u_video(
    .rst            ( rst_video     ),
    .clk            ( clk_gfx       ),
    .clk_cpu        ( clk48         ),
    .pxl2_cen       ( pxl2_cen      ),
    .pxl_cen        ( pxl_cen       ),

    .hdump          ( hdump         ),
    .vdump          ( vdump         ),
    .vrender        ( vrender       ),
    .gfx_en         ( gfx_en        ),
    .debug_bus      ( debug_bus     ),
    .cpu_speed      ( cpu_speed     ),
    .charger        (               ),
    .kabuki_en      (               ),
    .raster         ( raster        ),

    // CPU interface
    .ppu_rstn       ( ppu_rstn      ),
    .ppu1_cs        ( ppu1_cs       ),
    .ppu2_cs        ( ppu2_cs       ),
    .addr           ( ram_addr[12:1]),
    .dsn            ( dsn           ),      // data select, active low
    .cpu_dout       ( main_dout     ),
    .mmr_dout       ( mmr_dout      ),
    // BUS sharing
    .busreq         ( busreq        ),
    .busack         ( busack        ),

    // Object RAM
    .obank          ( obank         ),
    .oram_addr      ( gfx_oram_addr ),
    .oram_ok        ( gfx_oram_ok   ),
    .oram_data      ( gfx_oram_data ),
    .oram_clr       ( gfx_oram_clr  ),
    .oram_cs        ( gfx_oram_cs   ),
    .objcfg_cs      ( objcfg_cs     ),

    // Video signal
    .HS             ( HS            ),
    .VS             ( VS            ),
    .LHBL           ( LHBL          ),
    .LVBL           ( LVBL          ),
    .red            ( red           ),
    .green          ( green         ),
    .blue           ( blue          ),
    .flip           ( video_flip    ),

    // CPS-B Registers
    .cfg_we         ( cfg_we        ),
    .cfg_data       ( prog_data[7:0]),

    // Extra inputs read through the C-Board
    .cab_1p   ( cab_1p  ),
    .coin     ( coin    ),
    .joystick1      ( 10'h3ff       ),
    .joystick2      ( 10'h3ff       ),
    .joystick3      ( 10'h3ff       ),
    .joystick4      ( 10'h3ff       ),

    // Video RAM interface
    .vram_dma_addr  ( vram_dma_addr ),
    .vram_dma_data  ( vram_dma_data ),
    .vram_dma_ok    ( vram_dma_ok   ),
    .vram_dma_cs    ( vram_dma_cs   ),
    .vram_dma_clr   ( vram_clr      ),
    .vram_rfsh_en   ( vram_rfsh_en  ),

    // GFX ROM interface
    .rom1_addr      ( rom1_addr     ),
    .rom1_half      ( rom1_half     ),
    .rom1_data      ( rom1_data     ),
    .rom1_cs        ( rom1_cs       ),
    .rom1_ok        ( rom1_ok       ),
    .rom0_addr      ( rom0_addr     ),
    .rom0_bank      ( rom0_bank     ),
    .rom0_half      ( rom0_half     ),
    .rom0_data      ( rom0_data     ),
    .rom0_cs        ( rom0_cs       ),
    .rom0_ok        ( rom0_ok       ),

    .star_bank      ( star_bank     ),
    .star0_addr     (               ),
    .star0_data     ( 0             ),
    .star0_cs       (               ),
    .star0_ok       ( 1'b1          ),

    .star1_addr     (               ),
    .star1_data     ( 0             ),
    .star1_cs       (               ),
    .star1_ok       ( 1'b1          ),

    // Watched signals
    .watch_vram_cs  ( main_vram_cs  ),
    .watch          ( game_led      )
);

// Sound CPU cannot be disabled as there is
// interaction between both CPUs at power up
reg qsnd_rst;

always @(posedge clk48, posedge rst) begin
    if( rst )
        qsnd_rst  <= 1;
    else
        qsnd_rst  <= ~z80_rstn;
end

wire vol_up   = ~(coin[0] | joystick1[3]);
wire vol_down = ~(coin[0] | joystick1[2]);

`ifndef NOMAIN
jtcps15_sound u_sound(
    .rst        ( qsnd_rst          ),
    .clk48      ( clk48             ),
    .clk96      ( clk96             ),
    .cen8       ( cen8              ),
    .vol_up     ( vol_up            ),
    .vol_down   ( vol_down          ),
    .volume     ( volume            ),
    // Decode keys
    .kabuki_we  ( 1'b0              ),
    .kabuki_en  ( 1'b0              ),
    .wide_en    ( wide_en           ),

    // Interface with main CPU
    .main_addr  ( main2qs_addr      ),
    .main_dout  ( main_dout[7:0]    ),
    .main_din   ( main2qs_din       ),
    .main_ldswn ( dsn[0]            ),
    .main_buse_n( ~main2qs_cs       ),
    .main_busakn( main_busakn       ),
    .main_waitn ( main_waitn        ),

    // ROM
    .rom_addr   ( snd_addr          ),
    .rom_cs     ( snd_cs            ),
    .rom_data   ( snd_data          ),
    .rom_ok     ( snd_ok            ),

    // QSound sample ROM
    .qsnd_addr  ( qsnd_addr         ), // max 8 MB.
    .qsnd_cs    ( qsnd_cs           ),
    .qsnd_data  ( qsnd_data         ),
    .qsnd_ok    ( qsnd_ok           ),

    // ROM programming interface
    .prog_addr  ( prog_addr[12:0]   ),
    .prog_data  ( prog_data[7:0]    ),
    .prog_we    ( prog_qsnd         ),

    // Sound output
    .left       ( snd_left          ),
    .right      ( snd_right         ),
    .sample     ( sample            )
);
`else
    assign snd_left  = 0;
    assign snd_right = 0;
    assign sample    = 0;
    assign snd_cs    = 0;
    assign snd_addr  = 0;
    assign qsnd_cs   = 0;
    assign qsnd_addr = 0;
`endif

// CPS-2 WIDE: the runtime profile gate. Header byte 41, ACTIVE LOW, so a
// stock MRA (whose header is 0xFF-filled) runs this RBF as a stock machine.
jtcps2w_profile u_profile(
    .clk        ( clk           ),
    .ioctl_addr ( ioctl_addr    ),
    .ioctl_dout ( ioctl_dout    ),
    .ioctl_wr   ( ioctl_wr      ),
    .ioctl_ram  ( ioctl_ram     ),
    .wide_en    ( wide_en       )
);

jtcps1_sdram #(.CPS(2), .REGSIZE(REGSIZE)) u_sdram (
    .rst         ( rst_sdram     ),
    .wide_en     ( wide_en       ),
    .clk         ( clk           ),
    .clk_gfx     ( clk_gfx       ),
    .clk_cpu     ( clk48         ),
    .LVBL        ( LVBL          ),

    .ioctl_rom   ( ioctl_rom     ),
    .dwnld_busy  ( dwnld_busy    ),
    .cfg_we      ( cfg_we        ),

    // ROM LOAD
    .ioctl_addr  ( ioctl_addr    ),
    .ioctl_dout  ( ioctl_dout    ),
    .ioctl_din   ( ioctl_din     ),
    .ioctl_wr    ( ioctl_wr      ),
    .ioctl_ram   ( ioctl_ram     ),
    .prog_addr   ( prog_addr     ),
    .prog_data   ( prog_data     ),
    .prog_mask   ( prog_mask     ),
    .prog_ba     ( prog_ba       ),
    .prog_we     ( prog_we       ),
    .prog_rd     ( prog_rd       ),
    .prog_rdy    ( prog_rdy      ),
    .prog_qsnd   ( prog_qsnd     ),
    .kabuki_we   (               ), // disabled for CPS2
    .cps2_key_we ( key_we        ),
    .cps2_joymode( joymode       ),
    // joystick type


    // EEPROM
    .sclk           ( sclk          ),
    .sdi            ( sdi           ),
    .sdo            ( sdo           ),
    .scs            ( scs           ),
    .dump_flag      (               ),

    // Main CPU
    .main_rom_cs    ( main_rom_cs   ),
    .main_rom_ok    ( main_rom_ok   ),
    .main_rom_addr  ( main_rom_addr ),
    .main_rom_data  ( main_rom_data ),

    // VRAM
    .vram_clr       ( vram_clr      ),
    .vram_dma_cs    ( vram_dma_cs   ),
    .main_ram_cs    ( main_ram_cs   ),
    .main_vram_cs   ( main_vram_cs  ),
    .main_oram_cs   ( main_oram_cs  ),
    .obank          ( obank         ),
    .oram_base      ( oram_base     ),
    .vram_rfsh_en   ( vram_rfsh_en  ),

    .dsn            ( dsn           ),
    .main_dout      ( main_dout     ),
    .main_rnw       ( main_rnw      ),

    .main_ram_ok    ( main_ram_ok   ),
    .vram_dma_ok    ( vram_dma_ok   ),

    .main_ram_addr  ( ram_addr      ),
    .vram_dma_addr  ( vram_dma_addr ),

    .main_ram_data  ( main_ram_data ),
    .vram_dma_data  ( vram_dma_data ),

    .gfx_oram_addr  ( gfx_oram_addr ),
    .gfx_oram_data  ( gfx_oram_data ),
    .gfx_oram_ok    ( gfx_oram_ok   ),
    .gfx_oram_clr   ( gfx_oram_clr  ),
    .gfx_oram_cs    ( gfx_oram_cs   ),

    // Sound CPU and PCM
    .snd_cs      ( snd_cs        ),
    .pcm_cs      ( qsnd_cs       ),

    .snd_ok      ( snd_ok        ),
    .pcm_ok      ( qsnd_ok       ),

    .snd_addr    ( snd_addr      ),
    // [23] is the WIDE extension bank bit and jtcps1_sdram SPLITS on it
    // (slice D2): 0 -> bank 1 offset 0, the stock 8 MB; 1 -> the 1 MB window
    // in bank 0. It is 0 whenever wide_en is 0.
    .pcm_addr    ( qsnd_addr     ),

    .snd_data    ( snd_data      ),
    .pcm_data    ( qsnd_data     ),

    // Graphics
    .rom0_cs     ( rom0_cs       ),
    .rom1_cs     ( rom1_cs       ),

    .rom0_ok     ( rom0_ok       ),
    .rom1_ok     ( rom1_ok       ),

    .rom0_addr   ( rom0_addr     ),
    .rom0_bank   ( rom0_bank_sdram ),
    .rom1_addr   ( rom1_addr     ),

    .rom0_half   ( rom0_half     ),
    .rom1_half   ( rom1_half     ),

    .rom0_data   ( rom0_data     ),
    .rom1_data   ( rom1_data     ),

    .star_bank   ( star_bank     ),
    .star0_addr  ( 13'd0         ),
    .star0_data  (               ),
    .star0_ok    (               ),
    .star0_cs    ( 1'b0          ),

    .star1_addr  ( 13'd0         ),
    .star1_data  (               ),
    .star1_ok    (               ),
    .star1_cs    ( 1'b0          ),

    // Bank 0: allows R/W
    .ba0_addr    ( ba0_addr      ),
    .ba1_addr    ( ba1_addr      ),
    .ba2_addr    ( ba2_addr      ),
    .ba3_addr    ( ba3_addr      ),
    .ba_rd       ( ba_rd         ),
    .ba_wr       ( ba_wr         ),
    .ba_ack      ( ba_ack        ),
    .ba_dst      ( ba_dst        ),
    .ba_dok      ( ba_dok        ),
    .ba_rdy      ( ba_rdy        ),
    .ba0_din     ( ba0_din       ),
    .ba0_dsn     ( ba0_dsn       ),

    .data_read   ( data_read     )
);

endmodule

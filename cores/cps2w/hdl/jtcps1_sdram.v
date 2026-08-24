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
    Date: 5-12-2020 */

// ---------------------------------------------------------------------------
// CPS-2 WIDE (Vampire Saved) OVERRIDE of cores/cps1/hdl/jtcps1_sdram.v.
// Copied at jtcores v1.7.3 (slice D2) because the SDRAM PLACEMENT changes and
// the file is SHARED with cores/cps1, cores/cps15 and cores/cps2 — editing it
// in place would change the reference cores. The diff against the original IS
// the trust surface (CLAUDE.md rule 1 v2) and is frozen line by line by
// tests/test_mister_wide_gate.sh. Everything here implements
// docs/project/mister_map.md section 5, "THE MAP".
//
// WHAT MOVES, AND WHAT IS GATED. Three of the four changes are BEHAVIOURAL and
// every one of them is behind `wide_en` (MRA header byte 41, slice D1):
//   * the QSound READ split on pcm_addr[23]  (`pcmh_sel`),
//   * the group-C obj READ select on rom0_bank[2]  (`gfxc_sel`),
//   * the download-side redirects, passed to jtcps1_prom_we as `wide_en`.
// The fourth is the BANK-0 RE-PACK — VRAM/ORAM/WRAM/SND move up to make room
// for a 6 MB PRG region. That one is UNCONDITIONAL, because SLOTn_OFFSET are
// elaboration-time parameters of the jtframe slot modules and cannot be
// switched at run time. It is a RELOCATION and not a behaviour change: the
// 68k sees identical data at identical 68k addresses; VRAM/ORAM/WRAM are
// never downloaded; the Z80 region's download and read use the SAME constant;
// and bank 0 is the one bank with `JTFRAME_BA0_AUTOPRECH=1`
// (cores/cps1/cfg/common.def), so its per-access latency is address-
// independent by construction and no row-locality pattern can shift. That
// argument is not left as an argument: tests/test_mister_wide_inert.sh
// compares cps2 and cps2w work RAM BIT-IDENTICALLY, frame by frame, on the
// same stock download.
//
// SLOT COUNTS. Bank 0 goes from 5 to 7 slots (jtframe_ram1_7slots, ADDED to
// jtframe as a mechanical member of the ram1_Nslots family) and bank 1 from 1
// to 2 (jtframe_rom_2slots, which already exists). Map section 5, option A.
//
// WHAT IS *NOT* HERE, AND IS SLICE D3: the OBJ PROMOTE. `rom0_bank` is three
// bits wide at this port, but the game top drives {1'b0, rom0_bank} — the
// object table's 3-bit CPS-2 Turbo bank is D3. So in D2 `gfxc_sel` is
// constant 0, the two group-C read slots are provably unreachable, and what
// D2 proves is the PLACEMENT (the SDRAM image census), not the fetch.
// ---------------------------------------------------------------------------

module jtcps1_sdram #( parameter
           CPS     = 1,
           REGSIZE = 24,
           Z80_AW  = CPS==1 ? 16 : 19,
           PCM_AW  = CPS==1 ? 18 : 23
) (
    input           rst,
    input           clk,        // SDRAM clock (48/96)
    input           wide_en,    // CPS-2 WIDE profile (cores/cps2w/hdl/jtcps2w_profile.v)
    input           clk_gfx,    // 96 MHz
    input           clk_cpu,    // 48 MHz
    input           LVBL,

    input           ioctl_rom,
    output          dwnld_busy,
    output          cfg_we,

    // ROM LOAD
    input   [25:0]  ioctl_addr,
    input   [ 7:0]  ioctl_dout,
    output  [ 7:0]  ioctl_din,
    input           ioctl_wr,
    input           ioctl_ram,
    output  [22:0]  prog_addr,
    output  [15:0]  prog_data,
    output  [ 1:0]  prog_mask,
    output  [ 1:0]  prog_ba,
    output          prog_we,
    output          prog_rd,
    input           prog_rdy,
    output          prog_qsnd,

    // EEPROM
    input           sclk,
    input           sdi,
    output          sdo,
    input           scs,

    // Kabuki decoder (CPS 1.5)
    output          kabuki_we,

    // CPS2 Keys
    output          cps2_key_we,
    output   [ 1:0] cps2_joymode,

    // Main CPU
    input           main_rom_cs,
    output          main_rom_ok,
    input    [21:0] main_rom_addr,   // CPS-2 WIDE: 6 MB of program (slice D4)
    output   [15:0] main_rom_data,

    // VRAM
    input           vram_clr,
    input           vram_dma_cs,
    input           main_ram_cs,
    input           main_vram_cs,
    input           main_oram_cs,
    `ifdef CPS2
    input           obank,
    input    [15:0] oram_base,
    input    [12:0] gfx_oram_addr,
    output   [15:0] gfx_oram_data,
    output          gfx_oram_ok,
    input           gfx_oram_clr,
    input           gfx_oram_cs,
    `endif
    input           vram_rfsh_en,

    input    [ 1:0] dsn,
    input    [15:0] main_dout,
    input           main_rnw,

    output          main_ram_ok,
    output          vram_dma_ok,

    input    [17:1] main_ram_addr,
    input    [17:1] vram_dma_addr,

    output   [15:0] main_ram_data,
    output   [15:0] vram_dma_data,

    // Sound CPU and PCM
    input           snd_cs,
    input           pcm_cs,

    output          snd_ok,
    output          pcm_ok,

    input [Z80_AW-1:0] snd_addr,
    // CPS-2 WIDE: ONE BIT WIDER than the slot. jtframe's 8-bit SDRAM slot
    // caps at SDRAMW (jtframe_romrq_bcache.v:74), so the QSound region is two
    // slots in two banks and pcm_addr[PCM_AW] is the bank-select, not an
    // address bit of either slot.
    input [PCM_AW  :0] pcm_addr,

    output     [7:0] snd_data,
    output     [7:0] pcm_data,

    // Graphics
    input           rom0_cs,
    input           rom1_cs,

    output reg      rom0_ok, // obj
    output          rom1_ok,

    input    [19:0] rom0_addr,
    // CPS-2 WIDE: 3 bits. Bit 2 selects GFX group C and is driven by the obj
    // promote in slice D3; the game top ties it low until then.
    input    [ 2:0] rom0_bank,
    input    [19:0] rom1_addr,

    input           rom0_half,
    input           rom1_half,

    output reg [31:0] rom0_data,  // obj
    output     [31:0] rom1_data,

    input             star_bank,
    input     [12:0]  star0_addr,
    output    [31:0]  star0_data,
    output            star0_ok,
    input             star0_cs,

    input     [12:0]  star1_addr,
    output    [31:0]  star1_data,
    output            star1_ok,
    input             star1_cs,

    // Bank 0: allows R/W
    output   [22:0] ba0_addr,
    output   [22:0] ba1_addr,
    output   [22:0] ba2_addr,
    output   [22:0] ba3_addr,
    output   [ 3:0] ba_rd,
    output   [ 3:0] ba_wr,
    output   [15:0] ba0_din,
    output   [ 1:0] ba0_dsn,  // write mask
    input    [ 3:0] ba_ack,
    input    [ 3:0] ba_dst,
    input    [ 3:0] ba_dok,
    input    [ 3:0] ba_rdy,

    input    [15:0] data_read,
    output          dump_flag
);

// CPS-2 WIDE bank-0 map (docs/project/mister_map.md section 5). All of these
// are 23-bit WORD offsets; the byte offset is twice the constant.
//   byte 0x000000  68k PRG                    6 MB   (D4 widens the slot)
//   byte 0x600000  VRAM                     256 KB
//   byte 0x640000  OBJ RAM                   32 KB
//   byte 0x648000  work RAM RAM:$FF0000       64 KB
//   byte 0x658000  Z80 program              512 KB
//   byte 0x6E0000  QSound DSP banks 0x80+      1 MB   NEW
//   byte 0x7E0000  GFX group C, obj bank 5  7.995 MB NEW
// The CPS1 column keeps the reference values: this file is compiled only by
// cores/cps2w (CPS==2), and a CPS1 build of it must not silently re-place.
localparam [22:0] ZERO_OFFSET  = 23'h0,
                  PCM_OFFSET   = ZERO_OFFSET,
                  VRAM_OFFSET  = CPS==2 ? 23'h30_0000 : 23'h20_0000,
                  ORAM_OFFSET  = CPS==2 ? 23'h32_0000 : 23'h28_0000,
                  WRAM_OFFSET  = CPS==2 ? 23'h32_4000 : 23'h30_0000,
                  SND_OFFSET   = CPS==2 ? 23'h32_C000 : 23'h38_0000,
                  PCMH_OFFSET  = 23'h37_0000,   // QSound high window, bank 0
                  GFXC5_OFFSET = 23'h3F_0000,   // group C obj bank 5, bank 0
                  GFXC4_OFFSET = 23'h40_0000,   // group C obj bank 4, bank 1
                  ROM_OFFSET   = ZERO_OFFSET;

// Disabling the SDRAM cache latch increases
// object trhoughput
`ifdef MISTER
localparam OBJ_LATCH=0;
`else
// MiST/SiDi struggle with timing with the low latency setting
// So it is disabled. Nonetheless,
// they enjoy a different benefit as the SDRAM has dedicated
// lines for DQMH/L
localparam OBJ_LATCH=1;
`endif

`ifdef CPS2
    localparam [22:0] SCR_OFFSET = 23'h00_0000; // change this when moving to 8MB+ GFX
    localparam        CPS2       = 1;
`else
    localparam [22:0] SCR_OFFSET = ZERO_OFFSET;
    localparam        CPS2       = 0;

    wire [12:0] gfx_oram_addr = 13'd0;
    wire [15:0] gfx_oram_data;
    wire        gfx_oram_ok;
    wire        gfx_oram_clr = 0;
    wire        gfx_oram_cs  = 0;
`endif

`ifdef CPS15
localparam EEPROM_AW=7, EEPROM_DW=8;
`else
localparam EEPROM_AW=6, EEPROM_DW=16;
`endif

(*keep*) wire [22:0] cps2_gfx0;
wire [21:0] gfx1_addr, gfx0_addr;
// ---- CPS-2 WIDE, slice D2 ------------------------------------------------
wire        gfxc_sel, gfxc4_cs, gfxc5_cs, gfxc4_ok, gfxc5_ok;
wire [31:0] gfxc4_dout, gfxc5_dout;
wire        pcmh_sel, pcmh_cs, pcm_lo_cs, pcmh_ok, pcm_lo_ok;
wire [ 7:0] pcmh_data, pcm_lo_data;
wire [19:0] pcmh_addr;
wire [22:0] main_offset;
wire        ram_vram_cs;
wire        ba2_rdy_gfx, ba2_ack_gfx;
reg  [17:1] main_addr_x; // main addr modified for object bank access
reg         ocache_clr, obank_last;
wire        dump_we;


assign gfx0_addr   = {rom0_addr, rom0_half, 1'b0 }; // OBJ
assign gfx1_addr   = {rom1_addr, rom1_half, 1'b0 };
// CPS-2 WIDE: the QSound region is SPLIT on pcm_addr[PCM_AW] (= [23] on
// CPS-2). Banks 0x00-0x7F stay in SDRAM bank 1 at offset 0, byte-identical to
// stock jtcps2; banks 0x80+ read the 1 MB window in bank 0, MASKED to it.
assign pcmh_sel    = wide_en & pcm_addr[PCM_AW];
assign pcmh_cs     = pcm_cs &  pcmh_sel;
assign pcm_lo_cs   = pcm_cs & ~pcmh_sel;
assign pcm_ok      = pcmh_sel ? pcmh_ok   : pcm_lo_ok;
assign pcm_data    = pcmh_sel ? pcmh_data : pcm_lo_data;
/* verilator lint_off WIDTH */
assign pcmh_addr   = pcm_addr[PCM_AW-1:0];
/* verilator lint_on WIDTH */
assign ram_vram_cs = main_ram_cs | main_vram_cs | main_oram_cs;
assign main_offset = main_oram_cs ? ORAM_OFFSET :
                    (main_ram_cs  ? WRAM_OFFSET : VRAM_OFFSET );
assign prog_rd     = 0;
assign dump_we     = ioctl_wr & ioctl_ram;
assign ba_wr[3:1]  = 0;

always @(*) begin
    main_addr_x = main_ram_addr;
    `ifdef CPS2
    if( main_oram_cs ) begin
        main_addr_x[17:14]  = 4'd0;
        main_addr_x[13] = main_ram_addr[15] ^ obank;
    end
    `endif
end

jtcps1_prom_we #(
    .CPS        ( CPS           ),
    .REGSIZE    ( REGSIZE       ),
    .CPU_OFFSET ( ROM_OFFSET    ),
    .PCM_OFFSET ( PCM_OFFSET    ),
    .SND_OFFSET ( SND_OFFSET    ),
    // CPS-2 WIDE download-side placement; dead unless wide_en is high
    .PCMH_OFFSET ( PCMH_OFFSET  ),
    .GFXC4_OFFSET( GFXC4_OFFSET ),
    .GFXC5_OFFSET( GFXC5_OFFSET )
) u_prom_we(
    .clk            ( clk           ),
    .wide_en        ( wide_en       ),
    .ioctl_rom      ( ioctl_rom     ),
    .ioctl_addr     ( ioctl_addr    ),
    .ioctl_dout     ( ioctl_dout    ),
    .ioctl_wr       ( ioctl_wr      ),
    .ioctl_ram      ( ioctl_ram     ),
    .prog_addr      ( prog_addr     ),
    .prog_data      ( prog_data     ),
    .prog_mask      ( prog_mask     ),
    .prog_ba        ( prog_ba       ),
    .prog_we        ( prog_we       ),
    .prog_rdy       ( prog_rdy      ),
    .cfg_we         ( cfg_we        ),
    .dwnld_busy     ( dwnld_busy    ),
    // QSound & Kabuki keys
    .prom_we        ( prog_qsnd     ),
    .kabuki_we      ( kabuki_we     ),
    // CPS2
    .cps2_key_we    ( cps2_key_we   ),
    .joymode        ( cps2_joymode  )
);

// CPS-2 WIDE: seven slots. jtframe_ram1_7slots is an ADDITION to
// modules/jtframe/hdl/sdram — a mechanical member of the ram1_Nslots family,
// which upstream stops at 5 (docs/project/mister_map.md section 5, option A).
jtframe_ram1_7slots #(
    .SDRAMW      ( 23            ),
    .SLOT0_AW    ( 17            ), // Main CPU RAM
    .SLOT0_DW    ( 16            ),
    .SLOT0_FASTWR(  0            ),

    .SLOT1_AW    ( 17            ), // VRAM - read only access
    .SLOT1_DW    ( 16            ),
    .SLOT1_LATCH (  OBJ_LATCH    ),
    .SLOT1_DOUBLE(  1            ),
    .SLOT1_OFFSET( VRAM_OFFSET   ),

    .SLOT2_AW    ( 13            ), // Object RAM - read only access
    .SLOT2_DW    ( 16            ),
    .SLOT2_LATCH (  OBJ_LATCH    ),
    .SLOT2_DOUBLE(  1            ),
    .SLOT2_OFFSET( ORAM_OFFSET   ),

    .SLOT3_AW    ( CPS==2 ? 22 : 21 ), // Main CPU ROM. CPS-2 WIDE declares 6 MB,
                                  // so the slot has to reach past 4 MB. The
                                  // extra bit is 0 for every stock address and
                                  // SLOT3_OFFSET is unchanged, so a stock read
                                  // lands on the same SDRAM word.
    .SLOT3_DW    ( 16            ),
    .SLOT3_LATCH (  1            ),
    .SLOT3_DOUBLE(  1            ),
    .SLOT3_OFFSET(  ROM_OFFSET   ),

    .SLOT4_AW    ( Z80_AW        ), // Sound CPU
    .SLOT4_DW    (  8            ),
    .SLOT4_OFFSET(  SND_OFFSET   ),

    .SLOT5_AW    ( 20            ), // CPS-2 WIDE: QSound high window, 1 MB
    .SLOT5_DW    (  8            ),
    .SLOT5_OFFSET(  PCMH_OFFSET  ),

    .SLOT6_AW    ( 22            ), // CPS-2 WIDE: GFX group C, obj bank 5
    .SLOT6_DW    ( 32            ),
    .SLOT6_LATCH (  OBJ_LATCH    ),
    .SLOT6_DOUBLE(  1            ),
    .SLOT6_OFFSET( GFXC5_OFFSET  )
) u_bank0 (
    .rst         ( rst           ),
    .clk         ( clk           ),

    .slot0_offset( main_offset   ),
    .slot0_cs    ( ram_vram_cs   ),
    .slot0_wen   ( !main_rnw     ),
    .slot1_cs    ( vram_dma_cs   ),
    .slot1_clr   ( vram_clr      ),
    .slot2_cs    ( gfx_oram_cs   ),
    .slot2_clr   ( gfx_oram_clr  ),
    .slot3_cs    ( main_rom_cs   ),
    .slot3_clr   ( 1'b0          ),
    .slot4_cs    ( snd_cs        ),
    .slot4_clr   ( 1'b0          ),
    .slot5_cs    ( pcmh_cs       ),
    .slot5_clr   ( 1'b0          ),
    .slot6_cs    ( gfxc5_cs      ),
    .slot6_clr   ( 1'b0          ),

    .slot0_ok    ( main_ram_ok   ),
    .slot1_ok    ( vram_dma_ok   ),
    .slot2_ok    ( gfx_oram_ok   ),
    .slot3_ok    ( main_rom_ok   ),
    .slot4_ok    ( snd_ok        ),
    .slot5_ok    ( pcmh_ok       ),
    .slot6_ok    ( gfxc5_ok      ),

    .slot0_din   ( main_dout     ),
    .slot0_wrmask( dsn           ),

    .slot0_addr  ( main_addr_x   ),
    .slot1_addr  ( vram_dma_addr ),
    .slot2_addr  ( gfx_oram_addr ),
    .slot3_addr  ( main_rom_addr ),
    .slot4_addr  ( snd_addr      ),
    .slot5_addr  ( pcmh_addr     ),
    .slot6_addr  ( gfx0_addr     ),

    .slot0_dout  ( main_ram_data ),
    .slot1_dout  ( vram_dma_data ),
    .slot2_dout  ( gfx_oram_data ),
    .slot3_dout  ( main_rom_data ),
    .slot4_dout  ( snd_data      ),
    .slot5_dout  ( pcmh_data     ),
    .slot6_dout  ( gfxc5_dout    ),

    // SDRAM interface
    .sdram_addr  ( ba0_addr      ),
    .sdram_rd    ( ba_rd[0]      ),
    .sdram_wr    ( ba_wr[0]      ),
    .sdram_ack   ( ba_ack[0]     ),
    .data_dst    ( ba_dst[0]     ),
    .data_rdy    ( ba_rdy[0]     ),
    .data_write  ( ba0_din       ),
    .sdram_wrmask( ba0_dsn       ),
    .data_read   ( data_read     )
);

// CPS-2 WIDE: bank 1 carries the stock 8 MB of PCM at offset 0 — untouched —
// plus GFX group C obj bank 4 above it. Two streams, which is exactly what
// tests/audit_sdram_bank_load.sh modelled when it returned GO.
jtframe_rom_2slots #(
    .SDRAMW      ( 23            ),
    .SLOT0_AW    ( PCM_AW        ), // PCM, DSP sample banks 0x00-0x7F
    .SLOT0_DW    (  8            ),

    .SLOT1_AW    ( 22            ), // CPS-2 WIDE: GFX group C, obj bank 4
    .SLOT1_DW    ( 32            ),
    .SLOT1_LATCH ( OBJ_LATCH     ),
    .SLOT1_DOUBLE( 1             ),
    .SLOT1_OFFSET( GFXC4_OFFSET  )
) u_bank1 (
    .rst         ( rst           ),
    .clk         ( clk           ),

    .slot0_cs    ( pcm_lo_cs     ),
    .slot0_ok    ( pcm_lo_ok     ),
    .slot0_addr  ( pcm_addr[PCM_AW-1:0] ),
    .slot0_dout  ( pcm_lo_data   ),

    .slot1_cs    ( gfxc4_cs      ),
    .slot1_ok    ( gfxc4_ok      ),
    .slot1_addr  ( gfx0_addr     ),
    .slot1_dout  ( gfxc4_dout    ),

    .sdram_addr  ( ba1_addr      ),
    .sdram_rd    ( ba_rd[1]      ),
    .sdram_ack   ( ba_ack[1]     ),
    .data_dst    ( ba_dst[1]     ),
    .data_rdy    ( ba_rdy[1]     ),
    .data_read   ( data_read     )
);

wire [ 1:0] objgfx_cs, objgfx_ok;
wire [31:0] objgfx_dout0, objgfx_dout1;

`ifdef CPS2
    // CPS-2 WIDE: obj banks 4 and 5 (rom0_bank[2]=1) are GROUP C and live in
    // SDRAM banks 1 and 0. Bank 4 -> ba1 (in-match fighter art), bank 5 -> ba0
    // (select/wheel art, cold during a match). rom0_bank[1] is 0 for both, so
    // the 22-bit gfx0_addr covers each 8 MB slice on its own.
    // With wide_en LOW — and, until slice D3, with rom0_bank[2] tied low by
    // the game top — gfxc_sel is 0 and all four lines below are the reference
    // core's expressions exactly.
    assign gfxc_sel  = wide_en & rom0_bank[2];
    assign objgfx_cs = {2{rom0_cs & ~gfxc_sel}} & { rom0_bank[0], ~rom0_bank[0] };
    assign gfxc4_cs  = rom0_cs &  gfxc_sel & ~rom0_bank[0];
    assign gfxc5_cs  = rom0_cs &  gfxc_sel &  rom0_bank[0];
    assign cps2_gfx0 = { rom0_bank[1], gfx0_addr };

    always @(*) begin
        if( gfxc_sel ) begin
            rom0_ok   = rom0_bank[0] ? gfxc5_ok   : gfxc4_ok;
            rom0_data = rom0_bank[0] ? gfxc5_dout : gfxc4_dout;
        end else begin
            rom0_ok   = rom0_bank[0] ? objgfx_ok[1] : objgfx_ok[0];
            rom0_data = rom0_bank[0] ? objgfx_dout1 : objgfx_dout0;
        end
    end

    jtframe_rom_1slot #(
        .SDRAMW      ( 23            ),
        // Slot 0: Obj
        .SLOT0_AW    ( 23            ),
        .SLOT0_DW    ( 32            ),
        .SLOT0_DOUBLE( 1             ),
        .SLOT0_LATCH ( OBJ_LATCH     )
    ) u_bank2 (
        .rst         ( rst           ),
        .clk         ( clk_gfx       ), // do not use clk

        .slot0_cs    ( objgfx_cs[0]  ),
        .slot0_ok    ( objgfx_ok[0]  ),
        .slot0_addr  ( cps2_gfx0     ),
        .slot0_dout  ( objgfx_dout0  ),

        .sdram_addr  ( ba2_addr      ),
        .sdram_rd    ( ba_rd[2]      ),
        .sdram_ack   ( ba_ack[2]     ),
        .data_dst    ( ba_dst[2]     ),
        .data_rdy    ( ba_rdy[2]     ),
        .data_read   ( data_read     )
    );
`else
    assign objgfx_cs = 2'b10;
    always @(*) begin
        rom0_ok   = objgfx_ok[1];
        rom0_data = objgfx_dout1;
    end
    assign cps2_gfx0 = { 1'b0, gfx0_addr };
    assign ba_rd[2] = 0;
    assign ba2_addr = 0;
    // CPS-2 WIDE is CPS-2 only; tie the group-C read path off on CPS1
    assign gfxc_sel = 0;
    assign gfxc4_cs = 0;
    assign gfxc5_cs = 0;
`endif

// 7+15=22
wire [21:0] gfx_star0 = { 1'b0, star_bank, 5'd0, star0_addr, 2'b00 },
            gfx_star1 = { 1'b0, star_bank, 5'd0, star1_addr, 2'b10 };

jtframe_rom_4slots #(
    .SDRAMW      ( 23            ),
    // Slot 0: Obj
    .SLOT0_AW    ( 23            ),
    .SLOT0_DW    ( 32            ),
    .SLOT0_OFFSET( ZERO_OFFSET   ),
    .SLOT0_LATCH ( OBJ_LATCH     ),
    .SLOT0_DOUBLE( 1             ),

    // Slot 1: Scroll
    .SLOT1_AW    ( 22            ),
    .SLOT1_DW    ( 32            ),
    .SLOT1_OFFSET( SCR_OFFSET    ),
    .SLOT1_DOUBLE( 1             ),

    // Slot 2: Stars
    .SLOT2_AW    ( 22            ),
    .SLOT2_DW    ( 32            ),
    .SLOT2_OFFSET( SCR_OFFSET    ),

    // Slot 3: Stars
    .SLOT3_AW    ( 22            ),
    .SLOT3_DW    ( 32            ),
    .SLOT3_OFFSET( SCR_OFFSET    )
) u_bank3 (
    .rst         ( rst           ),
    .clk         ( clk_gfx       ), // do not use clk

    .slot0_cs    ( objgfx_cs[1]  ),
    .slot1_cs    ( rom1_cs       ),

    .slot0_ok    ( objgfx_ok[1]  ),
    .slot1_ok    ( rom1_ok       ),

    .slot0_addr  ( cps2_gfx0     ),
    .slot1_addr  ( gfx1_addr     ),

    .slot0_dout  ( objgfx_dout1  ),
    .slot1_dout  ( rom1_data     ),

    // stars
    .slot2_cs    ( star0_cs      ),
    .slot3_cs    ( star1_cs      ),
    .slot2_ok    ( star0_ok      ),
    .slot3_ok    ( star1_ok      ),
    .slot2_addr  ( gfx_star0     ),
    .slot3_addr  ( gfx_star1     ),
    .slot2_dout  ( star0_data    ),
    .slot3_dout  ( star1_data    ),

    .sdram_addr  ( ba3_addr      ),
    .sdram_rd    ( ba_rd[3]      ),
    .sdram_ack   ( ba_ack[3]     ),
    .data_dst    ( ba_dst[3]     ),
    .data_rdy    ( ba_rdy[3]     ),
    .data_read   ( data_read     )
);

// EEPROM used by Pang 3 and by CPS1.5/2
jt9346_16b8b #(.DW(EEPROM_DW),.AW(EEPROM_AW)) u_eeprom(
    .rst        ( rst       ),  // system reset
    .clk        ( clk       ),  // system clock
    // chip interface
    .sclk       ( sclk      ),  // serial clock
    .sdi        ( sdi       ),  // serial data in
    .sdo        ( sdo       ),  // serial data out and ready/not busy signal
    .scs        ( scs       ),  // chip select, active high. Goes low in between instructions
    // Dump access
    .dump_clk   ( clk       ),  // same as prom_we module
    .dump_addr  ( ioctl_addr[(EEPROM_DW==16?EEPROM_AW+1:EEPROM_AW):0] ),
    .dump_we    ( dump_we   ),
    .dump_din   ( ioctl_dout),
    .dump_dout  ( ioctl_din ),
    .dump_flag  ( dump_flag ),
    .dump_clr   ( ioctl_ram )
);

endmodule
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
    Date: 30-1-2020 */

// ---------------------------------------------------------------------------
// CPS-2 WIDE (Vampire Saved) OVERRIDE of cores/cps1/hdl/jtcps1_prom_we.v.
// Copied at jtcores v1.7.3 (slice D2) because the DOWNLOAD-side placement has
// to change and the file is SHARED with cores/cps1, cores/cps15 and
// cores/cps2 — editing it in place would change the reference cores. The diff
// against the original IS the trust surface (CLAUDE.md rule 1 v2) and is
// frozen line by line by tests/test_mister_wide_gate.sh.
//
// TWO redirects, BOTH behind `wide_en` (the runtime profile bit decoded from
// MRA header byte 41 by jtcps2w_profile.v, slice D1). With `wide_en` LOW both
// `is_gfxc` and `is_pcmhi` are constant 0 and every expression below reduces
// to the reference core's, character for character:
//
//   1. GFX GROUP C -> SDRAM banks 0 and 1. Vanilla's own 32 MB of art fills
//      banks 2+3 exactly (docs/project/mister_map.md section 4), so the
//      profile's group C — GFX region bytes 32-48 MB, i.e. gfx_addr[25]=1 —
//      has nowhere to go there. Obj bank 4 (gfx_addr[23]=0, the three fighter
//      bands) goes to bank 1 above the 8 MB of QSound; obj bank 5
//      (gfx_addr[23]=1, select/wheel art) goes to bank 0. Note gfx_addr[25:21]
//      pass through the CPS-2 address scramble at :105 unchanged, so the test
//      reads the same bit before and after it.
//   2. QSOUND SPLIT on pcm_addr[23]. DSP sample banks 0x00-0x7F (the stock
//      8 MB) stay at bank 1 offset 0 — byte-identical to stock jtcps2 — and
//      banks 0x80+ (which exist only in the WIDE profile) go to a 1 MB window
//      in bank 0. This is not cosmetic: jtframe's 8-bit SDRAM slot caps at
//      SDRAMW=23 = 8 MB (jtframe_romrq_bcache.v:74), so 8.9375 MB is only
//      reachable as TWO slots in two banks. The window is MASKED to its 1 MB
//      so that a region longer than 0x8FFFFF would alias inside the extension
//      instead of overwriting group-C art.
//
// The read side of both is cores/cps2w/hdl/jtcps1_sdram.v.
// ---------------------------------------------------------------------------

module jtcps1_prom_we #(
parameter        CPS=1, // 1, 15, or 2
                 REGSIZE=24, // This is defined at _game level
parameter [22:0] CPU_OFFSET =23'h0,
                 SND_OFFSET =23'h0,
                 PCM_OFFSET =23'h0,
                 GFX_OFFSET =23'h0,
                 // CPS-2 WIDE placement (slice D2). All three are 23-bit WORD
                 // offsets, like the four above, and all three are dead
                 // unless wide_en is high.
                 PCMH_OFFSET  =23'h0, // QSound DSP sample banks 0x80+
                 GFXC4_OFFSET =23'h0, // GFX group C, obj bank 4
                 GFXC5_OFFSET =23'h0, // GFX group C, obj bank 5
parameter [ 5:0] CFG_BYTE   =6'd39  // location of the byte with encoder information
)(
    input                clk,
    input                wide_en,   // CPS-2 WIDE profile (jtcps2w_profile.v)
    input                ioctl_rom,
    input      [25:0]    ioctl_addr,    // max 64 MB
    input      [ 7:0]    ioctl_dout,
    input                ioctl_wr,
    input                ioctl_ram,
    output reg [22:0]    prog_addr,
    output     [15:0]    prog_data,
    output reg [ 1:0]    prog_mask, // active low
    output reg [ 1:0]    prog_ba,
    output reg           prog_we,
    output reg           prom_we,   // for Q-Sound internal ROM
    input                prog_rdy,
    output reg           cfg_we,
    output               dwnld_busy,
    // Kabuki decoder (CPS 1.5)
    output               kabuki_we,
    // CPS2 keys
    output reg           cps2_key_we,
    output reg [ 1:0]    joymode
);

assign dwnld_busy = ioctl_rom;

// The start position header has 16 bytes, from which 6 are actually used and
// 10 are reserved
localparam [25:0] START_BYTES   = 8,
                  START_HEADER  = 16,
                  STARTW        = START_BYTES<<3;

localparam [25:0] FULL_HEADER   = 26'd64,
                  KABUKI_HEADER = 26'd48,
                  KABUKI_END    = KABUKI_HEADER + 26'd11,
                  CPS2_KEYS     = 26'd44,
                  CPS2_END      = 26'd64;

localparam [ 5:0] JOY_BYTE      = 6'h28;

reg  [STARTW-1:0] starts;
wire       [15:0] snd_start, pcm_start, gfx_start, qsnd_start;
reg        [ 7:0] pre_data;
reg        [ 1:0] kabuki_sr; // For 96MHz the write pulse must last two cycles

assign snd_start  = starts[15: 0];
assign pcm_start  = starts[31:16];
assign gfx_start  = starts[47:32];
assign qsnd_start = starts[63:48];
assign prog_data  = {2{pre_data}};
`ifdef CPS15
assign kabuki_we  = kabuki_sr[0];
`else
assign kabuki_we  = 0;
`endif

wire [25:0] bulk_addr = ioctl_addr - FULL_HEADER; // the header is excluded
wire [25:0] cpu_addr  = bulk_addr ; // the header is excluded
wire [25:0] snd_addr  = bulk_addr - { snd_start[15:0], 10'd0 };
wire [25:0] pcm_addr  = bulk_addr - { pcm_start[15:0], 10'd0 };
reg  [25:0] gfx_addr;
reg  [ 1:0] gfx_bank;

wire is_cps    = ioctl_addr > 7 && ioctl_addr < (REGSIZE+START_HEADER);
wire is_kabuki = ioctl_addr >= KABUKI_HEADER && ioctl_addr < KABUKI_END;
wire is_cps2   = ioctl_addr >= CPS2_KEYS && ioctl_addr < CPS2_END;
wire is_cpu    = bulk_addr[25:10] < snd_start;
wire is_snd    = bulk_addr[25:10] < pcm_start  && bulk_addr[25:10] >=snd_start;
wire is_oki    = bulk_addr[25:10] < gfx_start  && bulk_addr[25:10] >=pcm_start;
wire is_gfx    = bulk_addr[25:10] < qsnd_start && bulk_addr[25:10] >=gfx_start;
wire is_qsnd   = ioctl_addr >= FULL_HEADER && bulk_addr[25:10] >=qsnd_start; // Q-Sound ROM

reg       decrypt, pang3, pang3_bit;
reg [7:0] pang3_decrypt;

// ---- CPS-2 WIDE (Vampire Saved), slice D2 --------------------------------
reg  [22:0] gfxc_addr, pcmh_addr;
reg  [ 1:0] gfxc_ba;
// group C is GFX region bytes 32-48 MB; is_gfx already bounds the region
wire is_gfxc  = wide_en & gfx_addr[25];
// DSP sample bank 0x80+; is_oki already bounds the region
wire is_pcmhi = wide_en & pcm_addr[23];

always @(*) begin
    gfx_addr  = bulk_addr - { gfx_start, 10'd0 };
`ifdef CPS2
    // CPS2 address lines are scrambled
    gfx_addr = { gfx_addr[25:21], gfx_addr[3], gfx_addr[20:4], gfx_addr[2:0] };
    gfx_bank = { 1'b1, gfx_addr[23]};
`else
    gfx_bank  = 2'b11;
`endif
end

always @(*) begin
    // obj bank 5 -> SDRAM bank 0, obj bank 4 -> SDRAM bank 1
    gfxc_ba   = gfx_addr[23] ? 2'd0 : 2'd1;
    gfxc_addr = {1'b0, gfx_addr[22:1]} +
                (gfx_addr[23] ? GFXC5_OFFSET : GFXC4_OFFSET);
    // the high window is 1 MB and the address is masked to it
    pcmh_addr = {4'd0, pcm_addr[19:1]} + PCMH_OFFSET;
end


// The decryption is literally copied from MAME, it is up to
// the synthesizer to optimize the code. And it will.
always @(*) begin
    if( CPS==1 ) begin
        pang3 = is_cpu && cpu_addr[19] && decrypt  && (cpu_addr[0]^pang3_bit);
        pang3_decrypt =
            (((((((ioctl_dout[0] ? 8'h04 : 8'h00)  ^
                  (ioctl_dout[1] ? 8'h21 : 8'h00)) ^
                  (ioctl_dout[2] ? 8'h01 : 8'h00)) ^
                  (ioctl_dout[3] ? 8'h00 : 8'h50)) ^
                  (ioctl_dout[4] ? 8'h40 : 8'h00)) ^
                  (ioctl_dout[5] ? 8'h06 : 8'h00)) ^
                  (ioctl_dout[6] ? 8'h08 : 8'h00)) ^
                  (ioctl_dout[7] ? 8'h00 : 8'h88);
    end else begin
        pang3 = 0;
        pang3_decrypt = 8'd0;
    end
end

always @(posedge clk) begin
    if ( ioctl_wr && !ioctl_ram ) begin
        pre_data  <= pang3 ?
            pang3_decrypt : ioctl_dout;
        prog_mask <= !ioctl_addr[0] ? 2'b10 : 2'b01;
        // CPS-2 WIDE: the two `is_pcmhi`/`is_gfxc` arms are the ONLY
        // difference from the reference core, and both are 0 when wide_en is 0
        prog_addr <= is_cpu ? bulk_addr[23:1] + CPU_OFFSET : (
                     is_snd ?  snd_addr[23:1] + SND_OFFSET : (
                     is_oki ? (is_pcmhi ? pcmh_addr : pcm_addr[23:1] + PCM_OFFSET) :
                     is_gfx ? (is_gfxc  ? gfxc_addr : {gfx_addr[24],gfx_addr[22:1]} + GFX_OFFSET) : {10'd0, bulk_addr[12:0]}));
        prog_ba   <= (is_cpu||is_snd) ? 2'd0 : (
                      is_gfx ? (is_gfxc ? gfxc_ba : gfx_bank) : (
                      (is_oki & is_pcmhi) ? 2'd0 : 2'd1 ));
        if( is_kabuki )
            kabuki_sr <= 2'b11;
        if( is_cps2 ) begin
            cps2_key_we <= 1;
        end
        if( ioctl_addr < START_BYTES ) begin
            starts  <= { ioctl_dout, starts[STARTW-1:8] };
            cfg_we  <= 1'b0;
            prog_we <= 1'b0;
            prom_we <= 1'b0;
        end else begin
            if( is_cps ) begin
                cfg_we    <= 1'b1;
                prog_we   <= 1'b0;
                prom_we   <= 1'b0;
                if( ioctl_addr[5:0] == CFG_BYTE )
                    {decrypt, pang3_bit} <= ioctl_dout[7:6];
            end else if(ioctl_addr>=FULL_HEADER) begin
                cfg_we    <= 1'b0;
                prog_we   <= ~is_qsnd;
                prom_we   <=  is_qsnd;
            end else if( ioctl_addr[5:0] == JOY_BYTE ) begin
                joymode <= ioctl_dout[1:0]; // only CPS2
            end
        end
    end
    else begin
        cps2_key_we <= 0;
        if(!ioctl_rom || prog_rdy) prog_we  <= 1'b0;
        if( !ioctl_rom ) begin
            decrypt    <= 0;
            prom_we    <= 0;
        end
        kabuki_sr <= kabuki_sr>>1;
        cfg_we    <= 0;
    end
end

endmodule
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
    Date: 24-1-2021 */

// ---------------------------------------------------------------------------
// CPS-2 WIDE (Vampire Saved) OVERRIDE of cores/cps2/hdl/jtcps2_obj_scan.v.
// SLICE D3 — THE OBJ PROMOTE. Copied at jtcores v1.7.3; the file is SHARED
// with cores/cps2, so editing it in place would change the reference core.
// The diff against the original IS the trust surface (CLAUDE.md rule 1 v2)
// and is frozen line by line by tests/test_mister_wide_gate.sh.
//
// WHAT CHANGES, AND WHY IT IS THE ONLY SHAPE THAT WORKS. Stock CPS-2 reads the
// object's GFX bank from two bits of the frame table's y-word,
// `st3_bank <= table_y[14:13]`, so a 16-bit tile code plus a 2-bit bank is an
// 18-bit tile address = 32 MB of graphics. CPS-2 WIDE v1 needs 48 MB, i.e. a
// THIRD bank bit, and the free bit is y bit 12 — but it can only be read
// AFTER the sprite-list terminator test above, and that ordering is the whole
// of the rule:
//
//   * y bit 15 is the sprite-list TERMINATOR (`:141` below, unchanged). The
//     profile's first draft proposed reading bank bit 2 from bit 15 directly;
//     setting that bit on a live sprite ENDS THE LIST and drops every later
//     sprite (docs/project/cps2_wide.md, Correction A2).
//   * Capcom hit the same wall on CPS-2 Turbo and solved it the same way:
//     test bit 15 first, THEN promote bit 12 into it, then read a 3-bit bank
//     from bits 15:13. Inside the `else` arm below bit 15 is known to be 0,
//     so the promoted bank is exactly { y[12], y[14:13] }.
//   * That is why the build emits bank 4 as y-word 0x1000 and bank 5 as
//     0x3000 (tools/gfx_tiles.py `bank_word`) and NOT `bank << 13`, which
//     would be 0x8000 — a terminator.
//
// GATED. The promote is ANDed with `wide_en` (the runtime MRA header bit,
// slice D1), so with the profile clear `st3_bank[2]` is 0 and bits [1:0] are
// the stock expression, character for character. The reference core is
// untouched by construction, not by measurement.
// ---------------------------------------------------------------------------

module jtcps2_obj_scan(
    input              rst,
    input              clk,
    input              flip,
    input              wide_en,     // CPS-2 WIDE profile (jtcps2w_profile.v)

    input      [ 8:0]  vrender1, // 2 lines ahead of vdump
    input      [ 8:0]  hdump,
    output reg         line,

    input      [ 9:0]  off_x,
    input      [ 9:0]  off_y,

    // interface with frame table
    output reg [ 9:0]  table_addr,
    input      [15:0]  table_x,
    input      [15:0]  table_y,
    input      [15:0]  table_code,
    input      [15:0]  table_attr,

    // interface with renderer
    output reg         dr_start,    // dr for "draw"
    input              dr_idle,

    output reg [15:0]  dr_code,
    output reg [15:0]  dr_attr,
    output reg [ 8:0]  dr_hpos,
    output reg [ 2:0]  dr_prio,
    output reg [ 2:0]  dr_bank
);

reg  [ 9:0] mapper_in;
reg  [ 8:0] vrenderf;

reg  [ 9:0] obj_y, obj_x;
wire [15:0] code_mn;
wire [ 9:0] st4_effx;
reg  [ 2:0] st3_bank, st4_bank;
reg  [ 2:0] st3_prio, st4_prio;
wire        start;

reg         done;
wire [ 3:0] st3_tile_n, st4_tile_n, st3_tile_m;
reg  [ 3:0] npos;  // tile expansion n==horizontal, m==vertical
wire [ 2:0] promoted_bank;   // CPS-2 WIDE: the 3-bit obj bank, gated
reg  [ 4:0] n;
wire [ 3:0] subn;
wire [ 3:0] st4_vsub;
wire        inzone, inzonex, st3_vflip;
reg  [ 2:0] wait_cycle;
reg         last_tile;
reg         last_start;
wire        stall, nstall;
reg         cen=0;

reg  [15:0] st3_code, st3_attr, st4_attr;
reg  [ 9:0] st3_y, st3_x, st4_x;

// CPS-2 WIDE: the CPS-2 Turbo promote. It is READ in the `else` arm of the
// terminator test below, so bit 15 is known to be 0 there — which is the
// whole of the rule. See cores/cps2w/hdl/jtcps2w_obj_bank.v.
jtcps2w_obj_bank u_objbank(
    .wide_en    ( wide_en       ),
    .table_y    ( table_y       ),
    .bank       ( promoted_bank )
);

jtcps1_obj_tile_match u_tile_match(
    .rst        ( rst        ),
    .clk        ( clk        ),
    .cen        ( ~stall & cen    ),

    .obj_code   ( st3_code   ),
    .tile_m     ( st3_tile_m ),
    .tile_n     ( st3_tile_n ),
    .n          ( 4'd0       ),

    .vflip      ( st3_vflip  ),
    .vrenderf   ( vrenderf   ),
    .obj_y      ( st3_y      ),

    .vsub       ( st4_vsub   ),
    .inzone     ( inzone     ),
    .code_mn    ( code_mn    )
);

assign      start      = hdump == 'h1d0;

assign      st3_tile_m = st3_attr[15:12];
assign      st3_tile_n = st3_attr[11: 8];
assign      st3_vflip  = st3_attr[6];

assign      st4_tile_n = st4_attr[11: 8];
wire        st4_hflip  = st4_attr[5];
assign      subn       = (st4_hflip ? ( st4_tile_n - n[3:0] ) : n[3:0]);
assign      st4_effx   = st4_x + { 2'b0, subn, 4'd0 }; // effective x value for multi tile objects
assign      nstall     = n<={1'b0,st4_tile_n} && st4_tile_n!=0;
assign      stall      = (inzone && (!dr_idle || nstall));// || dr_start;

// the div-2 clock enable is needed because of the table_* signal latency
// If the OBJ RAM didn't have an output latch, or if the latch had a clock enable
// to control with the stall signal, the cen could be removed
always @(posedge clk) cen <= ~cen;

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        table_addr <= 0;
        n          <= 0;
        npos       <= 0;
        dr_start   <= 0;
        dr_code    <= 0;
        dr_attr    <= 0;
        dr_hpos    <= 0;
        dr_prio    <= 0;
        last_start <= 0;
        line       <= 0;
        done       <= 1;

        st3_x      <= 0;
        st4_x      <= 0;
        st3_y      <= 0;
        // st4_y      <= 0;
        st3_code   <= 0;
        st3_attr   <= 0;
        st4_attr   <= 0;
    end else if(cen) begin
        last_start <= start;

        if( !stall ) begin
        // I
            table_addr <= done ? 10'd0 : (table_addr+1'd1);
        // II
            if( table_y[15] || table_attr[15:8]==8'hff || &table_addr ) begin
                done     <= 1;
                st3_x    <= 0;
                st3_y    <= 0;
                st3_attr <= 0;
            end else begin
                st3_code <= table_code;
                st3_x    <= done ? 10'd0 : table_x[9:0] + 10'h40 - (table_attr[7] ? 10'd0 : off_x);
                st3_y    <= done ? 10'd0 : table_y[9:0] + 10'h10 - (table_attr[7] ? 10'd0 : off_y);
                st3_attr <= done ? 16'd0 : table_attr;
                st3_prio <= table_x[15:13];
                // CPS-2 WIDE: the 19th tile-address bit, promoted from y[12]
                // AFTER the terminator test above (which is why it is not read
                // from y[15]). Lifted into its own module so it can be swept
                // exhaustively; wide_en clear => the stock 2-bit bank.
                st3_bank <= promoted_bank;
            end
        // III
            st4_attr <= st3_attr;
            st4_x    <= st3_x;
            // st4_y    <= st3_y;
            st4_bank <= st3_bank;
            st4_prio <= st3_prio;
        end
        // IV
        if( inzone ) begin
            if( dr_idle ) begin
                dr_attr  <= { 4'd0, st4_vsub, st4_attr[7:0] };
                dr_code  <= { code_mn[15:4], code_mn[3:0]+n[3:0]};
                dr_hpos  <= st4_effx[8:0] - 9'd1;
                dr_prio  <= st4_prio;
                dr_bank  <= st4_bank;
                dr_start <= n <= {1'b0,st4_tile_n} && !st4_effx[9];
                if( !nstall ) begin
                    n    <= 0;
                    npos <= 0;
                end else begin
                    n    <= n+1'd1;
                    npos <= st4_hflip ? npos-4'd1 : npos+4'd1;
                end
            end else begin
                dr_start <= 0;
            end
        end else begin
            dr_start <= 0;
        end

        // This must be at the end
        if( start && !last_start ) begin
            line       <= ~line;
            vrenderf   <= vrender1 ^ {1'b0,{8{flip}}};
            n          <= 0;
            npos       <= 0;
            done       <= 0;
            table_addr <= 0;
        end
    end
end

endmodule

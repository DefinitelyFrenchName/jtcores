/*  This file is part of JTFRAME.
    JTFRAME program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTFRAME program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTFRAME.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 1-12-2020

    ADDED by the Vampire Saved project (CPS-2 WIDE), 2026-08-24. This file is
    a MECHANICAL member of the existing jtframe_ram1_Nslots family: it is
    jtframe_ram1_5slots.v with two more read-only slots, and nothing else.
    Slot 0 keeps the read/WRITE port (jtframe_ram_rq); slots 1..6 are
    jtframe_romrq, in descending priority. Nothing that already existed was
    modified: the family had 1..5, upstream simply has no 7-slot member, and
    the CPS-2 WIDE bank-0 map needs seven streams (RAM/VRAM/ORAM RW, VRAM DMA,
    gfx-ORAM, main ROM, Z80, QSound high window, GFX group-C obj bank 5).
    See docs/project/mister_map.md section 5, "Slot count", option A.        */

module jtframe_ram1_7slots #(parameter
    SDRAMW = 22,
    SLOT0_FASTWR = 0,

    SLOT0_DW = 8, SLOT1_DW = 8, SLOT2_DW = 8, SLOT3_DW = 8, SLOT4_DW = 8,
    SLOT5_DW = 8, SLOT6_DW = 8,
    SLOT0_AW = 8, SLOT1_AW = 8, SLOT2_AW = 8, SLOT3_AW = 8, SLOT4_AW = 8,
    SLOT5_AW = 8, SLOT6_AW = 8,

    SLOT1_LATCH  = 0,
    SLOT2_LATCH  = 0,
    SLOT3_LATCH  = 0,
    SLOT4_LATCH  = 0,
    SLOT5_LATCH  = 0,
    SLOT6_LATCH  = 0,

    SLOT1_DOUBLE = 0,
    SLOT2_DOUBLE = 0,
    SLOT3_DOUBLE = 0,
    SLOT4_DOUBLE = 0,
    SLOT5_DOUBLE = 0,
    SLOT6_DOUBLE = 0,

    SLOT1_OKLATCH= 1,
    SLOT2_OKLATCH= 1,
    SLOT3_OKLATCH= 1,
    SLOT4_OKLATCH= 1,
    SLOT5_OKLATCH= 1,
    SLOT6_OKLATCH= 1,

    CACHE1_SIZE = 0,
    CACHE2_SIZE = 0,
    CACHE3_SIZE = 0,
    CACHE4_SIZE = 0,
    CACHE5_SIZE = 0,
    CACHE6_SIZE = 0,
/* verilator lint_off WIDTH */
    parameter [SDRAMW-1:0] SLOT1_OFFSET = 0,
    parameter [SDRAMW-1:0] SLOT2_OFFSET = 0,
    parameter [SDRAMW-1:0] SLOT3_OFFSET = 0,
    parameter [SDRAMW-1:0] SLOT4_OFFSET = 0,
    parameter [SDRAMW-1:0] SLOT5_OFFSET = 0,
    parameter [SDRAMW-1:0] SLOT6_OFFSET = 0,
/* verilator lint_on WIDTH */

    parameter REF_FILE="sdram_bank3.hex"
)(
    input               rst,
    input               clk,

    input  [SLOT0_AW-1:0] slot0_addr,
    input  [SLOT1_AW-1:0] slot1_addr,
    input  [SLOT2_AW-1:0] slot2_addr,
    input  [SLOT3_AW-1:0] slot3_addr,
    input  [SLOT4_AW-1:0] slot4_addr,
    input  [SLOT5_AW-1:0] slot5_addr,
    input  [SLOT6_AW-1:0] slot6_addr,

    //  output data
    output [SLOT0_DW-1:0] slot0_dout,
    output [SLOT1_DW-1:0] slot1_dout,
    output [SLOT2_DW-1:0] slot2_dout,
    output [SLOT3_DW-1:0] slot3_dout,
    output [SLOT4_DW-1:0] slot4_dout,
    output [SLOT5_DW-1:0] slot5_dout,
    output [SLOT6_DW-1:0] slot6_dout,

    input    [SDRAMW-1:0] slot0_offset,

    input               slot0_cs,
    input               slot1_cs,
    input               slot2_cs,
    input               slot3_cs,
    input               slot4_cs,
    input               slot5_cs,
    input               slot6_cs,

    output              slot0_ok,
    output              slot1_ok,
    output              slot2_ok,
    output              slot3_ok,
    output              slot4_ok,
    output              slot5_ok,
    output              slot6_ok,

    // Slot 0 accepts 16-bit writes
    input               slot0_wen,
    input [SLOT0_DW-1:0] slot0_din,
    input [1:0]         slot0_wrmask,

    // Slot 1-6 cache can be cleared
    input               slot1_clr,
    input               slot2_clr,
    input               slot3_clr,
    input               slot4_clr,
    input               slot5_clr,
    input               slot6_clr,

    // SDRAM controller interface
    input               sdram_ack,
    output              sdram_rd,
    output              sdram_wr,
    output [SDRAMW-1:0] sdram_addr,
    input               data_rdy,
    input               data_dst,
    input       [15:0]  data_read,
    output      [15:0]  data_write,  // only 16-bit writes
    output      [ 1:0]  sdram_wrmask // each bit is active low
);

localparam SW=7;

wire [SW-1:0] req, slot_ok;
wire [SW-1:0] slot_sel;
wire          req_rnw; // slot 0

wire [SDRAMW-1:0] slot0_addr_req,
                  slot1_addr_req,
                  slot2_addr_req,
                  slot3_addr_req,
                  slot4_addr_req,
                  slot5_addr_req,
                  slot6_addr_req;

assign slot0_ok = slot_ok[0];
assign slot1_ok = slot_ok[1];
assign slot2_ok = slot_ok[2];
assign slot3_ok = slot_ok[3];
assign slot4_ok = slot_ok[4];
assign slot5_ok = slot_ok[5];
assign slot6_ok = slot_ok[6];

jtframe_ram_rq #(.SDRAMW(SDRAMW),.AW(SLOT0_AW),.DW(SLOT0_DW),.FASTWR(SLOT0_FASTWR)) u_slot0(
    .rst       ( rst                    ),
    .clk       ( clk                    ),
    .addr      ( slot0_addr             ),
    .addr_ok   ( slot0_cs               ),
    .offset    ( slot0_offset           ),
    .wrdata    ( slot0_din              ),
    .wrin      ( slot0_wen              ),
    .req_rnw   ( req_rnw                ),
    .sdram_addr( slot0_addr_req         ),
    .din       ( data_read              ),
    .din_ok    ( data_rdy               ),
    .dst       ( data_dst               ),
    .dout      ( slot0_dout             ),
    .req       ( req[0]                 ),
    .data_ok   ( slot_ok[0]             ),
    .we        ( slot_sel[0]            )
);

jtframe_romrq #(.SDRAMW(SDRAMW),.AW(SLOT1_AW),.DW(SLOT1_DW),
    .LATCH(SLOT1_LATCH),.DOUBLE(SLOT1_DOUBLE),.OKLATCH(SLOT1_OKLATCH),
    .CACHE_SIZE(CACHE1_SIZE))
u_slot1(
    .rst       ( rst                    ),
    .clk       ( clk                    ),
    .clr       ( slot1_clr              ),
    .offset    ( SLOT1_OFFSET           ),
    .addr      ( slot1_addr             ),
    .addr_ok   ( slot1_cs               ),
    .sdram_addr( slot1_addr_req         ),
    .din       ( data_read              ),
    .din_ok    ( data_rdy               ),
    .dst       ( data_dst               ),
    .dout      ( slot1_dout             ),
    .req       ( req[1]                 ),
    .data_ok   ( slot_ok[1]             ),
    .we        ( slot_sel[1]            )
);

jtframe_romrq #(.SDRAMW(SDRAMW),.AW(SLOT2_AW),.DW(SLOT2_DW),
    .LATCH(SLOT2_LATCH),.DOUBLE(SLOT2_DOUBLE),.OKLATCH(SLOT2_OKLATCH),
    .CACHE_SIZE(CACHE2_SIZE))
u_slot2(
    .rst       ( rst                    ),
    .clk       ( clk                    ),
    .clr       ( slot2_clr              ),
    .offset    ( SLOT2_OFFSET           ),
    .addr      ( slot2_addr             ),
    .addr_ok   ( slot2_cs               ),
    .sdram_addr( slot2_addr_req         ),
    .din       ( data_read              ),
    .din_ok    ( data_rdy               ),
    .dst       ( data_dst               ),
    .dout      ( slot2_dout             ),
    .req       ( req[2]                 ),
    .data_ok   ( slot_ok[2]             ),
    .we        ( slot_sel[2]            )
);

jtframe_romrq #(.SDRAMW(SDRAMW),.AW(SLOT3_AW),.DW(SLOT3_DW),
    .LATCH(SLOT3_LATCH),.DOUBLE(SLOT3_DOUBLE),.OKLATCH(SLOT3_OKLATCH),
    .CACHE_SIZE(CACHE3_SIZE))
u_slot3(
    .rst       ( rst                    ),
    .clk       ( clk                    ),
    .clr       ( slot3_clr              ),
    .offset    ( SLOT3_OFFSET           ),
    .addr      ( slot3_addr             ),
    .addr_ok   ( slot3_cs               ),
    .sdram_addr( slot3_addr_req         ),
    .din       ( data_read              ),
    .din_ok    ( data_rdy               ),
    .dst       ( data_dst               ),
    .dout      ( slot3_dout             ),
    .req       ( req[3]                 ),
    .data_ok   ( slot_ok[3]             ),
    .we        ( slot_sel[3]            )
);

jtframe_romrq #(.SDRAMW(SDRAMW),.AW(SLOT4_AW),.DW(SLOT4_DW),
    .LATCH(SLOT4_LATCH),.DOUBLE(SLOT4_DOUBLE),.OKLATCH(SLOT4_OKLATCH),
    .CACHE_SIZE(CACHE4_SIZE))
u_slot4(
    .rst       ( rst                    ),
    .clk       ( clk                    ),
    .clr       ( slot4_clr              ),
    .offset    ( SLOT4_OFFSET           ),
    .addr      ( slot4_addr             ),
    .addr_ok   ( slot4_cs               ),
    .sdram_addr( slot4_addr_req         ),
    .din       ( data_read              ),
    .din_ok    ( data_rdy               ),
    .dst       ( data_dst               ),
    .dout      ( slot4_dout             ),
    .req       ( req[4]                 ),
    .data_ok   ( slot_ok[4]             ),
    .we        ( slot_sel[4]            )
);

jtframe_romrq #(.SDRAMW(SDRAMW),.AW(SLOT5_AW),.DW(SLOT5_DW),
    .LATCH(SLOT5_LATCH),.DOUBLE(SLOT5_DOUBLE),.OKLATCH(SLOT5_OKLATCH),
    .CACHE_SIZE(CACHE5_SIZE))
u_slot5(
    .rst       ( rst                    ),
    .clk       ( clk                    ),
    .clr       ( slot5_clr              ),
    .offset    ( SLOT5_OFFSET           ),
    .addr      ( slot5_addr             ),
    .addr_ok   ( slot5_cs               ),
    .sdram_addr( slot5_addr_req         ),
    .din       ( data_read              ),
    .din_ok    ( data_rdy               ),
    .dst       ( data_dst               ),
    .dout      ( slot5_dout             ),
    .req       ( req[5]                 ),
    .data_ok   ( slot_ok[5]             ),
    .we        ( slot_sel[5]            )
);

jtframe_romrq #(.SDRAMW(SDRAMW),.AW(SLOT6_AW),.DW(SLOT6_DW),
    .LATCH(SLOT6_LATCH),.DOUBLE(SLOT6_DOUBLE),.OKLATCH(SLOT6_OKLATCH),
    .CACHE_SIZE(CACHE6_SIZE))
u_slot6(
    .rst       ( rst                    ),
    .clk       ( clk                    ),
    .clr       ( slot6_clr              ),
    .offset    ( SLOT6_OFFSET           ),
    .addr      ( slot6_addr             ),
    .addr_ok   ( slot6_cs               ),
    .sdram_addr( slot6_addr_req         ),
    .din       ( data_read              ),
    .din_ok    ( data_rdy               ),
    .dst       ( data_dst               ),
    .dout      ( slot6_dout             ),
    .req       ( req[6]                 ),
    .data_ok   ( slot_ok[6]             ),
    .we        ( slot_sel[6]            )
);

jtframe_ramslot_ctrl #(
    .SDRAMW     (SDRAMW     ),
    .SW         ( SW        ),
    .DW0        ( SLOT0_DW  )
)u_ctrl(
    .rst            ( rst       ),
    .clk            ( clk       ),
    .req            ( req       ),
    .slot_addr_req  ({ slot6_addr_req, slot5_addr_req, slot4_addr_req,
                       slot3_addr_req, slot2_addr_req,
                       slot1_addr_req, slot0_addr_req }),
    .req_rnw        ( req_rnw   ),        // only for slot0
    .slot_din       ( slot0_din ),
    .wrmask        (slot0_wrmask),   // only used if DW!=8
    .slot_sel       ( slot_sel  ),
    // SDRAM controller interface
    .sdram_ack      ( sdram_ack     ),
    .sdram_rd       ( sdram_rd      ),
    .sdram_wr       ( sdram_wr      ),
    .sdram_addr     ( sdram_addr    ),
    .data_rdy       ( data_rdy      ),
    .data_write     ( data_write    ),
    .sdram_wrmask   ( sdram_wrmask  )
);

endmodule

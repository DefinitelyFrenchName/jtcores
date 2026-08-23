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

    Author: the Vampire Saved project (CPS-2 WIDE), 2026
    Date: 23-8-2026 */

// jtcps2w_qsnd_bank — THE QSOUND SAMPLE-BANK LATCH, PROFILE-GATED.
//
// THE DEFECT IT FIXES. `cores/cps15/hdl/jtcps15_sound.v` latches
//
//     qsnd_addr[22:16] <= dsp_ab[6:0];
//
// i.e. SEVEN bank bits, so DSP sample bank 0x8N aliases onto 0x0N. The CPS-2
// WIDE profile puts its QSound extension in banks 0x80-0x8E, which on the
// stock core would therefore MIS-PLAY legacy audio rather than go silent.
//
// THE BANK BIT IS `dsp_ab[7]`, AND THAT IS MEASURED, NOT ASSUMED. The
// commented-out alternative left in jtcps15_sound.v:416-417 shows the original
// author was unsure of the permutation. MAME's low-level QSound device settles
// it: `emu/mame/src/devices/sound/qsound.cpp` maps the DSP16A external ROM
// space as `map(0x0000, 0x7fff).mirror(0x8000)` and then latches
// `m_rom_bank = (m_rom_bank & 0x8000U) | offset;`, where `offset` is the
// external-space address with the mirror bit removed — a STRAIGHT BINARY
// bank number in ab[14:0], no permutation and no gaps. Sample bytes are then
// read at `(u32(m_rom_bank) << 16) | m_rom_offset`. So bank bit 7 is ab[7],
// bank bit 8 would be ab[8], and the latch can be widened one bit at a time.
// `dsp_ab` is 16 bits and only `dsp_ab[15]` is consumed elsewhere (as the
// external-space strobe), so bits 7..14 are free.
//
// WHY IT IS ITS OWN MODULE. It is the whole of the D1 trust surface: one
// gated expression, exhaustively testable on its own over all 65,536 values
// of `dsp_ab` in both profile states (tests/test_mister_wide_gate.sh). With
// `wide_en` LOW the expression is bit-for-bit the stock one, including the
// reset value, so the reference behaviour is preserved BY CONSTRUCTION and
// not by measurement.

module jtcps2w_qsnd_bank(
    input             rst,
    input             clk,        // clk96, as in jtcps15_sound
    input             cen_cko,    // dsp_cen_cko
    input             wide_en,    // the profile gate; see jtcps2w_profile.v
    input      [15:0] dsp_ab,
    output reg [ 7:0] bank        // qsnd_addr[23:16]
);

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        bank <= 8'd0;
    end else if( dsp_ab[15] && cen_cko ) begin
        bank <= wide_en ? dsp_ab[7:0]      // 16 MB: banks 0x00-0xFF
                        : { 1'b0, dsp_ab[6:0] };  // stock: 8 MB, banks 0x00-0x7F
    end
end

endmodule

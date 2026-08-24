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
    Date: 24-8-2026 */

// jtcps2w_obj_bank — THE OBJECT GFX BANK, PROMOTED AND PROFILE-GATED.
//
// THE CAP IT LIFTS. Stock CPS-2 reads an object's graphics bank from two bits
// of the frame table's y-word — `st3_bank <= table_y[14:13]` in
// cores/cps2/hdl/jtcps2_obj_scan.v — so a 16-bit tile code plus a 2-bit bank
// is an 18-bit tile address: 2^18 tiles x 128 B = 32 MB, and that is the whole
// of the graphics the object engine can reach. CPS-2 WIDE v1 declares 48 MB,
// so it needs a THIRD bank bit.
//
// WHY BIT 12, AND WHY THE ORDER MATTERS MORE THAN THE BIT. y bit 15 is the
// sprite-list TERMINATOR (jtcps2_obj_scan.v:141, `if( table_y[15] || ... )
// done <= 1`). The profile's first draft proposed simply widening the mask to
// read bits 15:13 as the bank; setting bit 15 on a live sprite ENDS THE LIST
// and drops every later sprite, so bank values 4-7 would have been unusable
// (docs/project/cps2_wide.md, Correction A2). Capcom hit the same wall on
// CPS-2 Turbo and solved it by PROMOTING: test bit 15 first, then copy bit 12
// into it, then read a 3-bit bank. This module is the second and third steps;
// the caller has already done the first, so inside it bit 15 is known to be 0
// and the promoted bank is exactly { y[12], y[14:13] }.
//
// THE ENCODING THIS PRODUCES, and the one it does NOT:
//
//     bank 0 -> y 0x0000    bank 4 -> y 0x1000    (NOT 0x8000)
//     bank 1 -> y 0x2000    bank 5 -> y 0x3000    (NOT 0xA000)
//     bank 2 -> y 0x4000
//     bank 3 -> y 0x6000
//
// `bank << 13` would put bank 4 at 0x8000, which IS the terminator — the
// sprite list would end at the first tenant sprite. tools/gfx_tiles.py's
// `bank_word` emits the left column and says so in its own docstring; this
// module is the hardware half of that contract and the two are checked
// against each other in tests/rtl/tb_obj_bank.v.
//
// WHY IT IS ITS OWN MODULE. Same reason as jtcps2w_qsnd_bank: it is the whole
// behavioural surface of slice D3 in one expression, so it can be exercised
// over its ENTIRE input space — all 65,536 y-words in both profile states —
// rather than at whatever sprites one 60-minute core simulation happens to
// draw. With `wide_en` LOW bit 2 is zero for every input, so the reference
// core's 2-bit bank is preserved BY CONSTRUCTION.

module jtcps2w_obj_bank(
    input             wide_en,    // the profile gate; see jtcps2w_profile.v
    input      [15:0] table_y,    // the OBJ frame table's y-word
    output     [ 2:0] bank        // GFX bank, 0-7 (WIDE v1 declares 0-5)
);

assign bank = { wide_en & table_y[12], table_y[14:13] };

endmodule

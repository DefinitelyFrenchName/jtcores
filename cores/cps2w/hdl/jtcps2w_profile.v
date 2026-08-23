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

// jtcps2w_profile — THE RUNTIME PROFILE GATE OF THE CPS-2 WIDE CORE.
//
// WHY THIS MODULE EXISTS AT ALL. jtcps2w is a SEPARATE core from jtcps2, but
// it must still run the STOCK, unmodified romsets exactly as the reference
// core does — that is the emulator superset invariant, and on FPGA the only
// way to have it BY CONSTRUCTION (rather than as an inertness argument about
// bits that "should" never be set) is for the widened behaviour to be OFF
// unless the download says otherwise. So the profile is selected at RUNTIME,
// from the MRA, not by an `ifdef` at synthesis time. A stock MRA on this RBF
// is a stock machine.
//
// WHERE THE BIT LIVES. jtframe's ROM header is 44 bytes on CPS-2
// (JTFRAME_HEADER=44). jtcps1_prom_we.v consumes bytes 0-7 (the four region
// start words), 8-39 (the CPS config registers, `is_cps`) and 40 (JOY_BYTE);
// bytes 41-43 fall through every branch of its decoder and are IGNORED, and
// bytes 44-63 are the CPS-2 key. Byte 41 is therefore free at this pin, and
// the header comment at jtcps1_prom_we.v:52-54 ("6 are actually used and 10
// are reserved") is the licence to use it.
//
// WHY ACTIVE LOW — this is not a style choice. `cores/cps2/cfg/mame2mra.toml`
// declares `[header] fill=0xff`, so every byte a machine does not explicitly
// write is 0xFF, and the stock `vsavj` MRA emitted by this core has to stay
// BYTE-IDENTICAL to the reference core's (tests/test_mister_mra_map.sh). The
// only polarity that leaves stock MRAs untouched is one where the FILL means
// "profile off". jtframe's own JOY_BYTE works exactly this way: 0xFF is
// joystick mode 3 and the games that want mode 0 write 0xFC.
//
// So: header byte 41 bit 0 CLEAR = CPS-2 WIDE. The WIDE MRA writes 0xFE.
//
// The bit is written once, during the ROM download, while the core is held in
// reset; it is constant for the whole of play. It is re-defaulted at the first
// header byte of EVERY download, so a second download cannot inherit the
// previous one's profile.

module jtcps2w_profile #( parameter [5:0] PROFILE_BYTE = 6'd41 ) (
    input             clk,
    // ROM download stream (jtframe_mem_ports.inc)
    input      [25:0] ioctl_addr,
    input      [ 7:0] ioctl_dout,
    input             ioctl_wr,
    input             ioctl_ram,   // 1 = NVRAM download, not the ROM header
    output            wide_en
);

localparam [25:0] FULL_HEADER = 26'd64;   // jtcps1_prom_we.v:58, 44 + 20 key

reg [7:0] profile = 8'hff;                // = the header fill, i.e. profile off

assign wide_en = ~profile[0];

always @(posedge clk) begin
    if( ioctl_wr && !ioctl_ram && ioctl_addr < FULL_HEADER ) begin
        if( ioctl_addr[5:0] == 6'd0         ) profile <= 8'hff;
        if( ioctl_addr[5:0] == PROFILE_BYTE ) profile <= ioctl_dout;
    end
end

endmodule

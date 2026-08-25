# jtcps2w — CPS-2 WIDE (Vampire Saved) core

A SEPARATE core next to `cores/cps2`, so the reference CPS-2 core stays
untouched and separately usable. It is the MiSTer target of the
**Vampire Saved** project (full-roster Vampire Savior on the real CPS-2
engine): https://github.com/DefinitelyFrenchName/VampireSaved

## The profile is selected at RUNTIME, from the MRA

`cores/cps1`, `cores/cps2` and `cores/cps15` are **byte-untouched**. This core
reaches the widened behaviour through **header byte 41 of the ROM download**,
decoded by `hdl/jtcps2w_profile.v` into a `wide_en` wire that gates every
widened site. The byte is ACTIVE LOW because jtframe fills the header with
`0xFF` (`[header] fill=0xff`), so an MRA that says nothing runs this RBF as a
**stock machine** — the stock `vsavj` MRA emitted here is byte-identical to
`cores/cps2`'s except `<rbf>`. That is the emulator superset invariant made
structural rather than argued.

## What differs from `cores/cps2`, and why each file had to

`cfg/game.yaml` pulls a file from `cores/cps2w/hdl` only when it must differ;
everything else still resolves to `cores/cps2`, `cores/cps1` and
`cores/cps15`. Every override carries a header block naming its slice and its
reason, and **the line-by-line diff against the shared original is the trust
surface** — frozen by `tests/test_mister_wide_gate.sh` in the Vampire Saved
repository.

### New modules

| file | why |
|---|---|
| `hdl/jtcps2w_profile.v` | decodes the profile bit out of the ROM header |
| `hdl/jtcps2w_qsnd_bank.v` | the QSound sample-bank latch, gated: 8 bank bits when `wide_en`, the stock 7 otherwise (D1) |
| `hdl/jtcps2w_obj_bank.v` | the CPS-2 Turbo object promote, `{ wide_en & table_y[12], table_y[14:13] }` — lifted into its own module so it can be swept exhaustively (D3) |

### Overrides of shared files

| file | shared with | why |
|---|---|---|
| `hdl/jtcps2_game.v` | cps2 | 24-bit `qsnd_addr`, the profile instance, `wide_en` routed (D1) |
| `hdl/jtcps15_sound.v` | cps15 | `qsnd_addr` 23 → 24 bits and the gated bank latch (D1) |
| `hdl/jtcps1_prom_we.v` | cps1 | the DOWNLOAD side of the placement: the group-C GFX redirect and the QSound split across two SDRAM banks (D2) |
| `hdl/jtcps1_sdram.v` | cps1 | the READ side of the placement: the bank-0 re-pack (VRAM/ORAM/WRAM/Z80 moved to make room for a 6 MB PRG), the PCM-high slot, the two group-C GFX slots (D2) |
| `hdl/jtcps2_obj_scan.v` | cps2 | where the promote is READ — in the `else` arm of the sprite-list terminator test, which is the whole of the rule (D3) |
| `hdl/jtcps2_obj.v` | cps2 | the obj bank widens 2 → 3 bits between scanner and drawer; `wide_en` passes through (D3) |
| `hdl/jtcps1_obj_draw.v` | cps1, cps15 | a PURE WIDTH change — the drawer latches the bank it is handed and hands it on (D3) |
| `hdl/jtcps1_video.v` | cps1, cps15, cps2 | the only path between game top and object engine: `rom0_bank` widens, `wide_en` routes through (D3) |
| `hdl/jtcps2_main.v` | cps2 | the 6 MB program window — a READ-ONLY decode into `CPU:$400000-$5FFFFF` plus the `one_wait` boundary. Also carries the sim-only 68k read probe behind `` `ifdef JTCPS2W_PRGPROBE `` (D4) |
| `hdl/jtcps2_decrypt.v` | cps2 | THE DECRYPTION RANGE — see below (D5) |

### Not a source file, but do not lose it

| file | why |
|---|---|
| `hdl/pal_lut.hex` | the palette brightness LUT. NOT optional and NOT cosmetic-only: every core instantiating `jtcps1_pal` carries its own copy, `jtframe_ram` resolves `SYNFILE` by bare name, and `*.hex` is in this repo's `.gitignore` — so a new core loses it silently and RENDERS A BLACK SCREEN |
| `cfg/mame2mra.toml` | the `cps2w.cpp` sourcefile opt-in, the Vampire Savior `mustbe`, the mandatory QSound trim, and the profile header byte |
| `cfg/macros.def` | `CORENAME=JTCPS2W` |

## The one finding here that is not about this project

**The CPS-2 key's encrypted-opcode range word is stored COMPLEMENTED, and
`jtcps2_dec_ctrl` reads it straight** (slice D5). The consequence is invisible
on every stock CPS-2 game: the reference core decrypts opcode fetches all the
way to `CPU:$F03FFF` where MAME and FBNeo stop at `$0FFFFF`, and no stock game
has executable content above the window to notice. CPS-2 WIDE is the first
thing that puts any there, so it boots into garbage without the fix. The
override complements the word, profile-gated; `jtcps2_dec_ctrl` itself is
untouched.

## Status

**Slices D0-D5 are all in.** The WIDE romset boots on this core, reaches the
select screen, draws the extended 21-cell wheel, and a tenant fights — with
its fighter art coming out of SDRAM and its state matching MAME field-for-field
at the round-1 anchor. The QSound extension is fetched from DSP bank `0x83`.

**It synthesises and fits**: Quartus 20.1.1 Lite, Cyclone V `5CSEBA6U23I7`,
target mister, against `cores/cps2` built first as the reference leg — **+206
ALMs (+1.1%)** and +2,048 memory bits, with RAM blocks, DSPs and PLLs
unchanged.

**Timing does not close reliably, and this is worth knowing before you build
it.** Twelve seeds span -0.545 .. +0.396 ns with **4 failing**; five `cores/cps2`
control seeds span +0.144 .. +0.665 with none failing. Every failing path is
inside `jtframe_sdram64`, terminates at an SDRAM address pin, and reshuffles
between seeds — so what is marginal is that controller's address-generation
cone as a whole, shared infrastructure this fork does not touch, rather than
anything in the widened logic. Note that `jtseed` retries until a seed passes,
so a green build certifies "one placement was found that closes", never "this
design closes with margin". **A failing seed still emits an `.rbf` that is
indistinguishable from a good one — check the slack, not just the exit code.**

**What has never happened is hardware.** No `.rbf` has been loaded onto a
DE10-Nano and no analog output has been seen. Everything above is Verilator
plus the fitter.

The design, the arithmetic and the gates live in the Vampire Saved
repository: `docs/project/mister_map.md`, `docs/platform/mister.md`,
`docs/project/mister_core.md`, `docs/project/cps2_wide.md`.

Licence: GPL-3.0, as jtcores. See the repository LICENSE.

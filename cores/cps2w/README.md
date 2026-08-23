# jtcps2w — CPS-2 WIDE (Vampire Saved) core

A SEPARATE core next to `cores/cps2`, so the reference CPS-2 core stays
untouched and separately usable. It is the MiSTer target of the
**Vampire Saved** project (full-roster Vampire Savior on the real CPS-2
engine): https://github.com/DefinitelyFrenchName/VampireSaved

## The profile is selected at RUNTIME, from the MRA

`cores/cps2` and `cores/cps15` are **byte-untouched**. This core reaches the
widened behaviour through **header byte 41 of the ROM download**, decoded by
`hdl/jtcps2w_profile.v` into a `wide_en` wire that gates every widened site.
The byte is ACTIVE LOW because jtframe fills the header with `0xFF`
(`[header] fill=0xff`), so an MRA that says nothing runs this RBF as a
**stock machine** — the stock `vsavj` MRA emitted here is byte-identical to
`cores/cps2`'s except `<rbf>`. That is the emulator superset invariant made
structural rather than argued.

## What differs from `cores/cps2`, and why each file had to

`cfg/game.yaml` pulls a file from `cores/cps2w/hdl` only when it must differ;
everything else still resolves to `cores/cps2`, `cores/cps1` and
`cores/cps15`.

| file | why |
|---|---|
| `hdl/jtcps2w_profile.v` (new) | decodes the profile bit out of the ROM header |
| `hdl/jtcps2w_qsnd_bank.v` (new) | the QSound sample-bank latch, gated: 8 bank bits when `wide_en`, the stock 7 otherwise |
| `hdl/jtcps15_sound.v` (override) | `qsnd_addr` 23 → 24 bits and the latch above; the file is SHARED with `cores/cps15` |
| `hdl/jtcps2_game.v` (override) | 24-bit `qsnd_addr`, the profile instance, `wide_en` routed; the file is SHARED with `cores/cps2` |
| `hdl/pal_lut.hex` | the palette brightness LUT. NOT optional and NOT cosmetic-only: every core instantiating `jtcps1_pal` carries its own copy, `jtframe_ram` resolves `SYNFILE` by bare name, and `*.hex` is in this repo's `.gitignore` — so a new core loses it silently and RENDERS A BLACK SCREEN |
| `cfg/mame2mra.toml` | the `cps2w.cpp` sourcefile opt-in, the Vampire Savior `mustbe`, the mandatory QSound trim, and the profile header byte |
| `cfg/macros.def` | `CORENAME=JTCPS2W` |

Status: **slice D1** — the QSound sample-bank width, runtime-gated. The
placement work (SDRAM bank split, the group-C GFX redirect), the object
tile-code promote and the 68k PRG window are slices D2-D4 and are not here
yet. The design, the arithmetic and the gates live in the Vampire Saved
repository: `docs/project/mister_map.md`, `docs/platform/mister.md`,
`docs/project/cps2_wide.md`.

Licence: GPL-3.0, as jtcores. See the repository LICENSE.

# jtcps2w — CPS-2 WIDE (Vampire Saved) core

A SEPARATE core next to `cores/cps2`, so the reference CPS-2 core stays
untouched and separately usable. It is the MiSTer target of the
**Vampire Saved** project (full-roster Vampire Savior on the real CPS-2
engine): https://github.com/DefinitelyFrenchName/VampireSaved

Status: SCAFFOLD. `cfg/` is a twin of `cores/cps2/cfg` with only
`CORENAME=JTCPS2W` changed and the MRA set restricted to the Vampire
Savior family (the stock reference leg — the patched core running the
unmodified game must behave exactly as `jtcps2` does). No RTL differs
yet; every RTL change that follows is profile-gated and documented in the
Vampire Saved repository (`docs/platform/mister.md`,
`docs/project/cps2_wide.md`).

Licence: GPL-3.0, as jtcores. See the repository LICENSE.

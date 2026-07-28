# LMU wine patches (GE-Proton11-3)

Wine patches needed to run Le Mans Ultimate. Rebased from JacKeTUs/wine
(`lmu-d2d1-hid`, which was based on GE-Proton10-34) onto GE-Proton11-3's wine
(`9578fa3613f3379179b576968bc77c8161ab6ea8`).

Without these, LMU dies on race load: wine's `d2d1` returns `E_NOTIMPL` from
`CreateSpriteBatch` without writing the out-parameter, LMU doesn't check the
HRESULT and dereferences NULL. Confirmed via `EXCEPTION_ACCESS_VIOLATION`
(write to address 0) immediately after `fixme:d2d:d2d_device_context_CreateSpriteBatch`.

## Applying

`build.sh` does this for you. By hand, from the source tree with submodules
initialised:

    cd GE-Proton11-3-src/wine
    git am ../../patches/wine/lmu/*.patch

## Contents

| Patch | Purpose |
| --- | --- |
| 0001 | `ID2D1SpriteBatch` implementation — **the crash fix** |
| 0002 | `Tint` effect stub, `effect_id` tracking |
| 0003 | `debug_d2d_matrix3x2_f` tracing helper |
| 0004 | Move clip stack onto the bitmap (clip state leaked across render targets) |
| 0005 | `PushLayer`/`PopLayer` implementation |
| 0006 | Draw a Tint effect's input bitmap in `DrawImage`; sprite tint in the pixel shader |
| 0007 | Derive `guidInstance` from crc32(names)+serial+VID/PID so wheel bindings persist |
| 0008 | Build fix |
| 0009 | `IDirectInput7::FindDevice` — first cut, superseded by 0011 |
| 0010 | Hoist declarations (`-Werror=declaration-after-statement`) |
| 0011 | `IDirectInput7::FindDevice` via the joystick cache — **wheel hotplug** |

## Dropped from the original series

- **`HidP_SetData` implementation** — upstream wine now has a real one.
- The FFB patches from the old `ffb-patches` branch — both upstreamed. Effect value
  clamping is now `clamp_to_physical_value`/`set_parameter_value_clamp`; the angle
  conversion is upstream as `(direction + 27000) % 36000` plus `LOGICAL_MAXIMUM(4, 35900)`.

## Conflicts resolved during the rebase

- **0002**: upstream restructured `d2d_effects_init_builtins` around `X`/`X2` macros
  requiring a factory per effect, so Tint is registered as `X(tint)` with a new
  `tint_factory`. Property names corrected to `Color`/`ClampOutput` (the originals
  were mangled: `ColorD2D1_TINT_PROP_COLOR`). `CLSID_D2D1Tint` was already in
  upstream's `d2d1effects_2.idl`.
- **0006**: upstream hoisted the shaders and input-element descriptors to file scope
  with a `shape_` prefix. The `is_tinted`/`tint_colour` shader edits were ported into
  `shape_ps_code` rather than reintroducing the old in-function copies. The HLSL
  cbuffer layout still matches `struct d2d_ps_cb`.
- **0007**: upstream added its own `create_instance_uuid` (time-based, stable only via
  a registry cache). The crc32 derivation is kept because it is deterministic from
  hardware identity, and it preserves existing bindings. Upstream's now-unused
  `create_instance_uuid` is removed to avoid `-Werror=unused-function`.
  Upstream's `instance->dwSize` assignment is preserved.
- **0010**: the `dlls/hid/hidp.c` hunk was dropped along with the `HidP_SetData` commit.

## Fixes on top of the original series

**0011 rewrites 0009.** Both fix the same real bug: upstream's `FindDevice` is a
stub that returns `DI_OK` without writing `*pguidInstance`, so the caller passes
uninitialised stack memory to `CreateDevice`.

0009 replaced the stub with a lookup that feeds the caller's string to
`hid_joystick_device_try_open()`. An earlier version of 0011 assumed that was
wrong because callers pass a device *name* while `try_open` `CreateFileW`s its
argument as a *path*, and looked the name up instead. A `WINEDEBUG=+dinput`
capture of LMU on 2026-07-28 — Simagic wheel unplugged and reconnected mid-session
— settled it: LMU passes a device interface **path**, so the name-only lookup
would have missed every time.

0009 and 0010 are kept as-is (0010 patches both `dinput7_FindDevice` and
`hid_joystick_find_device`, so 0009 cannot simply be dropped). 0011 now replaces
the implementation with the one proven on cachyos as `../lmu-cachyos/0012`:

- `hid_joystick_refresh_devices()` first, since the device may have just been
  plugged back in;
- match the caller's string against the cached device interface **path**, folded
  to lowercase because `cache_entry_create()` lowercases what it stores;
- fall back to `tszInstanceName`/`tszProductName`, so name-passing callers work
  too — a strict superset of both earlier attempts;
- `DIERR_DEVICENOTREG` when nothing matches, instead of `DI_OK` with a garbage
  GUID.

The two series are now in sync on this fix; the only difference is that GE keeps
it as a rewrite of 0009 while cachyos never carried 0009 and has it as a single
patch.

## Status

**Builds.** `./build.sh ge GE-Proton11-3` applies all 11 patches cleanly onto
`9578fa3613f` and produces a complete tool tree and tarball. See the root
[README Status](../../../README.md#status) for what has been run in-game.

The d2d1 conflict resolutions listed above are compile-level. The equivalent
patches on the cachyos side are verified in-game (LMU loads onto the track, UI
renders correctly), but GE's `d2d1` is a different tree, so a garbled UI here
would mean 0004–0006 need another look rather than that the approach is wrong.

The hotplug fix in 0011 is verified in-game on cachyos (`../lmu-cachyos/README.md`
has the log). GE ships the same implementation, and the shipped `dinput.dll` /
`dinput8.dll` were checked to contain it, but the reconnect has not been exercised
on a GE build. Re-check with:

```
WINEDEBUG=+dinput PROTON_LOG=1 %command%
grep -E "FindDevice|matched instance|get_instance_from_guid" ~/steam-2399420.log
```

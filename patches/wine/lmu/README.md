# LMU wine patches (GE-Proton11-3)

Wine patches needed to run Le Mans Ultimate. Rebased from JacKeTUs/wine
(`lmu-d2d1-hid`, which was based on GE-Proton10-34) onto GE-Proton11-3's wine
(`9578fa3613f3379179b576968bc77c8161ab6ea8`).

Without these, LMU dies on race load: wine's `d2d1` returns `E_NOTIMPL` from
`CreateSpriteBatch` without writing the out-parameter, LMU doesn't check the
HRESULT and dereferences NULL. Confirmed via `EXCEPTION_ACCESS_VIOLATION`
(write to address 0) immediately after `fixme:d2d:d2d_device_context_CreateSpriteBatch`.

## Applying

From the repo root, with submodules initialised:

    cd wine
    git am ../patches/lmu/*.patch

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
| 0009 | `IDirectInput7::FindDevice` — lets LMU handle hotplugged devices |
| 0010 | Hoist declarations (`-Werror=declaration-after-statement`) |
| 0011 | Fix 0009: look `FindDevice` up by name, not by path |

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

- **0011** repairs 0009. The upstream `FindDevice` was a stub that returned `DI_OK`
  without writing `*pguidInstance`; 0009 replaced it with a lookup that feeds the
  caller's device *name* to `hid_joystick_device_try_open()`, which `CreateFileW`s
  its argument as a *path*. That fails for every real caller, so 0009 turned a
  silent no-op into a hard failure and hotplug never actually worked — not here and
  not on the GE-Proton10-34 build this series came from. 0011 searches the joystick
  cache by instance/product name instead.

## Not verified

These compile-level resolutions have not been built or run. In particular, whether
SpriteBatch/Layers still composite correctly against upstream's reworked d2d1 effect
pipeline needs an actual race in-game.

0011 has **not been compiled** — the mingw toolchain lives in the build container, not
on the host — and it is a hypothesis about the failure, not a confirmed diagnosis:
the bug it fixes is real, but whether LMU calls `FindDevice` on hotplug still needs a
`WINEDEBUG=+dinput` log to confirm.

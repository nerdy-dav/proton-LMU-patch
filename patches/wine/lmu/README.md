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
| 0012 | ICO/CUR entry extraction plus a WIC-less BMP decoder — **LMU 1.4 VR init** |
| 0013 | `BCryptDeriveKey` `KDF_SECRET_PREPEND`/`APPEND` — **LMU 1.4 multiplayer join** |

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

## Picked up for LMU 1.4 (0012, 0013)

Upstream released `GE-Proton10-34-LMU-hid_fixes-vr-bcrypt` on 2026-07-28 for the
LMU 1.4 update. It is the previous tag plus a wine bump from
`2790a7a9b91` to `cd8cbc6f89f` (JacKeTUs/wine branch `d2d1-3103`), which adds
exactly two commits — imported here as 0012 and 0013:

- **0012, `d3dx9_36`** — LMU 1.4 loads a `.cur` through `D3DXCreateTextureFromFileInMemory`.
  Wine's `d3dx_image_init` doesn't recognise the ICO/CUR container, so VR
  initialisation failed. The patch extracts the first icon directory entry,
  fixes up its DIB header (an ICO DIB stores `biHeight` doubled to cover the AND
  mask), and adds a plain BMP decoder used when WIC is unavailable.
- **0013, `bcrypt`** — the multiplayer join does an ECDH-P256 exchange and derives
  the session key with `BCryptDeriveKey(BCRYPT_KDF_HASH, …)` passing a
  `KDF_SECRET_PREPEND` buffer. `derive_key_hash` hashed only the shared secret and
  dropped the prepend/append buffers, so the derived key was wrong and the
  handshake never validated. CNG specifies `Hash(prepend || secret || append)`.

Neither touches d2d1 or dinput, so both are independent of 0001–0011.

**Adapted during the port.** Upstream authored these against GE-Proton10-34's
wine; on Proton 11's wine, 0012 needed two changes, folded into the patch:

- the `if (!is_d3dx9) return E_FAIL;` early-out the ICO block was inserted next to
  no longer exists in `d3dx_image_init` — that hunk is dropped and only the ICO
  block is added;
- `D3DX_ERROR_INVALID_DATA` is spelled `D3DXERR_INVALIDDATA` in this tree.

0013 applies unchanged. Both patches are byte-identical to `../lmu-cachyos/0013`
and `0014` — the two bases have not diverged in `bcrypt` or `d3dx9_36`.

## Status

**Builds and runs.** `./build.sh ge GE-Proton11-3` applies all 11 patches cleanly
onto `9578fa3613f` and produces a complete tool tree and tarball.

**0012 and 0013 build** (2026-07-31). `./build.sh ge GE-Proton11-3` applies 13/13
onto `9578fa3613f` and completes with no warning or error from `d3dx_helpers.c`
or `bcrypt_main.c` in a 284k-line log. The shipped `d3dx9_36.dll`, both arches,
carries the new `ico_entry:` traces and the `image_init: converted DIB to BMP`
trace, so 0012 is really in the binary; 0013 adds no strings, but the build
tree's `bcrypt_main.c` carries it and came from the same run.

**Not yet verified in-game**: no VR or multiplayer-join test has been run against
this build.

**Verified in-game** on 2026-07-28: LMU launches, loads onto the track, the
in-game UI renders correctly, and a Simagic wheel unplugged and reconnected
mid-session is re-acquired with force feedback resuming:

```
dinput7_FindDevice       ... name L"\\?\HID#VID_3514&PID_000E#..."
hid_joystick_find_device ... matched instance {ae42ba3a-804c-11f1-8001-000044455354}
dinput8_a_CreateDevice   ... guid {ae42ba3a-804c-11f1-8001-000044455354}
hid_joystick_device_try_open detected device type 0x10214
dinput_device_Acquire
```

`get_instance_from_guid ... not found` — the failure signature of the old stub —
appears zero times in a 580k-line log, and the instance GUID matches the one the
cachyos build derives for the same hardware, so bindings survive switching tools.

See the root [README Status](../../../README.md#status) for both bases side by
side and the list of known-benign log noise.

Re-check after any rebase with:

```
WINEDEBUG=+dinput PROTON_LOG=1 %command%
grep -E "FindDevice|matched instance|get_instance_from_guid" ~/steam-2399420.log
```

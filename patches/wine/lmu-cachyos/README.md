# LMU series for proton-cachyos

The full LMU series rebased onto `wine-cachyos` — crash fix, Layers, Tint
compositing and the wheel-binding fix.

Rebased onto: `CachyOS/wine-cachyos` commit `1ba4fa1`, the wine submodule of
proton-cachyos branch `cachyos_11.0_20260713/main`.

`build.sh` picks this directory up for the dated `cachyos_*/main` branches; the
GE series in `../lmu/` is used for GE builds.

For `cachyos_11.0_release/_sauce` (wine `e893f50`), use the separate
[`../lmu-proton-cachyos-11.0-release-sauce/`](../lmu-proton-cachyos-11.0-release-sauce/README.md)
series: `_sauce` already contains `ID2D1SpriteBatch` and the bcrypt prepend
fix, and its d2d1 has diverged enough that this 14-patch series does not apply.

## Why cachyos needs its own series

cachyos' wine is Valve's, not GE's. Stock, it has the same bug LMU trips over —
`d2d1/device.c` has

```c
static HRESULT STDMETHODCALLTYPE d2d_device_context_CreateSpriteBatch(ID2D1DeviceContext6 *iface,
        ID2D1SpriteBatch **sprite_batch)
{
    FIXME("iface %p, sprite_batch %p stub!\n", iface, sprite_batch);
    return E_NOTIMPL;
}
```

and no `dlls/d2d1/sprite_batch.c` at all. But its `d2d1` has diverged from GE's,
so most of `../lmu/` does not apply unchanged.

## The series

| here | from `../lmu/` | note |
| --- | --- | --- |
| 0001 | (new) | Adds `is_tinted`/`tint_colour` to `struct d2d_bitmap` and `effect_id` to `struct d2d_effect`, which 0002/0003 write to. Upstream 0006 declares these; here it is split out so the crash fix does not depend on the Tint HACK. |
| 0002 | 0001 | `ID2D1SpriteBatch` implementation — **the crash fix**. The struct block in `d2d1_private.h` moved to sit before `d2d_array_reserve` (context drift). |
| 0003 | 0002 | `Tint` effect stub + `effect_id` tracking. Clean. |
| 0004 | 0003 | `debug_d2d_matrix3x2_f` tracing helper. Clean — and required: Layers and Tint call it. |
| 0005 | 0007 | `guidInstance` from crc32(names)+serial+VID/PID, so wheel bindings persist. Clean. |
| 0006 | 0008 | The `joystick_hid.c` half of "Fix build" (`RtlComputeCrc32` casts). |
| 0007 | 0010 | The `sprite_batch.c` and `hid_joystick_device_try_open` hoists from "Fix warnings treated as errors". |
| 0008 | 0004 | Clip stack onto the bitmap. One fixup: the new field sits alongside the ones 0001 adds. |
| 0009 | 0005 | **Layers.** The real rebase — see below. |
| 0010 | 0006 | Tint compositing in `DrawImage` and the sprite tint in the pixel shader. One fixup: its declarations of the 0001 fields were dropped as already present; only `struct d2d_effect.output` was taken from that hunk. |
| 0011 | 0008 + 0010 | The `device.c` halves of both fix patches — the `const` drop on `d2d_layer_stack_push` plus declaration hoists in the Layers and DrawImage paths. |
| 0012 | (new) | `IDirectInput7::FindDevice` — wheel hotplug. Replaces `../lmu/0009`+`0011`, see below. |
| 0013 | `../lmu/0012` | ICO/CUR loading in `d3dx9_36` — **LMU 1.4 VR init**. See below. |
| 0014 | `../lmu/0013` | `BCryptDeriveKey` prepend/append — **LMU 1.4 multiplayer join**. See below. |

## Hotplug (0012)

`../lmu/0009` and `0011` are **not** carried. 0012 supersedes both, and it is
written against a log rather than a guess.

`../lmu/0011` assumed callers pass a device *name* and that 0009's path-based
lookup "fails for every real caller". A `WINEDEBUG=+dinput` capture of LMU on
2026-07-28, unplugging and reconnecting a Simagic wheel mid-session, shows the
opposite — LMU passes a device interface path:

```
fixme:dinput:dinput7_FindDevice ... name L"\\?\HID#VID_3514&PID_000E#273&337935523333&0&0&0#{4d1e55b2-...}" stub!
trace:dinput:dinput8_a_CreateDevice ... guid {a9ce5bb0-0000-0000-406e-d0f8ff6f0000}
warn:dinput:get_instance_from_guid guid {a9ce5bb0-0000-0000-406e-d0f8ff6f0000} not found
```

The stub returns `DI_OK` without writing `*pguidInstance`, so LMU passes
uninitialised stack memory (note the `406e-d0f8ff6f0000` tail — a stack address,
different on every call) to `CreateDevice`, which fails. The wheel is never
re-acquired.

The lookup needs no new bookkeeping: the same log shows `joystick_cache` already
holds that exact path against instance `{ae42ba3a-804c-11f1-8001-000044455354}`.
0012 calls `hid_joystick_refresh_devices()`, then matches the caller's string
against `entry->path` — folded to lowercase, since `cache_entry_create()`
lowercases what it stores — falling back to `tszInstanceName`/`tszProductName`
so name-passing callers work too. That fallback is what `../lmu/0011` was
reaching for; keeping both makes 0012 a strict superset.

Note this is a stock-wine bug, not a cachyos divergence: GE-Proton ships the
same stub.

## The Layers rebase (0009)

cachyos had already reworked `PushLayer`/`PopLayer`, so the patch could not just
replace the old stubs. What it does upstream is add `push_layer_impl` plus new
`ID2D1DeviceContext_PushLayer` and `PopLayer` implementations further down the
file; those applied cleanly. The conflict was the three now-duplicated old
stubs, resolved as:

- `d2d_device_context_PushLayer` — rewritten to build the
  `D2D1_LAYER_PARAMETERS1`, short-circuit `D2D_TARGET_UNKNOWN` and
  `D2D_TARGET_COMMAND_LIST`, then call `push_layer_impl`. The forward
  declaration the patch adds near the top of the file makes this legal.
- `d2d_device_context_PopLayer` (old stub) — deleted; the implementation the
  patch adds later takes over, and it still precedes the vtable.
- `d2d_device_context_ID2D1DeviceContext_PushLayer` (old stub) — same.

One signature difference matters: cachyos'
`d2d_command_list_push_layer()` takes **three** arguments, where GE's takes a
fourth `ID2D1Layer *layer`. The call the patch adds was changed to the
three-argument form, matching what upstream records in command lists today.

Also dropped from 0005: an `ERR()` added to `d2d_device_context_set_error`,
which logs on every error path. Pure debug noise, no behaviour.

## Picked up for LMU 1.4 (0013, 0014)

Upstream's `GE-Proton10-34-LMU-hid_fixes-vr-bcrypt` (2026-07-28) is the previous
tag plus a wine bump from `2790a7a9b91` to `cd8cbc6f89f` (JacKeTUs/wine branch
`d2d1-3103`), adding exactly two commits:

- **0013, `d3dx9_36`** — LMU 1.4 loads a `.cur` through
  `D3DXCreateTextureFromFileInMemory`. Wine's `d3dx_image_init` doesn't recognise
  the ICO/CUR container, so VR initialisation failed. The patch extracts the first
  icon directory entry, fixes up its DIB header (an ICO DIB stores `biHeight`
  doubled to cover the AND mask), and adds a plain BMP decoder used when WIC is
  unavailable.
- **0014, `bcrypt`** — the multiplayer join does an ECDH-P256 exchange and derives
  the session key with `BCryptDeriveKey(BCRYPT_KDF_HASH, …)` passing a
  `KDF_SECRET_PREPEND` buffer. `derive_key_hash` hashed only the shared secret and
  dropped the prepend/append buffers, so the derived key was wrong and the
  handshake never validated. CNG specifies `Hash(prepend || secret || append)`.

Neither touches `d2d1` or `dinput`, so both are independent of 0001–0012 and sit
at the end of the series unchanged in order.

**Adapted during the port.** Upstream authored these against GE-Proton10-34's
wine. On `1ba4fa1`, plain `git am` rejected 0013 and `git am -3` conflicted; the
resolution, folded into the patch, was:

- upstream inserted its ICO block immediately above
  `if (!is_d3dx9) return E_FAIL;` in `d3dx_image_init`. That early-out no longer
  exists in this tree, so that hunk is dropped and only the ICO block is added.
- `D3DX_ERROR_INVALID_DATA` is spelled `D3DXERR_INVALIDDATA` here (the file
  `#define`s it locally at the top).

0014 applies with a three-way merge and no content change. Both patches came out
byte-identical to `../lmu/0012` and `0013` — `bcrypt` and `d3dx9_36` have not
diverged between the two bases.

## Status

**0013 and 0014 build** (2026-07-31). `./build.sh cachyos cachyos_11.0_20260713/main`
applies 14/14 onto `1ba4fa1` and completes in 12m56s with no warning or error from
`d3dx_helpers.c` or `bcrypt_main.c` in a 354k-line log. The shipped
`d3dx9_36.dll`, both arches, carries the new `ico_entry:` traces and the
`image_init: converted DIB to BMP` trace, so 0013 is really in the binary; 0014
adds no strings, but the build tree's `bcrypt_main.c` carries it and came from the
same run.

**0014 verified in-game** on 2026-07-31: a multiplayer join completes. Before the
patch the handshake never validated, so this is the fix doing its job.

**0013 is not verified in-game**: no VR session has been run against this build.
The ICO/CUR code is present in the shipped `d3dx9_36.dll` on both architectures,
but present is not the same as working.

Everything below predates 0013/0014.

**Builds and runs.** `./build.sh cachyos` on `cachyos_11.0_20260713/main`
produces a complete tool tree and a `.tar.xz`; the shipped
`files/lib/wine/x86_64-windows/d2d1.dll` contains `d2d_sprite_batch_create`,
`somehow new layer is NULL` and `Stack push failed`, so both the crash fix and
the Layers implementation are really in the binary.

**Verified in-game** on 2026-07-28: LMU launches, loads onto the track, and the
in-game UI renders correctly.

An earlier build of this series without Layers/Tint got onto the track but with
a completely broken UI — that is what the Layers rebase fixed, and it is the
symptom to expect if 0008–0011 ever fail to apply after a rebase onto a newer
cachyos branch.

**0012 builds.** `./build.sh cachyos cachyos_11.0_20260713/main` succeeds with the
12-patch series (15m07s); the shipped `dinput.dll` and `dinput8.dll`, both arches,
contain `hid_joystick_find_device` and the `matched instance` trace, and no longer
contain the `FindDevice ... stub!` string.

**0012 verified in-game** on 2026-07-28, Simagic wheel unplugged and reconnected
mid-session on track:

```
hid_joystick_find_device ... matched instance {ae42ba3a-804c-11f1-8001-000044455354}
dinput8_a_CreateDevice   ... guid {ae42ba3a-804c-11f1-8001-000044455354}
hid_joystick_device_try_open detected device type 0x10214
dinput_device_Acquire
hid_joystick_send_force_feedback_command ... command 0x1
```

The wheel is re-acquired and force feedback resumes. `get_instance_from_guid ...
not found` — the failure signature of the old stub — appears zero times in the
whole log.

Expect one benign miss per reconnect:

```
warn:dinput:hid_joystick_find_device name L"\\?\HID#VID_3514&PID_0001&MI_00#..." not found
```

LMU also asks about the Simagic base's second HID interface, which is not a
joystick and so is legitimately not in `joystick_cache`. `DIERR_DEVICENOTREG` is
the correct answer and the game drops it without calling `CreateDevice`. Under the
old stub this same call returned `DI_OK` with an uninitialised GUID.

Re-check after any rebase with:

```
WINEDEBUG=+dinput PROTON_LOG=1 %command%
grep -E "FindDevice|matched instance|get_instance_from_guid" ~/steam-2399420.log
```

### Gotcha when iterating

`build.sh` used to lose hand-written commits between runs: `git submodule
update` resets `wine/` to the commit the superproject pins. It now saves and
restores wine's HEAD, but **export your work to patch files here before
rebuilding** — that is what the build actually applies.

The restore is deliberately conditional: wine's HEAD is put back only when it
contains the pinned commit, i.e. when it really is your work on this base. A
HEAD that has diverged from the pin — an interrupted clone leaving wine on the
upstream branch tip, or the pin moving under you with a new release — is *not*
restored, because replaying the series onto it produces conflicts that have
nothing to do with the series. That HEAD is kept as an `lmu-rescue/<timestamp>`
branch in `wine/`, so nothing is lost either way; `git -C <version>-src/wine
branch --list 'lmu-rescue/*'` finds it.

# LMU series for proton-cachyos

The full LMU series rebased onto `wine-cachyos` — crash fix, Layers, Tint
compositing and the wheel-binding fix.

Rebased onto: `CachyOS/wine-cachyos` commit `1ba4fa1`, the wine submodule of
proton-cachyos branch `cachyos_11.0_20260713/main`.

`build.sh` picks this directory up automatically for `./build.sh cachyos`; the
GE series in `../lmu/` is used for GE builds.

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

Not carried: `../lmu/0009` and `0011` (`IDirectInput7::FindDevice`, hotplug).
0009 applies but 0011, which fixes a real bug in it, does not; they have to move
together and neither is needed for the UI.

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

## Status

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

### Gotcha when iterating

`build.sh` used to lose hand-written commits between runs: `git submodule
update` resets `wine/` to the commit the superproject pins. It now saves and
restores wine's HEAD, but **export your work to patch files here before
rebuilding** — that is what the build actually applies.

# Proton + LMU Patch

Wine patches that make **Le Mans Ultimate** run under Proton, plus a script that
builds a ready-to-use Steam compatibility tool with them applied.

Four problems are fixed:

- **The game crashes on race load.** Wine's `d2d1` returns `E_NOTIMPL` from
  `CreateSpriteBatch` without writing the out-parameter; LMU doesn't check the
  HRESULT and dereferences NULL, giving an `EXCEPTION_ACCESS_VIOLATION` (write to
  address 0). Fixing this needs a real `ID2D1SpriteBatch`, and — for the in-game
  UI to actually render rather than come out garbled — Layers and Tint too.
- **A wheel unplugged mid-session never comes back.** Wine's
  `IDirectInput7::FindDevice` is a stub that returns `DI_OK` without writing
  `*pguidInstance`, so LMU passes uninitialised stack memory to `CreateDevice`.
- **VR never initialises (LMU 1.4).** The game loads a `.cur` through
  `D3DXCreateTextureFromFileInMemory`, and wine's `d3dx9_36` doesn't recognise the
  ICO/CUR container at all.
- **Multiplayer join fails (LMU 1.4).** The join handshake derives its session key
  with `BCryptDeriveKey(BCRYPT_KDF_HASH, …)` and a `KDF_SECRET_PREPEND` buffer;
  older wine hashed only the shared secret and ignored the prepend/append
  buffers, so the key came out wrong. `_sauce` already handles prepend; its series
  adds the missing append support.

The series started from [JacKeTUs/wine](https://github.com/JacKeTUs/wine)
(`lmu-d2d1-hid`, based on GE-Proton10-34), rebased onto GE-Proton11-3 and
proton-cachyos, with the upstreamed patches dropped and the hotplug fix rewritten.
Because wine `e893f50` — the wine pinned by `cachyos_11.0_release/_sauce` —
already carries real `ID2D1SpriteBatch` support and the bcrypt prepend fix,
`_sauce` has its own curated twelve-patch series rather than reusing the older
cachyos series.

## Quick start

```bash
git clone git@github.com:Pipodi/proton-LMU-patch.git
cd proton-LMU-patch
chmod +x build.sh
./build.sh cachyos cachyos_11.0_release/_sauce   # or: ./build.sh   (GE, the default)
```

The script prints the exact install command when it finishes. Restart Steam,
then pick the new tool in LMU's compatibility settings.

**Which base should I pick?** The older `cachyos` series is the more thoroughly
tested cachyos path; `cachyos_11.0_release/_sauce` applies cleanly but is still
awaiting its first full build and in-game run — see [Status](#status). Pick `ge`
if you already run GE-Proton for everything else.

## Requirements

- `git`
- `podman` or `docker` (the build runs inside the steamrt SDK image)
- `make`
- ~60 GB of free disk space
- Roughly 15–30 minutes, mostly compiling

## Usage

Two bases are supported: **`ge`** ([proton-ge-custom](https://github.com/GloriousEggroll/proton-ge-custom),
the default) and **`cachyos`** ([proton-cachyos](https://github.com/CachyOS/proton-cachyos)).

```bash
./build.sh                            # ge, newest GE-Proton tag on the remote
./build.sh ge GE-Proton11-3           # a specific GE tag
./build.sh cachyos                    # newest proton-cachyos release branch
./build.sh cachyos cachyos_11.0_release/_sauce
./build.sh cachyos cachyos_11.0_20261014/main
./build.sh GE-Proton11-3              # variant inferred from the tag name
./build.sh --check-only               # sanity checks only, change nothing
./build.sh -f ge master               # force a fresh re-clone
```

With no version given, both variants resolve the newest release live: the highest
`GE-Proton<major>-<minor>` tag for `ge`, and — since CachyOS cuts a branch per
release instead of tagging — the newest `cachyos_*/main`, `…/main_native` or
`…/_sauce` branch for `cachyos`. `…/main` is the Steam Linux Runtime flavour
(folder suffix `-slr`), `…/main_native` the native one (`-native`), and
`…/_sauce` keeps the `-sauce` suffix.

Other flags: `--install` (install into Steam after building), `--install-only`
(install an already-built package and do nothing else), `--skip-patch` (patch
layer already applied), `--no-clean` (reuse the build dir), `-y` (don't prompt
before deleting it).

## Installing

The build ends with:

```
GE-Proton11-3-build/GE-Proton11-3-LMU.tar.gz                                  # ge
proton-cachyos-11.0-release-sauce-build/proton-cachyos-…-LMU.tar.xz          # cachyos _sauce
proton-cachyos-11.0-20260713-slr-build/proton-cachyos-…-slr-LMU.tar.xz        # older cachyos
```

Install it with:

```bash
./build.sh cachyos cachyos_11.0_release/_sauce --install-only  # install what is already built
./build.sh cachyos cachyos_11.0_release/_sauce --install       # or build and install in one go
```

`--install-only` skips the source tree entirely — no clone, no submodule update,
no patching — so it is also the quickest way to reinstall after a Steam reset.

`cachyos_11.0_release/_sauce` (and its `_native`/`_action` siblings) only
`rsync`s `make redist` into `redist/`; it does not move the tree to
`<build-name>/` or create a tarball. `build.sh` normalizes that to the same
`<build-name>/`, `.tar.xz` and `.sha512sum` shape the dated branches produce.

What it does: verifies the tarball against its `.sha512sum`, unpacks it to a
staging directory *beside* the target and swaps it in (an interrupted install
can't leave a half-written tool that Steam still lists), removes any previous
install of the same name — `chmod -R u+w` first, since `make redist` ships the
tree mode 555 — then greps the installed DLLs for `d2d_sprite_batch_create`,
`hid_joystick_find_device` and `ico_entry` to prove the patches survived
packaging. It warns if Steam is running.

By hand, if you prefer:

```bash
mkdir -p ~/.local/share/Steam/compatibilitytools.d/GE-Proton11-3-LMU
tar -xf GE-Proton11-3-LMU.tar.gz \
    -C ~/.local/share/Steam/compatibilitytools.d/GE-Proton11-3-LMU --strip-components=1
```

**Don't use Proton's own `make install`.** Its `install` target depends on `all`,
so it re-enters the build on the *host*, outside the steamrt container the build
actually ran in. On any distro whose ffmpeg is newer than the runtime's, `winedmo`
then fails to compile (`unknown type name 'AVBSFInternal'`) and nothing is
installed. `build.sh` no longer suggests it.

Proton's Makefile defaults `STEAM_DIR` to `~/.steam/root`, which is usually a
symlink to the real library but not always — `build.sh` detects the actual
location (`$STEAM_DIR` from the environment wins, then `~/.local/share/Steam`,
`~/.steam/root`, `~/.steam/steam`, the flatpak path). Override it if the guess
is wrong:

```bash
STEAM_DIR=/mnt/games/Steam ./build.sh cachyos cachyos_11.0_release/_sauce --install-only
```

Restart Steam, then select the tool in LMU's compatibility settings.

## The patches

### GE series (13 patches)

| Patch | Purpose |
| --- | --- |
| 0001 | `ID2D1SpriteBatch` implementation — **the crash fix** |
| 0002 | `Tint` effect stub, `effect_id` tracking |
| 0003 | `debug_d2d_matrix3x2_f` tracing helper |
| 0004 | Move clip stack onto the bitmap |
| 0005 | `PushLayer`/`PopLayer` implementation — without it the UI renders garbled |
| 0006 | Draw a Tint effect's input bitmap in `DrawImage`; sprite tint in the pixel shader |
| 0007 | Derive `guidInstance` from crc32(names)+serial+VID/PID so wheel bindings persist |
| 0008 | Build fix |
| 0009 | `IDirectInput7::FindDevice` — first cut, superseded by 0011 |
| 0010 | Hoist declarations (`-Werror=declaration-after-statement`) |
| 0011 | `IDirectInput7::FindDevice` via the joystick cache — **wheel hotplug** |
| 0012 | ICO/CUR loading in `d3dx9_36` — **LMU 1.4 VR init** |
| 0013 | `BCryptDeriveKey` prepend/append buffers — **LMU 1.4 multiplayer join** |

That is the GE series (13 patches) in `patches/wine/lmu/`. The older cachyos
series (14 patches) in `patches/wine/lmu-cachyos/` carries the same fixes in a
different order and split, because cachyos' wine is Valve's rather than GE's and
its `d2d1` has diverged. Each directory has its own README with the full per-patch detail,
including every rebase conflict and how it was resolved:

- [`patches/wine/lmu/README.md`](patches/wine/lmu/README.md) — GE series
- [`patches/wine/lmu-cachyos/README.md`](patches/wine/lmu-cachyos/README.md) — older cachyos series

### proton-cachyos `_sauce` series (12 patches)

`cachyos_11.0_release/_sauce` pins wine `e893f50`, which already ships a real
`ID2D1SpriteBatch`, command-list layer support and the bcrypt prepend fix. Its
series therefore carries only the missing LMU work, plus one build-compatibility
patch for the SDK's FFmpeg 7:

| Patch | Purpose |
| --- | --- |
| 0001 | `is_tinted`/`tint_colour` fields on `d2d_bitmap`, `effect_id` on `d2d_effect` |
| 0002 | `Tint` effect stub and `CLSID_D2D1Tint` |
| 0003 | `debug_d2d_matrix3x2_f` tracing helper |
| 0004 | `DrawSpriteBatch` bitmap-target path — **the crash-fix companion** |
| 0005 | Move the clip stack onto the bitmap |
| 0006 | `PushLayer`/`PopLayer` implementation — without it the UI renders garbled |
| 0007 | Tint compositing in `DrawImage` and the pixel shader |
| 0008 | Stable `guidInstance` from names/serial/VID/PID so wheel bindings persist |
| 0009 | `IDirectInput7::FindDevice` via the joystick cache — **wheel hotplug** |
| 0010 | ICO/CUR loading in `d3dx9_36` — **LMU 1.4 VR init** |
| 0011 | `BCryptDeriveKey` `KDF_SECRET_APPEND` support (prepend is already present) |
| 0012 | Drop winedmo's PCM byte-order BSF, which no longer builds against FFmpeg 7 |

See
[`patches/wine/lmu-proton-cachyos-11.0-release-sauce/README.md`](patches/wine/lmu-proton-cachyos-11.0-release-sauce/README.md)
for the detailed porting notes against `e893f50`.

### How each base is handled

|  | proton-ge-custom | proton-cachyos |
| --- | --- | --- |
| LMU series | `git am` into `wine/` | `git am` into `wine/` |
| base patch layer | `protonprep-valve-staging.sh` | none — its Makefile applies `patches/<module>/*.patch` at build time |
| archive | `.tar.gz` | `.tar.xz`; `_sauce` leaves `redist/` and `build.sh` creates the archive/checksum |

Both bases end up with the series as **commits** in `wine/`, not in the working
tree: GE's prep script does `git reset --hard HEAD` (uncommitted work would be
lost), and CachyOS rsyncs `wine/` minus `.git` into the build dir, so commits
simply carry over.

### Keeping up with new releases

The series is authored against one specific wine commit, recorded in
`patches/wine/<series>/BASE`. When a new GE tag or cachyos branch moves wine on,
`build.sh` tries three things in order and only bothers you if all three fail:

1. **`git am`** — exact context. Tolerant of hunks having shifted, so most
   releases land here.
2. **`git am -3`** — three-way merge. Rescues drift in the context *around* a
   hunk, which plain `am` rejects.
3. **replay at `BASE`, then `git rebase --onto` the new wine** — a full
   three-way merge with every blob available. This is the one that survives
   real churn, and it is what upstream reworking nearby code needs.

If the rebase conflicts, upstream has changed the same lines the series changes
and a human has to decide what the merged result should be. The script restores
wine to where it was and prints the exact commands to redo the rebase by hand.

When step 2 or 3 does the work, the build is carrying a series that is **not**
what is checked in. Re-export it and update `BASE`:

```bash
git -C <version>-src/wine format-patch -<N> --no-signature -o patches/wine/<series>
```

Then commit the refreshed patches. A PR doing exactly that for a new base is the
most useful contribution there is.

### Overriding the series per base

Each series is rebased onto a specific wine. Drop a rebased series into an
override directory and the script picks it up automatically, most specific first:

```
patches/wine/lmu-<version-id>/    e.g. lmu-proton-cachyos-11.0-release-sauce/
patches/wine/lmu-<variant>/       e.g. lmu-cachyos/
patches/wine/lmu/                 the GE series (default)
```

## Folder structure

Versioned folders, so multiple builds coexist:

```
./
├── build.sh
├── patches/wine/lmu/                                    # GE series
├── patches/wine/lmu-cachyos/                            # older cachyos series
├── patches/wine/lmu-proton-cachyos-11.0-release-sauce/  # _sauce series
├── GE-Proton11-3-src/                                   # cloned source tree
├── GE-Proton11-3-build/                                 # build dir + final package
└── proton-cachyos-11.0-release-sauce-build/             # …one pair per variant+version
```

## Status

The GE and older cachyos series have the runtime history below, measured as of
2026-07-31. The newer `cachyos_11.0_release/_sauce` series applies cleanly but
has not been built or run yet.

### GE and older cachyos series

| | older proton-cachyos | proton-ge-custom |
| --- | --- | --- |
| base tested | `cachyos_11.0_20260713/main` | `GE-Proton11-3` |
| series applies | 14/14, clean | 13/13, clean |
| builds | yes (12m56s) | yes (2m39s warm, 14m32s cold) |
| fixes present in shipped DLLs | yes | yes |
| launches, loads onto track | **yes** | **yes** |
| in-game UI renders correctly | **yes** | **yes** |
| wheel reconnect mid-session | **yes** | **yes** |
| multiplayer join (LMU 1.4) | **yes** | **yes** |
| VR initialises (LMU 1.4) | not tested | not tested |

### `cachyos_11.0_release/_sauce` series

| | `_sauce` |
| --- | --- |
| wine base | `e893f50` (pinned by `cachyos_11.0_release/_sauce`) |
| series applies | 12/12, clean |
| builds | **yes** (28m52s clean build) |
| fixes present in shipped DLLs | **yes**, both architectures (`d2d1` SpriteBatch/Layers, `dinput8`, `d3dx9_36`; `bcrypt` compiled) |
| launches, loads onto track | not yet tested |
| in-game UI renders correctly | not yet tested |
| wheel reconnect mid-session | not yet tested |
| multiplayer join (LMU 1.4) | not yet tested |
| VR initialises (LMU 1.4) | not yet tested |

The `_sauce` series applies cleanly to `e893f50`, and a clean
`./build.sh cachyos cachyos_11.0_release/_sauce` completed on 2026-11-09 with a
1.6 GiB tool tree and a 308 MiB `.tar.xz`. Patch 0012 is required because the
SDK's FFmpeg 7 removed the internal BSF API used by `e893f50`'s old winedmo
code. Runtime testing still has to happen on a machine with Steam, LMU and the
relevant wheel/headset.

For the older series, the two LMU 1.4 patches were added on 2026-07-31 and both
bases were rebuilt with them.

**Multiplayer join is confirmed in-game on the older series** — the `bcrypt`
prepend/append fix (GE 0013, older cachyos 0014, `_sauce` 0011) does what it is
meant to where it has been run.

**VR initialisation is not tested, and will not be tested here** — there is no
VR headset on this end. The `d3dx9_36` ICO/CUR patch (GE 0012, older cachyos
0013, `_sauce` 0010) is build-verified only on the older series: the new code is
in the shipped `d3dx9_36.dll` on both architectures for both older bases, with no
warning from `d3dx_helpers.c` in either log, but nothing has ever exercised the
ICO/CUR path at runtime. It is carried because upstream ships it for LMU 1.4 and
it cannot affect the non-VR paths, not because it is known to work.

**If you have a headset, this is the one thing the project cannot check itself.**
A yes or a no is equally useful — see [Contributing](#contributing).

The GE and older cachyos rows were measured with the series that predates these
two patches; GE 0001–0011 and older cachyos 0001–0012 are unchanged by that
update.

"Fixes present in shipped DLLs" means the built `d2d1.dll` contains
`d2d_sprite_batch_create` and the Layers strings, and `dinput.dll` / `dinput8.dll`
(both architectures) contain `hid_joystick_find_device` with no `FindDevice`
stub left. That proves the patches compiled into the package — not that they
behave correctly.

The GE and older cachyos hotplug verifications are `WINEDEBUG=+dinput`
captures of a Simagic wheel unplugged and reconnected while on track:

```
hid_joystick_find_device ... matched instance {ae42ba3a-804c-11f1-8001-000044455354}
dinput8_a_CreateDevice   ... guid {ae42ba3a-804c-11f1-8001-000044455354}
hid_joystick_device_try_open detected device type 0x10214
dinput_device_Acquire
hid_joystick_send_force_feedback_command ... command 0x1
```

Force feedback resumes, and `get_instance_from_guid ... not found` — the failure
signature of the old stub — appears zero times in the whole log.

The GE and older cachyos bases resolve the wheel to the *same* `guidInstance`,
which is what GE 0007 and older cachyos 0005 are for — existing bindings survive
a switch between the two tools. `_sauce` 0008 carries the same derivation.

Neither log contains an unhandled exception, a `CreateSpriteBatch` fixme or any
d2d1 error, and both shut down cleanly.

Reports welcome, especially from wheels other than a Simagic base: different
hardware exercises different HID report descriptors.

### Known-benign log noise

Present on the GE and older cachyos bases, none of it caused by these patches:

- `warn:dinput:hid_joystick_find_device ... PID_0001&MI_00 ... not found`, once
  per reconnect. LMU also asks about the wheelbase's second HID interface, which
  is not a joystick and legitimately is not in the cache. `DIERR_DEVICENOTREG` is
  the right answer and the game drops it. Under the old stub this returned
  `DI_OK` with a garbage GUID.
- `warn:dinput:dinput_device_init_user_format ... not found` — the game asks for
  device objects this wheel does not have. Upstream behaviour.
- `warn:dinput:hid_joystick_read HidP_GetUsagesEx returned 0xc0110004` on that
  same secondary interface, and `fixme:dinput:hid_joystick_device_try_open device
  usage ff00:0001 not implemented!` for its vendor-defined usage page.
- One `err:sync:RtlpWaitForCriticalSection ... wait timed out` was seen in the GE
  run, in the force-feedback effect-download path and well before the unplug. It
  appeared once in 580k lines and the game recovered. Worth reporting if you see
  it repeatedly or paired with a visible stall.

## Troubleshooting

**The series won't apply.** `build.sh` already tried an exact apply, a three-way
merge and a rebase from the recorded `BASE` before giving up, so this means
upstream changed the same lines the series changes. The error prints the commands
to redo the rebase by hand; resolve the conflicts, re-export with
`git format-patch` and update `BASE`. See
[Keeping up with new releases](#keeping-up-with-new-releases).

**The clone was interrupted.** Re-run the build; since v2.2 the script repairs
this itself. An aborted clone leaves two states that look fine but are not, and
both used to surface much later as something unrelated:

- `wine/` parked on the upstream *branch tip* instead of the commit the
  superproject pins, because the submodule checkout never finished. The script
  used to preserve that HEAD on every later run, replaying the series onto a
  diverged base — which fails in `joystick_hid.c` and reads as the patches having
  gone stale. It now restores wine's HEAD only when that HEAD actually contains
  the pinned commit, and parks anything else on an `lmu-rescue/<timestamp>`
  branch first.
- Submodules registered at the right commit with an **empty working tree**.
  `git submodule update` considers them up to date and does nothing, so this
  never self-healed; the only symptom was `No rule to make target
  '.../configure.ac'`. They are now repopulated automatically with a forced
  checkout from the submodule's own object store. Repopulating a parent also
  exposes nested submodules the earlier recursive pass could not see, so the
  script re-runs the recursive update before checking for uninitialized
  submodules.

Clone failures during the submodule step are retried three times — sourceware.org
rate-limits `bzip2` with HTTP 429 fairly often.

**The UI is garbled but the game runs.** Layers didn't apply — patches 0004–0006
on GE, 0008–0011 on older cachyos, and 0004–0007 on `_sauce`. Check they are in
`git -C <version>-src/wine log`.

**A wheel replugged mid-session isn't detected.** Capture a log — set LMU's Steam
launch options to `WINEDEBUG=+dinput PROTON_LOG=1 %command%`, reproduce, then:

```bash
grep -E "FindDevice|matched instance|get_instance_from_guid" ~/steam-2399420.log
```

Working looks like `dinput7_FindDevice` → `hid_joystick_find_device ... matched
instance {…}` → `CreateDevice` with that same GUID. A `not found` warning for the
wheel itself, or a `get_instance_from_guid ... not found`, means the fix isn't
doing its job — please open an issue with that excerpt.

**GE build dies fetching `xrandr-1.5.4.tar.xz`** with `ERROR: The certificate of
'xorg.freedesktop.org' has expired`. That is an upstream x.org problem, not this
repo's — proton-ge-custom's Makefile downloads xrandr from `www.x.org` and wget
refuses the expired certificate. Pre-seed the file and the Makefile skips the
download:

```bash
cd GE-Proton11-3-src/contrib
curl -kLO https://www.x.org/releases/individual/app/xrandr-1.5.4.tar.xz
sha512sum xrandr-1.5.4.tar.xz   # must be 2758615a3d212cc5...379da5e5
```

`-k` skips the certificate check, so **verify the hash** — it is the one Alpine
publishes for this release, fetched over a valid connection. Do not skip that step.

**`make succeeded but … has no proton script`.** Older `build.sh` versions
expected `$BUILD_NAME/proton`; `cachyos_11.0_release/_sauce` only leaves
`redist/`. Current `build.sh` normalizes `redist/` and creates the archive and
checksum itself — update the script if you see this.

**`winedmo` fails with `unknown type name 'AVBSFInternal'`.** `e893f50` predates
CachyOS's winedmo/FFmpeg-7 revert. `_sauce` patch 0012 is that revert; if the
series is stale or was partially applied, re-check that 0012 is in
`git -C <version>-src/wine log`.

**Build fails with `configure: No such file or directory`.** Stale stamps from
`--no-clean`. Rebuild without it.

## Contributing

Issues and PRs welcome. Useful things to report:

- **Whether VR initialises.** Top of the list: there is no headset here, so the
  `d3dx9_36` ICO/CUR patch (GE 0012, older cachyos 0013, `_sauce` 0010) has never
  been exercised at runtime by anyone. "VR works" or "VR still fails" both close
  a real gap. If it fails, a `PROTON_LOG=1` log around the point it gives up is
  what's needed.
- A `WINEDEBUG=+dinput PROTON_LOG=1` log for any input problem.
- Whether the series applies to a newer GE tag or cachyos branch — and the
  rebased patches if you did the work.
- Wheels other than the ones listed in Status. Different hardware exercises
  different HID report descriptors.

When rebasing, export your work to patch files in the right `patches/wine/…`
directory before rebuilding — `build.sh` applies the patch files, not whatever
happens to be in `wine/`.

## Credits

- [JacKeTUs](https://github.com/JacKeTUs/wine) — the original `lmu-d2d1-hid` series.
- [GloriousEggroll](https://github.com/GloriousEggroll/proton-ge-custom) — proton-ge-custom.
- [CachyOS](https://github.com/CachyOS/proton-cachyos) — proton-cachyos.
- Structure inspired by [proton-LinUwUx-patch](https://github.com/brcly/proton-LinUwUx-patch).

## License

The patches modify Wine and are therefore under Wine's **LGPL-2.1-or-later**.
See `LICENSE`.

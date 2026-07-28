# Proton + LMU Patch

Wine patches that make **Le Mans Ultimate** run under Proton, plus a script that
builds a ready-to-use Steam compatibility tool with them applied.

Two problems are fixed:

- **The game crashes on race load.** Wine's `d2d1` returns `E_NOTIMPL` from
  `CreateSpriteBatch` without writing the out-parameter; LMU doesn't check the
  HRESULT and dereferences NULL, giving an `EXCEPTION_ACCESS_VIOLATION` (write to
  address 0). Fixing this needs a real `ID2D1SpriteBatch`, and — for the in-game
  UI to actually render rather than come out garbled — Layers and Tint too.
- **A wheel unplugged mid-session never comes back.** Wine's
  `IDirectInput7::FindDevice` is a stub that returns `DI_OK` without writing
  `*pguidInstance`, so LMU passes uninitialised stack memory to `CreateDevice`.

The series started from [JacKeTUs/wine](https://github.com/JacKeTUs/wine)
(`lmu-d2d1-hid`, based on GE-Proton10-34), rebased onto GE-Proton11-3 and
proton-cachyos, with the upstreamed patches dropped and the hotplug fix rewritten.

## Quick start

```bash
git clone <this-repo>
cd proton-LMU-patch
chmod +x build.sh
./build.sh cachyos          # or: ./build.sh   (GE, the default)
```

The script prints the exact install command when it finishes. Restart Steam,
then pick the new tool in LMU's compatibility settings.

**Which base should I pick?** `cachyos` is the more thoroughly tested of the two
— see [Status](#status). Pick `ge` if you already run GE-Proton for everything else.

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
./build.sh                            # default: ge GE-Proton11-3
./build.sh ge GE-Proton11-3           # a specific GE tag
./build.sh cachyos                    # newest proton-cachyos release branch
./build.sh cachyos cachyos_11.0_20260713/main
./build.sh GE-Proton11-3              # variant inferred from the tag name
./build.sh --check-only               # sanity checks only, change nothing
./build.sh -f ge master               # force a fresh re-clone
```

CachyOS cuts a branch per release instead of tagging, so `cachyos` with no branch
resolves the newest `cachyos_*/main` on the remote. `…/main` is the Steam Linux
Runtime flavour (folder suffix `-slr`), `…/main_native` the native one (`-native`).

Other flags: `--skip-patch` (patch layer already applied), `--no-clean` (reuse the
build dir), `-y` (don't prompt before deleting it).

## Installing

The build ends with:

```
GE-Proton11-3-build/GE-Proton11-3-LMU.tar.gz                                  # ge
proton-cachyos-11.0-20260713-slr-build/proton-cachyos-…-slr-LMU.tar.xz        # cachyos
```

Install it with:

```bash
cd GE-Proton11-3-build && make install STEAM_DIR=~/.local/share/Steam
```

or by hand:

```bash
mkdir -p ~/.local/share/Steam/compatibilitytools.d/GE-Proton11-3-LMU
tar -xf GE-Proton11-3-LMU.tar.gz \
    -C ~/.local/share/Steam/compatibilitytools.d/GE-Proton11-3-LMU --strip-components=1
```

Proton's Makefile defaults `STEAM_DIR` to `~/.steam/root`, which is usually a
symlink to the real library but not always — `build.sh` detects the actual
location (`$STEAM_DIR` from the environment wins, then `~/.local/share/Steam`,
`~/.steam/root`, `~/.steam/steam`, the flatpak path) and prints both commands
with it filled in.

Restart Steam, then select the tool in LMU's compatibility settings.

## The patches

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

That is the GE series (11 patches) in `patches/wine/lmu/`. The cachyos series
(12 patches) in `patches/wine/lmu-cachyos/` carries the same fixes in a different
order and split, because cachyos' wine is Valve's rather than GE's and its `d2d1` has
diverged. Each directory has its own README with the full per-patch detail,
including every rebase conflict and how it was resolved:

- [`patches/wine/lmu/README.md`](patches/wine/lmu/README.md) — GE series
- [`patches/wine/lmu-cachyos/README.md`](patches/wine/lmu-cachyos/README.md) — cachyos series

### How each base is handled

|  | proton-ge-custom | proton-cachyos |
| --- | --- | --- |
| LMU series | `git am` into `wine/` | `git am` into `wine/` |
| base patch layer | `protonprep-valve-staging.sh` | none — its Makefile applies `patches/<module>/*.patch` at build time |
| archive | `.tar.gz` | `.tar.xz` |

Both bases end up with the series as **commits** in `wine/`, not in the working
tree: GE's prep script does `git reset --hard HEAD` (uncommitted work would be
lost), and CachyOS rsyncs `wine/` minus `.git` into the build dir, so commits
simply carry over.

### Patch series per base

Each series is rebased onto a specific wine. Another tag will very likely need a
rebase first; `git am` stops and says so. Drop a rebased series into an override
directory and the script picks it up automatically, most specific first:

```
patches/wine/lmu-<version-id>/    e.g. lmu-proton-cachyos-11.0-20260713-slr/
patches/wine/lmu-<variant>/       e.g. lmu-cachyos/
patches/wine/lmu/                 the GE series (default)
```

## Folder structure

Versioned folders, so multiple builds coexist:

```
./
├── build.sh
├── patches/wine/lmu/                        # GE series
├── patches/wine/lmu-cachyos/                # cachyos series
├── GE-Proton11-3-src/                       # cloned source tree
├── GE-Proton11-3-build/                     # build dir + final package
└── proton-cachyos-11.0-20260713-slr-build/  # …one pair per variant+version
```

## Status

Both bases build and package cleanly. What has actually been *run* differs, so
here is exactly what is known, as of 2026-07-28:

| | proton-cachyos | proton-ge-custom |
| --- | --- | --- |
| base tested | `cachyos_11.0_20260713/main` | `GE-Proton11-3` |
| series applies | 12/12, clean | 11/11, clean |
| builds | yes (15m07s) | yes (14m32s) |
| fixes present in shipped DLLs | yes | yes |
| launches, loads onto track | **yes** | not tested yet |
| in-game UI renders correctly | **yes** | not tested yet |
| wheel reconnect mid-session | **yes** | not tested yet |

"Fixes present in shipped DLLs" means the built `d2d1.dll` contains
`d2d_sprite_batch_create` and the Layers strings, and `dinput.dll` / `dinput8.dll`
(both architectures) contain `hid_joystick_find_device` with no `FindDevice`
stub left. That proves the patches compiled into the package — not that they
behave correctly.

The cachyos hotplug verification is a `WINEDEBUG=+dinput` capture of a Simagic
wheel unplugged and reconnected while on track:

```
hid_joystick_find_device ... matched instance {ae42ba3a-804c-11f1-8001-000044455354}
dinput8_a_CreateDevice   ... guid {ae42ba3a-804c-11f1-8001-000044455354}
hid_joystick_device_try_open detected device type 0x10214
dinput_device_Acquire
hid_joystick_send_force_feedback_command ... command 0x1
```

Force feedback resumes, and `get_instance_from_guid ... not found` — the failure
signature of the old stub — appears zero times in the whole log.

GE ships the identical implementation, so it is expected to behave the same, but
nobody has driven it yet. Reports welcome, especially from wheels other than a
Simagic base: different hardware exercises different HID report descriptors.

## Troubleshooting

**`git am` fails.** The series is rebased onto one specific wine revision; a
different tag or branch needs it rebased. The error names the base it expects.
Recover with `git -C <version>-src/wine am --abort`.

**The UI is garbled but the game runs.** Layers didn't apply — patches 0004–0006
on GE, 0008–0011 on cachyos. Check they are in `git -C <version>-src/wine log`.

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

**Build fails with `configure: No such file or directory`.** Stale stamps from
`--no-clean`. Rebuild without it.

## Contributing

Issues and PRs welcome. Useful things to report:

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

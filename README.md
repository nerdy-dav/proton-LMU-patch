# Proton + LMU Patch

Wine patches that make **Le Mans Ultimate** run under Proton, plus a script that
builds a ready-to-use Steam compatibility tool with them applied.

Without these patches LMU dies on race load with an `EXCEPTION_ACCESS_VIOLATION`
(write to address 0): wine's `d2d1` returns `E_NOTIMPL` from `CreateSpriteBatch`
without writing the out-parameter, and LMU dereferences the result without
checking the HRESULT.

The series is rebased from [JacKeTUs/wine](https://github.com/JacKeTUs/wine)
(`lmu-d2d1-hid`, based on GE-Proton10-34) onto **GE-Proton11-3**'s wine, with the
upstreamed patches dropped and one real bug in the original series fixed.

## Requirements

- `git`
- `podman` or `docker` (the build runs inside the steamrt SDK image)
- `make`
- ~60 GB of free disk space

## Usage

Two bases are supported: **`ge`** ([proton-ge-custom](https://github.com/GloriousEggroll/proton-ge-custom),
the default) and **`cachyos`** ([proton-cachyos](https://github.com/CachyOS/proton-cachyos)).

```bash
chmod +x build.sh

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

The series is rebased onto **GE-Proton11-3**'s wine. Another tag — and
proton-cachyos in particular, whose wine is Valve's rather than GE's — will very
likely need it rebased first; `git am` stops and says so.

Drop a rebased series into an override directory and the script picks it up
automatically, most specific first:

```
patches/wine/lmu-<version-id>/    e.g. lmu-proton-cachyos-11.0-20260713-slr/
patches/wine/lmu-<variant>/       e.g. lmu-cachyos/
patches/wine/lmu/                 the GE-Proton11-3 series (default)
```

## Folder structure

Versioned folders, so multiple builds coexist:

```
./
├── build.sh
├── patches/wine/lmu/                        # the patch series
├── GE-Proton11-3-src/                       # cloned source tree
├── GE-Proton11-3-build/                     # build dir + final package
└── proton-cachyos-11.0-20260713-slr-build/  # …one pair per variant+version
```

## Output

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

Restart Steam, then select **GE-Proton11-3-LMU** in LMU's compatibility settings.

## The patches

Full detail, including every rebase conflict and how it was resolved, is in
[`patches/wine/lmu/README.md`](patches/wine/lmu/README.md).

| Patch | Purpose |
| --- | --- |
| 0001 | `ID2D1SpriteBatch` implementation — **the crash fix** |
| 0002 | `Tint` effect stub, `effect_id` tracking |
| 0003 | `debug_d2d_matrix3x2_f` tracing helper |
| 0004 | Move clip stack onto the bitmap |
| 0005 | `PushLayer`/`PopLayer` implementation |
| 0006 | Draw a Tint effect's input bitmap in `DrawImage`; sprite tint in the pixel shader |
| 0007 | Derive `guidInstance` from crc32(names)+serial+VID/PID so wheel bindings persist |
| 0008 | Build fix |
| 0009 | `IDirectInput7::FindDevice` — device hotplug |
| 0010 | Hoist declarations (`-Werror=declaration-after-statement`) |
| 0011 | Fix 0009: look `FindDevice` up by name, not by path |

## Status

**proton-ge-custom (GE-Proton11-3):** the series builds cleanly and produces a
complete tool tree. What has **not** been
verified in-game: whether SpriteBatch/Layers still composite correctly against
upstream's reworked d2d1 effect pipeline, and whether 0011 actually restores
hotplug (it fixes a real bug, but confirming it needs a `WINEDEBUG=+dinput` log).

**proton-cachyos (11.0, branch `cachyos_11.0_20260713/main`):** stock cachyos
has the identical bug — its `CreateSpriteBatch` is the same `E_NOTIMPL` stub and
there is no `dlls/d2d1/sprite_batch.c` — so LMU should reach the menus and die
at race load exactly as on unpatched GE.

`patches/wine/lmu-cachyos/` holds the full series rebased for it — crash fix,
Layers, Tint compositing and the `guidInstance` fix — in 11 patches. The Layers
rebase is the substantial one: cachyos had already reworked
`PushLayer`/`PopLayer`, so the implementation had to be merged on top of that
rather than replacing the old stubs. Details, including every conflict and how
it was resolved, in
[`patches/wine/lmu-cachyos/README.md`](patches/wine/lmu-cachyos/README.md).
Not carried: dinput hotplug (`../lmu/` 0009 + 0011).

**Verified in-game** on 2026-07-28: LMU launches, loads onto the track, and the
in-game UI renders correctly. This is currently the better-tested of the two
bases — the GE build has never been through a race session.

### Open questions (not yet checked)

Both are dinput, both need a wheel plugged in, and neither affects rendering —
noted here so they are not forgotten:

1. **Do wheel bindings persist?** `lmu-cachyos/0005` derives `guidInstance` from
   crc32(instance name + product name) + serial + VID/PID, so the GUID stays
   stable across replugs and LMU's saved control mapping keeps matching. It is
   in the build but has never been exercised. To check: bind a wheel, quit,
   replug it, relaunch, and see whether the bindings survived. If they reset,
   the patch is not doing its job.
2. **Does hotplug work?** Upstream `lmu/0009` (`IDirectInput7::FindDevice`) and
   `lmu/0011` (which fixes a real bug in 0009 — it looked the device up by path
   instead of by name) are **not** carried in the cachyos series. 0009 applies
   cleanly there, 0011 does not, and they have to move together. Symptom to
   watch for: connecting a wheel while LMU is already running and the game not
   noticing it. If that happens, rebasing that pair onto cachyos is the fix.

A `WINEDEBUG=+dinput` log is the artifact worth capturing for either.

## Credits

- [JacKeTUs](https://github.com/JacKeTUs/wine) — the original `lmu-d2d1-hid` series.
- [GloriousEggroll](https://github.com/GloriousEggroll/proton-ge-custom) — proton-ge-custom.
- Structure inspired by [proton-LinUwUx-patch](https://github.com/brcly/proton-LinUwUx-patch).

## License

The patches modify Wine and are therefore under Wine's **LGPL-2.1-or-later**.
See `LICENSE`.

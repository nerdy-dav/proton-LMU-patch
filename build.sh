#!/usr/bin/env bash
#
# ============================================================
#  Proton + LMU Builder
#  Builds GloriousEggroll's proton-ge-custom *or* CachyOS's
#  proton-cachyos with the Le Mans Ultimate wine patch series
#  applied.
# ============================================================
#
# The script is self-contained: it clones the source itself,
# applies patches/wine/lmu/*.patch as commits, runs the base's
# prep layer (GE only), and produces a redistributable Steam
# compat tool.
#
# Usage:
#   ./build.sh                          # ge, newest GE-Proton tag on the remote
#   ./build.sh ge GE-Proton11-3         # a specific GE tag
#   ./build.sh cachyos                  # newest proton-cachyos release branch
#   ./build.sh cachyos cachyos_11.0_20260713/main
#   ./build.sh GE-Proton11-3            # variant inferred from the tag name
#   ./build.sh --check-only             # sanity checks only, change nothing
#   ./build.sh -f ge master             # force a fresh re-clone
#
# Each variant+version gets its own -src/ and -build/ folder, so
# builds never overwrite each other.

set -Eeuo pipefail

VERSION="2.1"
GE_REPO="https://github.com/GloriousEggroll/proton-ge-custom.git"
GE_DEFAULT_TAG="GE-Proton11-3"   # only used if the remote cannot be queried
CACHY_REPO="https://github.com/CachyOS/proton-cachyos.git"
CACHY_FALLBACK_BRANCH="cachyos_11.0_20260713/main"

# Named in messages only. The commit each series was actually built against is
# recorded in patches/wine/<series>/BASE and is what the rebase fallback uses.
REBASE_BASE="GE-Proton11-3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_ROOT="${SCRIPT_DIR}/patches/wine"
GE_PREP="patches/protonprep-valve-staging.sh"

FORCE=0 CHECK_ONLY=0 SKIP_PATCH=0 NO_CLEAN=0 ASSUME_YES=0
VARIANT="" TAG=""

# -------------------- Output --------------------
if [[ -t 1 ]]; then
    R=$'\e[31m' G=$'\e[32m' Y=$'\e[33m' C=$'\e[36m' B=$'\e[1m' N=$'\e[0m'
else
    R= G= Y= C= B= N=
fi
step()   { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok()     { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn()   { printf '  %s!%s %s\n' "$Y" "$N" "$*" >&2; }
die()    { printf '\n%sFAILED:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
header() { printf '%s%s%s\n' "$C$B" "$*" "$N"; }
need()   { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found"; }

trap 'die "unexpected error at line $LINENO"' ERR

usage() {
    sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    exit 0
}

# -------------------- Arguments --------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)     usage ;;
        -f|--force)    FORCE=1; shift ;;
        --check-only)  CHECK_ONLY=1; shift ;;
        --skip-patch)  SKIP_PATCH=1; shift ;;
        --no-clean)    NO_CLEAN=1; shift ;;
        -y|--yes)      ASSUME_YES=1; shift ;;
        ge|proton-ge|eggroll)  VARIANT="ge"; shift ;;
        cachy|cachyos)         VARIANT="cachyos"; shift ;;
        valve|proton)  die "plain Valve Proton is not supported; use 'ge' or 'cachyos'" ;;
        -*)            die "unknown option: $1  (use --help)" ;;
        *)             [[ -z "$TAG" ]] || die "more than one tag given: '$TAG' and '$1'"
                       TAG="$1"; shift ;;
    esac
done

# A bare tag is enough to tell the two apart, so 'ge'/'cachyos' stays optional.
if [[ -z "$VARIANT" ]]; then
    case "$TAG" in
        GE-Proton*|"")  VARIANT="ge" ;;
        cachyos*|proton-cachyos*|experimental_*|proton_*) VARIANT="cachyos" ;;
        *) die "cannot tell which base '$TAG' belongs to — say 'ge' or 'cachyos' explicitly" ;;
    esac
fi

need git; need make; need sed; need tar; need awk

# -------------------- Variant resolution --------------------
# CachyOS cuts a new branch per release rather than tagging, so the default is
# resolved live: the newest cachyos_<ver>_<date>/main branch on the remote.
newest_cachy_branch() {
    git ls-remote --heads "$CACHY_REPO" 'refs/heads/cachyos_*/main' 2>/dev/null \
        | sed 's|.*refs/heads/||' | sort -V | tail -1
}

# GE tags each release, so the default is the newest GE-Proton tag on the
# remote. Release-candidate and other suffixed tags are skipped.
newest_ge_tag() {
    git ls-remote --tags --refs "$GE_REPO" 'GE-Proton*' 2>/dev/null \
        | sed 's|.*refs/tags/||' | grep -E '^GE-Proton[0-9]+-[0-9]+$' \
        | sort -V | tail -1
}

case "$VARIANT" in
    ge)
        REPO="$GE_REPO"
        if [[ -z "$TAG" ]]; then
            TAG="$(newest_ge_tag || true)"
            if [[ -n "$TAG" ]]; then
                ok "newest proton-ge-custom release: $TAG"
            else
                TAG="$GE_DEFAULT_TAG"
                warn "could not query the remote; falling back to $TAG"
            fi
        fi
        ;;
    cachyos)
        REPO="$CACHY_REPO"
        if [[ -z "$TAG" ]]; then
            TAG="$(newest_cachy_branch || true)"
            if [[ -n "$TAG" ]]; then
                ok "newest proton-cachyos release branch: $TAG"
            else
                TAG="$CACHY_FALLBACK_BRANCH"
                warn "could not query the remote; falling back to $TAG"
            fi
        fi
        ;;
esac

# Folder-safe id. CachyOS's '/main' and '/main_native' suffixes name the runtime
# flavour, so they are kept as -slr / -native rather than flattened away.
case "$VARIANT" in
    ge)      VERSION_ID="$(echo "$TAG" | sed -E 's|/|-|g; s/_/-/g')" ;;
    cachyos) VERSION_ID="$(echo "$TAG" | sed -E \
                    -e 's|^cachyos[_-]?|proton-cachyos-|' \
                    -e 's|/main_native$|-native|' \
                    -e 's|/main$|-slr|' \
                    -e 's|/|-|g; s/_/-/g' \
                    -e 's/-+/-/g; s/^-//; s/-$//')" ;;
esac

# The series lives in patches/wine/lmu and is rebased onto GE's wine. A base
# whose wine differs enough to need its own rebase gets an override directory,
# most specific first: lmu-<version-id>, then lmu-<variant>.
PATCH_DIR="${PATCH_ROOT}/lmu"
for candidate in "${PATCH_ROOT}/lmu-${VERSION_ID}" "${PATCH_ROOT}/lmu-${VARIANT}"; do
    if compgen -G "$candidate/*.patch" >/dev/null; then
        PATCH_DIR="$candidate"
        break
    fi
done

# Where Steam lives. Proton's Makefile defaults STEAM_DIR to ~/.steam/root, which
# on some setups is not a symlink to the real library — so detect it and pass it
# through explicitly. $STEAM_DIR from the environment always wins.
if [[ -z "${STEAM_DIR:-}" ]]; then
    for candidate in \
        "$HOME/.local/share/Steam" \
        "$HOME/.steam/root" \
        "$HOME/.steam/steam" \
        "$HOME/.var/app/com.valvesoftware.Steam/data/Steam"
    do
        [[ -d "$candidate" ]] && { STEAM_DIR="$candidate"; break; }
    done
    STEAM_DIR="${STEAM_DIR:-$HOME/.local/share/Steam}"
fi
COMPAT_DIR="$STEAM_DIR/compatibilitytools.d"

SRC="${SCRIPT_DIR}/${VERSION_ID}-src"
BUILD="${SCRIPT_DIR}/${VERSION_ID}-build"
BUILD_NAME="${VERSION_ID}-LMU"
PATCHLOG="$SRC/patchlog.txt"
BUILDLOG="$BUILD/log"

header "============================================================"
header "  Proton + LMU Builder v${VERSION}"
header "  Variant    : $VARIANT"
header "  Tag/Branch : $TAG"
header "  Package    : $BUILD_NAME"
header "============================================================"

########################################
step "Pre-flight checks"
########################################

compgen -G "$PATCH_DIR/*.patch" >/dev/null \
    || die "no patches found in $PATCH_DIR"
ok "patch series: $(ls "$PATCH_DIR"/*.patch | wc -l) patches from ${PATCH_DIR#"$SCRIPT_DIR"/}"
if [[ "$VARIANT" != "ge" && "$PATCH_DIR" == "$PATCH_ROOT/lmu" ]]; then
    warn "using the ${REBASE_BASE}-based series on $VARIANT — expect 'git am' to need a rebase"
    warn "put a rebased series in patches/wine/lmu-${VARIANT}/ (or lmu-${VERSION_ID}/) to override it"
fi

# The build runs inside the steamrt SDK container image; the mingw
# toolchain is not expected on the host.
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    CONTAINER_ENGINE=docker
    ok "docker usable"
elif command -v podman >/dev/null; then
    CONTAINER_ENGINE=podman
    ok "podman available"
else
    die "no usable container engine; the build runs inside the steamrt SDK image"
fi

avail_gb=$(stat -f --format='%a %S' "$SCRIPT_DIR" \
    | awk '{ printf "%d", ($1 * $2) / 1073741824 }')
if (( avail_gb < 60 )); then
    warn "only ${avail_gb}G free — source + build wants ~60G"
else
    ok "disk space: ${avail_gb}G free"
fi

########################################
step "Source tree"
########################################

if [[ -d "$SRC/.git" && $FORCE -eq 0 ]]; then
    ok "reusing $SRC (use --force to re-clone)"
else
    (( FORCE )) && rm -rf "$SRC"
    echo "  cloning $REPO @ $TAG"
    git clone --branch "$TAG" "$REPO" "$SRC" 2>/dev/null \
        || { git clone "$REPO" "$SRC" && git -C "$SRC" checkout "$TAG"; } \
        || die "could not clone/checkout '$TAG'"
    ok "cloned to $SRC"
fi

cd "$SRC"

# Nine submodule working trees were once found emptied (.git present,
# correct commit, zero files), which surfaces only as a baffling
# "No rule to make target '.../configure.ac'".
#
# 'git submodule update' checks wine out at the commit the superproject pins,
# which silently throws away the patch series -- and any local work on top of
# it. Remember where wine was and put it back afterwards; the series is
# normally re-applied below, but hand-written commits that are not yet exported
# to patch files would otherwise be lost (recoverable only via the reflog).
wine_head=""
[[ -d wine/.git || -f wine/.git ]] && wine_head=$(git -C wine rev-parse HEAD 2>/dev/null || true)

echo "  updating submodules (this takes a while on first run)"
git submodule update --init --recursive || die "submodule update failed"

if [[ -n "$wine_head" ]] && [[ "$(git -C wine rev-parse HEAD)" != "$wine_head" ]]; then
    git -C wine checkout -q "$wine_head" \
        || die "submodule update moved wine/ off $wine_head and it could not be restored"
    warn "restored wine/ to $(git -C wine rev-parse --short HEAD) (submodule update had reset it)"
fi

empty=$(git submodule foreach --recursive --quiet \
    'if [ "$(ls -A | grep -cv "^\.git$")" = "0" ]; then echo "$sm_path"; fi; true')
if [[ -n "$empty" ]]; then
    printf '%s\n' "$empty" | sed 's/^/      /'
    die "submodule working trees above are empty. Restore with:
       git submodule update --init --recursive -- <path>...
     Do NOT add --force globally: it also reverts the patch layer in wine/."
fi
ok "all submodule working trees populated"

uninit=$(git submodule status --recursive | awk '/^-/ {print $2}')
[[ -z "$uninit" ]] || { printf '%s\n' "$uninit" | sed 's/^/      /'
    die "submodules above are uninitialized"; }
ok "all nested submodules initialized"

########################################
step "Applying the LMU wine series"
########################################

# These are applied as commits (git am), not to the working tree. Both bases
# end up with them:
#   GE      — prep does 'git reset --hard HEAD' in wine/, so anything
#             uncommitted would be lost; commits survive it.
#   CachyOS — has no prep layer at all; its Makefile rsyncs wine/ (minus .git)
#             into the build dir, so committed content is simply carried over.
lmu_total=0 lmu_found=0 lmu_missing=()
count_series() {
    lmu_total=0 lmu_found=0 lmu_missing=()
    local wine_log; wine_log="$(git -C wine log --format=%s -50)"
    local p subject
    for p in "$PATCH_DIR"/*.patch; do
        lmu_total=$((lmu_total + 1))
        subject=$(sed -n 's/^Subject: \[PATCH[^]]*\] //p' "$p" | head -1)
        [[ -n "$subject" ]] || continue
        # Match on a prefix: subjects get rewrapped, and some were amended.
        if grep -qF "${subject:0:40}" <<<"$wine_log"; then
            lmu_found=$((lmu_found + 1))
        else
            lmu_missing+=("$(basename "$p")")
        fi
    done
}

# Each series records the wine commit it was authored against in a BASE file.
# When the base has moved on, we can replay the series there and let git rebase
# do a real three-way merge instead of demanding the old context back.
series_base() {
    [[ -f "$PATCH_DIR/BASE" ]] || return 1
    sed -n 's/^commit[[:space:]]\+//p' "$PATCH_DIR/BASE" | head -1
}

# Applying the series, easiest mechanism first:
#   1. plain 'git am'            — exact context, the usual case
#   2. 'git am -3'               — three-way where the pre-image blobs are around
#   3. replay at BASE + rebase   — real merge against a base that has moved on
# Anything left is a genuine conflict that wants a human.
apply_series() {
    local base head
    head="$(git -C wine rev-parse HEAD)"

    if git -C wine am "$PATCH_DIR"/*.patch 2>&1 | sed 's/^/      /'; then
        ok "applied $lmu_total patches"
        return
    fi
    git -C wine am --abort 2>/dev/null || true

    warn "exact apply failed — the base has moved; trying a three-way merge"
    if git -C wine am -3 "$PATCH_DIR"/*.patch 2>&1 | sed 's/^/      /'; then
        ok "applied $lmu_total patches (three-way)"
        warn "context drifted: re-export the series with 'git format-patch' and"
        warn "update $(basename "$PATCH_DIR")/BASE so the next build takes the fast path"
        return
    fi
    git -C wine am --abort 2>/dev/null || true

    if ! base="$(series_base)" || [[ -z "$base" ]]; then
        die "git am failed and $(basename "$PATCH_DIR")/BASE records no base commit to rebase from.
     Rebase the series by hand and re-export it to ${PATCH_DIR#"$SCRIPT_DIR"/}."
    fi

    warn "three-way failed too — replaying the series at its recorded base and rebasing"
    if ! git -C wine cat-file -e "${base}^{commit}" 2>/dev/null; then
        echo "      fetching base commit $base"
        git -C wine fetch --quiet origin "$base" 2>/dev/null \
            || git -C wine fetch --quiet --tags origin 2>/dev/null || true
    fi
    git -C wine cat-file -e "${base}^{commit}" 2>/dev/null || die \
        "base commit $base is not in the wine clone and could not be fetched.
     It may have been garbage-collected upstream. Rebase the series by hand."

    git -C wine checkout --quiet -B lmu-series "$base" \
        || die "could not check out the recorded base $base"
    git -C wine am "$PATCH_DIR"/*.patch >/dev/null 2>&1 || {
        git -C wine am --abort 2>/dev/null || true
        git -C wine checkout --quiet --detach "$head"
        die "the series does not even apply to its own recorded base $base.
     $(basename "$PATCH_DIR")/BASE is wrong, or the patches were edited by hand."
    }

    if git -C wine rebase --onto "$head" "$base" lmu-series 2>&1 | sed 's/^/      /'; then
        git -C wine checkout --quiet --detach lmu-series
        ok "rebased $lmu_total patches from $(git -C wine rev-parse --short "$base") onto $(git -C wine rev-parse --short "$head")"
        warn "this build carries a rebased series that is NOT what is in ${PATCH_DIR#"$SCRIPT_DIR"/}."
        warn "if it works, export it and update BASE:"
        warn "  git -C $SRC/wine format-patch -$lmu_total --no-signature -o ${PATCH_DIR#"$SCRIPT_DIR"/}"
        return
    fi

    git -C wine rebase --abort 2>/dev/null || true
    git -C wine checkout --quiet --detach "$head"
    die "the series conflicts with this base and needs a human. To do it by hand:
       git -C $SRC/wine checkout -B lmu-series $base
       git -C $SRC/wine am ${PATCH_DIR#"$SCRIPT_DIR"/}/*.patch
       git -C $SRC/wine rebase --onto $head $base lmu-series
     resolve, then re-export with 'git format-patch' and update BASE."
}

# CachyOS's build applies every patches/wine/*.patch in the source tree on top
# of the rsynced copy. Ours are commits, so a stray copy there would be applied
# a second time and fail the build.
if [[ "$VARIANT" == "cachyos" ]]; then
    stray=$( { find patches/wine -name '*.patch' 2>/dev/null || true; } | wc -l)
    (( stray == 0 )) || warn "$stray patch(es) in $SRC/patches/wine will also be applied by the build"
fi

count_series
if (( lmu_found == lmu_total )); then
    ok "series already in wine history ($lmu_found/$lmu_total)"
elif (( SKIP_PATCH )); then
    warn "--skip-patch: series is incomplete ($lmu_found/$lmu_total), continuing anyway"
else
    if (( lmu_found > 0 )); then
        die "wine history has a partial series ($lmu_found/$lmu_total).
     Reset it before retrying:
       git -C $SRC/wine am --abort 2>/dev/null; git -C $SRC/wine reset --hard @{upstream}"
    fi
    apply_series
    count_series
    (( lmu_found == lmu_total )) || die "series applied but verification found only $lmu_found/$lmu_total"
    ok "applied $lmu_total patches"
fi
ok "wine HEAD $(git -C wine rev-parse --short HEAD)"

if (( CHECK_ONLY )); then
    printf '\n%sPre-flight checks passed.%s\n' "$G" "$N"
    exit 0
fi

########################################
step "Base patch layer"
########################################

if [[ "$VARIANT" == "ge" ]]; then
    [[ -f "$GE_PREP" ]] || die "$GE_PREP not found — is this a proton-ge-custom checkout?"

    echo "  running $GE_PREP (output -> $(basename "$PATCHLOG"))"
    if ! "./$GE_PREP" &> "$PATCHLOG"; then
        tail -20 "$PATCHLOG" | sed 's/^/      /'
        die "prep script exited non-zero; see $PATCHLOG"
    fi
    ok "prep script finished ($(wc -l < "$PATCHLOG") lines)"

    # A rejected hunk does not fail the script — patch(1) keeps going and the
    # damage only shows up as a compile error much later.
    if grep -inE 'FAILED|hunk.*ignored|can.t find file|Reversed \(or previously applied\)' \
            "$PATCHLOG" > "$SRC/.patchfail" 2>/dev/null; then
        sed 's/^/      /' "$SRC/.patchfail"; rm -f "$SRC/.patchfail"
        die "patch failures above — fix before building, or the build dies deep in wine"
    fi
    rm -f "$SRC/.patchfail"
    ok "no rejected hunks"
else
    # proton-cachyos carries its patches in the submodules themselves and
    # applies patches/<module>/*.patch from the Makefile at build time. There
    # is nothing to run here.
    ok "proton-cachyos: no prep layer to run (patches applied by the Makefile)"
fi

########################################
step "Post-patch verification"
########################################

if [[ "$VARIANT" == "ge" ]]; then
    # The GE layer is applied to wine's working tree, so a clean tree means it
    # is missing entirely (e.g. after 'git submodule update --force').
    modified=$(git -C wine status --porcelain | grep -vc '^??' || true)
    (( modified > 0 )) || die "wine/ has no modified tracked files — the GE patch layer is not applied"
    ok "wine working tree carries the patch layer ($modified files modified)"

    # Concrete assertion: the winedmo patch rewrites this file off FFmpeg's
    # removed AVBSFInternal onto its own WineFFBSFContext. Unpatched, it cannot
    # compile against the shipped ffmpeg.
    bsf="wine/dlls/winedmo/libavcodec/pcm_byte_order_reverse_bsf.c"
    if [[ -f "$bsf" ]]; then
        grep -q 'AVBSFInternal' "$bsf" \
            && die "$bsf still uses AVBSFInternal — ge-video-rework did not apply. Check $PATCHLOG."
        grep -q 'WineFFBSFContext' "$bsf" \
            && ok "winedmo ffmpeg compat applied" \
            || warn "$bsf has neither marker — patch may have changed shape"
    fi

    [[ -f wine/dlls/wineopenxr/openxr.c ]] \
        && ok "wineopenxr copied into wine/dlls" \
        || warn "wine/dlls/wineopenxr/openxr.c missing"
else
    # Nothing rewrites wine/ before the build here, so the only thing worth
    # asserting is that the crash fix really is in the tree the build will copy.
    grep -rq 'ID2D1SpriteBatch' wine/dlls/d2d1/ \
        && ok "d2d1 sources carry the SpriteBatch implementation" \
        || die "wine/dlls/d2d1 has no ID2D1SpriteBatch — the series is not in the working tree"
    [[ -d wineopenxr ]] \
        && ok "wineopenxr present" \
        || warn "wineopenxr/ missing — unexpected for proton-cachyos"
fi

########################################
step "Build"
########################################

if (( NO_CLEAN )); then
    # Source dirs are rsynced with --delete and no --exclude configure, so a
    # re-sync can delete a generated configure that make already stat'd as
    # present -> "env: '.../configure': No such file or directory" (Error 127).
    warn "--no-clean: stale stamps can cause spurious 'configure: No such file' errors"
    warn "if that happens: rm -f $BUILD/.<module>-source $BUILD/.<module>-post-source"

    # 'make redist' installs the tool tree read-only (mode 555), so a second
    # run cannot overwrite it: "cp: cannot create regular file ...: Permission
    # denied", usually on whichever module happens to install first.
    if [[ -d "$BUILD/dist" ]]; then
        chmod -R u+w "$BUILD/dist" 2>/dev/null || true
        ok "made $BUILD/dist writable again"
    fi

    # 'redist' does 'mv ./redist $(BUILD_NAME)', which does not overwrite: with
    # last run's output still in place it moves redist/ *inside* it instead and
    # then fails with "cannot overwrite ...: Directory not empty".
    if [[ -d "$BUILD/$BUILD_NAME" || -d "$BUILD/redist" ]]; then
        chmod -R u+w "$BUILD/$BUILD_NAME" 2>/dev/null || true
        rm -rf "$BUILD/$BUILD_NAME" "$BUILD/redist"
        ok "removed the previous package tree so 'make redist' can recreate it"
    fi
else
    if [[ -d "$BUILD" ]] && (( ! ASSUME_YES )); then
        read -rp "  delete $BUILD and rebuild from scratch? [y/N] " reply
        [[ "$reply" == [yY]* ]] || die "aborted by user"
    fi
    rm -rf "$BUILD"
fi

mkdir -p "$BUILD"
cd "$BUILD"
"$SRC/configure.sh" --build-name="$BUILD_NAME" --container-engine="$CONTAINER_ENGINE"
ok "configured as $BUILD_NAME"

echo "  building (output -> $BUILDLOG); this takes a long time"
start=$SECONDS
build_rc=0
make redist &> "$BUILDLOG" || build_rc=$?
elapsed=$(( SECONDS - start ))

########################################
step "Build result"
########################################

printf '  elapsed: %dm%02ds, log: %s (%s lines)\n' \
    $(( elapsed / 60 )) $(( elapsed % 60 )) "$BUILDLOG" "$(wc -l < "$BUILDLOG")"

if (( build_rc != 0 )); then
    # Parallel make interleaves output, so the tail is usually unrelated
    # noise. Grep for the real errors instead.
    echo
    echo "  first real errors:"
    grep -nE ': (error|fatal error):|No rule to make target|Error 127|ERROR:|\*\*\* \[' \
        "$BUILDLOG" | head -15 | sed 's/^/      /'
    echo
    echo "  meson configure errors, if any:"
    grep -h 'ERROR:' "$BUILD"/obj-*/meson-logs/meson-log.txt 2>/dev/null \
        | sort -u | head -5 | sed 's/^/      /'
    die "make redist exited $build_rc"
fi

# Both bases emit $BUILD/$BUILD_NAME/ plus an archive and checksum alongside it
# -- there is no redist/ directory, despite GE's README wording. GE compresses
# with gzip, CachyOS with xz.
tree="$BUILD/$BUILD_NAME"
tarball=""
for ext in tar.xz tar.gz; do
    [[ -f "$BUILD/$BUILD_NAME.$ext" ]] && { tarball="$BUILD/$BUILD_NAME.$ext"; break; }
done

[[ -f "$tree/proton" ]] || die "make succeeded but $tree has no proton script"
[[ -d "$tree/files/lib" || -d "$tree/files/lib64" ]] \
    || die "make succeeded but $tree looks incomplete (no files/lib or files/lib64)"
ok "tool tree: $tree ($(du -sh "$tree" | cut -f1))"

if [[ -n "$tarball" ]]; then
    if [[ -f "$BUILD/$BUILD_NAME.sha512sum" ]] \
        && ( cd "$BUILD" && sha512sum -c --status "$BUILD_NAME.sha512sum" 2>/dev/null ); then
        ok "tarball verified: $(basename "$tarball") ($(du -h "$tarball" | cut -f1))"
    else
        warn "tarball present but checksum did not verify"
    fi
else
    warn "no tarball found — install from the tool tree instead"
fi

# Spot-check that the patched modules actually produced DLLs. wineopenxr is
# built into wine on GE and shipped separately by CachyOS, so it is only
# checked where it is expected.
dlls=(d2d1 dinput8 winedmo)
[[ "$VARIANT" == "ge" ]] && dlls+=(wineopenxr)
for dll in "${dlls[@]}"; do
    compgen -G "$tree/files/lib*/wine/x86_64-windows/$dll.dll" >/dev/null \
        || warn "$dll.dll missing from the build"
done
ok "checked patched modules (${dlls[*]})"

echo
header "============================================================"
header "  BUILD SUCCESSFUL"
header "============================================================"
printf '  %sVariant%s  : %s\n'    "$B" "$N" "$VARIANT"
printf '  %sTag%s      : %s\n'    "$B" "$N" "$TAG"
printf '  %sSource%s   : %s\n'    "$B" "$N" "$SRC"
printf '  %sPackage%s  : %s\n'    "$B" "$N" "${tarball:-$tree}"
header "============================================================"
echo
echo "Install with:"
echo "  cd $BUILD && make install STEAM_DIR=$STEAM_DIR"
echo
if [[ -n "$tarball" ]]; then
    echo "or manually:"
    echo "  mkdir -p $COMPAT_DIR/$BUILD_NAME"
    echo "  tar -xf \"$tarball\" -C $COMPAT_DIR/$BUILD_NAME --strip-components=1"
    echo
fi
echo "Then restart Steam and select $BUILD_NAME for Le Mans Ultimate."

#!/bin/sh
# Build the strata-amd image from a Strata release.
#   ./build.sh                  the latest release of Niko1221/Strata
#   ./build.sh --ref v0.1.42    one release (what a deployment should pin)
#   ./build.sh --src DIR        a Strata source folder you already have (a checkout, a patched tree)
# Options: --arch gfx1151 (the GPU the engine is compiled for), --suffix TEXT (added to the image tag),
#          --repo OWNER/NAME (default Niko1221/Strata).
# The release is downloaded to ./src/<tag>/ once and reused; the Dockerfile gets it as the named build context
# "strata". Image tags: strata-amd:<version>-<arch>[-suffix] and strata-amd:latest.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="Niko1221/Strata"; REF="${STRATA_REF:-latest}"; ARCH="${GPU_ARCH:-gfx1151}"; SRC=""; SUFFIX=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF="$2"; shift 2 ;;
    --src) SRC="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    --suffix) SUFFIX="-$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done
case "$ARCH" in gfx[0-9a-f]*) ;; *) echo "bad --arch: $ARCH" >&2; exit 2 ;; esac
case "$REPO" in */*) ;; *) echo "bad --repo: $REPO" >&2; exit 2 ;; esac

if [ -n "$SRC" ]; then
  [ -f "$SRC/CMakeLists.txt" ] && [ -f "$SRC/setup.py" ] || { echo "$SRC is not a Strata source folder" >&2; exit 1; }
  SRC="$(cd "$SRC" && pwd)"
  REF="local:$(git -C "$SRC" describe --tags --always 2>/dev/null || basename "$SRC")"
else
  if [ "$REF" = "latest" ]; then
    REF="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"])')"
  fi
  case "$REF" in v[0-9]*) ;; *) echo "not a release tag: $REF" >&2; exit 2 ;; esac
  case "$REF" in *[!0-9A-Za-z._-]*) echo "not a release tag: $REF" >&2; exit 2 ;; esac
  SRC="$HERE/src/${REPO%%/*}-${REPO##*/}-$REF"
  if [ ! -f "$SRC/setup.py" ]; then
    echo "downloading $REPO $REF ..."
    mkdir -p "$HERE/src"; rm -rf "$SRC.tmp"; mkdir "$SRC.tmp"
    curl -fL --retry 3 -o "$SRC.tar.gz" "https://github.com/$REPO/archive/refs/tags/$REF.tar.gz"
    echo "sha256 $(sha256sum "$SRC.tar.gz" | cut -d' ' -f1)  $REF" | tee "$SRC.sha256"
    tar -xzf "$SRC.tar.gz" --strip-components=1 -C "$SRC.tmp"
    [ -f "$SRC.tmp/setup.py" ] || { echo "the download is not a Strata source tree" >&2; rm -rf "$SRC.tmp"; exit 1; }
    mv "$SRC.tmp" "$SRC"
  else
    echo "using the cached $SRC"
  fi
fi

VER="$(sed -n 's/.*project(strata VERSION \([0-9.]*\).*/\1/p' "$SRC/CMakeLists.txt" | head -1)"
[ -n "$VER" ] || { echo "no project version in $SRC/CMakeLists.txt" >&2; exit 1; }
TAG="strata-amd:${VER}-${ARCH}${SUFFIX}"
echo "building $TAG from $REF ($SRC)"
DOCKER_BUILDKIT=1 docker build --build-context strata="$SRC" \
  --build-arg GPU_ARCH="$ARCH" --build-arg STRATA_REF="$REF" \
  -t "$TAG" -t strata-amd:latest "$HERE"
echo "built $TAG"

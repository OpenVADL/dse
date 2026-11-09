#!/usr/bin/env bash
#
# Generate a QEMU ISS with OpenVADL and compile it for one ISA variant.
# Reuse sources in gen/VARIANT/iss and write logs and results to results/VARIANT.
# --clean removes only compiled outputs. Requires OpenVADL in PATH.
# Run from any directory. Relative paths resolve from the dse project root.
# Supports Bash 3.2 on macOS and Bash on Linux.

set -euo pipefail

# ---------------------------------------------------------------------------
# Shared helpers and defaults
# ---------------------------------------------------------------------------
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/lib/build-common.sh"
VARIANT=""
JOBS=""
CLEAN=0
CACHE=auto

# ---------------------------------------------------------------------------
# Help and argument parsing
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") --variant NAME [--jobs N] [--cache TOOL] [--clean]

Generate and build a QEMU ISS with OpenVADL from PATH.

  --variant NAME   Required: rv32i, crc0, crc1, crc2, or crc012.
  -j, --jobs N     Parallel build jobs. Default: available CPU count.
  --cache TOOL     auto, ccache, sccache, or none. Default: auto.
                   auto prefers ccache, then sccache, then none.
  --clean          Remove compiled outputs. Preserve QEMU sources.
  -h, --help       Show this help.

Sources and binaries: gen/NAME/iss/ (binary in build/).
Logs and timings: results/NAME/.
The script manages the project's Python environment and its packages.
The script tries python3, then python, and requires Python 3.11 or newer.
Set PYTHON to select the base Python executable without fallback.
Relative paths start at the dse project root.
On the first run, OpenVADL downloads QEMU and can request source confirmation.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --variant) need_arg "$@"; VARIANT="$2"; shift 2 ;;
    -j|--jobs) need_arg "$@"; JOBS="$2"; shift 2 ;;
    --cache) need_arg "$@"; CACHE="$2"; shift 2 ;;
    --clean) CLEAN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option '$1'" ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation and dependency checks
# ---------------------------------------------------------------------------
prepare_backend_build iss

# ---------------------------------------------------------------------------
# Output paths and QEMU source initialization
# ---------------------------------------------------------------------------
OUTPUT_DIR="$ROOT/gen/$VARIANT"
GEN_DIR="$OUTPUT_DIR/iss"
BUILD_DIR="$GEN_DIR/build"
RESULT_DIR="$ROOT/results/$VARIANT"
TARGET="$(printf '%s' "$ISA" | tr '[:upper:]' '[:lower:]')"
BINARY="$BUILD_DIR/qemu-system-$TARGET"
INIT_ARGS=()
if [ ! -f "$GEN_DIR/configure" ] || [ ! -f "$GEN_DIR/Makefile" ] ||
   [ ! -f "$GEN_DIR/VERSION" ] || [ ! -f "$GEN_DIR/meson.build" ]; then
  INIT_ARGS=(--init)
fi

# ---------------------------------------------------------------------------
# Logs and result recording, including failed builds
# ---------------------------------------------------------------------------
start_build_recording iss

report "Variant: $VARIANT ($ISA)"
report "QEMU sources: $GEN_DIR"
report "Compiler cache: $CACHE"

# ---------------------------------------------------------------------------
# Step 1: QEMU source generation
# ---------------------------------------------------------------------------
report "Step 1: Generating QEMU sources"
STAGE=generation
start="$(now)"
# Bash 3.2 treats an empty array as unset under nounset.
run openvadl iss "${MODEL_ARGS[@]}" --output "$OUTPUT_DIR" \
  ${INIT_ARGS[@]+"${INIT_ARGS[@]}"} "$SPEC"
GENERATION_SECONDS="$(elapsed "$start" "$(now)")"
[ -f "$GEN_DIR/configure" ] || die "QEMU sources are missing from '$GEN_DIR'"

# ---------------------------------------------------------------------------
# Step 2: QEMU configuration and compilation
# ---------------------------------------------------------------------------
report "Step 2: Building QEMU"
STAGE=build
start="$(now)"
if [ "$CLEAN" -eq 1 ]; then
  run rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
use_compiler_cache "$CACHE"
configure_compiler_cache_paths "$CACHE" "$GEN_DIR"
if [ "$CACHE" != none ]; then
  CFLAGS="$(compiler_cache_flags "${CFLAGS:-}")"
  CXXFLAGS="$(compiler_cache_flags "${CXXFLAGS:-}")"
  OBJCFLAGS="$(compiler_cache_flags "${OBJCFLAGS:-}")"
  export CFLAGS CXXFLAGS OBJCFLAGS
fi
FDT_ARGS=()
if pkg-config --exists libfdt; then
  FDT_ARGS+=("--extra-cflags=$(pkg-config --cflags libfdt)")
  FDT_ARGS+=("--extra-ldflags=$(pkg-config --libs libfdt)")
fi
run "$GEN_DIR/configure" "--target-list=$TARGET-softmmu" "--python=$PYTHON" \
  "--cc=$CC" "--cxx=$CXX" "--objcc=$OBJC" \
  --enable-fdt=system --disable-docs ${FDT_ARGS[@]+"${FDT_ARGS[@]}"}
run make -j "$JOBS"
[ -x "$BINARY" ] || die "QEMU build did not produce '$BINARY'"
BUILD_SECONDS="$(elapsed "$start" "$(now)")"
STAGE=complete
report_compiler_cache_stats "$CACHE"

# ---------------------------------------------------------------------------
# Summary. The exit trap writes run.json and appends build-times.csv.
# ---------------------------------------------------------------------------
report "Generation: $GENERATION_SECONDS s"
report "QEMU build: $BUILD_SECONDS s"
report "Binary: $BINARY"

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
source "$ROOT/scripts/lib/shell.sh"
source "$ROOT/scripts/lib/iss-results.sh"
source "$ROOT/scripts/lib/compiler-cache.sh"
VARIANT=""
JOBS=""
CLEAN=0
CACHE=auto
PYTHON="${PYTHON:-python3}"

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
Set PYTHON to select the base Python executable. Default: python3.
Relative paths start at the dse project root.
On the first run, OpenVADL downloads QEMU and can request source confirmation.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  if [ -n "${LOG:-}" ]; then printf 'error: %s\n' "$*" >> "$LOG"; fi
  exit 1
}
need_arg() { [ $# -ge 2 ] && [ -n "$2" ] || die "option '$1' requires an argument"; }

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
case "$VARIANT" in
  rv32i) ISA=RV32ICustomCrcBase ;;
  crc0) ISA=RV32ICustomCrc0 ;;
  crc1) ISA=RV32ICustomCrc1 ;;
  crc2) ISA=RV32ICustomCrc2 ;;
  crc012) ISA=RV32ICustomCrc ;;
  *) die "pass --variant rv32i, crc0, crc1, crc2, or crc012" ;;
esac
if [ -n "$JOBS" ]; then
  case "$JOBS" in *[!0-9]*|0) die "--jobs requires a positive integer" ;; esac
  [ "${JOBS#0}" = "$JOBS" ] || die "--jobs requires a positive integer without leading zeros"
fi

PYTHON_PATH="$(absolute_command "$PYTHON")" || die "'$PYTHON' not found in PATH"
PYTHON="$PYTHON_PATH"
CACHE="$(select_compiler_cache "$CACHE")" || exit $?
PYTHON="$PYTHON" bash "$ROOT/scripts/check-deps.sh" iss --cache "$CACHE" || exit 1
source "$ROOT/scripts/python-env.sh"
use_project_python "$ROOT" || exit 1
[ -n "$JOBS" ] || JOBS="$(cpu_count)"

# ---------------------------------------------------------------------------
# Output paths and QEMU source initialization
# ---------------------------------------------------------------------------
SPEC="$ROOT/specs/rv32iCustom.vadl"
[ -f "$SPEC" ] || die "specification '$SPEC' does not exist"
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
mkdir -p "$RESULT_DIR"
LOG="$RESULT_DIR/build-iss.log"
: > "$LOG"
COMMANDS="$(mktemp)"
STARTED="$(now)"
GENERATION_SECONDS=0
BUILD_SECONDS=0
STAGE=setup

trap finish_iss EXIT

report "Variant: $VARIANT ($ISA)"
report "QEMU sources: $GEN_DIR"
report "Compiler cache: $CACHE"

# ---------------------------------------------------------------------------
# Step 1: QEMU source generation
# ---------------------------------------------------------------------------
STAGE=generation
start="$(now)"
# Bash 3.2 treats an empty array as unset under nounset.
run openvadl iss --model "TargetIsa=$ISA" --output "$OUTPUT_DIR" \
  ${INIT_ARGS[@]+"${INIT_ARGS[@]}"} "$SPEC"
GENERATION_SECONDS="$(elapsed "$start" "$(now)")"
[ -f "$GEN_DIR/configure" ] || die "QEMU sources are missing from '$GEN_DIR'"

# ---------------------------------------------------------------------------
# Step 2: QEMU configuration and compilation
# ---------------------------------------------------------------------------
STAGE=build
start="$(now)"
if [ "$CLEAN" -eq 1 ]; then
  run rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
use_compiler_cache "$CACHE"
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

# ---------------------------------------------------------------------------
# Summary. The exit trap writes run.json and appends build-times.csv.
# ---------------------------------------------------------------------------
report "Generation: $GENERATION_SECONDS s"
report "QEMU build: $BUILD_SECONDS s"
report "Binary: $BINARY"

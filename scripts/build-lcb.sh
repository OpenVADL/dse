#!/usr/bin/env bash
#
# Generate an LLVM compiler backend (LCB) from a VADL specification.
# Compile the toolchain with the generated Makefile and report generation/build times.
# Requires OpenVADL in PATH. Sources and binaries use --output-dir (default: output).
# Run from any directory. Relative paths resolve from the dse project root.
# Supports Bash 3.2 on macOS and Bash on Linux.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"
source "$SCRIPT_DIR/lib/compiler-cache.sh"
PYTHON="${PYTHON:-python3}"

# ---------------------------------------------------------------------------
# Defaults. Empty LLVM build settings use the generated Makefile's defaults.
# ---------------------------------------------------------------------------
TARGET=""
VARIANT=""
OUTPUT_DIR="output"
CACHE="auto"
BUILD_TYPE=""
# Upstream LLVM targets built next to the generated one.
UPSTREAM_TARGETS="RISCV"
JOBS=""
LINK_JOBS=""
CLEAN=0

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") --variant NAME [options]

Generates the LLVM compiler backend from a VADL specification (openvadl lcb)
and compiles the LLVM toolchain using the generated <output-dir>/lcb/Makefile.
Prints the duration of the VADL generation, the LLVM compilation and the total.
openvadl must be in the PATH.

Specification / generation:
  -t, --target NAME        LLVM target name passed to openvadl
                           (default: spec file name in lower case)
      --variant NAME       ISA to generate the backend for
                           (required):
                             rv32i    RV32I of specs/rv32i.vadl
                             crc0     RV32ICustomCrc0 of specs/rv32iCustom.vadl
                             crc1     RV32ICustomCrc1 of specs/rv32iCustom.vadl
                             crc2     RV32ICustomCrc2 of specs/rv32iCustom.vadl
                             crc012   RV32ICustomCrc (crc0, crc1 and crc2)
                                      of specs/rv32iCustom.vadl
                           The specification paths are relative to the
                           dse project root.
  -o, --output-dir DIR     openvadl output directory; sources and the Makefile
                           are generated into DIR/lcb (default: $OUTPUT_DIR).
                           Relative paths start at the dse project root.

LLVM build (options not given fall back to the generated Makefile's defaults):
      --cache TOOL         Compiler cache used as compiler launcher:
                           auto, ccache, sccache, or none (default: auto).
                           auto prefers ccache, then sccache, then none.
  -b, --build-type TYPE    Debug, Release, RelWithDebInfo or MinSizeRel
                           (LLVM_CMAKE_BUILD_TYPE)
  -j, --jobs N             LLVM_PARALLEL_COMPILE_JOBS
      --link-jobs N        LLVM_PARALLEL_LINK_JOBS
      --clean              Delete the LLVM build directory first (cold build)

The upstream target $UPSTREAM_TARGETS is always built next to the generated one.

  -h, --help               Show this help and exit

Examples:
  $(basename "$0") --variant crc0
  $(basename "$0") --variant rv32i --build-type Release --cache none --clean
  $(basename "$0") --variant crc012 --jobs 8
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

need_arg() {
  [ $# -ge 2 ] && [ -n "$2" ] || die "option '$1' requires an argument"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -t|--target) need_arg "$@"; TARGET="$2"; shift 2 ;;
    --variant) need_arg "$@"; VARIANT="$2"; shift 2 ;;
    -o|--output-dir) need_arg "$@"; OUTPUT_DIR="$2"; shift 2 ;;
    --cache) need_arg "$@"; CACHE="$2"; shift 2 ;;
    -b|--build-type) need_arg "$@"; BUILD_TYPE="$2"; shift 2 ;;
    -j|--jobs) need_arg "$@"; JOBS="$2"; shift 2 ;;
    --link-jobs) need_arg "$@"; LINK_JOBS="$2"; shift 2 ;;
    --clean) CLEAN=1; shift ;;
    *) usage >&2; echo >&2; die "unknown option '$1'" ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation and derived values
# ---------------------------------------------------------------------------
CACHE="$(select_compiler_cache "$CACHE")" || exit $?

case "$BUILD_TYPE" in
  ""|Debug|Release|RelWithDebInfo|MinSizeRel) ;;
  *) die "invalid build type '$BUILD_TYPE' (expected Debug, Release, RelWithDebInfo or MinSizeRel)" ;;
esac

[ -n "$VARIANT" ] || die "no variant given; pass --variant NAME"

# The CRC variants select TargetIsa in rv32iCustom.vadl.
# rv32i.vadl has only one ISA.
SPEC=""
VARIANT_ISA=""
MODEL_ARGS=()
case "$VARIANT" in
  rv32i) SPEC="specs/rv32i.vadl"; VARIANT_ISA="RV32I" ;;
  crc0) SPEC="specs/rv32iCustom.vadl"; VARIANT_ISA="RV32ICustomCrc0" ;;
  crc1) SPEC="specs/rv32iCustom.vadl"; VARIANT_ISA="RV32ICustomCrc1" ;;
  crc2) SPEC="specs/rv32iCustom.vadl"; VARIANT_ISA="RV32ICustomCrc2" ;;
  crc012) SPEC="specs/rv32iCustom.vadl"; VARIANT_ISA="RV32ICustomCrc" ;;
  *) die "invalid variant '$VARIANT' (expected rv32i, crc0, crc1, crc2 or crc012)" ;;
esac
case "$VARIANT" in
  crc*) MODEL_ARGS+=(--model "TargetIsa=$VARIANT_ISA") ;;
esac

[ -f "$SPEC" ] || die "specification '$SPEC' does not exist"
PYTHON="$PYTHON" bash "$SCRIPT_DIR/check-deps.sh" lcb --cache "$CACHE" || exit 1
source "$SCRIPT_DIR/python-env.sh"
use_project_python "$ROOT" || exit 1

if [ -z "$TARGET" ]; then
  TARGET="$(basename "$SPEC" .vadl | tr '[:upper:]' '[:lower:]')"
fi

GEN_DIR="$OUTPUT_DIR/lcb"
MAKEFILE="$GEN_DIR/Makefile"

# Wall-clock time in seconds with millisecond precision. `date +%s.%N` isn't
# supported on macOS, so perl is used instead (available on macOS and Linux).
now() {
  perl -MTime::HiRes=time -e 'printf "%.3f\n", time'
}

elapsed() {
  perl -e 'printf "%.3f\n", $ARGV[1] - $ARGV[0]' "$1" "$2"
}

fmt_duration() {
  perl -e '
    my $t = $ARGV[0];
    my $h = int($t / 3600); my $m = int(($t - $h * 3600) / 60);
    my $s = $t - $h * 3600 - $m * 60;
    printf "%02d:%02d:%06.3f (%.3f s)\n", $h, $m, $s, $t;
  ' "$1"
}

section() {
  printf '\n==> %s\n' "$*"
}

# Reads the value of a plain `VAR=value` or `VAR ?= value` line from the Makefile.
makefile_value() {
  sed -n -E "s/^[[:space:]]*$1[[:space:]]*\??=[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$/\1/p" "$MAKEFILE" | head -n 1
}

# OpenVADL's Makefile selects sccache only for C++.
# Apply the selected launcher to both C and C++.
patch_makefile_launcher() {
  local launcher tmp
  launcher="$(sed -n -E 's/.*-DCMAKE_CXX_COMPILER_LAUNCHER=([^[:space:]\\]*).*/\1/p' "$MAKEFILE" | head -n 1)"
  tmp="$(mktemp)"
  {
    if ! grep -q '^LLVM_COMPILER_LAUNCHER ?=' "$MAKEFILE"; then
      echo "LLVM_COMPILER_LAUNCHER ?= $launcher"
    fi
    sed -E 's/(-DCMAKE_(C|CXX)_COMPILER_LAUNCHER=)[^[:space:]\\]*/\1$(LLVM_COMPILER_LAUNCHER)/g' "$MAKEFILE" |
      if grep -q -- '-DCMAKE_C_COMPILER_LAUNCHER=' "$MAKEFILE"; then
        cat
      else
        sed 's/-DCMAKE_CXX_COMPILER_LAUNCHER=/-DCMAKE_C_COMPILER_LAUNCHER=$(LLVM_COMPILER_LAUNCHER) -DCMAKE_CXX_COMPILER_LAUNCHER=/'
      fi
  } > "$tmp"
  mv "$tmp" "$MAKEFILE"
}

echo "Specification : $SPEC"
echo "Variant       : $VARIANT ($VARIANT_ISA)"
echo "Target        : $TARGET"
echo "Generated dir : $GEN_DIR"
echo "Compiler cache: $CACHE"

VADL_TIME="0"
LLVM_TIME="0"

# ---------------------------------------------------------------------------
# Step 1: VADL generation
# ---------------------------------------------------------------------------
section "Generating LLVM sources from $SPEC"
start="$(now)"
# ${arr[@]+...} avoids an "unbound variable" error for empty arrays in bash 3.2.
openvadl lcb "$SPEC" --output "$OUTPUT_DIR" --target "$TARGET" ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}
VADL_TIME="$(elapsed "$start" "$(now)")"
echo "VADL generation took $(fmt_duration "$VADL_TIME")"

# ---------------------------------------------------------------------------
# Step 2: LLVM compilation with the generated Makefile
# ---------------------------------------------------------------------------
[ -f "$MAKEFILE" ] || die "openvadl generated no Makefile at '$MAKEFILE'"

patch_makefile_launcher

MAKE_VARS=()
[ -z "$BUILD_TYPE" ] || MAKE_VARS+=("LLVM_CMAKE_BUILD_TYPE=$BUILD_TYPE")
MAKE_VARS+=("LLVM_UPSTREAM_TARGETS=$UPSTREAM_TARGETS")
[ -z "$JOBS" ] || MAKE_VARS+=("LLVM_PARALLEL_COMPILE_JOBS=$JOBS")
[ -z "$LINK_JOBS" ] || MAKE_VARS+=("LLVM_PARALLEL_LINK_JOBS=$LINK_JOBS")
# Use the selected cache as the compiler launcher.
# Disable LLVM_CCACHE_BUILD to prevent two caches from running together.
if [ "$CACHE" = none ]; then
  MAKE_VARS+=("LLVM_CCACHE_BUILD=0" "LLVM_COMPILER_LAUNCHER=")
else
  MAKE_VARS+=("LLVM_CCACHE_BUILD=0" "LLVM_COMPILER_LAUNCHER=$CACHE")
fi

BUILD_DIR="$GEN_DIR/$(makefile_value LLVM_SOURCE_PATH)/build"

if [ "$CLEAN" -eq 1 ] && [ -d "$BUILD_DIR" ]; then
  section "Removing build directory $BUILD_DIR"
  rm -rf "$BUILD_DIR"
fi

section "Building LLVM: make build ${MAKE_VARS[*]:-}"
start="$(now)"
# ${arr[@]+...} avoids an "unbound variable" error for empty arrays in bash 3.2.
make -C "$GEN_DIR" build ${MAKE_VARS[@]+"${MAKE_VARS[@]}"}
LLVM_TIME="$(elapsed "$start" "$(now)")"
echo "LLVM compilation took $(fmt_duration "$LLVM_TIME")"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
TOTAL_TIME="$(perl -e 'printf "%.3f\n", $ARGV[0] + $ARGV[1]' "$VADL_TIME" "$LLVM_TIME")"

section "Summary"
printf 'VADL generation : %s\n' "$(fmt_duration "$VADL_TIME")"
printf 'LLVM compilation: %s\n' "$(fmt_duration "$LLVM_TIME")"
printf 'Total           : %s\n' "$(fmt_duration "$TOTAL_TIME")"
printf 'Binaries        : %s/bin\n' "$BUILD_DIR"

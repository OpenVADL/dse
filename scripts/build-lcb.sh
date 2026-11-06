#!/usr/bin/env bash
#
# Generates an LLVM compiler backend (LCB) from a VADL specification and
# compiles the resulting LLVM toolchain with the Makefile that openvadl
# generates. Reports how long each step took. Expects openvadl in the PATH.
#
# Works with the bash 3.2 shipped by macOS as well as with bash on Linux.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults. LLVM build settings left empty are not passed to make, so the
# defaults of the generated Makefile apply.
# ---------------------------------------------------------------------------
TARGET=""
VARIANT=""
OUTPUT_DIR="output"
CACHE="none"
BUILD_TYPE=""
# Upstream LLVM targets built next to the generated one.
UPSTREAM_TARGETS="RISCV"
JOBS=""
LINK_JOBS=""
CLEAN=0

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
                           current directory.
  -o, --output-dir DIR     openvadl output directory; sources and the Makefile
                           are generated into DIR/lcb (default: $OUTPUT_DIR)

LLVM build (options not given fall back to the generated Makefile's defaults):
      --cache TOOL         Compiler cache used as compiler launcher:
                           none, sccache or ccache (default: $CACHE)
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
case "$CACHE" in
  none|sccache|ccache) ;;
  *) die "invalid cache '$CACHE' (expected none, sccache or ccache)" ;;
esac
if [ "$CACHE" != none ]; then
  command -v "$CACHE" >/dev/null || die "'$CACHE' not found in PATH; use --cache none"
fi

case "$BUILD_TYPE" in
  ""|Debug|Release|RelWithDebInfo|MinSizeRel) ;;
  *) die "invalid build type '$BUILD_TYPE' (expected Debug, Release, RelWithDebInfo or MinSizeRel)" ;;
esac

[ -n "$VARIANT" ] || die "no variant given; pass --variant NAME"

# Specification and ISA of the variant. The crc variants override the
# TargetIsa model of rv32iCustom.vadl; rv32i.vadl has only one ISA.
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
command -v openvadl >/dev/null || die "'openvadl' not found in PATH"

if [ -z "$TARGET" ]; then
  TARGET="$(basename "$SPEC" .vadl | tr '[:upper:]' '[:lower:]')"
fi

GEN_DIR="$OUTPUT_DIR/lcb"
MAKEFILE="$GEN_DIR/Makefile"

for tool in make cmake ninja git; do
  command -v "$tool" >/dev/null || die "'$tool' not found in PATH"
done

# Wall-clock time in seconds with millisecond precision. `date +%s.%N` is not
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

# The generated Makefile hard-codes the compiler launcher (sccache) in the cmake
# call. Replace it with a variable that defaults to the original value, so it can
# be disabled from the command line. Running this on a patched Makefile is a no-op.
patch_makefile_launcher() {
  local launcher tmp
  if grep -q '^LLVM_COMPILER_LAUNCHER ?=' "$MAKEFILE"; then
    return
  fi
  launcher="$(sed -n -E 's/.*-DCMAKE_CXX_COMPILER_LAUNCHER=([^[:space:]\\]*).*/\1/p' "$MAKEFILE" | head -n 1)"
  tmp="$(mktemp)"
  {
    echo "LLVM_COMPILER_LAUNCHER ?= $launcher"
    sed -E 's/(-DCMAKE_(C|CXX)_COMPILER_LAUNCHER=)[^[:space:]\\]*/\1$(LLVM_COMPILER_LAUNCHER)/' "$MAKEFILE"
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
# Step 2: LLVM compilation via the generated Makefile
# ---------------------------------------------------------------------------
[ -f "$MAKEFILE" ] || die "openvadl generated no Makefile at '$MAKEFILE'"

patch_makefile_launcher

MAKE_VARS=()
[ -z "$BUILD_TYPE" ] || MAKE_VARS+=("LLVM_CMAKE_BUILD_TYPE=$BUILD_TYPE")
MAKE_VARS+=("LLVM_UPSTREAM_TARGETS=$UPSTREAM_TARGETS")
[ -z "$JOBS" ] || MAKE_VARS+=("LLVM_PARALLEL_COMPILE_JOBS=$JOBS")
[ -z "$LINK_JOBS" ] || MAKE_VARS+=("LLVM_PARALLEL_LINK_JOBS=$LINK_JOBS")
# The cache is always set as compiler launcher. LLVM's own ccache support
# (LLVM_CCACHE_BUILD) is disabled, so no two caches are stacked.
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

#!/usr/bin/env bash
#
# Generate and build an LLVM backend for one ISA variant.
# Reuse sources and compiled outputs. Record logs and results for each variant.
# Run from any directory. Relative paths resolve from the dse project root.
# Supports Bash 3.2 on macOS and Bash on Linux.
set -euo pipefail

# ---------------------------------------------------------------------------
# Shared helpers and defaults
# ---------------------------------------------------------------------------
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/lib/build-common.sh"
source "$ROOT/scripts/lib/llvm-options.sh"
VARIANT=""
TARGET=""
OUTPUT_DIR=""
JOBS=""
LINK_JOBS=1
BUILD_TYPE=MinSizeRel
UPSTREAM_TARGETS=RISCV
CACHE=auto
CLEAN=0
PYTHON="${PYTHON:-python3}"
LLVM_ASSERTIONS=On
LLVM_DUMP=On
LLVM_COMPATIBILITY_WORKAROUND=0

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") --variant NAME [options]

Generate and build the LLVM toolchain with OpenVADL from PATH.

  --variant NAME       Required: rv32i, crc0, crc1, crc2, or crc012.
  -t, --target NAME    LLVM target name. Default: selected ISA in lowercase.
  -o, --output-dir DIR Generation directory. Default: gen/NAME.
  -j, --jobs N         Parallel compilation jobs. Default: available CPU count.
  --link-jobs N        Parallel link jobs. Default: 1.
  -b, --build-type TYPE Debug, Release, RelWithDebInfo, or MinSizeRel (default).
  --cache TOOL         auto, ccache, sccache, or none. Default: auto.
                       auto prefers ccache, then sccache, then none.
  --clean              Remove compiled outputs. Preserve LLVM sources and caches.
  -h, --help           Show this help.

Sources and binaries: gen/NAME/lcb/ (or DIR/lcb/ with --output-dir).
Logs and results: results/NAME/.
Relative paths start at the dse project root.
The script manages the project's Python environment and its packages.
The upstream RISCV target is built alongside the generated target.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --variant) need_arg "$@"; VARIANT="$2"; shift 2 ;;
    -t|--target) need_arg "$@"; TARGET="$2"; shift 2 ;;
    -o|--output-dir) need_arg "$@"; OUTPUT_DIR="$2"; shift 2 ;;
    -j|--jobs) need_arg "$@"; JOBS="$2"; shift 2 ;;
    --link-jobs) need_arg "$@"; LINK_JOBS="$2"; shift 2 ;;
    -b|--build-type) need_arg "$@"; BUILD_TYPE="$2"; shift 2 ;;
    --cache) need_arg "$@"; CACHE="$2"; shift 2 ;;
    --clean) CLEAN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option '$1'" ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation and dependency checks
# ---------------------------------------------------------------------------
case "$BUILD_TYPE" in
  Debug|Release|RelWithDebInfo|MinSizeRel) ;;
  *) die "invalid build type '$BUILD_TYPE'" ;;
esac
prepare_backend_build lcb

# ---------------------------------------------------------------------------
# Output paths and result recording, including failed builds
# ---------------------------------------------------------------------------
[ -n "$TARGET" ] || TARGET="$(printf '%s' "$ISA" | tr '[:upper:]' '[:lower:]')"
[ -n "$OUTPUT_DIR" ] || OUTPUT_DIR="$ROOT/gen/$VARIANT"
if [ "${OUTPUT_DIR:0:1}" != / ]; then OUTPUT_DIR="$ROOT/$OUTPUT_DIR"; fi
GEN_DIR="$OUTPUT_DIR/lcb"
MAKEFILE="$GEN_DIR/Makefile"
BINARY=""
start_build_recording lcb
report "Variant: $VARIANT ($ISA)"
report "LLVM target: $TARGET"
report "LLVM sources: $GEN_DIR"
report "Compiler cache: $CACHE"

# ---------------------------------------------------------------------------
# LLVM Makefile helpers
# ---------------------------------------------------------------------------
# Reads the value of a plain `VAR=value` or `VAR ?= value` line from the Makefile.
makefile_value() {
  sed -n -E "s/^[[:space:]]*$1[[:space:]]*\??=[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$/\1/p" "$MAKEFILE" | head -n 1
}

# OpenVADL's Makefile selects sccache only for C++.
# Apply the selected launcher to both C and C++ and enable dump support.
patch_makefile_options() {
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
      fi |
      if grep -q -- '-DLLVM_ENABLE_DUMP=' "$MAKEFILE"; then
        sed -E 's/(-DLLVM_ENABLE_DUMP=)[^[:space:]\\]*/\1$(LLVM_ENABLE_DUMP)/g'
      else
        sed 's/-DCMAKE_CXX_COMPILER_LAUNCHER=/-DLLVM_ENABLE_DUMP=$(LLVM_ENABLE_DUMP) -DCMAKE_CXX_COMPILER_LAUNCHER=/'
      fi |
      if [ "$CACHE" = none ]; then
        cat
      else
        sed 's/-DCMAKE_CXX_COMPILER_LAUNCHER=/-DCMAKE_C_FLAGS="$$LCB_CACHE_CFLAGS" -DCMAKE_CXX_FLAGS="$$LCB_CACHE_CXXFLAGS" -DCMAKE_CXX_COMPILER_LAUNCHER=/'
      fi
  } > "$tmp"
  mv "$tmp" "$MAKEFILE"
}

# ---------------------------------------------------------------------------
# Step 1: LLVM source generation
# ---------------------------------------------------------------------------
report "Step 1: Generating LLVM sources"
STAGE=generation
start="$(now)"
run openvadl lcb "$SPEC" --output "$OUTPUT_DIR" --target "$TARGET" "${MODEL_ARGS[@]}"
GENERATION_SECONDS="$(elapsed "$start" "$(now)")"

# ---------------------------------------------------------------------------
# Step 2: LLVM configuration and compilation
# ---------------------------------------------------------------------------
report "Step 2: Building LLVM"
STAGE=build
start="$(now)"
[ -f "$MAKEFILE" ] || die "OpenVADL generated no Makefile at '$MAKEFILE'"
patch_makefile_options
LLVM_SOURCE_PATH="$(makefile_value LLVM_SOURCE_PATH)"
[ -n "$LLVM_SOURCE_PATH" ] || die "generated Makefile has no LLVM_SOURCE_PATH"
if [ "${LLVM_SOURCE_PATH:0:1}" = / ]; then
  BUILD_DIR="$LLVM_SOURCE_PATH/build"
else
  BUILD_DIR="$GEN_DIR/$LLVM_SOURCE_PATH/build"
fi
BINARY="$BUILD_DIR/bin/clang"
select_llvm_build_options "$BUILD_DIR"
report "LLVM assertions: $LLVM_ASSERTIONS"
report "LLVM dump support: $LLVM_DUMP"
configure_compiler_cache_paths "$CACHE" "$GEN_DIR"
LCB_CACHE_CFLAGS="${CFLAGS:-}"
LCB_CACHE_CXXFLAGS="${CXXFLAGS:-}"
if [ "$CLEAN" -eq 0 ] && [ -f "$BUILD_DIR/CMakeCache.txt" ]; then
  LCB_CACHE_CFLAGS="$(cmake_cache_value CMAKE_C_FLAGS "$BUILD_DIR")"
  LCB_CACHE_CXXFLAGS="$(cmake_cache_value CMAKE_CXX_FLAGS "$BUILD_DIR")"
fi
LCB_CACHE_CFLAGS="$(compiler_cache_flags "$LCB_CACHE_CFLAGS")"
LCB_CACHE_CXXFLAGS="$(compiler_cache_flags "$LCB_CACHE_CXXFLAGS")"
export LCB_CACHE_CFLAGS LCB_CACHE_CXXFLAGS
if [ "$CLEAN" -eq 1 ] && [ -d "$BUILD_DIR" ]; then
  run rm -rf "$BUILD_DIR"
fi
MAKE_VARS=("LLVM_CMAKE_BUILD_TYPE=$BUILD_TYPE" "LLVM_UPSTREAM_TARGETS=$UPSTREAM_TARGETS"
  "LLVM_PARALLEL_COMPILE_JOBS=$JOBS" "LLVM_PARALLEL_LINK_JOBS=$LINK_JOBS"
  "CMAKE_CXX_STANDARD=17" "LLVM_CCACHE_BUILD=0"
  "LLVM_ENABLE_ASSERTIONS=$LLVM_ASSERTIONS" "LLVM_ENABLE_DUMP=$LLVM_DUMP")
if [ "$CACHE" = none ]; then
  MAKE_VARS+=("LLVM_COMPILER_LAUNCHER=")
else
  MAKE_VARS+=("LLVM_COMPILER_LAUNCHER=$CACHE")
fi
run make -C "$GEN_DIR" build "${MAKE_VARS[@]}"
for tool in clang llc llvm-mc llvm-objdump ld.lld; do
  [ -x "$BUILD_DIR/bin/$tool" ] || die "LLVM build did not produce '$BUILD_DIR/bin/$tool'"
done
BUILD_SECONDS="$(elapsed "$start" "$(now)")"
STAGE=complete
report_compiler_cache_stats "$CACHE"

# ---------------------------------------------------------------------------
# Summary. The exit trap writes run.json and appends build-times.csv.
# ---------------------------------------------------------------------------
report "Generation: $GENERATION_SECONDS s"
report "LLVM build: $BUILD_SECONDS s"
report "Binaries: $BUILD_DIR/bin"

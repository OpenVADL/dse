#!/usr/bin/env bash
# LLVM 19 comparator compatibility with newer libc++, including Xcode 27.
# Upstream fix: https://github.com/llvm/llvm-project/pull/160804

source "$ROOT/scripts/lib/dependencies.sh"

cmake_cache_value() {
  sed -n "s/^$1:[^=]*=//p" "$2/CMakeCache.txt" | head -n 1
}

llvm19_comparator_supported() (
  local build_dir="$1" cached_compiler sdk
  local CXX="${CXX:-c++}" CXXFLAGS="${CXXFLAGS:-}" LDFLAGS="${LDFLAGS:-}" DEPENDENCY_DIR
  DEPENDENCY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dse-llvm-toolchain.XXXXXX")" || return 2
  trap 'rm -rf "$DEPENDENCY_DIR"' EXIT
  if [ "${CLEAN:-0}" -eq 0 ] && [ -f "$build_dir/CMakeCache.txt" ]; then
    cached_compiler="$(cmake_cache_value CMAKE_CXX_COMPILER "$build_dir")"
    [ -z "$cached_compiler" ] || CXX="$(printf '%q' "$cached_compiler")"
    CXXFLAGS="$(cmake_cache_value CMAKE_CXX_FLAGS "$build_dir")"
    LDFLAGS="$(cmake_cache_value CMAKE_EXE_LINKER_FLAGS "$build_dir")"
    sdk="$(cmake_cache_value CMAKE_OSX_SYSROOT "$build_dir")"
    if [ -n "$sdk" ] && [ ! -d "$sdk" ]; then
      sdk="$(xcrun --sdk "$sdk" --show-sdk-path 2>/dev/null)" || return 2
    fi
    [ -z "$sdk" ] || CXXFLAGS="$CXXFLAGS -isysroot $(printf '%q' "$sdk")"
  fi
  compile_probe cxx $'#include <set>\nint main() { std::set<int> s; s.insert(1); }' >/dev/null 2>&1 || return 2
  compile_probe cxx '#include <set>
struct Key { int value; };
namespace std {
template <> struct less<Key> {
  explicit less(const int *state) : state(state) {}
  bool operator()(Key a, Key b) const { return a.value < b.value; }
  const int *state;
};
}
int main() {
  int state = 0;
  std::set<Key, std::less<Key>> values{std::less<Key>(&state)};
  values.insert(Key{1});
}' >/dev/null 2>&1 || return 1
)

select_llvm_build_options() {
  local status
  LLVM_COMPATIBILITY_WORKAROUND=0
  LLVM_DUMP=On
  case "${LLVM_ENABLE_ASSERTIONS:-auto}" in
    On|ON|on|true|TRUE|1) LLVM_ASSERTIONS=On ;;
    Off|OFF|off|false|FALSE|0) LLVM_ASSERTIONS=Off ;;
    auto)
      if llvm19_comparator_supported "$1"; then
        LLVM_ASSERTIONS=On
      else
        status=$?
        [ "$status" -eq 1 ] || die "LLVM C++ toolchain probe failed"
        LLVM_ASSERTIONS=Off
        LLVM_COMPATIBILITY_WORKAROUND=1
        report "Applying LLVM 19 comparator workaround for the selected C++ toolchain"
      fi ;;
    *) die "LLVM_ENABLE_ASSERTIONS must be auto, On, or Off" ;;
  esac
}

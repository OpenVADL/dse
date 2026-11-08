#!/usr/bin/env bash

select_compiler_cache() {
  case "${1:-auto}" in
    auto)
      if command -v ccache >/dev/null 2>&1; then printf 'ccache\n'
      elif command -v sccache >/dev/null 2>&1; then printf 'sccache\n'
      else printf 'none\n'
      fi ;;
    none|ccache|sccache) printf '%s\n' "$1" ;;
    *) printf 'error: invalid cache %s (expected auto, ccache, sccache, or none)\n' "$1" >&2; return 2 ;;
  esac
}

# Map each backend's source tree to the same paths across variants.
# https://ccache.dev/manual/latest.html#_compiling_in_different_directories
configure_compiler_cache_paths() {
  local cache="$1" source_dir="$2"
  COMPILER_CACHE_PATH_FLAG=""
  [ "$cache" != none ] || return 0
  source_dir="$(cd "$source_dir" && pwd -P)" || return 1
  case "$cache" in
    ccache) export CCACHE_BASEDIR="$source_dir" ;;
    sccache) export SCCACHE_BASEDIRS="$source_dir" ;;
  esac
  COMPILER_CACHE_PATH_FLAG="-ffile-prefix-map=$source_dir=."
}

compiler_cache_flags() {
  local flags="$1" word quoted result=""
  [ -n "${COMPILER_CACHE_PATH_FLAG:-}" ] || { printf '%s\n' "$flags"; return; }
  split_shell_words "$flags" || return 1
  for word in ${SHELL_WORDS[@]+"${SHELL_WORDS[@]}"}; do
    # Cached CMake flags can already have this map.
    [ "$word" != "$COMPILER_CACHE_PATH_FLAG" ] || continue
    printf -v quoted '%q' "$word"
    result+="${result:+ }$quoted"
  done
  printf -v quoted '%q' "$COMPILER_CACHE_PATH_FLAG"
  printf '%s\n' "${result}${result:+ }$quoted"
}

cached_compiler() {
  local cache="$1" compiler="$2"
  while :; do
    case "$compiler" in
      'ccache '*|'sccache '*|*/'ccache '*|*/'sccache '*) compiler="${compiler#* }" ;;
      *) break ;;
    esac
  done
  if [ "$cache" = none ]; then printf '%s\n' "$compiler"
  else printf '%s %s\n' "$cache" "$compiler"
  fi
}

use_compiler_cache() {
  local cache="$1" cc="${CC:-cc}" cxx="${CXX:-c++}" objc="${OBJC:-}"
  if [ -z "$objc" ]; then
    if command -v clang >/dev/null 2>&1; then objc=clang; else objc="$cc"; fi
  fi
  CC="$(cached_compiler "$cache" "$cc")"
  CXX="$(cached_compiler "$cache" "$cxx")"
  OBJC="$(cached_compiler "$cache" "$objc")"
  export CC CXX OBJC
}

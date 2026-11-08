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

#!/usr/bin/env bash
#
# Shared shell helpers for executable paths, CPU counts, and compiler settings.
# Source this file. split_shell_words returns its arguments in SHELL_WORDS.
# Supports Bash 3.2 on macOS and Bash on Linux.

# ---------------------------------------------------------------------------
# Executable paths and host CPU count
# ---------------------------------------------------------------------------
qemu_insn_plugin() {
  local path
  for path in "$1/tests/tcg/plugins/libinsn.so" "$1/tests/tcg/plugins/libinsn.dylib"; do
    if [ -f "$path" ]; then printf '%s\n' "$path"; return 0; fi
  done
  return 1
}

absolute_command() {
  local path
  path="$(command -v "$1")" || return 1
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *) printf '%s/%s\n' "$(cd "$(dirname "$path")" && pwd)" "${path##*/}" ;;
  esac
}

select_python() {
  local candidate
  local candidates=("${PYTHON:-python3}")
  if [ -z "${PYTHON:-}" ]; then candidates+=(python); fi
  for candidate in "${candidates[@]}"; do
    if "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 11))' >/dev/null 2>&1; then
      absolute_command "$candidate"
      return $?
    fi
  done
  if [ -n "${PYTHON:-}" ]; then
    printf 'error: PYTHON=%s requires a working Python >= 3.11 interpreter.\n' "$PYTHON" >&2
  else
    printf 'error: Python >= 3.11 not found in PATH (tried python3 and python). Set PYTHON to select an interpreter.\n' >&2
  fi
  return 1
}

cpu_count() {
  local count
  count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || printf '1')"
  case "$count" in ''|*[!0-9]*|0) count=1 ;; esac
  printf '%s\n' "$count"
}

# ---------------------------------------------------------------------------
# Quoted compiler commands and flags
# ---------------------------------------------------------------------------
# Split compiler settings. Don't run substitutions or expand globs.
# Return the words in SHELL_WORDS. Accept shell quotes and backslash escapes.
split_shell_words() {
  local text="$1" word='' quote='' char next active=0 index
  SHELL_WORDS=()
  for ((index = 0; index < ${#text}; index++)); do
    char="${text:index:1}"
    if [ "$quote" = "'" ]; then
      if [ "$char" = "'" ]; then quote=''; else word+="$char"; fi
    elif [ "$char" = '\' ]; then
      ((index + 1 < ${#text})) || return 1
      next="${text:index+1:1}"
      if [ "$quote" = '"' ] && [[ "$next" != [\$\`\"\\] ]] && [ "$next" != $'\n' ]; then
        word+='\'
      else
        index=$((index + 1))
        [ "$next" = $'\n' ] || word+="$next"
      fi
      active=1
    elif [ "$quote" = '"' ]; then
      if [ "$char" = '"' ]; then quote=''; else word+="$char"; fi
    else
      case "$char" in
        "'"|'"') quote="$char"; active=1 ;;
        ' '|$'\t'|$'\r'|$'\n')
          if [ "$active" -eq 1 ]; then SHELL_WORDS+=("$word"); word=''; active=0; fi ;;
        *) word+="$char"; active=1 ;;
      esac
    fi
  done
  [ -z "$quote" ] || return 1
  if [ "$active" -eq 1 ]; then SHELL_WORDS+=("$word"); fi
}

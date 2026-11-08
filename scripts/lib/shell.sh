#!/usr/bin/env bash
#
# Shared shell helpers for executable paths, CPU counts, and compiler settings.
# Source this file. split_shell_words returns its arguments in SHELL_WORDS.
# Supports Bash 3.2 on macOS and Bash on Linux.

# ---------------------------------------------------------------------------
# Executable paths and host CPU count
# ---------------------------------------------------------------------------
absolute_command() {
  local path
  path="$(command -v "$1")" || return 1
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *) printf '%s/%s\n' "$(cd "$(dirname "$path")" && pwd)" "${path##*/}" ;;
  esac
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

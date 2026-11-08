#!/usr/bin/env bash
# Shared validation and setup for ISS and LLVM builds. The caller sets ROOT.

source "$ROOT/scripts/lib/shell.sh"
source "$ROOT/scripts/lib/compiler-cache.sh"
source "$ROOT/scripts/lib/build-results.sh"
source "$ROOT/scripts/python-env.sh"

die() {
  printf 'error: %s\n' "$*" >&2
  if [ -n "${LOG:-}" ]; then printf 'error: %s\n' "$*" >> "$LOG"; fi
  exit 1
}

need_arg() { [ $# -ge 2 ] && [ -n "$2" ] || die "option '$1' requires an argument"; }

validate_positive_integer() {
  case "$2" in ''|*[!0-9]*|0*) die "$1 requires a positive integer without leading zeros" ;; esac
}

select_variant() {
  case "$VARIANT" in
    rv32i) ISA=RV32ICustomCrcBase ;;
    crc0) ISA=RV32ICustomCrc0 ;;
    crc1) ISA=RV32ICustomCrc1 ;;
    crc2) ISA=RV32ICustomCrc2 ;;
    crc012) ISA=RV32ICustomCrc ;;
    *) die "pass --variant rv32i, crc0, crc1, crc2, or crc012" ;;
  esac
  SPEC="$ROOT/specs/rv32iCustom.vadl"
  [ -f "$SPEC" ] || die "specification '$SPEC' does not exist"
  MODEL_ARGS=(--model "TargetIsa=$ISA")
}

prepare_backend_build() {
  select_variant
  [ -z "$JOBS" ] || validate_positive_integer --jobs "$JOBS"
  [ -z "${LINK_JOBS:-}" ] || validate_positive_integer --link-jobs "$LINK_JOBS"
  PYTHON="$(absolute_command "$PYTHON")" || die "Python not found in PATH"
  CACHE="$(select_compiler_cache "$CACHE")" || exit $?
  PYTHON="$PYTHON" bash "$ROOT/scripts/check-deps.sh" "$1" --cache "$CACHE" || exit 1
  use_project_python "$ROOT" || exit 1
  [ -n "$JOBS" ] || JOBS="$(cpu_count)"
}

report_compiler_cache_stats() {
  case "$1" in
    ccache|sccache)
      run "$1" --show-stats || report "warning: failed to read $1 statistics"
      ;;
  esac
}

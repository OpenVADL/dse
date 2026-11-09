#!/usr/bin/env bash
#
# Check common and backend-specific requirements for ISS, LCB, or RTL builds.
# Report all missing or unusable dependencies and exit with status 1.
# Probes use a temporary directory and don't change generated build outputs.
# Run from any directory. Relative paths resolve from the dse project root.
# Supports Bash 3.2 on macOS and Bash on Linux.

set -euo pipefail

# ---------------------------------------------------------------------------
# Shared probes
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"
source "$SCRIPT_DIR/lib/shell.sh"
source "$SCRIPT_DIR/lib/dependencies.sh"
source "$SCRIPT_DIR/lib/compiler-cache.sh"

# ---------------------------------------------------------------------------
# Help, defaults, and argument parsing
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") {iss|lcb|rtl} [--cache {auto|ccache|sccache|none}]

Check build dependencies and list missing requirements.
ISS and LCB try python3, then python, and require Python 3.11 or newer.
Set PYTHON to select the build interpreter without fallback.
For RTL, set VADL_CMD to select OpenVADL. Default: openvadl.
Relative paths start at the dse project root.
EOF
}

BACKEND=''
CACHE=auto
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --cache)
      if [ $# -lt 2 ]; then usage >&2; exit 2; fi
      CACHE="$2"; shift 2 ;;
    iss|lcb|rtl)
      if [ -n "$BACKEND" ]; then usage >&2; exit 2; fi
      BACKEND="$1"; shift ;;
    *) usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation and dependency report
# ---------------------------------------------------------------------------
case "$BACKEND" in
  iss|lcb|rtl) ;;
  *) usage >&2; exit 2 ;;
esac
case "$CACHE" in
  auto|none|sccache|ccache) ;;
  *) usage >&2; exit 2 ;;
esac

CACHE="$(select_compiler_cache "$CACHE")" || exit $?
check_dependencies "$BACKEND" "$CACHE"

#!/usr/bin/env bash
#
# Prepare the project's .venv and select its Python for subsequent build commands.
# Source this file and call use_project_python with the project root.
# Run this file directly to prepare the environment as a standalone step.
# Clear inherited Python module paths so they don't override the environment.
# Supports Bash 3.2 on macOS and Bash on Linux.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell.sh"

# ---------------------------------------------------------------------------
# Environment setup and interpreter selection
# ---------------------------------------------------------------------------
python_environment_identity() {
  "$1" -c 'import os, sys
if sys.argv[1]:
    if sys.prefix == sys.base_prefix or os.path.realpath(sys.prefix) != os.path.realpath(sys.argv[1]):
        sys.exit(1)
print(sys.base_prefix)
print(sys.version.split()[0])' "${2:-}"
}

prepare_project_python() (
  local project_root="$1" base_python directory python log expected actual
  printf 'Preparing project Python environment...\n'
  cd "$project_root" || return 1
  project_root="$(pwd -P)"
  directory="$project_root/.venv"
  python="$directory/bin/python"
  log="$directory/setup.log"
  unset PYTHONPATH PYTHONHOME PIP_TARGET PIP_PREFIX
  base_python="$(select_python)" || return 1
  base_python="$("$base_python" -c 'import sys; print(getattr(sys, "_base_executable", sys.executable))')" || {
    printf 'error: base Python is unavailable\n' >&2
    return 1
  }
  expected="$(python_environment_identity "$base_python")" || return 1
  actual="$(python_environment_identity "$python" "$directory" 2>/dev/null)" || actual=''
  if [ "$actual" != "$expected" ]; then
    rm -rf "$directory" || return 1
    mkdir -p "$directory" || return 1
    if ! "$base_python" -m venv "$directory" > "$log" 2>&1; then
      printf 'error: Python environment creation failed. See %s\n' "$log" >&2
      return 1
    fi
  fi
  export VIRTUAL_ENV="$directory"
  export PATH="$directory/bin:$PATH"
  export PIP_USER=false PIP_REQUIRE_VIRTUALENV=true
  export PIP_CACHE_DIR="$directory/cache"
  if ! {
    "$python" -m pip install --disable-pip-version-check --requirement "$project_root/requirements.txt" &&
    "$python" -m pip check
  } > "$log" 2>&1; then
    printf 'error: Python environment setup failed. See %s\n' "$log" >&2
    return 1
  fi
)

use_project_python() {
  local project_root="$1"
  prepare_project_python "$project_root" || return 1
  export VIRTUAL_ENV="$project_root/.venv"
  export PYTHON="$VIRTUAL_ENV/bin/python"
  export PATH="$VIRTUAL_ENV/bin:$PATH"
  unset PYTHONPATH PYTHONHOME
}

python_env_main() {
  local script_dir project_root
  case "${1:-}" in
    -h|--help)
      printf 'Usage: %s [PROJECT_ROOT]\n' "$(basename "$0")"
      return 0 ;;
  esac
  [ $# -le 1 ] || { printf 'error: expected at most one project root\n' >&2; return 2; }
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  project_root="$(cd "${1:-$script_dir/..}" && pwd -P)" || return 1
  use_project_python "$project_root"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  python_env_main "$@"
fi

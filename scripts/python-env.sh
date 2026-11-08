#!/usr/bin/env bash
#
# Prepare the project's .venv and select its Python for subsequent build commands.
# Source this file and call use_project_python with the project root.
# Clear inherited Python module paths so they don't override the environment.
# Supports Bash 3.2 on macOS and Bash on Linux.

# ---------------------------------------------------------------------------
# Environment setup and interpreter selection
# ---------------------------------------------------------------------------
use_project_python() {
  local project_root="$1"
  "${PYTHON:-python3}" "$project_root/scripts/prepare-python-env.py" "$project_root" || return 1
  export VIRTUAL_ENV="$project_root/.venv"
  export PYTHON="$VIRTUAL_ENV/bin/python"
  export PATH="$VIRTUAL_ENV/bin:$PATH"
  unset PYTHONPATH PYTHONHOME
}

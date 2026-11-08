#!/usr/bin/env bash
#
# Shared dependency probes for check-deps.sh. Source after lib/shell.sh.
# Check tool versions, compiler/linker support, Python venv support, and libraries.
# check_dependencies runs probes in a subshell and removes temporary files on exit.
# Supports Bash 3.2 on macOS and Bash on Linux.

# ---------------------------------------------------------------------------
# Failure collection and tool versions
# ---------------------------------------------------------------------------
check_dependency() {
  local label="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then
    MISSING_DEPENDENCIES+=("$label")
    return 1
  fi
}

version_at_least() {
  local text="$1" minimum="$2" pattern='[0-9]+(\.[0-9]+)+' index actual required
  local found=() expected=()
  [[ "$text" =~ $pattern ]] || return 1
  IFS=. read -r -a found <<< "${BASH_REMATCH[0]}"
  IFS=. read -r -a expected <<< "$minimum"
  for ((index = 0; index < ${#expected[@]}; index++)); do
    actual=$((10#${found[index]:-0}))
    required=$((10#${expected[index]}))
    [ "$actual" -lt "$required" ] && return 1
    [ "$actual" -gt "$required" ] && return 0
  done
  return 0
}

probe_tool() {
  local name="$1" minimum="${2:-}" output
  command -v "$name" >/dev/null || return 1
  output="$("$name" --version)" || return 1
  [ -z "$minimum" ] || version_at_least "$output" "$minimum"
}

check_tool() {
  local name="$1" minimum="${2:-}" label="$1"
  [ -z "$minimum" ] || label+=" >= $minimum"
  check_dependency "$label" probe_tool "$name" "$minimum" || :
}

# ---------------------------------------------------------------------------
# Python virtual-environment support
# ---------------------------------------------------------------------------
probe_virtual_environment() {
  "$PYTHON" -m venv --without-pip --system-site-packages "$DEPENDENCY_DIR/pyvenv" || return 1
  "$DEPENDENCY_DIR/pyvenv/bin/python" -c 'import venv, ensurepip, tomllib'
}

# ---------------------------------------------------------------------------
# Compiler and native-library probes
# ---------------------------------------------------------------------------
compile_probe() {
  local language="$1" source="$2" compiler_setting flags_setting standard path
  local compiler=() flags=() linker_flags=()
  shift 2
  case "$language" in
    c) compiler_setting="${CC:-cc}"; flags_setting="${CFLAGS:-}"; standard=gnu11; path="$DEPENDENCY_DIR/probe.c" ;;
    cxx) compiler_setting="${CXX:-c++}"; flags_setting="${CXXFLAGS:-}"; standard=c++17; path="$DEPENDENCY_DIR/probe.cpp" ;;
  esac
  split_shell_words "$compiler_setting" || return 1
  compiler=( ${SHELL_WORDS[@]+"${SHELL_WORDS[@]}"} )
  [ "${#compiler[@]}" -gt 0 ] || return 1
  split_shell_words "$flags_setting" || return 1
  flags=( ${SHELL_WORDS[@]+"${SHELL_WORDS[@]}"} )
  split_shell_words "${LDFLAGS:-}" || return 1
  linker_flags=( ${SHELL_WORDS[@]+"${SHELL_WORDS[@]}"} )
  printf '%s\n' "$source" > "$path" || return 1
  "${compiler[@]}" "-std=$standard" ${flags[@]+"${flags[@]}"} "$path" \
    -o "$DEPENDENCY_DIR/probe" ${linker_flags[@]+"${linker_flags[@]}"} "$@"
}

probe_library() {
  local package="$1" source="$2" flags
  pkg-config --exists "$package" || return 1
  if [ "$C_COMPILER_AVAILABLE" -eq 1 ]; then
    flags="$(pkg-config --cflags --libs "$package")" || return 1
    split_shell_words "$flags" || return 1
    compile_probe c "$source" ${SHELL_WORDS[@]+"${SHELL_WORDS[@]}"}
  fi
}

probe_libfdt() {
  local source=$'#include <libfdt.h>\n#include <libfdt_env.h>\nint main(void) { return fdt_find_max_phandle(0, 0); }'
  if pkg-config --exists libfdt 2>/dev/null; then
    probe_library 'libfdt >= 1.5.1' "$source"
  else
    compile_probe c "$source" -lfdt
  fi
}

# ---------------------------------------------------------------------------
# Common and backend-specific requirements
# ---------------------------------------------------------------------------
check_common_dependencies() {
  local tool
  check_dependency 'Python >= 3.11' probe_tool "$PYTHON" 3.11 || :
  for tool in openvadl make git; do check_tool "$tool"; done
  check_tool jq 1.6
  check_tool ninja 1.8
  for tool in ar nm ranlib; do check_dependency "$tool" command -v "$tool" || :; done
  C_COMPILER_AVAILABLE=0
  if check_dependency 'C compiler and linker' compile_probe c 'int main(void) { return 0; }'; then
    C_COMPILER_AVAILABLE=1
  fi
  check_dependency 'C++17 compiler and linker' compile_probe cxx \
    $'#include <optional>\nint main() { return std::optional<int>(0).value(); }' || :
  check_dependency 'Python virtual environment support' probe_virtual_environment || :
  if command -v sha256sum >/dev/null; then
    check_dependency sha256sum sha256sum --version || :
  else
    check_dependency 'shasum (SHA-256)' shasum -a 256 /dev/null || :
  fi
}

check_iss_dependencies() {
  local pkg_config_available=0
  check_common_dependencies
  if check_dependency pkg-config probe_tool pkg-config; then pkg_config_available=1; fi
  if [ "$pkg_config_available" -eq 1 ]; then
    check_dependency 'glib-2.0 >= 2.66.0' probe_library 'glib-2.0 >= 2.66.0' \
      $'#include <glib.h>\nint main(void) { g_free(g_malloc(1)); return 0; }' || :
    check_dependency 'gmodule-no-export-2.0 >= 2.66.0' probe_library 'gmodule-no-export-2.0 >= 2.66.0' \
      $'#include <gmodule.h>\nint main(void) { return !g_module_supported(); }' || :
    check_dependency 'pixman-1 >= 0.21.8' probe_library 'pixman-1 >= 0.21.8' \
      $'#include <pixman.h>\nint main(void) { return pixman_version() == 0; }' || :
    check_dependency zlib probe_library zlib \
      $'#include <zlib.h>\nint main(void) { return zlibVersion() == 0; }' || :
  fi
  if [ "$C_COMPILER_AVAILABLE" -eq 1 ]; then
    check_dependency 'libfdt >= 1.5.1 (headers and library)' probe_libfdt || :
  fi
}

check_lcb_dependencies() {
  local cache="$1" tool
  check_common_dependencies
  check_tool cmake 3.20
  for tool in curl tar gzip unzip perl; do check_dependency "$tool" command -v "$tool" || :; done
}

# ---------------------------------------------------------------------------
# Probe lifecycle and combined report
# ---------------------------------------------------------------------------
check_dependencies() (
  local backend="$1" cache="$2"
  local PYTHON="${PYTHON:-python3}" DEPENDENCY_DIR C_COMPILER_AVAILABLE
  local MISSING_DEPENDENCIES=()
  case "$backend" in
    iss) printf 'Checking ISS dependencies...\n' ;;
    lcb) printf 'Checking LCB dependencies...\n' ;;
  esac
  DEPENDENCY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dse-deps.XXXXXX")" || return 1
  trap 'rm -rf "$DEPENDENCY_DIR"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  case "$backend" in
    iss) check_iss_dependencies ;;
    lcb) check_lcb_dependencies "$cache" ;;
  esac
  if [ "$cache" != none ]; then check_dependency "$cache" command -v "$cache" || :; fi
  if [ "${#MISSING_DEPENDENCIES[@]}" -gt 0 ]; then
    printf 'Missing or unusable dependencies:\n' >&2
    printf '  - %s\n' "${MISSING_DEPENDENCIES[@]}" >&2
    printf 'See README.md for installation.\n' >&2
    return 1
  fi
  printf 'Dependency check passed.\n'
)

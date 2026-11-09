#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/lib/build-common.sh"
VARIANT=''
TARGET=''
OUTPUT_DIR=''
LCB_BIN=''
ISS=''
INSN_PLUGIN=''
TIMEOUT=30
SKIP_COMPILE=0
SKIP_ISS=0

usage() {
  cat <<EOF
Usage: $(basename "$0") --variant NAME [options]

Compile CRC32 with the generated LCB and check it on the generated ISS.

  --variant NAME       Required: rv32i, crc0, crc1, crc2, or crc012.
  --skip-compile       Reuse the workload ELF.
  --skip-iss           Skip simulation and the checksum check.
  --skip-rtl           Accepted for compatibility. RTL execution is unavailable.
  --output-dir DIR     Artifact root. Default: gen/NAME.
  --lcb-bin DIR        Directory with generated LLVM executables.
  --target NAME        Generated LLVM target name.
  --iss FILE           Generated QEMU executable.
  --insn-plugin FILE   Instruction-count plugin. Default: beside the ISS build.
  --timeout SECONDS    ISS timeout. Default: 30 (positive integer).
  -h, --help           Show this help.

Relative paths start at the dse project root.
Logs and results: results/NAME/. Workload outputs: gen/NAME/crc32/.
Instruction counts cover the full program, including input setup and output.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --variant) need_arg "$@"; VARIANT="$2"; shift 2 ;;
    --target) need_arg "$@"; TARGET="$2"; shift 2 ;;
    --output-dir) need_arg "$@"; OUTPUT_DIR="$2"; shift 2 ;;
    --lcb-bin) need_arg "$@"; LCB_BIN="$2"; shift 2 ;;
    --iss) need_arg "$@"; ISS="$2"; shift 2 ;;
    --insn-plugin) need_arg "$@"; INSN_PLUGIN="$2"; shift 2 ;;
    --timeout) need_arg "$@"; TIMEOUT="$2"; shift 2 ;;
    --skip-compile) SKIP_COMPILE=1; shift ;;
    --skip-iss) SKIP_ISS=1; shift ;;
    --skip-rtl) shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option '$1'" ;;
  esac
done
select_variant
validate_positive_integer --timeout "$TIMEOUT"
command -v jq >/dev/null || die 'jq is missing from PATH'

RESULT_DIR="$ROOT/results/$VARIANT"
METADATA="$RESULT_DIR/run.json"
if [ -f "$METADATA" ]; then
  jq -es 'length == 1 and (.[0] | type) == "object"' "$METADATA" >/dev/null || die 'run.json must contain one JSON object'
fi
DEFAULT_OUTPUT=0
[ -n "$OUTPUT_DIR" ] || { OUTPUT_DIR="$ROOT/gen/$VARIANT"; DEFAULT_OUTPUT=1; }
[ "${OUTPUT_DIR:0:1}" = / ] || OUTPUT_DIR="$ROOT/$OUTPUT_DIR"
if [ -z "$TARGET" ] && [ -f "$METADATA" ]; then
  TARGET="$(jq -r '.["build-lcb"].target // empty' "$METADATA")"
fi
[ -n "$TARGET" ] || TARGET="$(printf '%s' "$ISA" | tr '[:upper:]' '[:lower:]')"
if [ -z "$LCB_BIN" ] && [ "$DEFAULT_OUTPUT" -eq 1 ] && [ -f "$METADATA" ]; then
  LCB_BINARY="$(jq -r '.["build-lcb"] | select(.exit_code == 0) | .binary // empty' "$METADATA")"
  [ -z "$LCB_BINARY" ] || LCB_BIN="${LCB_BINARY%/*}"
fi
[ -n "$LCB_BIN" ] || LCB_BIN="$OUTPUT_DIR/lcb/llvm-final/build/bin"
[ "${LCB_BIN:0:1}" = / ] || LCB_BIN="$ROOT/$LCB_BIN"
[ -n "$ISS" ] || ISS="$OUTPUT_DIR/iss/build/qemu-system-$(printf '%s' "$ISA" | tr '[:upper:]' '[:lower:]')"
[ "${ISS:0:1}" = / ] || ISS="$ROOT/$ISS"
WORKLOAD="$ROOT/workloads/crc32"
OUT="$OUTPUT_DIR/crc32"
ELF="$OUT/crc32.elf"
mkdir -p "$RESULT_DIR" "$OUT"
COMMANDS="$(mktemp)"
TIMEOUT_MARKER="$(mktemp)"
rm -f "$TIMEOUT_MARKER"
STARTED="$(now)"
STAGE=setup
COMPILE_RESULT=skipped
ISS_RESULT=skipped
# Full checksum for the 1,024-word input with seed zero.
EXPECTED=65842ca9
ACTUAL=''
EXECUTED_INSTRUCTIONS=null
VERSIONS='{}'
CUSTOM_INSTRUCTIONS=null
LOG=''

write_workload_results() {
  local status="$1" record temporary hashes inputs binary_hash=''
  hashes="$(specification_hashes)" || return 1
  inputs="$(file_hashes "$WORKLOAD"/src/* "$WORKLOAD/Makefile" "$INSN_PLUGIN")" || return 1
  if [ -f "$ELF" ]; then
    binary_hash="$(file_hashes "$ELF" | jq -r 'to_entries[0].value')" || return 1
  fi
  record="$(jq -n --arg variant "$VARIANT" --arg isa "$ISA" --arg target "$TARGET" \
    --arg binary "$ELF" --arg hash "$binary_hash" --arg compile "$COMPILE_RESULT" --arg iss "$ISS_RESULT" \
    --arg expected "$EXPECTED" --arg actual "$ACTUAL" --arg stage "$STAGE" \
    --arg host "$(uname -srm)" --argjson status "$status" --argjson timeout "$TIMEOUT" \
    --argjson started "$STARTED" --argjson total "$(elapsed "$STARTED" "$(now)")" \
    --argjson versions "$VERSIONS" --argjson hashes "$hashes" --argjson inputs "$inputs" \
    --argjson instructions "$CUSTOM_INSTRUCTIONS" --argjson count "$EXECUTED_INSTRUCTIONS" \
    --arg plugin "$INSN_PLUGIN" --slurpfile commands "$COMMANDS" '{
      variant: $variant, isa: $isa, target: $target, binary: $binary, binary_sha256: $hash,
      started_at: ($started | floor | strftime("%Y-%m-%dT%H:%M:%S+00:00")),
      total_seconds: $total, stage: $stage, exit_code: $status, host: $host,
      compile: $compile, iss: $iss, rtl: "skipped", timeout_seconds: $timeout,
      expected: $expected, actual: $actual, custom_instructions: $instructions,
      executed_instructions: $count, instruction_count_scope: "full-program",
      insn_plugin: (if $plugin == "" then null else $plugin end),
      versions: $versions, specification_sha256: $hashes, input_sha256: $inputs, commands: $commands,
      skipped_steps: ([if $compile == "skipped" then "compile-crc32" else empty end,
        if $iss == "skipped" then "run-iss" else empty end, "run-rtl"])
    }')" || return 1
  temporary="$(mktemp "$RESULT_DIR/run.json.XXXXXX")" || return 1
  if [ -f "$METADATA" ]; then
    jq --argjson record "$record" '. + {"run-crc32": $record}' "$METADATA" > "$temporary" || return 1
  else
    jq -n --argjson record "$record" '{"run-crc32": $record}' > "$temporary" || return 1
  fi
  mv "$temporary" "$METADATA" || return 1
  if [ "$SKIP_ISS" -eq 0 ]; then
    printf 'variant,expected,actual,result,executed_instructions,instruction_count_scope\n%s,%s,%s,%s,%s,full-program\n' \
      "$VARIANT" "$EXPECTED" "$ACTUAL" "$ISS_RESULT" "${EXECUTED_INSTRUCTIONS#null}" > "$RESULT_DIR/crc32-iss.csv"
  fi
}

finish_workload() {
  local status=$?
  trap - EXIT
  if ! write_workload_results "$status"; then
    printf 'error: failed to write CRC32 results in %s\n' "$RESULT_DIR" >&2
    [ "$status" -ne 0 ] || status=1
  fi
  rm -f "$COMMANDS" "$TIMEOUT_MARKER"
  exit "$status"
}
trap finish_workload EXIT

require_executable() { [ -x "$1" ] && [ -f "$1" ] || die "executable missing: $1"; }
record_version() {
  local name="$1"; shift
  VERSIONS="$(printf '%s\n' "$VERSIONS" | jq --arg name "$name" --arg version "$(tool_version "$@" --version)" '. + {($name): $version}')"
}
checksum() {
  local value
  value="$(sed -nE 's/^CRC32=([[:xdigit:]]{8})$/\1/p' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in ''|*$'\n'*) die "expected one CRC32=XXXXXXXX result in $1" ;; esac
  printf '%s\n' "$value"
}

run_iss() {
  local pid watchdog status=0
  jq -cn --arg stage "$STAGE" --arg cwd "$PWD" \
    --args '{stage: $stage, cwd: $cwd, argv: $ARGS.positional}' -- "$@" >> "$COMMANDS"
  "$@" >> "$LOG" 2>&1 &
  pid=$!
  (
    sleep "$TIMEOUT" &
    sleeper=$!
    trap 'kill "$sleeper" 2>/dev/null || :' EXIT
    trap 'exit 0' TERM
    wait "$sleeper" || exit 0
    : > "$TIMEOUT_MARKER"
    kill "$pid" 2>/dev/null || exit 0
    sleep 1
    kill -KILL "$pid" 2>/dev/null || :
  ) &
  watchdog=$!
  wait "$pid" || status=$?
  kill "$watchdog" 2>/dev/null || :
  wait "$watchdog" 2>/dev/null || :
  cat "$LOG"
  [ ! -f "$TIMEOUT_MARKER" ] || die "ISS exceeded the $TIMEOUT second timeout"
  [ "$status" -eq 0 ] || die "ISS exited with $status"
}

if [ "$SKIP_COMPILE" -eq 0 ]; then
  STAGE=compile
  COMPILE_RESULT=failed
  LOG="$RESULT_DIR/crc32-compile.log"
  : > "$LOG"
  command -v make >/dev/null || die 'make is missing from PATH'
  for tool in clang llvm-mc ld.lld llvm-objdump; do
    require_executable "$LCB_BIN/$tool"
    record_version "$tool" "$LCB_BIN/$tool"
  done
  run make --no-print-directory -C "$WORKLOAD" "LCB_BIN=$LCB_BIN" "TARGET=$TARGET" "OUT=$OUT"
  report "Disassembly: $OUT/crc32.dump"
  CUSTOM_INSTRUCTIONS="$(sed -nE 's/^[[:space:]]*(crc[012])[[:space:]].*/\1/p' "$OUT/crc_32.s" | sort -u | jq -Rsc 'split("\n") | map(select(length > 0))')"
  report "Selected CRC instructions: $(printf '%s' "$CUSTOM_INSTRUCTIONS" | jq -r 'if length == 0 then "none" else join(", ") end')"
  COMPILE_RESULT=passed
fi
if [ "$SKIP_ISS" -eq 0 ]; then
  STAGE=iss
  ISS_RESULT=failed
  LOG="$RESULT_DIR/crc32-iss.log"
  : > "$LOG"
  [ -f "$ELF" ] || die "workload ELF missing: $ELF. Compile it before --skip-compile"
  require_executable "$ISS"
  if [ -z "$INSN_PLUGIN" ]; then
    INSN_PLUGIN="$(qemu_insn_plugin "${ISS%/*}")" || die "insn plugin missing beside '$ISS'. Run scripts/build-iss.sh --variant $VARIANT"
  fi
  [ "${INSN_PLUGIN:0:1}" = / ] || INSN_PLUGIN="$ROOT/$INSN_PLUGIN"
  [ -f "$INSN_PLUGIN" ] || die "insn plugin missing: $INSN_PLUGIN"
  INSN_LOG="$RESULT_DIR/crc32-insn.log"
  : > "$INSN_LOG"
  record_version qemu "$ISS"
  run_iss "$ISS" -machine spike -m 16M -display none -monitor none -serial stdio -bios "$ELF" \
    -plugin "$INSN_PLUGIN,inline=true" -d plugin -D "$INSN_LOG"
  ACTUAL="$(checksum "$LOG")"
  EXECUTED_INSTRUCTIONS="$(sed -nE 's/^total insns: ([0-9]+)$/\1/p' "$INSN_LOG")"
  case "$EXECUTED_INSTRUCTIONS" in
    ''|0*|*$'\n'*) EXECUTED_INSTRUCTIONS=null; die "expected one positive instruction count in $INSN_LOG" ;;
  esac
  [ "$ACTUAL" = "$EXPECTED" ] || die "CRC32 mismatch: expected $EXPECTED, got $ACTUAL"
  ISS_RESULT=passed
  report "CRC32=$ACTUAL passed ($VARIANT)"
  report "Executed instructions (full program): $EXECUTED_INSTRUCTIONS"
fi
STAGE=complete

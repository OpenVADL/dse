#!/usr/bin/env bash
# Generate RTL, emit SystemVerilog, and run Sky130 synthesis and placement.
# Run from any directory. Relative paths resolve from the dse project root.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/lib/build-common.sh"
SPEC=''
TOP_MODULE=''
NAME=''
CLOCK_PERIOD=5
CACHE=auto
PYTHON="${PYTHON:-python3}"
VADL_CMD="${VADL_CMD:-openvadl}"

usage() {
  cat <<EOF
Usage: $(basename "$0") --spec FILE --top-module MODULE [options]

Generate RTL and run SystemVerilog emission, synthesis, placement, and timing analysis.
The specification must define a hardware implementation.

  --spec FILE          Required: VADL specification.
  --top-module MODULE  Required: generated SystemVerilog top module.
  --name NAME          Output name. Default: top module.
  --clock-period NS    Positive clock period in nanoseconds. Default: 5.
  --cache TOOL         auto, ccache, sccache, or none. Default: auto.
                       auto prefers ccache, then sccache, then none.
  -h, --help           Show this help.

Sources and outputs: gen/NAME/rtl/ (SystemVerilog and netlist in build/).
Logs, timings, and metadata: results/NAME/.
Hardware inputs: hardware/yosys/, hardware/openroad/, and hardware/pdk/sky130/.
Set VADL_CMD to select the OpenVADL executable. Default: openvadl.
Set PYTHON to select Python 3.11 or newer. Default: python3.
Relative paths start at the dse project root. Requires Bash 3.2 or newer.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --spec) need_arg "$@"; SPEC="$2"; shift 2 ;;
    --top-module) need_arg "$@"; TOP_MODULE="$2"; shift 2 ;;
    --name) need_arg "$@"; NAME="$2"; shift 2 ;;
    --clock-period) need_arg "$@"; CLOCK_PERIOD="$2"; shift 2 ;;
    --cache) need_arg "$@"; CACHE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option '$1'" ;;
  esac
done

[ -n "$SPEC" ] || die 'pass --spec FILE'
[ -f "$SPEC" ] || die "specification '$SPEC' does not exist"
[[ "$TOP_MODULE" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die 'pass --top-module with a plain SystemVerilog identifier'
[ -n "$NAME" ] || NAME="$TOP_MODULE"
[[ "$NAME" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] || die '--name must contain only letters, digits, underscores, dots, and hyphens, and start with a letter, digit, or underscore'
[[ "$CLOCK_PERIOD" =~ ^[0-9]+([.][0-9]+)?$ ]] && [[ "$CLOCK_PERIOD" =~ [1-9] ]] ||
  die '--clock-period requires a positive decimal number in nanoseconds'
case "$SPEC" in /*) ;; *) SPEC="$ROOT/$SPEC" ;; esac
PYTHON="$(absolute_command "$PYTHON")" || die 'Python not found in PATH'
VADL_CMD="$(absolute_command "$VADL_CMD")" || die 'OpenVADL not found. Set VADL_CMD or add openvadl to PATH'
CACHE="$(select_compiler_cache "$CACHE")" || exit $?
PYTHON="$PYTHON" VADL_CMD="$VADL_CMD" bash "$ROOT/scripts/check-deps.sh" rtl --cache "$CACHE"
use_compiler_cache "$CACHE"

VARIANT="$NAME"
ISA=''
TARGET="$TOP_MODULE"
JOBS=null
CLEAN=0
OUTPUT_DIR="$ROOT/gen/$NAME"
GEN_DIR="$OUTPUT_DIR/rtl"
SYSTEM_VERILOG="$GEN_DIR/build/$TOP_MODULE.sv"
NETLIST="$GEN_DIR/build/${TOP_MODULE}_netlist.v"
BINARY=''
EMISSION_SECONDS=0
SYNTHESIS_SECONDS=0
PLACEMENT_SECONDS=0
BUILD_STARTED=''
start_build_recording rtl
report "RTL build: $NAME ($TOP_MODULE)"
report "Specification: $SPEC"
report "Clock period: $CLOCK_PERIOD ns"
report "Compiler cache: $CACHE"

STAGE=generation
start="$(now)"
run "$VADL_CMD" rtl "$SPEC" --timings --reset-vector=reset_vector -o "$OUTPUT_DIR"
[ -d "$GEN_DIR" ] || die "RTL generation did not produce '$GEN_DIR'"
GENERATION_SECONDS="$(elapsed "$start" "$(now)")"

STAGE=preparation
BUILD_STARTED="$(now)"
run "$PYTHON" "$ROOT/scripts/lib/rtl-scripts.py" "$ROOT/hardware" "$GEN_DIR" "$TOP_MODULE" "$CLOCK_PERIOD"
cd "$GEN_DIR"

# Remove stage outputs so a successful command can't reuse a stale artifact.
STAGE=emission
start="$(now)"
rm -f "$SYSTEM_VERILOG" "$NETLIST"
run sbt 'testOnly CoreEmit -- -t emit'
[ -f "$SYSTEM_VERILOG" ] || die "SystemVerilog emission did not produce '$SYSTEM_VERILOG'"
EMISSION_SECONDS="$(elapsed "$start" "$(now)")"

STAGE=synthesis
start="$(now)"
run yosys -s ./yosys.ys
[ -f "$NETLIST" ] || die "Yosys did not produce '$NETLIST'"
SYNTHESIS_SECONDS="$(elapsed "$start" "$(now)")"

STAGE=placement
start="$(now)"
run openroad ./openroad.tcl
PLACEMENT_SECONDS="$(elapsed "$start" "$(now)")"
BUILD_SECONDS="$(elapsed "$BUILD_STARTED" "$(now)")"
STAGE=complete
report "Generation: $GENERATION_SECONDS s"
report "SystemVerilog emission: $EMISSION_SECONDS s"
report "Synthesis: $SYNTHESIS_SECONDS s"
report "Placement and timing analysis: $PLACEMENT_SECONDS s"
report "Netlist: $NETLIST"

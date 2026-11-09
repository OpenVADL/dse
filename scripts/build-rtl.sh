#!/usr/bin/env bash
# Generate RTL, emit SystemVerilog, and run Sky130 synthesis and placement.
# Run from any directory. Relative paths resolve from the dse project root.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/lib/build-common.sh"
source "$ROOT/scripts/lib/rtl-scripts.sh"
SPEC=''
TOP_MODULE=''
VARIANT=''
MICROARCHITECTURE=5stage
CLOCK_PERIOD=5
CACHE=auto
VADL_CMD="${VADL_CMD:-openvadl}"

usage() {
  cat <<EOF
Usage: $(basename "$0") --variant NAME [options]

Generate RTL and run SystemVerilog emission, synthesis, placement, and timing analysis.
Select a bundled pipeline and the same ISA variants as ISS and LCB.

  --variant NAME       Required: rv32i, crc0, crc1, crc2, or crc012.
  --microarchitecture NAME
                       3stage or 5stage. Default: 5stage.
  --spec FILE          Override the selected pipeline specification.
                       The file must define a TargetIsa model.
  --top-module MODULE  Override the generated top module.
                       Default: ThreeStage or FiveStage for the selected pipeline.
  --clock-period NS    Positive clock period in nanoseconds. Default: 5.
  --cache TOOL         auto, ccache, sccache, or none. Default: auto.
                       auto prefers ccache, then sccache, then none.
  -h, --help           Show this help.

Sources and outputs: gen/VARIANT/rtl/MICROARCHITECTURE/.
SystemVerilog and netlist: build/ within that directory.
Logs, timings, and metadata: results/VARIANT/rtl/MICROARCHITECTURE/.
Hardware inputs: hardware/yosys/, hardware/openroad/, and hardware/pdk/sky130/.
Set VADL_CMD to select the OpenVADL executable. Default: openvadl.
Relative paths start at the dse project root. Requires Bash 3.2 or newer.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --variant) need_arg "$@"; VARIANT="$2"; shift 2 ;;
    --microarchitecture) need_arg "$@"; MICROARCHITECTURE="$2"; shift 2 ;;
    --spec) need_arg "$@"; SPEC="$2"; shift 2 ;;
    --top-module) need_arg "$@"; TOP_MODULE="$2"; shift 2 ;;
    --clock-period) need_arg "$@"; CLOCK_PERIOD="$2"; shift 2 ;;
    --cache) need_arg "$@"; CACHE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option '$1'" ;;
  esac
done

select_variant
case "$MICROARCHITECTURE" in
  3stage) DEFAULT_TOP_MODULE=ThreeStage ;;
  5stage) DEFAULT_TOP_MODULE=FiveStage ;;
  *) die 'pass --microarchitecture 3stage or 5stage' ;;
esac
[ -n "$SPEC" ] || SPEC="$ROOT/specs/mia/rv_${MICROARCHITECTURE}.vadl"
[ -n "$TOP_MODULE" ] || TOP_MODULE="$DEFAULT_TOP_MODULE"
[ -f "$SPEC" ] || die "specification '$SPEC' does not exist"
[[ "$TOP_MODULE" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die 'pass --top-module with a plain SystemVerilog identifier'
[[ "$CLOCK_PERIOD" =~ ^[0-9]+([.][0-9]+)?$ ]] && [[ "$CLOCK_PERIOD" =~ [1-9] ]] ||
  die '--clock-period requires a positive decimal number in nanoseconds'
case "$SPEC" in /*) ;; *) SPEC="$ROOT/$SPEC" ;; esac
VADL_CMD="$(absolute_command "$VADL_CMD")" || die 'OpenVADL not found. Set VADL_CMD or add openvadl to PATH'
CACHE="$(select_compiler_cache "$CACHE")" || exit $?
VADL_CMD="$VADL_CMD" bash "$ROOT/scripts/check-deps.sh" rtl --cache "$CACHE"
use_compiler_cache "$CACHE"

TARGET="$TOP_MODULE"
JOBS=null
CLEAN=0
GEN_DIR="$ROOT/gen/$VARIANT/rtl/$MICROARCHITECTURE"
RTL_GENERATION_DIR=''
SYSTEM_VERILOG="$GEN_DIR/build/$TOP_MODULE.sv"
NETLIST="$GEN_DIR/build/${TOP_MODULE}_netlist.v"
BINARY=''
EMISSION_SECONDS=0
SYNTHESIS_SECONDS=0
PLACEMENT_SECONDS=0
BUILD_STARTED=''
start_build_recording rtl "$ROOT/results/$VARIANT/rtl/$MICROARCHITECTURE"
report "Variant: $VARIANT ($ISA)"
report "Microarchitecture: $MICROARCHITECTURE"
report "Top module: $TOP_MODULE"
report "Specification: $SPEC"
report "Clock period: $CLOCK_PERIOD ns"
report "Compiler cache: $CACHE"

STAGE=generation
start="$(now)"
mkdir -p "$GEN_DIR"
# OpenVADL appends rtl/ to its output path. Emit into the selected project directory.
RTL_GENERATION_DIR="$(mktemp -d "$GEN_DIR/.generation.XXXXXX")"
ln -s "$GEN_DIR" "$RTL_GENERATION_DIR/rtl"
run "$VADL_CMD" rtl "$SPEC" "${MODEL_ARGS[@]}" --top-module "$TOP_MODULE" \
  --timings --reset-vector=reset_vector -o "$RTL_GENERATION_DIR"
rm -rf "$RTL_GENERATION_DIR"
RTL_GENERATION_DIR=''
GENERATION_SECONDS="$(elapsed "$start" "$(now)")"

STAGE=preparation
BUILD_STARTED="$(now)"
render_rtl_template yosys "$ROOT/hardware/yosys/bench_core_asic_sky130.ys" > "$GEN_DIR/yosys.ys"
render_rtl_template openroad "$ROOT/hardware/openroad/bench_core_asic_sky130.tcl" > "$GEN_DIR/openroad.tcl"
cd "$GEN_DIR"

STAGE=emission
start="$(now)"
run sbt 'testOnly CoreEmit -- -t emit'
EMISSION_SECONDS="$(elapsed "$start" "$(now)")"

STAGE=synthesis
start="$(now)"
run yosys -s ./yosys.ys
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

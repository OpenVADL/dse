#!/bin/bash

# Stop on failed steps, including commands whose output is piped through tee.
set -eo pipefail

# Prerequisites:
# * sbt
# * yosys
# * openroad

if ! command -v sbt >/dev/null 2>&1; then
    echo "Required command 'sbt' not found. See https://www.scala-sbt.org/1.x/docs/Installing-sbt-on-Linux.html (macOS: brew install sbt)."
    exit 1
fi

if ! command -v yosys >/dev/null 2>&1; then
    echo "Required command 'yosys' not found. See https://github.com/YosysHQ/oss-cad-suite-build#installation (macOS: brew install yosys)."
    exit 1
fi

if ! command -v openroad >/dev/null 2>&1; then
    cat <<'EOF'
Required command 'openroad' not found.
OpenROAD can be built from source by following the instructions at https://openroad.readthedocs.io/en/latest/user/Build.html
or using the following steps (for revisions supporting these installer flags):

> git clone --recursive https://github.com/The-OpenROAD-Project/OpenROAD.git
> cd OpenROAD
> ./etc/DependencyInstaller.sh -base
> ./etc/DependencyInstaller.sh -all
> ./etc/Build.sh

Add the directory containing the built openroad binary (*/bin) to PATH.
Alternatively, install a prebuilt package matching your Linux distribution.
EOF
    exit 1
fi

# Override with an executable path or command name, e.g.:
# VADL_CMD=/path/to/openvadl ./build-rtl.sh <spec.vadl> <core_name> [clock_period_in_ns]
VADL_CMD="${VADL_CMD:-openvadl}"
if ! command -v -- "$VADL_CMD" >/dev/null 2>&1; then
  echo "OpenVADL executable '$VADL_CMD' not found. Set VADL_CMD or add openvadl to PATH." >&2
  exit 1
fi

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

SPEC="$1"
if [ -z "$SPEC" ]; then
  echo "Usage: $0 <spec.vadl> <core_name> [clock_period_in_ns]"
  exit 1
fi

TOP_MODULE="$2"
if [ -z "$TOP_MODULE" ]; then
  echo "Usage: $0 <spec.vadl> <core_name> [clock_period_in_ns]"
  exit 1
fi

CLOCK_PERIOD="$3"
if [ -z "$CLOCK_PERIOD" ]; then
  CLOCK_PERIOD=5
fi

# Bash time reports elapsed wall-clock seconds to stderr.
build_rtl() {
  local TIMEFORMAT

  # Initialize build directory
  mkdir -p "$BASE_DIR/build"

  # Output the hardware description next to the script
  TIMEFORMAT="[timing] OpenVADL RTL generation: %3R s"
  time "$VADL_CMD" rtl "$SPEC" --timings --reset-vector=reset_vector -o "$BASE_DIR/build"

  # Prepare scripts
  TIMEFORMAT="[timing] Script preparation: %3R s"
  time {
    sed "s/TOP_MODULE/${TOP_MODULE}/g" "$BASE_DIR/yosys/bench_core_asic_sky130.ys" |
    sed "s|/opt/pdk|${BASE_DIR}/pdk|g" \
      > "$BASE_DIR/build/rtl/yosys.ys"
    sed "s/TOP_MODULE/${TOP_MODULE}/g;s/CLOCK_PERIOD/${CLOCK_PERIOD}/g" \
      "$BASE_DIR/openroad/bench_core_asic_sky130.tcl"  |
    sed "s|/opt/pdk|${BASE_DIR}/pdk|g" |
    sed "s|/rtl/build|${BASE_DIR}/build/rtl/build|g" \
      > "$BASE_DIR/build/rtl/openroad.tcl"
  }

  # Navigate to Chisel project directory
  cd "$BASE_DIR/build/rtl"

  # Translate Chisel to Verilog, writes the result to build/*
  TIMEFORMAT="[timing] Chisel to SystemVerilog: %3R s"
  time sbt "testOnly CoreEmit -- -t emit" > "$BASE_DIR/build/${TOP_MODULE}_sbt.log"

  # Synthesize against SkyWater 130nm cell library
  TIMEFORMAT="[timing] Yosys synthesis: %3R s"
  time yosys -s ./yosys.ys > "$BASE_DIR/build/${TOP_MODULE}_yosys_asic_sky130.log"

  # Placement for more realistic area & timing estimates
  TIMEFORMAT="[timing] OpenROAD placement and STA: %3R s"
  time openroad ./openroad.tcl > "$BASE_DIR/build/${TOP_MODULE}_openroad_asic_sky130.log"
}

TIMEFORMAT="[timing] Total RTL build: %3R s"
time build_rtl

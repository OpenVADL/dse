#!/usr/bin/env bash
#
# Timing, command logging, specification hashes, and result files for backend builds.
# The caller sets paths, options, timings, and the build stage.
# Use jq for JSON and sha256sum or shasum for hashes.
# Supports Bash 3.2 on macOS and Bash on Linux.

# ---------------------------------------------------------------------------
# Timing and command logging
# ---------------------------------------------------------------------------
now() { jq -n 'now'; }

elapsed() {
  jq -n --arg start "$1" --arg end "$2" \
    '(($end | tonumber) - ($start | tonumber)) * 1000 | round / 1000'
}

report() { printf '%s\n' "$*" | tee -a "$LOG"; }

run() {
  jq -cn --arg stage "$STAGE" --arg cwd "$PWD" \
    --args '{stage: $stage, cwd: $cwd, argv: $ARGS.positional}' -- "$@" >> "$COMMANDS" || return 1
  "$@" 2>&1 | tee -a "$LOG"
}

# ---------------------------------------------------------------------------
# Tool versions and specification hashes
# ---------------------------------------------------------------------------
tool_version() {
  local output
  if output="$("$@" 2>&1)"; then
    printf '%s\n' "$output"
  else
    printf 'Unavailable: %s\n' "$output"
  fi
}

file_hashes() {
  local path hash
  for path in "$@"; do
    [ -f "$path" ] || continue
    # Hash stdin so filenames don't change the checksum output format.
    if command -v sha256sum >/dev/null; then
      hash="$(sha256sum < "$path")" || return 1
    else
      hash="$(shasum -a 256 < "$path")" || return 1
    fi
    jq -cn --arg path "${path#"$ROOT"/}" --arg hash "${hash%% *}" \
      '{key: $path, value: $hash}' || return 1
  done | jq -s 'from_entries'
}

specification_hashes() {
  file_hashes "$ROOT"/specs/*.vadl "$ROOT"/specs/mia/*.vadl "${SPEC:-}"
}

# ---------------------------------------------------------------------------
# Atomic run.json update and build-times.csv append
# ---------------------------------------------------------------------------
write_build_results() {
  local status="$1" total hashes binary_version='' record metadata temporary csv versions details='{}' inputs='{}'
  total="$(elapsed "$STARTED" "$(now)")" || return 1
  hashes="$(specification_hashes)" || return 1
  if [ "$status" -eq 0 ] && [ -n "$BINARY" ]; then binary_version="$(tool_version "$BINARY" --version)"; fi
  versions="$(jq -n --arg openvadl "$(tool_version "$OPENVADL" --version)" \
    '{openvadl: $openvadl}')" || return 1
  if [ "$ARTIFACT" != rtl ]; then
    versions="$(printf '%s\n' "$versions" | jq --arg make "$(tool_version make --version)" \
      --arg python "$(tool_version "$PYTHON" --version)" '. + {make: $make, python: $python}')" || return 1
  fi
  case "$ARTIFACT" in
    iss) versions="$(printf '%s\n' "$versions" | jq --arg version "$binary_version" --argjson status "$status" \
      '. + {qemu: (if $status == 0 then $version else null end)}')" || return 1
      details="$(jq -n --arg plugin "${INSN_PLUGIN:-}" \
        '{insn_plugin: (if $plugin == "" then null else $plugin end)}')" || return 1 ;;
    lcb) versions="$(printf '%s\n' "$versions" | jq --arg version "$binary_version" \
      --arg cmake "$(tool_version cmake --version)" --argjson status "$status" \
      '. + {cmake: $cmake, clang: (if $status == 0 then $version else null end)}')" || return 1 ;;
    rtl)
      versions="$(printf '%s\n' "$versions" | jq --arg java "$(tool_version java -version)" \
        --arg sbt "$(tool_version sbt --script-version)" --arg yosys "$(tool_version yosys -V)" \
        --arg openroad "$(tool_version openroad -version)" \
        '. + {java: $java, sbt: $sbt, yosys: $yosys, openroad: $openroad}')" || return 1
      inputs="$(file_hashes "$ROOT"/hardware/pdk/sky130/* \
        "$ROOT/hardware/yosys/bench_core_asic_sky130.ys" \
        "$ROOT/hardware/openroad/bench_core_asic_sky130.tcl")" || return 1
      details="$(jq -n --arg spec "$SPEC" --arg top "$TOP_MODULE" --arg mia "$MICROARCHITECTURE" \
        --arg clock "$CLOCK_PERIOD" --arg sv "$SYSTEM_VERILOG" --arg netlist "$NETLIST" \
        --argjson emission "$EMISSION_SECONDS" --argjson synthesis "$SYNTHESIS_SECONDS" \
        --argjson placement "$PLACEMENT_SECONDS" '{
          binary: null, specification: $spec, top_module: $top, microarchitecture: $mia,
          clock_period_ns: ($clock | tonumber), system_verilog: $sv, netlist: $netlist,
          stage_seconds: {emission: $emission, synthesis: $synthesis, placement: $placement}
        }')" || return 1 ;;
  esac
  record="$(jq -n \
    --arg assertions "${LLVM_ASSERTIONS:-}" --arg dump "${LLVM_DUMP:-}" \
    --argjson workaround "${LLVM_COMPATIBILITY_WORKAROUND:-0}" \
    --arg artifact "$ARTIFACT" --arg target "$TARGET" --arg build_type "${BUILD_TYPE:-}" \
    --argjson link_jobs "${LINK_JOBS:-null}" --argjson versions "$versions" \
    --arg variant "$VARIANT" --arg isa "$ISA" --arg binary "$BINARY" --arg stage "$STAGE" --arg cache "$CACHE" \
    --argjson jobs "$JOBS" --argjson clean "$CLEAN" --argjson started "$STARTED" \
    --argjson generation "$GENERATION_SECONDS" --argjson build "$BUILD_SECONDS" \
    --argjson total "$total" --argjson status "$status" --argjson hashes "$hashes" \
    --argjson inputs "$inputs" --argjson details "$details" \
    --arg system "$(uname -srm)" --arg machine "$(uname -m)" \
    --slurpfile commands "$COMMANDS" '{
      artifact: $artifact, variant: $variant, isa: $isa, target: $target,
      started_at: ($started | floor | strftime("%Y-%m-%dT%H:%M:%S+00:00")),
      jobs: $jobs, link_jobs: $link_jobs, build_type: $build_type, clean: ($clean == 1), cache: $cache,
      generation_seconds: $generation, build_seconds: $build, total_seconds: $total,
      exit_code: $status, stage: $stage, binary: $binary,
      host: {system: $system, machine: $machine},
      versions: $versions,
      specification_sha256: $hashes, input_sha256: $inputs,
      skipped_steps: ["compile-crc32", "run-iss", "run-rtl"], commands: $commands
    } + (if $artifact == "lcb" then {
      llvm_assertions: ($assertions == "On"), llvm_dump: ($dump == "On"),
      llvm_compatibility_workaround: ($workaround == 1)
    } else {} end) + $details')" || return 1

  metadata="$RESULT_DIR/run.json"
  temporary="$(mktemp "$RESULT_DIR/run.json.XXXXXX")" || return 1
  if [ -f "$metadata" ]; then
    if ! jq -es --arg key "build-$ARTIFACT" --argjson record "$record" '
      if length == 1 and (.[0] | type) == "object" then
        .[0] + {($key): $record}
      else error("run.json must contain one JSON object") end
    ' "$metadata" > "$temporary"; then
      rm -f "$temporary"
      return 1
    fi
  else
    printf '%s\n' "$record" | jq --arg key "build-$ARTIFACT" '{($key): .}' > "$temporary" || { rm -f "$temporary"; return 1; }
  fi
  mv "$temporary" "$metadata" || { rm -f "$temporary"; return 1; }

  csv="$RESULT_DIR/build-times.csv"
  if [ ! -s "$csv" ]; then
    printf 'started_at,artifact,variant,generation_seconds,build_seconds,total_seconds,jobs,link_jobs,cache,clean,exit_code\n' > "$csv" || return 1
  fi
  printf '%s\n' "$record" | jq -r --arg clean "$CLEAN" \
    '[.started_at, .artifact, .variant, .generation_seconds, .build_seconds,
      .total_seconds, .jobs, (.link_jobs // ""), .cache, $clean, .exit_code] | @csv' >> "$csv"
}

# ---------------------------------------------------------------------------
# Exit handling. Preserve the build failure status if result recording also fails.
# ---------------------------------------------------------------------------
finish_build() {
  local status=$? metadata_status
  trap - EXIT
  set +e
  case "$STAGE" in
    generation) GENERATION_SECONDS="$(elapsed "$start" "$(now)")" ;;
    build) BUILD_SECONDS="$(elapsed "$start" "$(now)")" ;;
  esac
  if [ "$ARTIFACT" = rtl ]; then
    case "$STAGE" in
      emission) EMISSION_SECONDS="$(elapsed "$start" "$(now)")" ;;
      synthesis) SYNTHESIS_SECONDS="$(elapsed "$start" "$(now)")" ;;
      placement) PLACEMENT_SECONDS="$(elapsed "$start" "$(now)")" ;;
    esac
    if [ -n "$BUILD_STARTED" ]; then BUILD_SECONDS="$(elapsed "$BUILD_STARTED" "$(now)")"; fi
  fi
  if write_build_results "$status"; then
    metadata_status=0
  else
    metadata_status=$?
    printf 'error: failed to write %s results in %s\n' "$(printf '%s' "$ARTIFACT" | tr '[:lower:]' '[:upper:]')" "$RESULT_DIR" >&2
  fi
  rm -f "$COMMANDS"
  if [ "$ARTIFACT" = rtl ] && [ -n "${RTL_GENERATION_DIR:-}" ]; then
    rm -rf "$RTL_GENERATION_DIR"
  fi
  [ "$status" -ne 0 ] || status=$metadata_status
  exit "$status"
}

start_build_recording() {
  ARTIFACT="$1"
  RESULT_DIR="${2:-$ROOT/results/$VARIANT}"
  mkdir -p "$RESULT_DIR"
  LOG="$RESULT_DIR/build-$ARTIFACT.log"
  : > "$LOG"
  COMMANDS="$(mktemp)"
  STARTED="$(now)"
  GENERATION_SECONDS=0
  BUILD_SECONDS=0
  STAGE=setup
  trap finish_build EXIT
}

#!/usr/bin/env bash
#
# Timing, command logging, specification hashes, and result files for build-iss.sh.
# Source from build-iss.sh. The caller sets paths, options, timings, and build stage.
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

specification_hashes() {
  local path hash
  for path in "$ROOT"/specs/*.vadl; do
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

# ---------------------------------------------------------------------------
# Atomic run.json update and build-times.csv append
# ---------------------------------------------------------------------------
write_iss_results() {
  local status="$1" total hashes qemu_version='' record metadata temporary csv
  total="$(elapsed "$STARTED" "$(now)")" || return 1
  hashes="$(specification_hashes)" || return 1
  if [ "$status" -eq 0 ]; then qemu_version="$(tool_version "$BINARY" --version)"; fi
  record="$(jq -n \
    --arg variant "$VARIANT" --arg isa "$ISA" --arg binary "$BINARY" --arg stage "$STAGE" --arg cache "$CACHE" \
    --argjson jobs "$JOBS" --argjson clean "$CLEAN" --argjson started "$STARTED" \
    --argjson generation "$GENERATION_SECONDS" --argjson build "$BUILD_SECONDS" \
    --argjson total "$total" --argjson status "$status" --argjson hashes "$hashes" \
    --arg system "$(uname -srm)" --arg machine "$(uname -m)" \
    --arg openvadl "$(tool_version openvadl --version)" --arg make "$(tool_version make --version)" \
    --arg python "$(tool_version "$PYTHON" --version)" --arg qemu "$qemu_version" \
    --slurpfile commands "$COMMANDS" '{
      artifact: "iss", variant: $variant, isa: $isa,
      started_at: ($started | floor | strftime("%Y-%m-%dT%H:%M:%S+00:00")),
      jobs: $jobs, clean: ($clean == 1), cache: $cache,
      generation_seconds: $generation, build_seconds: $build, total_seconds: $total,
      exit_code: $status, stage: $stage, binary: $binary,
      host: {system: $system, machine: $machine},
      versions: {openvadl: $openvadl, make: $make, python: $python,
                 qemu: (if $status == 0 then $qemu else null end)},
      specification_sha256: $hashes, input_sha256: {},
      skipped_steps: ["compile-crc32", "run-iss", "run-rtl"], commands: $commands
    }')" || return 1

  metadata="$RESULT_DIR/run.json"
  temporary="$(mktemp "$RESULT_DIR/run.json.XXXXXX")" || return 1
  if [ -f "$metadata" ]; then
    if ! jq -es --argjson record "$record" '
      if length == 1 and (.[0] | type) == "object" then
        .[0] + {"build-iss": $record}
      else error("run.json must contain one JSON object") end
    ' "$metadata" > "$temporary"; then
      rm -f "$temporary"
      return 1
    fi
  else
    printf '%s\n' "$record" | jq '{"build-iss": .}' > "$temporary" || { rm -f "$temporary"; return 1; }
  fi
  mv "$temporary" "$metadata" || { rm -f "$temporary"; return 1; }

  csv="$RESULT_DIR/build-times.csv"
  if [ ! -s "$csv" ]; then
    printf 'started_at,artifact,variant,generation_seconds,build_seconds,total_seconds,jobs,link_jobs,cache,clean,exit_code\n' > "$csv" || return 1
  fi
  printf '%s\n' "$record" | jq -r --arg clean "$CLEAN" \
    '[.started_at, .artifact, .variant, .generation_seconds, .build_seconds,
      .total_seconds, .jobs, "", .cache, $clean, .exit_code] | @csv' >> "$csv"
}

# ---------------------------------------------------------------------------
# Exit handling. Preserve the build failure status if result recording also fails.
# ---------------------------------------------------------------------------
finish_iss() {
  local status=$? metadata_status
  trap - EXIT
  set +e
  case "$STAGE" in
    generation) GENERATION_SECONDS="$(elapsed "$start" "$(now)")" ;;
    build) BUILD_SECONDS="$(elapsed "$start" "$(now)")" ;;
  esac
  if write_iss_results "$status"; then
    metadata_status=0
  else
    metadata_status=$?
    printf 'error: failed to write ISS results in %s\n' "$RESULT_DIR" >&2
  fi
  rm -f "$COMMANDS"
  [ "$status" -ne 0 ] || status=$metadata_status
  exit "$status"
}

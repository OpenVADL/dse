#!/usr/bin/env bash
# Paths need different quoting in Yosys scripts and Tcl scripts.

rtl_quote_path() {
  local value="$1" tool="$2"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  if [ "$tool" = openroad ]; then
    value="${value//\$/\\\$}"
    value="${value//\[/\\[}"
    value="${value//\]/\\]}"
  fi
  printf '"%s"' "$value"
}

render_rtl_template() {
  local tool="$1" template="$2" line remaining token key value path
  while IFS= read -r line || [ -n "$line" ]; do
    remaining="$line"
    while [[ "$remaining" =~ @([A-Z_]+)@ ]]; do
      token="${BASH_REMATCH[0]}"
      key="${BASH_REMATCH[1]}"
      path=''
      case "$key" in
        TOP_MODULE) value="$TOP_MODULE" ;;
        CLOCK_PERIOD) value="$CLOCK_PERIOD" ;;
        SYSTEM_VERILOG) path="$SYSTEM_VERILOG" ;;
        NETLIST) path="$NETLIST" ;;
        LIBERTY) path="$ROOT/hardware/pdk/sky130/sky130_fd_sc_hd__tt_025C_1v80.lib" ;;
        TECH_LEF) path="$ROOT/hardware/pdk/sky130/sky130_fd_sc_hd__nom.tlef" ;;
        CELL_LEF) path="$ROOT/hardware/pdk/sky130/sky130_fd_sc_hd.lef" ;;
        *) printf 'error: unknown RTL template token %s\n' "$token" >&2; return 1 ;;
      esac
      if [ -n "$path" ]; then value="$(rtl_quote_path "$path" "$tool")"; fi
      printf '%s%s' "${remaining%%"$token"*}" "$value"
      remaining="${remaining#*"$token"}"
    done
    printf '%s\n' "$remaining"
  done < "$template"
}

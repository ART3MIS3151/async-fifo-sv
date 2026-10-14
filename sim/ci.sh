#!/usr/bin/env bash
# CI checks for async-fifo-sv. Runs on GitHub Actions (ubuntu-24.04) on every push;
# also runnable anywhere with: bash sim/ci.sh
#
# Conventions (keep these and CI stays green):
#   rtl/*.sv, rtl/*.v      synthesisable design files only (no classes, no SVA)
#   tb/tb_*.sv             Icarus-runnable self-checking testbenches.
#                          A test PASSES only if it prints "TEST PASSED" and nothing
#                          containing "FAIL", "ERROR" or "FATAL".
#                          Put  // ci: skip  on the first line of a TB that needs a
#                          commercial simulator (class-based TB, covergroups, SVA).
#   Each tb_*.sv must contain exactly one top module named like the file (tb_counter.sv -> tb_counter).
set -uo pipefail
shopt -s nullglob
cd "$(dirname "$0")/.."

RTL=(rtl/*.sv rtl/*.v)
TBS=(tb/tb_*.sv)
fail=0
summary=()

sec(){ echo; echo "=============== $* ==============="; }

# ---- 1. Verilator lint (P2.G1) --------------------------------------------
sec "Verilator lint"
if ((${#RTL[@]} == 0)); then
  echo "rtl/ is empty: skipped"; summary+=("lint: skipped (no RTL)")
else
  # All RTL linted together so cross-module references resolve.
  # MULTITOP is suppressed: several independent top modules (bin2gray, sync_fifo, ...) are expected.
  if verilator --lint-only -Wall -Wno-MULTITOP --timing "${RTL[@]}"; then
    echo "lint clean"; summary+=("lint: PASS (${#RTL[@]} file(s))")
  else
    summary+=("lint: FAIL"); fail=1
  fi
fi

# ---- 2. Yosys latch check (P3.B4) -----------------------------------------
sec "Yosys latch check"
if ((${#RTL[@]} == 0)); then
  echo "rtl/ is empty: skipped"; summary+=("latch check: skipped (no RTL)")
else
  reads=""; for f in "${RTL[@]}"; do reads+="read_verilog -sv $f; "; done
  if yosys -q -l sim/yosys.log -p "${reads} proc; opt -fast; memory -nomap; select -assert-none t:\$dlatch t:\$adlatch t:\$dlatchsr t:\$sr; tee -o sim/yosys_stat.txt stat"; then
    echo "no latches inferred"; summary+=("latch check: PASS")
  else
    echo "latch inferred (or Yosys could not parse the RTL); see sim/yosys.log"; summary+=("latch check: FAIL"); fail=1
  fi
fi

# ---- 3. Icarus self-checking tests (P1-P4) --------------------------------
sec "Icarus tests"
ran=0
for tb in "${TBS[@]}"; do
  top=$(basename "$tb" .sv)
  if head -n1 "$tb" | grep -q "ci: skip"; then
    echo "[$top] skipped (marked ci: skip)"; summary+=("$top: skipped"); continue
  fi
  ran=$((ran+1))
  out="sim/${top}.out"
  if ! iverilog -g2012 -Wall -o "sim/${top}.vvp" -s "$top" "${RTL[@]}" "$tb" > "sim/${top}.compile.log" 2>&1; then
    cat "sim/${top}.compile.log"; echo "[$top] COMPILE FAILED"; summary+=("$top: COMPILE FAIL"); fail=1; continue
  fi
  ( cd sim && timeout 300 vvp -n "${top}.vvp" ) > "$out" 2>&1; rc=$?
  cat "$out"
  if (( rc == 0 )) && grep -q "TEST PASSED" "$out" && ! grep -Eqi "FAIL|ERROR|FATAL" "$out"; then
    echo "[$top] PASS"; summary+=("$top: PASS")
  else
    echo "[$top] FAIL (exit $rc)"; summary+=("$top: FAIL"); fail=1
  fi
done
((${#TBS[@]} == 0)) && { echo "tb/ has no tb_*.sv: skipped"; summary+=("tests: skipped (no TB)"); }

sec "Summary"
printf '%s\n' "${summary[@]}"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  { echo "### async-fifo-sv CI"; printf -- '- %s\n' "${summary[@]}"; } >> "$GITHUB_STEP_SUMMARY"
fi
exit $fail

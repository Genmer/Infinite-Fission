#!/bin/bash
# R269 fix-round-1 QA battery — 7 suites, each its own process, sequential.
cd /e/Code/Agent/Infinite-Fission || exit 9
OUT=repo/docs/qa/_r269_batt
: > "$OUT/_results_fix1.txt"

run() {
  local name="$1"; shift
  ./tools/Godot_v4.3-stable_win64_console.exe --headless --path repo "$@" > "$OUT/fix1_$name.log" 2>&1
  local ec=$?
  local summary
  summary=$(grep -a "验收汇总\|汇总：PASS" "$OUT/fix1_$name.log" | tail -1)
  echo "$name | exit=$ec | $summary" >> "$OUT/_results_fix1.txt"
}

run qa_r269_bucketprobe   -s tests/qa_r269_bucketprobe.gd
run qa_r269_boostmode     -s tests/qa_r269_boostmode.gd
run test_qa_r220_mode     -s tests/runner/test_qa_r220_mode.gd
run test_r220_governor    -s tests/runner/test_r220_governor.gd
run qa_r228_diagfreeze    -s tests/qa_r228_diagfreeze.gd -- compare=tests/qa_r228_diagfreeze_before_stripped.txt
run test_verify_feedback  -s tests/runner/test_verify_feedback.gd
run test_fx_quality       -s tests/runner/test_fx_quality.gd
echo "BATTERY_DONE" >> "$OUT/_results_fix1.txt"

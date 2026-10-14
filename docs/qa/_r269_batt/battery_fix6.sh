#!/bin/bash
# R269 fix-6 QA battery — probe + 4 suites, each own process.
cd /e/Code/Agent/Infinite-Fission || exit 9
OUT=repo/docs/qa/_r269_batt
: > "$OUT/_results_fix6.txt"

run() {
  local name="$1"; shift
  ./tools/Godot_v4.3-stable_win64_console.exe --headless --path repo "$@" > "$OUT/fix6_$name.log" 2>&1
  local ec=$?
  local summary
  summary=$(grep -a "验收汇总\|汇总：PASS" "$OUT/fix6_$name.log" | tail -1)
  echo "$name | exit=$ec | $summary" >> "$OUT/_results_fix6.txt"
}

run qa_r269_boostmode     -s tests/qa_r269_boostmode.gd
run test_qa_r220_mode     -s tests/runner/test_qa_r220_mode.gd
run test_r220_governor    -s tests/runner/test_r220_governor.gd
run test_verify_feedback  -s tests/runner/test_verify_feedback.gd
echo "BATTERY_DONE" >> "$OUT/_results_fix6.txt"

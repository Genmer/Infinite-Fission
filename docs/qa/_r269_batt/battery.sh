#!/bin/bash
# R269 QA battery — each suite in its own process, sequential.
cd /e/Code/Agent/Infinite-Fission || exit 9
OUT=repo/docs/qa/_r269_batt
mkdir -p "$OUT"
: > "$OUT/_results.txt"

run() {
  local name="$1"; shift
  ./tools/Godot_v4.3-stable_win64_console.exe --headless --path repo "$@" > "$OUT/$name.log" 2>&1
  local ec=$?
  local summary
  summary=$(grep -a "验收汇总" "$OUT/$name.log" | tail -1)
  echo "$name | exit=$ec | $summary" >> "$OUT/_results.txt"
}

run qa_r269_boostmode          -s tests/qa_r269_boostmode.gd
run qa_r269_bucketprobe        -s tests/qa_r269_bucketprobe.gd
run test_r220_governor         -s tests/runner/test_r220_governor.gd
run test_qa_r220_mode          -s tests/runner/test_qa_r220_mode.gd
run test_fx_quality            -s tests/runner/test_fx_quality.gd
run test_qa_r218_probe         -s tests/runner/test_qa_r218_probe.gd
run test_r218_simbound         -s tests/runner/test_r218_simbound.gd
run test_r230_k2_deathcap      -s tests/runner/test_r230_k2_deathcap.gd
run test_r229_pool_valve       -s tests/runner/test_r229_pool_valve.gd
run test_r212_poolwarm         -s tests/runner/test_r212_poolwarm.gd
run test_r213_fullload         -s tests/runner/test_r213_fullload.gd
run test_r202_g3_enemyhot      -s tests/runner/test_r202_g3_enemyhot.gd
run test_pkg0                  -s tests/runner/test_pkg0.gd
run test_pkg3                  -s tests/runner/test_pkg3.gd
run qa_r268_physphase          -s tests/qa_r268_physphase.gd
run test_r195_adapt            -s tests/runner/test_r195_adapt.gd
run test_pkg4                  -s tests/runner/test_pkg4.gd
run test_verify_feedback       -s tests/runner/test_verify_feedback.gd
run qa_r267_crystal_blade      -s tests/qa_r267_crystal_blade.gd
run test_r267_runstart_prewarm -s tests/qa_r267_runstart_prewarm.gd
run qa_r228_diagfreeze         -s tests/qa_r228_diagfreeze.gd -- compare=tests/qa_r228_diagfreeze_before_stripped.txt
echo "BATTERY_DONE" >> "$OUT/_results.txt"

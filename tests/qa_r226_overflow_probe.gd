# tests/qa_r226_overflow_probe.gd
# R226 QA 探针入口（非电池口——电池只 glob tests/runner/test_*.gd；手工跑法：
#   ./tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/qa_r226_overflow_probe.gd
# 猎杀面：拆帽后超大层数的溢出/NaN、F4 池钳退役后的全额化、诅咒负贡献线性、
# MULT 取优无限层、满层质变 ×1.6 幂等、存档层数恢复数学（restore=N×attach 同构）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/qa_r226_overflow_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R226 拆帽边界探针（溢出/NaN/诅咒/取优/恢复） ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

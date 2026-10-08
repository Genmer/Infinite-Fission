# tests/test_r225_fullload_visual.gd
# R225 满载敌视觉再降回归入口（门禁按指令路径 tests/test_r225_fullload_visual.gd 直跑——
# R225 门禁第 1 轮实锤；用例体单源在 tests/runner/r225_fullload_visual_cases.gd，
# tests/runner/test_r225_fullload_visual.gd 为电池 glob（_batt_r215.py:12 只扫
# tests/runner/test_*.gd）保留的同内容入口，两入口零断言重复）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/r225_fullload_visual_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R225 满载敌视觉再降回归 ══════════")
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

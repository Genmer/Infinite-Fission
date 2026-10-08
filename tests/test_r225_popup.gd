# tests/test_r225_popup.gd
# R225 跳字位图化·门禁入口（门禁按 tests/<文件名>.gd 口径直跑本文件）。
# 与 tests/runner/test_r225_popup.gd 同构薄引导（电池 glob=tests/runner/test_*.gd，
# _batt_r215.py:12——两入口共用同一用例体 r225_popup_cases.gd，防双份用例漂移）。
# 结构说明（铁律②）：-s 脚本编译早于 autoload 注册，入口只做引导无顶层类型化引用；
# 用例体经运行时 load 编译。
extends SceneTree

const CASES_PATH := "res://tests/runner/r225_popup_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R225 跳字位图化自测 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("汇总：PASS 0 / FAIL 1（共 1 项）")
		quit(1)
		return
	var cases = cases_script.new()
	cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

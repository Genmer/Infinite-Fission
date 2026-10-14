# tests/runner/test_r211_xpstar.gd
# R211 经验星星三合一自测入口（godot --headless --path <工程> -s 本文件）：
# 棕星根修（白体贴图）+ 全档提亮可分辨 + 档内透明度 50%→100% 渐进。
extends SceneTree

const CASES_PATH := "res://tests/runner/r211_xpstar_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R211 经验星星验收 ══════════")
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

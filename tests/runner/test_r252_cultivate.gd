# tests/runner/test_r252_cultivate.gd
# R252 需求①「培养上限提帽」自测入口（godot --headless --path <工程> -s tests/runner/test_r252_cultivate.gd）
# 两段式入口照抄 test_r244_flushbucket.gd 模式（-s 编译期禁引工程类名纪律——
# 用例体运行时 load）。验收锚：R252 设计 §1.5 C1-C7。
extends SceneTree

const CASES_PATH := "res://tests/runner/r252_cultivate_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R252 需求① 培养上限提帽自测 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)                      # await 到用例收尾再读 fail_count（r229 入口同款）
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

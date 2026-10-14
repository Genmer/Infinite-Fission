# tests/runner/test_r252_blessing.gd
# R252 需求②「祝福（开局自选词条）」自测入口（godot --headless --path <工程> -s
# tests/runner/test_r252_blessing.gd）。两段式入口照抄 test_r244_flushbucket.gd 模式。
# 验收锚：R252 设计 §2.5 B1-B12。
extends SceneTree

const CASES_PATH := "res://tests/runner/r252_blessing_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R252 需求② 祝福系统自测 ══════════")
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

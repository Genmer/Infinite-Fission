# tests/runner/test_r230_mute.gd
# R230 二cb「静音按钮」自测入口（godot --headless --path <工程> -s tests/runner/test_r230_mute.gd）
# 真源：用户反馈「你测试的时候能静音吗，有点吵，或者说直接加一个静音按钮」——
# master_mute 设置键 + SfxBank 全播放器统一 SILENT_DB(-60) + 设置页音效音量行内静音药丸。
extends SceneTree

const CASES_PATH := "res://tests/runner/r230_mute_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R230 静音按钮自测 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)                      # r229 入口同款：await 到用例收尾再读 fail_count
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

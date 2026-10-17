# tests/qa288v2_continue_probe.gd
# 修轮复核探针（R288 修轮：QA288-1/2/3 闭合 + QA288-4 动态复核）。
# 纪律同 qa288_continue_probe.gd：-s 入口编译期先于 autoload 注册——零工程类名直引。
extends SceneTree

const CASES_PATH := "res://tests/qa288v2_continue_probe_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("════════ QA288v2 修轮复核 · 三缺口闭合取证 ════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败")
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)
	quit(1 if cases.fail_count() > 0 else 0)

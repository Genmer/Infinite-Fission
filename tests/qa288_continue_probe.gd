# tests/qa288_continue_probe.gd
# QA 独立探针（R288 刀A 快照缺口取证——continue_run 不刷新 / 遗物双源分歧 / daily 祝福行）。
# 纪律同 qa_r288_buildagg.gd：-s 入口编译期先于 autoload 注册——零工程类名直引。
extends SceneTree

const CASES_PATH := "res://tests/qa288_continue_probe_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("════════ QA288 探针 · continue_run/daily 构筑快照缺口取证 ════════")
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

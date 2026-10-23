# tests/qa_r293qa_sim.gd
# R293 QA 独立验收（模拟轴刀 + 帧率帽/诊断键）· 入口。SceneTree -s 模式（qa_r293_
# fpscap.gd 同款结构——入口零工程类名直引，用例体运行时 load）。
# 断言面与开发套件 qa_r293_simknives / qa_r293_fpscap 完全独立（不复用其夹具形状/
# 敌人布点/断言路径——QA 独立取证口径，qa_r272_qa_indep 先例）。
extends SceneTree

const CASES_PATH := "res://tests/qa_r293qa_sim_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("════════ R293 QA 独立验收 · 模拟轴刀（查询共享/帧缓存/空场早退）+ 帧率帽/drawcallsN ════════")
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

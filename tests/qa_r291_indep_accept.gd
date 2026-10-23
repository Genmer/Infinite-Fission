# tests/qa_r291_indep_accept.gd
# R291 独立 QA 验收探针（UI 定格 + 峰值四刀：副武四分频/W9 命中帽/消弹半频/拖尾门）——入口。
# 断言从验收依据 1-6 重新表述，独立于开发套件与 R289/R290 既有套件。
extends SceneTree


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ R291 独立 QA · UI 定格 + 峰值四刀验收（点 1-6） ══════════")
	await process_frame
	await process_frame
	var cs: GDScript = load("res://tests/qa_r291_indep_accept_cases.gd")
	if cs == null or not cs.can_instantiate():
		print("FAIL | 用例体加载失败")
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cs.new()
	await cases.run(self)
	var fails: int = cases.fail_count()
	quit(1 if fails > 0 else 0)

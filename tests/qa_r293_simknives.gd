# tests/qa_r293_simknives.gd
# R293 模拟刀 B 独立验收：② 段武器侧查询帧级共享（W9 查询共享 + has_target_now
# 帧缓存 + 空场早退）。入口。
extends SceneTree


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ R293 独立验收 · 模拟轴刀（查询共享/帧缓存/空场早退） ══════════")
	await process_frame
	await process_frame
	var cs: GDScript = load("res://tests/qa_r293_simknives_cases.gd")
	if cs == null or not cs.can_instantiate():
		print("FAIL | 用例体加载失败")
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cs.new()
	await cases.run(self)
	var fails: int = cases.fail_count()
	quit(1 if fails > 0 else 0)

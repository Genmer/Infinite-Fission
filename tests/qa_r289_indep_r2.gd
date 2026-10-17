# tests/qa_r289_indep_r2.gd
# R289 修轮第 2 轮独立复核入口（新增；既有 24/54 独立探针保持不改）。
extends SceneTree


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ R289 独立 QA · 第2轮复核（P1-1/P1-2/P2-3） ══════════")
	await process_frame
	await process_frame
	var cs: GDScript = load("res://tests/qa_r289_indep_r2_cases.gd")
	if cs == null or not cs.can_instantiate():
		print("FAIL | 用例体加载失败")
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cs.new()
	await cases.run(self)
	var fails: int = cases.fail_count()
	quit(1 if fails > 0 else 0)

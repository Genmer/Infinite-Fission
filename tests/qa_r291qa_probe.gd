# tests/qa_r291qa_probe.gd
# R291 QA 侧独立探针入口（额外重点 a/b/c + 点1-5 独立复测）——不触产品代码。
extends SceneTree


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ R291 QA 独立探针（a 守恒/bit 等价 · b 闩翻转 · c W8 · 点1-5 复测） ══════════")
	await process_frame
	await process_frame
	var cs: GDScript = load("res://tests/qa_r291qa_probe_cases.gd")
	if cs == null or not cs.can_instantiate():
		print("FAIL | 用例体加载失败")
		print("探针汇总：0/1 通过")
		quit(1)
		return
	var cases = cs.new()
	await cases.run(self)
	var fails: int = cases.fail_count()
	quit(1 if fails > 0 else 0)

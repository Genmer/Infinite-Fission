# tests/qa_r259_stale.gd — R259 专项深挖①：陈旧数据面 + 信号面（QA 探针，不入电池）
# 场景：缓存命中但底层数据已变 → 显示必须正确（R254-D1 同型回归）。headless 测试档。
extends SceneTree

const CASES_PATH := "res://tests/qa_r259_stale_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	var body: GDScript = load(CASES_PATH)
	if body == null or not body.can_instantiate():
		print("PROBE FAIL | 用例体加载失败：%s" % CASES_PATH)
		quit(1)
		return
	var cases: Object = body.new()
	await cases.run(self)
	var fails: int = int(cases.call("fail_count"))
	quit(1 if fails > 0 else 0)

# tests/qa_r259_leak.gd — R259 专项深挖②：内存面（QA 探针，不入电池）
# 缓存行常驻/detach 复用语义下：互切+切档+失效重建不累积；sig-miss 重建旧行去向直证。
extends SceneTree

const CASES_PATH := "res://tests/qa_r259_leak_cases.gd"


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

# tests/qa_r260_diag_state.gd — 一次性诊断/清理口（逻辑在运行时加载体——autoload 编译期不可见）
extends SceneTree

const CASES_PATH := "res://tests/qa_r260_diag_state_cases.gd"


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
	quit(0)

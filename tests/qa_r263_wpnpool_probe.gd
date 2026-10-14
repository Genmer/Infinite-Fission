# tests/qa_r263_wpnpool_probe.gd — R263 定谳探针入口：开局祝福池「武器绑定词条」缺席核查
extends SceneTree

const CASES_PATH := "res://tests/qa_r263_wpnpool_probe_cases.gd"


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

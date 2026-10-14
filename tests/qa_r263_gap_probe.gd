# tests/qa_r263_gap_probe.gd — R263 QA 独立缝隙探针（设计 §6 之外的重点缝隙面）
# 电池编排：写 user://（祝福记忆/星尘/图鉴）有副作用——单独跑、勿与其他套件混跑判读。
extends SceneTree

const CASES_PATH := "res://tests/qa_r263_gap_probe_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R263 QA 缝隙探针 ══════════")
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

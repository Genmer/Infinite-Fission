# tests/qa_r263_gift.gd — R263 祝福送武器批验收口（G1-G12）
# 电池编排：写 user://（祝福记忆/星尘/图鉴）有副作用——恒置电池末位（qa_r262e 先例）。
extends SceneTree

const CASES_PATH := "res://tests/qa_r263_gift_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R263 祝福送武器自测 ══════════")
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

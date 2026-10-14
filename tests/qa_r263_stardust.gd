# tests/qa_r263_stardust.gd — R263 祝福收费（星尘）批验收口（S1-S11）
# 电池编排：写 user://（星尘/记忆/结算记录）有副作用——恒置电池末位（qa_r262e 先例）。
extends SceneTree

const CASES_PATH := "res://tests/qa_r263_stardust_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R263 星尘经济自测 ══════════")
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

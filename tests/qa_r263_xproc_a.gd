# tests/qa_r263_xproc_a.gd — R263 真双进程 G9b · 进程 A（购买局落档）
# 用法：-s tests/qa_r263_xproc_a.gd 然后另起进程跑 -s tests/qa_r263_xproc_b.gd
# 电池编排：A 故意不还原档/不清 RunSave（跨进程链的被测面）；B 收尾统一还原。
extends SceneTree

const CASES_PATH := "res://tests/qa_r263_xproc_a_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ R263 双进程 A：购买局→暂停退出落档 ══════════")
	await process_frame
	await process_frame
	var body: GDScript = load(CASES_PATH)
	if body == null or not body.can_instantiate():
		print("PROBE FAIL | 用例体加载失败")
		quit(1)
		return
	var cases: Object = body.new()
	await cases.run(self)
	var fails: int = int(cases.call("fail_count"))
	quit(1 if fails > 0 else 0)

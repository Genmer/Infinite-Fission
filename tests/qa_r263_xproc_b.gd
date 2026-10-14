# tests/qa_r263_xproc_b.gd — R263 真双进程 G9b · 进程 B（新进程继续+重开）
# 前置：先跑 -s tests/qa_r263_xproc_a.gd；本进程独立起 Godot（Meta/_run_blessing_paid
# 全新实例口径=「杀进程重进」）。收尾：RunSave.clear + 档字节按 A 快照还原 + 清快照。
extends SceneTree

const CASES_PATH := "res://tests/qa_r263_xproc_b_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ R263 双进程 B：新进程 continue→死亡重开 ══════════")
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

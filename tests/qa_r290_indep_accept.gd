# tests/qa_r290_indep_accept.gd
# R290 独立 QA 验收探针（保帧三刀：死区/负载门/双帽/W9 缓存/关态零位移）——入口。
# 断言从验收依据 1-5 重新表述，独立于开发套件与 R289 既有套件。
extends SceneTree


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ R290 独立 QA · 保帧三刀验收（点 1-5） ══════════")
	await process_frame
	await process_frame
	var cs: GDScript = load("res://tests/qa_r290_indep_accept_cases.gd")
	if cs == null or not cs.can_instantiate():
		print("FAIL | 用例体加载失败")
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cs.new()
	await cases.run(self)
	var fails: int = cases.fail_count()
	quit(1 if fails > 0 else 0)

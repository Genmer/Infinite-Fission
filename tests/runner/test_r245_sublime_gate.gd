# tests/runner/test_r245_sublime_gate.gd
# R245「红卡大屏确认门」自测入口（godot --headless --path <工程> -s tests/runner/test_r245_sublime_gate.gd）
# 验收锚（设计 §7-1）：A) 批含 kind==SUBLIME 的 _on_card_choice 后 state==LEVEL_UP
# 且大屏 is_open；B) confirmed 后 state==PLAYING 且 resume_grace>0；C) pending>0 确认后
# 选卡窗重开；D) 进大屏时 _persist_defer_depth==0；E) 挂机模式大屏 1.5s 自动确认；
# F) 批不含 SUBLIME 时无门直通 PLAYING（链路与旧版逐位一致）。
extends SceneTree

const CASES_PATH := "res://tests/runner/r245_sublime_gate_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R245 红卡大屏确认门自测 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)                      # r244 入口同款：await 到用例收尾再读 fail_count
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

# tests/runner/test_r245_diag_gate.gd
# R245「MENU 行物步µs 伪影修复·诊断门」自测入口
# （godot --headless --path <工程> -s tests/runner/test_r245_diag_gate.gd）
# 验收锚（设计 §7-2）：A) MENU/GAME_OVER/PAUSED 态 _diag_accumulate_window 多帧后
# _diag_phys_samples==0；B) PLAYING 态照常累计；C) M 行拼装 物步µs==0 且 r229 尾锚
# 正则仍匹配；D) state_changed 后秒窗累计器归零；E) 导出头串含 R245 词条。
extends SceneTree

const CASES_PATH := "res://tests/runner/r245_diag_gate_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R245 诊断门（物步µs 状态门）自测 ══════════")
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

# tests/runner/test_qa_r220_mode.gd
# QA 独立取证入口（R220 模式地基包 A + 卡窗预热包 D——qa_r220_mode_cases.gd 用例体）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load
#（照 test_r218_simbound.gd 结构）。
extends SceneTree

const CASES_PATH := "res://tests/runner/qa_r220_mode_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · QA R220 模式地基+卡窗预热（独立取证） 回归 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

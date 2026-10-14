# tests/qa_r271_flushcut.gd
# R271 A/B 轴刀验收入口（设计 §5——qa_r271_flushcut_cases.gd 用例体）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load
#（照 tests/qa_r269_boostmode.gd 结构；套件落 tests/ 根）。
extends SceneTree

const CASES_PATH := "res://tests/qa_r271_flushcut_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R271 A/B 轴刀验收（verdict 门控：V-C1 实测 + 未触发档 SKIP 判据 + B1 判读行） ══════════")
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

# tests/qa_r271_stepacct.gd
# R271 P 轨二轮定谳键契约入口（设计 §5 p1-p6——qa_r271_stepacct_cases.gd 用例体）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load
#（照 tests/qa_r269_boostmode.gd 结构；套件落 tests/ 根）。
extends SceneTree

const CASES_PATH := "res://tests/qa_r271_stepacct_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R271 P 轨二轮定谳键（步闭环/三哨兵/树进出/绘µs/渲帧面/行格式） 回归 ══════════")
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

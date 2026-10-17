# tests/qa_r289_weaponlod.gd
# R289 深载三刀（A 武器分键+隔帧节流 / B 深载密度帽 / C 75% 应急档）契约入口
# （用例体 qa_r289_weaponlod_cases.gd）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load
#（照 qa_r288_buildagg.gd 结构）。
extends SceneTree

const CASES_PATH := "res://tests/qa_r289_weaponlod_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R289 深载三刀（A 节流+B 密度帽+C 应急档） 回归 ══════════")
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

# tests/runner/test_r232_pending_bag.gd
# R232 刀1b 回归入口（godot --headless --path <工程> -s 本文件）
# 契约：pending 字段袋——r223_settlebudget 既有口径全保（同对累积/冲刷序/过期强冲/
# 硬帽丢弃/uid 复验/幂等占位）+ 袋形态新断言（冲刷重建 ctx 字段完备性/袋池上限）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/r232_pending_bag_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R232（刀1b pending 字段袋） 回归 ══════════")
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

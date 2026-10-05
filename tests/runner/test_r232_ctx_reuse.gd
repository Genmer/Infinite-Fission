# tests/runner/test_r232_ctx_reuse.gd
# R232 刀1b 回归入口（godot --headless --path <工程> -s 本文件）
# 契约：DamageContext 弹侧复用（借出即全字段重置）+ 顺延字段袋（快照/浅拷贝/双帧字段/
# 袋池）——生命周期矩阵锁（分析 AC-3/R1/R5 断言面）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load
# （两文件铁律，test_r223_settlebudget 同构）。
extends SceneTree

const CASES_PATH := "res://tests/runner/r232_ctx_reuse_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R232（刀1b ctx 复用+pending 袋） 回归 ══════════")
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

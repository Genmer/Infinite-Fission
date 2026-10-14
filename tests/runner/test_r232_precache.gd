# tests/runner/test_r232_precache.gd
# R232 刀1c 回归入口（godot --headless --path <工程> -s 本文件）
# 契约：MULT 乘区贡献缓存——「静态贡献缓存 × 条件活评」与现网逐命中 evaluate 逐值
# 等价（分析 AC-5 全条件纯度分类的测试锁）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/r232_precache_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R232（刀1c MULT 贡献缓存） 回归 ══════════")
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

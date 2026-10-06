# tests/runner/test_r233_settleus.gd
# R233 T0 回归入口（godot --headless --path <工程> -s 本文件）
# 契约：诊断键 settle_us_per=每结算均值 µs——修前 diag_counts 字典字面量按序求值，
# 结N 键先消费 _diag_settles_last 共享基线，settle_us_per 内二次拉取差分≈0 → 分母
# maxi(n,1)=1 → 输出退化为「每秒累计 µs」而非「每结算均值 µs」（vc37 实证 8134 应为
# 39.9）。修后分母走独立差分基线（与结N 键同帧同窗同源），结N 键口径不变。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/r233_settleus_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R233 T0（结µs 每结算均值修复） 回归 ══════════")
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

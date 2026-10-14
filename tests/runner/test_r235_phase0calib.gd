# tests/runner/test_r235_phase0calib.gd
# R235 搭车④ Phase0 六臂校准件回归入口（godot --headless --path <工程> -s 本文件）
# 契约：scripts/diag/phase0_calib.gd（真机随包六臂微基准——A 属性轴/B SoA/C RefCounted/
# D local/E 逐弹方法/F 批处理）菜单态自动触发一次 + 一次性「校准」行进 DebugStats 环形
# 日志 + 二次挂载幂等不占日志；同套断言搭车③行尾三键（物步µs/派µs/渲ms）在位性。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/r235_phase0calib_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R235（搭车③④：长尾分键计时 + Phase0 真机校准件） 回归 ══════════")
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

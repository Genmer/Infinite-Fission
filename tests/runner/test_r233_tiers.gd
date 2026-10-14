# tests/runner/test_r233_tiers.gd
# R233 T3+T4 回归入口（godot --headless --path <工程> -s 本文件）
# 契约：T3=决策6 五参数（结算帽 T1/T2 + SETTLE_STALE_FRAME + DISPATCH_FRAME_CAP +
# STALE_FRAME_WINDOW + MAGNET_ABSORB_PER_FRAME）*_30HZ 档位常量+选择器，两态对拍
# （60Hz 态=原值逐位 / 30Hz 态=新档逐位 / 原六 const 两态均不改写——const 断言保护
# 策略的套件级锁定，AC-6）；T4=决策2 四处半频相位短路（_ui/_fx/_shard subtick +
# orbit_field _redraw_ctr，谓词成立时隔帧分支不生效每 tick 直驱、60Hz 态行为逐位
# 不变，AC-8）+ 派发/顺延/强冲行为两态对拍（帽 48→96、窗 30→15、强冲 12→6）。
# headless 电池口径零扰动（桌面/headless 谓词恒 false=现状 60Hz 档）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/r233_tiers_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R233 T3+T4（五参数档位联动 + 四处相位短路） 回归 ══════════")
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

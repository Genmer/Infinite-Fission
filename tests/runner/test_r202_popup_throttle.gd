# tests/runner/test_r202_popup_throttle.gd
# R202 伤害数字节流·自测入口（godot --headless --path <工程>
#   -s tests/runner/test_r202_popup_throttle.gd）。
# G2「伤害数字节流」（popupPolicy 两态口径）：层1 同目标存活即并入 + CRIT 升格 +
# element 刷新 + 层2 满池全局单例 1/8 采样 + 入口 settings 缓存 + tick 等值跳过写点。
# 命名注记：test_r202_perf.gd 已被 G4「帧率显示」套件占用（fpsFeature），本组用
# 独立名 test_r202_popup_throttle 防覆盖别组工作。
# 结构说明（同 test_fx_quality）：-s 脚本编译早于 autoload 注册，入口只做引导；
# 用例体 r202_popup_throttle_cases.gd 经运行时 load 编译。
extends SceneTree

const CASES_PATH := "res://tests/runner/r202_popup_throttle_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R202 伤害数字节流（G2）自测 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("汇总：PASS 0 / FAIL 1（共 1 项）")
		quit(1)
		return
	var cases = cases_script.new()
	cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

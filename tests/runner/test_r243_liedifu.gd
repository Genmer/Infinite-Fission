# tests/runner/test_r243_liedifu.gd
# R243 法器·裂地斧（w2-liedifu）专项套件入口：掷斧幽灵飞行 + 落地震荡 AOE/清弹/
# 击退 + GroundShockFx 裂地特效 + FRACTAL 子斧二次迷你震荡 + 图标 static func。
# 契约：headless、退出码判据（0 过 / 1 挂）；「共 N 项」总数断言与用例数一致
#（R231 假绿教训）。设计 §9.1 talisman ④⑤⑥⑦ + 验收 ①~⑩。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/r243_liedifu_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R243（法器·裂地斧 w2-liedifu） 专项套件 ══════════")
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

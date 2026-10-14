# tests/runner/test_r241_boomfix.gd
# R241 回旋刃三修 + 技能自动施放按钮回归入口。
# 契约：② 元素附魔刃体基色参数化（KIN=金原观感）；① 回旋母弹分裂子代=迷你回旋刃
# （boomerang 键 + 0.55×短甩程）+ 子代寿命地板 1.2s（EXPIRE 期分裂静默白给修复）；
# ③ 出程速度地板 60px/s 翻相守卫（跳弹永存门 999s 死刃滞空修复）；④ HUD 技能键
# 正下方自动施放开关（Meta 单一真源 skill_auto_cast；开=冷却完成自动施放，
# PLAYING+未暂停+有技能四重门）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/r241_boomfix_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R241（回旋刃三修+技能自动施放） 回归 ══════════")
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

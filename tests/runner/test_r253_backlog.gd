# tests/runner/test_r253_backlog.gd
# R253 缓办清账批自测入口（godot --headless --path <工程> -s 本文件）
# 验收锚：A) 护盾独立计时运行时补充（tick 逐单元/重挂保进度/视图同步）
# B) 防御控制向六遗物（激活+效果落点）C) 第 2 关保底遗物 D) 每日挑战固定普通
# E) fission 首发难度门 F) 源码锚（红卡排除/横幅抽公共/文案消歧/SpellRing 推进）。
extends SceneTree

const CASES_PATH := "res://tests/runner/r253_backlog_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R253 缓办清账批自测 ══════════")
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

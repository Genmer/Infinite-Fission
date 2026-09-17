# tests/runner/test_barrage.gd
# Boss 弹幕专项自测入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_barrage.gd）
# 覆盖（ENEMY_BOSS_TELEGRAPH.md §9 P1 验收要点）：三型弹幕齐射 count/arc 断言、
# 前摇预警门控（预警期零出弹）、冻结停摆、阶段门控、跟射波、存量折算、
# DataValidator barrage 校验、敌弹 soak（0.6s 无敌帧）、同屏敌弹预算、E4 泛化回归。
#
# 结构说明（同 pkg0~pkg5）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，
# 入口只做引导；用例体 barrage_cases.gd 经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/barrage_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · Boss 弹幕专项自测 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

# tests/runner/test_r252_menu_perf.gd
# R252 需求④菜单点击性能 + 图鉴「祝福」页签 自测入口（SceneTree 脚本：
# godot --headless --path <工程> -s tests/runner/test_r252_menu_perf.gd）
# 覆盖（设计 §4.5）：M0 基线探针对比 / M1 首建上限 / M2 无双布局 / M3 委托臂成品缓存 /
# M4 双预热预算 / M5 写盘收口 / M6 页签无条件重建回归 / M7 页签改名 + P2/P3 直测。
# 结构说明（同 pkg0~pkg5 / test_rxn_codex）：-s 脚本模式下入口脚本编译早于 autoload
# 全局名注册，入口只做引导；用例体经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/r252_menu_perf_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R252 菜单性能+祝福页签 自测 ══════════")
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

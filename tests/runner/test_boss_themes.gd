# tests/runner/test_boss_themes.gd
# Boss 主题攻击专项自测入口（godot --headless --path <工程> -s tests/runner/test_boss_themes.gd）
# 覆盖（R18 P2 + 用户点名「冰大范围降冰/火大范围喷火」）：mine 雷区（flavor 皮 +
# 冰锁减速池/毒潭）、laser_sweep 扫线（起角锁定/垂距命中）、E17~E20 配置迁移、玩家减速通道。
extends SceneTree

const CASES_PATH := "res://tests/runner/boss_theme_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · Boss 主题攻击自测 ══════════")
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

# tests/runner/test_weapon_orbit.gd
# 武器悬浮层 + W9 随机挥砍 + 环绕飞刀自测入口（godot --headless --path <工程>
# -s tests/runner/test_weapon_orbit.gd）。真源：R25 用户反馈。
extends SceneTree

const CASES_PATH := "res://tests/runner/weapon_orbit_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 武器悬浮层自测 ══════════")
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

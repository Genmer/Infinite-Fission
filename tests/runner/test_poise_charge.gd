# tests/runner/test_poise_charge.gd
# 韧性条打断 + B5 三连冲锋 + 施法音色自测入口（godot --headless --path <工程>
# -s tests/runner/test_poise_charge.gd）。真源：ENEMY_BOSS_TELEGRAPH §2.1 韧性 / B5 冲锋 / §9 P3。
extends SceneTree

const CASES_PATH := "res://tests/runner/poise_charge_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 韧性/冲锋/音色自测 ══════════")
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

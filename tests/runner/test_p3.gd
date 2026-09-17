# tests/runner/test_p3.gd
# Boss 三阶段+狂暴+裂变召唤专项自测入口（godot --headless --path <工程> -s tests/runner/test_p3.gd）
# 真源：docs/design/ENEMY_BOSS_TELEGRAPH.md §3 阶段模板 / B4 裂变召唤 / B8 狂暴化（§9 P3）。
extends SceneTree

const CASES_PATH := "res://tests/runner/p3_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · Boss P3 专项自测 ══════════")
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

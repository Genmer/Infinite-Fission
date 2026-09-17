# tests/runner/test_history.gd
# 历史功能抽查自测入口（godot --headless --path <工程> -s tests/runner/test_history.gd）
# 真源：FEEDBACK_TRACKER 历史轮中无自动化覆盖的功能——R8 W9消弹/刷新倍价、
# R2 换一批/存档、R15 暴击谐振重置技能冷却。
extends SceneTree

const CASES_PATH := "res://tests/runner/history_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 历史功能抽查 ══════════")
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

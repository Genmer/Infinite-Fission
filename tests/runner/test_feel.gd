# tests/runner/test_feel.gd
# 打击质感 + 技能演出自测入口（godot --headless --path <工程> -s tests/runner/test_feel.gd）
# 真源：R19 用户反馈「优化打击整体质感」「技能没特效、不知道效果何时结束」。
extends SceneTree

const CASES_PATH := "res://tests/runner/feel_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 打击质感/技能演出自测 ══════════")
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

# tests/runner/test_cd_pace.gd
# R29 迟到减CD 专项自测入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_cd_pace.gd）
# 真源：用户反馈「迟到减cd 角色cd应该立刻见效、减少」——减CD/射速词条、技能急速、
# 过载咆哮等改节拍的增益到手时，已在倒计时的冷却必须按比例立刻缩短，不等自然走完。
extends SceneTree

const CASES_PATH := "res://tests/runner/cd_pace_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 迟到减CD 专项自测 ══════════")
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

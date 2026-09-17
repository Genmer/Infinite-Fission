# tests/runner/test_p1_polish.gd
# P1 清账批次自测入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_p1_polish.gd）
# 覆盖：战前补给固定商店（R5.12-P1）/ 金币词条 AFF_GOLD（R5.12-P1）/ 前期构筑提速三件套
# （R5.12-P1：武器卡保底/槽2提前/手枪基伤）。
extends SceneTree

const CASES_PATH := "res://tests/runner/p1_polish_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · P1 清账批次自测 ══════════")
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

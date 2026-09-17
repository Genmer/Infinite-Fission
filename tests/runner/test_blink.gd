# tests/runner/test_blink.gd
# BLINK 闪现爆炸族专项自测入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_blink.gd）
# 覆盖（ENEMY_PATTERNS_BASIC.md §3.3 / §6.6 测试锚）：落点快照 ±24、冻结断读条、
# 击退断引信、引信冻结停摆、走位出圈免伤、世界层红圈、E24 数据/校验、魔域波表织入。
extends SceneTree

const CASES_PATH := "res://tests/runner/blink_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · BLINK 闪爆族专项自测 ══════════")
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

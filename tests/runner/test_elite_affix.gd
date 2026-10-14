# tests/runner/test_elite_affix.gd
# 夜间R39 精英词缀专项自测入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_elite_affix.gd）
# 真源：待办池「精英技能词缀五件套」（ENEMY_BOSS_TELEGRAPH.md §6：Boss 技弱化版，
# wave8+ 投放 / 15+ 双词缀 / 前摇含 +150ms / 冻结打断 cd 退 50% / 扫线狂暴永不下发）。
extends SceneTree

const CASES_PATH := "res://tests/runner/elite_affix_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 精英词缀专项自测 ══════════")
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

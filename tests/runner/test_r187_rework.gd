# tests/runner/test_r187_rework.gd
# R187 武器五方向重做整案·验收入口（godot --headless --path <工程> -s tests/runner/test_r187_rework.gd）
# 真源：docs/design/R187_WEAPON_REWORK.md §2.1~§2.5 五方向 Acceptance。
# 方向键口径：laser / prism / rockets / pistol / orbit。
# 全过 exit 0，否则 exit 1；结尾打印「验收汇总：X/Y 通过」。
extends SceneTree

const CASES_PATH := "res://tests/runner/r187_rework_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R187 武器五方向重做验收 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	cases.run(self)
	var total: int = cases.total_count()
	var failed: int = cases.fail_count()
	print("══════════════════════════════════════════════════")
	print("验收汇总：%d/%d 通过" % [total - failed, total])
	quit(0 if failed == 0 else 1)

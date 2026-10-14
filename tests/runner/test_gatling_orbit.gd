# tests/runner/test_gatling_orbit.gd
# 加特林曳光表现 + 环绕武器成长/形态互斥自测入口（godot --headless --path <工程>
# -s tests/runner/test_gatling_orbit.gd）。真源：R19 用户反馈（手枪/加特林表现区分、
# 环绕武器转速/大小成长、剑/斧/闪电形态选中即锁定）。
extends SceneTree

const CASES_PATH := "res://tests/runner/gatling_orbit_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 加特林/环绕武器自测 ══════════")
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

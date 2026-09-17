# tests/runner/test_elem_immune.gd
# 元素深化专项自测入口（godot --headless --path <工程> -s tests/runner/test_elem_immune.gd）
# 真源：docs/design/ELEMENT_DEEPEN.md（R22）——元素免疫/数字元素配色/反应专属特效。
extends SceneTree

const CASES_PATH := "res://tests/runner/elem_immune_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 元素免疫/配色自测 ══════════")
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

# tests/runner/test_fx_quality.gd
# 特效质量档位自测入口（godot --headless --path <工程> -s tests/runner/test_fx_quality.gd）
# 真源：FEEDBACK_TRACKER R19「buff 叠多卡顿」——fx_quality 三档消费端接线锁定。
extends SceneTree

const CASES_PATH := "res://tests/runner/fx_quality_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 特效质量档位自测 ══════════")
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

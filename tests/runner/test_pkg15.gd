# tests/runner/test_pkg15.gd
# v1.5.0 自测入口（TTK 复校工装与平衡回收；两段式同 pkg0~pkg14：
# godot --headless --path <工程> -s tests/runner/test_pkg15.gd）
# 覆盖冻结方案 pkg15 用例组 P1~P20（A14_v1.5.0_design.md §7；每恰 1 断言）
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg15_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · v1.5.0 TTK 复校自测（pkg15 P1~P20） ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats）
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

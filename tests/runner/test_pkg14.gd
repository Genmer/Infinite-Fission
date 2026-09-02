# tests/runner/test_pkg14.gd
# v1.4.0 自测入口（Meta 二期：图鉴与成就；两段式同 pkg0~pkg13：
# godot --headless --path <工程> -s tests/runner/test_pkg14.gd）
# 覆盖冻结方案 pkg14 用例组 C1~C24（A13_v1.4.0_design.md §7；每恰 1 断言）
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg14_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · v1.4.0 Meta 二期自测（pkg14 C1~C24） ══════════")
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

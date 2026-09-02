# tests/runner/test_pkg14_extra.gd
# v1.4.0 验收补充入口（tester 独立验收补漏；两段式同 pkg14：
# godot --headless --path <工程> -s tests/runner/test_pkg14_extra.gd）
# 覆盖 pkg14 C1~C24 之外的验收缺口 X1~X10（补漏清单见 pkg14_extra_cases.gd 头注）
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg14_extra_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · v1.4.0 验收补充（pkg14_extra X1~X10） ══════════")
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

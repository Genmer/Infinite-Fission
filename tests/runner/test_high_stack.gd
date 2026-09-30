# tests/runner/test_high_stack.gd
# 高位叠层审计自测入口（godot --headless --path <工程> -s tests/runner/test_high_stack.gd）
# 两段式入口（PROGRESS.md §7 契约，仿 test_buff_audit.gd）：-s 模式入口编译早于 autoload
# 注册——本入口零 autoload 编译期引用（仅 extends SceneTree + 运行期 load()），
# process_frame 两帧（autoload 就绪）后再加载用例体执行。FAIL>0 → quit(1)。
extends SceneTree

const CASES_PATH := "res://tests/runner/high_stack_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 高位叠层审计 ══════════")
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

# tests/runner/test_verify_feedback.gd
# 用户反馈验收入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_verify_feedback.gd）
# 结构同 pkg0~pkg4：-s 模式下入口编译早于 autoload 注册 → 只做引导；用例体运行时加载。
extends SceneTree

const CASES_PATH := "res://tests/runner/verify_feedback_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 用户反馈逐项验收 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	cases.run(self)
	if cases.fail_count() > 0:
		quit(1)
	else:
		quit(0)

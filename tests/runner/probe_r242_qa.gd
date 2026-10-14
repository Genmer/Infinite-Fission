# tests/runner/probe_r242_qa.gd
# R242 QA 静态审查疑点实证探针入口（godot --headless --path <工程> -s 本文件）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/qa_r242_probe_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R242 QA 探针（门态/空转断言/混号符号/残留色） ══════════")
	await process_frame
	await process_frame
	var watchdog: SceneTreeTimer = create_timer(300.0)
	watchdog.timeout.connect(_on_watchdog)
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)
	if cases.fail_count() > 0:
		quit(1)
	else:
		quit(0)


func _on_watchdog() -> void:
	print("[watchdog] 探针超时/协程中止——强制退出（3）")
	quit(3)

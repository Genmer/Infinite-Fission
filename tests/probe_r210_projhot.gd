# tests/probe_r210_projhot.gd
# R210 弹段细分探针入口（godot --headless --path <工程> -s 本文件）。
# vc17 真机日志：fps27 时弹段 9-12ms × 赶帽 2 步 = 「余 26-33ms」主体——本探针把
# 弹段拆成 敌网格重建 / 敌弹收集+重建 / 逐弹 tick / 玩家段 / 敌段 五件称重定刀。
extends SceneTree

const CASES_PATH := "res://tests/probe_r210_projhot_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ R210 探针 · 弹段内部配比（N58 敌 + 加特林弹幕） ══════════")
	await process_frame
	await process_frame
	var watchdog: SceneTreeTimer = create_timer(600.0)
	watchdog.timeout.connect(_on_watchdog)
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("[probe] 用例体加载失败——强制退出（2）")
		quit(2)
		return
	var cases = cases_script.new()
	cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)


func _on_watchdog() -> void:
	print("[watchdog] 探针超时/协程中止——强制退出（3）")
	quit(3)

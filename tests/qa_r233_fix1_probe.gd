# tests/qa_r233_fix1_probe.gd
# R233 修复轮 QA 独立探针（入口）：HIGH-1 派deferred/派drop 行拼装真值 + 闩/独立基线
# + MED-3 关态插模拟µs 读数（量级/同窗/闩）+ 真实 1Hz 采样器行验证。
# 用法（会话根）：
#   ./tools/Godot_v4.3-stable_win64_console.exe --headless --path repo \
#     -s tests/qa_r233_fix1_probe.gd
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/qa_r233_fix1_probe_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ QA 探针：R233 修复轮独立复核（HIGH-1 派发键 / MED-3 插模拟µs） ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)
	if cases.fail_count() > 0:
		quit(1)
	else:
		quit(0)

# tests/runner/test_r233_swept.gd
# R233 T5 回归入口（godot --headless --path <工程> -s 本文件）
# 契约：决策4 swept 隧穿对策——30Hz 态（GameLoop.sim30_effective() 谓词开）粗判查询点
# 膨胀（半步弦，979.2px/s 档 +16.3px）+ 窄相线段化（步前暂存 prev→步末位弦 vs 目标圆）；
# 60Hz 态（谓词关）逐位现网。headless 用 sim30_override=-3 驱 30Hz 真值臂 / -2 强制关臂
# （r233_sim30 哨兵同款可测性）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/r233_swept_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R233 T5（swept 隧穿对策） 回归 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

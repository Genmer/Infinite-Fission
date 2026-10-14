# tests/runner/test_r206_spiral.gd
# R206 掐螺旋+尖峰取证自测入口（godot --headless --path <工程> -s 本文件）
# 覆盖：物理追赶帽 mobile 门（headless 缺省 8 不动）+ 跳字半频 mobile 门源级锚 +
#   五段峰值采样/清零钩 + 诊断行「尖峰」标记（>25ms）+ 日志头渲染键修正与追赶帽行。
extends SceneTree

const CASES_PATH := "res://tests/runner/r206_spiral_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R206 掐螺旋与尖峰取证验收 ══════════")
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

# tests/runner/test_r233_interp.gd
# R233 T6 回归入口（godot --headless --path <工程> -s 本文件）
# 契约：T6=决策3 渲染插值层（双缓冲成员×4 类实体 + 恢复/快照遍历 + _process alpha
# 写入 + 池化矩阵 + 谓词关/headless 首行直返零写）。AC-4 全矩阵 + AC-9 插µs 喂数与
# 深载 ≤500µs 冒烟。headless 口径注明：_process 在 headless 直返不可驱动（设计 R3
# 定案），写遍历/alpha 用直接调函数口径（_ip_render_write/_ip_alpha_advance）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/r233_interp_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R233 T6（渲染插值层） 回归 ══════════")
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

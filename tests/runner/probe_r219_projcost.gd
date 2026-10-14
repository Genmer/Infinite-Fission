# tests/runner/probe_r219_projcost.gd
# R219 弹段每物理步成本探针入口（godot --headless --path <工程> -s 本文件）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
# 机器行格式（供脚本侧解析，逐行精确）：
#   PROJ,N=100,ms=x.xx / PROJ,N=300,ms=x.xx / PROJ,N=600,ms=x.xx
#   PROJ,N=<tier>,part=<move|bound|visual|collide|dispatch|grid>,ms=x.xx
#   PROJ,DONE（末行）
extends SceneTree

const CASES_PATH := "res://tests/runner/probe_r219_projcost_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R219 弹段每物理步成本探针（敌弹链 N=100/300/600） ══════════")
	await process_frame
	await process_frame
	# 看门狗（probe_r210_projhot 同款）：运行期错误中止 run 协程时 await 不再恢复——
	# 无看门狗则进程永挂，脚本侧运行器被拖死。正常 quit 后计时器永不触发。
	var watchdog: SceneTreeTimer = create_timer(600.0)
	watchdog.timeout.connect(_on_watchdog)
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("PROJ,DONE")
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
	print("PROJ,DONE")
	quit(3)

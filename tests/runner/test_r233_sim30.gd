# tests/runner/test_r233_sim30.gd
# R233 T1+T2 回归入口（godot --headless --path <工程> -s 本文件）
# 契约：T2=SIM_30HZ_ENABLED 单源谓词（决策5 挂 game_loop）+ meta_manager 挂点
# 60→30（R204 mobile 门同址）——谓词 false 时 Engine 键零写（headless 早退零写点）；
# -3 哨兵同款可测性（pool_valve_override 先例）；60Hz 档选表返回原值（决策6 *_30HZ
# 后缀常量方案，T3 铺路）。T1=插µs 诊断键（决策7 诊断先于行为刀）——关态恒 0 基线、
# 行尾追加位不破尾锚。headless 电池口径零扰动（_physics_process 手动驱动不读 Engine 设置）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/r233_sim30_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R233 T1+T2（插µs 键 + SIM_30HZ 开关挂点） 回归 ══════════")
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

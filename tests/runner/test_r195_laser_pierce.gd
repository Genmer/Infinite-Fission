# tests/runner/test_r195_laser_pierce.gd
# R195 激光穿透探针入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_r195_laser_pierce.gd）
# 覆盖（S1-S9，直驱范式沿用 pkg3）：预算口径 hit=N（基线 pierce=1 零位移）、无逐目标衰减、
# pierce_index=序数+1（SYN_PIERCE_EVO 激活 ×1.2/×1.4）、灼焦归属（贯穿目标全量同叠）、
# 束端=末贯穿目标 / 无敌满束长、副束门（预算恒 1）、折射分叉数不随 N 增长、超程对照
# （E4 t=600>560 恒满血）、last_hit_uid / LaserWeapon._pierce_count / pause 面板穿透行契约。
# 结构同 pkg0~pkg5：-s 模式下入口脚本编译早于 autoload 全局名注册，入口只做引导；
# 用例体 r195_laser_pierce_cases.gd 经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/r195_laser_pierce_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R195 激光穿透探针 ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats）
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null:
		# 用例体编译失败（load 已打印解析错误）——立即失败退出（防 -s 套件悬挂电池）
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

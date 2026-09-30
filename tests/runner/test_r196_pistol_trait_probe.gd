# tests/runner/test_r196_pistol_trait_probe.gd
# R196 手枪词条家族失效探针入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_r196_pistol_trait_probe.gd）
# 探测目标（FEEDBACK_TRACKER R196 #2/#3）：
#   #2 手枪多重装填没生效——还是单发
#   #3 手枪选穿透弹头→往后面射 3 个散发子弹
# 结构同 pkg0~pkg5/r195_laser_pierce：-s 模式下入口脚本编译早于 autoload 全局名注册，
# 入口只做引导；用例体经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/r196_pistol_trait_probe_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R196 手枪词条家族探针 ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats）
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null:
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

# tests/runner/test_r252_relics.gd
# R252 遗物扩容自测入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_r252_relics.gd）
# 覆盖（设计 §3.5）：R0 注册面 34 件 / R1-R16 每件三件套（激活生效-守卫-reset）/
#   R17 RELIC 权重三源 8.0 / R18 存档随档 / 重开运行态清零。
#
# 结构说明（同 pkg0~pkg5）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，
# 入口只做引导；用例体 r252_relics_cases.gd 经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/r252_relics_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R252 遗物扩容自测 ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats）
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	cases.run(self)
	var fail_count: int = cases.fail_count()
	# 防伪绿：用例体中途脚本崩溃会以零断言数返回——run_completed 未置位即判失败
	if not bool(cases.get("run_completed")):
		print("[入口] 用例体未走完（run_completed=false）——按失败退出")
		quit(1)
	elif fail_count > 0:
		quit(1)
	else:
		quit(0)

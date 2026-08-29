# tests/runner/test_pkg5.gd
# 集成包自测入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_pkg5.gd）
# 覆盖（任务书 D）：全链冒烟（Boot→MENU→开战→击杀→掉落经验→升级→选卡→词条生效→
#   Boss 波→死亡→结算→重开）、真管线九步落血、xp 链路、遗物触发、RANGED 敌弹池化、
#   分离力、duck 收紧第二批回归、AC 核心子集（A1 §3 可自动化条目）。
#
# 结构说明（同 pkg0~pkg4）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，
# 入口只做引导；用例体 pkg5_cases.gd 经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg5_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 集成包全链自测 ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats）
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

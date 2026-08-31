# tests/runner/test_pkg7.gd
# v0.7.0 自测入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_pkg7.gd）
# 覆盖（A6_v0.7.0_design.md 增量）：
#   U1 芯片数据层（ChipData schema/8 .tres/validator/registry 类目）、U2 运行时（ChipHandler
#   装备/槽位/商店 offer/Boss 掉落/波次解锁）、U3 结算接线（芯片独立乘区段/crit 折算/射速/
#   消费点）、U12 双 Boss 修复、U13 召唤计数、U14 kind 单源+受击红闪、U5 金币关、
#   U4+U7 商店芯片货架/槽位面板、U6 Boss 芯片掉落、U8~U10 反应表现与统计、U11 首件武器保底。
#
# 结构说明（同 pkg0~pkg6）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，
# 入口只做引导；用例体 pkg7_cases.gd 经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg7_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · v0.7.0 自测 ══════════")
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

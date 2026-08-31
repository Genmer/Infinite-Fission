# tests/runner/test_pkg6.gd
# v0.6.0 自测入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_pkg6.gd）
# 覆盖（A4_v0.6.0_design.md 增量）：
#   T1 武器门槛词条（required_weapon 过滤 + apply 防御）、T4 金币词条数据 + 校验器扩项、
#   T3 金币链路（掉落可复现/满池合并守恒/吸收入账/restart 归零/chance 抽样）、
#   T5 武器卡（候选全集/满槽空/权重和/三处同值/apply 增槽/已持有去重）、
#   T2 HUD 布局（layout_rects 不相交/横幅时序/配色）、T6 商店（状态机/触发器/购买仲裁/黑市）、
#   T7 Boss 弹幕（fan/ring/spiral 节奏/召唤/敌弹伤害/split hp_override/死后停射）。
#
# 结构说明（同 pkg0~pkg5）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，
# 入口只做引导；用例体 pkg6_cases.gd 经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg6_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · v0.6.0 自测 ══════════")
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

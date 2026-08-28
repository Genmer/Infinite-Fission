# tests/runner/test_pkg0.gd
# 包 0 基座自测入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_pkg0.gd）
# 覆盖：池取出/归还/满池丢弃/清洁断言、SpaceGrid 插入查询（含边界桶）、EventBus 订阅退订/
# 风暴计数/订阅回落、DataValidator 坏数据剔除（负射速/δ>0.92/缺字段）、ModifierStack 聚合
# 断言（B_spec 公式例 336 / 同实例重入 150）、GameConfig/DebugStats/DataRegistry 骨架。
# 每断言 print PASS/FAIL + 汇总；失败以非零退出码结束（模式 A 口径，A2 §6.2）。
#
# 结构说明：-s 脚本模式下入口脚本的编译早于 autoload 全局名注册（EventBus/GameConfig/
# DebugStats 在 Main::start 后期才进 GDScript 全局表），故入口只做引导；用例体在
# pkg0_cases.gd，经运行时 load 编译——此时三个 autoload 已就绪（已实测验证），
# 用例可按工程常规以全局名访问 autoload。正常游戏路径（autoload 自身）不受此影响。
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg0_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 包 0 基座自测 ══════════")
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

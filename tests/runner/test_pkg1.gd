# tests/runner/test_pkg1.gd
# 包 1 · 伤害结算管线自测入口（SceneTree 脚本：
#   godot --headless --path <工程> -s tests/runner/test_pkg1.gd）
# 覆盖（架构 §7.2 包 1 自测清单 / 模式 A 公式回归）：
#   AC-12.1 公式锚点 336 / AC-12.2 防御层 150 / F3 衰减不等式族 / F4+Flat 池钳 /
#   单区 cap / 名额 top-8 + priority 决胜 / F9 整体钳 8.0 / R_alarm 双闸一局一次 /
#   暴击固定种子复现 / 幂等 + 死亡短路 / NaN sanitize / 诅咒全额 / Local 独立 /
#   目标侧抗性×易伤 / 反应独立结算快照口径 / 1000 次确定性哈希。
# 每断言 print PASS/FAIL + 汇总；失败以非零退出码结束（模式 A 口径，A2 §6.2）。
#
# 结构说明（沿用包 0 两段式入口）：-s 脚本模式下入口脚本的编译早于 autoload 全局名
# 注册（EventBus/GameConfig/DebugStats 在 Main::start 后期才进 GDScript 全局表），
# 故入口只做引导；用例体在 tests/formula/test_formula_pipeline.gd，经运行时 load
# 编译——此时三个 autoload 已就绪，用例可按工程常规以全局名访问 autoload。
extends SceneTree

const CASES_PATH := "res://tests/formula/test_formula_pipeline.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 包 1 伤害管线自测 ══════════")
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

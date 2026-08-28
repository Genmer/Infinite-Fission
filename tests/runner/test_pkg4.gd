# tests/runner/test_pkg4.gd
# 包 4 自测入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_pkg4.gd）
# 覆盖（PROGRESS §5 行动 5 / 任务书必测要点）：
#   状态机迁移矩阵（含非法迁移拒绝 / E-16 死亡与升级仲裁）、顿帧档位来自 gamefeel 配置且
#   Engine.time_scale 恒不被改写、game_delta 双时间通道（顿帧期 game_delta≈0 而 raw 正常）、
#   trauma 档位与衰减、固定帧序一次 tick 内调用顺序、HUD 数值绑定、跳字池化 0 运行期实例化、
#   三选一全流程（roll 数量/池过滤/应用后恢复/连升排队/fallback）、爆虫引爆时序与警示圈、
#   Boss 波伴随怪节奏（波表驱动 + pkg2 fallback 兼容）。
#
# 结构说明（同 pkg0~pkg3）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，
# 入口只做引导；用例体 pkg4_cases.gd 经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg4_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 包 4 表现与流程自测 ══════════")
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

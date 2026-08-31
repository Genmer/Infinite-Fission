# tests/runner/test_pkg6_extra.gd
# v0.6.0 验收补漏入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_pkg6_extra.gd）
# 由 tester 独立验收补写（不并入 pkg6 基线 115 项，保持 PROGRESS 基线口径不变）：
#   T1 DataRegistry 加载 68 资源 0 剔除（表尺寸 vs 文件系统独立对账）
#   T4 卡池 500 抽（固定种子）金币双词条各 ≥1 次 / apply 掉率词条 chance=0.06 抽样上移 ≥6.8% /
#      叠满 stack_max 移出候选池
#   T5 apply 武器卡后精通候选含新武器
#   T6 restart 后限购位/金币/商店库存归零 + 黑市申请不跨局
#
# 结构说明（同 pkg0~pkg6 两段式入口）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，
# 入口只做引导；用例体 pkg6_extra_cases.gd 经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg6_extra_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · v0.6.0 验收补漏自测 ══════════")
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

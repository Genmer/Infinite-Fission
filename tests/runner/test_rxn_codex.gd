# tests/runner/test_rxn_codex.gd
# 图鉴「反应」页自测入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_rxn_codex.gd）
# 覆盖（R191#5 用户反馈「图鉴里专门开一个元素反应的展示」）：
#   reaction_note 文案单源 / 三源同锁 3 条（枚举·数值表·跳字规格表）/ R186 反应字型参数 /
#   页构建（4 页签 + 反应页 3 行）/ 行级断言（名称=单源、副文案含 effect+unlock、
#   预览五项 override、倍率跟随 reaction_table）/ 页签显隐互斥 / 无存档键改动 /
#   反应触发真条件（双槽附着、2s CD、优先级——无难度门，页面文案同口径）。
# 结构说明（同 pkg0~pkg5 / test_mech_gate）：-s 脚本模式下入口脚本编译早于 autoload
# 全局名注册，入口只做引导；用例体经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/rxn_codex_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 图鉴反应页自测 ══════════")
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

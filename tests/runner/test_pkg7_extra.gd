# tests/runner/test_pkg7_extra.gd
# v0.7.0 验收补漏入口（tester 独立验收；SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_pkg7_extra.gd）
# 覆盖（pkg7 未覆盖的验收点增量；两段式同 pkg0~pkg7：入口只做引导，用例体运行时 load）：
#   U1 重复扫描幂等 / U3 芯片不占乘区 top-8 名额 + joint 手算对照 + 拔芯片回基线 + clamp 保留 /
#   U5 固定种子掉落次数对比 + 波末奖励单调 / U4+U7 闭店重开货架可复现 /
#   U8 环元素色 + 衰减 + 死亡隐藏 / U9 burst 计数与 scene_id 映射在环 /
#   U12 BossBar 联动 / U13 伴随满场召唤仍触发 / U14 shop_ui kind 单源 / ③ 金币关经济链一次。
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg7_extra_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · v0.7.0 验收补漏（tester 独立） ══════════")
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

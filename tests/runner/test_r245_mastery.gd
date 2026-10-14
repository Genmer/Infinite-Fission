# tests/runner/test_r245_mastery.gd
# R245 需求⑤「武器精通品质梯白蓝紫三档全分化」自测入口
# （godot --headless --path <工程> -s tests/runner/test_r245_mastery.gd）
# 真源：docs/design/2026-10-09-R245-design.md §5 / §7-5：
#   boosts = 1 + rarity（白+1/蓝+2/紫+3）；rarity_cap 钳档与去金档语义不变；
#   MASTERY_DOUBLE_RARITY 常量删除；卡面连升 ×N 动态化；R85 蓝白同值压平推翻。
extends SceneTree

const CASES_PATH := "res://tests/runner/r245_mastery_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R245 精通品质梯三档分化自测 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

# tests/runner/test_residue.gd
# Boss 死亡残留专项自测入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_residue.gd）
# 真源：用户反复反馈（R8/R15/R18 共 10 次）「Boss 死爆开的球残留不消失」——
# R18 根修三件套：Boss/精英死亡全场碎片立即磁吸 + 状态切换（选卡/暂停/结算）磁吸 +
# 彩纸 PROCESS_MODE_ALWAYS 真实时间自清。
extends SceneTree

const CASES_PATH := "res://tests/runner/residue_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · Boss 残留专项自测 ══════════")
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

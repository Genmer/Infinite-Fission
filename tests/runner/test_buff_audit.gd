# tests/runner/test_buff_audit.gd
# 全池 buff 行为审计自测入口（godot --headless --path <工程> -s tests/runner/test_buff_audit.gd）
# 真源：用户点名「buff 整体合理性/整体池全部评估，无效 buff 修复掉」——
# 补齐零覆盖卡的行为断言（背水协议/贯穿协鸣/几何分裂/死亡新星）+ 乘区条件 + ADD 数值表锁定。
extends SceneTree

const CASES_PATH := "res://tests/runner/buff_audit_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 全池 buff 行为审计 ══════════")
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

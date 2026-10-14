# tests/runner/test_r212_skillresume.gd
# R212 技能冷却随档自测入口（SceneTree 脚本：godot --headless --path <工程>
#   -s tests/runner/test_r212_skillresume.gd）
# 覆盖：serialize_run 快照含 skill_cd + 暂停→回主菜单→继续 往返保真（用户 bug
#   「返回主菜单再回到游戏会刷新角色技能」）+ 满 CD 边界 + 旧档无键零迁移
#   + 脏档超界 clamp + 恢复后就绪态口径（skill_ready）。
extends SceneTree

const CASES_PATH := "res://tests/runner/r212_skillresume_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R212 技能冷却随档验收 ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats→Meta）
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

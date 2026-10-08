# tests/probe_r244_skill_stack.gd（R244 技能自动施放·僚机叠层 根因复现探针入口）
# 跑法：APPDATA=E:/Code/Agent/Infinite-Fission/.qa_sandbox_r243 Godot --headless \
#         --path E:/Code/Agent/Infinite-Fission/repo -s tests/probe_r244_skill_stack.gd
# 假设检验：诺亚 _skill_summon_orbs 在效果期（SUMMON_DURATION=10s）内再激活时
#   append 新副本/新护航舰而不清旧（player.gd:914/934/935），共享 _summon_left 标量
#   被再施放刷新→旧副本永不到期。自动/手动同病（同走 activate_skill，本体验收门
#   只有 skill_ready 冷却不查增益期）。绕过冷却=把 skill_cd_left 直写 0（等效
#   CDR 堆到有效 CD<10s 后自动施法的逐帧再触发）。
# 纪律：-s 入口零工程类名直引（全鸭子），用例体运行时加载；无 test_ 前缀不入电池。
extends SceneTree

const CASES_PATH := "res://tests/probe_r244_skill_stack_body.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	var body: GDScript = load(CASES_PATH)
	if body == null or not body.can_instantiate():
		print("PROBE FAIL | 用例体加载失败：%s" % CASES_PATH)
		quit(1)
		return
	var cases: Object = body.new()
	await cases.run(self)
	var fails: int = int(cases.call(&"fail_count"))
	if fails > 0:
		print("PROBE 汇总：%d 项硬门未过" % fails)
		quit(1)
	else:
		print("PROBE 汇总：硬门全过")
		quit(0)

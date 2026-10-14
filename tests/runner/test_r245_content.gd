# tests/runner/test_r245_content.gd
# R245「内容扩容批」流C 自测入口（godot --headless --path <工程> -s tests/runner/test_r245_content.gd）
# 覆盖（设计 docs/design/2026-10-09-R245-design.md §4 / §7-4 验收 A-F）：
#   A 展开后全表 160 条 + 逐 type 计数对账（撞 id/撞档守卫零跳过的等价证明）
#   B 8 信号→计数→解锁全链（skill_cast/player_died/graze/shield_blocked+bullet_nullified/
#     trait_milestone/revive_burst/reroll_granted/damage_alarm + A 组事件链）
#   C 旧档（无新键）load 后默认 0、achievements_done 不回收（零迁移）
#   D RELIC 卡 → codex_relics 收录 + 图鉴遗物页签 18 行 + 角标分母 133
#   E 奖励总额 1800 ≤ 封顶 1850（动态求和）
#   F 未完成成就行进度值（x/y）与 _counter_value 一致
# 结构说明（同 test_r244_flushbucket / test_rxn_codex 先例）：-s 脚本模式下入口脚本编译
# 早于 autoload 全局名注册，入口只做引导；用例体经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/r245_content_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R245 内容扩容（成就+图鉴）自测 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)                      # r244 入口同款：await 到用例收尾再读 fail_count
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

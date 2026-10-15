# tests/qa_r285_gridhit.gd
# R285 弹侧根治批 QA 套件入口（设计 docs/design/2026-10-15-R285-projectile-perf-design.md §5）：
# · T1 boost 开网格命中 sweep 语义断言（t1a 序守卫 / t1b 收集冲刷同帧 / t1c 命中对拍 /
#   t1d 关态逐位 / t1e 掷斧·敌弹不受扰）；
# · boost 关 A/B 逐位对拍（强关压过 boost——pkg4 关键路径夹具同源读数）；
# · T2 物面守门（p1 弹场景零物理件 / p2 全树 Area2D 白名单 / p3 CONTACT_RADIAL 旗语义锁 /
#   p4 boost 两态集合逐位）；
# · T3 死亡链冲刷（t3a 批量化快照语义 / t3b inline 面不动 / t3c 关态即时 / t3d 兜底排空 /
#   t3e 燎原连锁读数漂移声明带）；
# · P0 四分键+ipµs 桶在账断言（命/结/死/回/ip 五键 + shortcircuit_ip_pass 机制）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load
#（照 tests/qa_r271_deeprepro.gd 结构；套件落 tests/ 根）。
# 盘档纪律（§0.5）：套件自清——Meta._settings 入口快照、收尾整字典还原 + Meta._save()
# 落盘（headless 存档走 meta_save_test.cfg）；本套件零落盘文件写点。
extends SceneTree

const CASES_PATH := "res://tests/qa_r285_gridhit_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R285 弹侧根治批 QA（T1 网格命中 sweep + T2 物面守门 + T3 死亡冲刷） ══════════")
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

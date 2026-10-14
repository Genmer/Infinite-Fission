# tests/qa_r267_panel_cache.gd — R267 刀P3 三面板行缓存验收入口（记录/养成/每日）
# 验收面（设计 §1.3）：
#   a) 首开建组（全量构建路径不回归）+ 重开直挂（≤1500µs 且 ≪ 首开）；
#   b) 面板内购买轻刷新（行不换实例、文案/货币角标即时更新、≤1500µs）；
#   c) 指纹失效语义：显示字段变→重建新实例且文案更新；字段不变→同实例直挂；
#      DailyStartButton 语义名保持（verify_feedback 可达性锚）。
# 纪律：-s 入口零工程类直引，逻辑全在 cases 体运行时加载；套件首尾快照/还原 Meta。
extends SceneTree

const CASES_PATH := "res://tests/qa_r267_panel_cache_cases.gd"


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
	var fails: int = int(cases.call("fail_count"))
	quit(1 if fails > 0 else 0)

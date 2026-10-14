# tests/qa_r257_probe_p7drain.gd — R257 QA-257-3 探针入口（只读产品代码）
# 目的：r188_idle P7 溢出批消化慢因量化——每帧抽卡预算/merged 递减速率/单帧墙钟
# 三因子分解，定位 300s timeout「挂起」真身（慢 vs 死等 vs 递减回归）。
# 纪律：-s 入口零工程类直引，逻辑全在 cases 体运行时加载。
extends SceneTree

const CASES_PATH := "res://tests/qa_r257_probe_p7drain_cases.gd"


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
	quit(0)

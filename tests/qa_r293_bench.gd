# tests/qa_r293_bench.gd
# R293 headless 深载模拟基准台架入口（tests/qa_r293_bench_cases.gd 用例体）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load
#（照 tests/qa_r292_export_progress.gd / qa_r271_deeprepro.gd 结构；套件落 tests/ 根）。
# 只量模拟轴：固定 seed、直驱物理步 N=600；输出契约行（逐字）：
#   BENCH|total|<ms>（整步直调墙钟）/ BENCH|player| / BENCH|projectile| /
#   BENCH|enemy| / BENCH|weapons|（段探针口径，每步均值 ms）。
extends SceneTree

const CASES_PATH := "res://tests/qa_r293_bench_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R293 headless 深载模拟基准台架（敌90 驻场 + 弹448 顶格 + boost 促1 + 直驱 600 步） ══════════")
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

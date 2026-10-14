# tests/runner/test_r245_melee_unify.gd
# R245「近战统一」（需求③ · 流B）自测入口
#（godot --headless --path <工程> -s tests/runner/test_r245_melee_unify.gd）
# 真源：R245 设计文档 §3（W13 半径表下压 [130,140,155,170,190] / 挡弹域
# BLOCK_RADIUS_TABLE [60,66,72,80,92] 双域统一 / W13 化身随圈成长 /
# 虚线圈重绘去重加半径触发）。用例体 r245_melee_unify_cases.gd 运行时 load——
# -s 编译期禁引工程类名纪律（cases 禁 test_ 前缀防电池 glob 误收）。
extends SceneTree

const CASES_PATH := "res://tests/runner/r245_melee_unify_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R245 近战统一（流B）自测 ══════════")
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

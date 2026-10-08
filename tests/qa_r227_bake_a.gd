# tests/qa_r227_bake_a.gd
# QA-R227 独立探针 A（QA 侧留档）：continue_run 真链补烤 + 成本上界 + 短路零成本 +
# diag 三段贯通（bitmap_bake_us → diag_counts → debug_stats 行尾 补N + 头部口径）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/qa_r227_bake_a_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ QA-R227 探针 A：continue_run 真链 / 成本 / diag 贯通 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)
	if cases.fail_count() > 0:
		quit(1)
	else:
		quit(0)

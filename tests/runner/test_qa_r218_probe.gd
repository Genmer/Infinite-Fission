# tests/runner/test_qa_r218_probe.gd
# R218 QA 独立探针入口（godot --headless --path <工程> -s 本文件）
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
# 独立于 r218_simbound（开发自测）的第三方验证口（qa 系交叉验证，同 qa_r216/qa_r217 先例）。
extends SceneTree

const CASES_PATH := "res://tests/runner/qa_r218_probe_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R218 QA 独立探针（帽语义/分组N/他键/跳键/满载帽/契约/回归面） ══════════")
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

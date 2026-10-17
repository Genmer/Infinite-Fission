# tests/qa_r286qa_probe.gd
# R286 QA 独立探针入口（只报告不修复——用例体 qa_r286qa_probe_cases.gd 运行时加载）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引（qa_r286_diagkeys.gd 同款）。
extends SceneTree

const CASES_PATH := "res://tests/qa_r286qa_probe_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ R286 QA 独立探针（键碰撞/段窗和语义/五桶生命周期/S9 隔离） ══════════")
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
	if cases.fail_count() > 0:
		quit(1)
	else:
		quit(0)

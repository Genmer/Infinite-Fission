# tests/qa_r287qa_probe.gd
# R287 QA 独立探针入口（六段分键行格式/段和包含恒等式+popup>0 含敌台架/_tick_fast_player
# 预检门第三位点/位点1·2 直驱零副作用——用例体 qa_r287qa_probe_cases.gd）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load
#（照 qa_r287_emptyquery.gd / qa_r285_gridhit.gd 结构）。
extends SceneTree

const CASES_PATH := "res://tests/qa_r287qa_probe_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R287 QA 独立探针（行格式/段和恒等式/第三位点/直驱等价） ══════════")
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

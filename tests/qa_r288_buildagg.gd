# tests/qa_r288_buildagg.gd
# R288 构筑快照 + boost 门逐跳字关（刀A/刀B）契约入口（用例体 qa_r288_buildagg_cases.gd）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load
#（照 qa_r286_diagkeys.gd 结构）。
extends SceneTree

const CASES_PATH := "res://tests/qa_r288_buildagg_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R288 构筑快照+跳字聚合（刀A/刀B） 回归 ══════════")
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

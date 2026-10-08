# tests/runner/test_qa_r214_extra.gd
# QA R214 独立探针入口（godot --headless --path <工程> -s 本文件）
# 覆盖点：meta 跨 reparent / 桶内 global 恒等 / is_clean 闸 / 出生风暴 / 帽冻片恢复 /
#         E7 敌弹可见性根因（verify_feedback FAIL 归因）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/qa_r214_extra_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ QA · R214 补充探针（meta/恒等/闸/风暴/冻片/E7根因） ══════════")
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

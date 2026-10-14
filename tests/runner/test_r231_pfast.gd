# tests/runner/test_r231_pfast.gd
# R231 刀B「玩家弹快路径」自测入口（godot --headless --path <工程> -s tests/runner/test_r231_pfast.gd）
# 真源：R231 设计 ③ 测试计划 T8-T12 + 分析三处判据级修订（AC-4 派发后判定/EF_SIZE 排除、
# AC-6 range 内联）+ 追加快N 诊断键契约。用例体：r231_pfast_cases.gd（禁 test_ 前缀防
# 电池 glob 误收——R230 教训）。
extends SceneTree

const CASES_PATH := "res://tests/runner/r231_pfast_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R231 刀B 玩家弹快路径自测 ══════════")
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

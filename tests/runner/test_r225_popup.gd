# tests/runner/test_r225_popup.gd
# R225 跳字位图化·自测入口（godot --headless --path <工程>
#   -s tests/runner/test_r225_popup.gd）。
# 覆盖（方案口径）：字形序列正确 / CRIT·元素色 tint / 并入与帽契约 / mobile 门关闭=
# 旧路径回归锁 / 位图路径 Label 计数=0 结构断言 / 图集契约与未就绪回退。
# 结构说明（同 test_r202_popup_throttle）：-s 脚本编译早于 autoload 注册，入口只做引导；
# 用例体 r225_popup_cases.gd 经运行时 load 编译。
extends SceneTree

const CASES_PATH := "res://tests/runner/r225_popup_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R225 跳字位图化自测 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("汇总：PASS 0 / FAIL 1（共 1 项）")
		quit(1)
		return
	var cases = cases_script.new()
	cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

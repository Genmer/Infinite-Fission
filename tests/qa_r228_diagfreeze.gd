# tests/qa_r228_diagfreeze.gd
# QA-R228/R229 留档探针：诊断行冻结格式对拍（改造前后同一 boot+触发序列）。
# 用法（会话根）：
#   采集（改造前跑一次，stdout 重定向存档）：
#     ./tools/Godot_v4.3-stable_win64_console.exe --headless --path repo \
#       -s tests/qa_r228_diagfreeze.gd -- capture \
#       > repo/tests/qa_r228_diagfreeze_before.txt
#   对拍（改造后跑；加载采集档逐行比对）：
#     ./tools/Godot_v4.3-stable_win64_console.exe --headless --path repo \
#       -s tests/qa_r228_diagfreeze.gd -- compare=tests/qa_r228_diagfreeze_before.txt
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
#   探针本体零 R229 新符号引用（trim_free_to / pool_valve_override 一概不出现）——
#   同一脚本可在改造前后双态运行（改造前的「触发步」= tier/mode 注入 + 驱动一帧物理，
#   即改造前可达的最接近等价序列；改造后补 -3 哨兵的完整触发在 test_r229_pool_valve 内）。
extends SceneTree

const CASES_PATH := "res://tests/qa_r228_diagfreeze_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ QA 探针：诊断行冻结格式对拍（R229 裁N 追加） ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self, _mode_from_args(), _before_path_from_args())
	if cases.fail_count() > 0:
		quit(1)
	else:
		quit(0)


func _mode_from_args() -> String:
	# 用户参数（-- 之后）：capture（默认）/ compare=<采集档路径>
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if s.begins_with("compare="):
			return "compare"
	return "capture"


func _before_path_from_args() -> String:
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if s.begins_with("compare="):
			return s.substr("compare=".length())
	return ""

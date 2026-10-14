# tests/qa_r227_bake_b.gd
# QA-R227 独立探针 B（QA 侧留档）：零烤制路径真链——override=0 强制不补开局 /
# PLAYING 帧无烤制（门开仍零烤——B 红线运行时证据）/ continue_endless 不挂补烤（F 口径）/
# restart_run 真链补烤 + 多次重开幂等 + 队列序独立复测。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/qa_r227_bake_b_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ QA-R227 探针 B：零烤制路径真链 / continue_endless 口径 ══════════")
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

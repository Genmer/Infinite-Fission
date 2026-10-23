# tests/qa_r293_fpscap.gd
# R293 刀C 独立验收：帧率帽解锁（设置行 fps_cap 四档读写/默认 60 不变/Engine.max_fps
# 接线面——mobile 门内应用、桌面/headless 零写承重墙）+ drawcallsN 真机判读键
#（1Hz 行尾新段 + 导出口径头 R293 段）。入口（照 tests/qa_r292_export_progress.gd
# 结构；-s 入口编译期先于 autoload 注册——零工程类名直引，用例体运行时 load）。
extends SceneTree

const CASES_PATH := "res://tests/qa_r293_fpscap_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ R293 刀C 独立验收 · 帧率帽解锁 + drawcallsN 真机判读键 ════════")
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

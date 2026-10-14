# R267 刀P4 面板关闭脏标记落盘验收入口（独立进程；双文件先例同 qa_r262_bless_tier）
extends SceneTree

const CASES := "res://tests/qa_r267_meta_dirty_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	var cases = load(CASES).new()
	var fails: int = int(cases.call("run_all", self))
	quit(1 if fails > 0 else 0)

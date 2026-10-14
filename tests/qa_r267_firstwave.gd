# R267 刀P5 首波摊帧验收入口（独立进程=电池卫生；-s 直跑入口编译期看不到 autoload，
# 用例体独立文件 qa_r262_bless_tier 双文件先例）
extends SceneTree

const CASES := "res://tests/qa_r267_firstwave_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	var cases = load(CASES).new()
	var fails: int = int(cases.call("run_all", self))
	quit(1 if fails > 0 else 0)

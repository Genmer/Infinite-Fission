# R267 ②冷位图出发组合探针入口（独立进程=static 图集冷；模拟真机快速出发）
extends SceneTree

const CASES := "res://tests/probe_r267_coldstart_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	var cases = load(CASES).new()
	var fails: int = int(cases.call("run_all", self))
	quit(1 if fails > 0 else 0)

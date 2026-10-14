# R267 ①出发链/选卡链分段微基准入口（探针，只测不改）
# headless 量 CPU 同步段桌面当量；真机渲染/音频/IO 差异以代码锚+资产尺寸另行披露
extends SceneTree

const CASES := "res://tests/probe_r267_startchain_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	var cases = load(CASES).new()
	var fails: int = int(cases.call("run_all", self))
	quit(1 if fails > 0 else 0)

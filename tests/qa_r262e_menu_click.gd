# R262e ②点击卡顿微基准入口：四段同步成本量化（选关面板/祝福首开/start_run/选卡窗）
# headless 量 CPU 同步段（真机渲染轴另算——渲ms 已由 diag 行覆盖）
extends SceneTree

const CASES := "res://tests/qa_r262e_menu_click_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	var cases = load(CASES).new()
	var fails: int = int(cases.call("run_all", self))
	quit(1 if fails > 0 else 0)

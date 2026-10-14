# tests/qa_r257_probe_journey.gd — R257 探针入口（只读产品代码；真实按钮路径+全程时间线）
# 目的：复现「困难-第三关-出发-回到主页」全程感知时间线——出发信号→面板→确认→
# PLAYING→首敌→首伤→死亡→结算屏行为（自动重开档位读数）——钉死「瞬死感知为未进游戏」
# 假说与面板不可见假说的桌面基线。
# 纪律：-s 入口零工程类直引，逻辑全在 cases 体运行时加载。
extends SceneTree

const CASES_PATH := "res://tests/qa_r257_probe_journey_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	var body: GDScript = load(CASES_PATH)
	if body == null or not body.can_instantiate():
		print("PROBE FAIL | 用例体加载失败：%s" % CASES_PATH)
		quit(1)
		return
	var cases: Object = body.new()
	await cases.run(self)
	quit(0)

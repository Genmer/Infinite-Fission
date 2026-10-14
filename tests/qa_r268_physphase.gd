# tests/qa_r268_physphase.gd — R268 物理相四性能刀验收口（P1 升格臂绕帽 / P2 记账洞三表 /
# P3 拖尾半频+减长 / P4 预热深载门）。
# 双文件结构（-s 直跑入口编译期看不到 autoload，用例体运行时 load——tests/qa_r267_crystal_blade.gd 先例）。
extends SceneTree

const CASES_PATH := "res://tests/qa_r268_physphase_cases.gd"


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
	var fails: int = int(cases.call("fail_count"))
	quit(1 if fails > 0 else 0)

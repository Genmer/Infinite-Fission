# tests/qa_r268_transparent.gd — R268：透明基准校准 + 匕首感修复验收口
# （V1 几何/残影降档门/D 白缘断言 + V2 迁移后钉值抽检/虚影锚锁定/缓存零重建）。
# 双文件结构（-s 直跑入口编译期看不到 autoload，用例体独立文件——qa_r267_crystal_blade.gd 先例）。
extends SceneTree

const CASES_PATH := "res://tests/qa_r268_transparent_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	var body: GDScript = load(CASES_PATH)
	if body == null or not body.can_instantiate():
		print("PROBE FAIL | R268：用例体加载失败：%s" % CASES_PATH)
		quit(1)
		return
	var cases: Object = body.new()
	await cases.run(self)
	var fails: int = int(cases.call("fail_count"))
	quit(1 if fails > 0 else 0)

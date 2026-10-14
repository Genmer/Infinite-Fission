# tests/qa_r267_crystal_blade.gd — R267 视觉刀验收口（水晶质感生成器 + 六刃接入 + 旋风刀棕修）
# 双文件结构（-s 直跑入口编译期看不到 autoload，用例体独立文件——tests/qa_r262_bless_tier.gd 先例）。
extends SceneTree

const CASES_PATH := "res://tests/qa_r267_crystal_blade_cases.gd"


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

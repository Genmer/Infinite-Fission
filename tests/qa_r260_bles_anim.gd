# tests/qa_r260_bles_anim.gd — R260 Q 弹动画掉帧批验收口
# 泵挂起链 + 祝福行缓存 + 档位色刷新（headless 内存态测试档）
extends SceneTree

const CASES_PATH := "res://tests/qa_r260_bles_anim_cases.gd"


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

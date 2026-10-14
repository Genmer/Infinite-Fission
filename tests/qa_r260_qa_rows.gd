# tests/qa_r260_qa_rows.gd — R260 QA 专项深挖②：祝福行缓存边角（headless 内存态）
# 覆盖：池序确定性 / 同池同档零重建 / 同池不同序=重建 / 池变（缩/扩）重建+旧行
# 释放+ButtonGroup 无残留 / 档变重建+行按下色随档 / 复用路径选中态重置与预选重施加。
# 注：收口一律用 close()（零信号零 Meta 写），避免污染本地存档记忆键。
extends SceneTree

const CASES_PATH := "res://tests/qa_r260_qa_rows_cases.gd"


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

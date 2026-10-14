# tests/qa_r260_qa_pump.gd — R260 QA 专项深挖①：泵挂起/恢复完备性（headless 内存态）
# 覆盖：六类大厅面板开合扫全 / _process 实泵动态门（CardDesc remaining+图鉴页缓存
# 真消化）/ 绕过置位的关闭路径（_on_map_pick/_on_daily_start——缺陷探针，FAIL=缺陷）
# / settings 独立屏泵态取证 / 祝福链信号连接与防御收口恢复。
extends SceneTree

const CASES_PATH := "res://tests/qa_r260_qa_pump_cases.gd"


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

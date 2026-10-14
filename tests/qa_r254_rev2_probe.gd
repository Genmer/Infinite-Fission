# tests/qa_r254_rev2_probe.gd — QA 修轮复核探针入口（只读产品代码）
# 目的：R254 修轮五点独立验证——
#   P1 pending 二次出发换图采用链（current_map_id 真源一致性——疑点复核）
#   P2 泵在建页被同步路径抢建 → 页毕弃置半成品、缓存不被覆盖
#   P3 invalidate 中途（泵半页态）状态复位
#   P4 回菜单失效口 keep_reaction：反应页同实例保留、其余四页失效、队列重排 4 项
#   P5 每日出发 pending 闸（评审#4：吞掉+面板强制开）
# 纪律：-s 入口编译期 autoload 未注册——入口零工程类直引，逻辑全在 cases 体运行时加载。
extends SceneTree

const CASES_PATH := "res://tests/qa_r254_rev2_probe_cases.gd"


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

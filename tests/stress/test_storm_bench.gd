# tests/stress/test_storm_bench.gd
# R188 新增锚：风暴档基准入口（两段式——入口只做引导，用例体运行时 load 编译）。
# 覆盖（验收口径）：≥300 damage_resolved/帧风暴形态 + P95 < 8.3ms + 七池/表现件池对账
# + 节点/RSS 平台期（迷你 soak）。
extends SceneTree

const CASES_PATH := "res://tests/stress/storm_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R188 风暴档基准（≥300结算/帧形态） ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	await cases.run(self)
	quit(1 if cases.fail_count() > 0 else 0)

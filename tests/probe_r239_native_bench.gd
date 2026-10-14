# tests/probe_r239_native_bench.gd（R239 原生第一刀桌面 A/B 基准——query_circle_snap
# NATIVE off vs on 吞吐对）
# 跑法：cmd /c "E:/Code/Agent/Infinite-Fission/tools/Godot_v4.3-stable_win64_console.exe \
#         --headless --path E:/Code/Agent/Infinite-Fission/repo -s tests/probe_r239_native_bench.gd"
#       （超时给足 300s；全绝对路径）
# 目的（R239 判据：桌面 ≥3× 才算成立，真机预期更高）：同一网格快照同负载下
#   NATIVE off（GDScript 双循环）vs on（C++ FissionSpaceGrid）的 query_circle_snap
#   吞吐（K queries/s）与每查询 µs。负载口径=深载夹具（敌 120 驻场、查询半径覆盖
#   60Hz 点判定 6px 到 30Hz swept 带 ~22.5px）。
# 纪律：种子固定（确定性布局公式无 RNG 消费——SEED 入 meta 备查）；探针只读不改产品
#   代码（SpaceGrid.NATIVE_QUERIES static 开关属既有门面）；-s 入口零工程类名直引（全
#   鸭子），用例体运行时加载（probe_r234_databench 同构）；无 test_ 前缀不入电池；产物
#   JSON 写 docs/qa/probe_r239_native.json（性能结论只认留档 JSON）。
extends SceneTree

const CASES_PATH := "res://tests/probe_r239_native_bench_cases.gd"


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
	var fails: int = int(cases.call(&"fail_count"))
	if fails > 0:
		print("PROBE 汇总：%d 项硬门未过（见上 FAIL 行）" % fails)
		quit(1)
	else:
		print("PROBE 汇总：硬门全过（A/B 数字+JSON 已写 docs/qa/——桌面口径，真机系数须另测）")
		quit(0)

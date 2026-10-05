# tests/probe_r232_knife1e_falsify.gd（R232 刀1e 证伪测量探针入口）
# 跑法：cd E:/Code/Agent/Infinite-Fission && tools/Godot_v4.3-stable_win64_console.exe \
#         --headless --path E:/Code/Agent/Infinite-Fission/repo -s tests/probe_r232_knife1e_falsify.gd
# 目的（评审#2 修轮①）：刀1e「⑤聚合 typed 批处理」收口证伪配对——AGG_TYPED
#   false(字典原路径)/true(typed 平行数组) 各一轮、双序（dict→typed→typed→dict）
#   平衡顺序漂移，MICRO 同构合成结算（r225 合成 ctx 同值：base100+1add+2mult+1local
#   +crit0.05，批 48/96/192，窗外预构建，零打点），每臂读数=三批中位。
#   产物 JSON：docs/qa/probe_r232_knife1e_falsified_<日期>.json（modifier_stack.gd
#   AGG_TYPED 头注引用源）。证伪判读：typed 中位 ≥ dict 中位 → 证伪成立（shipped=false
#   维持）；typed 更快 → NOT_REPRODUCED 如实记录（开关复评依据）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时加载；无 test_
#   前缀不入电池。
extends SceneTree

const CASES_PATH := "res://tests/probe_r232_knife1e_falsify_cases.gd"


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

# tests/runner/test_r235_quickwins.gd
# R235 快项组合回归入口（godot --headless --path <工程> -s 本文件）
# 契约：4a 跳弹臂快路径（贴边带预检回落 _check_edge_bounce 本体+反射补 _sync_visual）
# + 4b 命中弹双查询合并（预检同口径 query_r 直填 _candidates，_check_collision(true) 跳重查）
# + 4c 关态插值快照直返（生产关 override==-1 直返；注入态保持原无条件语义）
# + 搭车①敌 _hit_area.collision_mask=2 / player.collision_layer=3 配对收窄。
# 核心口径：快慢孪生逐位等价（同参数弹一直驱 _tick_fast_player / 一直驱 tick()，含反弹帧
# 位置/速度/回收因逐帧全等——r231 T9 同款确定性锚）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/r235_quickwins_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R235（快项组合：跳弹快路径/双查询合并/关态短路/mask 收窄） 回归 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

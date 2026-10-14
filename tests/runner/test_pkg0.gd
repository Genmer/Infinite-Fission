# tests/runner/test_pkg0.gd
# 包 0 基座自测入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_pkg0.gd）
# 覆盖：池取出/归还/满池丢弃/清洁断言、SpaceGrid 插入查询（含边界桶）、EventBus 订阅退订/
# 风暴计数/订阅回落、DataValidator 坏数据剔除（负射速/δ>0.92/缺字段）、ModifierStack 聚合
# 断言（B_spec 公式例 336 / 同实例重入 150）、GameConfig/DebugStats/DataRegistry 骨架。
# 每断言 print PASS/FAIL + 汇总；失败以非零退出码结束（模式 A 口径，A2 §6.2）。
#
# 结构说明：-s 脚本模式下入口脚本的编译早于 autoload 全局名注册（EventBus/GameConfig/
# DebugStats 在 Main::start 后期才进 GDScript 全局表），故入口只做引导；用例体在
# pkg0_cases.gd，经运行时 load 编译——此时三个 autoload 已就绪（已实测验证），
# 用例可按工程常规以全局名访问 autoload。正常游戏路径（autoload 自身）不受此影响。
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg0_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 包 0 基座自测 ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats）
	await process_frame
	await process_frame
	# R188 档0：EventBus E-12 订阅纪律断言挂 dev 开关（默认关）——pkg0 内保证开启，
	# 用例体的非 Node 订阅拦截口径不受门控影响（入口脚本编译早于 autoload 注册，走运行时路径取节点）。
	var bus: Node = root.get_node("/root/EventBus")
	var gate_ok := _probe_end_frame_gate(bus)
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	cases.run(self)
	var fail_count: int = cases.fail_count()
	if not gate_ok:
		fail_count += 1
	if fail_count > 0:
		quit(1)
	else:
		quit(0)


# ── R188 档0 验收微探针：end_frame 门控两态计时 ─────────────────────
# 开启态（_check_node_subscribers 全信号×连接扫描）vs 关闭态（仅风暴计数清零），
# 1000 次均值（另 50 次预热）；关闭态须较开启态下降 ≥90%（dev 常量税剥离）。
func _probe_end_frame_gate(bus: Node) -> bool:
	var on_us := _time_end_frame(bus, true)
	var off_us := _time_end_frame(bus, false)
	var drop := 1.0 - (off_us / maxf(on_us, 0.000001))
	print("[pkg0] end_frame 门控微探针：开启态均值 %.3f µs / 关闭态均值 %.3f µs → 下降 %.1f%%（门槛 ≥90%%）：%s" % [
		on_us, off_us, drop * 100.0, "PASS" if drop >= 0.9 else "FAIL"])
	bus.dev_assertions = true   # 用例体（E-12 拦截断言）需要开启态，恢复
	return drop >= 0.9


func _time_end_frame(bus: Node, enabled: bool) -> float:
	bus.dev_assertions = enabled
	for i in 50:
		bus.end_frame()   # 预热（JIT/缓存）
	var t0 := Time.get_ticks_usec()
	for i in 1000:
		bus.end_frame()
	return float(Time.get_ticks_usec() - t0) / 1000.0

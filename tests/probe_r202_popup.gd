# tests/probe_r202_popup.gd
# R202 性能探针（非测试——勿用 test_ 前缀，防电池 glob 收录）：
# 侦查伤害跳字链路在「N 敌被激光持续命中 300 帧」下的实测开销。
# 口径：PopupPool(容量80/预热80) + PopupManager 独立组装（与 game_loop.gd:1334-1363
# 同参数），60fps 帧循环内同步复算激光节拍（tick_rate 跳/s，laser_beam._tick_settle
# 同式累加器），逐跳直呼 pm.on_damage_resolved（= EventBus.damage_resolved 的跳字
# 消费端成本；DamageResult 逐跳新建，与 DamagePipeline.resolve 每跳一结果同口径）。
# 采集：池运行期实例化数 / 新起跳字数（acquire）/ 峰值同屏 / 每帧消费端耗时 /
# 每帧 PopupManager.tick 耗时 / 满池丢弃数。
# 工程约束：-s 主脚本编译早于 autoload 注册——PopupPool/PopupManager 经运行期
# load() 取脚本（test_fx_quality.gd 同式），顶层禁直引其 class_name；
# GameConst/DamageResult 纯常量类无 autoload 依赖，可直引。
# 跑法：godot --headless --path repo -s tests/probe_r202_popup.gd
extends SceneTree

const FRAMES := 300
const FPS := 60.0
const N_ENEMIES := [8, 20, 32]          # 三档敌群规模
const SETTLE_HZ := [8.0, 16.0]          # 8 = 激光默认 tick_rate；16 = 射速强化后
const POOL_CAP := 80                    # balance_tables.tres pool_prewarm.popup

var _total_calls: int = 0
var _settle_us: int = 0
var _tick_us: int = 0
var _frames_with_settle: int = 0


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ R202 跳字链路探针（N 敌 × 激光持续命中 %d 帧） ══════════" % FRAMES)
	await process_frame
	await process_frame                                   # autoload 就绪后再取脚本
	var meta: Node = get_root().get_node_or_null("/root/Meta")
	var q_env := int(meta.call(&"settings", "fx_quality")) if meta != null else -1
	var dmg_on := bool(meta.call(&"settings", "damage_numbers_on")) if meta != null else false
	print("ENV| fx_quality=%d damage_numbers_on=%s（Meta 运行期读值）" % [q_env, str(dmg_on)])
	var pool_script: GDScript = load("res://scripts/core/pools/popup_pool.gd")
	var pm_script: GDScript = load("res://scripts/ui/popup_manager.gd")
	# 先按出厂高档（2）实测——Set/restore 防污染用户档（set_setting 写即存）
	if meta != null and q_env != 2:
		meta.call(&"set_setting", "fx_quality", 2)
	for hz in SETTLE_HZ:
		for n in N_ENEMIES:
			_scenario(pool_script, pm_script, n, hz, 2)
	if meta != null and q_env != 2:
		meta.call(&"set_setting", "fx_quality", q_env)
		# 环境原档（如 0=低）也实测一组，供档位对照
		for n in N_ENEMIES:
			_scenario(pool_script, pm_script, n, 8.0, q_env)
	print("────────────────────────────────────────")
	quit(0)


func _scenario(p_pool_script: GDScript, p_pm_script: GDScript, p_n: int, p_hz: float,
		p_quality: int) -> void:
	var pool: Node = p_pool_script.new()
	pool.name = "ProbePopupPool"
	get_root().add_child(pool)
	pool.call(&"setup", &"popup", load("res://scenes/ui/damage_popup.tscn"), POOL_CAP)
	pool.call(&"prewarm", POOL_CAP)
	var pm: Node = p_pm_script.new()
	pm.name = "ProbePopupManager"
	get_root().add_child(pm)
	pm.call(&"setup", pool)

	var delta := 1.0 / FPS
	var interval := 1.0 / p_hz
	var acc := 0.0
	_total_calls = 0
	_settle_us = 0
	_tick_us = 0
	_frames_with_settle = 0
	var peak_active := 0
	var hits0 := int(pool.call(&"stats")["hits"])
	var inst0 := int(pool.call(&"stats")["runtime_instantiates"])
	var tick_no := 0
	# -s 主脚本编译早于 autoload 注册：GameConfig 经场景树运行期寻址（非标识符直引）
	var gc := get_root().get_node_or_null("/root/GameConfig")

	for frame in range(FRAMES):
		if gc != null:
			gc.call(&"advance_frame")             # frame_stamp 推进（manager 帧闸判据）
		acc += delta
		var due := acc >= interval
		while acc >= interval:
			acc -= interval
		if due:
			var t0 := Time.get_ticks_usec()
			for e in range(p_n):
				var r := DamageResult.new()
				r.final_value = 10.0 + (e % 5)
				r.popup_style = GameConst.PopupStyle.CRIT if (tick_no + e) % 4 == 0 \
					else GameConst.PopupStyle.NORMAL
				r.target_uid = 1000 + e
				r.element = GameConst.Element.KIN
				r.pos = Vector2(400.0 + (e % 8) * 60.0, 300.0 + (e / 8) * 60.0)
				r.frame_stamp = int(gc.get(&"frame_stamp")) if gc != null else frame
				pm.call(&"on_damage_resolved", r)
				_total_calls += 1
			tick_no += 1
			_settle_us += Time.get_ticks_usec() - t0
			_frames_with_settle += 1
		var t1 := Time.get_ticks_usec()
		pm.call(&"tick", delta)
		_tick_us += Time.get_ticks_usec() - t1
		peak_active = maxi(peak_active, int(pm.get(&"active_popups")))

	var st: Dictionary = pool.call(&"stats")
	var new_pops := int(st["hits"]) - hits0                      # 新起跳字数（池取出次数）
	var runtime_inst := int(st["runtime_instantiates"]) - inst0  # 运行期 instantiate（应为 0）
	var drops := int(pm.call(&"dropped_count"))
	var merge_calls := _total_calls - new_pops - drops
	print("PROBE| q=%d n=%2d hz=%2.0f | damage_resolved→跳字端 %d 次(%.1fµs/次) | 新起跳字 %d | 合并 %d | 丢弃 %d | 峰值同屏 %d | 池子节点 %d | 运行期实例化 %d | 消费端 %.1f µs/结算帧(均) | tick %.1f µs/帧(均)" % [
		p_quality, p_n, p_hz, _total_calls, float(_settle_us) / maxf(float(_total_calls), 1.0),
		new_pops, merge_calls, drops,
		peak_active, pool.get_child_count(), runtime_inst,
		float(_settle_us) / maxf(float(_frames_with_settle), 1.0),
		float(_tick_us) / float(FRAMES),
	])
	pm.call(&"clear_all")
	pool.free()
	pm.free()

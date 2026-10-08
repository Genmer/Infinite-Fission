# tests/render_load_probe_cases.gd
# 渲染侧负载侦查用例体（探索B）：headless 直测各渲染同步热点的 CPU 侧成本。
# 口径：手动驱动 tick/_process（1/60s 步长），只测脚本侧渲染同步（Line2D 写点/
# Sprite transform 写/modulate 写/queue_redraw 类），不含 GPU 提交（headless 无渲染）。
# 节点泄漏说明：探针节点不显式释放（quit() 收树），测量循环不 await、与引擎帧不交错。
extends RefCounted

const DT := 1.0 / 60.0
const N_ENEMIES := 100
const N_BEAMS := 8
const FRAMES := 1200                      # 20s @ 60Hz

var tree: SceneTree


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	# ── A) 敌人 tick：无元素状态（仅 idle 呼吸/摇摆视觉）──
	Meta.set_setting("fx_quality", 2)
	var enemies: Array = _spawn_enemies(false)
	_burn_in(enemies)
	_clear_status(enemies)                 # 真基线：撤状态（挂件已建但全隐藏）
	var ms_a := _time_enemy_ticks(enemies)
	print("[probe] A) %d 敌 tick（无状态，fx_quality=2）：%.3f ms/帧 = %.1f µs/敌/帧 | 可见子件 %d" % [
		N_ENEMIES, ms_a, ms_a * 1000.0 / N_ENEMIES, _count_active_children(enemies)])

	# ── B) 敌人 tick：满元素状态（点燃+寒滞+感电+超导——后期常态）──
	var ms_b := _time_enemy_ticks(enemies, true)
	print("[probe] B) %d 敌 tick（燃+寒+感电+超导，fx_quality=2）：%.3f ms/帧 = %.1f µs/敌/帧 | 可见子件 %d" % [
		N_ENEMIES, ms_b, ms_b * 1000.0 / N_ENEMIES, _count_active_children(enemies)])

	# ── C) 同 B 但 fx_quality=0（低档：火苗 0/落雷关）──
	Meta.set_setting("fx_quality", 0)
	var ms_c := _time_enemy_ticks(enemies, true)
	print("[probe] C) %d 敌 tick（同 B，fx_quality=0）：%.3f ms/帧 = %.1f µs/敌/帧" % [
		N_ENEMIES, ms_c, ms_c * 1000.0 / N_ENEMIES])

	# ── D) 激光束 tick（渲染同步：双 Line2D clear+add_point ×2 + 呼吸束宽）──
	var beams: Array = _spawn_beams(N_BEAMS)
	var ms_d := _time_beam_ticks(beams)
	print("[probe] D) %d 束 LaserBeam.tick（无目标直射，_sync_line 全量）：%.3f ms/帧 = %.1f µs/束/帧" % [
		N_BEAMS, ms_d, ms_d * 1000.0 / N_BEAMS])

	# ── D2) 原始 Line2D 基元对照（无脚本逻辑，纯写点+写宽 ×16 条）──
	var ms_d2 := _time_raw_lines(N_BEAMS * 2)
	print("[probe] D2) %d 条裸 Line2D（clear+2点+写宽/帧）：%.3f ms/帧 = %.1f µs/条/帧" % [
		N_BEAMS * 2, ms_d2, ms_d2 * 1000.0 / (N_BEAMS * 2)])

	# ── E) 元素特效层 ElementalFxLayer.tick（池件饱和态：闪电流+迸裂+DOT+爆炸）──
	var fx := ElementalFxLayer.new()
	tree.get_root().add_child(fx)
	for i in range(8):
		fx._on_chain_lightning(Vector2(100, 100), Vector2(500, 900))
	for i in range(20):
		fx._on_beam_impact(Vector2(200 + i * 20, 400), Vector2.RIGHT)
	for i in range(24):
		fx._on_dot_fired(Vector2(200 + i * 20, 700))
	for i in range(6):
		fx._on_kill_blast(Vector2(360, 640), 90.0)
	var t0 := Time.get_ticks_usec()
	for i in range(FRAMES):
		fx.tick(DT)
	var ms_e := float(Time.get_ticks_usec() - t0) / 1000.0 / FRAMES
	print("[probe] E) ElementalFxLayer.tick（池饱和：8闪电+20迸裂+24火星+6爆）：%.3f ms/帧" % ms_e)

	# ── F) ConfettiBurst._process（90 枚彩纸 + 每帧 queue_redraw）──
	var conf := ConfettiBurst.new()
	tree.get_root().add_child(conf)
	conf.set_process(false)                # 引擎帧不驱动（手动独占计时窗）
	conf._celebrate(Vector2(360, 640))
	var t1 := Time.get_ticks_usec()
	for i in range(66):                     # 1.1s 全程
		conf._process(DT)
	var ms_f := float(Time.get_ticks_usec() - t1) / 1000.0 / 66.0
	print("[probe] F) ConfettiBurst._process（90 枚）：%.3f ms/帧（Boss 死亡 1.1s 窗口）" % ms_f)

	# ── G) CameraShake 震屏（trauma 满档对照）──
	var shake := CameraShake.new()
	shake.setup(8.0, 1.5, 0.4)
	shake.add(1.0)
	var t2 := Time.get_ticks_usec()
	for i in range(FRAMES):
		shake.tick(DT)
		if shake.trauma <= 0.0:
			shake.add(1.0)
		var v := shake.offset_and_rotation()
		if v == Vector3.INF:
			break
	var ms_g := float(Time.get_ticks_usec() - t2) / 1000.0 / FRAMES
	print("[probe] G) CameraShake.tick+offset（trauma 恒满）：%.3f ms/帧" % ms_g)
	print("[probe] 完成。")


func _spawn_enemies(p_with_status: bool) -> Array:
	var data: EnemyData = load("res://resources/enemies/E1_grunt.tres")
	var host := Node2D.new()
	host.name = "ProbeEnemies"
	tree.get_root().add_child(host)
	var out: Array = []
	for i in range(N_ENEMIES):
		var e := Enemy.new()
		e.position = Vector2(40.0 + (i % 10) * 68.0, 40.0 + (i / 10) * 118.0)
		host.add_child(e)
		e.spawn(data, 5, 0)
		out.append(e)
	return out


func _burn_in(p_enemies: Array) -> void:
	# 预热：让惰性挂件（火苗/冰渣/电弧/落雷/贴图）先建出来 + JIT 热，不计时
	for i in range(30):
		_tick_all(p_enemies, true)
	_tick_all(p_enemies, false)


func _tick_all(p_enemies: Array, p_status: bool) -> void:
	if p_status:
		for e in p_enemies:
			if e.elemental == null:
				e.elemental = ElementalState.new()
			e.elemental.burn_timer = 5.0
			e.elemental.chill_timer = 5.0
			e.elemental.freeze_timer = 0.0
			e.elemental.gauges[GameConst.Element.LTG] = 80.0
			e.elemental.superconduct_active = true
	for e in p_enemies:
		e.tick(DT)


func _clear_status(p_enemies: Array) -> void:
	# 撤状态：计时器清零（挂件隐藏走 _tick_status_fx 的 not burning 分支）
	for e in p_enemies:
		if e.elemental != null:
			e.elemental.burn_timer = 0.0
			e.elemental.chill_timer = 0.0
			e.elemental.freeze_timer = 0.0
			e.elemental.gauges[GameConst.Element.LTG] = 0.0
			e.elemental.superconduct_active = false


func _time_enemy_ticks(p_enemies: Array, p_status: bool = false) -> float:
	var t0 := Time.get_ticks_usec()
	for i in range(FRAMES):
		_tick_all(p_enemies, p_status)
	return float(Time.get_ticks_usec() - t0) / 1000.0 / FRAMES


func _count_active_children(p_enemies: Array) -> int:
	var n := 0
	for e in p_enemies:
		for c in e.get_children():
			if c is CanvasItem and (c as CanvasItem).visible:
				n += 1
	return n


func _spawn_beams(p_count: int) -> Array:
	var host := Node2D.new()
	host.name = "ProbeBeams"
	tree.get_root().add_child(host)
	var out: Array = []
	for i in range(p_count):
		var b := LaserBeam.new()
		host.add_child(b)
		b.spawn({
			"position": Vector2(360.0, 900.0),
			"dir": Vector2.from_angle(TAU * float(i) / float(p_count) - PI * 0.5),
			"depth": 0,
			"tick_atk": 6.0,
			"tick_rate": 8.0,
			"beam_length": 560.0,
			"beam_width": 14.0,
		})
		out.append(b)
	return out


func _time_beam_ticks(p_beams: Array) -> float:
	var t0 := Time.get_ticks_usec()
	for i in range(FRAMES):
		for b in p_beams:
			b.tick(DT)
	return float(Time.get_ticks_usec() - t0) / 1000.0 / FRAMES


func _time_raw_lines(p_count: int) -> float:
	# 裸 Line2D 基元：每帧 clear_points + add_point ×2 + 写 width（_sync_line 同款写序列）
	var host := Node2D.new()
	host.name = "ProbeRawLines"
	tree.get_root().add_child(host)
	var lines: Array = []
	for i in range(p_count):
		var ln := Line2D.new()
		host.add_child(ln)
		ln.add_point(Vector2.ZERO)
		ln.add_point(Vector2(0.0, -560.0))
		lines.append(ln)
	var t0 := Time.get_ticks_usec()
	for i in range(FRAMES):
		for ln in lines:
			ln.clear_points()
			ln.add_point(Vector2.ZERO)
			ln.add_point(Vector2(0.0, -560.0 + sin(float(i) * 0.1) * 4.0))
			ln.width = 14.0 * (1.0 + 0.07 * sin(float(i) * 0.43))
	return float(Time.get_ticks_usec() - t0) / 1000.0 / FRAMES

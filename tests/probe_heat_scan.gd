# tests/probe_heat_scan.gd —— 逻辑热路径侦查探针（只读基准，不改任何游戏文件）
# 用法：godot --headless --path repo -s tests/probe_heat_scan.gd
# 产出：① Meta.settings 微基准 ② Area2D.get_overlapping_areas 微基准 ③ 数组 duplicate
# ④ ElementalState.tick 单件微基准 ⑤ 真敌 200 只 × 300 帧 enemy.tick 实测
# ⑥ ElementalSystem.tick+detect_reactions 200 宿主实测。
extends SceneTree

const WARM := 50
const N_ENEMIES := 200
const N_FRAMES := 300
const DT := 1.0 / 60.0


func _initialize() -> void:
	await process_frame
	await process_frame
	print("══════════ 热路径侦查探针（headless 基准）══════════")
	_bench_meta_settings()
	_bench_overlap_areas()
	_bench_array_duplicate()
	_bench_elemental_state()
	await _bench_enemy_tick()
	print("══════════ 探针结束 ══════════")
	quit(0)


func _bench_meta_settings() -> void:
	var meta: Node = root.get_node("/root/Meta")
	for i in WARM:
		meta.call(&"settings", "fx_quality")
	var t0 := Time.get_ticks_usec()
	var sink := 0
	for i in 20000:
		sink += int(meta.call(&"settings", "fx_quality"))
	var us := float(Time.get_ticks_usec() - t0) / 20000.0
	print("[A] Meta.settings(\"fx_quality\") ×20000：%.3f µs/次（enemy.gd 点燃/感电 fx 每帧每敌调用）" % us)


func _bench_overlap_areas() -> void:
	var area := Area2D.new()
	var cs := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = 14.0
	cs.shape = shape
	area.add_child(cs)
	root.add_child(area)
	for i in WARM:
		area.get_overlapping_areas()
	var t0 := Time.get_ticks_usec()
	var sink := 0
	for i in 20000:
		sink += area.get_overlapping_areas().size()
	var us := float(Time.get_ticks_usec() - t0) / 20000.0
	print("[B] Area2D.get_overlapping_areas() ×20000：%.3f µs/次（enemy.gd:497 每敌每 tick 无条件调用）" % us)
	area.queue_free()


func _bench_array_duplicate() -> void:
	var arr: Array = []
	arr.resize(200)
	for i in WARM:
		arr.duplicate()
	var t0 := Time.get_ticks_usec()
	for i in 20000:
		arr.duplicate()
	var us := float(Time.get_ticks_usec() - t0) / 20000.0
	print("[C] Array(200).duplicate() ×20000：%.3f µs/次（elemental_system.gd:187/211 _hosts.duplicate 同族参照）" % us)


func _bench_elemental_state() -> void:
	var state_cls: GDScript = load("res://scripts/combat/elemental/elemental_state.gd")
	var lambdas: Array[float] = [0.35, 0.30, 0.40, 0.35, 0.50, 0.25, 0.30]
	var st = state_cls.new()
	for i in WARM:
		st.tick(DT, lambdas)
	var t0 := Time.get_ticks_usec()
	for i in 20000:
		st.tick(DT, lambdas)
	var us := float(Time.get_ticks_usec() - t0) / 20000.0
	print("[D] ElementalState.tick（空 reaction_cd）×20000：%.3f µs/次（含 :97 _expired=[] 每调用分配）" % us)


func _bench_enemy_tick() -> void:
	# 入口脚本编译早于 autoload 全局名注册——真件类运行时 load（pkg0 入口同模式）
	var registry_cls: GDScript = load("res://scripts/core/data/data_registry.gd")
	var enemy_cls: GDScript = load("res://scripts/entities/enemy/enemy.gd")
	var system_cls: GDScript = load("res://scripts/combat/elemental/elemental_system.gd")
	var registry = registry_cls.new()
	registry.load_all("res://data/manifest.cfg")
	var data = registry.get_enemy(&"E1_grunt")
	if data == null:
		print("[E] E1_grunt 数据缺失——敌 tick 实测跳过")
		return
	# 玩家占位（组缓存命中——模拟真局 _player() 缓存路径）
	var player := Node2D.new()
	player.add_to_group(&"player")
	root.add_child(player)
	var enemies: Array = []
	for i in N_ENEMIES:
		var e = enemy_cls.new()
		root.add_child(e)
		e.spawn(data, 5, 0)
		enemies.append(e)
	# 预热
	for f in 10:
		for e in enemies:
			e.tick(DT)
	var t0 := Time.get_ticks_usec()
	for f in N_FRAMES:
		for e in enemies:
			e.tick(DT)
	var total_us := Time.get_ticks_usec() - t0
	var per_frame_ms := float(total_us) / 1000.0 / float(N_FRAMES)
	var per_enemy_us := float(total_us) / float(N_FRAMES) / float(N_ENEMIES)
	print("[E] Enemy.tick ×%d 敌 ×%d 帧：合计 %.1f ms｜%.3f ms/帧（200 敌）｜%.1f µs/敌/tick" % [
		N_ENEMIES, N_FRAMES, float(total_us) / 1000.0, per_frame_ms, per_enemy_us])
	# 元素系统（真实 register_host 链路）
	var sys = system_cls.new()
	root.add_child(sys)
	for e in enemies:
		sys.register_host(e)
	for f in 10:
		sys.tick(DT)
		sys.detect_reactions()
	t0 = Time.get_ticks_usec()
	for f in N_FRAMES:
		sys.tick(DT)
		sys.detect_reactions()
	total_us = Time.get_ticks_usec() - t0
	print("[F] ElementalSystem.tick+detect_reactions ×%d 宿主 ×%d 帧：%.3f ms/帧（含 _hosts.duplicate ×2/帧）" % [
		N_ENEMIES, N_FRAMES, float(total_us) / 1000.0 / float(N_FRAMES)])
	for e in enemies:
		e.queue_free()
	sys.queue_free()
	player.queue_free()
	await _bench_enemy_tick_split(data)


func _bench_enemy_tick_split(p_data) -> void:
	# 热点归因：① 全量 tick 对照 ② _tick_visual 置空 ③ 再剥离接触伤害 overlap 查询
	var enemy_cls: GDScript = load("res://scripts/entities/enemy/enemy.gd")
	var sub_visual := GDScript.new()
	sub_visual.source_code = "extends \"res://scripts/entities/enemy/enemy.gd\"\n\nfunc _tick_visual(_p_game_delta: float) -> void:\n\tpass\n"
	sub_visual.reload()
	var player := Node2D.new()
	player.add_to_group(&"player")
	root.add_child(player)
	var enemies: Array = []
	for i in N_ENEMIES:
		var e = sub_visual.new()
		root.add_child(e)
		e.spawn(p_data, 5, 0)
		enemies.append(e)
	for f in 10:
		for e in enemies:
			e.tick(DT)
	var t0 := Time.get_ticks_usec()
	for f in N_FRAMES:
		for e in enemies:
			e.tick(DT)
	var no_visual_us := float(Time.get_ticks_usec() - t0)
	print("[G] 敌 tick 剥离 _tick_visual ×%d×%d：%.3f ms/帧｜%.1f µs/敌/tick（对照 [E] 全量）" % [
		N_ENEMIES, N_FRAMES, no_visual_us / 1000.0 / float(N_FRAMES),
		no_visual_us / float(N_FRAMES) / float(N_ENEMIES)])
	for e in enemies:
		e.set(&"_hit_area", null)   # 探针侧实例改动：跳过 tick 内 get_overlapping_areas 循环
	for f in 10:
		for e in enemies:
			e.tick(DT)
	t0 = Time.get_ticks_usec()
	for f in N_FRAMES:
		for e in enemies:
			e.tick(DT)
	var no_overlap_us := float(Time.get_ticks_usec() - t0)
	print("[H] 再剥离接触 overlap 查询 ×%d×%d：%.3f ms/帧｜%.1f µs/敌/tick" % [
		N_ENEMIES, N_FRAMES, no_overlap_us / 1000.0 / float(N_FRAMES),
		no_overlap_us / float(N_FRAMES) / float(N_ENEMIES)])
	for e in enemies:
		e.queue_free()
	player.queue_free()

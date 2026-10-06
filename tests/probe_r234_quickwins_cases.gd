# tests/probe_r234_quickwins_cases.gd（R234 快项探针用例体——入口运行时加载）
# 复刻口径（r224 夹具同源，差异披露）：
# · 构筑/敌群/压血/风筝/封顶 xp_need 全部同 r224（见 probe_r224_deepload_cases.gd 头注）；
# · 差异①：A/B/C/A2 臂改引擎自然步进（await physics_frame），kite/topup 在 physics_frame
#   回调执行（下一步生效——与 r224「驱动前写位」差一步，负载形态等价）；
# · 差异②：settle_budget_override=-3（模拟真机 tier2，60Hz 档帽 96/派发帽 48——本探针
#   headless sim30 恒 false，60Hz 口径=R234 回退目标档）；
# · 差异③：r224 三情景改本探针四引擎臂+一同步臂（测量目的不同——物理服务器可见性）。
# · TIME_PHYSICS_PROCESS 语义（Godot 4.3 主循环）：每主循环迭代若含物理步，该值=本迭代
#   physics 处理耗时（秒；含 PhysicsServer2D step + 全部 _physics_process 回调）。
#   headless 全速 idle 下多数迭代 0 物理步（值保留上次）→ 每恰一次 physics_frame 信号采
#   一次=每物理步恰采一次。
# · 空域采样口径：physics_frame 回调时网格=上一步 ④ 重建快照、弹位=该步末（近似一步
#   错位，占比判读用）；半径 8≈W2 弹预检口径（_fast_radius）、64=网格保守半径、200=远空域。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GROVE_TABLE := "res://resources/maps/wave_table_grove.tres"
const DT60 := 1.0 / 60.0
const HOLD := 120
const WARMUP_FRAMES := 300
const ARM_FRAMES := 600
const TOPUP_PER_FRAME := 8
const PLAYER_HOME := Vector2(360.0, 900.0)
const ENEMY_HP_SCALE := 0.3
const SAMPLE_EVERY := 12
const OUT_JSON := "res://docs/qa/probe_r234_quickwins_2026-10-06.json"

var tree: SceneTree
var _gl: GameLoop = null
var _comp: Array[Dictionary] = []
var _cursor: int = 0
var _out: Dictionary = {}                 # JSON root


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261006)
	if not _boot():
		_teardown()
		return
	# 预热（引擎驱动——同步预热会漏物理稳态）
	await _arm_engine_inner("warmup", "warmup", "", WARMUP_FRAMES, false)
	await _arm_engine("A 基线（现状：121 Area2D 全默认互相监测）", "A", "")
	await _arm_engine("B 敌mask收窄（敌间 pair 全消，敌-玩家保留）", "B", "mask")
	await _arm_engine("C 监测全关（成本上限锚）", "C", "off")
	await _arm_engine("A2 复验（恢复默认——漂移对照）", "A2", "restore")
	await _arm_sync("D 同步臂（r224 口径：物理服务器不步进=纯帧序基线）", "D")
	_micro_bench()
	_write_json()
	_teardown()


# ── 引导（r224 复刻） ───────────────────────────────────────────────

func _boot() -> bool:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "ProbeR234Quickwins"
	tree.root.add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[probe] Boot 失败：%s" % str(_gl.boot_fatal))
		return false
	PerfGovernor.set_process(false)
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	DamagePipeline.settle_budget_override = -3      # 模拟真机 tier2（60Hz 档帽 96）
	_gl.current_map_id = &"world_grove"
	if not _gl.start_run():
		push_error("[probe] start_run 失败")
		return false
	_gl.player.set("xp_need", 1.0e12)
	_gl.player.set("max_hp", 1.0e12)
	_gl.player.set("hp", 1.0e12)
	_gl.player.unlocked_slots = 6
	_gl.player.global_position = PLAYER_HOME
	var gatling: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	if gatling == null:
		push_error("[probe] W2 装配失败")
		return false
	gatling.level = 5
	var pierce: TraitData = _gl.registry.get_trait(&"AFF_PIERCE")
	for i in range(3):
		gatling.attach_trait(pierce)
	var multi: TraitData = _gl.registry.get_trait(&"AFF_MULTI")
	for i in range(2):
		gatling.attach_trait(multi)
	var bounce: TraitData = _gl.registry.get_trait(&"MEC_BOUNCE")
	for i in range(3):
		gatling.attach_trait(bounce)
	var nova: TraitData = _gl.registry.get_trait(&"MEC_KILL_BLAST")
	for i in range(2):
		gatling.attach_trait(nova)
	var fractal: TraitData = _gl.registry.get_trait(&"MEC_FRACTAL")
	for i in range(2):
		gatling.attach_trait(fractal)
	_gl.stage_probe_enabled = true
	if not _load_composition():
		return false
	for i in range(HOLD):
		_spawn_one()
	print("boot：grove w16 ×0.3 压血 %d 敌 + W2 L5 五词条（r224 同构）；settle=-3 tier2 帽96@60Hz" % HOLD)
	return true


func _load_composition() -> bool:
	var tbl: Resource = load(GROVE_TABLE)
	if tbl == null or not ("entries" in tbl):
		return false
	var entry: Resource = null
	for e in tbl.get("entries"):
		if int(e.get("index")) == 16:
			entry = e
			break
	if entry == null:
		return false
	for c in entry.get("composition"):
		var src: EnemyData = _gl.registry.get_enemy(StringName(c.get("enemy_id")))
		if src == null:
			return false
		var data: EnemyData = src.duplicate()
		data.hp_base = data.hp_base * ENEMY_HP_SCALE
		var tags := int(c.get("tags", 0))
		for i in range(int(c.get("count", 1))):
			_comp.append({"data": data, "tags": tags})
	_comp.shuffle()
	return true


func _spawn_one() -> void:
	var c: Dictionary = _comp[_cursor % _comp.size()]
	_cursor += 1
	var e := (_gl.pools[&"enemy"] as EnemyPool).acquire() as Enemy
	if e == null:
		return
	e.bucket_host = (_gl.pools[&"enemy"] as EnemyPool).bucket_host
	e.spawn(c["data"], 16, int(c["tags"]))
	e.global_position = Vector2(randf() * 680.0 + 20.0, randf() * 1180.0 + 40.0)
	_gl.spawner.active.append(e)


func _topup() -> void:
	var want: int = mini(TOPUP_PER_FRAME, HOLD - _gl.spawner.active.size())
	for i in range(want):
		_spawn_one()


func _kite(p_frame: int) -> void:
	var ang := float(p_frame) * 0.35 / 60.0
	_gl.player.global_position = Vector2(360.0 + cos(ang) * 140.0,
		660.0 + sin(ang) * 200.0)


# ── Area2D 臂切换（帧间直写——physics_frame 回调内不在物理步中，安全） ──

func _apply_arm(p_mode: String) -> void:
	var player_area: Area2D = _gl.player as Area2D
	if p_mode == "mask":
		for e in _gl.spawner.active:
			var ha: Area2D = (e as Enemy).get("_hit_area") as Area2D
			if ha != null:
				ha.collision_mask = 2               # 敌只 pair layer 含 2 者
		player_area.collision_layer = 3              # 1|2：保留原 1 位 + 对敌 mask=2 可见
	elif p_mode == "off":
		for e in _gl.spawner.active:
			var ha: Area2D = (e as Enemy).get("_hit_area") as Area2D
			if ha != null:
				ha.monitoring = false
		player_area.monitoring = false
	elif p_mode == "restore":
		for e in _gl.spawner.active:
			var ha: Area2D = (e as Enemy).get("_hit_area") as Area2D
			if ha != null:
				ha.collision_mask = 1
				ha.monitoring = true
		player_area.collision_layer = 1
		player_area.monitoring = true


# ── 引擎驱动臂（await physics_frame） ───────────────────────────────

func _arm_engine(p_label: String, p_key: String, p_mode: String) -> void:
	await _arm_engine_inner(p_label, p_key, p_mode, ARM_FRAMES, true)


func _arm_engine_inner(p_label: String, p_key: String, p_mode: String,
		p_frames: int, p_record: bool) -> void:
	print("── %s ──" % p_label)
	if p_mode != "":
		_apply_arm(p_mode)
	var phys_ms: Array[float] = []
	var samples: Array[Dictionary] = []
	var i := 0
	while i < p_frames:
		await tree.physics_frame
		_kite(i)
		_topup()
		var t := float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
		phys_ms.append(t)
		if p_record and i % SAMPLE_EVERY == 0:
			samples.append(_sample_field())
		i += 1
	var s := phys_ms.duplicate()
	s.sort()
	var line := "%s：TIME_PHYSICS_PROCESS ms p50=%.3f p95=%.3f mean=%.3f（n=%d）" % [
		p_key, _pct(s, 0.50), _pct(s, 0.95), _mean(phys_ms), p_frames]
	if p_record:
		var empty_ratio := _sample_series(samples, "empty8_ratio")
		var far_ratio := _sample_series(samples, "empty200_ratio")
		var qlen := _sample_series(samples, "queue_len")
		var qs := qlen.duplicate()
		qs.sort()
		line += "｜弹 p50=%.0f 空域(8px)p50=%.0f%% 远空(200px)p50=%.0f%%｜派发队列 p50=%.0f p95=%.0f" % [
			_pct(_sorted_f(_sample_series(samples, "projs")), 0.50),
			_pct(_sorted_f(empty_ratio), 0.50) * 100.0,
			_pct(_sorted_f(far_ratio), 0.50) * 100.0,
			_pct(qs, 0.50), _pct(qs, 0.95)]
	_out[p_key] = {
		"time_physics_ms": {"p50": _pct(s, 0.50), "p95": _pct(s, 0.95), "mean": _mean(phys_ms)},
		"samples": samples,
	}
	print(line)


# ── 同步臂（r224 口径——物理服务器不步进） ──────────────────────────

func _arm_sync(p_label: String, p_key: String) -> void:
	print("── %s ──" % p_label)
	_apply_arm("restore")
	var totals: Array[float] = []
	var stage: Dictionary = {}
	var samples: Array[Dictionary] = []
	var i := 0
	while i < ARM_FRAMES:
		_kite(i)
		var t0 := Time.get_ticks_usec()
		_gl._physics_process(DT60)
		totals.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		_topup()
		for k in _gl.stage_probe_us:
			if not stage.has(k):
				stage[k] = [] as Array[float]
			(stage[k] as Array[float]).append(float(_gl.stage_probe_us[k]) / 1000.0)
		if i % SAMPLE_EVERY == 0:
			samples.append(_sample_field())
		i += 1
	var s := totals.duplicate()
	s.sort()
	var seg: Dictionary = {}
	var keys: Array = stage.keys()
	keys.sort()
	var seg_line := ""
	for k in keys:
		var arr: Array[float] = stage[k]
		var sa := arr.duplicate()
		sa.sort()
		seg[String(k)] = {"mean": _mean(arr), "p95": _pct(sa, 0.95)}
		seg_line += "%s=%.2f " % [String(k), _mean(arr)]
	_out[p_key] = {
		"wall_ms": {"p50": _pct(s, 0.50), "p95": _pct(s, 0.95), "mean": _mean(totals)},
		"segments": seg,
		"samples": samples,
	}
	print("D：整帧墙钟 ms p50=%.3f p95=%.3f mean=%.3f（n=%d）" % [_pct(s, 0.50), _pct(s, 0.95), _mean(totals), ARM_FRAMES])
	print("D：段均值 ms：%s" % seg_line)


# ── 场采样（弹-敌空域分布 + 派发队列） ─────────────────────────────

func _sample_field() -> Dictionary:
	var pool := _gl._projectile_pool
	var actives := pool.active_projectiles()
	var grid := _gl.enemy_grid
	var empty8 := 0
	var empty64 := 0
	var empty200 := 0
	var total := 0
	for p in actives:
		var pb := p as ProjectileBase
		if pb == null or not pb.is_inside_tree():
			continue
		var team := int(pb.team)
		if team != 0:
			continue                                  # 空域口径=玩家弹（批筛靶面）
		total += 1
		var pos: Vector2 = pb.global_position
		if grid.query_circle_snap(pos, 8.0).is_empty():
			empty8 += 1
		if grid.query_circle_snap(pos, 64.0).is_empty():
			empty64 += 1
		if grid.query_circle_snap(pos, 200.0).is_empty():
			empty200 += 1
	var queue_len := 0
	if _gl.pipeline != null:
		var q: Variant = _gl.pipeline.get("_resolved_queue")
		if q is Array:
			queue_len = (q as Array).size()
	var d := _gl.diag_counts()
	return {
		"projs": total,
		"empty8": empty8, "empty64": empty64, "empty200": empty200,
		"empty8_ratio": float(empty8) / maxf(float(total), 1.0),
		"empty64_ratio": float(empty64) / maxf(float(total), 1.0),
		"empty200_ratio": float(empty200) / maxf(float(total), 1.0),
		"queue_len": queue_len,
		"enemies": int(d[&"enemies"]),
		"settles_sec": int(d[&"settles"]),
		"pfast": int(d[&"pfast_live"]),
	}


func _sample_series(p_samples: Array[Dictionary], p_key: String) -> Array[float]:
	var out: Array[float] = []
	for s in p_samples:
		out.append(float(s[p_key]))
	return out


# ── 微基准：dispatch 顺延数组前移 + 过期扫描近似 ─────────────────────

func _micro_bench() -> void:
	print("── 微基准：dispatch 顺延前移（damage_pipeline.gd:326-328 主语句）──")
	var res: Dictionary = {}
	for L in [700, 2000, 4000]:
		var a: Array = []
		a.resize(L)
		for i in range(L):
			a[i] = RefCounted.new()
		var n := 48                                    # 60Hz 档派发帽
		var reps := 50
		var t0 := Time.get_ticks_usec()
		for r in range(reps):
			for i in range(n, L):
				a[i - n] = a[i]
			a.resize(L - n)
			a.resize(L)                                # 重填模拟下帧入队回长
			for i in range(n):
				a[L - n + i] = a[i % maxi(L - n, 1)]
		var move_us := float(Time.get_ticks_usec() - t0) / float(reps)
		res["shift_%d" % L] = move_us
		print("  L=%d 前移 %d 元素+resize：%.1fµs/次（每步一次——若队列稳态 %d 长，顺延移动≈%.2fms/步）" % [
			L, L - n, move_us, L, move_us / 1000.0])
	# 过期扫描近似（int 比较 while 循环）
	var stamps: Array[int] = []
	stamps.resize(2000)
	var t1 := Time.get_ticks_usec()
	var reps2 := 200
	for r in range(reps2):
		var cur := r
		var i := 0
		var drop_from := 0
		while drop_from < stamps.size() and absi(stamps[drop_from] - cur) > 15:
			drop_from += 1
	var scan_us := float(Time.get_ticks_usec() - t1) / float(reps2)
	res["stale_scan_2000"] = scan_us
	print("  过期扫描 while 2000 项 int 比较：%.1fµs/次" % scan_us)
	_out["micro_bench_us"] = res


# ── 留档/收尾 ──────────────────────────────────────────────────────

func _write_json() -> void:
	_out["meta"] = {
		"date": "2026-10-06", "package": "R234 快项挖掘探针（desktop headless）",
		"map": "world_grove w16（敌血 ×0.3 复本）", "hold": HOLD,
		"dt": DT60, "arm_frames": ARM_FRAMES, "warmup": WARMUP_FRAMES,
		"build": "W2_gatling L5 + PIERCE×3/MULTI×2/BOUNCE×3/NOVA×2/FRACTAL×2（r224 同构）",
		"governor": "frozen, mode=frame_priority, tier_override=2, settle=-3（60Hz 档帽96/派发48）",
		"seed": 20261006,
		"arm_semantics": {
			"A": "现状（121 Area2D 默认 layer=1/mask=1 互相监测）",
			"B": "敌 _hit_area.collision_mask=2 + 玩家 collision_layer=3（敌间 pair 消除）",
			"C": "敌+玩家 monitoring=false（监测成本上限锚）",
			"A2": "恢复默认复验（漂移对照）",
			"D": "同步手动驱动（物理服务器不步进=纯帧序）",
		},
		"note": "TIME_PHYSICS_PROCESS 含 PhysicsServer2D step + _physics_process 回调；"
			+ "空域采样=physics_frame 回调时（网格=上一步快照，弹位=该步末——一步错位近似）；"
			+ "绝对 ms 桌面≈真机 ×0.5-2（R224 口径）；Area2D 成本真机判读须乘该系数带。",
	}
	var f := FileAccess.open(OUT_JSON, FileAccess.WRITE)
	if f == null:
		push_warning("[probe] JSON 写入失败：%s" % OUT_JSON)
		return
	f.store_string(JSON.stringify(_out, "\t"))
	f.close()
	print("JSON 留档：%s" % OUT_JSON)


func _teardown() -> void:
	DamagePipeline.settle_budget_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.set_process(true)
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame


# ── 统计工具 ──────────────────────────────────────────────────────

func _sorted_f(p_arr: Array[float]) -> Array[float]:
	var s := p_arr.duplicate()
	s.sort()
	return s


func _pct(p_sorted: Array[float], p_pct: float) -> float:
	if p_sorted.is_empty():
		return 0.0
	var i := clampi(int(float(p_sorted.size()) * p_pct), 0, p_sorted.size() - 1)
	return p_sorted[i]


func _mean(p_arr: Array[float]) -> float:
	if p_arr.is_empty():
		return 0.0
	var s := 0.0
	for v in p_arr:
		s += v
	return s / float(p_arr.size())

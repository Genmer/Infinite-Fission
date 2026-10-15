# tests/qa_r285_gridhit_cases.gd（R285 弹侧根治批 QA 用例体——入口运行时加载）
# 覆盖（设计 §5 t1a-t1e / §3.2 p1-p4 / §5 t3a-t3e / §3.4 P0 键在账）：
# · T1 boost 开网格命中 sweep：收集-冲刷两段式语义（序守卫/同帧闭合/对拍/关态逐位/掷斧敌弹不受扰）；
# · T2 物面守门：弹场景零物理件 + 全树 Area2D 白名单 + CONTACT_RADIAL 旗语义锁（零产品断言面）；
# · T3 死亡链冲刷：快照计数制批量化 + inline 面不动 + 关态即时 + 当帧兜底排空 + 燎原连锁读数
#   漂移声明带（§3.1.5 声明④验收面）；
# · P0：命/结/死/回/ip 五桶键在账 + shortcircuit_ip_pass 短路机制（S8 同款注入）。
# 架构锚（定死）：boost 关（override 强关或 boost_mode 假）→ Area2D 现状路径逐位不变
#（pkg4 116/0 由此保住）；boost 开 → 网格命中新路径。RNG 契约变更声明（boost 开侧
# 命中时点帧级偏移允许/伤害数值与命中率统计不变）见 projectile_base._collect_hit_pairs
# 与 enemy._death_fanout 头注；本套件对拍口径=同 override 逐位 + 跨 override 统计带。
# 时序锚：SceneTree.physics_frame 在该帧 Node._physics_process 之前发出——「帧内步后
# 读数」必须连等两次（第二次恢复点=下一帧头，此刻上一帧已完整走完 ④冲刷/⑤/兜底）。
# 纪律：套件自清盘档（Meta._settings 快照还原 + _save 落盘）；静态注入口出厂态复位；
# 池件判存活用 is_instance_valid、勿二次 release；零工程类名直引由入口承担（本文件
# 运行时编译，类型名可用）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const PROJ_SCENE := "res://scenes/combat/projectiles/ballistic_projectile.tscn"
const HOMING_SCENE := "res://scenes/combat/projectiles/homing_projectile.tscn"
const ENEMY_SRC := "res://scripts/entities/enemy/enemy.gd"
const DT := 1.0 / 60.0
const PLAYER_HOME := Vector2(360.0, 980.0)
const HP_BIG := 1.0e9

var tree: SceneTree
var _gl: GameLoop = null
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _saved_settings: Dictionary = {}
# 指标订阅器（damage_resolved/enemy_killed 全局累计——用例间经 _reset_metrics 归零）
var _dmg_sum: float = 0.0
var _settle_n: int = 0
var _kill_n: int = 0
var _kill_order: Array[int] = []             # 击杀派发序（实例 id——FIFO 断言源）
var _metric_connected: bool = false
var _t3a_targets: Array[Enemy] = []          # t3a 物理帧回调的击杀目标（引擎步前击杀）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_saved_settings = Meta._settings.duplicate()      # 入口快照（收尾还原——磁盘不留测试痕，§0.5）
	_boot()
	PerfGovernor.set_process(false)
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = 3
	PerfGovernor.boost_override = -1
	Meta.set_setting("fx_quality", 2)           # r230 先例：钉高防跨套件 user:// 残留漂门
	_setup_battle()
	# ── 用例序：T2 场景面 → T1 语义 → T3 → P0 键 → T2 p3 二次 boot ──
	_t2_p1_scene_physface()
	_t2_p2_area_whitelist()
	_t1a_serial_guard()
	_t1cd_controlled_compare()
	_t1b_sameframe_closure()
	_t1e_axe_enemy_bullet()
	await _t1c2_ab_bench()
	await _t3a_flush_semantics()
	_t3b_inline_face()
	_t3c_off_immediate()
	_t3d_fallback_drain()
	_t3e_spread_burn()
	_p0_prof_buckets()
	await _t2_p3_contact_radial()
	await _cleanup()


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s（%s）" % [p_name, p_detail])
		print("  FAIL | %s（%s）" % [p_name, p_detail])


# ── boot / 夹具 ────────────────────────────────────────────────────

func _boot() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R285GridHit"
	tree.root.add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[r285] Boot 失败：%s" % str(_gl.boot_fatal))
		_fail += 1


func _setup_battle() -> void:
	# 受控战斗态（无 start_run——wave_director 恒 IDLE 零波次干扰，敌/弹全夹具注入）：
	# state 直置 PLAYING（qa_r269 a6 同款手法）；玩家钉桩（hp/xp 巨额——接触/升级不扰动）。
	_gl.state = GameConst.GameStatus.PLAYING
	_gl.wave_director.set("_hard_cap_left", 9999.0)
	_gl.player.set("xp_need", 1.0e12)
	_gl.player.set("max_hp", 1.0e12)
	_gl.player.set("hp", 1.0e12)
	_gl.player.unlocked_slots = 6
	_gl.player.global_position = PLAYER_HOME
	_connect_metrics()
	_reset_metrics()
	_field_reset()


func _connect_metrics() -> void:
	if _metric_connected:
		return
	_metric_connected = true
	EventBus.damage_resolved.connect(_on_damage_resolved)
	EventBus.enemy_killed.connect(_on_enemy_killed)


func _disconnect_metrics() -> void:
	if _metric_connected:
		EventBus.damage_resolved.disconnect(_on_damage_resolved)
		EventBus.enemy_killed.disconnect(_on_enemy_killed)
		_metric_connected = false


func _on_damage_resolved(p_result: DamageResult) -> void:
	_dmg_sum += float(p_result.final_value)
	_settle_n += 1


func _on_enemy_killed(p_enemy: Node2D) -> void:
	_kill_n += 1
	_kill_order.append(p_enemy.get_instance_id())


func _reset_metrics() -> void:
	_dmg_sum = 0.0
	_settle_n = 0
	_kill_n = 0
	_kill_order.clear()


func _spawn_enemy(p_pos: Vector2, p_hp: float, p_register_elemental := false) -> Enemy:
	# 夹具敌注入（deeprepro _spawn_one 同款：池 acquire + spawner.active 挂账）；
	# register_elemental=true 时手动 register_host（无 spawner.tick 路径的元素宿主补挂）。
	var e := (_gl.pools[&"enemy"] as EnemyPool).acquire() as Enemy
	if e == null:
		return null
	e.bucket_host = (_gl.pools[&"enemy"] as EnemyPool).bucket_host
	var data: EnemyData = _gl.registry.get_enemy(&"E1_grunt")
	e.spawn(data, 1, 0)
	e.hp = p_hp
	e.global_position = p_pos
	if p_register_elemental and _gl.elemental != null:
		_gl.elemental.register_host(e)
	_gl.spawner.active.append(e)
	return e


func _spawn_bullet(p_pos: Vector2, p_vel: Vector2, p_params: Dictionary = {},
		p_team: int = 0) -> ProjectileBase:
	# 夹具弹注入（deeprepro _inject_filler_bullet 同款四依赖；pierce/面板/形态键经 params）
	var pool: ProjectilePool = _gl.pools[&"projectile"] as ProjectilePool
	var pb: ProjectileBase = pool.acquire(p_team)
	if pb == null:
		return null
	pb.damage_pipeline = _gl.pipeline
	pb.enemy_grid = _gl.enemy_grid
	pb.pool = pool
	pb.elemental = _gl.elemental
	var params := p_params.duplicate()
	params["position"] = p_pos
	params["velocity"] = p_vel
	params["team"] = p_team
	if not params.has("lifetime"):
		params["lifetime"] = 6.0
	if not params.has("pierce"):
		params["pierce"] = 1
	if not params.has("hitbox_radius"):
		params["hitbox_radius"] = 6.0
	if not params.has("panel_snapshot"):
		params["panel_snapshot"] = {"base_atk": 100.0, "crit_rate": 0.0, "crit_mult": 2.0}
	pb.spawn(params)
	return pb


func _field_reset() -> void:
	# 臂间清场：弹/敌/碎片全归还（同帧同步块零并发击杀——逐帧排空防双释放；
	# 敌先 unregister_host 再 release，R253/R259 纪律）
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles().duplicate():
		(_gl.pools[&"projectile"] as ObjectPool).release(p)
	for p in (_gl.pools[&"homing"] as ProjectilePool).active_projectiles().duplicate():
		(_gl.pools[&"homing"] as ObjectPool).release(p)
	for e in _gl.spawner.active.duplicate():
		if is_instance_valid(e):
			_gl.elemental.unregister_host(e)
			(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_gl.spawner.active.clear()
	for s in _gl.active_shards.duplicate():
		(_gl.pools[&"xp"] as XPPool).release(s)
	_gl.active_shards.clear()
	_gl.player.set("hp", 1.0e12)
	_gl.player.global_position = PLAYER_HOME
	_reset_metrics()


func _set_gates(p_boost: int, p_grid: int, p_death: int) -> void:
	# R285 注入口三态快设（出厂态=-1 真值；套件收尾统一复位）
	PerfGovernor.boost_override = p_boost
	GameLoop.grid_hit_override = p_grid
	GameLoop.death_flush_override = p_death


func _drive(p_frames: int) -> void:
	for i in range(p_frames):
		_gl._physics_process(DT)


func _settles_total() -> int:
	return int((_gl.pipeline.call(&"stats") as Dictionary).get("settles", 0))


func _bucket_us(p_key: StringName) -> int:
	return int(DebugStats.diag_bucket_window_us(p_key))


func _clear_weapons() -> void:
	# 槽位全清（首发武器随 boot 已装槽——多 run 不叠装；queue_free 帧末消化）
	for i in range(_gl.player.weapon_slots.size()):
		var w = _gl.player.weapon_slots[i]
		if w != null and is_instance_valid(w):
			w.queue_free()
		_gl.player.weapon_slots[i] = null


# ── T2 p1：弹场景零物理件（运行期锁——场景 5 行裸 Node2D 的结构证伪键） ──

func _t2_p1_scene_physface() -> void:
	print("── t2.p1 弹场景零物理件（ballistic/homing 深扫） ──")
	for scene_path in [PROJ_SCENE, HOMING_SCENE]:
		var ps: PackedScene = load(scene_path)
		var node: Node = ps.instantiate()
		var phys := 0
		_count_physics(node, phys)
		_check("t2.p1 %s 子树 CollisionObject2D/CollisionShape2D==0（弹×弹不检测的结构性证伪键）" % scene_path.get_file(),
			phys == 0, "物理件=%d" % phys)
		node.free()


func _count_physics(p_node: Node, p_out: int) -> void:
	if p_node is CollisionObject2D or p_node is CollisionShape2D:
		p_out += 1
	for c in p_node.get_children():
		_count_physics(c, p_out)


# ── T2 p2/p4：满配 boot 全树 Area2D 白名单 + boost 两态逐位 ──────────

func _t2_p2_area_whitelist() -> void:
	print("── t2.p2/p4 全树 Area2D 白名单（敌 HitArea×N + 玩家本体）+ boost 两态逐位 ──")
	_set_gates(-1, -1, -1)                      # 关态真值
	for i in range(3):
		_spawn_enemy(Vector2(200.0 + 60.0 * i, 400.0), HP_BIG)
	var areas_off := _collect_areas()
	var ok_set := true
	var masks_ok := true
	var player_found := false
	for a in areas_off:
		if a == _gl.player:
			player_found = true
			continue
		var owner_enemy: Enemy = a.get_parent() as Enemy
		if owner_enemy == null or String(a.name) != "HitArea":
			ok_set = false
		elif a.collision_mask != 2:
			masks_ok = false
	_check("t2.p2 全树 Area2D ⊆ {敌 HitArea, 玩家本体}（白名单锁，敌×3 在场）",
		ok_set and areas_off.size() >= 4, "集合=%d 白名单内=%s" % [areas_off.size(), str(ok_set)])
	_check("t2.p2 玩家本体在场 ∧ collision_layer==3（R235 搭车① 现状锁）",
		player_found and _gl.player.collision_layer == 3,
		"found=%s layer=%d" % [str(player_found), _gl.player.collision_layer])
	_check("t2.p2 敌 HitArea collision_mask==2 全数（敌只与玩家配对）",
		masks_ok, "mask 漂移")
	# p4：boost 开态同一集合逐位（同节点、同 mask/layer——boost 不触物理面）
	PerfGovernor.boost_override = 1
	var areas_on := _collect_areas()
	PerfGovernor.boost_override = -1
	var same := areas_on.size() == areas_off.size()
	if same:
		for i in range(areas_on.size()):
			if areas_on[i] != areas_off[i] \
					or (areas_on[i] as Area2D).collision_mask != (areas_off[i] as Area2D).collision_mask \
					or (areas_on[i] as Area2D).collision_layer != (areas_off[i] as Area2D).collision_layer:
				same = false
				break
	_check("t2.p4 boost 开/关 Area2D 集合与 mask/layer 逐位（R269 保帧模式关态逐位同源）",
		same, "关=%d 开=%d" % [areas_off.size(), areas_on.size()])
	_field_reset()


func _collect_areas() -> Array[Area2D]:
	var out: Array[Area2D] = []
	_walk_areas(_gl, out)
	return out


func _walk_areas(p_node: Node, p_out: Array[Area2D]) -> void:
	if p_node is Area2D:
		p_out.append(p_node)
	for c in p_node.get_children():
		_walk_areas(c, p_out)


# ── T1 t1a：序守卫 + 穿透预算（收集-冲刷两段式核心语义） ────────────

func _t1a_serial_guard() -> void:
	print("── t1a 序守卫：穿透弹双候选 → 只结第一对、无幻影结算 ──")
	_set_gates(1, 1, 0)                         # boost 开 + 网格强开 + 死亡关（隔离 T1 面）
	_field_reset()
	var s0 := _settles_total()
	var a := _spawn_enemy(Vector2(360.0, 600.0), HP_BIG)
	var b := _spawn_enemy(Vector2(360.0, 616.0), HP_BIG)   # 16px 双候选同格（桶内插入序 A→B）
	var proj := _spawn_bullet(Vector2(360.0, 608.0), Vector2(0.0, 20.0),
		{"pierce": 1, "hitbox_radius": 40.0})
	_drive(1)
	_check("t1a 序守卫：pierce=1 双候选 → 只结第一对（A 掉血 ∧ B 分毫未动）",
		a.hp < HP_BIG and is_equal_approx(b.hp, HP_BIG),
		"AΔ=%.1f BΔ=%.1f" % [HP_BIG - a.hp, HP_BIG - b.hp])
	_check("t1a 穿透耗尽回收：弹已离场（PIERCE_DEPLETED 统一收束）",
		not (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles().has(proj),
		"still_active=%s" % str((_gl.pools[&"projectile"] as ProjectilePool).active_projectiles().has(proj)))
	_check("t1a 无幻影结算：结N 增量==1（第二对被序守卫吸收）",
		_settles_total() - s0 == 1, "结N+%d" % (_settles_total() - s0))
	_check("t1a 冲刷后对缓冲恒空（快照冲刷语义）",
		GameLoop._hp_proj.size() == 0 and GameLoop._hp_serial.size() == 0,
		"proj=%d serial=%d" % [GameLoop._hp_proj.size(), GameLoop._hp_serial.size()])
	# serial 复用守卫直驱：pierce 尚存的活弹被手工落一条「serial 过期」残对——
	# 冲刷必须跳过（防 FRACTAL 子代 pool.acquire 复用同节点后的幻影对误结算）
	_field_reset()
	var s1 := _settles_total()
	var c := _spawn_enemy(Vector2(360.0, 600.0), HP_BIG)
	var p1 := _spawn_bullet(Vector2(360.0, 604.0), Vector2.ZERO,
		{"pierce": 3, "hitbox_radius": 40.0})
	_drive(1)                                   # 合法命中 C 一对（pierce 尚余 2，弹仍在场）
	var legal_settles := _settles_total() - s1
	var hp_mid := c.hp
	GameLoop._hp_proj.append(p1)
	GameLoop._hp_target.append(c)
	GameLoop._hp_serial.append(p1.run_serial - 1)    # 旧 serial ≠ 现 run_serial → 必须跳过
	GameLoop._flush_hit_pairs()
	_check("t1a serial 复用守卫：过期 serial 残对零结算（合法命中恰 1 结不增）",
		legal_settles == 1 and _settles_total() - s1 == 1 and is_equal_approx(c.hp, hp_mid),
		"合法=%d 总=%d CΔ=%.1f" % [legal_settles, _settles_total() - s1, hp_mid - c.hp])
	_field_reset()


# ── T1 t1c3/t1d：单弹单敌受控夹具逐项对拍表（关态逐位 + boost 网格等价） ──

func _t1cd_controlled_compare() -> void:
	print("── t1c3/t1d 受控对拍：单弹单敌（A=关态真值 / B=强关压 boost / C=boost 网格） ──")
	var ra := _run_controlled(9001, -1, -1)     # A：boost 关（桌面真值路径）
	var rb := _run_controlled(9001, 1, 0)       # B：boost 开 + 网格强关（t1d 注入口压过 boost）
	var rc := _run_controlled(9001, 1, 1)       # C：boost 开 + 网格真值开（T1 新路径）
	_check("t1d 关态逐位：A(关态真值) ≡ B(强关压 boost) 全项逐位（pkg4 承重墙语义）",
		_readouts_equal(ra, rb), _readouts_diff(ra, rb))
	_check("t1c3 单弹单敌对拍：A ≡ C 全项逐位（命中判定/穿透/结N/伤值同帧同序等价）",
		_readouts_equal(ra, rc), _readouts_diff(ra, rc))


func _run_controlled(p_seed: int, p_boost: int, p_grid: int) -> Dictionary:
	_field_reset()
	_clear_weapons()                            # 受控面：首发武器出场（唯一伤源=夹具弹）
	seed(p_seed)
	_gl.pipeline.call(&"set_rng_seed", p_seed)
	_set_gates(p_boost, p_grid, 0)
	var s0 := _settles_total()
	var e := _spawn_enemy(Vector2(360.0, 700.0), 5000.0)
	var proj := _spawn_bullet(Vector2(360.0, 400.0), Vector2(0.0, 480.0),
		{"pierce": 1, "hitbox_radius": 6.0, "panel_snapshot":
			{"base_atk": 37.0, "crit_rate": 0.25, "crit_mult": 2.0}})
	_drive(90)
	var out := {
		"enemy_hp": e.hp,
		"settles_delta": _settles_total() - s0,
		"dmg": _dmg_sum,
		"player_hp": _gl.player.hp,
		"serial": proj.run_serial,
		"grid_frame_hits": int(GameLoop.hit_pairs_flushed),
	}
	_field_reset()
	return out


func _readouts_equal(p_a: Dictionary, p_b: Dictionary) -> bool:
	for k in p_a:
		if k == "grid_frame_hits" or k == "serial":
			continue                            # 会话累计对数/单调 serial——模式间天然不同，不入逐位面
		if p_a[k] != p_b[k]:
			return false
	return true


func _readouts_diff(p_a: Dictionary, p_b: Dictionary) -> String:
	var parts: Array[String] = []
	for k in p_a:
		if k == "grid_frame_hits" or k == "serial":
			continue
		if p_a[k] != p_b[k]:
			parts.append("%s %s≠%s" % [k, str(p_a[k]), str(p_b[k])])
	return "；".join(parts) if not parts.is_empty() else "全等"


# ── T1 t1b：收集/冲刷同帧闭合（300 帧驱动 + 关态缓冲恒空） ──────────

func _t1b_sameframe_closure() -> void:
	print("── t1b 收集/冲刷同帧：boost 态 300 帧跨帧滞留==0 ∧ 关态缓冲恒空 ──")
	# 开态臂：弹群穿敌阵——每帧 ④ 尾冲刷完毕（缓冲零残留）
	_set_gates(1, 1, 0)
	_field_reset()
	_gl.stage_probe_enabled = true
	for i in range(6):
		_spawn_enemy(Vector2(300.0 + 40.0 * i, 640.0), HP_BIG)
	var h0 := int(GameLoop.hit_pairs_flushed)
	var residues := 0
	for i in range(300):
		if i % 10 == 0:
			_spawn_bullet(Vector2(240.0 + (i % 7) * 40.0, 80.0), Vector2(0.0, 520.0),
				{"pierce": 2, "hitbox_radius": 8.0})
		_gl._physics_process(DT)
		if GameLoop._hp_proj.size() != 0 or GameLoop._hp_target.size() != 0 \
				or GameLoop._hp_serial.size() != 0:
			residues += 1
	_check("t1b 开态 300 帧：帧帧冲刷完毕（跨帧滞留计数==0）", residues == 0,
		"滞留帧=%d" % residues)
	var flushed_delta := int(GameLoop.hit_pairs_flushed) - h0
	_check("t1b 开态命中在账：会话冲刷对数增量 >0", flushed_delta > 0, "对数+%d" % flushed_delta)
	var hc := _bucket_us(&"hit_collect")
	var hf := _bucket_us(&"hit_flush")
	_check("p0 命/结µs 桶在账：开态窗内 命µs>0 ∧ 结µs>0（收集段/冲刷段计时落账）",
		hc > 0 and hf > 0, "命µs=%d 结µs=%d" % [hc, hf])
	# 关态臂：boost 开 + 网格强关——缓冲恒空、冲刷对数零增量（强关压过 boost）
	var h1 := int(GameLoop.hit_pairs_flushed)
	_set_gates(1, 0, 0)
	residues = 0
	for i in range(120):
		if i % 10 == 0:
			_spawn_bullet(Vector2(240.0 + (i % 7) * 40.0, 80.0), Vector2(0.0, 520.0),
				{"pierce": 2, "hitbox_radius": 8.0})
		_gl._physics_process(DT)
		if GameLoop._hp_proj.size() != 0 or GameLoop._hp_target.size() != 0 \
				or GameLoop._hp_serial.size() != 0:
			residues += 1
	var off_delta := int(GameLoop.hit_pairs_flushed) - h1
	_check("t1b 关态 120 帧：两缓冲恒空 ∧ 冲刷对数零增量（强关压过 boost——t1d 注入口语义）",
		residues == 0 and off_delta == 0, "滞留帧=%d 对数+%d" % [residues, off_delta])
	_gl.stage_probe_enabled = false
	_field_reset()


# ── T1 t1e：掷斧/敌弹不受扰 ─────────────────────────────────────────

func _t1e_axe_enemy_bullet() -> void:
	print("── t1e 掷斧零命中对 ∧ 敌弹撞玩家时序两态逐位 ──")
	# 掷斧幽灵飞行：boost 网格开态零命中对、敌不掉血（_flight_axe 守卫同位）
	_set_gates(1, 1, 0)
	_field_reset()
	var h0 := int(GameLoop.hit_pairs_flushed)
	var e := _spawn_enemy(Vector2(360.0, 600.0), HP_BIG)
	var axe := _spawn_bullet(Vector2(360.0, 604.0), Vector2(0.0, -240.0),
		{"flight_axe": true, "pierce": 5, "hitbox_radius": 40.0, "target_point": Vector2(60.0, 160.0)})
	_drive(3)
	var axe_alive: bool = is_instance_valid(axe) and axe._live
	_check("t1e 掷斧：boost 网格开态零命中对 ∧ 敌分毫未动 ∧ 弹仍在飞",
		int(GameLoop.hit_pairs_flushed) - h0 == 0 and is_equal_approx(e.hp, HP_BIG)
			and axe_alive,
		"对数+%d 敌Δ=%.1f live=%s" % [int(GameLoop.hit_pairs_flushed) - h0,
			HP_BIG - e.hp, str(axe_alive)])
	_field_reset()
	# 敌弹 team1 撞玩家：两态帧序读数逐位（team1 撞玩家直判不改——设计「不动」项）
	var hp_full := 1.0e12
	var hits := []
	for mode in 2:
		_field_reset()
		_set_gates(1, 1 if mode == 0 else 0, 0)
		_gl.player.set("hp", hp_full)
		var eb := _spawn_bullet(Vector2(360.0, 100.0), Vector2(0.0, 620.0),
			{"pierce": 1, "hitbox_radius": 6.0, "panel_snapshot": {"base_atk": 13.0}}, 1)
		var hit_at := -1
		for i in range(120):
			_gl._physics_process(DT)
			if _gl.player.hp < hp_full:
				hit_at = i
				break
		var dead_ok: bool = (not is_instance_valid(eb)) or not eb._live
		hits.append([hit_at, _gl.player.hp, dead_ok])
		_check("t1e 敌弹撞玩家（%s 态）：命中发生 ∧ 弹回收" % ["网格开", "强关"][mode],
			hit_at >= 0 and dead_ok, "hit@%d live=%s" % [hit_at, str(dead_ok)])
	_check("t1e 敌弹时序两态逐位：命中帧/掉血值/回收态 A≡B（team1 面零扰动）",
		hits[0][0] == hits[1][0] and hits[0][1] == hits[1][1] and hits[0][2] == hits[1][2],
		"开=%s 关=%s" % [str(hits[0]), str(hits[1])])
	_field_reset()


# ── T1 t1c2：多 seed 命中对拍台架（真开火通道 W2——统计带验收） ─────

func _t1c2_ab_bench() -> void:
	print("── t1c2 命中对拍台架：W2 真开火 × 5 seed × override 0/1（±2% 声明带） ──")
	var seeds := [11, 23, 37, 41, 53]
	var agg := {0: {"dmg": 0.0, "settles": 0.0, "kills": 0.0},
		1: {"dmg": 0.0, "settles": 0.0, "kills": 0.0}}
	# ① 确定性锁：同 seed 同 override 两跑逐位（W2 弹道/结算法确定性口径）
	var r1 := _run_w2_run(seeds[0], 0)
	var r2 := _run_w2_run(seeds[0], 0)
	_check("t1c2① 确定性锁：seed=%d override=0 两跑全指标逐位" % seeds[0],
		r1["dmg"] == r2["dmg"] and r1["settles"] == r2["settles"] and r1["kills"] == r2["kills"],
		"跑1=%s 跑2=%s" % [str(r1), str(r2)])
	# ② 跨 override 多 seed 聚合带
	var rows := ""
	for s in seeds:
		var r0 := _run_w2_run(s, 0)
		var rx := _run_w2_run(s, 1)
		agg[0]["dmg"] += float(r0["dmg"])
		agg[0]["settles"] += float(r0["settles"])
		agg[0]["kills"] += float(r0["kills"])
		agg[1]["dmg"] += float(rx["dmg"])
		agg[1]["settles"] += float(rx["settles"])
		agg[1]["kills"] += float(rx["kills"])
		rows += "seed=%d 关[dmg=%.0f 结=%d 杀=%d] 开[dmg=%.0f 结=%d 杀=%d]  " % [
			s, r0["dmg"], r0["settles"], r0["kills"], rx["dmg"], rx["settles"], rx["kills"]]
	print("  读数（逐 seed）：%s" % rows.strip_edges())
	var n := float(seeds.size())
	for metric in ["dmg", "settles", "kills"]:
		var m0 := float(agg[0][metric]) / n
		var m1 := float(agg[1][metric]) / n
		var rel := absf(m1 - m0) / maxf(m0, 1.0)
		_check("t1c2② 跨 override 聚合带（%s）：|开−关|/关 ≤ 2%%" % metric, rel <= 0.02,
			"关均值=%.1f 开均值=%.1f 相对差=%.2f%%" % [m0, m1, rel * 100.0])
	_field_reset()


func _run_w2_run(p_seed: int, p_grid: int) -> Dictionary:
	_field_reset()
	seed(p_seed)
	_gl.pipeline.call(&"set_rng_seed", p_seed)
	_set_gates(1, p_grid, 0)                    # boost 开态（A/B 两臂只差网格门——促1 深载口径）
	_clear_weapons()
	var w = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	w.level = 3
	for i in range(14):
		_spawn_enemy(Vector2(120.0 + (i % 7) * 80.0, 420.0 + floorf(i / 7.0) * 200.0), 20.0)
	var s0 := _settles_total()
	_drive(600)
	var out := {"dmg": _dmg_sum, "settles": _settles_total() - s0, "kills": _kill_n}
	_clear_weapons()
	_field_reset()
	return out


# ── T3 t3a：批量化快照语义（冲刷点前 0 → 冲刷后 3 / FIFO / 再入队当帧兜底吸收） ──

func _t3a_flush_semantics() -> void:
	print("── t3a 死亡冲刷批量化：冲刷点前==0 后==3 / FIFO / 再入队当帧闭合 ──")
	_set_gates(1, -1, -1)                       # 真值路径（boost 开 → 双门随 boost）
	_field_reset()
	_drive(1)                                   # 门为帧级缓存（〔v2·M2〕）——回调击杀前过帧界刷新
	var k0 := _kill_n
	var ids: Array[int] = []
	for i in range(3):
		var e := _spawn_enemy(Vector2(200.0 + 60.0 * i, 400.0), 100.0)
		ids.append(e.get_instance_id())
	_kill_order.clear()
	var cb := Callable(self, "_t3a_kill_all_cb")
	tree.physics_frame.connect(cb)
	await tree.physics_frame                    # 恢复点=帧 N 头：回调已杀 3（冲刷点前）
	tree.physics_frame.disconnect(cb)
	var before := _kill_n - k0
	await tree.physics_frame                    # 恢复点=帧 N+1 头：帧 N 的 ④尾冲刷/⑤/兜底已走完
	_check("t3a 批量化：冲刷点前 emit 计数==0（帧内击杀全在队）", before == 0,
		"冲刷点前击杀+%d" % before)
	_check("t3a 批量化：冲刷后 emit 计数==3（快照冲刷一次到位）", _kill_n - k0 == 3,
		"击杀+%d" % (_kill_n - k0))
	_check("t3a FIFO：死亡序=派发序（A→B→C）", _kill_order == ids,
		"序=%s 期望=%s" % [str(_kill_order), str(ids)])
	_check("t3a 收窄在冲刷点：spawner.active 已收窄 ∧ 冲刷队列排空",
		_gl.spawner.active.size() == 0 and GameLoop._death_queue.is_empty(),
		"active=%d 队=%d" % [_gl.spawner.active.size(), GameLoop._death_queue.size()])
	_check("t3a 冲刷计数在账：deaths_flushed ≥3", int(GameLoop.deaths_flushed) >= 3,
		"死冲=%d" % int(GameLoop.deaths_flushed))
	# 冲刷中再入队（防御面）：快照制下新段不顺延本段 → 下一冲刷点（⑤尾）/帧末兜底
	# 当帧吸收——无跨帧滞留（§3.3 〔v2·M3〕）
	_field_reset()
	_drive(1)                                   # 帧界刷新（同上）
	var k1 := _kill_n
	var late := _spawn_enemy(Vector2(300.0, 500.0), 100.0)
	late.dead = true                            # 死亡已 mark、未入队（夹具直构残段）
	var trio: Array[Enemy] = []
	for i in range(3):
		trio.append(_spawn_enemy(Vector2(200.0 + 60.0 * i, 400.0), 100.0))
	_t3a_targets = trio
	var requeued := [false]
	var handler := func(_e: Node2D) -> void:
		if not requeued[0]:
			requeued[0] = true
			GameLoop.enqueue_death(late)             # 冲刷中途人为再入队（快照语义防御面）
	EventBus.enemy_killed.connect(handler)
	var cb2 := Callable(self, "_t3a_kill_targets_cb")
	tree.physics_frame.connect(cb2)
	await tree.physics_frame                    # 帧 M 头：杀 3（此刻 fan-out 尚未执行——在队）
	await tree.physics_frame                    # 帧 M+1 头：④尾冲刷（首 emit 时再入队 late）/
	                                            # ⑤尾·兜底吸收已全部走完——此刻才可断连
	tree.physics_frame.disconnect(cb2)
	EventBus.enemy_killed.disconnect(handler)
	var late_gone: bool = (not is_instance_valid(late)) \
		or bool(late.get_meta(ObjectPool._META_IN_POOL, false))
	_check("t3a 当帧闭合：冲刷中再入队残段当帧被后续冲刷点吸收（4 杀 ∧ 队空 ∧ 无跨帧滞留）",
		_kill_n - k1 == 4 and GameLoop._death_queue.is_empty() and late_gone,
		"击杀+%d 队=%d 残段已收=%s" % [_kill_n - k1, GameLoop._death_queue.size(), str(late_gone)])
	_field_reset()


func _t3a_kill_all_cb() -> void:
	for e in _gl.spawner.active.duplicate():
		e.apply_damage(1.0e9)                   # 同帧 3 杀：dead inline + 入队（fan-out 挂冲刷点）


func _t3a_kill_targets_cb() -> void:
	for e in _t3a_targets:
		if is_instance_valid(e):
			e.apply_damage(1.0e9)


# ── T3 t3b：inline 面不动（dead 即时置位 → 后续命中死亡短路不浪费穿透） ──

func _t3b_inline_face() -> void:
	print("── t3b inline 面：dead 冲刷前即置位 ∧ 穿透不浪费（死亡短路） ──")
	_set_gates(1, 1, 1)                         # 全开（boost 网格 + 死亡冲刷）
	_field_reset()
	_drive(1)                                   # 帧界刷新（出帧击杀须读过帧缓存的门）
	var s0 := _settles_total()
	var pre := _spawn_enemy(Vector2(360.0, 600.0), 100.0)
	var live := _spawn_enemy(Vector2(360.0, 616.0), 100.0)
	pre.apply_damage(1.0e9)                     # A 先死：dead inline 置位、fan-out 在队
	_check("t3b dead 即时置位：apply_damage 返回即 dead==true（冲刷前）", pre.dead,
		"dead=%s" % str(pre.dead))
	_spawn_bullet(Vector2(360.0, 608.0), Vector2.ZERO, {"pierce": 1, "hitbox_radius": 40.0})
	_drive(1)
	_check("t3b 死亡短路：dead 目标零结算（结N==1 恰为活敌）∧ 活敌掉血（穿透未被亡敌浪费）",
		_settles_total() - s0 == 1 and live.hp < 100.0,
		"结N+%d liveΔ=%.1f" % [_settles_total() - s0, 100.0 - live.hp])
	_field_reset()


# ── T3 t3c：关态 fan-out 即时（死亡弹爆/收尸时序与刀前逐位） ────────

func _t3c_off_immediate() -> void:
	print("── t3c 关态即时：death_flush 关 → apply_damage 调用点 fan-out 已执行 ──")
	_set_gates(-1, -1, -1)                      # 全关（桌面默认真值路径）
	_field_reset()
	var k0 := _kill_n
	var e := _spawn_enemy(Vector2(360.0, 600.0), 100.0)
	_drive(1)                                   # 帧界刷新（关态缓存落定后再出帧击杀）
	e.apply_damage(1.0e9)
	_check("t3c 关态即时：emit 计数调用点即 +1（零入队零延迟）", _kill_n - k0 == 1,
		"击杀+%d" % (_kill_n - k0))
	_check("t3c 关态收尸即时：spawner.active 已收窄 ∧ 队恒空",
		_gl.spawner.active.size() == 0 and GameLoop._death_queue.is_empty(),
		"active=%d 队=%d" % [_gl.spawner.active.size(), GameLoop._death_queue.size()])
	_field_reset()


# ── T3 t3d：当帧兜底长跑排空 + is_instance_valid 复验 ───────────────

func _t3d_fallback_drain() -> void:
	print("── t3d 兜底：长跑 200 帧队恒空 ∧ 中途 free 亡敌不崩 ──")
	_set_gates(1, -1, 1)                        # 死亡冲刷强开（grid 真值——无弹面不涉）
	_field_reset()
	var k0 := _kill_n
	var drained_frames := 0
	var killed_mid := false
	for i in range(200):
		if i % 40 == 0:
			var e := _spawn_enemy(Vector2(360.0, 400.0), 100.0)
			e.apply_damage(1.0e9)               # 入队（冲刷点在帧内）
			if i == 120:
				# 看门狗先行归还仿真：冲刷点前 free——flush 复验 is_instance_valid 吸收
				_gl.spawner.active.erase(e)
				e.free()
				killed_mid = true
		_gl._physics_process(DT)
		if GameLoop._death_queue.is_empty():
			drained_frames += 1
	_check("t3d 长跑 200 帧：每帧末队列恒空（兜底冲刷后零滞留）", drained_frames == 200,
		"队空帧=%d/200" % drained_frames)
	_check("t3d 复验：中途 free 亡敌被 is_instance_valid 守卫吸收（零崩溃零误 fan-out）",
		killed_mid and _kill_n - k0 == 4, "击杀+%d（期望恰 4——free 者不计）" % (_kill_n - k0))
	_field_reset()


# ── T3 t3e：燎原连锁读数漂移（声明④验收面——开侧单向收窄） ──────────

func _t3e_spread_burn() -> void:
	print("── t3e 燎原连锁：同帧双杀 dead 过滤收窄（关=点燃 / 开=跳过——声明带） ──")
	# 夹具：A 带燃（spread 半径 150）+ B 在半径内；同帧杀 A→B。
	# 关态：A fan-out 即时 → B 活 → 满槽点燃（burn_spread +1）；开态：A/B dead 全置位
	# 先于 fan-out → B 被跳过（burn_spread +0）——单向收窄=§3.1.5 声明④实测面。
	var counts := {0: [], 1: []}
	for mode in 2:                              # 0=关 / 1=开
		for rep in 2:                           # ①每侧两跑逐位（确定性锁）
			_field_reset()
			seed(7700 + rep)
			if mode == 0:
				_set_gates(-1, -1, -1)
			else:
				_set_gates(1, -1, 1)
			var a := _spawn_enemy(Vector2(300.0, 600.0), 100.0, true)
			var b := _spawn_enemy(Vector2(360.0, 600.0), 100.0, true)
			var st: ElementalState = a.elemental
			st.burn_timer = 5.0
			st.burn_spread_radius = 150.0
			st.burn_snapshot_atk = 100.0
			_drive(1)                           # 帧界刷新（门为帧级缓存——出帧击杀前过帧界）
			var sp0 := DebugStats.get_counter(&"burn_spread")
			a.apply_damage(1.0e9)
			# 点燃读数在杀 B 前取（B 死后归还 → elemental 置 null 读不到状态面）；
			# FIR 满槽即清槽转燃烧（ElementalState.apply 旧三元素口径）——探针读 burn_timer
			var b_ignited: bool = is_instance_valid(b) and b.elemental != null \
				and (float(b.elemental.burn_timer) > 0.0
					or float(b.elemental.gauges[GameConst.Element.FIR]) > 0.0)
			b.apply_damage(1.0e9)
			_drive(2)                           # 开态 fan-out 在冲刷点；关态已在调用点执行
			var spread := int(DebugStats.get_counter(&"burn_spread")) - int(sp0)
			counts[mode].append([spread, b_ignited])
	_field_reset()
	_check("t3e① 关侧确定性：两跑读数逐位（fan-out 即时——刀前一致）",
		counts[0][0] == counts[0][1], "两跑=%s" % str(counts[0]))
	_check("t3e① 开侧确定性：两跑读数逐位（快照冲刷确定序）",
		counts[1][0] == counts[1][1], "两跑=%s" % str(counts[1]))
	_check("t3e③ 关态燎原面逐位：A 死时 B 活 → 点燃发生（spread==1 ∧ B 满槽）",
		counts[0][0][0] == 1 and counts[0][0][1] == true,
		"spread=%s ignited=%s" % [str(counts[0][0][0]), str(counts[0][0][1])])
	_check("t3e② 声明带（方向单向收窄）：开侧 B 被 dead 过滤跳过（spread==0 ∧ 未点燃）",
		counts[1][0][0] == 0 and counts[1][0][1] == false,
		"spread=%s ignited=%s" % [str(counts[1][0][0]), str(counts[1][0][1])])
	_check("t3e② 漂移方向锁：开侧 ≤ 关侧（燎原 DOT 收益单向收窄——§0.2 迁移点④）",
		int(counts[1][0][0]) <= int(counts[0][0][0]),
		"关=%s 开=%s" % [str(counts[0][0][0]), str(counts[1][0][0])])


# ── P0：四分键 + ipµs 桶 + ip 短路机制 ──────────────────────────────

func _p0_prof_buckets() -> void:
	print("── p0 四分键/ipµs 桶在账 + S8 ip 短路机制 ──")
	# 死µs：关态也累计（fan-out 即时路径计时——零行为）
	_gl.stage_probe_enabled = true
	_set_gates(-1, -1, -1)
	_field_reset()
	_drive(1)                                   # 帧界刷新（prof_buckets_frame 随 ④ 头 stage_probe 落定）
	var d0 := _bucket_us(&"death_flush")
	var e := _spawn_enemy(Vector2(360.0, 600.0), 100.0)
	e.apply_damage(1.0e9)
	var d1 := _bucket_us(&"death_flush")
	_check("p0 死µs：关态 fan-out 也入账（现状路径计时——零行为）", d1 > d0,
		"死µs %d→%d" % [d0, d1])
	# 回µs：弹 _recycle→release 链（关态也累计——计时点在 ProjectileBase._recycle 本体，
	# 池直 release 不经该链，故走真实回收原因入口）
	var r0 := _bucket_us(&"recycle")
	var p := _spawn_bullet(Vector2(360.0, 300.0), Vector2.ZERO)
	p._recycle(GameConst.RecycleReason.EXPIRED)
	var r1 := _bucket_us(&"recycle")
	_check("p0 回µs：弹回收链入账（关态也累计）", r1 > r0, "回µs %d→%d" % [r0, r1])
	# ipµs + S8 短路：注入 30Hz 谓词（R233 同款）→ 双遍历执行入账；短路臂归零
	var sim_saved := GameLoop.SIM_30HZ_ENABLED
	var ov_saved := GameLoop.sim30_override
	var ip_short_saved := GameLoop.shortcircuit_ip_pass
	GameLoop.SIM_30HZ_ENABLED = true
	GameLoop.sim30_override = -3
	var i0 := _bucket_us(&"ip_pass")
	_drive(2)
	var i1 := _bucket_us(&"ip_pass")
	_check("p0 ipµs：30Hz 态双遍历入账（恢复+快照合计）", i1 > i0,
		"ipµs %d→%d" % [i0, i1])
	GameLoop.shortcircuit_ip_pass = true
	var i2 := _bucket_us(&"ip_pass")
	_drive(2)
	var i3 := _bucket_us(&"ip_pass")
	_check("p0 S8 ip 短路：注入口置位 → 双遍历零执行（ipµs 零增量）", i3 == i2,
		"ipµs %d→%d" % [i2, i3])
	GameLoop.SIM_30HZ_ENABLED = sim_saved
	GameLoop.sim30_override = ov_saved
	GameLoop.shortcircuit_ip_pass = ip_short_saved
	_gl.stage_probe_enabled = false
	_field_reset()


# ── T2 p3：CONTACT_RADIAL 旗语义锁（二次 boot——probe_r237 A2K 手法） ─

func _t2_p3_contact_radial() -> void:
	print("── t2.p3 CONTACT_RADIAL 旗语义锁（产品无写口事实锁 + A2K 重挂） ──")
	var src := FileAccess.get_file_as_string(ENEMY_SRC)
	_check("t2.p3 产品无写口：enemy.gd 零『CONTACT_RADIAL = true』赋值点（V-A 未实施事实锁）",
		src.count("CONTACT_RADIAL = true") == 0,
		"写口=%d" % src.count("CONTACT_RADIAL = true"))
	_check("t2.p3 旗出厂态：Enemy.CONTACT_RADIAL==false（桌面/boost 两态同）",
		Enemy.CONTACT_RADIAL == false, "flag=%s" % str(Enemy.CONTACT_RADIAL))
	# A2K 重挂：free 主 _gl → 前置旗 → 二次 boot（池预热期 _ready 读旗——运行中翻旗不追溯）
	_set_gates(-1, -1, -1)
	_field_reset()
	_disconnect_metrics()
	_gl.free()
	_gl = null
	Enemy.CONTACT_RADIAL = true
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R285GridHitA2K"
	tree.root.add_child(_gl)
	Enemy.CONTACT_RADIAL = false                # 立即复位（池预热已完成读旗——A2K 同款纪律）
	var ok: bool = _gl.boot_ready and _gl.state == GameConst.GameStatus.MENU
	if ok:
		_gl.state = GameConst.GameStatus.PLAYING
		var e := (_gl.pools[&"enemy"] as EnemyPool).acquire() as Enemy
		if e != null:
			e.bucket_host = (_gl.pools[&"enemy"] as EnemyPool).bucket_host
			e.spawn(_gl.registry.get_enemy(&"E1_grunt"), 1, 0)
		var ha_v: Variant = e.get("_hit_area")
		_check("t2.p3 清退刀态：旗 on → 新构敌 _hit_area==null（敌 HitArea 从不构建）",
			ha_v == null, "hit_area 在场=%s" % str(ha_v != null))
		_check("t2.p3 清退刀态：玩家面惰化（monitoring==false ∧ monitorable==false ∧ layer==0）",
			_gl.player.monitoring == false and _gl.player.monitorable == false
				and _gl.player.collision_layer == 0,
			"mon=%s mable=%s layer=%d" % [str(_gl.player.monitoring),
				str(_gl.player.monitorable), _gl.player.collision_layer])
		_gl.elemental.unregister_host(e)
		(_gl.pools[&"enemy"] as EnemyPool).release(e)
	else:
		_check("t2.p3 A2K 二次 boot", false, "boot 失败")
	# 复挂主 _gl（旗已复位——出厂态语义）
	_gl.free()
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R285GridHit2"
	tree.root.add_child(_gl)
	_check("t2.p3 旗复位回挂：出厂态 boot 正常（旗 off → 玩家 layer==3）",
		_gl.boot_ready and _gl.player.collision_layer == 3,
		"boot=%s layer=%d" % [str(_gl.boot_ready), _gl.player.collision_layer])
	_setup_battle()
	await tree.process_frame
	await tree.process_frame


# ── 收尾（盘档自清 + 注入口出厂态复位） ─────────────────────────────

func _cleanup() -> void:
	_disconnect_metrics()
	if _gl != null and is_instance_valid(_gl):
		_set_gates(-1, -1, -1)
		GameLoop.shortcircuit_ip_pass = false
		GameLoop.prof_buckets_frame = false
		GameLoop.grid_hit_frame = false
		GameLoop.death_flush_frame = false
		GameLoop.SIM_30HZ_ENABLED = false
		GameLoop.sim30_override = -1
		Enemy.CONTACT_RADIAL = false
		PerfGovernor.boost_override = -1
		PerfGovernor.mode_override = -1
		PerfGovernor.tier_override = -1
		PerfGovernor.tier = 3
		PerfGovernor.set_process(true)
		PerfGovernor._test_reset()
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame
	# 盘档自清（§0.5——R272 两度盘档毒教训）：快照整字典还原 + Meta._save() 落盘
	#（内存 erase 无效；headless 存档走 meta_save_test.cfg）
	Meta._settings = _saved_settings
	Meta._save()
	RunSave.clear()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])

# tests/qa_r287_emptyquery_cases.gd（R287 用例体——入口运行时加载）
# 覆盖（空场查询早退刀的行为等价面；判据=快照空 ⇒ 任何 query_* 必然零候选）：
#   e1 is_empty 真值链：rebuild([])→true / rebuild([敌])→false / 再 rebuild([])→true
#      （帧间复位——_snap_items 是唯一实体真源）+ 清场后真链空场驱动 1 步 is_empty()
#      （④ 头实际重建路径同步保持空态，非仅直调口径）。
#   e2 空场零命中等价（boost 开——真机热路径）：无敌 + 弹阵驱动 60 步 → 结算数=0、
#      伤害=0（早退前空查询本就零候选零命中——逐位等价的判读面）。
#   e3 有敌命中常在（早退未过度跳）：巨血敌 + 贴身弹驱动 → 结算数>0（boost 开收集
#      路径 t3a / boost 关 _check_collision 路径 t3b 两态各自断言——两条查询位点都
#      不因早退丢真命中；弹贴敌位生成+低速对穿，规避敌游走脱靶噪声）。
#   e4 弹运动不受扰：空场早退激活期弹位置正常推进（早退只在命中查询位点、不触 tick）。
# 夹具纪律（照 qa_r285_gridhit_cases 同款）：受控 PLAYING（无 start_run——wave 恒
# IDLE 零波次干扰）；玩家钉桩 hp/xp 巨额；敌/弹池注入四依赖；敌先 unregister_host
# 再 release（R253/R259）；盘档自清（Meta 快照整字典还原+_save 落盘，R272 教训）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const PLAYER_HOME := Vector2(360.0, 980.0)
const DRIVE_FRAMES := 60

var tree: SceneTree
var _gl: Node = null
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _saved_settings: Dictionary = {}
var _dmg_sum: float = 0.0
var _settle_n: int = 0
var _metric_connected: bool = false


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_saved_settings = Meta._settings.duplicate()      # 入口快照（收尾还原——磁盘不留测试痕）
	_boot()
	PerfGovernor.set_process(false)
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = 3
	PerfGovernor.boost_override = -1
	Meta.set_setting("fx_quality", 2)           # r230 先例：钉高防跨套件 user:// 残留漂门
	_setup_battle()
	_e1_is_empty_truth_chain()
	_e2_empty_field_no_hits()
	await _e3_enemy_present_hits_still_flow()
	_e4_bullet_motion_undisturbed()
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
		print("  FAIL | %s（%s）" % p_name, p_detail)


# ── boot / 夹具（gridhit 同款） ─────────────────────────────────────

func _boot() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate()
	_gl.name = "R287EmptyQuery"
	tree.root.add_child(_gl)
	if not (_gl.get("boot_ready") and _gl.state == GameConst.GameStatus.MENU):
		push_error("[r287] Boot 失败：%s" % str(_gl.get("boot_fatal")))
		_fail += 1


func _setup_battle() -> void:
	_gl.state = GameConst.GameStatus.PLAYING
	_gl.wave_director.set("_hard_cap_left", 9999.0)
	_gl.player.set("xp_need", 1.0e12)
	_gl.player.set("max_hp", 1.0e12)
	_gl.player.set("hp", 1.0e12)
	_gl.player.unlocked_slots = 6
	_gl.player.global_position = PLAYER_HOME
	if not _metric_connected:
		_metric_connected = true
		EventBus.damage_resolved.connect(_on_damage_resolved)
	_reset_metrics()


func _on_damage_resolved(p_result) -> void:
	_dmg_sum += float(p_result.get("final_value"))
	_settle_n += 1


func _reset_metrics() -> void:
	_dmg_sum = 0.0
	_settle_n = 0


func _drive(p_frames: int) -> void:
	for i in range(p_frames):
		_gl._physics_process(DT)


func _spawn_enemy(p_pos: Vector2, p_hp: float) -> Node:
	var pool = _gl.pools[&"enemy"]
	var e = pool.acquire()
	if e == null:
		return null
	e.bucket_host = pool.bucket_host
	var data: Resource = _gl.registry.get_enemy(&"E1_grunt")
	e.spawn(data, 1, 0)
	e.hp = p_hp
	e.global_position = p_pos
	_gl.spawner.active.append(e)
	return e


func _spawn_bullet(p_pos: Vector2, p_vel: Vector2) -> Node:
	var pool = _gl.pools[&"projectile"]
	var pb = pool.acquire(0)
	if pb == null:
		return null
	pb.damage_pipeline = _gl.pipeline
	pb.enemy_grid = _gl.enemy_grid
	pb.pool = pool
	pb.elemental = _gl.elemental
	pb.spawn({
		"position": p_pos, "velocity": p_vel, "team": 0,
		"lifetime": 6.0, "pierce": 1, "hitbox_radius": 6.0,
		"panel_snapshot": {"base_atk": 100.0, "crit_rate": 0.0, "crit_mult": 2.0},
	})
	return pb


func _field_reset() -> void:
	for p in (_gl.pools[&"projectile"] as ObjectPool).active_projectiles().duplicate():
		(_gl.pools[&"projectile"] as ObjectPool).release(p)
	for e in _gl.spawner.active.duplicate():
		if is_instance_valid(e):
			_gl.elemental.unregister_host(e)
			(_gl.pools[&"enemy"] as ObjectPool).release(e)
	_gl.spawner.active.clear()
	_gl.player.set("hp", 1.0e12)
	_gl.player.global_position = PLAYER_HOME
	_reset_metrics()


# ── e1：is_empty 真值链 ────────────────────────────────────────────

func _e1_is_empty_truth_chain() -> void:
	print("── e1 is_empty 真值链（快照唯一真源 + 帧间复位） ──")
	var grid = _gl.enemy_grid
	var empty_arr: Array[Node2D] = []              # 字面量直传 Array[Node2D] 参数不转换——先落类型化变量
	grid.rebuild(empty_arr)
	_check("e1a rebuild([]) → is_empty()=true（空场判据基准态）",
		grid.is_empty(), "")
	var probe: Node2D = _spawn_enemy(Vector2(600.0, 600.0), 1.0e9)
	var one_arr: Array[Node2D] = [probe]
	grid.rebuild(one_arr)
	_check("e1b rebuild([敌]) → is_empty()=false（快照非空翻转）",
		not grid.is_empty(), "")
	grid.rebuild(empty_arr)
	_check("e1c 再 rebuild([]) → is_empty()=true（帧间复位——上帧敌不滞留）",
		grid.is_empty(), "")
	# 真链口径：清掉探针敌后驱动一步，④ 头实际重建（非直调）保持空态
	_field_reset()
	_drive(1)
	_check("e1d 真链空场驱动 1 步 → is_empty()=true（④ 实际重建路径同步空态）",
		grid.is_empty(), "")


# ── e2：空场零命中等价（boost 开——真机热路径） ─────────────────────

func _e2_empty_field_no_hits() -> void:
	print("── e2 空场零命中等价（boost 开/无敌弹阵 ×%d 步） ──" % DRIVE_FRAMES)
	_field_reset()
	PerfGovernor.boost_override = 1
	GameLoop.grid_hit_override = 1
	GameLoop.death_flush_override = 1
	for i in range(8):
		_spawn_bullet(PLAYER_HOME + Vector2(40.0 * (i + 1), -120.0),
			Vector2(120.0, -300.0))
	_drive(DRIVE_FRAMES)
	_check("e2a 空场+弹阵驱动 → 结算数=0（早退前空查询本就零命中——逐位等价）",
		_settle_n == 0, "结算数=%d" % _settle_n)
	_check("e2b 空场+弹阵驱动 → 伤害=0", _dmg_sum == 0.0, "伤害=%.1f" % _dmg_sum)


# ── e3：有敌命中常在（早退未过度跳——两查询位点两态） ───────────────

func _e3_enemy_present_hits_still_flow() -> void:
	print("── e3 有敌命中常在（巨血敌+贴身弹——boost 开/关两态） ──")
	var foe_pos := PLAYER_HOME + Vector2(120.0, -240.0)
	# t3a：boost 开（_collect_hit_pairs 收集位点——真机热路径）
	_field_reset()
	PerfGovernor.boost_override = 1
	GameLoop.grid_hit_override = 1
	GameLoop.death_flush_override = 1
	var ea: Node = _spawn_enemy(foe_pos, 1.0e9)
	_spawn_bullet(foe_pos + Vector2(-6.0, 0.0), Vector2(30.0, 0.0))
	_spawn_bullet(foe_pos + Vector2(6.0, 0.0), Vector2(-30.0, 0.0))
	_drive(DRIVE_FRAMES)
	_check("e3a boost 开：巨血敌在场 → 结算数>0（收集位点早退未丢真命中）",
		_settle_n > 0, "结算数=%d 敌hp=%.0f" % [_settle_n, ea.hp])
	await tree.process_frame
	# t3b：boost 关（_check_collision 通用位点——桌面/关态路径）
	_field_reset()
	PerfGovernor.boost_override = 0
	GameLoop.grid_hit_override = 0
	GameLoop.death_flush_override = 0
	var eb: Node = _spawn_enemy(foe_pos, 1.0e9)
	_spawn_bullet(foe_pos + Vector2(-6.0, 0.0), Vector2(30.0, 0.0))
	_spawn_bullet(foe_pos + Vector2(6.0, 0.0), Vector2(-30.0, 0.0))
	_drive(DRIVE_FRAMES)
	_check("e3b boost 关：巨血敌在场 → 结算数>0（通用位点早退未丢真命中）",
		_settle_n > 0, "结算数=%d 敌hp=%.0f" % [_settle_n, eb.hp])
	await tree.process_frame


# ── e4：弹运动不受扰 ───────────────────────────────────────────────

func _e4_bullet_motion_undisturbed() -> void:
	print("── e4 弹运动不受扰（空场早退激活期 tick 正常） ──")
	_field_reset()
	PerfGovernor.boost_override = 1
	GameLoop.grid_hit_override = 1
	GameLoop.death_flush_override = 1
	var b: Node = _spawn_bullet(PLAYER_HOME + Vector2(0.0, -60.0), Vector2(60.0, -420.0))
	var pos0: Vector2 = b.global_position
	_drive(20)
	var moved: float = b.global_position.distance_to(pos0)
	_check("e4 空场驱动 20 步 → 弹位移 >100px（早退只在命中查询位点、不触 tick）",
		moved > 100.0, "位移=%.1f" % moved)


# ── 收尾（gridhit 同款纪律） ───────────────────────────────────────

func _cleanup() -> void:
	if _metric_connected:
		EventBus.damage_resolved.disconnect(_on_damage_resolved)
		_metric_connected = false
	if _gl != null and is_instance_valid(_gl):
		PerfGovernor.boost_override = -1
		PerfGovernor.mode_override = -1
		PerfGovernor.tier_override = -1
		PerfGovernor.tier = 3
		PerfGovernor.set_process(true)
		PerfGovernor._test_reset()
		GameLoop.grid_hit_override = -1
		GameLoop.death_flush_override = -1
		GameLoop.prof_buckets_frame = false
		GameLoop.grid_hit_frame = false
		GameLoop.death_flush_frame = false
		GameLoop.SIM_30HZ_ENABLED = false
		GameLoop.sim30_override = -1
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame
	# 盘档自清（R272 两度盘档毒教训）：快照整字典还原 + Meta._save() 落盘
	Meta._settings = _saved_settings
	Meta._save()
	RunSave.clear()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])

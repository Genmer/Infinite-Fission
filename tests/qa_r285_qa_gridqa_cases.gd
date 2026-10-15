# tests/qa_r285_qa_gridqa_cases.gd（R285 QA 独立探针用例体——入口运行时加载）
# 独立测试轮（qa-r285）：只报告不修复。全部探针为实施员 qa_r285_gridhit 51 断言未覆盖面，
# 聚焦：时序边界 / 同帧多弹 / 穿透-反弹 / 元素反应 DOT / boost 热切换 / 盘档卫生 / 池交互。
# 时序锚：_drive 一次=_gl._physics_process 一次完整帧（④收集-冲刷/⑤/兜底全走完）——
# 帧后直读即「该帧末」状态（qa_r285_gridhit cases 头注同款口径）。
# 纪律：套件自清盘档（Meta._settings 快照还原 + _save 落盘）；静态注入口出厂态复位；
# 池件判存活 is_instance_valid、勿二次 release；本文件运行时编译，工程类型名可用。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const PROJ_SRC := "res://scripts/combat/projectile/projectile_base.gd"
const DT := 1.0 / 60.0
const PLAYER_HOME := Vector2(360.0, 980.0)
const HP_BIG := 1.0e9
const SAVE_PATH := "user://meta_save_test.cfg"

var tree: SceneTree
var _gl: GameLoop = null
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _saved_settings: Dictionary = {}
# 指标订阅器（damage_resolved/enemy_killed 全局累计——用例间 _reset_metrics 归零）
var _dmg_sum: float = 0.0
var _settle_n: int = 0
var _kill_n: int = 0
var _metric_connected: bool = false
var _save_bytes_before: PackedByteArray = PackedByteArray()


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot()
	PerfGovernor.set_process(false)
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = 3
	PerfGovernor.boost_override = -1
	Meta.set_setting("fx_quality", 2)                 # r230 先例：钉高防跨套件 user:// 漂门
	_setup_battle()
	# 快照取 set_setting 后（qF 终态=还原重存——settings 段与基线逐位不因钉高动作自偏）
	_saved_settings = Meta._settings.duplicate()
	_save_bytes_before = _read_save_bytes()           # 盘档卫生基线（门翻转全程零写盘——qF）
	# ── 用例序：语义对拍面 → 时序边界 → 池交互 → DOT 闭合 → 卫生终检 ──
	_qa_sameframe_multi_bullet()
	_qb_bounce_attach()
	_qj_sim30_swept()
	_qc1_off_framehead_buffer_clear()
	_qc2_gate_flip_residual_queue()
	_qc3_frame_cache_latch()
	_qd1_release_before_flush()
	_qd2_freed_proj_in_buffer()
	_qe_dot_kill_sameframe()
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


# ── boot / 夹具（qa_r285_gridhit 同款惯用法） ───────────────────────

func _boot() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R285QAGridQA"
	tree.root.add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[r285qa] Boot 失败：%s" % str(_gl.boot_fatal))
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
		EventBus.enemy_killed.connect(_on_enemy_killed)
	_reset_metrics()
	_field_reset()


func _on_damage_resolved(p_result: DamageResult) -> void:
	_dmg_sum += float(p_result.final_value)
	_settle_n += 1


func _on_enemy_killed(p_enemy: Node2D) -> void:
	_kill_n += 1


func _reset_metrics() -> void:
	_dmg_sum = 0.0
	_settle_n = 0
	_kill_n = 0


func _spawn_enemy(p_pos: Vector2, p_hp: float, p_register_elemental := false) -> Enemy:
	var e := (_gl.pools[&"enemy"] as EnemyPool).acquire() as Enemy
	if e == null:
		return null
	e.bucket_host = (_gl.pools[&"enemy"] as EnemyPool).bucket_host
	var data: EnemyData = _gl.registry.get_enemy(&"E1_grunt")
	e.spawn(data, 1, 0)
	e.hp = p_hp
	e.global_position = p_pos
	e.ip_birth_snap()                           # enemy.gd:843 夹具纪律：直 spawn+挂位后定型插值缓冲
	                                            #（sim30 恢复遍历在场时防池上家残位写回——qJ 踩坑修正）
	if p_register_elemental and _gl.elemental != null:
		_gl.elemental.register_host(e)
	_gl.spawner.active.append(e)
	return e


func _spawn_bullet(p_pos: Vector2, p_vel: Vector2, p_params: Dictionary = {},
		p_team: int = 0) -> ProjectileBase:
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
	PerfGovernor.boost_override = p_boost
	GameLoop.grid_hit_override = p_grid
	GameLoop.death_flush_override = p_death


func _drive(p_frames: int) -> void:
	for i in range(p_frames):
		_gl._physics_process(DT)


func _settles_total() -> int:
	return int((_gl.pipeline.call(&"stats") as Dictionary).get("settles", 0))


func _read_save_bytes() -> PackedByteArray:
	if FileAccess.file_exists(SAVE_PATH):
		return FileAccess.get_file_as_bytes(SAVE_PATH)
	return PackedByteArray()


func _settings_section_text(p_bytes: PackedByteArray) -> String:
	# ConfigFile 无内存直载口——按行提取 [settings] 段的 values= 行（写点唯一：
	# meta_manager._save cfg.set_value("settings", "values", _settings)）
	if p_bytes.is_empty():
		return "<absent>"
	var in_sec := false
	for line in p_bytes.get_string_from_utf8().split("\n"):
		var t := line.strip_edges()
		if t.begins_with("[") and t.ends_with("]"):
			in_sec = (t == "[settings]")
			continue
		if in_sec and t.begins_with("values="):
			return t
	return "<no-settings-section>"


# ── qA：同帧多弹单敌（致死短路一次性 / 非致死独立结算——两态对拍） ──

func _qA_readout(p_enemy: Node2D) -> Dictionary:
	return {
		"hp": p_enemy.hp,
		"settles": _settle_n,
		"kills": _kill_n,
		"dmg": _dmg_sum,
		"buf_proj": GameLoop._hp_proj.size(),
		"buf_serial": GameLoop._hp_serial.size(),
	}


func _qA_run(p_kill: bool, p_boost: int, p_grid: int, p_death: int) -> Dictionary:
	_field_reset()
	_set_gates(p_boost, p_grid, p_death)
	_drive(1)                                   # 帧界闩门（门为帧级缓存——出帧注入前过帧界）
	var hp := 80.0 if p_kill else HP_BIG
	var e := _spawn_enemy(Vector2(360.0, 600.0), hp)
	var projs: Array[ProjectileBase] = []
	for i in range(3):
		projs.append(_spawn_bullet(Vector2(360.0, 600.0), Vector2.ZERO,
			{"pierce": 1, "hitbox_radius": 6.0}))
	_drive(1)
	var out := _qA_readout(e)
	out["alive_cnt"] = 0
	for p in projs:                             # 致死面：短路弹不耗穿透——3 弹全应在场
		if (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles().has(p):
			out["alive_cnt"] += 1
	_field_reset()
	_set_gates(-1, -1, -1)
	return out


func _qa_sameframe_multi_bullet() -> void:
	print("── qA 同帧多弹单敌：致死 E-06 短路一次性 / 非致死独立结算（两态对拍） ──")
	var kill_off := _qA_run(true, -1, -1, -1)    # 关态真值
	var kill_on := _qA_run(true, 1, 1, 1)        # boost 网格死亡三开（T1+T3 新路径）
	_check("qA1 致死短路：settles==1（三对冲刷仅一结——同帧多弹死亡短路一次性）",
		kill_on["settles"] == 1, str(kill_on))
	_check("qA1 致死短路：kills==1 ∧ emit 恰一次（同帧三杀申请一次 fan-out）",
		kill_on["kills"] == 1, str(kill_on))
	_check("qA1 致死短路：敌 hp==0（首结致死，后结零血泄漏）",
		kill_on["hp"] == 0.0, "hp=%s" % str(kill_on["hp"]))
	_check("qA1 两态对拍：关 ≡ 开 全项逐位（同帧多弹语义与刀前一致）",
		kill_off == kill_on, "关=%s 开=%s" % [str(kill_off), str(kill_on)])
	var big_off := _qA_run(false, -1, -1, -1)
	var big_on := _qA_run(false, 1, 1, 1)
	_check("qA2 非致死独立结算：settles==3 ∧ dmg==300（同敌多弹各自独立结算——E-03 逐弹面）",
		big_on["settles"] == 3 and absf(float(big_on["dmg"]) - 300.0) < 0.01, str(big_on))
	_check("qA2 非致死独立结算：敌 hp==HP_BIG−300",
		absf(float(big_on["hp"]) - (HP_BIG - 300.0)) < 0.01, str(big_on))
	_check("qA2 两态对拍：关 ≡ 开 全项逐位",
		big_off == big_on, "关=%s 开=%s" % [str(big_off), str(big_on)])


# ── qB：反弹弹命中（反弹预算不受命中侵蚀 + 元素附着同帧面——两态对拍） ──

func _qb_bounce_attach() -> void:
	print("── qB 反弹弹命中：bounces 预算不动 + FIR 附着面（R15/§5.1 反弹行——两态对拍） ──")
	var runs := []
	for mode in 2:                              # 0=关态真值 / 1=boost 网格三开
		_field_reset()
		if mode == 0:
			_set_gates(-1, -1, -1)
		else:
			_set_gates(1, 1, 1)
		_drive(1)
		var e := _spawn_enemy(Vector2(360.0, 600.0), HP_BIG, true)
		var proj := _spawn_bullet(Vector2(360.0, 590.0), Vector2(0.0, 10.0),
			{"pierce": 999, "bounces": 2, "hitbox_radius": 6.0,
			"element": GameConst.Element.FIR, "attach_value": 50.0})
		_drive(1)
		var fir: float = -1.0
		if is_instance_valid(e) and e.elemental != null:
			fir = float(e.elemental.gauges[GameConst.Element.FIR])
		runs.append({
			"hp": e.hp, "dmg": _dmg_sum, "settles": _settle_n,
			"live": proj._live, "bounces": proj.bounces_left, "fir_gauge": fir,
		})
	_field_reset()
	_set_gates(-1, -1, -1)
	_check("qB 命中发生：settles==1 ∧ dmg>0（反弹弹网格路径正常结算）",
		runs[1]["settles"] == 1 and float(runs[1]["dmg"]) > 0.0, str(runs[1]))
	_check("qB 反弹预算不动：命中后弹存活 ∧ bounces_left==2（R15 敌命中不改反弹预算）",
		runs[1]["live"] == true and runs[1]["bounces"] == 2, str(runs[1]))
	_check("qB 元素附着同帧面：FIR gauge>0（④尾提交仍在 ⑤ 检测前——附着不丢）",
		float(runs[1]["fir_gauge"]) > 0.0, "fir=%s" % str(runs[1]["fir_gauge"]))
	_check("qB 两态对拍：关 ≡ 开 全项逐位（hp/dmg/反弹预算/附着量）",
		runs[0] == runs[1], "关=%s 开=%s" % [str(runs[0]), str(runs[1])])


# ── qJ：sim30 swept 收集（30Hz 弦判定口径——两态对拍补面） ──────────

func _qj_sim30_swept() -> void:
	print("── qJ sim30 swept：30Hz 弦判定收集制 ≡ 现状（高速弹穿越弦两态对拍） ──")
	var runs := []
	for mode in 2:
		_field_reset()
		GameLoop.SIM_30HZ_ENABLED = true
		GameLoop.sim30_override = -3            # 模拟 mobile（sim30_effective==true）
		if mode == 0:
			_set_gates(-1, -1, -1)
		else:
			_set_gates(1, 1, 1)
		_drive(1)
		var e := _spawn_enemy(Vector2(360.0, 700.0), HP_BIG)
		# 高速弹：单步弦长 3000×(2/60)=100px ≫ 敌命中窗（6+14=20px）——点判定会漏，
		# swept 弦判定必中（R233 T5 口径）——两态都应命中
		var proj := _spawn_bullet(Vector2(360.0, 550.0), Vector2(0.0, 3000.0),
			{"pierce": 1, "hitbox_radius": 6.0})
		_drive(6)
		runs.append({
			"hp": e.hp, "dmg": _dmg_sum, "settles": _settle_n,
			"gone": not (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles().has(proj),
		})
		GameLoop.SIM_30HZ_ENABLED = false
		GameLoop.sim30_override = -1
	_field_reset()
	_set_gates(-1, -1, -1)
	_check("qJ swept 收集：开态弦判定命中（settles==1 ∧ 弹穿透耗尽离场）",
		runs[1]["settles"] == 1 and runs[1]["gone"] == true, str(runs[1]))
	_check("qJ 两态对拍：关 ≡ 开 全项逐位（swept 判定口径 sweep 化零漂移）",
		runs[0] == runs[1], "关=%s 开=%s" % [str(runs[0]), str(runs[1])])


# ── qC1：关态帧头清残对缓冲（防跨帧幻影提交） ──────────────────────

func _qc1_off_framehead_buffer_clear() -> void:
	print("── qC1 关态帧头清：残对缓冲不跨帧提交（门翻转边界幻影对面） ──")
	# 正向对照：残对在开态直冲必须结算（证明残对构造有效——排除「构造无效假绿」）
	_field_reset()
	_set_gates(1, 1, 0)
	_drive(1)
	var e := _spawn_enemy(Vector2(360.0, 600.0), HP_BIG)
	var proj := _spawn_bullet(Vector2(360.0, 300.0), Vector2.ZERO,
		{"pierce": 3, "hitbox_radius": 6.0})
	_drive(1)                                   # 远距不相碰——零合法命中
	var s0 := _settles_total()
	GameLoop._hp_proj.append(proj)
	GameLoop._hp_target.append(e)
	GameLoop._hp_serial.append(proj.run_serial)
	GameLoop._flush_hit_pairs()
	_check("qC1 正向对照：开态直冲残对恰结 1（残对构造有效）",
		_settles_total() - s0 == 1 and float(e.hp) < HP_BIG,
		"结N+%d hpΔ=%.1f" % [_settles_total() - s0, HP_BIG - e.hp])
	# 边界面：同构造残对落在缓冲 → 门翻关 → 下帧 ④ 头清空、零提交
	_field_reset()
	_set_gates(1, 1, 1)
	_drive(1)
	var e2 := _spawn_enemy(Vector2(360.0, 600.0), HP_BIG)
	var proj2 := _spawn_bullet(Vector2(360.0, 300.0), Vector2.ZERO,
		{"pierce": 3, "hitbox_radius": 6.0})
	_drive(1)
	var s1 := _settles_total()
	GameLoop._hp_proj.append(proj2)
	GameLoop._hp_target.append(e2)
	GameLoop._hp_serial.append(proj2.run_serial) # 不冲刷——残对滞留跨「关门」边界
	_set_gates(0, 0, 0)                          # boost/网格/死亡全强关（用户关 perf_boost 同构）
	_drive(1)
	_check("qC1 关态帧头清：三缓冲清空 ∧ 残对零提交（跨帧幻影结算防住）",
		GameLoop._hp_proj.size() == 0 and GameLoop._hp_target.size() == 0 \
			and GameLoop._hp_serial.size() == 0 and _settles_total() - s1 == 0,
		"buf=%d/%d/%d 结N+%d" % [GameLoop._hp_proj.size(), GameLoop._hp_target.size(),
			GameLoop._hp_serial.size(), _settles_total() - s1])
	_drive(1)                                   # 再帧复验：无延迟爆
	_check("qC1 关态再帧：仍零提交（无延迟幻影爆）",
		_settles_total() - s1 == 0, "结N+%d" % (_settles_total() - s1))
	_field_reset()
	_set_gates(-1, -1, -1)


# ── qC2：门翻转残队复合时序（含 R66 看门狗交互——击杀 fan-out 永失观察） ──

func _qc2_gate_flip_residual_queue() -> void:
	print("── qC2 门翻转残队：关态滞留 → 看门狗强归还 → 复开冲刷守卫跳过（边界观察） ──")
	_field_reset()
	_set_gates(1, 1, 1)
	_drive(1)                                   # 闩门（death_flush_frame==true）
	var e := _spawn_enemy(Vector2(360.0, 600.0), 100.0)
	e.apply_damage(1.0e9)                       # 直杀（模拟 ⑤ 尾后入队——当前产品无此杀源）
	_check("qC2 入队：dead 即时 ∧ 队==1 ∧ emit==0（fan-out 待冲刷）",
		e.dead and GameLoop._death_queue.size() == 1 and _kill_n == 0,
		"队=%d emit=%d" % [GameLoop._death_queue.size(), _kill_n])
	_set_gates(0, 0, 0)                         # 翻关（不冲刷直接翻——边界态）
	_drive(1)
	_check("qC2 关态滞留：队仍==1 ∧ emit==0（关态零冲刷点——残队不过期）",
		GameLoop._death_queue.size() == 1 and _kill_n == 0,
		"队=%d emit=%d" % [GameLoop._death_queue.size(), _kill_n])
	_drive(66)                                  # 1.1s：R66 看门狗（1Hz）必扫——dead+visible 尸体强归还
	_check("qC2 看门狗交互：尸体被强归还（active 收窄）——fan-out 仍零执行",
		not _gl.spawner.active.has(e) and _kill_n == 0,
		"在场=%s emit=%d" % [str(_gl.spawner.active.has(e)), _kill_n])
	_set_gates(1, 1, 1)
	_drive(1)                                   # 复开：④ 尾冲刷残队
	_check("qC2 复开冲刷：队排空零崩溃 ∧ emit 仍 0（in-pool 守卫跳过——该杀 fan-out 永失："
		+ "xp/图鉴/击杀账全丢；当前产品无 ⑤ 尾后杀源=不可达，防御面按声明工作——观察项登记）",
		GameLoop._death_queue.is_empty() and _kill_n == 0,
		"队=%d emit=%d" % [GameLoop._death_queue.size(), _kill_n])
	_field_reset()
	_set_gates(-1, -1, -1)


# ── qC3：帧级缓存翻帧生效 + grid/death 两门独立裁定 ────────────────

func _qc3_frame_cache_latch() -> void:
	print("── qC3 帧级缓存：门翻转翻帧生效 + 两门独立裁定（〔v2·M2〕语义） ──")
	_set_gates(1, 1, 1)
	_drive(1)
	_check("qC3 三开闩门：grid_hit_frame ∧ death_flush_frame 同帧真",
		GameLoop.grid_hit_frame == true and GameLoop.death_flush_frame == true,
		"grid=%s death=%s" % [str(GameLoop.grid_hit_frame), str(GameLoop.death_flush_frame)])
	_set_gates(-1, -1, -1)                       # 全真值（boost 关）→ 翻帧生效
	_drive(1)
	_check("qC3 翻帧生效：复位后下一帧两缓存落假（帧级缓存非粘滞）",
		GameLoop.grid_hit_frame == false and GameLoop.death_flush_frame == false,
		"grid=%s death=%s" % [str(GameLoop.grid_hit_frame), str(GameLoop.death_flush_frame)])
	_set_gates(-1, 1, 0)                         # 独立裁定：boost 关 + 网格强开 + 死亡强关
	_drive(1)
	_check("qC3 独立裁定：grid 开 ∧ death 关（T1/T3 可独立裁定——override 压过真值）",
		GameLoop.grid_hit_frame == true and GameLoop.death_flush_frame == false,
		"grid=%s death=%s" % [str(GameLoop.grid_hit_frame), str(GameLoop.death_flush_frame)])
	_set_gates(-1, -1, -1)
	_drive(1)


# ── qD1：队中敌先归池（in-pool meta 守卫零 fan-out + 计数语义） ────

func _qd1_release_before_flush() -> void:
	print("── qD1 队中敌先归池：in-pool 守卫跳过 fan-out（R272 双 fan-out 防线独立复验） ──")
	_field_reset()
	_set_gates(1, 1, 1)
	_drive(1)
	var e := _spawn_enemy(Vector2(360.0, 600.0), 100.0)
	e.apply_damage(1.0e9)                       # 入队（不冲刷）
	_gl.spawner.active.erase(e)                 # 模拟先行收尸（erase → release 同看门狗序）
	(_gl.pools[&"enemy"] as EnemyPool).release(e)
	var f0 := int(GameLoop.deaths_flushed)
	GameLoop._flush_deaths()                    # 直调冲刷（④ 尾同函数）
	_check("qD1 in-pool 守卫：已归池敌零 fan-out（emit==0 ∧ 零崩溃）∧ 队排空",
		_kill_n == 0 and GameLoop._death_queue.is_empty(),
		"emit=%d 队=%d" % [_kill_n, GameLoop._death_queue.size()])
	_check("qD1 计数语义观察：deaths_flushed 仍按快照段 +1（跳过也计——P0 键口径非结算数，登记）",
		int(GameLoop.deaths_flushed) - f0 == 1,
		"冲刷计数 +%d" % (int(GameLoop.deaths_flushed) - f0))
	_set_gates(-1, -1, -1)


# ── qD2：对缓冲节点 free（is_instance_valid 守卫） ─────────────────

func _qd2_freed_proj_in_buffer() -> void:
	print("── qD2 对缓冲节点 free：is_instance_valid 守卫吸收（池外裸节点构造） ──")
	_field_reset()
	_set_gates(1, 1, 0)                         # 隔离 T1 面（死亡关——纯命中冲刷守卫）
	_drive(1)
	var e := _spawn_enemy(Vector2(360.0, 600.0), HP_BIG)
	var s0 := _settles_total()
	var ghost := (load(PROJ_SRC) as GDScript).new() as ProjectileBase   # 池外裸节点（不入树不入池）
	ghost._live = true
	ghost.run_serial = 777
	GameLoop._hp_proj.append(ghost)
	GameLoop._hp_target.append(e)
	GameLoop._hp_serial.append(777)
	ghost.free()                                # 冲刷前节点销毁（模拟极端释放序）
	GameLoop._flush_hit_pairs()
	_check("qD2 is_instance_valid 守卫：free 弹残对零结算零崩溃 ∧ 缓冲排空",
		_settles_total() - s0 == 0 and GameLoop._hp_proj.is_empty()
			and GameLoop._hp_serial.is_empty() and is_instance_valid(e)
			and is_equal_approx(float(e.hp), HP_BIG),
		"结N+%d buf=%d" % [_settles_total() - s0, GameLoop._hp_proj.size()])
	_field_reset()
	_set_gates(-1, -1, -1)


# ── qE：燃烧 DOT 杀同帧闭合（⑤ 尾冲刷点覆盖 DOT/反应杀——两态对拍） ──

func _qe_dot_kill_sameframe() -> void:
	print("── qE 燃烧 DOT 杀：⑤ 尾冲刷点同帧闭合（DOT 死不跨帧滞留——两态对拍） ──")
	var runs := []
	for mode in 2:                              # 0=关态真值 / 1=boost 网格死亡三开
		_field_reset()
		if mode == 0:
			_set_gates(-1, -1, -1)
		else:
			_set_gates(1, 1, 1)
		_drive(1)                               # 闩门
		var e := _spawn_enemy(Vector2(360.0, 600.0), 100.0, true)
		var st: ElementalState = e.elemental
		st.burn_timer = 5.0                     # 点燃（consume_dot_due 首查即到期——下帧 ⑤ 首跳）
		st.burn_layers = 1
		st.burn_snapshot_atk = 1.0e6            # 首跳 0.15×1e6=150k ≫ hp100 → 一跳必杀
		var dead_frame := -1
		for i in range(60):
			_drive(1)
			if e.dead:
				dead_frame = i
				break
		runs.append({
			"frame": dead_frame, "kills": _kill_n,
			"queue": GameLoop._death_queue.size(),
			"narrowed": not _gl.spawner.active.has(e),
		})
	_field_reset()
	_set_gates(-1, -1, -1)
	_drive(1)                                   # 帧缓存落假（qH 终检前提——门为帧级缓存）
	_check("qE DOT 杀发生：60 帧内首跳致死（两态皆然）",
		runs[0]["frame"] >= 0 and runs[1]["frame"] >= 0,
		"关帧=%s 开帧=%s" % [str(runs[0]["frame"]), str(runs[1]["frame"])])
	_check("qE 开态同帧闭合：死帧末 emit==1 ∧ 队空 ∧ spawner 已收窄（⑤ 尾冲刷——DOT 死零跨帧）",
		runs[1]["kills"] == 1 and runs[1]["queue"] == 0 and runs[1]["narrowed"] == true,
		str(runs[1]))
	_check("qE 两态对拍：死帧序逐位（DOT cadence 两态一致——确定性）",
		runs[0]["frame"] == runs[1]["frame"],
		"关帧=%s 开帧=%s" % [str(runs[0]["frame"]), str(runs[1]["frame"])])


# ── 收尾（盘档卫生断言 + 自清 + 注入口出厂态终检） ─────────────────

func _cleanup() -> void:
	if _metric_connected:
		EventBus.damage_resolved.disconnect(_on_damage_resolved)
		EventBus.enemy_killed.disconnect(_on_enemy_killed)
		_metric_connected = false
	# qF：盘档卫生——套件全程（含门翻转/池释放/看门狗/双态对拍）meta_save_test.cfg 零写盘
	#（全文件字节逐位）+ settings 段零漂移（全文件口径不用于收尾比对：套件击杀推内存
	# codex/成就计数——Meta._save 序列化全量元游戏状态（meta_manager.gd:1434-1462），
	# 自清重存的合法差只在 codex 段；settings 段才是「模式/门零盘档写」的承重面）
	var save_after := _read_save_bytes()
	_check("qF 盘档卫生：套件全程 meta_save_test.cfg 字节逐位不变（红线 5 模式关不写盘档）",
		save_after == _save_bytes_before,
		"前 %d B / 后 %d B" % [_save_bytes_before.size(), save_after.size()])
	# qH：注入口出厂态终检（各探针自复位后不应有残留）
	_check("qH 出厂态终检：三 override==-1 ∧ ip 短路关 ∧ 帧缓存假",
		GameLoop.grid_hit_override == -1 and GameLoop.death_flush_override == -1 \
			and PerfGovernor.boost_override == -1 and GameLoop.shortcircuit_ip_pass == false \
			and GameLoop.grid_hit_frame == false and GameLoop.death_flush_frame == false,
		"boost=%d grid=%d death=%d" % [PerfGovernor.boost_override,
			GameLoop.grid_hit_override, GameLoop.death_flush_override])
	if _gl != null and is_instance_valid(_gl):
		_set_gates(-1, -1, -1)
		GameLoop.shortcircuit_ip_pass = false
		GameLoop.prof_buckets_frame = false
		GameLoop.grid_hit_frame = false
		GameLoop.death_flush_frame = false
		GameLoop.SIM_30HZ_ENABLED = false
		GameLoop.sim30_override = -1
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
	Meta._settings = _saved_settings
	Meta._save()
	RunSave.clear()
	var save_final := _read_save_bytes()
	_check("qF 自清落盘：还原+重存后 settings 段与基线逐位（自清不引入设置面盘档漂移）",
		_settings_section_text(save_final) == _settings_section_text(_save_bytes_before),
		"基线=[%s] 终态=[%s]" % [_settings_section_text(_save_bytes_before),
			_settings_section_text(save_final)])
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])

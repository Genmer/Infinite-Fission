# tests/qa_r287qa_probe_cases.gd（R287 QA 独立探针用例体——入口运行时加载）
# 独立于开发套件（qa_r287_emptyquery 9 项 / qa_r286_diagkeys 13 项）的断言写法：
#   F 行格式冻结（正则整段法）：十五键「命提灭回ip 段和 弹网敌 跳玩特UI他派」连续
#      正则一次锁定键序+邻接；位序（渲峰ms 之后、尖峰标记/行尾之前）；十五键各恰一次；
#      MENU 态六新键==0（非 PLAYING 不累计契约）；口径声明头 R287 句在场。
#   R 含敌台架：真伤害→真跳字→popup 段 >0 真值（开发套件未断言面）；player/grid/enemy
#      段>0；段和 ≥ 九分键之和（R287 包含恒等式）；复位口十累计器归零+复驱复活；
#      1Hz 行上墙读数（弹/敌/跳/玩四键 >0——累计器→行打印链路活）。
#   S 第三位点（_tick_fast_player 预检 elif 门——开发套件只盖位点1/2）：
#      pfast 资格断言（trait_stack 注入 → _pfast==true ∧ 分区计数快N≥1——弹确走快路径）；
#      空场 boost 关（网格强关）零结算/零伤害/零冲刷对；有敌 boost 关命中常在；空场
#      boost 开（位点1 复核）零冲刷对；空场弹运动不受扰。
#   G 直驱单元探针（比整帧驱动更尖的等价边界）：位点1 _collect_hit_pairs 空网格零对
#      追加/有敌贴身恰+1 对；位点2 _check_collision 空网格零结算/有敌贴身恰+1 结算；
#      is_empty 真值链（rebuild 空→insert 补插→rebuild 空 + 真链驱动三态）。
# 夹具纪律（照 qa_r285_gridhit_cases 同款）：受控 PLAYING（无 start_run——wave 恒 IDLE）；
# 玩家钉桩 hp/xp 巨额；敌先 unregister_host 再 release（R253/R259）；字面量数组不直传
# Array[Node2D] 参数；盘档自清（Meta 快照整字典还原+_save 落盘，R272 教训）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const PLAYER_HOME := Vector2(360.0, 980.0)
const HP_BIG := 1.0e9
# 十五键尾段连续正则（键序+邻接一次锁定；\d+ 保证数值整形可解析）
const TAIL_PATTERN := "命µs(\\d+) 提µs(\\d+) 灭µs(\\d+) 回µs(\\d+) ipµs(\\d+) 段和µs(\\d+) 弹段µs(\\d+) 网段µs(\\d+) 敌段µs(\\d+) 跳段µs(\\d+) 玩段µs(\\d+) 特段µs(\\d+) UI段µs(\\d+) 他段µs(\\d+) 派段µs(\\d+)"
# R289 行尾十三键续段（十五键段之后、尖峰标记之前；F2 位序断言剥离用——同
# qa_r228_diagfreeze_cases.gd:171 第 11 次迁移协议，全量键强制在场）
const R289_PATTERN := "^ 武1µs(\\d+) 武2µs(\\d+) 武3µs(\\d+) 武4µs(\\d+) 武5µs(\\d+) 武6µs(\\d+) 武7µs(\\d+) 武8µs(\\d+) 武9µs(\\d+) 副武µs(\\d+) 深(\\d+) 武跳(\\d+) 弹拒(\\d+)"

var tree: SceneTree
var _gl: GameLoop = null
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _saved_settings: Dictionary = {}
var _dmg_sum: float = 0.0
var _settle_n: int = 0
var _metric_connected: bool = false
var _tail_re: RegEx
var _r289_re: RegEx


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_tail_re = RegEx.new()
	var cerr := _tail_re.compile(TAIL_PATTERN)
	if cerr != OK:
		print("FAIL | 探针正则编译失败：%s" % str(cerr))
		_fail += 1
	_r289_re = RegEx.new()
	var cerr289 := _r289_re.compile(R289_PATTERN)
	if cerr289 != OK:
		print("FAIL | R289 续段正则编译失败：%s" % str(cerr289))
		_fail += 1
	_saved_settings = Meta._settings.duplicate()      # 入口快照（收尾还原——磁盘不留测试痕）
	_boot()
	PerfGovernor.set_process(false)
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = 3
	PerfGovernor.boost_override = -1
	Meta.set_setting("fx_quality", 2)             # r230 先例：钉高防跨套件 user:// 残留漂门
	Meta.set_setting("damage_numbers_on", true)   # popup 真值前提（写口发信号——R202 直写盲区注记）
	_f_line_format()
	_setup_battle()
	_r_enemy_rig()
	_s_third_site()
	_g_direct_sites()
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


# ── boot / 夹具（gridhit 同款） ─────────────────────────────────────

func _boot() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R287QAProbe"
	tree.root.add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[r287qa] Boot 失败：%s" % str(_gl.boot_fatal))
		_fail += 1


func _setup_battle() -> void:
	# 受控战斗态（无 start_run——wave_director 恒 IDLE 零波次干扰，敌/弹全夹具注入）
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
	_field_reset()
	_clear_weapons()          # 受控面：唯一伤源=夹具弹（t1cd 同款）


func _on_damage_resolved(p_result) -> void:
	_dmg_sum += float(p_result.get("final_value"))
	_settle_n += 1


func _reset_metrics() -> void:
	_dmg_sum = 0.0
	_settle_n = 0


func _drive(p_frames: int) -> void:
	for i in range(p_frames):
		_gl._physics_process(DT)


func _spawn_enemy(p_pos: Vector2, p_hp: float) -> Enemy:
	var e := (_gl.pools[&"enemy"] as EnemyPool).acquire() as Enemy
	if e == null:
		return null
	e.bucket_host = (_gl.pools[&"enemy"] as EnemyPool).bucket_host
	var data: EnemyData = _gl.registry.get_enemy(&"E1_grunt")
	e.spawn(data, 1, 0)
	e.hp = p_hp
	e.global_position = p_pos
	_gl.spawner.active.append(e)
	return e


func _spawn_bullet(p_pos: Vector2, p_vel: Vector2, p_params: Dictionary = {}) -> ProjectileBase:
	var pool: ProjectilePool = _gl.pools[&"projectile"] as ProjectilePool
	var pb: ProjectileBase = pool.acquire(0)
	if pb == null:
		return null
	pb.damage_pipeline = _gl.pipeline
	pb.enemy_grid = _gl.enemy_grid
	pb.pool = pool
	pb.elemental = _gl.elemental
	var params := p_params.duplicate()
	params["position"] = p_pos
	params["velocity"] = p_vel
	params["team"] = 0
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


func _spawn_pfast_bullet(p_pos: Vector2, p_vel: Vector2) -> ProjectileBase:
	# 快路径资格弹：trait_stack 真件注入（空栈——无词条/无 ON_TICK 钩子/无 EF_SIZE）
	# ⇒ spawn 尾判据 _pfast==true ⇒ _tick_one_pool 分区走 _tick_fast_player（第三位点）。
	return _spawn_bullet(p_pos, p_vel, {
		"trait_stack": TraitStack.new(),
		"pierce": 1,
		"hitbox_radius": 6.0,
	})


func _field_reset() -> void:
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles().duplicate():
		(_gl.pools[&"projectile"] as ObjectPool).release(p)
	for e in _gl.spawner.active.duplicate():
		if is_instance_valid(e):
			_gl.elemental.unregister_host(e)
			(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_gl.spawner.active.clear()
	_gl.player.set("hp", 1.0e12)
	_gl.player.global_position = PLAYER_HOME
	_reset_metrics()


func _set_gates(p_boost: int, p_grid: int, p_death: int) -> void:
	PerfGovernor.boost_override = p_boost
	GameLoop.grid_hit_override = p_grid
	GameLoop.death_flush_override = p_death


func _settles_total() -> int:
	return int((_gl.pipeline.call(&"stats") as Dictionary).get("settles", 0))


func _clear_weapons() -> void:
	for i in range(_gl.player.weapon_slots.size()):
		var w = _gl.player.weapon_slots[i]
		if w != null and is_instance_valid(w):
			w.queue_free()
		_gl.player.weapon_slots[i] = null


func _push_sample_gate() -> void:
	# 1Hz 采样界推离（防 _diag_format_line 外的采样复位——直驱同步块无帧界，双保险）
	DebugStats._diag_last_ms = Time.get_ticks_msec()


func read_acc(p_acc: String) -> int:
	return int(_gl.get(p_acc))


# ── F：行格式冻结（正则整段法——MENU 态） ──────────────────────────

func _f_line_format() -> void:
	print("── F 行格式冻结（十五键连续正则——MENU 态） ──")
	_push_sample_gate()
	var line: String = DebugStats._diag_format_line(_gl, Time.get_ticks_msec())
	var m := _tail_re.search(line)
	_check("F1 十五键连续整段匹配（键序 命提灭回ip 段和 弹网敌 跳玩特UI他派 + 键间零夹带）",
		m != null, line.right(170))
	if m == null:
		return                      # 后续 F 项依赖捕获组——F1 红即止（已计 1 FAIL）
	var i_peak := line.rfind("渲峰ms")
	var rest := line.substr(m.get_end())
	# R289 续段剥离（十五键段尾 → 武1..武9/副武/深/武跳/弹拒 → 尖峰/行尾）
	var m289 := _r289_re.search(rest)
	var rest_after289 := rest
	if m289 != null:
		rest_after289 = rest.substr(m289.get_end())
	_check("F2 位序：十五键段起点在 渲峰ms 之后；段尾后仅允许 R289 十三键续段 + 尖峰 标记或行尾",
		i_peak >= 0 and m.get_start() > i_peak and m289 != null
			and (rest_after289.is_empty() or rest_after289.begins_with(" 尖峰")),
		"渲峰ms@%d 段起@%d 段后残='%s' 289残='%s'" % [i_peak, m.get_start(),
			rest.left(24), rest_after289.left(24)])
	var keys15 := ["命µs", "提µs", "灭µs", "回µs", "ipµs", "段和µs", "弹段µs", "网段µs",
		"敌段µs", "跳段µs", "玩段µs", "特段µs", "UI段µs", "他段µs", "派段µs"]
	var ok_once := true
	var d_once := ""
	for k in keys15:
		var n := line.count(" %s" % k)
		if n != 1:
			ok_once = false
			d_once += "%s×%d " % [k, n]
	_check("F3 十五键各恰出现一次（无重复、无键名互含碰撞）", ok_once, d_once)
	var ok_zero := true
	var d_zero := ""
	for gi in range(10, 16):
		var v := int(m.get_string(gi))
		if v != 0:
			ok_zero = false
		d_zero += "%s=%d " % [keys15[gi - 1], v]
	_check("F4 MENU 态 R287 六新键读数全 0（非 PLAYING 态窗不累计契约）", ok_zero, d_zero)
	var text := str((DebugStats.diag_export() as Dictionary).get("text", ""))
	_check("F5 口径声明头 R287 句在场（六键名序列原文）",
		text.contains("R287 键") and text.contains("跳段µs/玩段µs/特段µs/UI段µs/他段µs/派段µs"),
		"len=%d 首60=%s" % [text.length(), text.left(60)])


# ── R：含敌台架（段和包含恒等式 + popup 段>0 真值 + 上墙读数） ──────

func _r_enemy_rig() -> void:
	print("── R 含敌台架（boost 开热路径：段和包含恒等式 + popup>0 + 上墙） ──")
	_set_gates(1, 1, 1)
	_field_reset()
	_gl.stage_probe_enabled = true
	_gl.diag_reset_stage_win_sums()
	for i in range(6):
		_spawn_enemy(Vector2(220.0 + 50.0 * i, 300.0), HP_BIG)
	for f in range(90):
		if f % 10 == 0:
			_spawn_bullet(Vector2(200.0 + (f % 7) * 40.0, 80.0), Vector2(0.0, 520.0),
				{"pierce": 2, "hitbox_radius": 8.0})
		_gl._physics_process(DT)
	var popup_us := read_acc("_stage_win_popup_us")
	var player_us := read_acc("_stage_win_player_us")
	var fx_us := read_acc("_stage_win_fx_us")
	var ui_us := read_acc("_stage_win_ui_us")
	var other_us := read_acc("_stage_win_other_us")
	var dispatch_us := read_acc("_stage_win_dispatch_us")
	var sum_us := read_acc("_stage_win_sum_us")
	var proj_us := read_acc("_stage_win_proj_us")
	var grid_us := read_acc("_stage_win_grid_us")
	var enemy_us := read_acc("_stage_win_enemy_us")
	var nine_sum := proj_us + grid_us + enemy_us + popup_us + player_us + fx_us \
		+ ui_us + other_us + dispatch_us
	print("  窗读数µs：和=%d 弹=%d 网=%d 敌=%d 跳=%d 玩=%d 特=%d UI=%d 他=%d 派=%d（九键和=%d 残差=%d）"
		% [sum_us, proj_us, grid_us, enemy_us, popup_us, player_us, fx_us, ui_us,
			other_us, dispatch_us, nine_sum, sum_us - nine_sum])
	_check("R1 台架有效性：90 步内真结算>0（伤害链活——popup 断言的前提）",
		_settle_n > 0 and _dmg_sum > 0.0, "结=%d 伤=%.1f" % [_settle_n, _dmg_sum])
	_check("R2 popup 段>0 真值（真伤害→真跳字→跳字管线计时入账——开发套件未断言面）",
		popup_us > 0, "跳段=%dµs" % popup_us)
	_check("R3 玩/网/敌段>0（台架三基础段活）",
		player_us > 0 and grid_us > 0 and enemy_us > 0,
		"玩=%d 网=%d 敌=%d" % [player_us, grid_us, enemy_us])
	_check("R4 段和 ≥ 九分键之和（R287 六键 ⊆ 段和——包含恒等式，AC④）",
		sum_us >= nine_sum, "和=%d 九键和=%d" % [sum_us, nine_sum])
	# 复位口：十累计器归零 + 复驱复活（累计点在 PLAYING 帧入口——探针开着即再累计）
	_gl.diag_reset_stage_win_sums()
	var ok_zero := true
	for acc in ["_stage_win_sum_us", "_stage_win_proj_us", "_stage_win_grid_us",
			"_stage_win_enemy_us", "_stage_win_popup_us", "_stage_win_player_us",
			"_stage_win_fx_us", "_stage_win_ui_us", "_stage_win_other_us",
			"_stage_win_dispatch_us"]:
		if read_acc(acc) != 0:
			ok_zero = false
	_check("R5 复位口十累计器归零（diag_reset_stage_win_sums 扩展生效）", ok_zero, "")
	_drive(2)
	_check("R6 复位后复驱 2 步 → 段和复活 >0（累计点活——读走清零非死账）",
		read_acc("_stage_win_sum_us") > 0, "和=%d" % read_acc("_stage_win_sum_us"))
	# 上墙：复位后重新积累满窗（弹+敌+跳+玩四键须 >0）→ 1Hz 行捕获
	_gl.diag_reset_stage_win_sums()
	for f in range(90):
		if f % 10 == 0:
			_spawn_bullet(Vector2(200.0 + (f % 7) * 40.0, 80.0), Vector2(0.0, 520.0),
				{"pierce": 2, "hitbox_radius": 8.0})
		_gl._physics_process(DT)
	_push_sample_gate()
	var line: String = DebugStats._diag_format_line(_gl, Time.get_ticks_msec())
	var m := _tail_re.search(line)
	if m == null:
		_check("R7 1Hz 行上墙：十五键段匹配（PLAYING 行）", false, line.right(170))
	else:
		var wall_proj := int(m.get_string(7))
		var wall_enemy := int(m.get_string(9))
		var wall_popup := int(m.get_string(10))
		var wall_player := int(m.get_string(11))
		_check("R7 1Hz 行上墙读数：弹段µs/敌段µs/跳段µs/玩段µs 四键 >0（累计器→行链路活）",
			wall_proj > 0 and wall_enemy > 0 and wall_popup > 0 and wall_player > 0,
			"弹=%d 敌=%d 跳=%d 玩=%d" % [wall_proj, wall_enemy, wall_popup, wall_player])
	_gl.stage_probe_enabled = false


# ── S：第三位点（_tick_fast_player 预检 elif 门） ───────────────────

func _s_third_site() -> void:
	print("── S 第三位点（_tick_fast_player 预检 elif 门——boost 关快路径） ──")
	_check("S0a 快路径出厂开关 PLAYER_BULLET_FAST_PATH==true（产品默认）",
		GameLoop.PLAYER_BULLET_FAST_PATH == true, str(GameLoop.PLAYER_BULLET_FAST_PATH))
	# S1 空场 + boost 关（grid 强关 → grid_hit_frame=false → elif 预检门每帧执行）
	_set_gates(-1, 0, 0)
	_field_reset()
	var pfast_ok := true
	for i in range(6):
		var b := _spawn_pfast_bullet(PLAYER_HOME + Vector2(-120.0 + 48.0 * i, -80.0),
			Vector2(60.0, -420.0))
		if b == null or not b._pfast:
			pfast_ok = false
	var s0 := _settles_total()
	var f0 := int(GameLoop.hit_pairs_flushed)
	_drive(1)                                  # 分区计数快N 在帧内定型——驱动后才可读
	var pfast_live := int(_gl.diag_counts().get(&"pfast_live", -1))
	_check("S0b pfast 弹资格（trait_stack 注入 → _pfast==true ∧ 快N≥1——弹确走 _tick_fast_player）",
		pfast_ok and pfast_live >= 1, "资格=%s 快N=%d" % [str(pfast_ok), pfast_live])
	_drive(59)
	_check("S1 空场 boost 关：pfast 弹阵 60 步 → 零结算/零伤害/零冲刷对（elif 门空场直通等价）",
		_settle_n == 0 and _dmg_sum == 0.0 and _settles_total() == s0
			and int(GameLoop.hit_pairs_flushed) - f0 == 0,
		"结=%d 伤=%.1f 冲刷+%d" % [_settle_n, _dmg_sum,
			int(GameLoop.hit_pairs_flushed) - f0])
	# S2 有敌 + boost 关：elif 门非空放行 → 预检查询 → _check_collision(true) → 命中链
	_field_reset()
	var foe_pos := PLAYER_HOME + Vector2(120.0, -240.0)
	var foe := _spawn_enemy(foe_pos, HP_BIG)
	var ba := _spawn_pfast_bullet(foe_pos + Vector2(-6.0, 0.0), Vector2(30.0, 0.0))
	var bb := _spawn_pfast_bullet(foe_pos + Vector2(6.0, 0.0), Vector2(-30.0, 0.0))
	# 资格在驱动前捕获：命中后 pierce=1 耗尽 → 弹回收 _reset_state 清 _pfast（非缺陷）
	var ba_ok: bool = ba != null and ba._pfast
	var bb_ok: bool = bb != null and bb._pfast
	_drive(60)
	_check("S2 有敌 boost 关：pfast 弹贴身 → 结算>0（elif 门非空放行预检——真命中不丢）",
		ba_ok and bb_ok and _settle_n > 0,
		"结=%d 敌hp=%.0f" % [_settle_n, foe.hp])
	# S3 空场 + boost 开（位点1 复核：_collect_hit_pairs 早退——同弹型独立对拍）
	_set_gates(1, 1, 1)
	_field_reset()
	for i in range(6):
		_spawn_pfast_bullet(PLAYER_HOME + Vector2(-120.0 + 48.0 * i, -80.0),
			Vector2(60.0, -420.0))
	var f1 := int(GameLoop.hit_pairs_flushed)
	_drive(60)
	_check("S3 空场 boost 开：pfast 弹阵 60 步 → 零结算/零伤害/零冲刷对（位点1 boost 态复核）",
		_settle_n == 0 and _dmg_sum == 0.0 and int(GameLoop.hit_pairs_flushed) - f1 == 0,
		"结=%d 伤=%.1f 冲刷+%d" % [_settle_n, _dmg_sum,
			int(GameLoop.hit_pairs_flushed) - f1])
	# S4 空场弹运动不受扰（早退只在命中查询位点、不触 tick）
	_set_gates(-1, 0, 0)
	_field_reset()
	var mo := _spawn_pfast_bullet(PLAYER_HOME + Vector2(0.0, -60.0), Vector2(60.0, -420.0))
	var pos0: Vector2 = mo.global_position
	_drive(20)
	_check("S4 空场 pfast 弹 20 步位移 >100px（运动链不受早退扰动）",
		mo.global_position.distance_to(pos0) > 100.0,
		"位移=%.1f" % mo.global_position.distance_to(pos0))


# ── G：直驱单元探针（位点1/2 零副作用 + is_empty 真链） ────────────

func _g_direct_sites() -> void:
	print("── G 直驱单元探针（位点1/2 空场零副作用 + is_empty 真链） ──")
	_set_gates(-1, 0, 0)
	_field_reset()
	var grid := _gl.enemy_grid
	var empty_arr: Array[Node2D] = []          # 字面量不直传类型化参数——先落类型化变量
	# G3a 真值链（直调面）：rebuild 空 → 空上 insert 补插 → 再空（各自独立周期——契约内）
	grid.rebuild(empty_arr)
	var t1: bool = grid.is_empty()
	var probe_e := _spawn_enemy(Vector2(600.0, 600.0), HP_BIG)
	grid.rebuild(empty_arr)
	grid.insert(probe_e, grid.max_entity_radius())   # 波内补插路径（空快照上 insert）
	var t2: bool = (not grid.is_empty())
	grid.rebuild(empty_arr)
	var t3: bool = grid.is_empty()
	_check("G3a is_empty 真值链：rebuild([])→true / 空上insert(敌)→false / 再rebuild([])→true（快照唯一真源+帧间复位）",
		t1 and t2 and t3, "%s %s %s" % [str(t1), str(t2), str(t3)])
	# G3b 真链三态（④ 头实际 rebuild——非直调口径）
	_field_reset()
	_drive(1)
	var r1: bool = grid.is_empty()
	_spawn_enemy(Vector2(500.0, 600.0), HP_BIG)
	_drive(1)
	var r2: bool = (not grid.is_empty())
	_field_reset()
	_drive(1)
	var r3: bool = grid.is_empty()
	_check("G3b 真链三态：清场驱动→true / 有敌驱动→false / 再清→true（④ 实际重建同步空态）",
		r1 and r2 and r3, "%s %s %s" % [str(r1), str(r2), str(r3)])
	# G1 位点1 直驱：_collect_hit_pairs 空网格 → 对缓冲零追加；有敌贴身 → 恰+1 对
	_field_reset()
	GameLoop._hp_proj.clear()
	GameLoop._hp_target.clear()
	GameLoop._hp_serial.clear()
	var b1 := _spawn_bullet(Vector2(360.0, 500.0), Vector2.ZERO, {"hitbox_radius": 40.0})
	grid.rebuild(empty_arr)
	b1._collect_hit_pairs()
	var pairs_empty: bool = GameLoop._hp_proj.size() == 0
	var foe2 := _spawn_enemy(Vector2(360.0, 504.0), HP_BIG)
	var foe_arr: Array[Node2D] = [foe2]
	grid.rebuild(foe_arr)
	var b2 := _spawn_bullet(Vector2(360.0, 500.0), Vector2.ZERO, {"hitbox_radius": 40.0})
	b2._collect_hit_pairs()
	var pairs_after: int = GameLoop._hp_proj.size()
	_check("G1 位点1 直驱：空网格 _collect_hit_pairs 零对追加；有敌贴身恰+1 对（早退边界两侧）",
		pairs_empty and pairs_after == 1, "空后对数0=%s 有敌后=%d" % [str(pairs_empty), pairs_after])
	GameLoop._hp_proj.clear()
	GameLoop._hp_target.clear()
	GameLoop._hp_serial.clear()
	# G2 位点2 直驱：_check_collision 空网格 → 零结算；有敌贴身 → 恰+1 结算（即时链）
	_field_reset()
	GameLoop.grid_hit_frame = false
	var s0 := _settles_total()
	var b3 := _spawn_bullet(Vector2(360.0, 500.0), Vector2.ZERO, {"hitbox_radius": 40.0})
	grid.rebuild(empty_arr)
	b3._check_collision()
	var settles_after_empty: int = _settles_total() - s0
	var foe3 := _spawn_enemy(Vector2(360.0, 504.0), HP_BIG)
	var f_arr: Array[Node2D] = [foe3]
	grid.rebuild(f_arr)
	var b4 := _spawn_bullet(Vector2(360.0, 500.0), Vector2.ZERO, {"hitbox_radius": 40.0})
	b4._check_collision()
	var settles_after_foe: int = _settles_total() - s0
	_check("G2 位点2 直驱：空网格 _check_collision 零结算；有敌贴身恰+1 结算（通用路径即时链活）",
		settles_after_empty == 0 and settles_after_foe == 1,
		"空后+%d 有敌后+%d" % [settles_after_empty, settles_after_foe])
	GameLoop._hp_proj.clear()
	GameLoop._hp_target.clear()
	GameLoop._hp_serial.clear()


# ── 收尾（gridhit 同款纪律） ───────────────────────────────────────

func _cleanup() -> void:
	if _metric_connected:
		EventBus.damage_resolved.disconnect(_on_damage_resolved)
		_metric_connected = false
	if _gl != null and is_instance_valid(_gl):
		_gl.stage_probe_enabled = false
		_set_gates(-1, -1, -1)
		GameLoop.shortcircuit_ip_pass = false
		GameLoop.prof_buckets_frame = false
		GameLoop.grid_hit_frame = false
		GameLoop.death_flush_frame = false
		GameLoop.SIM_30HZ_ENABLED = false
		GameLoop.sim30_override = -1
		GameLoop._hp_proj.clear()
		GameLoop._hp_target.clear()
		GameLoop._hp_serial.clear()
		PerfGovernor.boost_override = -1
		PerfGovernor.mode_override = -1
		PerfGovernor.tier_override = -1
		PerfGovernor.tier = 3
		PerfGovernor.set_process(true)
		PerfGovernor._test_reset()
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

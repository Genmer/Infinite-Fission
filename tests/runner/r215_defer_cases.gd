# tests/runner/r215_defer_cases.gd
# R215 用例体：延迟开窗（刀A）+ ②段即时吸收帽（刀B）+ 菜单分帧贴图预热（刀C）+
# 桶/磁片遥测（刀D）。
# 背景（vc22 真机定案，FEEDBACK_TRACKER 二d）：
#   刀A：选卡窗磁尖峰 183ms=吸收链内同步开窗级联（gain_xp→emit→_open_card_flow）
#        ——PLAYING 期升级只记档，帧尾（⑧后）开窗归 UI 键。
#   刀B：玩段尖峰 119ms=波末死亡堆②段非磁吸片圈内即时吸收（pickup.tick:181 当帧
#        转磁吸即收）不经帽——并入 24/帧帽（QA DEF-3 收口）。
#   刀C：开局弹 173ms / 敌段 57-96ms=首次登场贴图变体战斗帧内惰性生成——boot 建
#        队（零生成，boot 集中实测 6.8s 超预算）+ MENU 态 12ms/帧消化。
#   刀D：diag 行加 桶e+p（E' 合批健康度）/ 磁（磁键尖峰负载基数）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const PLAYER_HOME := Vector2(360.0, 900.0)
const DT := 1.0 / 60.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_test_1_deferred_open()
	_enter_run_frozen()
	_test_2_stage2_instant_absorb_cap()
	_test_3_menu_tex_prewarm()
	_test_4_diag_telemetry()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])


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


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R215GameLoopUnderTest"
	tree.get_root().add_child(_gl)


func _enter_run_frozen() -> void:
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.state = GameConst.GameStatus.MENU
	_gl.player.global_position = PLAYER_HOME


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


# ── ① 刀A：升级开窗延迟（记档/消费/排队/批路径/GAME_OVER/跨局清） ──
func _test_1_deferred_open() -> void:
	print("── ① 延迟开窗 ──")
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_check("前置：PLAYING", _gl.state == GameConst.GameStatus.PLAYING, "state=%d" % _gl.state)
	var lv0: int = _gl.player.level
	_gl.player.gain_xp(_gl.player.xp_need)
	_check("同帧不开窗（state 仍 PLAYING + 记档）",
		_gl.state == GameConst.GameStatus.PLAYING
			and int(_gl.get("_deferred_level_open")) >= 0,
		"state=%d deferred=%s" % [_gl.state, str(_gl.get("_deferred_level_open"))])
	_gl.player.gain_xp(_gl.player.xp_need * 2.0)
	_check("同帧后续升级走排队帽（pending≥1）",
		int(_gl.pending_level_ups) >= 1, "pending=%d" % _gl.pending_level_ups)
	_gl.stage_probe_enabled = true
	_gl.call(&"_consume_deferred_level_open")
	# R216 刀②契约更新：开窗级联归「卡」键（与 UI 键分离归因——vc24 读数粒度）
	# R220 刀1 键名同步：卡键拆分后开窗归 card_open（拆解契约 §3.1 冻结名）
	_check("帧尾消费开窗（LEVEL_UP + 窗开 + 卡开键归因）",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open
			and _gl.stage_probe_us.has(&"card_open"),
		"state=%d open=%s" % [_gl.state, str(_gl.card_select_ui.is_open)])
	_gl.stage_probe_enabled = false
	_gl.card_select_ui.choose(0)
	_check("选卡恢复 PLAYING（queued 窗链完好）",
		_gl.state == GameConst.GameStatus.PLAYING or _gl.card_select_ui.is_open,
		"state=%d" % _gl.state)
	while _gl.state == GameConst.GameStatus.LEVEL_UP:
		_gl.card_select_ui.choose(0)
	# GAME_OVER 同帧：开窗作废计数
	_gl.state = GameConst.GameStatus.MENU
	_gl.start_run()
	# QA-R215-DEF-1：kill 走 take_contact_damage 可被格挡/复活词条拦截（卡牌 offer 未
	# 种子化随机）→ 40% flaky。死亡仲裁丢弃口径只依赖态=GAME_OVER——强制合法迁移
	# （PLAYING→GAME_OVER 迁移矩阵合法行），确定性直达。
	_check("前置：GAME_OVER（强制合法迁移）",
		_gl.change_state(GameConst.GameStatus.GAME_OVER),
		"state=%d" % _gl.state)
	var drop0: int = _gl.dropped_level_ups
	_gl.player.gain_xp(_gl.player.xp_need * 100.0)
	_gl.call(&"_consume_deferred_level_open")
	_check("GAME_OVER 期升级丢弃（dropped 增加，不开窗）",
		_gl.dropped_level_ups > drop0
			and _gl.state == GameConst.GameStatus.GAME_OVER,
		"drop %d→%d state=%d" % [drop0, _gl.dropped_level_ups, _gl.state])
	# 跨局陈旧档清除（B 组直调 _on_level_up 残留场景复刻）
	_gl.quit_to_menu()
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.call(&"_on_level_up", 2)               # 不消费——模拟测试中途弃档残留
	_check("陈旧档存在（前置）", int(_gl.get("_deferred_level_open")) >= 0, "")
	_gl.quit_to_menu()
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_check("start_run 清陈旧档（跨局零泄漏）",
		int(_gl.get("_deferred_level_open")) == -1,
		"deferred=%s" % str(_gl.get("_deferred_level_open")))
	_gl.state = GameConst.GameStatus.MENU


# ── ② 刀B：死亡堆即时吸收帽（非磁吸片圈内当帧转吸） ──────────────
func _test_2_stage2_instant_absorb_cap() -> void:
	print("── ② 即时吸收帽 ──")
	_gl.state = GameConst.GameStatus.PLAYING
	_gl.player.global_position = PLAYER_HOME
	var pool := _gl.pools[&"xp"] as XPPool
	var shards: Array = _gl.get("active_shards")
	shards.clear()
	var total := 0.0
	for i in range(160):
		var s: XpShard = pool.acquire()
		if s == null:
			break
		s.activate(1.0, 0.0)                 # 先激活（内含一次性出生散射）
		s.global_position = _gl.player.global_position + Vector2(1.0, 0.0)   # 后落位（圈内 <24px）
		shards.append(s)
		total += 1.0
	_check("死亡堆夹具（160 非磁吸圈内片）", shards.size() == 160 and not (shards[0] as XpShard).is_magnet(),
		"n=%d" % shards.size())
	var acc := [0.0]                          # lambda 按值捕获 → 数组容器累加
	var on_xp := func(p_amount: float) -> void: acc[0] += p_amount
	EventBus.xp_gained.connect(on_xp)
	_gl.call(&"_tick_xp_shards", DT)          # 单帧
	var after_first: int = shards.size()
	_check("②段单帧即时吸收帽 24（160 片只收 %d）" % (160 - after_first),
		160 - after_first == 24, "left=%d absorbed=%d" % [after_first, 160 - after_first])
	for f in range(40):                       # 多帧全收
		_gl.call(&"_tick_xp_shards", DT)
	EventBus.xp_gained.disconnect(on_xp)
	_check("多帧全部吸收 + 面值守恒",
		shards.is_empty() and is_equal_approx(acc[0], total),
		"left=%d gained=%f total=%f" % [shards.size(), acc[0], total])
	_gl.state = GameConst.GameStatus.MENU


# ── ③ 刀C：菜单分帧贴图预热（建队/预算消化/真源覆盖） ────────────
func _test_3_menu_tex_prewarm() -> void:
	print("── ③ 菜单贴图预热 ──")
	var q: Array = _gl.get("_tex_prewarm_queue")
	_check("boot 建队（≥25 项：共享拆粒+kind+特殊脸+boss 双面）", q.size() >= 25,
		"queue=%d" % q.size())
	var size0: int = q.size()
	_gl.state = GameConst.GameStatus.MENU
	# R215 修：①②期间 MENU 帧已消化常规段、队首可能已抵 boss 段（挂机门正确
	# 暂停=净减 0）——置 dwell≥阈值验预算消化路径；门行为由下方专测覆盖。
	# R222 Fix P 契约迁移：重项超预算折臂跳帧（跳帧帧零消化）——本断言锁「预算消化
	# 路径」，先清占空余额隔离（占空行为由 r222_runrearm ② 承接）
	# R244 冲刷桶批迁移：预热消费在渲染轴 _process（原 _physics_process MENU 臂）
	_gl.set("_menu_dwell_s", 99.0)
	_gl.set("_tex_prewarm_skip", 0)
	_gl._process(DT)                       # MENU 态渲染帧：12ms 预算消化
	var size1: int = (_gl.get("_tex_prewarm_queue") as Array).size()
	_check("MENU 渲染帧消化（队列净减 ≥1）", size1 < size0, "%d→%d" % [size0, size1])
	# R215 修：boss 双面挂机门——先消化常规段（dwell 归零后 <3s），队首抵 boss 项时
	# 单帧应暂停（不丢项不消化）；随后置 dwell≥阈值放行全量清队
	# （R222 Fix P：循环内逐帧清占空余额——本循环锁门/清队语义不锁占空节奏）
	_gl.set("_menu_dwell_s", 0.0)
	while not (_gl.get("_tex_prewarm_queue") as Array).is_empty() \
			and not String(((_gl.get("_tex_prewarm_queue") as Array)[0] as Dictionary).get(&"kind", &"")).begins_with("boss"):
		_gl.set("_tex_prewarm_skip", 0)
		_gl._process(DT)
	var q_at_boss: Array = _gl.get("_tex_prewarm_queue")
	if not q_at_boss.is_empty():
		var boss_cnt_pre: int = q_at_boss.size()
		_gl.set("_tex_prewarm_skip", 0)
		_gl._process(DT)                    # dwell=0 <3s（渲染帧不累计 dwell）→ boss 项不出队
		_check("boss 挂机门（dwell<3s 队首 boss 项暂停）",
			(_gl.get("_tex_prewarm_queue") as Array).size() == boss_cnt_pre,
			"%d" % boss_cnt_pre)
		_gl.set("_menu_dwell_s", 99.0)
		while not (_gl.get("_tex_prewarm_queue") as Array).is_empty():
			_gl.set("_tex_prewarm_skip", 0)   # R222 Fix P：逐帧清臂（锁清队语义不锁占空）
			_gl._process(DT)
		_check("预算循环清队（全变体在缓存）",
			(_gl.get("_tex_prewarm_queue") as Array).is_empty(), "")
	var cache: Dictionary = TextureFactory._cache
	# R215 修：剔死键 enemy_elite_false/bastion（生产无消费方），补真键 armor 两态+crown
	for k in ["enemy_grunt_false", "enemy_volatile_scared_false", "enemy_boss1_true",
			"enemy_bastion_core_false", "enemy_bastion_armor_false",
			"enemy_bastion_armor_cracked_false", "crown"]:
		_check("预热覆盖真源键（%s）" % k, cache.has(k), "")
	# R216 契约更新：白体星（star_44_ffffffff）无消费方已除——预热表改碎片变体
	#（4 档×3 量化 alpha；此处抽查 tier0 档底=白档色×alpha0.5 八位键）
	var t0c := PopPalette.xp_tier_color(0)
	t0c.a = 0.5
	_check("共享域预热（碎片变体抽查 tier0 档底，to_html 八位口径）",
		cache.has("star_44_" + t0c.to_html()),
		str(cache.keys().size()))
	# QA-R215-DEF-2 修正：TAG_BOSS=2（原 1<<0=TAG_ELITE 使断言恒真）——单操作数锁死
	var ed := EnemyData.new()
	ed.id = &"E17_boss_ice"
	_check("visual_kind_for：TAG_BOSS → boss4", Enemy.visual_kind_for(ed, GameConst.TAG_BOSS) == &"boss4", "")
	ed.id = &"E4_boomer"
	_check("visual_kind_for：E4 前缀 → volatile", Enemy.visual_kind_for(ed, 0) == &"volatile", "")


# ── ④ 刀D：桶/磁片遥测 ──────────────────────────────────────────
func _test_4_diag_telemetry() -> void:
	print("── ④ 遥测 ──")
	var counts: Dictionary = _gl.diag_counts()
	_check("diag_counts 新键（桶e/桶p/磁片）",
		counts.has(&"bucket_enemy") and counts.has(&"bucket_projectile")
			and counts.has(&"magnet_shards"),
		str(counts.keys()))
	_check("菜单态基数（桶 0/磁 0）",
		int(counts[&"bucket_enemy"]) == 0 and int(counts[&"magnet_shards"]) == 0,
		"e=%d m=%d" % [int(counts[&"bucket_enemy"]), int(counts[&"magnet_shards"])])
	_enter_run_frozen()
	_gl.state = GameConst.GameStatus.PLAYING
	var ehost: Node = (_gl.pools[&"enemy"] as ObjectPool).bucket_host
	var epool := _gl.pools[&"enemy"] as EnemyPool
	var e1 := epool.acquire() as Enemy
	e1.bucket_host = ehost
	var d := EnemyData.new()
	d.id = &"E1_grunt"
	d.hp_base = 100.0
	d.spd_base = 0.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	e1.spawn(d, 1, 0)
	var counts2: Dictionary = _gl.diag_counts()
	_check("spawn 后桶计数 ≥1（E' 健康度口上线）",
		int(counts2[&"bucket_enemy"]) >= 1, "e=%d" % int(counts2[&"bucket_enemy"]))
	epool.release(e1)
	_gl.state = GameConst.GameStatus.MENU

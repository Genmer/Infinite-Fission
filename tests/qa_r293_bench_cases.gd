# tests/qa_r293_bench_cases.gd（R293 headless 深载模拟基准台架用例体——入口运行时加载）
# 口径（如实登记——夹具范式照抄 qa_r271_deeprepro_cases.gd，只量模拟轴）：
# · 场景：start_run 后 state 恒 PLAYING；boost_override=1（促1 深载态）+ mode_override=0
#   （帧率优先）+ tier_override=2 + deep_override=0（R289 深载三刀强关——受控原始负载
#   对照口径，r271 同款；本台架不动任何注入口/短路面）。
# · 负载：敌 90 池化驻场（grove 波表 w16 构成平铺池 + 补位 8/帧，HP ×0.3 压血复本）
#   + team-0 活弹 448 顶格（W2 加特林 L5 五词条真开火通道 + 池直注填充弹补位
#   ≤24/帧——r271「弹 ≥420 量级断言」同款）。
# · 驱动：固定 seed、直驱 _gl._physics_process(1/60) 紧循环（probe_r224_deepload 同款
#   ——绕开引擎帧泵/渲染相，只量模拟轴）；180 步预热 + N=600 步测量，每步维护夹具
#   （风筝/敌补位/弹补位——均在计时区外）。
# · 计时：Time.get_ticks_usec 只包住整步直调（total=每步墙钟均值）；段读数=stage_probe_us
#   段探针（game_loop 段计时口径，stage_probe_enabled=true）：
#     player    = ② 玩段全量（stage_probe_us[&"player"]——输入+player.tick+碎片+连杀）
#     projectile= ④ 弹段（&"grid_projectile"——双网格重建+弹 tick+命/死冲刷）
#     enemy     = ⑤ 敌段（&"enemy"——敌 AI+元素 tick+软分离）
#     weapons   = ② 内火段（&"player_wp"=Player.probe_weapons_us——四组武器调度，
#                 game_loop ② 段拆键，R217 刀C）
# · 输出契约（逐字，每步均值 ms，%.3f）：
#     BENCH|total|<ms> / BENCH|player|<ms> / BENCH|projectile|<ms> /
#     BENCH|enemy|<ms> / BENCH|weapons|<ms>
# · 轻量 sanity（保证量的是真负载）：全程 state=PLAYING / 敌驻场 ≥85 / team-0 活弹
#   ≥420（驻场门口径=r271 M4 门① 同款：补位后 standing count 每步采样；单步击杀
#   瞬时缺口由补位节流回填，属夹具 churn 非驻场失效——补位前下探另册披露不设门）/
#   命中对数增量 >0（GameLoop.hit_pairs_flushed——促1 下 T1 网格命中在账）/
#   玩家位置变化（风筝轨道）/ 四段探针全窗在账。
# · 禁锚定渲染节点内部结构：全部经池/spawner/player 公共 API（第二批渲染合批后台架
#   必须仍可跑）；不改任何游戏代码。headless 无渲染/无 GPU——绝对 ms 桌面口径，
#   真机对照按 R224 修正（≈×0.5-2）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GROVE_TABLE := "res://resources/maps/wave_table_grove.tres"
const DT60 := 1.0 / 60.0
const HOLD := 90                         # 敌驻场（vc79 深载敌 90 帽——r271 同款）
const TARGET_BULLETS := 448              # team-0 活弹顶格（vc79 弹 448 观测峰——r271 同款）
const BULLET_FLOOR := 420                # 弹下限（r271 M4 门① 同款）
const ENEMY_FLOOR := 85                  # 敌下限（r271 M4 门① 同款）
const WARMUP_STEPS := 180                # 预热（加特林 spin_up 2s + 弹/敌稳态——r271 帧数同款）
const MEASURE_STEPS := 600               # N=600 直驱测量步（契约）
const TOPUP_PER_FRAME := 8               # 敌补位节流（SPAWN_PER_FRAME 同款）
const BULLET_TOPUP_CAP := 24             # 弹补位/帧帽（r271 同款）
const ENEMY_HP_SCALE := 0.3
const PLAYER_HOME := Vector2(360.0, 900.0)

var tree: SceneTree
var _gl: GameLoop = null
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _comp: Array[Dictionary] = []        # 平铺构成池 {data: EnemyData, tags: int}
var _cursor: int = 0
var _min_enemies: int = 99999
var _min_bullets: int = 99999
var _dip_enemies: int = 99999            # 补位前下探（披露读数——单步击杀瞬时尖峰）
var _dip_bullets: int = 99999            # 同上（弹侧）
var _left_playing: bool = false          # 状态看门狗（预热+测量全程）
var _saved_settings: Dictionary = {}     # Meta 快照（收尾 R270 盘档毒配方还原）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261024)
	_saved_settings = Meta._settings.duplicate()
	print("══ R293 深载模拟基准：敌90 驻场 + 弹448 顶格 + boost 促1 + 直驱 %d 步（只量模拟轴） ══" % MEASURE_STEPS)
	if not _boot():
		await _teardown()
		return
	_left_playing = false
	_warmup()
	var res := _measure()
	_report(res)
	await _teardown()


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


# ── boot（夹具照抄 qa_r271_deeprepro_cases._boot——只裁掉与基准无关的诊断面） ──

func _boot() -> bool:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R293Bench"
	tree.root.add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[bench] Boot 失败：%s" % str(_gl.boot_fatal))
		_fail += 1
		return false
	PerfGovernor.set_process(false)       # 调速器冻结采样（r271/r224 同款）
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	PerfGovernor.boost_override = 1       # 促1：85% 保帧深载态（vc79 配置面）
	PerfGovernor.deep_override = 0        # R289 深载三刀强关（注入口 0——受控原始负载，r271 同款）
	_gl.current_map_id = &"world_grove"
	if not _gl.start_run():
		push_error("[bench] start_run 失败")
		_fail += 1
		return false
	# 台架保活（r271 v4 同款：hard_cap 9999s 永不到点 + 敌 90 驻场 → 清空检测/通关支路死）
	_gl.wave_director.set("_hard_cap_left", 9999.0)
	_gl.player.set("xp_need", 1.0e12)     # 防开窗（选卡=暂停态正交项）
	_gl.player.set("max_hp", 1.0e12)
	_gl.player.set("hp", 1.0e12)
	_gl.player.unlocked_slots = 6
	_gl.player.global_position = PLAYER_HOME
	var gatling: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	if gatling == null:
		push_error("[bench] W2 装配失败")
		_fail += 1
		return false
	gatling.level = 5
	var attached := 0
	for t in [["AFF_PIERCE", 3], ["AFF_MULTI", 2], ["MEC_BOUNCE", 3], ["MEC_KILL_BLAST", 2], ["MEC_FRACTAL", 2]]:
		var td: TraitData = _gl.registry.get_trait(StringName(t[0]))
		for i in range(int(t[1])):
			if gatling.attach_trait(td):
				attached += 1
	_check("boot 构筑挂载：W2 L5 五词条 12/12", attached == 12, "attached=%d/12" % attached)
	_gl.stage_probe_enabled = true        # 段探针在账（BENCH 段行读数源——r224 同款）
	if not _load_composition():
		return false
	print("boot：grove w16 构成 %d 敌种池，压血×%.2f；W2 L5 五词条；boost_override=1（deep 强关）" % [
		_comp.size(), ENEMY_HP_SCALE])
	return true


func _load_composition() -> bool:
	var tbl: Resource = load(GROVE_TABLE)
	if tbl == null or not ("entries" in tbl):
		push_error("[bench] 波表加载失败：%s" % GROVE_TABLE)
		_fail += 1
		return false
	var entry: Resource = null
	for e in tbl.get("entries"):
		if int(e.get("index")) == 16:
			entry = e
			break
	if entry == null:
		push_error("[bench] grove 波表无 index==16 条目")
		_fail += 1
		return false
	for c in entry.get("composition"):
		var src: EnemyData = _gl.registry.get_enemy(StringName(c.get("enemy_id")))
		if src == null:
			push_error("[bench] 敌数据缺失：%s" % str(c.get("enemy_id")))
			_fail += 1
			return false
		var data: EnemyData = src.duplicate()   # 压血复本（仅台架持有，注册表真件不动）
		data.hp_base = data.hp_base * ENEMY_HP_SCALE
		var tags := int(c.get("tags", 0))
		for i in range(int(c.get("count", 1))):
			_comp.append({"data": data, "tags": tags})
	_comp.shuffle()
	return true


# ── 夹具维护（每步计时区外执行——r271 _on_phys_frame 同款面） ────────

func _kite(p_i: int) -> void:
	# 风筝轨迹（r271/r224 同款）：玩家绕屏心慢速环绕——敌群尾随成团、弹幕有飞行距离
	var ang := float(p_i) * 0.35 / 60.0
	_gl.player.global_position = Vector2(360.0 + cos(ang) * 140.0,
		660.0 + sin(ang) * 200.0)


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


func _topup_enemies() -> void:
	var alive: int = _gl.spawner.active.size()
	var want: int = mini(TOPUP_PER_FRAME, HOLD - alive)
	for i in range(want):
		_spawn_one()


func _team0_bullets() -> int:
	var n := 0
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		var pb := p as ProjectileBase
		if pb != null and pb.team == 0:
			n += 1
	return n


func _inject_filler_bullet() -> void:
	# 池直注填充弹（r271 同款）：依赖注入照 ballistic_weapon 四字段；0 伤快照 + 环带
	# 布点（风筝轨道外圈 r∈[320,380]——命中面≈0，杀敌面留给真开火通道）
	var pool: ProjectilePool = _gl.pools[&"projectile"] as ProjectilePool
	var pb: ProjectileBase = pool.acquire(0)
	if pb == null:
		return
	pb.damage_pipeline = _gl.pipeline
	pb.enemy_grid = _gl.enemy_grid
	pb.pool = pool
	pb.elemental = _gl.elemental
	var ang := randf() * TAU
	var r := randf_range(320.0, 380.0)
	pb.spawn({
		"position": Vector2(clampf(360.0 + cos(ang) * r, 16.0, 704.0),
			clampf(660.0 + sin(ang) * r, 16.0, 1264.0)),
		"velocity": Vector2.from_angle(randf() * TAU) * randf_range(2.0, 12.0),
		"lifetime": 9.0, "pierce": 24, "bounces": 0,
		"hitbox_radius": 2.0, "team": 0,
	})


func _maintain(p_i: int) -> void:
	_kite(p_i)
	if int(_gl.state) != GameConst.GameStatus.PLAYING:
		_left_playing = true
	if p_i % 120 == 0:
		_gl.wave_director.set("_hard_cap_left", 9999.0)   # 保活复钉（r271 _arm 同款）
	var enemies_pre: int = _gl.spawner.active.size()
	var bullets_pre := _team0_bullets()
	_dip_enemies = mini(_dip_enemies, enemies_pre)       # 补位前下探（另册披露，不设门）
	_dip_bullets = mini(_dip_bullets, bullets_pre)
	_topup_enemies()
	var want := mini(TARGET_BULLETS - bullets_pre, BULLET_TOPUP_CAP)
	for i in range(want):
		_inject_filler_bullet()
	# 驻场门采样口径=r271 M4 门① 同款：补位后 standing count（单步击杀瞬时缺口由补位
	# 节流回填——瞬时尖峰属夹具 churn 非驻场失效；补位前下探另册披露）
	_min_enemies = mini(_min_enemies, _gl.spawner.active.size())
	_min_bullets = mini(_min_bullets, _team0_bullets())


# ── 驱动与测量（直驱紧循环——r224 _scenario 同款；total 只包整步直调） ──

func _warmup() -> void:
	print("预热：%d 直驱步（spin_up/弹/敌稳态）" % WARMUP_STEPS)
	for i in range(WARMUP_STEPS):
		_maintain(i)
		_gl._physics_process(DT60)


func _measure() -> Dictionary:
	print("测量窗：%d 直驱步（Time.get_ticks_usec 只包整步直调；段读数=stage_probe_us 逐帧采）" % MEASURE_STEPS)
	_min_enemies = 99999
	_min_bullets = 99999
	_dip_enemies = 99999
	_dip_bullets = 99999
	var hit0 := int(GameLoop.hit_pairs_flushed)
	var death0 := int(GameLoop.deaths_flushed)
	var pos0: Vector2 = _gl.player.global_position
	var totals: Array[float] = []         # 每步整步墙钟 ms
	var seg_acc := {&"player": 0, &"grid_projectile": 0, &"enemy": 0, &"player_wp": 0}
	var seg_n := {&"player": 0, &"grid_projectile": 0, &"enemy": 0, &"player_wp": 0}
	for i in range(MEASURE_STEPS):
		_maintain(i)
		var t0 := Time.get_ticks_usec()
		_gl._physics_process(DT60)
		var wall_us := Time.get_ticks_usec() - t0
		totals.append(float(wall_us) / 1000.0)
		for k in seg_acc:
			if _gl.stage_probe_us.has(k):
				seg_acc[k] = int(seg_acc[k]) + int(_gl.stage_probe_us[k])
				seg_n[k] = int(seg_n[k]) + 1
	if int(_gl.state) != GameConst.GameStatus.PLAYING:   # 末步内离场兜底（pre-step 采样补漏）
		_left_playing = true
	return {
		"totals": totals,
		"seg_acc": seg_acc, "seg_n": seg_n,
		"hit_pairs": int(GameLoop.hit_pairs_flushed) - hit0,
		"deaths": int(GameLoop.deaths_flushed) - death0,
		"pos_delta": _gl.player.global_position.distance_to(pos0),
		"min_enemies": _min_enemies, "min_bullets": _min_bullets,
		"dip_enemies": _dip_enemies, "dip_bullets": _dip_bullets,
		"left_playing": _left_playing,
	}


func _seg_ms(p_res: Dictionary, p_key: StringName) -> float:
	var n := int((p_res["seg_n"] as Dictionary).get(p_key, 0))
	if n <= 0:
		return 0.0
	var acc := int((p_res["seg_acc"] as Dictionary).get(p_key, 0))
	return float(acc) / float(n) / 1000.0


func _report(p_res: Dictionary) -> void:
	print("── 读数（每步均值 ms/步，N=%d 直驱步；headless 桌面口径，真机≈×0.5-2〔R224 修正〕） ──" % MEASURE_STEPS)
	print("fixture：敌min=%d（补位前下探%d） 弹min(team-0)=%d（下探%d） 命中对数+%d 死亡冲刷+%d 玩家位移=%.0fpx" % [
		int(p_res["min_enemies"]), int(p_res["dip_enemies"]),
		int(p_res["min_bullets"]), int(p_res["dip_bullets"]),
		int(p_res["hit_pairs"]), int(p_res["deaths"]), float(p_res["pos_delta"])])
	var totals: Array[float] = p_res["totals"]
	var sorted_t := totals.duplicate()
	sorted_t.sort()
	print("整步墙钟 ms：p50=%.3f p95=%.3f p99=%.3f（60Hz 预算 16.67）" % [
		_pct(sorted_t, 0.50), _pct(sorted_t, 0.95), _pct(sorted_t, 0.99)])
	print("段键对照：player=②玩段全量 / projectile=④弹段（grid_projectile） / enemy=⑤敌段 / weapons=②内火段（player_wp）")
	# ── 输出契约行（逐字——解析器口径，勿动前缀/顺序） ──
	print("BENCH|total|%.3f" % _mean(totals))
	print("BENCH|player|%.3f" % _seg_ms(p_res, &"player"))
	print("BENCH|projectile|%.3f" % _seg_ms(p_res, &"grid_projectile"))
	print("BENCH|enemy|%.3f" % _seg_ms(p_res, &"enemy"))
	print("BENCH|weapons|%.3f" % _seg_ms(p_res, &"player_wp"))
	# ── 轻量 sanity（量的是真负载的自证面） ──
	var seg_n: Dictionary = p_res["seg_n"]
	_check("s1 全程 state 恒 PLAYING（预热+测量）", not bool(p_res["left_playing"]),
		"left_playing=%s" % str(bool(p_res["left_playing"])))
	_check("s2 敌驻场 ≥%d（补位后 standing count——r271 M4 门① 同款口径）" % ENEMY_FLOOR,
		int(p_res["min_enemies"]) >= ENEMY_FLOOR,
		"敌min=%d 补位前下探=%d" % [int(p_res["min_enemies"]), int(p_res["dip_enemies"])])
	_check("s3 team-0 活弹 ≥%d（补位后 standing count——r271 M4 门① 同款口径）" % BULLET_FLOOR,
		int(p_res["min_bullets"]) >= BULLET_FLOOR,
		"弹min=%d 补位前下探=%d" % [int(p_res["min_bullets"]), int(p_res["dip_bullets"])])
	_check("s4 命中对数增量 >0（促1 T1 网格命中在账——真负载自证）",
		int(p_res["hit_pairs"]) > 0, "命中+%d" % int(p_res["hit_pairs"]))
	_check("s5 玩家位置变化 >50px（风筝轨道在跑）",
		float(p_res["pos_delta"]) > 50.0, "%.0fpx" % float(p_res["pos_delta"]))
	_check("s6 四段探针全窗在账（player/projectile/enemy/weapons 计数=%d）" % MEASURE_STEPS,
		int(seg_n.get(&"player", 0)) == MEASURE_STEPS
			and int(seg_n.get(&"grid_projectile", 0)) == MEASURE_STEPS
			and int(seg_n.get(&"enemy", 0)) == MEASURE_STEPS
			and int(seg_n.get(&"player_wp", 0)) == MEASURE_STEPS,
		"n=%d/%d/%d/%d" % [int(seg_n.get(&"player", 0)),
			int(seg_n.get(&"grid_projectile", 0)), int(seg_n.get(&"enemy", 0)),
			int(seg_n.get(&"player_wp", 0))])


# ── 收尾（注入口复位 + R270 盘档毒配方还原） ─────────────────────────

func _teardown() -> void:
	PerfGovernor.boost_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.deep_override = -1
	PerfGovernor.set_deep_active(false)
	PerfGovernor.set_process(true)
	# R270 盘档毒配方（r292 同款）：快照还原 + 本套件可致写面显式 erase 再落盘
	Meta._settings = _saved_settings.duplicate()
	Meta._settings.erase("perf_boost")
	Meta._settings.erase("boost_res")
	Meta._save()
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame
	RunSave.clear()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for fl in _failures:
			print("  FAIL 详情：%s" % fl)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])


# ── 统计工具（probe_r224_deepload_cases 同款） ───────────────────────

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

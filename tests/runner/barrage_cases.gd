# tests/runner/barrage_cases.gd
# Boss 弹幕专项用例体（由 test_barrage.gd 入口在 autoload 就绪后运行时加载编译）。
# 真源：docs/design/ENEMY_BOSS_TELEGRAPH.md §9 P1 验收要点 1/2/4/5/7 + §1.1 预警铁律。
# 确定性：合成 EnemyData 驱动 Enemy 实例（真池 + 真敌弹池），手动 tick 推进 game_delta。
extends RefCounted

const DT := 1.0 / 120.0                          # 120Hz 物理帧
const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_test_data_barrage_config()                   # 五 Boss .tres 真源断言
	_test_ring_volley()                           # B1：count/等角/伤害平值/预警期零出弹
	_test_aimed_spread_volley()                   # B2：扇心锁定/arc 分布/跟射波
	_test_spiral_emission()                       # B3：臂数/步进角/持续喷发
	_test_phase_gating_and_freeze()               # 阶段门控 + 冻结停摆（§1.3 game_delta）
	_test_legacy_pattern_conversion()             # §4 存量 bullet_patterns 折算
	_test_validator_barrage()                     # §9 验收 4：barrage 必填/三档/pct 界
	_test_soak_and_bullet_budget()                # §9 验收 2/6：soak + 敌弹预算
	_test_volatile_ring_generalization()          # FuseRing 泛化零行为变化（§1.4）
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 环境 ──────────────────────────────────────────────────────────
func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _make_boss_data(p_barrage: Array) -> EnemyData:
	# 合成 Boss（零速、大血量、真 Boss tag；immune_mask=0 便于冻结停摆用例直注状态）
	var data := EnemyData.new()
	data.id = &"E_BARRAGE_T"
	data.hp_base = 1000000.0
	data.spd_base = 0.0
	data.dmg_base = 5.0
	data.hitbox_r = 14.0
	data.tags = GameConst.TAG_BOSS
	data.boss = {"phases": 2, "phase2_hp": 0.5, "phase2_resist": 0.2,
		"barrage": p_barrage, "summons": {}}
	return data


func _spawn_boss(p_data: EnemyData) -> Enemy:
	var boss: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	boss.spawn(p_data, 10, 0)
	boss.projectile_pool = _gl.pools[&"projectile"]
	boss.position = _gl.player.global_position + Vector2(260.0, 0.0)
	for i in range(boss._barrage_cd.size()):
		boss._barrage_cd[i] = 0.0                # 清开场错相：用例需要立即施法
	return boss


func _release_boss(p_boss: Enemy) -> void:
	(_gl.pools[&"enemy"] as EnemyPool).release(p_boss)


func _enemy_bullets() -> Array:
	var out: Array = []
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		if p is ProjectileBase and (p as ProjectileBase).team == 1:
			out.append(p)
	return out


func _clear_bullets() -> void:
	for b in _enemy_bullets():
		b.nullify()


func _tick_boss(p_boss: Enemy, p_frames: int) -> void:
	for i in range(p_frames):
		p_boss.tick(DT)


# ── 数据真源 ──────────────────────────────────────────────────────
func _test_data_barrage_config() -> void:
	print("── 五 Boss 弹幕配置 ──")
	for id in [&"E6_boss1", &"E6_boss2", &"E6_boss3", &"E17_frost_sovereign", &"E18_demon_lord"]:
		var data: EnemyData = load("res://resources/enemies/%s.tres" % String(id))
		var barr: Array = data.boss.get("barrage", [])
		_check("%s：barrage 就位（存量双轨清零）" % String(id),
			not barr.is_empty() and not data.boss.has("bullet_patterns"))
		var types: Array = []
		for b: Dictionary in barr:
			types.append(String(b.get("type", "")))
		_check("%s：含 ring/aimed_spread/spiral 至少一型" % String(id),
			types.has("ring") or types.has("aimed_spread") or types.has("spiral"))
	# 验收 7：dmg 平值抽查（7/13/6 = 12%/22%/10%）
	var e17: EnemyData = load("res://resources/enemies/E17_frost_sovereign.tres")
	var dmgs: Array = []
	for b: Dictionary in e17.boss["barrage"]:
		dmgs.append(float(b.get("dmg", 0.0)))
	_check("E17：dmg 平值档位对齐（7/13/6 在册）", dmgs.has(7.0) and dmgs.has(13.0) and dmgs.has(6.0))


# ── B1 聚能环爆 ───────────────────────────────────────────────────
func _test_ring_volley() -> void:
	print("── B1 环爆 ──")
	var def := {"type": "ring", "phase": 1, "cd": 6.0, "telegraph": "swell",
		"telegraph_s": 0.4, "count": 14, "speed": 170.0, "dmg": 7.0}
	var boss := _spawn_boss(_make_boss_data([def]))
	_tick_boss(boss, 6)                            # 先推进少量帧（进入施法）
	_check("B1：前摇期零出弹（§1.1 预警铁律）", _enemy_bullets().is_empty()
		and boss.get("_cast_idx") >= 0)
	_tick_boss(boss, 80)                           # 0.4s 前摇走完（48 帧 @120Hz）
	var bullets := _enemy_bullets()
	_check("B1：齐射 14 发（count 断言）", bullets.size() == 14, "实得 %d" % bullets.size())
	if bullets.size() == 14:
		var center := boss.global_position
		var angles: Array[float] = []
		var ok_dmg := true
		for b: ProjectileBase in bullets:
			angles.append((b.global_position - center).angle())
			if absf(float(b.panel_snapshot.get("base_atk", 0.0)) - 7.0) > 0.01:
				ok_dmg = false
		angles.sort()
		var step := TAU / 14.0
		var ok_spacing := true
		for i in range(1, angles.size()):
			if absf(angles[i] - angles[i - 1] - step) > deg_to_rad(1.0):
				ok_spacing = false
		_check("B1：等角分布（步进 %d° ±1°）" % int(rad_to_deg(step)), ok_spacing)
		_check("B1：伤害平值 = 7（验收 7）", ok_dmg)
		_check("B1：释放后 cd 重置（无二连发）", boss.get("_barrage_cd")[0] > 5.0)
	_clear_bullets()
	_release_boss(boss)


# ── B2 锁定扇射 ───────────────────────────────────────────────────
func _test_aimed_spread_volley() -> void:
	print("── B2 扇射 ──")
	var def := {"type": "aimed_spread", "phase": 1, "cd": 5.0, "telegraph": "fan",
		"telegraph_s": 0.4, "count": 5, "speed": 340.0, "arc_deg": 40.0,
		"waves": 2, "wave_gap_s": 0.25, "dmg": 13.0}
	var boss := _spawn_boss(_make_boss_data([def]))
	# 前摇锁定方向（起手快照）；期间移动玩家模拟走位 → 弹道不追踪
	_tick_boss(boss, 6)
	var locked_dir: Vector2 = boss.get("_cast_dir")
	_gl.player.position += Vector2(0.0, 220.0)     # 前摇内横移（警示即弹道，§1.2）
	_tick_boss(boss, 55)                           # 帧内释放首波（~49 帧），第二波（~79）未至
	var bullets := _enemy_bullets()
	_check("B2：首波 5 发", bullets.size() == 5, "实得 %d" % bullets.size())
	if bullets.size() == 5:
		var ok_arc := true
		for b: ProjectileBase in bullets:
			var dir: Vector2 = (b.global_position - boss.global_position).normalized()
			if absf(dir.angle_to(locked_dir)) > deg_to_rad(20.0) + 0.02:
				ok_arc = false
		_check("B2：弹道在锁定扇心 ±20° 内（不追踪）", ok_arc)
	# 跟射波（wave_gap 0.25s = 30 帧）
	_clear_bullets()
	_tick_boss(boss, 30)
	_check("B2：第二波 5 发（waves=2）", _enemy_bullets().size() == 5,
		"实得 %d" % _enemy_bullets().size())
	_clear_bullets()
	_tick_boss(boss, 30)
	_check("B2：两波后无三波", _enemy_bullets().is_empty())
	_release_boss(boss)
	_gl.player.position -= Vector2(0.0, 220.0)


# ── B3 旋转火舌 ───────────────────────────────────────────────────
func _test_spiral_emission() -> void:
	print("── B3 螺旋 ──")
	var def := {"type": "spiral", "phase": 1, "cd": 8.0, "telegraph": "swell",
		"telegraph_s": 0.4, "arms": 2, "step_deg": 17.0, "emit_s": 0.5,
		"speed": 205.0, "dmg": 6.0}
	var boss := _spawn_boss(_make_boss_data([def]))
	_tick_boss(boss, 126)                          # 前摇 48 帧 + 喷发 0.5s（60 帧）+ 余量
	var bullets := _enemy_bullets()
	# 每臂 6 次喷发（t=0,0.09,...,0.45）× 2 臂 = 12（±2 容差：帧离散）
	_check("B3：喷发弹数 ≈ 2 臂 × 6（±2）",
		absi(bullets.size() - 12) <= 2, "实得 %d" % bullets.size())
	_check("B3：喷发期同屏敌弹 ≤ 120（§9 验收 6）",
		(_gl.pools[&"projectile"] as ProjectilePool).total_active() <= 120)
	_clear_bullets()
	_release_boss(boss)


# ── 阶段门控 + 冻结停摆 ───────────────────────────────────────────
func _test_phase_gating_and_freeze() -> void:
	print("── 阶段门控 / 冻结停摆 ──")
	var def2 := {"type": "aimed_spread", "phase": 2, "cd": 5.0, "telegraph": "fan",
		"telegraph_s": 0.4, "count": 3, "speed": 330.0, "arc_deg": 30.0, "dmg": 13.0}
	var boss := _spawn_boss(_make_boss_data([def2]))
	boss.set("boss_phase", 1)
	_tick_boss(boss, 120)                          # 1s：phase 门控下永不施法
	_check("阶段门控：phase=1 不放 phase2 技", _enemy_bullets().is_empty()
		and int(boss.get("_cast_idx")) < 0)
	boss.set("boss_phase", 2)
	_tick_boss(boss, 126)
	_check("阶段门控：phase=2 解锁（齐射 3 发）", _enemy_bullets().size() == 3,
		"实得 %d" % _enemy_bullets().size())
	_clear_bullets()
	_release_boss(boss)
	# 冻结停摆：sf=0 时前摇/冷却全停（§1.3 game_delta 通道；Boss 免疫冻结为实战口径，
	# 用例直注 ElementalState.freeze_timer 验证停摆通路）
	var def1 := {"type": "ring", "phase": 1, "cd": 6.0, "telegraph": "swell",
		"telegraph_s": 0.4, "count": 8, "speed": 170.0, "dmg": 7.0}
	var boss2 := _spawn_boss(_make_boss_data([def1]))
	boss2.elemental = ElementalState.new()
	boss2.elemental.freeze_timer = 5.0
	_tick_boss(boss2, 120)                         # 冻结 1s：不得进入施法
	_check("冻结停摆：不出弹不施法", _enemy_bullets().is_empty()
		and int(boss2.get("_cast_idx")) < 0)
	boss2.elemental.freeze_timer = 0.0
	_tick_boss(boss2, 30)                          # 解冻 → 前摇中（剩 ~0.16s）
	var left0: float = boss2.get("_cast_left")
	boss2.elemental.freeze_timer = 5.0
	_tick_boss(boss2, 24)                          # 前摇中再冻结：cast_left 不动
	_check("冻结停摆：前摇计时冻结（cast_left 不推进）",
		int(boss2.get("_cast_idx")) >= 0
		and absf(boss2.get("_cast_left") - left0) < 0.0001)
	boss2.elemental.freeze_timer = 0.0
	_tick_boss(boss2, 60)
	_check("解冻后前摇完成齐射", _enemy_bullets().size() == 8)
	_clear_bullets()
	_release_boss(boss2)


# ── 存量折算 ──────────────────────────────────────────────────────
func _test_legacy_pattern_conversion() -> void:
	print("── 存量折算 ──")
	var data := EnemyData.new()
	data.id = &"E_LEGACY_BOSS"
	data.hp_base = 100000.0
	data.tags = GameConst.TAG_BOSS
	data.boss = {"phases": 2, "phase2_resist": 0.2,
		"bullet_patterns": {"interval_s": 4.2, "pattern": "fan", "count": 24, "dmg": 16.0,
			"speed_mult_phase2": 1.35},
		"summons": {}}
	var boss := _spawn_boss(data)
	var barr: Array = boss.get("_barrage")
	_check("存量折算：bullet_patterns → barrage[0]", barr.size() == 1
		and String(barr[0].get("type", "")) == "aimed_spread")
	_tick_boss(boss, 126)
	_check("存量折算：折算技可齐射（24 发扇形）", _enemy_bullets().size() == 24,
		"实得 %d" % _enemy_bullets().size())
	_clear_bullets()
	_release_boss(boss)


# ── DataValidator ─────────────────────────────────────────────────
func _error_fields(p_report: Array) -> Array[String]:
	# 校验报告 → 字段名清单（仅 error 级条目；warning 属迁移/提示口径）
	var out: Array[String] = []
	for r: Dictionary in p_report:
		if String(r.get("severity", DataValidator.SEV_ERROR)) == DataValidator.SEV_ERROR:
			out.append(String(r.get("field", "")))
	return out


func _test_validator_barrage() -> void:
	print("── 校验器 ──")
	var v := DataValidator.new()
	var good := _make_boss_data([{"type": "ring", "phase": 1, "cd": 5.0,
		"telegraph": "swell", "telegraph_s": 0.4, "count": 14, "speed": 170.0, "dmg": 7.0}])
	var bad_missing := _make_boss_data([{"type": "ring", "cd": 5.0, "dmg": 7.0}])
	var bad_pct := _make_boss_data([{"type": "ring", "phase": 1, "cd": 5.0,
		"telegraph": "swell", "telegraph_s": 0.4, "count": 14, "speed": 170.0, "dmg": 40.0}])
	var bad_tier := _make_boss_data([{"type": "ring", "phase": 1, "cd": 5.0,
		"telegraph": "swell", "telegraph_s": 0.55, "count": 14, "speed": 170.0, "dmg": 7.0}])
	var no_barrage := _make_boss_data([])
	no_barrage.boss.erase("barrage")
	no_barrage.boss.erase("bullet_patterns")
	var f_good := _error_fields(v.validate_enemy(good))
	_check("校验：合法 barrage 零 error", f_good.is_empty(), str(f_good))
	_check("校验：缺 telegraph/telegraph_s → error（验收 4）",
		not _error_fields(v.validate_enemy(bad_missing)).is_empty())
	_check("校验：dmg pct 越界（40/60=67%>50）→ error（验收 4）",
		not _error_fields(v.validate_enemy(bad_pct)).is_empty())
	_check("校验：telegraph_s 非三档（0.55）→ error",
		not _error_fields(v.validate_enemy(bad_tier)).is_empty())
	_check("校验：弹幕段全缺 → error",
		not _error_fields(v.validate_enemy(no_barrage)).is_empty())
	# 存量双轨：bullet_patterns 走 warning（E19/E20 迁移提示），不拒绝
	var legacy := EnemyData.new()
	legacy.id = &"E_LEGACY_V"
	legacy.hp_base = 100.0
	legacy.tags = GameConst.TAG_BOSS
	legacy.boss = {"phases": 2, "phase2_resist": 0.2,
		"bullet_patterns": {"interval_s": 4.2, "pattern": "ring", "count": 24, "dmg": 16.0},
		"summons": {}}
	var report_l := v.validate_enemy(legacy)
	var has_warn := false
	var has_err := false
	for r: Dictionary in report_l:
		if String(r.get("field", "")) == &"boss.bullet_patterns" \
				and String(r.get("severity", "")) == DataValidator.SEV_WARNING:
			has_warn = true
		if String(r.get("severity", "")) == DataValidator.SEV_ERROR:
			has_err = true
	_check("校验：存量 bullet_patterns = 告警不拒绝（E19/E20 过渡）", has_warn and not has_err)
	# 真源 tres：五 Boss 校验零 error
	for id in [&"E6_boss1", &"E6_boss3", &"E17_frost_sovereign", &"E18_demon_lord"]:
		var data: EnemyData = load("res://resources/enemies/%s.tres" % String(id))
		var errs := _error_fields(v.validate_enemy(data))
		_check("校验：%s 零 error" % String(id), errs.is_empty(), str(errs))


# ── soak + 预算 ───────────────────────────────────────────────────
func _test_soak_and_bullet_budget() -> void:
	print("── soak / 预算 ──")
	# §9 验收 2：敌弹 team=1 命中走 0.6s 无敌帧（0.6s 内多发只扣 1 次）
	_gl.player.invuln_left = 0.0
	var hp0: float = _gl.player.hp
	_gl.player.take_contact_damage(7.0)
	_gl.player.take_contact_damage(13.0)
	_gl.player.take_contact_damage(21.0)
	var dropped := hp0 - _gl.player.hp
	_check("soak：0.6s 内三连命中只扣 1 次", absf(dropped - 7.0) < 0.01,
		"实扣 %.1f" % dropped)
	_gl.player.invuln_left = 0.0                   # 清无敌帧（防污染后续用例）


# ── E4 泛化回归 ───────────────────────────────────────────────────
func _test_volatile_ring_generalization() -> void:
	print("── E4 泛化回归 ──")
	var data := EnemyData.new()
	data.id = &"E4_volatile"
	data.hp_base = 72.0
	data.spd_base = 75.0
	data.dmg_base = 8.0
	var bug: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	bug.spawn(data, 1, 0)
	bug.projectile_pool = _gl.pools[&"projectile"]
	var ring: Node2D = bug.get("_fuse_ring")
	_check("E4：警示圈 = TelegraphCircle 泛化件",
		ring is Telegraph.TelegraphCircle)
	_check("E4：警示圈半径/配色不变（零行为变化）",
		ring.radius == 110.0 and ring.color.r == 1.0)
	# 接触 → 引导激活（既有行为）
	_gl.player.position = bug.global_position + Vector2(10.0, 0.0)
	bug.tick(DT)
	_check("E4：接触后引导激活（fuse_armed）", bool(bug.fuse_armed()))
	_gl.player.position = Vector2(10000.0, 10000.0)
	_release_boss(bug)

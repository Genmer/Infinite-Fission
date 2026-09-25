# tests/runner/w1_volley_cases.gd
# R187 §2.4 手枪「并行弹幕 × 跳弹增值」用例体（由 test_w1_volley.gd 入口在 autoload
# 就绪后运行时加载编译）。真源：docs/design/R187_WEAPON_REWORK.md §2.4 Acceptance 1~7。
# ① 面板锚点 70/80/121/143/198 + pierce [1,1,2,2,2]；② 并排几何确定性 + L5 收束；
# ③ 跳弹预算/永存/黄金弹；④ TH_VOLLEY_STATE 弹幕态；⑤ 上限阀压测；
# ⑥ REL_ECHO 回响绕门负例 + 副本弹幕态独立；⑦ validator 负例。
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"
const STRESS_SECONDS := 30.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_test_panel_anchors()
	_test_formation_geometry()
	_test_bounce_axis()
	_test_volley_state()
	_test_stress_valve()
	_test_distinctness_and_echo_gate()
	_test_validator()
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
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.set("unlocked_slots", GameConst.MAX_WEAPON_SLOTS)
	# 几何用例前置：玩家就位场地中部（默认 (0,0) 贴左墙——并排编队会撞墙反弹污染轨迹）
	_gl.player.position = Vector2(360.0, 1000.0)


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


func _make_weapon(p_level: int) -> BallisticWeapon:
	# 每配置独立实例（依赖注入经 player.add_weapon——pipeline/pool/grid 全接）
	var w: BallisticWeapon = _gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol")) as BallisticWeapon
	if w != null:
		w.level = clampi(p_level, 1, 5)
		w._invalidate_panel()
	return w


func _release_weapon(p_w: BallisticWeapon) -> void:
	# 组间回收：清弹 + 摘槽 + 延迟释放（槽位立即可复用——_first_available_slot 判 null）
	if p_w == null:
		return
	_drop_bullets(p_w)
	var slots: Array = _gl.player.weapon_slots
	for i in range(slots.size()):
		if slots[i] == p_w:
			slots[i] = null
	p_w.queue_free()


func _drop_bullets(p_w: BallisticWeapon) -> void:
	# 归还本武器在场弹（池清洁口径，gatling_orbit_cases 先例）——
	# active_projectiles() 返回池内部数组引用，回收中会原地擦除 → 必须遍历副本
	var snapshot: Array = (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles().duplicate()
	for p in snapshot:
		if p is ProjectileBase and (p as ProjectileBase).weapon_uid == p_w.uid:
			(p as ProjectileBase).nullify()


func _my_bullets(p_w: BallisticWeapon) -> Array[ProjectileBase]:
	var out: Array[ProjectileBase] = []
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		if p is ProjectileBase and (p as ProjectileBase).weapon_uid == p_w.uid:
			out.append(p as ProjectileBase)
	return out


func _lateral_offsets(p_w: BallisticWeapon) -> Array[float]:
	# 出膛横向偏移（相对出膛口；无敌人 → 瞄准 = UP，垂向 = 水平轴）——集合口径判等
	var muzzle: Vector2 = p_w.muzzle_position()
	var out: Array[float] = []
	for b in _my_bullets(p_w):
		out.append(b.global_position.x - muzzle.x)
	out.sort()
	return out


func _offsets_match(p_actual: Array[float], p_expected: Array[float],
		p_tol: float = 0.05) -> bool:
	# 浮点容差集合判等（Node2D.position 走 float32——±0.05px 内视为精确编队）
	if p_actual.size() != p_expected.size():
		return false
	for i in range(p_actual.size()):
		if absf(p_actual[i] - p_expected[i]) > p_tol:
			return false
	return true


# ── 验收① 面板锚点 ────────────────────────────────────────────────
func _test_panel_anchors() -> void:
	print("── ① 面板锚点（70/80/121/143/198）──")
	var pistol: WeaponData = _gl.registry.get_weapon(&"W1_pistol")
	_check("① 前置：W1_pistol 入注册表", pistol != null)
	if pistol == null:
		return
	_check("① upgrade_table 恰 5 项", pistol.upgrade_table.size() == 5)
	var dps_expect: Array[float] = [70.0, 80.0, 121.0, 143.0, 198.0]
	var pierce_expect: Array[int] = [1, 1, 2, 2, 2]
	for i in range(5):
		var lv: WeaponLevelStats = pistol.upgrade_table[i]
		var dps := lv.base_atk * lv.rof * float(lv.pellets)
		_check("① L%d 面板 DPS %.1f（±0.5）" % [i + 1, dps_expect[i]],
			absf(dps - dps_expect[i]) <= 0.5, "实得 %.2f" % dps)
		_check("① L%d pierce==%d" % [i + 1, pierce_expect[i]],
			lv.pierce == pierce_expect[i], "实得 %d" % lv.pierce)
	# p1_polish 锚存活（L1=14 / L2=16——提速基伤锁定）
	_check("① p1_polish 锚：L1 base_atk==14 / L2==16",
		absf(pistol.upgrade_table[0].base_atk - 14.0) < 0.001
		and absf(pistol.upgrade_table[1].base_atk - 16.0) < 0.001)
	# L1/L2 过期 note 修正（旧文案错写 60/70 → 新文案必须写对 70/80）
	_check("① L1/L2 note 过期文案修正（按新表写 70/80）",
		String(pistol.upgrade_table[0].note).contains("70")
		and String(pistol.upgrade_table[1].note).contains("80"))
	# 编队/跳弹新键在册
	var seg: Dictionary = pistol.ballistic
	_check("① lateral_gap_levels=[0,0,12,12,12]",
		seg.get("lateral_gap_levels") is Array and _levels_f(seg["lateral_gap_levels"]) == [0.0, 0.0, 12.0, 12.0, 12.0])
	_check("① converge_pct_levels L5==0.55",
		seg.get("converge_pct_levels") is Array and absf(float((seg["converge_pct_levels"] as Array)[4]) - 0.55) < 0.0001)
	_check("① bounce_levels=[0,0,1,1,2]",
		seg.get("bounce_levels") is Array and _levels_f(seg["bounce_levels"]) == [0.0, 0.0, 1.0, 1.0, 2.0])
	_check("① bounce_amp=0.12 / cap=1.0",
		absf(float(seg.get("bounce_amp", 0.0)) - 0.12) < 0.0001
		and absf(float(seg.get("bounce_amp_cap", 0.0)) - 1.0) < 0.0001)
	# 阈值在册直读 WeaponData.threshold_traits（get_threshold 属 WeaponBase 运行时）
	var volley_th: Dictionary = {}
	var bank_th: Dictionary = {}
	for tt in pistol.threshold_traits:
		if String(tt.get("threshold_id", "")) == "TH_VOLLEY_STATE":
			volley_th = tt
		if String(tt.get("threshold_id", "")) == "TH_BANK_SHOT":
			bank_th = tt
	_check("① 阈值在册：TH_VOLLEY_STATE(pellets≥6) + TH_BANK_SHOT(bounce≥12)",
		not volley_th.is_empty() and absf(float(volley_th.get("threshold", 0.0)) - 6.0) < 0.0001
		and not bank_th.is_empty() and absf(float(bank_th.get("threshold", 0.0)) - 12.0) < 0.0001)


# ── 验收② 并排几何确定性 ──────────────────────────────────────────
func _test_formation_geometry() -> void:
	print("── ② 并排几何/收束 ──")
	# L3 双管 ±6 / L5 三线 ±12；seed(42) 十次一致
	var w3 := _make_weapon(3)
	var first3: Array[float] = []
	for round_i in range(10):
		seed(42)
		_drop_bullets(w3)
		w3.try_fire()
		var offs := _lateral_offsets(w3)
		if round_i == 0:
			first3 = offs
		else:
			_check("② L3 offset 十次一致（round %d）" % (round_i + 1),
				_offsets_match(offs, first3), str(offs))
	_check("② L3 出 2 弹 offset={-6,+6}",
		_offsets_match(first3, [-6.0, 6.0]), str(first3))
	_drop_bullets(w3)

	var w5 := _make_weapon(5)
	var first5: Array[float] = []
	for round_i in range(10):
		seed(42)
		_drop_bullets(w5)
		w5.try_fire()
		var offs := _lateral_offsets(w5)
		if round_i == 0:
			first5 = offs
		else:
			_check("② L5 offset 十次一致（round %d）" % (round_i + 1),
				_offsets_match(offs, first5), str(offs))
	_check("② L5 出 3 弹 offset={-12,0,+12}",
		_offsets_match(first5, [-12.0, 0.0, 12.0]), str(first5))
	# L5 收束：步进模拟至 55% 射程 → 三弹距瞄准线 <10px（中轴弹速度方向 = 瞄准线向）
	_check("② L5 收束 <10px @55% 射程", _converge_probe(w5, 0.55, 10.0))
	_drop_bullets(w5)
	# L3 对照：无收束 → 全程恒 12px 间距（0.25R / 0.55R 双检查点）
	seed(42)
	_drop_bullets(w3)
	w3.try_fire()
	_check("② L3 对照恒 12px 间距", _spacing_probe(w3, 12.0))
	_drop_bullets(w3)
	# MEC_PARALLEL_CAL ×3：阵宽 12+12=24（±24px）、收束点 55%→70%
	var cal: TraitData = _gl.registry.get_trait(&"MEC_PARALLEL_CAL")
	_check("② 前置：MEC_PARALLEL_CAL 上架", cal != null)
	if cal != null:
		for i in range(3):
			w5.attach_trait(cal)
		_check("② PARALLEL_CAL×3 阵宽 ±24px",
			absf(w5._lateral_gap() - 24.0) < 0.0001, "实得 %.2f" % w5._lateral_gap())
		_check("② PARALLEL_CAL×3 收束点 0.70",
			absf(w5._converge_pct() - 0.70) < 0.0001, "实得 %.3f" % w5._converge_pct())
		seed(42)
		_drop_bullets(w5)
		w5.try_fire()
		_check("② PARALLEL_CAL×3 出膛 offset={-24,0,+24}",
			_offsets_match(_lateral_offsets(w5), [-24.0, 0.0, 24.0]),
			str(_lateral_offsets(w5)))
		_check("② PARALLEL_CAL×3 收束 <10px @70% 射程", _converge_probe(w5, 0.70, 10.0))
	_drop_bullets(w5)
	_release_weapon(w3)
	_release_weapon(w5)


func _converge_probe(p_w: BallisticWeapon, p_pct: float, p_tol_px: float) -> bool:
	# 步进弹体至 p_pct×射程 处，量三弹到瞄准线（出膛口 × 中轴弹速向）的垂距
	var bullets := _my_bullets(p_w)
	if bullets.size() != 3:
		return false
	var muzzle: Vector2 = p_w.muzzle_position()
	var center_dir := Vector2.UP
	for b in bullets:
		if absf(b.global_position.x - muzzle.x) < 0.5 and b.velocity.length() > 1.0:
			center_dir = b.velocity.normalized()   # 中轴弹（offset 0）速向 = 编队瞄准线向
			break
	var target := _range_of(p_w) * p_pct
	for b in bullets:
		var spawn_pos: Vector2 = b.global_position
		var guard := 0
		while spawn_pos.distance_to(b.global_position) < target and guard < 2000:
			b.tick(DT)
			guard += 1
			if b.global_position.distance_to(muzzle) > 1400.0:
				return false                 # 出界护栏（池化弹不在树内，只做位置护栏）
		var perp_dist: float = absf((b.global_position - muzzle).cross(center_dir))
		if perp_dist >= p_tol_px:
			return false
	return true


func _spacing_probe(p_w: BallisticWeapon, p_expect_px: float) -> bool:
	# L3 双弹全程恒间距检查点（0.25R / 0.55R）
	var bullets := _my_bullets(p_w)
	if bullets.size() != 2:
		return false
	var checkpoints: Array[float] = [_range_of(p_w) * 0.25, _range_of(p_w) * 0.55]
	var traveled := 0.0
	var last_pos_a: Vector2 = bullets[0].global_position
	var idx := 0
	var guard := 0
	while idx < checkpoints.size() and guard < 2000:
		var pa: Vector2 = bullets[0].global_position
		var pb: Vector2 = bullets[1].global_position
		traveled += pa.distance_to(last_pos_a)
		last_pos_a = pa
		if traveled >= checkpoints[idx]:
			if absf(pa.distance_to(pb) - p_expect_px) > 0.5:
				return false
			idx += 1
		bullets[0].tick(DT)
		bullets[1].tick(DT)
		guard += 1
	return idx == checkpoints.size()


func _range_of(p_w: BallisticWeapon) -> float:
	return maxf(float(p_w.data.ballistic.get("range", 680.0)), 10.0)


func _levels_f(p_arr: Variant) -> Array[float]:
	# .tres 数组元素经 YAML 反序列化可能落 int/float 混合——统一 float 后比较
	var out: Array[float] = []
	if p_arr is Array:
		for v in p_arr:
			out.append(float(v))
	return out


# ── 验收③ 跳弹增值/永存/黄金弹 ────────────────────────────────────
func _test_bounce_axis() -> void:
	print("── ③ 跳弹预算/永存/黄金弹 ──")
	# L1/L2/L3/L5 出弹反弹预算 0/0/1/2
	var expect := {1: 0, 2: 0, 3: 1, 5: 2}
	for lv in expect.keys():
		var w := _make_weapon(lv)
		seed(42)
		w.try_fire()
		var bullets := _my_bullets(w)
		var ok := bullets.size() > 0
		for b in bullets:
			if b.bounces_left != int(expect[lv]):
				ok = false
		_check("③ L%d 出弹 bounces_left==%d" % [lv, expect[lv]],
			ok, "实弹数 %d" % bullets.size())
		_drop_bullets(w)
		_release_weapon(w)
	# 金 MEC_BOUNCE 1 层（value 5.2 = 白 2.0×金 2.6）→ L5 预算 2+5=7
	var w5 := _make_weapon(5)
	var gold: TraitData = (_gl.registry.get_trait(&"MEC_BOUNCE") as TraitData).duplicate()
	gold.value = 5.2
	w5.attach_trait(gold)
	seed(42)
	w5.try_fire()
	var ok7 := true
	for b in _my_bullets(w5):
		if b.bounces_left != 7:
			ok7 = false
	_check("③ 金 MEC_BOUNCE×1 → L5 预算==7", ok7, str(_my_bullets(w5).size()))
	# 永存：5 次 ON_BOUNCE 触发 TH_BOUNCE_ETERNAL（lifetime≥999）、4 次不触发
	#（反弹间推进帧号——TraitBase.can_trigger 的 E-03「本帧已触发」闸按真实帧路径放行）
	var eternal_ok := true
	for b in _my_bullets(w5):
		for i in range(4):
			GameConfig.advance_frame()
			b._apply_bounce(Vector2(0, 1))
		if b.lifetime_left >= 999.0:
			eternal_ok = false                  # 4 次：不触发
		GameConfig.advance_frame()
		b._apply_bounce(Vector2(0, 1))
		if b.lifetime_left < 999.0:
			eternal_ok = false                  # 第 5 次：永存
	_check("③ 5 次 ON_BOUNCE 触发永存（≥999）/ 4 次不触发", eternal_ok)
	# 永存配额阀：配额达满 → get_threshold 对 TH_BOUNCE_ETERNAL 断供（新弹不再获永续）
	w5._eternal_quota_full = true
	_check("③ 配额满 → TH_BOUNCE_ETERNAL 断供",
		w5.get_threshold(&"TH_BOUNCE_ETERNAL").is_empty()
		and not w5.get_threshold(&"TH_CRIT_SHARD").is_empty())
	w5._eternal_quota_full = false
	_check("③ 配额释放 → TH_BOUNCE_ETERNAL 恢复",
		not w5.get_threshold(&"TH_BOUNCE_ETERNAL").is_empty())
	_drop_bullets(w5)
	_bank_shot_checks(w5)
	_release_weapon(w5)


func _bank_shot_checks(p_w: BallisticWeapon) -> void:
	# 黄金弹：bounce_count≥12 → 必暴 + 落点弹片（真管线结算；邻近敌承接弹片伤）
	var edata := EnemyData.new()
	edata.id = &"E_W1_BANK"
	edata.hp_base = 100000.0
	edata.spd_base = 0.0
	var main: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	main.spawn(edata, 1, 0)
	var shard_t: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	shard_t.spawn(edata, 1, 0)
	var wpos: Vector2 = p_w.global_position
	main.global_position = wpos + Vector2(0, -80.0)
	shard_t.global_position = wpos + Vector2(0, -80.0) + Vector2(30.0, 0.0)
	if p_w.enemy_grid != null:
		p_w.enemy_grid.insert(main, main.hitbox_r)
		p_w.enemy_grid.insert(shard_t, shard_t.hitbox_r)
	# 正例：bounce_count=12 → crit_chance 抬到 1.0；落点弹片恰一次（计数 +1、邻敌掉血）
	var ctx := DamageContext.make()
	ctx.source_uid = p_w.uid
	ctx.target = main
	ctx.target_uid = main.uid
	ctx.frame_stamp = GameConfig.frame_stamp
	ctx.base_atk = 10.0
	ctx.crit_chance = 0.05
	ctx.crit_mult = 2.0
	ctx.bounce_count = 12
	ctx.pos = main.global_position
	var shard_hp_before: float = shard_t.hp
	var shard_counter_before := DebugStats.get_counter(&"bank_shard_triggered")
	p_w.inject_relic_pools(ctx, main)
	var crit_guaranteed := absf(ctx.crit_chance - 1.0) < 0.0001
	GameConfig.advance_frame()                     # 换帧：避开管线幂等缓存（帧戳入键）
	ctx.frame_stamp = GameConfig.frame_stamp
	_gl.pipeline.begin_frame()
	var result: DamageResult = _gl.pipeline.call(&"resolve", ctx)
	_check("③ 黄金弹 bounce≥12 必暴（crit_chance==1 → is_crit）",
		crit_guaranteed and result != null and result.is_crit,
		"crit_chance=%.2f is_crit=%s" % [ctx.crit_chance, str(result.is_crit) if result != null else "null"])
	_check("③ 黄金弹落点弹片（计数 +1 且邻敌掉血）",
		DebugStats.get_counter(&"bank_shard_triggered") == shard_counter_before + 1
		and shard_t.hp < shard_hp_before)
	# 反例：bounce_count=6 → 无必暴、无弹片
	GameConfig.advance_frame()                     # 换帧：避开管线幂等缓存
	var ctx6 := DamageContext.make()
	ctx6.source_uid = p_w.uid
	ctx6.target = main
	ctx6.target_uid = main.uid
	ctx6.frame_stamp = GameConfig.frame_stamp
	ctx6.base_atk = 10.0
	ctx6.crit_chance = 0.05
	ctx6.crit_mult = 2.0
	ctx6.bounce_count = 6
	ctx6.pos = main.global_position
	p_w.inject_relic_pools(ctx6, main)
	_check("③ bounce<12 不触发黄金弹",
		absf(ctx6.crit_chance - 0.05) < 0.0001
		and DebugStats.get_counter(&"bank_shard_triggered") == shard_counter_before + 1)
	# 跳弹增值乘区：bounce_count=6 → +0.72（6×0.12，帽内）；叠加后整体仍受 cap_prod 8.0 截断
	GameConfig.advance_frame()                     # 换帧：避开管线幂等缓存
	var ctx_amp := DamageContext.make()
	ctx_amp.source_uid = p_w.uid
	ctx_amp.target = main
	ctx_amp.target_uid = main.uid
	ctx_amp.frame_stamp = GameConfig.frame_stamp
	ctx_amp.base_atk = 10.0
	ctx_amp.crit_chance = 0.0
	ctx_amp.crit_mult = 2.0
	ctx_amp.bounce_count = 6
	ctx_amp.pos = main.global_position
	p_w.inject_relic_pools(ctx_amp, main)
	var amp_found := 0.0
	for pool in ctx_amp.mult_pools:
		if StringName(String(pool.get("pool_id", ""))) == &"bounce_amp":
			amp_found = float(pool.get("contrib", 0.0))
	_check("③ 跳弹增值 +0.72 入乘区（bounce_count 6 × 0.12）",
		absf(amp_found - 0.72) < 0.0001, "实得 %.3f" % amp_found)
	for i in range(4):
		ctx_amp.mult_pools.append({
			"pool_id": StringName("synthetic_%d" % i), "source_uid": 0,
			"contrib": 2.0, "cap_pool": 2.0, "priority": 0,
		})
	GameConfig.advance_frame()                     # 换帧：避开管线幂等缓存
	ctx_amp.frame_stamp = GameConfig.frame_stamp
	_gl.pipeline.begin_frame()
	var amp_result: DamageResult = _gl.pipeline.call(&"resolve", ctx_amp)
	_check("③ 增值链经 cap_prod 8.0 截断（mult_product==8.0）",
		amp_result != null and absf(amp_result.mult_product - 8.0) < 0.001,
		"实得 %.3f" % (amp_result.mult_product if amp_result != null else -1.0))
	(_gl.pools[&"enemy"] as EnemyPool).release(main)
	(_gl.pools[&"enemy"] as EnemyPool).release(shard_t)
	if p_w.enemy_grid != null:
		p_w.enemy_grid.rebuild([] as Array[Node2D])   # 清网：后续用例保持无敌期望


# ── 验收④ TH_VOLLEY_STATE 弹幕态 ─────────────────────────────────
func _test_volley_state() -> void:
	print("── ④ 弹幕态（pellets≥6 触发）──")
	var w := _make_weapon(5)
	var multi: TraitData = _gl.registry.get_trait(&"AFF_MULTI")
	_check("④ 前置：AFF_MULTI 上架", multi != null)
	if multi == null:
		return
	# 对照：×1 层 → 基础 3+1=4 丸（+1.45→round 1）< 6 不触发
	w.attach_trait(multi)
	_check("④ 对照：pellets==4（<6 不触发）", w._pellet_count() == 4,
		"实得 %d" % w._pellet_count())
	seed(42)
	w.try_fire()
	_check("④ 对照：弹幕态未激活", w._volley_left <= 0.0 and _my_bullets(w).size() == 4)
	_drop_bullets(w)
	# 触发：×2 层 → 3+round(2.9)=6 丸 ≥ 6 → 弹幕态
	w.attach_trait(multi)
	_check("④ 触发门：pellets==6", w._pellet_count() == 6, "实得 %d" % w._pellet_count())
	var hits: Array = [0]
	var cb := func(_tid: StringName, _n: String, _m: float) -> void: hits[0] += 1
	EventBus.trait_milestone.connect(cb)
	var counter_before := DebugStats.get_counter(&"volley_state_active")
	var base_interval: float = w._fire_interval()
	seed(42)
	w.try_fire()
	_check("④ pellets=6 触发弹幕态（_volley_left>0）", w._volley_left > 0.0)
	_check("④ 首发激活：trait_milestone 恰 1 次 + volley_state_active 计数 +1",
		hits[0] == 1 and DebugStats.get_counter(&"volley_state_active") == counter_before + 1,
		"hits=%d count=%d" % [hits[0], DebugStats.get_counter(&"volley_state_active")])
	_check("④ 弹幕态出 8 弹（+2 并排）", _my_bullets(w).size() == 8,
		"实得 %d" % _my_bullets(w).size())
	_check("④ 弹幕态开火间隔 ×0.8", absf(w._fire_interval() - base_interval * 0.8) < 0.0001,
		"interval=%.4f base=%.4f" % [w._fire_interval(), base_interval])
	_check("④ 弹幕态阵形 offset 8 丸 ±42px",
		_offsets_match(_lateral_offsets(w),
			[-42.0, -30.0, -18.0, -6.0, 6.0, 18.0, 30.0, 42.0]),
		str(_lateral_offsets(w)))
	_drop_bullets(w)
	# 时序：4.0s 激活 → 3.0s 散热 → 恢复（interval 回 1.0×，再触发可重进）
	#（485 tick = 4.042s——跨过 float 相除边界，散热已入档）
	for i in range(485):
		w.tick(DT)
	_check("④ 激活 4.0s 后进入散热（cd≈3.0）",
		w._volley_left <= 0.0 and w._volley_cd_left > 2.9 and w._volley_cd_left <= 3.0,
		"left=%.3f cd=%.3f" % [w._volley_left, w._volley_cd_left])
	_check("④ 散热期 interval 恢复 ×1.0",
		absf(w._fire_interval() - base_interval) < 0.0001)
	for i in range(370):
		w.tick(DT)
	_check("④ 散热 3.0s 后就绪（可再触发）",
		w._volley_cd_left <= 0.0 and w._volley_left <= 0.0)
	seed(42)
	w.try_fire()
	_check("④ 散热后再次触发（首发播报不重复）",
		w._volley_left > 0.0 and hits[0] == 1
		and DebugStats.get_counter(&"volley_state_active") == counter_before + 2)
	EventBus.trait_milestone.disconnect(cb)
	_drop_bullets(w)
	_release_weapon(w)


# ── 验收⑤ 上限阀压测（满配 30s 连射） ─────────────────────────────
func _test_stress_valve() -> void:
	print("── ⑤ 上限阀压测（满配 30s）──")
	var w := _make_weapon(5)
	var multi: TraitData = _gl.registry.get_trait(&"AFF_MULTI")
	w.attach_trait(multi)
	w.attach_trait(multi)                          # pellets 3+3=6 → 弹幕态链路常开
	var gold: TraitData = (_gl.registry.get_trait(&"MEC_BOUNCE") as TraitData).duplicate()
	gold.value = 5.2
	w.attach_trait(gold)                           # 反弹预算 2+5=7（永存可达、≈12s 生命周期）
	seed(42)
	var my_cd := 0.0
	var frames := int(STRESS_SECONDS / DT)
	var peak_eternal := 0
	var peak_live := 0
	var sample := 0
	var dropped_before := DebugStats.get_counter(&"w1_spawn_dropped")
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var pipe := _gl.pipeline
	for f in range(frames):
		GameConfig.advance_frame()                 # 帧号推进（E-03 帧闸/管线幂等键真源）
		pipe.begin_frame()
		# 逐弹 tick（GameLoop 帧序④口径；倒序副本防回收重入）
		var flying: Array = pool.active_projectiles().duplicate()
		flying.reverse()
		for p in flying:
			if p is ProjectileBase:
				(p as ProjectileBase).tick(DT)
		w.tick(DT)                                 # 推进弹幕态/配额扫描计时
		my_cd = maxf(my_cd - DT, 0.0)
		if my_cd <= 0.0 and w.try_fire():
			my_cd = w._fire_interval()
		pipe.end_frame()
		sample += 1
		if sample >= 12:                           # 10Hz 采样
			sample = 0
			var live := 0
			var eternal := 0
			for b in _my_bullets(w):
				live += 1
				if b.lifetime_left >= 120.0:
					eternal += 1
			peak_live = maxi(peak_live, live)
			peak_eternal = maxi(peak_eternal, eternal)
	var dropped := DebugStats.get_counter(&"w1_spawn_dropped") - dropped_before
	_check("⑤ 永存弹峰值 ≤240", peak_eternal <= 240, "峰值 %d" % peak_eternal)
	_check("⑤ 稳态活弹 <600", peak_live < 600, "峰值 %d" % peak_live)
	_check("⑤ 池拒收率 <1%（无 w1_spawn_dropped）",
		float(dropped) / maxf(float(frames), 1.0) < 0.01, "丢弃 %d" % dropped)
	_drop_bullets(w)
	_release_weapon(w)


# ── 验收⑥ 区分度/回响绕门负例 ────────────────────────────────────
func _test_distinctness_and_echo_gate() -> void:
	print("── ⑥ REL_ECHO 绕门负例/副本独立 ──")
	var cal: TraitData = _gl.registry.get_trait(&"MEC_PARALLEL_CAL")
	_check("⑥ 前置：MEC_PARALLEL_CAL 上架", cal != null)
	if cal == null:
		return
	# 负例：回响把「平行校准」挂到 W2（form 0 同域、无编队键）→ add_gap 不生效
	var w2: BallisticWeapon = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling")) as BallisticWeapon
	w2.attach_trait(cal)
	_check("⑥ REL_ECHO 负例：W2 挂 PARALLEL_CAL 阵宽/收束/回廊全不生效",
		absf(w2._lateral_gap() - 0.0) < 0.0001
		and absf(w2._converge_pct() - 0.0) < 0.0001
		and not w2._corridor_active())
	seed(42)
	w2.try_fire()
	var w2_offs: Array[float] = []
	var muzzle2: Vector2 = w2.muzzle_position()
	for b in _my_bullets(w2):
		w2_offs.append(b.global_position.x - muzzle2.x)
	_check("⑥ 负例：W2 出弹零横向偏移（编队几何不越界）",
		_offsets_match(w2_offs, [0.0]), str(w2_offs))
	# 对照：W1 挂同卡生效
	var w1 := _make_weapon(5)
	w1.attach_trait(cal)
	_check("⑥ 对照：W1 挂 PARALLEL_CAL 生效（gap 12+4=16）",
		absf(w1._lateral_gap() - 16.0) < 0.0001, "实得 %.2f" % w1._lateral_gap())
	# 副本弹幕态计时独立（R183 同 lane 参数 + 实例态隔离口径）
	var wcopy := _make_weapon(5)
	var multi: TraitData = _gl.registry.get_trait(&"AFF_MULTI")
	var w1_base_interval: float = w1._fire_interval()
	wcopy.attach_trait(multi)
	wcopy.attach_trait(multi)
	var copy_base_interval: float = wcopy._fire_interval()
	seed(42)
	wcopy.try_fire()
	_check("⑥ 前置：副本弹幕态激活", wcopy._volley_left > 0.0)
	_check("⑥ 副本独立：本体 interval 不受副本弹幕态影响（计时互不串扰）",
		w1._volley_left <= 0.0 and w1._volley_cd_left <= 0.0
		and absf(w1._fire_interval() - w1_base_interval) < 0.0001
		and absf(wcopy._fire_interval() - copy_base_interval * 0.8) < 0.0001)
	_drop_bullets(w1)
	_drop_bullets(w2)
	_drop_bullets(wcopy)
	_release_weapon(w1)
	_release_weapon(w2)
	_release_weapon(wcopy)


# ── 验收⑦ validator 负例 ──────────────────────────────────────────
func _test_validator() -> void:
	print("── ⑦ validator 负例 ──")
	var base: WeaponData = _gl.registry.get_weapon(&"W1_pistol")
	_check("⑦ 前置：W1 数据在册", base != null)
	if base == null:
		return
	var v := DataValidator.new()
	var bad_levels := {
		"lateral_gap_levels": [0.0, 0.0, 12.0, 12.0],
		"converge_pct_levels": [0.0, 0.0, 0.0],
		"bounce_levels": [0.0, 0.0],
	}
	for key in bad_levels.keys():
		var m: WeaponData = base.duplicate(true)
		m.ballistic[key] = bad_levels[key]
		var out := v.validate_weapon(m)
		var hit := false
		for issue in out:
			if String(issue.get("severity", "")) == DataValidator.SEV_ERROR \
					and String(issue.get("field", "")) == "ballistic." + String(key):
				hit = true
		_check("⑦ %s 长度≠5 报 error" % String(key), hit)
	# 域负例：bounce 超上限 5
	var m6: WeaponData = base.duplicate(true)
	m6.ballistic["bounce_levels"] = [0.0, 0.0, 1.0, 1.0, 6.0]
	var out6 := v.validate_weapon(m6)
	var hit6 := false
	for issue in out6:
		if String(issue.get("severity", "")) == DataValidator.SEV_ERROR \
				and String(issue.get("field", "")).begins_with("ballistic.bounce_levels"):
			hit6 = true
	_check("⑦ bounce_levels 值域 [0,5] 越界报 error", hit6)
	# 正例：现网 W1 全键合法零 error（_levels 长度/域全过）
	_check("⑦ 现网 W1 数据零 error", v.validate_weapon(base).is_empty())
	# EF 白名单：EF_VOLLEY / EF_BANK 在册（未入册时 check_references 剔除阈值条目）
	_check("⑦ EF_VOLLEY/EF_BANK 入 TECH_EFFECT_IDS 白名单",
		DataValidator.TECH_EFFECT_IDS.has(&"EF_VOLLEY")
		and DataValidator.TECH_EFFECT_IDS.has(&"EF_BANK"))
	var reg := DataRegistry.new()
	var nope: WeaponData = base.duplicate(true)
	nope.threshold_traits = [{
		"threshold_id": &"TH_W1_NOPE", "metric": "pellets", "threshold": 6.0,
		"effect_id": &"EF_NOPE", "params": {},
	}]
	reg.weapons[nope.id] = nope
	var issues := v.check_references(reg)
	var warned := false
	for issue in issues:
		if String(issue.get("field", "")) == "threshold_traits.effect_id" \
				and String(issue.get("severity", "")) == DataValidator.SEV_WARNING:
			warned = true
	_check("⑦ 反证：EF_NOPE 阈值被剔除（宿主保留）+ 告警",
		nope.threshold_traits.is_empty() and warned)

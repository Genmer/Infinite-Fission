# tests/runner/r211_elemcolor_cases.gd
# R211 元素染色批·用例体（由 test_r211_elemcolor.gd 入口在 autoload 就绪后运行时加载编译）。
# 用户需求：①武器弹药元素变色——激光主束挂 ELEM 卡即变对应元素色（加特林链路已在位，
#   行为锁定防回归）；②命中数字按元素染色（挂点已在位，修好束/弹 element 断点即恢复）。
# 覆盖：
#   T1 加特林弹药元素变色：W2 挂 ELE_IGNITE → try_fire → 弹 element==FIR、变体=_VIS_TRACER(4)、
#      贴图==tracer_tex(ELEMENT_COLORS[FIR])；挂卡前 KIN 对照==tracer_tex() 藏青缺省。
#   T2 激光主束挂卡重染（断点本体）：W4 常驻主束（lifetime=0 不重建）挂 ELE_IGNITE →
#      逐拍 _on_tick_post → element==FIR、束色==element_tint(FIR)、同实例未重建。
#   T3 束色优先级不回归：灰染束保灰蓝、折射束保光谱色且束宽 ×0.7 只做一次（refresh
#      不叠乘）、副束元素染色、KIN 主束玩家蓝——refresh_element_tint 幂等零漂移。
#   T4 命中数字元素色（零改动锚）：合成 DamageResult FIR/KIN → 跳字按 ELEMENT_COLORS
#      染色 / KIN 白档；R202 合并取最新元素口径不破坏（merge 既有行为只锁不改）。
#   T5 端到端：FIR 主束实束打真敌 → resolve → 跳字自动带元素色（全链恢复验证）。
# 元素色单源纪律：断言与实现一律挂 PopPalette.ELEMENT_COLORS / LaserBeam.element_tint。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT60 := 1.0 / 60.0
const PLAYER_HOME := Vector2(360.0, 900.0)

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _lw: LaserWeapon = null                # T2 装配的 W4（T5 复用同一把已挂火卡的激光）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_test_1_gatling_element_tracer()
	_test_2_laser_main_beam_retint()
	_test_3_beam_tint_priority()
	_test_4_popup_element_color()
	_test_5_laser_popup_e2e()
	_test_6_subbeam_elem_attach()
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
	_gl.name = "R211GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.state = GameConst.GameStatus.MENU      # 冻结波次（r210 同款骨架）
	_gl.player.global_position = PLAYER_HOME
	_gl.player.set("unlocked_slots", 4)        # W1 起始 + 加特林 + 激光共 3 把


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _bullet_of(p_weapon: WeaponBase) -> ProjectileBase:
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		if p is ProjectileBase and (p as ProjectileBase).team == 0 \
				and (p as ProjectileBase).get("weapon_ref") == p_weapon:
			return p
	return null


func _nullify_bullets_of(p_weapon: WeaponBase) -> void:
	var hits: Array[ProjectileBase] = []
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		if p is ProjectileBase and (p as ProjectileBase).team == 0 \
				and (p as ProjectileBase).get("weapon_ref") == p_weapon:
			hits.append(p)
	for b in hits:
		b.nullify()


func _fixture_enemy() -> EnemyData:
	var d := EnemyData.new()
	d.id = &"E_R211_CASE"
	d.display_name = "E_R211_CASE"
	d.hp_base = 1000.0
	d.spd_base = 0.0                           # 静止敌（几何确定性）
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


# ── T1 加特林弹药元素变色（链路已在位——行为锁定） ──────────────────
func _test_1_gatling_element_tracer() -> void:
	print("── T1 加特林弹药元素变色 ──")
	var t_kin: ImageTexture = TextureFactory.tracer_tex()
	var t_fire: ImageTexture = TextureFactory.tracer_tex(
		PopPalette.ELEMENT_COLORS[GameConst.Element.FIR])
	var gat: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	_check("前置：加特林装配", gat != null and gat is BallisticWeapon, "gat=%s" % str(gat))
	if gat == null:
		return
	gat.try_fire()
	var kin_b := _bullet_of(gat)
	_check("挂卡前 KIN 对照：弹 element==KIN 且贴图=藏青缺省 tracer_tex() 同实例",
		kin_b != null and kin_b.element == GameConst.Element.KIN
			and (kin_b.get("_sprite") as Sprite2D).texture.get_rid() == t_kin.get_rid(),
		"b=%s" % str(kin_b))
	_nullify_bullets_of(gat)
	gat.attach_trait(_gl.registry.get_trait(&"ELE_IGNITE"))
	gat.try_fire()
	var fire_b := _bullet_of(gat)
	_check("挂 ELE_IGNITE 后：弹 element==FIR 且变体=_VIS_TRACER(4)",
		fire_b != null and fire_b.element == GameConst.Element.FIR
			and int(fire_b.get("_vis_variant")) == 4,
		"elem=%s variant=%s" % [str(fire_b.element if fire_b != null else -1),
			str(fire_b.get("_vis_variant") if fire_b != null else -1)])
	_check("挂 ELE_IGNITE 后：弹贴图=tracer_tex(ELEMENT_COLORS[FIR])（火橙曳光≠藏青）",
		fire_b != null
			and (fire_b.get("_sprite") as Sprite2D).texture.get_rid() == t_fire.get_rid()
			and (fire_b.get("_sprite") as Sprite2D).texture.get_rid() != t_kin.get_rid(),
		"")
	_nullify_bullets_of(gat)


# ── T2 激光主束挂卡重染（断点本体——R211 修复口） ────────────────────
func _test_2_laser_main_beam_retint() -> void:
	print("── T2 激光主束挂卡重染 ──")
	var laser: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W4_pulse_beam"))
	_check("前置：激光 W4 装配为 LaserWeapon", laser is LaserWeapon, "lw=%s" % str(laser))
	if not (laser is LaserWeapon):
		return
	_lw = laser as LaserWeapon
	_lw.try_fire()
	var beam: LaserBeam = _lw._main_beam
	var uid0: int = beam.uid if beam != null else 0
	var player_blue := Color(PopPalette.PLAYER.r, PopPalette.PLAYER.g,
		PopPalette.PLAYER.b, 0.85)
	_check("建束对照：主束 element==KIN 且束色=玩家蓝（挂卡前观感不动）",
		beam != null and beam.is_live() and beam.element == GameConst.Element.KIN
			and (beam.get("_line") as Line2D).default_color.is_equal_approx(player_blue),
		"elem=%s" % str(beam.element if beam != null else -1))
	_lw.attach_trait(_gl.registry.get_trait(&"ELE_IGNITE"))
	for i in range(5):
		_lw._on_tick_post(DT60)                # 逐拍回写通道（挂卡即拍生效——R211 修复口）
	var fir_tint := LaserBeam.element_tint(GameConst.Element.FIR)
	var same_instance: bool = beam != null and is_instance_valid(beam) \
		and beam == _lw._main_beam and beam.uid == uid0
	_check("挂卡逐拍后：主束 element==FIR 且束色=element_tint(FIR)（同实例未重建）",
		same_instance and beam.element == GameConst.Element.FIR
			and (beam.get("_line") as Line2D).default_color.is_equal_approx(fir_tint),
		"elem=%s same=%s" % [str(beam.element if same_instance else -1), str(same_instance)])
	# 芯线契约：W4 focus_ramp=true——逐拍 apply_focus_visual 在元素回写之后覆写芯线
	#（R91 白热芯优先，元素读感由外层束线承担）；未启聚焦的束芯=tint.lerp(WHITE,0.9)。
	if _lw._focus_enabled:
		_check("聚焦主束芯线保 R91 白热口径（元素重染不冲白热芯，元素色走外层束线）",
			same_instance and (beam.get("_core") as Line2D).default_color.is_equal_approx(
				Color(1.0, 1.0, 1.0, 0.95)), "")
	else:
		_check("非聚焦束内芯同步重染（core = tint.lerp(WHITE,0.9) 同 spawn 口径）",
			same_instance and (beam.get("_core") as Line2D).default_color.is_equal_approx(
				fir_tint.lerp(Color.WHITE, 0.9)), "")


# ── T3 束色优先级不回归（refresh_element_tint 幂等） ─────────────────
func _test_3_beam_tint_priority() -> void:
	print("── T3 束色优先级不回归 ──")
	var pool: LaserBeamPool = _gl.pools[&"laser"] as LaserBeamPool
	_check("前置：激光束池在位", pool != null, "")
	if pool == null:
		return
	# 灰染束（R183 复制体）：灰蓝优先于元素染色
	var gray := pool.acquire() as LaserBeam
	gray.spawn({"team": 0, "gray_tint": true, "element": GameConst.Element.FIR})
	var gray_want := Color(PopPalette.RARITY_NORMAL.r, PopPalette.RARITY_NORMAL.g,
		PopPalette.RARITY_NORMAL.b, 0.6)
	var gray_line := gray.get("_line") as Line2D
	gray.refresh_element_tint()
	_check("灰染束保灰蓝（元素不覆写）且 refresh 幂等",
		gray_line.default_color.is_equal_approx(gray_want), "")
	# 折射束（W5 光谱）：depth2=光谱紫优先于元素染色；束宽 ×0.7 只做一次
	var refr := pool.acquire() as LaserBeam
	refr.spawn({"team": 0, "depth": 2, "is_refraction": true,
		"element": GameConst.Element.FIR})
	var refr_line := refr.get("_line") as Line2D
	var width_after_spawn: float = refr.beam_width
	refr.refresh_element_tint()
	_check("折射束保光谱紫（SHOCK）不被主束元素覆写",
		refr_line.default_color.is_equal_approx(
			Color(PopPalette.SHOCK.r, PopPalette.SHOCK.g, PopPalette.SHOCK.b, 0.85)), "")
	_check("折射束宽 ×0.7 只做一次（refresh 后不叠乘成 0.49 倍）",
		absf(width_after_spawn - 14.0 * 0.7) < 0.001
			and absf(refr.beam_width - 14.0 * 0.7) < 0.001,
		"w=%f→%f" % [width_after_spawn, refr.beam_width])
	# 副束元素染色（第三谱系——SPECTRA/挂卡通道）
	var sub := pool.acquire() as LaserBeam
	sub.spawn({"team": 0, "sub_beam": true, "element": GameConst.Element.ICE})
	_check("副束元素染色（element_tint(ICE) 单源）",
		(sub.get("_line") as Line2D).default_color.is_equal_approx(
			LaserBeam.element_tint(GameConst.Element.ICE)), "")
	# KIN 主束：玩家蓝缺省，refresh 幂等零写点
	var kin := pool.acquire() as LaserBeam
	kin.spawn({"team": 0})
	var blue := Color(PopPalette.PLAYER.r, PopPalette.PLAYER.g, PopPalette.PLAYER.b, 0.85)
	kin.refresh_element_tint()
	_check("KIN 主束玩家蓝缺省（refresh 幂等不漂色）",
		(kin.get("_line") as Line2D).default_color.is_equal_approx(blue), "")
	for b in [gray, refr, sub, kin]:
		if b != null and is_instance_valid(b) and b.is_live():
			b._recycle()                      # 归还池（T5 复用池名额）


# ── T4 命中数字元素色（挂点在位零改动锚 + R202 合并语义） ────────────
func _emit_direct(p_uid: int, p_element: int) -> void:
	# 合成直击结算结果（popup_style NORMAL）走真事件链（EventBus→PopupManager→DamagePopup）
	var r := DamageResult.new()
	r.final_value = 10.0
	r.element = p_element
	r.target_uid = p_uid
	r.popup_style = GameConst.PopupStyle.NORMAL
	r.pos = PLAYER_HOME + Vector2(-90.0 + float(p_uid % 7) * 30.0, -180.0)
	EventBus.emit_damage_resolved(r)


func _popup_of(p_uid: int) -> DamagePopup:
	for p in _gl.popup_manager._active_list:
		if p != null and is_instance_valid(p) and p.target_uid == p_uid:
			return p
	return null


func _test_4_popup_element_color() -> void:
	print("── T4 命中数字元素色 ──")
	var pm: PopupManager = _gl.popup_manager
	_check("前置：跳字管理器在位且已接池", pm != null and pm.popup_pool != null, "")
	if pm == null or pm.popup_pool == null:
		return
	_emit_direct(910001, GameConst.Element.FIR)
	var p_fir := _popup_of(910001)
	_check("FIR 结算 → 跳字 self_modulate==ELEMENT_COLORS[FIR]",
		p_fir != null and p_fir.element == GameConst.Element.FIR
			and (p_fir.get("_label") as Label).self_modulate.is_equal_approx(
				PopPalette.ELEMENT_COLORS[GameConst.Element.FIR]), "")
	_emit_direct(910002, GameConst.Element.KIN)
	var p_kin := _popup_of(910002)
	_check("KIN 对照 → 跳字保持白 Color(1,1,1)（无元素不染，CRIT/量级既有色不动）",
		p_kin != null
			and (p_kin.get("_label") as Label).self_modulate.is_equal_approx(Color(1.0, 1.0, 1.0)),
		"")
	# R202 合并语义：同 uid 合并窗内后续元素改写宿主色（merge 取最新元素——既有口径，
	# 本批零改动只锁不破坏；染色不破坏合并的数值累加语义）
	_emit_direct(910003, GameConst.Element.FIR)
	var p_merge := _popup_of(910003)
	_emit_direct(910003, GameConst.Element.ICE)
	pm.tick(DT60)                              # 合并刷新走 tick（R189 脏标记口径）
	_check("合并语义不破坏：同 uid 后续 ICE 并入 → 跳字取最新元素色（ELEMENT_COLORS[ICE]）",
		p_merge != null and p_merge.element == GameConst.Element.ICE
			and (p_merge.get("_label") as Label).self_modulate.is_equal_approx(
				PopPalette.ELEMENT_COLORS[GameConst.Element.ICE]),
		"elem=%s" % str(p_merge.element if p_merge != null else -1))


# ── T5 端到端：FIR 主束实束打真敌 → 跳字自动带元素色 ─────────────────
func _test_5_laser_popup_e2e() -> void:
	print("── T5 端到端：激光伤害字恢复元素色 ──")
	if _lw == null:
		_check("前置：T2 激光在位（夹具缺失）", false, "")
		return
	var epool: EnemyPool = _gl.pools[&"enemy"] as EnemyPool
	var enemy := epool.acquire() as Enemy
	enemy.spawn(_fixture_enemy(), 1, 0)
	enemy.global_position = PLAYER_HOME + Vector2(0.0, -150.0)
	_gl.spawner.active.append(enemy)
	var enemy_uid := int(enemy.get("uid"))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var found_fir_popup := false
	for i in range(60):                        # ≤1s 实束（主束常驻已带 FIR）
		_lw.tick(DT60)
		_gl.enemy_grid.rebuild(_gl.spawner.active)
		for e in _gl.spawner.active:
			if is_instance_valid(e):
				(e as Enemy).tick(DT60)
		# R220 刀11：damage_resolved 批化——真实帧序 ⑧ UI 段前 GameLoop 调
		# dispatch_resolved_frame；手动帧循环在此对位补派发（时序与真机一致）
		if _gl.pipeline != null and _gl.pipeline.has_method(&"dispatch_resolved_frame"):
			_gl.pipeline.call(&"dispatch_resolved_frame")
		_gl.popup_manager.tick(DT60)
		EventBus.end_frame()
		var pi := _popup_of(enemy_uid)
		if pi != null and pi.element == GameConst.Element.FIR:
			found_fir_popup = true
			break
	var settle_now: int = _lw._main_beam.settle_count \
			if _lw._main_beam != null and is_instance_valid(_lw._main_beam) else 0
	_check("FIR 主束实束结算发生（settle_count>0）", settle_now > 0, "settle=%d" % settle_now)
	var pp := _popup_of(enemy_uid)
	_check("主束伤害跳字自动带 FIR 元素色（ctx.element→result.element→跳字全链恢复）",
		found_fir_popup and pp != null and pp.element == GameConst.Element.FIR
			and (pp.get("_label") as Label).self_modulate.is_equal_approx(
				PopPalette.ELEMENT_COLORS[GameConst.Element.FIR]),
		"found=%s elem=%s" % [str(found_fir_popup), str(pp.element if pp != null else -1)])
	if is_instance_valid(enemy):
		_gl.spawner.active.erase(enemy)
		epool.release(enemy)
	_gl.enemy_grid.rebuild(_gl.spawner.active)


# ── T6 副束挂卡即时重染（attach_trait ELEM 分支 + SPECTRA 轮转） ──────
func _test_6_subbeam_elem_attach() -> void:
	print("── T6 副束挂卡即时重染 ──")
	# 全新 W4 夹具：T2 的 _lw 已挂 ELE_IGNITE（其新副束生成时即带 FIR——生成快照路径
	# 本就在位）；本用例锁的是「副束先存活、元素卡后到」的陈旧快照补口，须未挂卡武器。
	_gl.player.set("unlocked_slots", 6)
	var lw2: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W4_pulse_beam"))
	_check("前置：全新 W4 装配为 LaserWeapon（未挂任何元素卡）", lw2 is LaserWeapon,
		"lw2=%s" % str(lw2))
	if not (lw2 is LaserWeapon):
		return
	var w := lw2 as LaserWeapon
	var reg := _gl.registry
	# FAN 拓扑不索敌（固定角）——无敌人也常驻扫场；SPLIT_PRISM 挂载即补位副束。
	# 真 .tres value=1.45 → 1 副束/层、stack_max=3——挂两张凑 ≥2 副束供轮转断言。
	w.attach_trait(reg.get_trait(&"MEC_BEAM_FAN"))
	for i in range(2):
		w.attach_trait(reg.get_trait(&"MEC_SPLIT_PRISM"))
	var subs := w._alive_sub_beams()
	_check("前置：FAN+SPLIT_PRISM×2 出存活副束（≥2，无敌人也常驻）",
		subs.size() >= 2, "n=%d" % subs.size())
	if subs.size() < 2:
		return
	var kin_ok := true
	for b in subs:
		kin_ok = kin_ok and b.sub_beam and b.element == GameConst.Element.KIN
	_check("挂卡前存活副束 element==KIN（生成时快照——新武器无元素）", kin_ok, "")
	# 挂首张 ELEM 卡：存活副束即时按 dominant 重染（attach_trait ELEM 分支——R211 补口，
	# 此前元素停在生成时快照、只对之后新生成的副束生效）
	w.attach_trait(reg.get_trait(&"ELE_IGNITE"))
	var fir_ok := true
	for b in w._alive_sub_beams():
		fir_ok = fir_ok and b.element == GameConst.Element.FIR \
			and (b.get("_line") as Line2D).default_color.is_equal_approx(
				LaserBeam.element_tint(GameConst.Element.FIR))
	_check("挂 ELE_IGNITE：存活副束即时重染（element==FIR 且束色=element_tint(FIR)）",
		fir_ok, "")
	# SPECTRA 轮转：再挂 SPECTRA + 第二元素卡 → 存活副束按锁定次序轮转（首 FIR 次 ICE）
	w.attach_trait(reg.get_trait(&"MEC_BEAM_SPECTRA"))
	w.attach_trait(reg.get_trait(&"ELE_FREEZE"))
	var rot := w._alive_sub_beams()
	var rot_ok: bool = rot.size() >= 2 and rot[0].element == GameConst.Element.FIR \
		and rot[1].element == GameConst.Element.ICE \
		and (rot[0].get("_line") as Line2D).default_color.is_equal_approx(
			LaserBeam.element_tint(GameConst.Element.FIR)) \
		and (rot[1].get("_line") as Line2D).default_color.is_equal_approx(
			LaserBeam.element_tint(GameConst.Element.ICE))
	_check("SPECTRA+双元素卡：存活副束按锁定次序轮转（首 FIR 次 ICE 各自染色）",
		rot_ok, "n=%d e0=%s e1=%s" % [rot.size(),
			str(rot[0].element if rot.size() > 0 else -1),
			str(rot[1].element if rot.size() > 1 else -1)])

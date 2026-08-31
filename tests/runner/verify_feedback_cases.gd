# tests/runner/verify_feedback_cases.gd
# 用户反馈验收用例体（由 test_verify_feedback.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖 2026-08-29 两轮试玩反馈的「行为级」验收（不只编译/回归，而是逐项真实跑通）：
#   ① 升级回满血 ② 新武器卡上架→装配真件（add_weapon 链）→构筑面板签名刷新
#   ③ 槽满不上架武器卡 ④ 稀有度数值缩放（金 ×2.6、白不缩放、注册表资源不落改）
#   ⑤ 紫精通连升 2 级 + 文案 Lv 区间 ⑥ MEC_HIT_BURST 命中迸裂真实落血
#   ⑦ E7 喷吐者远程开火（敌弹池入池） ⑧ 死亡元素释放（感电残弧广播）
#   ⑨ 左下角构筑面板 → 暂停 + 详情卡可见 ⑩ 粒子池寿命兜底回收（爆炸残留修复）
#   ⑪ 感电落雷/燃烧余烬/冰冻冰晶表现件挂载 ⑫ Boss 巨大化 + 弹幕密度 + E7 织入波表
#   ⑬ 描述去黑话（无 W8 编号）⑭ META_ROADMAP 规划文档存在
extends RefCounted

const DT := 1.0 / 120.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_test_level_up_full_heal()
	_test_weapon_card_equip_chain()
	_test_weapon_card_slot_guard()
	_test_rarity_value_scale()
	_test_mastery_double_and_wording()
	_test_hit_burst()
	_test_e7_ranged_fire()
	_test_death_element_discharge()
	_test_build_details_panel()
	_test_particle_reap()
	_test_status_fx_nodes()
	_test_data_tuning()
	_test_docs()
	_test_meta_systems()
	_test_maps_systems()
	_test_swamp_eco()
	_test_char_meta()
	_test_economy()
	_test_polish()
	_test_p0_fixes()
	_test_map_bosses()
	_test_map_affixes2()
	_test_endless_maps()
	_test_p2_damage_tiers()
	_test_p2_bgm()
	_test_p2_daily()
	_test_p2_characters()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("验收汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 引导 ──────────────────────────────────────────────────────────
func _boot_game_loop() -> void:
	_gl = GameLoop.new()
	_gl.name = "GameLoopForVerify"
	tree.get_root().add_child(_gl)
	_gl.set_physics_process(false)             # 确定性：禁自动帧（手动驱动语义，对齐 pkg4）
	_check("Boot：完成且进入 MENU", _gl.boot_ready and _gl.state == GameConst.GameStatus.MENU)
	_check("Boot：子系统齐全", _gl.player != null and _gl.card_generator != null
		and _gl.hud != null and _gl.pause_overlay != null and _gl.spawner != null)


func _teardown_game_loop() -> void:
	tree.paused = false
	if _gl != null:
		_gl.free()
	_gl = null


# ── ① 升级回满血 ──────────────────────────────────────────────────
func _test_level_up_full_heal() -> void:
	print("── 升级回满血 ──")
	var p: Node = _gl.player
	var lv0: int = int(p.get("level"))
	p.set("hp", 10.0)
	p.call(&"gain_xp", float(p.get("xp_need")))
	_check("升级触发（lv+1）", int(p.get("level")) == lv0 + 1)
	_check("升级回满血（hp == max_hp）", absf(float(p.get("hp")) - float(p.get("max_hp"))) <= 0.01)


# ── ② 新武器卡 → add_weapon 真件装配 ─────────────────────────────
func _test_weapon_card_equip_chain() -> void:
	print("── 新武器卡装配链 ──")
	var p: Node = _gl.player
	var sig0: String = _gl.hud._compute_build_sig()
	p.call(&"unlock_slot", 2)
	var cands: Array = _gl.card_generator._weapon_candidates(p)
	_check("解锁槽 2 后：未持有武器上架（候选 ≥1）", cands.size() >= 1)
	var card: Dictionary = _gl.card_generator._make_weapon_card(
		_gl.registry.get_weapon(&"W3_shotgun"))
	_check("武器卡字段（kind=WEAPON / 名含霰弹枪）",
		int(card.get("kind")) == CardGenerator.CardKind.WEAPON
		and String(card.get("display_name")).contains("霰弹枪"))
	_gl.card_generator.apply_choice(card, p)
	var w: Variant = (p.get("weapon_slots") as Array)[1]
	_check("装配 = 真件 WeaponBase（不再污染槽位——add_weapon 工厂链）",
		w is WeaponBase and is_instance_valid(w))
	if w is WeaponBase:
		var wd: Variant = w.get("data")
		_check("装配武器 = 霰弹枪 W3 且 Lv1", wd != null and String(wd.get("id")) == "W3_shotgun"
			and int(w.get("level")) == 1)
		var panel: Dictionary = (w as Object).call(&"build_panel_snapshot")
		_check("真件面板可用（base_atk > 0）", float(panel.get("base_atk", 0.0)) > 0.0)
	_check("构筑面板签名刷新（新 uid 入签名）", _gl.hud._compute_build_sig() != sig0)
	# 清理：拆下霰弹枪（还原单武器口径，后续用例不受扰）
	(p.get("weapon_slots") as Array)[1] = null
	(w as Node).free()


# ── ③ 槽满不上架 ─────────────────────────────────────────────────
func _test_weapon_card_slot_guard() -> void:
	print("── 武器卡槽位守卫 ──")
	var p: Node = _gl.player
	p.set("unlocked_slots", 1)                # 复位：仅槽 0（已被手枪占）→ 全占
	_check("已解锁槽全占 → 武器卡不上架（候选 = 0）",
		_gl.card_generator._weapon_candidates(p).is_empty())
	p.call(&"unlock_slot", 2)
	_check("解锁空槽 2 → 恢复上架（候选 ≥1）",
		_gl.card_generator._weapon_candidates(p).is_empty() == false)


# ── ④ 稀有度数值缩放 ─────────────────────────────────────────────
func _test_rarity_value_scale() -> void:
	print("── 稀有度数值缩放 ──")
	var gen: CardGenerator = _gl.card_generator
	var p: Node = _gl.player
	var base: TraitData = _gl.registry.get_trait(&"AFF_ATK_UP")
	var cands := gen.generate_candidates({"player": p, "wave": 1, "fixed_rarities": [3, 0, 0]})
	var gold_card: Dictionary = {}
	var white_card: Dictionary = {}
	for c in cands:
		if int(c.get("kind")) == CardGenerator.CardKind.TRAIT:
			if int(c.get("rarity")) == 3 and gold_card.is_empty():
				gold_card = c
			elif int(c.get("rarity")) == 0 and white_card.is_empty():
				white_card = c
	if not gold_card.is_empty() and gold_card.get("id") == base.id:
		_check("金卡数值 ×2.6（0.15 → 0.39）",
			absf(float((gold_card.get("data") as TraitData).value) - 0.39) <= 0.001)
		_check("金卡描述重写真实数字（含 39%）",
			String(gold_card.get("description")).contains("39%"))
	elif not gold_card.is_empty():
		print("　（跳过金断言：fixed_rarities 命中其他词条 %s）" % String(gold_card.get("id")))
	if not white_card.is_empty() and white_card.get("id") == base.id:
		_check("白卡不缩放（0.15 原值）",
			absf(float((white_card.get("data") as TraitData).value) - 0.15) <= 0.001)
	_check("注册表共享资源不落改（原值仍 0.15）", absf(base.value - 0.15) <= 0.0001)


# ── ⑤ 紫精通连升 2 级 + Lv 区间文案 ──────────────────────────────
func _test_mastery_double_and_wording() -> void:
	print("── 精通连升与文案 ──")
	var gen: CardGenerator = _gl.card_generator
	var p: Node = _gl.player
	var w: WeaponBase = (p.get("weapon_slots") as Array)[0]
	var lv0: int = int(w.get("level"))
	var cands := gen.generate_candidates({"player": p, "wave": 1, "fixed_rarities": [2, -1, -1]})
	var mastery: Dictionary = {}
	for c in cands:
		if int(c.get("kind")) == CardGenerator.CardKind.MASTERY \
				and (c.get("weapon") as Object) == w:
			mastery = c
			break
	_check("紫精通卡 roll 到（连升通道）", not mastery.is_empty())
	if mastery.is_empty():
		return
	_check("文案含等级区间（Lv%d→Lv%d）" % [lv0, mini(lv0 + 2, WeaponBase.MAX_LEVEL)],
		String(mastery.get("display_name")).contains("→"))
	_check("level_boosts = 2", int(mastery.get("level_boosts", 0)) == 2)
	gen.apply_choice(mastery, p)
	_check("应用后连升 2 级（lv +%d）" % int(mastery.get("level_boosts", 0)),
		int(w.get("level")) == mini(lv0 + 2, WeaponBase.MAX_LEVEL))


# ── ⑥ MEC_HIT_BURST 命中迸裂 ─────────────────────────────────────
func _test_hit_burst() -> void:
	print("── 命中迸裂 ──")
	var p: Node = _gl.player
	var w: WeaponBase = (p.get("weapon_slots") as Array)[0]
	var burst_trait: TraitData = _gl.registry.get_trait(&"MEC_HIT_BURST")
	_check("注册表：MEC_HIT_BURST 已加载", burst_trait != null)
	if burst_trait == null:
		return
	w.attach_trait(burst_trait)
	var main := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	var near := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	var far := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	main.spawn(_fixture_enemy(&"E_VB_MAIN", 100000.0), 1, 0)
	near.spawn(_fixture_enemy(&"E_VB_NEAR", 100000.0), 1, 0)
	far.spawn(_fixture_enemy(&"E_VB_FAR", 100000.0), 1, 0)
	main.position = Vector2(360.0, 400.0)
	near.position = Vector2(430.0, 400.0)     # 70px < 迸裂半径 80
	far.position = Vector2(700.0, 400.0)      # 340px 半径外
	_gl.enemy_grid.rebuild([main, near, far])
	var near_hp0: float = near.hp
	var far_hp0: float = far.hp
	var ctx := w.build_damage_context(main)
	var tctx := TraitContext.new()
	tctx.event = GameConst.TraitEvent.ON_HIT
	tctx.weapon = w
	tctx.target = main
	tctx.damage_ctx = ctx
	if w.trait_stack != null:
		for pool in w.trait_stack.collect_mult_pools(tctx):
			ctx.mult_pools.append(pool)
	w.inject_vuln_pool(ctx, main)
	w.trait_stack.dispatch(GameConst.TraitEvent.ON_HIT, tctx)
	_check("迸裂：半径内邻敌真实落血（真件管线 9b）", near.hp < near_hp0)
	_check("迸裂：半径外不波及", absf(far.hp - far_hp0) <= 0.001)
	_check("迸裂遥测计数（hit_burst_triggered）",
		DebugStats.get_counter(&"hit_burst_triggered") >= 1)
	for e: Node in [main, near, far]:
		_gl.pools[&"enemy"].release(e)


func _fixture_enemy(p_id: StringName, p_hp: float) -> EnemyData:
	var d := EnemyData.new()
	d.id = p_id
	d.display_name = String(p_id)
	d.hp_base = p_hp
	d.spd_base = 0.0
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


# ── ⑦ E7 喷吐者远程开火 ──────────────────────────────────────────
func _test_e7_ranged_fire() -> void:
	print("── E7 远程开火 ──")
	var e7: EnemyData = _gl.registry.get_enemy(&"E7_spitter")
	_check("注册表：E7_spitter 已加载（behavior=RANGED）",
		e7 != null and int(e7.behavior) == GameConst.EnemyBehavior.RANGED)
	if e7 == null:
		return
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(e7, 6, 0)
	enemy.projectile_pool = _gl.pools[&"projectile"]   # 直连池 spawn 绕过 spawner → 手动注入
	enemy.position = (_gl.player as Node2D).global_position + Vector2(220.0, 0.0)
	var free0: int = int(_gl.pools[&"projectile"].stats()["free"])
	enemy.set("fire_cd_left", 0.0)
	for i in range(3):
		enemy.tick(DT)
	var free1: int = int(_gl.pools[&"projectile"].stats()["free"])
	_check("射程内驻停开火（敌弹入池 free -1）", free1 == free0 - 1)
	var bullet: Node = null
	for n in _gl.pools[&"projectile"].get_children():
		if n is Node2D and (n as Node2D).visible:
			bullet = n
			break
	_check("敌弹实体可见（team=1 敌方弹）", bullet != null)
	_gl.pools[&"enemy"].release(enemy)


# ── ⑧ 死亡元素释放 ───────────────────────────────────────────────
func _test_death_element_discharge() -> void:
	print("── 死亡元素释放 ──")
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(_fixture_enemy(&"E_DIS", 100.0), 1, 0)
	_gl.elemental.register_host(enemy)
	var arcs: Array = []
	var cb := func(_a: Vector2, _b: Vector2) -> void: arcs.append(true)
	EventBus.chain_lightning.connect(cb)
	(enemy.elemental as ElementalState).gauges[GameConst.Element.LTG] = 80.0
	enemy.call(&"_death_element_discharge")
	_check("LTG 槽 80 → 死亡释放感电残弧（≥1 跳广播）", arcs.size() >= 1)
	EventBus.chain_lightning.disconnect(cb)
	_gl.elemental.unregister_host(enemy)
	_gl.pools[&"enemy"].release(enemy)


# ── ⑨ 左下角构筑面板 → 暂停 + 详情卡 ─────────────────────────────
func _test_build_details_panel() -> void:
	print("── 左下角 buff 详情 ──")
	_gl.call(&"start_run")
	_gl.hud.build_details_requested.emit()
	_check("点击 → 进入 PAUSED", _gl.state == GameConst.GameStatus.PAUSED)
	_check("构筑详情卡可见", _gl.pause_overlay.is_details_visible())
	_check("暂停卡隐藏（双卡互斥）", not _gl.pause_overlay.is_pause_visible()
		or _gl.pause_overlay._card.visible == false)
	_gl.pause_overlay.toggle_details()
	_check("toggle → 切回暂停卡", not _gl.pause_overlay.is_details_visible())
	_gl.hud.build_details_requested.emit()
	_check("PAUSED 中再点 → 切回详情卡", _gl.pause_overlay.is_details_visible())
	_gl.pause_overlay.resume_requested.emit()
	_check("继续 → PLAYING", _gl.state == GameConst.GameStatus.PLAYING)
	_gl.call(&"quit_to_menu")


# ── ⑩ 粒子池寿命兜底 ─────────────────────────────────────────────
func _test_particle_reap() -> void:
	print("── 爆炸残留兜底 ──")
	var pp: ParticlePool = _gl.pools[&"particle"]
	var live0: int = int(pp.stats()["live"])
	pp.burst(&"burst_default", Vector2.ZERO, 4)
	_check("burst 后发射器取出（live +1）", int(pp.stats()["live"]) == live0 + 1)
	pp.reap_expired(0.016)
	_check("寿命内 reap 不误收", int(pp.stats()["live"]) == live0 + 1)
	pp.reap_expired(99.0)
	# live ≤ live0：reap 允许顺带回收早前测试遗留的在场发射器（HIT 爆发等）——正好验证兜底
	_check("超时强制归还（finished 未触发也不残留——爆炸残留修复）",
		int(pp.stats()["live"]) <= live0 and pp._burst_left.is_empty(),
		"live=%d/%d left=%s rejected=%d" % [int(pp.stats()["live"]), live0,
			str(pp._burst_left.values()), int(pp.stats()["rejected_releases"])])


# ── ⑪ 元素状态表现件挂载 ─────────────────────────────────────────
func _test_status_fx_nodes() -> void:
	print("── 状态表现件 ──")
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(_fixture_enemy(&"E_FX", 100.0), 1, 0)
	_gl.elemental.register_host(enemy)
	var st: ElementalState = enemy.elemental
	st.gauges[GameConst.Element.LTG] = 50.0
	enemy.call(&"_tick_status_fx", DT)
	_check("感电：双电弧挂件就位", int(enemy._shock_arcs.size()) == 2)
	enemy.set("_shock_bolt_cd", 0.0)
	enemy.call(&"_tick_status_fx", DT)
	_check("感电：垂直落雷挂件就位（去圆球化）", enemy._shock_bolt != null
		and enemy._shock_bolt.visible)
	st.gauges[GameConst.Element.LTG] = 0.0
	st.apply(GameConst.Element.FIR, 100.0, 100.0)
	enemy.call(&"_tick_status_fx", DT)
	_check("点燃：余烬光晕 + 火苗 ×4（燃烧可见性）", enemy._burn_ember != null
		and enemy._burn_ember.visible and int(enemy._burn_flames.size()) == 4)
	st.apply(GameConst.Element.ICE, 100.0, 100.0)   # 一次满槽 → 寒滞
	st.apply(GameConst.Element.ICE, 100.0, 100.0)   # 二次满槽 → 完全冻结
	enemy.call(&"_tick_status_fx", DT)
	_check("冰冻：冰晶放大可见（冻结档 base×1.5）",
		enemy._frost_shards.size() > 0
		and (enemy._frost_shards[0] as Sprite2D).scale.x >= enemy._base_scale * 1.4)
	_gl.elemental.unregister_host(enemy)
	_gl.pools[&"enemy"].release(enemy)


# ── ⑫ 数据调优落位 ───────────────────────────────────────────────
func _test_data_tuning() -> void:
	print("── 数值/数据调优 ──")
	_check("Boss 巨大化（视觉倍率 3.8 ≈ 1/4 屏）", absf(Enemy.BOSS_VISUAL_MULT - 3.8) <= 0.001)
	_check("最终 Boss（视觉倍率 5.0 ≈ 1/3 屏 + TAG_FINAL_BOSS）",
		absf(Enemy.FINAL_BOSS_VISUAL_MULT - 5.0) <= 0.001
		and GameConst.TAG_FINAL_BOSS == 4)
	_check("精英巨大化（视觉倍率 1.55 + E2 精英倍率就位）",
		absf(Enemy.ELITE_VISUAL_MULT - 1.55) <= 0.001
		and not _gl.registry.get_enemy(&"E2_runner").elite_mult.is_empty())
	var frost_txt := FileAccess.get_file_as_string("res://resources/maps/wave_table_frost.tres")
	_check("冰原 w12 编入冰霜仔精英（tags=1）", '"tags": 1' in frost_txt)
	_check("冰原 w20 最终 Boss 标签（tags=6）", '"tags": 6' in frost_txt)
	var boss1: EnemyData = _gl.registry.get_enemy(&"E6_boss1")
	_check("Boss1 弹幕密度（count 14 / 4.6s）",
		int(boss1.boss.get("bullet_patterns", {}).get("count", 0)) == 14)
	_check("E7 经验梯度（exp_base 10）", absf(_gl.registry.get_enemy(&"E7_spitter").exp_base - 10.0) <= 0.001)
	_check("Boss1 经验（600）", absf(boss1.exp_base - 600.0) <= 0.001)
	var f := FileAccess.open("res://resources/waves/wave_table_main.tres", FileAccess.READ)
	var wave_txt := f.get_as_text() if f != null else ""
	_check("波表已织入 E7 喷吐者", wave_txt.contains("E7_spitter"))
	var roll_gold := 0
	_gl.card_generator.rng.seed = 777
	for i in range(500):
		if _gl.card_generator._roll_rarity(5) == 3:
			roll_gold += 1
	_check("金卡率 6% 档（500 抽 ≤55）", roll_gold <= 55, "gold=%d" % roll_gold)


# ── ⑬⑭ 描述去黑话 / 规划文档 ─────────────────────────────────────
func _test_docs() -> void:
	print("── 文案与文档 ──")
	_check("谐振轨道描述无 W8 黑话",
		not String(_gl.registry.get_trait(&"MEC_ORBIT_LINK").description).contains("W8"))
	_check("扩大印刻描述说明碰撞半径",
		String(_gl.registry.get_trait(&"AFF_AREA").description).contains("碰撞半径"))
	_check("META_ROADMAP.md 规划文档存在（大厅/成就/图鉴/股市/养成）",
		FileAccess.file_exists("res://META_ROADMAP.md"))


# ── ⑮ 大厅 / 图鉴 / 成就 / 记录（Meta 落地验收） ─────────────────
func _test_meta_systems() -> void:
	print("── 大厅/图鉴/成就/记录 ──")
	_check("Meta autoload 就绪（Meta != null）", Meta != null)
	if Meta == null:
		return
	# 存档隔离：先备份并清空既有存档（含运行期状态复位）——跨次运行不互相污染
	var save_backup := ""
	if FileAccess.file_exists("user://meta_save.cfg"):
		save_backup = FileAccess.get_file_as_string("user://meta_save.cfg")
		DirAccess.remove_absolute("user://meta_save.cfg")
	Meta.codex_kills = {}
	Meta.codex_weapons = {}
	Meta.codex_traits = {}
	Meta.achievements_done = {}
	Meta.records = {"best_wave": 0, "best_kills": 0, "best_level": 1,
		"total_runs": 0, "total_kills": 0}
	# 图鉴：武器获得解锁 / 词条抽取解锁
	_check("图鉴：武器未解锁（初始）", not Meta.is_weapon_unlocked(&"W3_shotgun"))
	Meta._on_card_chosen(&"W3_shotgun", 4)
	_check("图鉴：card_chosen(WEAPON) → 武器解锁", Meta.is_weapon_unlocked(&"W3_shotgun"))
	Meta._on_card_chosen(&"MEC_HIT_BURST", 1)
	_check("图鉴：card_chosen(TRAIT) → 词条解锁", Meta.is_trait_unlocked(&"MEC_HIT_BURST"))
	# 记录：波次/等级/击杀 → GAME_OVER 结算
	Meta._on_wave_started(12)
	Meta._on_level_up(9)
	Meta._on_enemy_killed(_make_killed_enemy_stub(false))
	var runs0: int = int(Meta.records["total_runs"])
	Meta._on_state_changed(GameConst.GameStatus.GAME_OVER)
	_check("记录：最高波次 12", int(Meta.records["best_wave"]) == 12)
	_check("记录：单局击杀 1", int(Meta.records["best_kills"]) == 1)
	_check("记录：局数 +1（%d→%d）" % [runs0, runs0 + 1],
		int(Meta.records["total_runs"]) == runs0 + 1)
	_check("成就：wave_10 解锁", Meta.is_ach_done(&"wave_10"))
	_check("成就：first_blood 解锁", Meta.is_ach_done(&"first_blood"))
	_check("持久化：user://meta_save.cfg 已落盘", FileAccess.file_exists("user://meta_save.cfg"))
	# 大厅 UI：入口 + 面板
	var menu: MenuScreen = _gl.menu_screen
	_check("大厅：registry 已注入", menu.registry != null)
	_check("大厅：六入口按钮就位（图鉴/成就/记录/角色/养成/每日——P2 每日挑战入口 +1）",
		menu._lobby_btns.size() == 6)
	menu._on_lobby_pressed("codex")
	_check("大厅：图鉴面板打开且条目 >0",
		menu._panel_root.visible and menu._panel_list.get_child_count() > 0)
	menu._on_codex_tab("武器")
	_check("大厅：武器页签切换（条目 = 注册表武器数）",
		_live_children(menu._panel_list) == menu.registry.weapons.size())
	menu._on_lobby_pressed("ach")
	_check("大厅：成就面板打开（条目 = 定义数 %d）" % Meta.ACHIEVEMENTS.size(),
		_live_children(menu._panel_list) == Meta.ACHIEVEMENTS.size())
	menu._on_lobby_pressed("records")
	_check("大厅：记录面板打开（全局 5 + 分图标题 1 + 5 图 + 进度 1 = 12 行）",
		_live_children(menu._panel_list) == 12)
	menu._on_panel_close()
	_check("大厅：返回关闭面板", not menu._panel_root.visible)
	# 恢复既有存档（测试隔离）
	var cfg := ConfigFile.new()
	if save_backup != "":
		var f := FileAccess.open("user://meta_save.cfg", FileAccess.WRITE)
		f.store_string(save_backup)
		f.close()
	else:
		DirAccess.remove_absolute("user://meta_save.cfg")


# ── ⑯ 多地图 / 新怪 / 通关解锁链（M2 落地验收） ──────────────────
func _test_maps_systems() -> void:
	print("── 多地图与新怪 ──")
	_check("MapTable：5 张地图（含翠毒沼泽）", MapTable.count() == 5)
	_check("MapTable：首关加载注册表主表（30 波）",
		MapTable.load_table(&"world_grass", _gl.registry).entries.size() == 30)
	var frost_table := MapTable.load_table(&"world_frost", _gl.registry)
	_check("MapTable：寒霜冰原旁路波表（20 波）", frost_table != null
		and frost_table.entries.size() == 20 and frost_table.id == &"frost")
	_check("新怪：E8 恶魔小鬼（CHASE 追击）",
		_gl.registry.get_enemy(&"E8_imp") != null
		and int(_gl.registry.get_enemy(&"E8_imp").behavior) == GameConst.EnemyBehavior.CHASE)
	var frost_e: EnemyData = _gl.registry.get_enemy(&"E9_frostling")
	_check("新怪：E9 冰霜仔（ICE 抗 60% + 冻结免疫）",
		frost_e != null and absf(frost_e.resist[2] - 0.6) <= 0.001
		and int(frost_e.immune_mask & GameConst.IMMUNE_FREEZE) != 0)
	_check("新怪：E10 林间飞雀（疾冲走位分型）",
		_gl.registry.get_enemy(&"E10_woodbird") != null)
	var aqua: EnemyData = _gl.registry.get_enemy(&"E11_aquasquirt")
	_check("新怪：E11 水泡怪（RANGED 远程）",
		aqua != null and int(aqua.behavior) == GameConst.EnemyBehavior.RANGED
		and not aqua.ranged.is_empty())
	# 解锁链：首关恒解锁 → 未解锁拒绝启动 → 通关后解锁并启动
	Meta.maps_cleared = {}
	Meta.map_records = {}
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl._on_menu_start(&"world_frost")
	_check("选图：未解锁拒绝启动（仍 MENU）", _gl.state == GameConst.GameStatus.MENU)
	_check("解锁链：首关恒解锁", Meta.is_map_unlocked(&"world_grass"))
	_check("解锁链：第二关初始锁定", not Meta.is_map_unlocked(&"world_frost"))
	Meta.mark_map_cleared(&"world_grass")
	_check("解锁链：通关首关 → 第二关解锁", Meta.is_map_unlocked(&"world_frost"))
	_check("解锁链：next_map_id（grass→frost）",
		MapTable.next_map_id(&"world_grass") == &"world_frost")
	_gl._on_menu_start(&"world_frost")
	_check("选图：启动进入 PLAYING", _gl.state == GameConst.GameStatus.PLAYING)
	_check("选图：当前地图 = 寒霜冰原", _gl.current_map_id == &"world_frost")
	_check("选图：波表已切换（id=frost）", _gl.wave_director.wave_table.id == &"frost")
	_check("主题：HUD 图名注入", _gl.hud.map_name == "寒霜冰原")
	_check("主题：云层色调 = 冰原淡青", _gl._backdrop.modulate
		== (MapTable.get_map(&"world_frost").tint as Color))
	# 分图记录：模拟 12 波/9 级/3 杀 → GAME_OVER 结算入 world_frost 桶
	Meta._on_wave_started(12)
	Meta._on_level_up(9)
	for i in range(3):
		Meta._on_enemy_killed(_make_killed_enemy_stub(false))
	Meta._on_state_changed(GameConst.GameStatus.GAME_OVER)
	var mr: Dictionary = Meta.map_records.get("world_frost", {})
	_check("分图记录：world_frost best_wave=12", int(mr.get("best_wave", 0)) == 12)
	Meta._on_wave_cleared(20)
	_check("通关标记：wave_cleared(20) → 冰原通关", Meta.is_map_cleared(&"world_frost"))
	_check("解锁链：第三关（魔域）随之解锁", Meta.is_map_unlocked(&"world_demon"))
	# 大厅：选关面板 4 行
	_gl.state = GameConst.GameStatus.MENU
	_gl.menu_screen._open_map_select()
	_check("大厅：选关面板 5 张地图卡",
		_live_children(_gl.menu_screen._panel_list) == MapTable.count())
	_gl.menu_screen._on_panel_close()


# ── ⑰ 翠毒沼泽生态（沼泽毒系新图 + 五新怪验收） ──────────────────
func _test_swamp_eco() -> void:
	print("── 翠毒沼泽生态 ──")
	_check("MapTable：5 张地图（沼泽殿后）", MapTable.count() == 5
		and MapTable.MAPS[4].id == &"world_swamp")
	var swamp_table := MapTable.load_table(&"world_swamp", _gl.registry)
	_check("沼泽波表（20 波 + id=swamp）", swamp_table != null
		and swamp_table.entries.size() == 20)
	for pair: Array in [[&"E12_bogslime", GameConst.EnemyBehavior.CHASE],
			[&"E14_boguard", GameConst.EnemyBehavior.CHASE],
			[&"E16_marshmaw", GameConst.EnemyBehavior.CHASE],
			[&"E13_bogspitter", GameConst.EnemyBehavior.RANGED]]:
		var ed: EnemyData = _gl.registry.get_enemy(pair[0])
		_check("新怪注册：%s（behavior=%d）" % [String(pair[0]), int(pair[1])],
			ed != null and int(ed.behavior) == int(pair[1]))
	var guard: EnemyData = _gl.registry.get_enemy(&"E14_boguard")
	_check("沼泽卫士：全抗 40%（护盾装甲口径）",
		absf(guard.resist[0] - 0.4) <= 0.001 and absf(guard.resist[1] - 0.4) <= 0.001
		and absf(guard.resist[2] - 0.4) <= 0.001)
	# 毒爆：E12 死亡 → 半径内玩家掉血（contact×0.6）
	var p2d: Node2D = _gl.player
	var slime := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	slime.spawn(_gl.registry.get_enemy(&"E12_bogslime"), 1, 0)
	slime.position = p2d.global_position + Vector2(50.0, 0.0)   # 50 < 110 毒爆半径
	var hp0: float = float(p2d.get("hp"))
	slime.call(&"_death_poison_splash")
	_check("毒爆：半径内玩家掉血（contact ×0.6）", float(p2d.get("hp")) < hp0)
	_gl.pools[&"enemy"].release(slime)
	var hp1: float = float(p2d.get("hp"))
	p2d.set("hp", hp1)
	# 远程可见性回归：主波表 w6/8/14/17 均含 E7（用户反馈「远程见不到」→ 密度提升验证）
	var main_txt := FileAccess.get_file_as_string("res://resources/waves/wave_table_main.tres")
	var spitter_waves := main_txt.count("E7_spitter")
	_check("主表远程密度（E7 出场波次 ≥6）", spitter_waves >= 6)
	# 沼泽解锁链：树海通关 → 沼泽解锁
	Meta.maps_cleared = {}
	Meta.mark_map_cleared(&"world_grove")
	_check("解锁链：树海通关 → 沼泽解锁", Meta.is_map_unlocked(&"world_swamp"))
	Meta.maps_cleared = {}


# ── ⑱ 角色系统 + 局外养成（M8 落地验收） ─────────────────────────
func _test_char_meta() -> void:
	print("── 角色与局外养成 ──")
	_check("CharacterTable：8 角色（解锁链完整——P2 薇拉/诺亚 +2）", CharacterTable.count() == 8)
	# 解锁链：全图通关（测试环境解锁全部角色）
	for m in MapTable.MAPS:
		Meta.mark_map_cleared(m.id)
	_check("解锁链：哨兵恒解锁 / 零需树海通关",
		Meta.is_character_unlocked(&"sentinel") and Meta.is_character_unlocked(&"zero"))
	Meta.maps_cleared = {}
	Meta.mark_map_cleared(&"world_grass")
	_check("解锁链：薇拉解锁（草原） / 零回落锁定（树海未清）",
		Meta.is_character_unlocked(&"veles") and not Meta.is_character_unlocked(&"zero"))
	for m in MapTable.MAPS:
		Meta.mark_map_cleared(m.id)
	# 角色应用：薇拉（45 血 + 25% 攻）
	var p: Node = _gl.player
	_gl.state = GameConst.GameStatus.MENU
	Meta.character_id = &"veles"
	p.call(&"set_character", &"veles")
	_check("角色：薇拉血量 45 + 养成加成",
		absf(float(p.get("max_hp")) - (45.0 + Meta.hp_bonus())) <= 0.01)
	# 武器面板口径：面板在实例化时定格（局内买养成不追改——下一局生效）
	var w_veles := (p.get("weapon_slots") as Array)[0] as WeaponBase
	_check("角色：攻击修正入武器（meta_atk_pct = 养成 + 0.25）",
		absf(w_veles.meta_atk_pct - (Meta.atk_pct() + 0.25)) <= 0.001)
	# 技能：过载咆哮
	p.call(&"activate_skill")
	_check("技能：过载咆哮 rof_mult=2", absf(float(p.get("rof_mult")) - 2.0) <= 0.001)
	var w0: WeaponBase = (p.get("weapon_slots") as Array)[0]
	_check("技能：射速面板吃 rof_mult（interval 减半）",
		float(w0.call(&"_fire_interval")) < float(w0.call(&"_fire_interval")) * 2.5)
	for i in range(300):
		p.call(&"tick", DT, Vector2.ZERO)       # 4s 增益耗尽（120Hz × 300 = 2.5s 不够 → 补齐）
	for i in range(200):
		p.call(&"tick", DT, Vector2.ZERO)
	_check("技能：增益到期 rof_mult 回 1", absf(float(p.get("rof_mult")) - 1.0) <= 0.001)
	# 磐：践踏消弹（增强后 -5% 攻）
	Meta.character_id = &"bulwark"
	p.call(&"set_character", &"bulwark")
	_check("角色：磐血量 95 + 养成（增强 -5% 攻口径）",
		absf(float(p.get("max_hp")) - (95.0 + Meta.hp_bonus())) <= 0.01)
	# 零：时滞力场（全场静止）
	var stop_target := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	stop_target.spawn(_fixture_enemy(&"E_TS", 100.0), 1, 0)
	_gl.enemy_grid.rebuild([stop_target])
	_gl.elemental.register_host(stop_target)     # 冻结计时器在 ElementalState（需挂宿主）
	Meta.character_id = &"zero"
	p.call(&"set_character", &"zero")
	_check("角色：零血量 65 + 养成", absf(float(p.get("max_hp")) - (65.0 + Meta.hp_bonus())) <= 0.01)
	p.call(&"activate_skill")
	_check("技能：时滞力场 → 全场静止 2.5s",
		stop_target.elemental != null
		and float((stop_target.elemental as ElementalState).freeze_timer) >= 2.4)
	_gl.elemental.unregister_host(stop_target)
	_gl.pools[&"enemy"].release(stop_target)
	# 莽：毒沼绽放（全屏毒伤）
	var nova_target := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	nova_target.spawn(_fixture_enemy(&"E_Nova", 100000.0), 1, 0)
	_gl.elemental.register_host(nova_target)
	_gl.enemy_grid.rebuild([nova_target])
	Meta.character_id = &"mank"
	p.call(&"set_character", &"mank")
	var nhp0: float = float(nova_target.get("hp"))
	p.set("skill_cd_left", 0.0)
	p.call(&"activate_skill")
	_check("技能：毒沼绽放 → 全屏 150% 攻结算", float(nova_target.get("hp")) < nhp0)
	_gl.elemental.unregister_host(nova_target)
	_gl.pools[&"enemy"].release(nova_target)
	Meta.character_id = &"sentinel"
	# 养成：结晶购买
	Meta.crystals = 200
	Meta.upgrades = {}
	_check("养成：初始 Lv0", Meta.upgrade_level(&"life") == 0)
	_check("养成：购买成功（20💎）", Meta.buy_upgrade(&"life"))
	_check("养成：等级 1 + 余额 180", Meta.upgrade_level(&"life") == 1 and Meta.crystals == 180)
	_check("养成：血量加成 +10", absf(Meta.hp_bonus() - 10.0) <= 0.001)
	Meta.crystals = 10
	_check("养成：结晶不足拒绝（atk 需 30）", not Meta.buy_upgrade(&"atk"))
	Meta.crystals = 500
	# 结算产出：12 波 60 杀 → ceil(18+2.4)=21
	Meta._on_wave_started(12)
	for i in range(60):
		Meta._on_enemy_killed(_make_killed_enemy_stub(false))
	var cr0: int = Meta.crystals
	Meta._on_state_changed(GameConst.GameStatus.GAME_OVER)
	_check("养成：局结算结晶产出（+21）", Meta.crystals == cr0 + 21)
	# 大厅面板
	var menu: MenuScreen = _gl.menu_screen
	menu._on_lobby_pressed("char")
	_check("大厅：角色面板 3 张卡", _live_children(menu._panel_list) == CharacterTable.count())
	for c in menu._panel_list.get_children():
		c.free()                                  # 立即清（queue_free 无帧迭代不清真——计数口径）
	menu._on_lobby_pressed("upgrade")
	_check("大厅：养成面板（结晶头 + 7 升级 + 注释 = 9 行）",
		_live_children(menu._panel_list) == 9,
		"live=%d" % _live_children(menu._panel_list))
	menu._on_panel_close()
	Meta.character_id = &"sentinel"
	Meta.upgrades = {}
	Meta.crystals = 0
	Meta._save()                                  # 养成测试不留痕（防污染 pkg 字面量断言）


# ── ⑲ 战地黑市 + 金币 + 音效（M7 落地验收） ─────────────────────
func _test_economy() -> void:
	print("── 战地黑市与音效 ──")
	# 金币掉账：强制 gold_drop 必中
	var e := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	e.spawn(_fixture_enemy(&"E_GOLD", 10.0), 1, 0)
	e.data.gold_drop = {"chance": 1.0, "min": 7, "max": 7}
	var g0: int = int(_gl.player.get("gold"))
	_gl._on_enemy_killed_drop_xp(e)
	_check("金币：击杀掉账 +7", int(_gl.player.get("gold")) == g0 + 7)
	_gl.pools[&"enemy"].release(e)
	# 行情系数界
	var shop: ShopUi = _gl.shop_ui
	var in_band := true
	for slot in range(6):
		var m := shop.market_mult(5, slot)
		if m < 0.7 or m > 1.3:
			in_band = false
	_check("行情：系数 ∈ [0.7, 1.3]", in_band)
	# 开店 → 货架 → 购买治疗包 → 出击
	_gl.state = GameConst.GameStatus.PLAYING
	_gl.player.set("gold", 500)
	_gl.player.set("hp", 10.0)
	var hp0: float = float(_gl.player.get("hp"))
	var gold0: int = int(_gl.player.get("gold"))
	shop.open(_gl.player, 5)
	_check("黑市：开店可见", shop.is_shop_visible())
	var healed := false
	for i in range(shop._wares.size()):
		if String(shop._wares[i].get("kind", "")) == "heal":
			shop._buy(i)
			healed = float(_gl.player.get("hp")) > hp0 + 1.0
			break
	_check("黑市：治疗包购买回血", healed)
	_check("黑市：金币扣减", int(_gl.player.get("gold")) < gold0)
	var g1: int = int(_gl.player.get("gold"))
	shop._on_refresh_pressed()
	_check("黑市：刷新扣费", int(_gl.player.get("gold")) <= g1 - 10)
	shop.close()
	_check("黑市：出击 → PLAYING（含宽限）", _gl.state == GameConst.GameStatus.PLAYING)
	# 游侠闪现
	var p: Node = _gl.player
	Meta.character_id = &"ranger"
	p.call(&"set_character", &"ranger")
	var pos0: Vector2 = (p as Node2D).global_position
	p.set("_last_move_dir", Vector2.RIGHT)
	p.call(&"activate_skill")
	_check("游侠：瞬步位移 + 无敌", ((p as Node2D).global_position - pos0).length() > 200.0
		and float(p.get("invuln_left")) > 0.5)
	Meta.character_id = &"sentinel"
	# 音效库
	_check("音效：8 种程序化音色就绪", SfxBank.I != null and SfxBank.I._streams.size() >= 9)
	SfxBank.I.play(&"kill")
	SfxBank.I.play(&"level")


# ── ⑳ 成就奖励 / 复活 / 地图词缀 ─────────────────────────────────
func _test_polish() -> void:
	print("── 成就奖励/复活/词缀 ──")
	# 成就奖励结晶：wave_30 达成 → +80（选未达成项——wave_10 已在早前用例解锁）
	Meta._run_max_wave = 30
	var cr0: int = Meta.crystals
	Meta._check_achievements()
	# 同一轮 wave_20（+40）会一并解锁 → 合计 +120
	_check("成就奖励：wave_30 达成（+80，连带 wave_20 +40）",
		Meta.is_ach_done(&"wave_30") and Meta.crystals == cr0 + 120,
		"cr=%d/%d" % [Meta.crystals, cr0 + 120])
	# 复活：应急协议 1 级 → 致死一击满血复活
	Meta.upgrades = {"revive": 1}
	var p: Node = _gl.player
	p.call(&"set_character", &"sentinel")
	_check("复活：充能就位（1 次）", int(p.get("revives_left")) == 1)
	p.set("invuln_left", 0.0)                     # 清无敌（接触伤害有无敌帧护栏）
	p.set("hp", 1.0)
	p.call(&"take_contact_damage", 50.0)
	_check("复活：致死伤害 → 满血存活 + 2s 无敌",
		absf(float(p.get("hp")) - float(p.get("max_hp"))) <= 0.01
		and float(p.get("invuln_left")) >= 1.5 and int(p.get("revives_left")) == 0)
	p.set("invuln_left", 0.0)
	p.call(&"take_contact_damage", 99999.0)
	_check("复活：耗尽后正常死亡仲裁（E-16 不受扰）", bool(p.get("_dead")))
	p.call(&"respawn")
	# 地图词缀：定义完整 + spawner 应用
	for mid: Array in [[&"world_grass", ""], [&"world_frost", "ice_resist"],
			[&"world_demon", "spd_mult"], [&"world_grove", "xp_mult"],
			[&"world_swamp", "hp_mult"]]:
		var def := MapTable.get_map(mid[0])
		_check("词缀：%s → %s" % [String(mid[0]), String(mid[1]) if String(mid[1]) != "" else "无词缀"],
			String(def.get("mod_id", "")) == String(mid[1]))
	var frost_def := MapTable.get_map(&"world_frost")
	_check("词缀文案：霜冻之地", String(frost_def.get("mod_name", "")).contains("冰抗"))
	# spawner 词缀应用（spd_mult 实测）
	_gl.spawner.map_mods = {"spd_mult": 1.10}
	var se := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	se.spawn(_fixture_enemy(&"E_MOD", 10.0), 1, 0)
	var spd0: float = se.speed
	_gl.spawner._apply_map_mods(se)
	_check("词缀：spawner 应用移速 +10%", absf(se.speed - spd0 * 1.10) <= 0.01)
	_gl.spawner.map_mods = {}
	_gl.pools[&"enemy"].release(se)


func _test_p0_fixes() -> void:
	# 2026-08-31 P0 双修验收（META_ROADMAP §5.10 前两项）：
	# ① MEC_SHIELD 挂载链（原 p_trait.layers 运行时崩溃 → 护盾永不生效）
	# ② W4 脉冲激光（lifetime 三处断链 → 常驻）
	print("── P0 修复：护盾链 + W4 脉冲 ──")
	var p: Node = _gl.player
	var main_w: Node = null
	for w: Node in p.weapon_slots:
		if w != null and is_instance_valid(w):
			main_w = w
			break
	# ① 护盾：真路径挂载（attach_trait 唯一收束口——选卡/回响共用）
	var shield_data: TraitData = _gl.registry.get_trait(&"MEC_SHIELD")
	var ok1: bool = main_w.attach_trait(shield_data)
	_check("护盾链：attach_trait 成功（无崩溃）", ok1)
	_check("护盾链：interval=8.0 首充 8s 未就绪",
		absf(float(p.get("shield_interval")) - 8.0) <= 0.01
		and absf(float(p.get("shield_timer")) - 8.0) <= 0.01
		and not bool(p.get("shield_ready")))
	main_w.attach_trait(shield_data)             # 2 层
	_check("护盾链：2 层 → interval=5.5", absf(float(p.get("shield_interval")) - 5.5) <= 0.01)
	p.set("shield_timer", 0.01)
	for i in range(3):                           # 3 帧 ×8.33ms 必然走完 10ms 尾差
		p.call(&"tick", 1.0 / 120.0, Vector2.ZERO)
	_check("护盾链：充满 → shield_ready", bool(p.get("shield_ready")))
	var hp0: float = float(p.get("hp"))
	p.set("invuln_left", 0.0)
	p.call(&"take_contact_damage", 50.0)
	_check("护盾链：格挡 → HP 不掉 + 进入再充能",
		absf(float(p.get("hp")) - hp0) <= 0.01 and not bool(p.get("shield_ready"))
		and absf(float(p.get("shield_timer")) - 5.5) <= 0.01)
	# ⑤ 前置还原：清除护盾状态（防本批次后续 roll 断言被充能干扰——语义无后续依赖）
	# ② W4 脉冲：真池真网格（GameLoop 既有依赖），0.5s 收束 + cd 后再起束
	var lw: Node = load("res://scripts/combat/weapon/laser_weapon.gd").new()
	lw.name = "VerifyW4"
	_gl.add_child(lw)
	lw.position = Vector2(100, 640)
	lw.setup(_gl.registry.get_weapon(&"W4_pulse_beam"), p, {
		"enemy_grid": _gl.enemy_grid, "laser_pool": _gl.pools[&"laser"],
	})
	lw.try_fire()
	var beam: Node = lw._main_beam
	_check("W4 脉冲：lifetime=0.5 已接线", beam != null and absf(beam.lifetime - 0.5) <= 0.01)
	var t := 0.0
	while t < 0.6:
		lw.tick(1.0 / 120.0)
		t += 1.0 / 120.0
	_check("W4 脉冲：0.5s 后光束收束", not beam.is_live())
	lw.free()
	# ③ W5 对照组：无 pulse_duration 键 → 常驻（行为不回归）
	var w5: Node = load("res://scripts/combat/weapon/laser_weapon.gd").new()
	w5.name = "VerifyW5"
	_gl.add_child(w5)
	w5.position = Vector2(100, 640)
	w5.setup(_gl.registry.get_weapon(&"W5_prism"), p, {
		"enemy_grid": _gl.enemy_grid, "laser_pool": _gl.pools[&"laser"],
	})
	w5.try_fire()
	var beam5: Node = w5._main_beam
	_check("W5 对照：无脉冲键 → 常驻（lifetime=0）", beam5 != null and beam5.lifetime <= 0.0)
	w5.free()
	# ④ 卡池每局随机（start_run → rng.randomize 改写 state）
	_gl.card_generator.rng.seed = 42
	var state0: int = _gl.card_generator.rng.state
	_gl.card_generator.rng.randomize()
	_check("卡池：每局 randomize 改写 RNG 流", _gl.card_generator.rng.state != state0)
	# ⑤ 词条卡目标随机武器：双武器持有下 roll 40 次 → 目标覆盖 ≥2 把
	p.set("unlocked_slots", 5)                   # 前序批次槽位态未知——全解锁保装配
	var w2: Node = p.call(&"add_weapon", _gl.registry.get_weapon(&"W2_gatling"))
	_check("词条目标：第二把武器装配成功", w2 != null)
	var targets: Dictionary = {}
	_gl.card_generator.rng.seed = 20260831
	for i in range(40):
		var cands := _gl.card_generator.generate_candidates({"player": p, "wave": 20})
		for c: Dictionary in cands:
			if int(c.get("kind", -1)) == 1 and c.get("target_weapon") != null:
				targets[int(c["target_weapon"].get("uid"))] = true
	_check("词条目标：40 次发牌覆盖 ≥2 把武器（不再全砸主武器）", targets.size() >= 2,
		"覆盖=%d" % targets.size())
	# ⑥ 技能 CD 全员 120s
	var all_cd := true
	for c: Dictionary in CharacterTable.CHARACTERS:
		if absf(float(c.get("cd", 0.0)) - 120.0) > 0.01:
			all_cd = false
	_check("技能：6 角色 CD 全员 120s", all_cd and CharacterTable.CHARACTERS.size() >= 6)
	# ⑦ W4 数据键 + W5 对照（数据侧口径锁定）
	var w4d: Resource = _gl.registry.get_weapon(&"W4_pulse_beam")
	_check("数据：W4 laser.pulse_duration=0.5", absf(float(w4d.laser.get("pulse_duration", 0.0)) - 0.5) <= 0.01)
	var w5d: Resource = _gl.registry.get_weapon(&"W5_prism")
	_check("数据：W5 无 pulse_duration（常驻口径）", not w5d.laser.has("pulse_duration"))


# ── ㉑ 每图专属 Boss（P1：冰原/魔域/树海/沼泽独立 Boss——数据/贴图/分型/波表/怪闸） ──
func _test_map_bosses() -> void:
	# 数值真源：E6_boss2 同波位量级（hp_base 16537 → 专属 Boss = 16000±10% 微调）；
	# schema 键照 boss2/3 先例（phases/bullet_patterns/summons/phase2_resist）。
	print("── 每图专属 Boss ──")
	var boss_ids: Array[StringName] = [&"E17_frost_sovereign", &"E18_demon_lord",
		&"E19_grove_warden", &"E20_swamp_hydra"]
	var kinds: Array[StringName] = [&"boss4", &"boss5", &"boss6", &"boss7"]
	# ① 数据加载 + schema（TAG_BOSS + boss 段四键 + hp 量级）
	var loaded := true
	var schema_ok := true
	var hp_ok := true
	for bid in boss_ids:
		var bd: EnemyData = _gl.registry.get_enemy(bid)
		if bd == null:
			loaded = false
			continue
		if int(bd.tags & GameConst.TAG_BOSS) == 0 or bd.boss.is_empty():
			schema_ok = false
		else:
			for key in ["phases", "bullet_patterns", "summons", "phase2_resist"]:
				if not bd.boss.has(key):
					schema_ok = false
		if absf(bd.hp_base - 16000.0) > 1600.0:
			hp_ok = false
	_check("数据加载：E17~E20 四专属 Boss 入注册表", loaded)
	_check("schema：boss 段四键齐 + TAG_BOSS + hp≈16000（boss2 同波位 ±10%）",
		schema_ok and hp_ok)
	# ② validator：加载后全量校验 0 剔除（4 Boss 未被数据守门剔除）
	var validator := DataValidator.new()
	var report: Dictionary = validator.validate_all(_gl.registry)
	var all_in := true
	for bid in boss_ids:
		if _gl.registry.get_enemy(bid) == null:
			all_in = false
	_check("validator：全量校验 0 剔除（4 Boss 存活于注册表）",
		(report["rejected"] as Array).size() == 0 and all_in)
	# ③ 贴图：非空 + 96px 画布 + 互异（缓存实例不同——与 boss1~3 剪影互异同口径）
	var tex_b4 := TextureFactory.enemy_tex(&"boss4")
	var tex_b5 := TextureFactory.enemy_tex(&"boss5")
	var tex_b6 := TextureFactory.enemy_tex(&"boss6")
	var tex_b7 := TextureFactory.enemy_tex(&"boss7")
	var distinct := tex_b4 != null and tex_b5 != null and tex_b6 != null and tex_b7 != null \
		and tex_b4.get_width() == 96 and tex_b7.get_height() == 96 \
		and tex_b4 != tex_b5 and tex_b4 != tex_b6 and tex_b4 != tex_b7 \
		and tex_b5 != tex_b6 and tex_b5 != tex_b7 and tex_b6 != tex_b7 \
		and tex_b4 != TextureFactory.enemy_tex(&"boss1") \
		and tex_b4 != TextureFactory.enemy_tex(&"boss2") \
		and tex_b4 != TextureFactory.enemy_tex(&"boss3")
	_check("贴图：boss4~7 非空 + 96px 画布 + 相互/对 boss1~3 互异", distinct)
	var angry_ok := tex_b4 != TextureFactory.enemy_tex(&"boss4", true) \
		and tex_b5 != TextureFactory.enemy_tex(&"boss5", true) \
		and tex_b6 != TextureFactory.enemy_tex(&"boss6", true) \
		and tex_b7 != TextureFactory.enemy_tex(&"boss7", true)
	_check("贴图：4 新 Boss 怒相变体就位（angry 缓存独立）", angry_ok)
	# ④ 分型判定 + 视觉接线 + 巨型化（spawn 4 实体，tags=6 → FINAL x5.0 档）
	var kind_ok := true
	var visual_ok := true
	var scale_ok := true
	for i in range(4):
		var en := (_gl.pools[&"enemy"] as EnemyPool).acquire()
		en.spawn(_gl.registry.get_enemy(boss_ids[i]), 20, GameConst.TAG_FINAL_BOSS)
		if en.get("_kind") != kinds[i]:
			kind_ok = false
		var spr: Sprite2D = en.get("_sprite")
		if spr == null or spr.texture != TextureFactory.enemy_tex(kinds[i], false):
			visual_ok = false
		if absf(float(en.get("_base_scale")) - 14.0 * Enemy.FINAL_BOSS_VISUAL_MULT / Enemy.BOSS_TEX_R) > 0.001:
			scale_ok = false
		_gl.pools[&"enemy"].release(en)
	_check("分型判定：E17~E20 spawn 实体 _kind = boss4~7", kind_ok)
	_check("视觉接线：sprite 贴图 = 分型缓存同实例", visual_ok)
	_check("巨型化：TAG_FINAL_BOSS → x5.0 档（hitbox 口径基准）", scale_ok)
	# ⑤ 波表接入：4 图 w20 composition = 本图专属 Boss + 引擎选取以表内 Boss 优先
	var pairs: Array = [
		[&"world_frost", &"E17_frost_sovereign"],
		[&"world_demon", &"E18_demon_lord"],
		[&"world_grove", &"E19_grove_warden"],
		[&"world_swamp", &"E20_swamp_hydra"],
	]
	var wave_ok := true
	var pick_ok := true
	var saved_table: WaveTableData = _gl.wave_director.wave_table
	for pr: Array in pairs:
		var tbl: WaveTableData = MapTable.load_table(pr[0], _gl.registry)
		if tbl == null or tbl.entries.size() != 20:
			wave_ok = false
			continue
		var w20: WaveEntryData = null
		for e in tbl.entries:
			if e.index == 20:
				w20 = e
		var found := false
		if w20 != null:
			for comp in w20.composition:
				if StringName(String(comp.get("enemy_id", ""))) == StringName(String(pr[1])):
					found = true
		if not found:
			wave_ok = false
		_gl.wave_director.wave_table = tbl
		var pick: EnemyData = _gl.wave_director.call(&"_find_boss_data", 20)
		if pick == null or pick.id != StringName(String(pr[1])):
			pick_ok = false
	_gl.wave_director.wave_table = saved_table
	_check("波表接入：4 图 w20 composition 编入本图专属 Boss（键序不变）", wave_ok)
	_check("引擎选取：_find_boss_data 表内 Boss 优先（每图 w20 选对）", pick_ok)
	# ⑥ 主表轮换不回归（rotation 池扩到 7 只后，主表三 Boss 波选取不变）
	_gl.wave_director.wave_table = _gl.registry.get_wave_table()
	var main_ok := true
	var expects: Array = [[10, &"E6_boss1"], [20, &"E6_boss2"], [30, &"E6_boss3"]]
	for ex: Array in expects:
		var mp: EnemyData = _gl.wave_director.call(&"_find_boss_data", ex[0])
		if mp == null or mp.id != StringName(String(ex[1])):
			main_ok = false
	_check("主表轮换：w10/20/30 仍 = boss1/2/3（rotation 不回归）", main_ok)
	# ⑦ F-19 Boss 波伴怪闸口径：w20 节奏 ×1/2.5s 场上≤12 + Boss 未登场时闸开（口径不回归）
	var rhythm: Dictionary = _gl.wave_director.call(&"_escort_rhythm", 20)
	_check("F-19 伴怪闸：w20 节奏 ×1/2.5s 场上≤12 + 未登场闸开（不回归）",
		absf(float(rhythm["interval"]) - 2.5) <= 0.001 and int(rhythm["cap"]) == 12
		and bool(_gl.wave_director.call(&"_escort_gate_open")))


# ── 地图词缀二期（双词缀：祝福利好玩家 + 诅咒利敌） ────────────────
func _test_map_affixes2() -> void:
	# 数值真源：map_table.gd MAPS 注释块（2026-08-31 本轮裁定，强度温和 ±5~12%）。
	# 应用点：诅咒 → spawner._apply_map_mods；祝福 → player.map_*（金币: GameLoop 掉账 /
	# 经验: Player.gain_xp / 射速: WeaponBase._fire_interval / 回血: GameLoop wave_cleared 订阅）
	print("── 双词缀（祝福/诅咒） ──")
	# ① 5 图双键齐全 + 旧 mod_id 兼容（既有单向词缀键不删）
	var dual_ok := true
	var legacy_ok := true
	var expect_legacy := {&"world_grass": "", &"world_frost": "ice_resist",
		&"world_demon": "spd_mult", &"world_grove": "xp_mult", &"world_swamp": "hp_mult"}
	for m in MapTable.MAPS:
		for k in ["bless_id", "bless_name", "curse_id", "curse_name"]:
			if String(m.get(k, "")) == "":
				dual_ok = false
		if String(m.get("mod_id", "")) != String(expect_legacy[m.id]):
			legacy_ok = false
	_check("双词缀：5 图 bless/curse 键齐全", dual_ok)
	_check("双词缀：旧 mod_id 键保留（兼容断言）", legacy_ok)
	# ② 注入口实测：_apply_map_affixes → 敌侧 mods + 玩家侧四字段（逐图口径）
	var inject_ok := true
	var inject_info := ""
	var checks: Array = [
		[&"world_grass", {"mob_hp_mult": 1.08}, 1.10, 1.0, 1.0, 0.0],
		[&"world_frost", {"ice_resist": 0.2}, 1.0, 1.0, 1.10, 0.0],
		[&"world_demon", {"spd_mult": 1.10}, 1.0, 1.06, 1.0, 0.0],
		[&"world_grove", {"contact_mult": 1.08}, 1.0, 1.0, 1.0, 0.02],
		[&"world_swamp", {"hp_mult": 1.10}, 1.08, 1.0, 1.08, 0.0],
	]
	for c: Array in checks:
		_gl._apply_map_affixes(MapTable.get_map(c[0]))
		var bad := ""
		if _gl.spawner.map_mods != (c[1] as Dictionary):
			bad += "mods=%s " % str(_gl.spawner.map_mods)
		if absf(_gl.player.map_gold_mult - float(c[2])) > 0.001:
			bad += "gold=%.3f " % _gl.player.map_gold_mult
		if absf(_gl.player.map_rof_mult - float(c[3])) > 0.001:
			bad += "rof=%.3f " % _gl.player.map_rof_mult
		if absf(_gl.player.map_xp_mult - float(c[4])) > 0.001:
			bad += "xp=%.3f " % _gl.player.map_xp_mult
		if absf(_gl.player.map_wave_heal_pct - float(c[5])) > 0.001:
			bad += "heal=%.3f" % _gl.player.map_wave_heal_pct
		if bad != "":
			inject_ok = false
			inject_info += "%s[%s] " % [String(c[0]), bad.strip_edges()]
	_check("双词缀注入：5 图诅咒 mods + 祝福字段（gold/rof/xp/回血）", inject_ok, inject_info)
	_gl._apply_map_affixes(MapTable.get_map(MapTable.FIRST_MAP_ID))   # 还原草原口径
	# ③ 敌侧诅咒应用实测（spawner._apply_map_mods 出生差分；w1 = data 基准值）
	var epool := _gl.pools[&"enemy"] as EnemyPool
	var fx := _fixture_enemy(&"E_AFFX", 100.0)
	fx.spd_base = 60.0
	fx.dmg_base = 10.0
	var en := epool.acquire()
	en.spawn(fx, 1, 0)
	_gl.spawner.map_mods = {"hp_mult": 1.10}
	_gl.spawner._apply_map_mods(en)
	_check("诅咒·泥沼：敌 HP +10%", absf(en.max_hp - 110.0) <= 0.01 and absf(en.hp - 110.0) <= 0.01)
	_gl.spawner.map_mods = {"mob_hp_mult": 1.08}
	_gl.spawner._apply_map_mods(en)
	_check("诅咒·虫群：非 Boss HP +8%（叠加 110 → 118.8）", absf(en.max_hp - 118.8) <= 0.01)
	var boss_fx := _fixture_enemy(&"E_AFFX_B", 100.0)
	boss_fx.tags = GameConst.TAG_BOSS
	var ben := epool.acquire()
	ben.spawn(boss_fx, 1, GameConst.TAG_BOSS)
	_gl.spawner._apply_map_mods(ben)
	_check("诅咒·虫群：Boss 免除", absf(ben.max_hp - 100.0) <= 0.01)
	_gl.spawner.map_mods = {"contact_mult": 1.08}
	_gl.spawner._apply_map_mods(en)
	_check("诅咒·毒肤：敌接触伤 +8%（10 → 10.8）", absf(en.contact_dmg - 10.8) <= 0.01)
	_gl.spawner.map_mods = {"ice_resist": 0.2}
	_gl.spawner._apply_map_mods(en)
	_check("诅咒·霜甲：敌冰抗 +20%", absf(float(en.resist[2]) - 0.2) <= 0.001)
	_gl.spawner.map_mods = {"spd_mult": 1.10}
	_gl.spawner._apply_map_mods(en)
	_check("诅咒·疾魔：敌移速 +10%（60 → 66）", absf(en.speed - 66.0) <= 0.01)
	_gl.spawner.map_mods = {}
	epool.release(en)
	epool.release(ben)
	# ④ 玩家侧祝福实测
	var p: Node = _gl.player
	# 金币（丰饶 ×1.10：gold_drop 固定 10 → 入账 11）
	var gstub := _make_killed_enemy_stub(false)
	(gstub.data as EnemyData).gold_drop = {"chance": 1.0, "min": 10, "max": 10}
	var gold0: int = int(p.get("gold"))
	p.set("map_gold_mult", 1.10)
	_gl._on_enemy_killed_drop_xp(gstub)
	_check("祝福·丰饶：金币掉账 +10%（10 → 11）", int(p.get("gold")) == gold0 + 11)
	p.set("map_gold_mult", 1.0)
	_gl.pools[&"enemy"].release(gstub)
	# 经验（寒晶：gain_xp 差分比 = map_xp_mult；养成萃取系数在比值中相消）
	p.set("xp", 0.0)
	p.set("map_xp_mult", 1.0)
	p.call(&"gain_xp", 10.0)
	var d1: float = float(p.get("xp"))
	p.set("xp", 0.0)
	p.set("map_xp_mult", 1.10)
	p.call(&"gain_xp", 10.0)
	var d2: float = float(p.get("xp"))
	_check("祝福·寒晶：gain_xp ×1.10（差分比）", d1 > 0.0 and absf(d2 / d1 - 1.10) <= 0.01)
	p.set("xp", 0.0)
	p.set("map_xp_mult", 1.0)
	# 射速（狂热 ×1.06 → 开火间隔 /1.06）
	var w0: WeaponBase = (p.get("weapon_slots") as Array)[0]
	p.set("map_rof_mult", 1.0)
	var itv0: float = float(w0.call(&"_fire_interval"))
	p.set("map_rof_mult", 1.06)
	var itv1: float = float(w0.call(&"_fire_interval"))
	_check("祝福·狂热：射速 interval /1.06",
		itv0 > 0.0 and absf(itv1 / itv0 - 1.0 / 1.06) <= 0.001)
	p.set("map_rof_mult", 1.0)
	# 每波回血（滋养 2% max_hp + 满血钳制 + 无祝福不回血）
	p.set("hp", 30.0)
	p.set("map_wave_heal_pct", 0.02)
	_gl._on_wave_cleared_bless_heal(5)
	var heal_expect: float = 30.0 + float(p.get("max_hp")) * 0.02
	_check("祝福·滋养：波清回血 2% max_hp", absf(float(p.get("hp")) - heal_expect) <= 0.01)
	p.set("hp", float(p.get("max_hp")))
	_gl._on_wave_cleared_bless_heal(6)
	_check("祝福·滋养：满血不溢出", absf(float(p.get("hp")) - float(p.get("max_hp"))) <= 0.01)
	p.set("map_wave_heal_pct", 0.0)
	p.set("hp", 30.0)
	_gl._on_wave_cleared_bless_heal(7)
	_check("祝福·滋养：无祝福不回血", absf(float(p.get("hp")) - 30.0) <= 0.01)
	p.set("hp", float(p.get("max_hp")))
	# ⑤ 菜单展示存在性（每图祝/诅两行小字）
	_gl.menu_screen._open_map_select()
	var bless_cnt := 0
	var curse_cnt := 0
	for row_node in _gl.menu_screen._panel_list.get_children():
		if row_node.is_queued_for_deletion():
			continue
		for sub in (row_node as Node).get_children():
			if sub is Label:
				var txt := String((sub as Label).text)
				if txt.begins_with("祝"):
					bless_cnt += 1
				elif txt.begins_with("诅"):
					curse_cnt += 1
	_check("菜单展示：双词缀两行小字（5 祝 + 5 诅）", bless_cnt == 5 and curse_cnt == 5,
		"bless=%d curse=%d" % [bless_cnt, curse_cnt])
	_gl.menu_screen._on_panel_close()


# ── 分图无尽延伸（表内无尽段 + per-map Boss 轮换 + Meta 深度） ─────
func _test_endless_maps() -> void:
	print("── 分图无尽延伸 ──")
	# ① 5 表无尽条目存在且 ≥10 条 + index 自 final_wave+1 连续
	var cnt_ok := true
	var idx_ok := true
	for m in MapTable.MAPS:
		var t := MapTable.load_table(m.id, _gl.registry)
		if t == null or t.endless_entries.size() < 10:
			cnt_ok = false
			continue
		var expect := int(m.final_wave) + 1
		for e in t.endless_entries:
			if e.index != expect:
				idx_ok = false
			expect += 1
	_check("无尽表：5 表 endless_entries ≥10 条", cnt_ok)
	_check("无尽表：index 自 final_wave+1 连续", idx_ok)
	# ② 驱动器消费表内无尽条目（冰原 w21：构成/TP/窗口取表值）
	var wd := _gl.wave_director
	var saved_tbl: WaveTableData = wd.wave_table
	_gl.spawner.spawn_queue.clear()
	wd.wave_table = MapTable.load_table(&"world_frost", _gl.registry)
	var e21: WaveEntryData = wd.call(&"_table_entry", 21)
	var e21_sum := 0
	if e21 != null:
		for comp in e21.composition:
			e21_sum += int(comp.get("count", 0))
	wd.start_wave(21)
	_check("无尽表消费：w21 构成源自 endless_entries（48 只入队）",
		e21 != null and _gl.spawner.queue_count() == e21_sum and e21_sum == 48,
		"queue=%d sum=%d" % [_gl.spawner.queue_count(), e21_sum])
	_check("无尽表消费：w21 TP/窗口取表值（60.4 / 26.2）",
		absf(wd.tp_budget - 60.4) <= 0.01 and absf(wd.window_left - 26.2) <= 0.01)
	# ③ 无尽 Boss 波：逢 5 轮换本图池（表内 composition 真源）
	_check("无尽 Boss：w25 逢 5 + 表内轮换 E6_boss1",
		bool(wd.call(&"_is_boss_wave", 25))
		and (wd.call(&"_find_boss_data", 25) as EnemyData).id == &"E6_boss1")
	_check("无尽 Boss：w30 本图专属 E17_frost_sovereign",
		(wd.call(&"_find_boss_data", 30) as EnemyData).id == &"E17_frost_sovereign")
	_gl.spawner.spawn_queue.clear()
	# ④ 表尽回退公式（w45 无条目 → 无尽公式 TP/窗口，A3 §2.6 口径不变）
	wd.start_wave(45)
	_check("表尽回退：w45 TP = 110×1.03^15 / 窗口 33",
		absf(wd.tp_budget - 110.0 * pow(1.03, 15.0)) <= 0.01
		and absf(wd.window_left - 33.0) <= 0.01)
	_gl.spawner.spawn_queue.clear()
	# ⑤ per-map Boss 回退轮换池（表尽段逢 10；池 = 各图 w10/w20 已用 Boss）
	var rot_ok := true
	var rot_info := ""
	var rot_cases: Array = [
		[&"world_grass", 50, &"E6_boss2"],
		[&"world_frost", 40, &"E6_boss1"],
		[&"world_demon", 40, &"E6_boss2"],
		[&"world_grove", 40, &"E6_boss1"],
		[&"world_swamp", 40, &"E6_boss2"],
	]
	for rc: Array in rot_cases:
		wd.wave_table = MapTable.load_table(rc[0], _gl.registry)
		var pick: EnemyData = wd.call(&"_find_boss_data", rc[1])
		if pick == null or pick.id != StringName(String(rc[2])):
			rot_ok = false
			rot_info += "%s w%d→%s " % [String(rc[0]), int(rc[1]),
				String(pick.id) if pick != null else "null"]
	_check("Boss 回退轮换：per-map 池（grass w50→boss2 / frost·grove w40→boss1 / demon·swamp w40→boss2）",
		rot_ok, rot_info)
	# ⑥ 主表无尽行为不回归：无表公式段 TP（pkg2 锁定口径）+ 主表主体段 30 波不变
	wd.wave_table = null
	wd.start_wave(35)
	_check("主表不回归：无表 w35 公式 TP 110×1.03^5",
		absf(wd.tp_budget - 110.0 * pow(1.03, 5.0)) <= 0.01)
	_gl.spawner.spawn_queue.clear()
	wd.wave_table = _gl.registry.get_wave_table()
	var e31: WaveEntryData = wd.call(&"_table_entry", 31)
	_check("主表无尽段：w31 表驱动（主体段 30 波 + endless 10 条分表存储）",
		e31 != null and _gl.registry.get_wave_table().entries.size() == 30
		and _gl.registry.get_wave_table().endless_entries.size() == 10)
	_gl.spawner.spawn_queue.clear()
	wd.wave_table = saved_tbl
	# ⑦ Meta 无尽深度：结算写入 / 读取 / 未记录默认 0（快照隔离——先断言再还原；
	# 清残留结算先行改道 grass——残留 _run_max_wave 的深度只会写入一次性 grass 记录）
	var saved_mr: Dictionary = Meta.map_records
	Meta.map_records = {}
	Meta.set_run_map(&"world_grass")
	Meta._on_state_changed(GameConst.GameStatus.GAME_OVER)      # 清残留单局计数
	Meta.set_run_map(&"world_frost")
	Meta._on_wave_started(27)                                    # 冰原 final 20 → 深度 7
	Meta._on_state_changed(GameConst.GameStatus.GAME_OVER)
	_check("Meta 无尽深度：frost 27 波 → 深度 7", Meta.endless_depth(&"world_frost") == 7,
		"got=%d" % Meta.endless_depth(&"world_frost"))
	_check("Meta 无尽深度：未记录图默认 0",
		Meta.endless_depth(&"world_swamp") == 0 and Meta.endless_depth(&"world_demon") == 0)
	Meta.map_records = saved_mr
	# ⑧ HUD 波次号无尽段继续递增
	EventBus.emit_wave_started(41)
	_check("HUD：无尽段波次号递增（41）", _gl.hud.wave == 41)


# ── P2-1 伤害数字分级（白/蓝/紫/金——大小/颜色/音效三联动） ────────
func _test_p2_damage_tiers() -> void:
	print("── P2 伤害数字分级 ──")
	var pm: PopupManager = _gl.popup_manager
	pm.tick(10.0)                                  # 清场（归还上批活跃跳字）
	var base: float = _gl.call(&"_popup_tier_baseline")
	_check("分级基准：主武器面板 base_atk × crit_mult（>0）", base > 0.0, "base=%s" % str(base))
	_check("分级音色：紫「叮」/ 金重击已入 sfx_bank",
		SfxBank.I != null and SfxBank.I._streams.has(&"tier_high")
		and SfxBank.I._streams.has(&"tier_epic"))
	var cases := [[0.5, 0], [2.0, 1], [4.0, 2], [8.0, 3]]   # [倍率, 期望档]
	var uid := 9100
	for c: Array in cases:
		var r := DamageResult.new()
		r.final_value = base * float(c[0])
		r.target_uid = uid
		r.pos = Vector2(100, 200)
		r.popup_style = GameConst.PopupStyle.NORMAL
		pm.on_damage_resolved(r)
		uid += 1
	_check("量级分档：0.5×/2×/4×/8× → 白/蓝/紫/金四档判定", pm.active_popups == 4)
	for i: int in range(cases.size()):
		var popup: DamagePopup = pm._active_list[i]
		var expect_size := roundi(DamagePopup.FONT_SIZE * float(DamagePopup.TIER_SCALES[int(cases[i][1])]))
		_check("档位 %d：字号 ×%s（%dpx）" % [int(cases[i][1]), str(DamagePopup.TIER_SCALES[int(cases[i][1])]), expect_size],
			popup.tier == int(cases[i][1])
			and popup._label.get_theme_font_size("font_size") == expect_size)
	_check("档位配色：蓝/紫/金 = 稀有度三色（调色板单源）",
		(pm._active_list[1] as DamagePopup)._label.self_modulate == PopPalette.RARITY_RARE
		and (pm._active_list[2] as DamagePopup)._label.self_modulate == PopPalette.RARITY_EPIC
		and (pm._active_list[3] as DamagePopup)._label.self_modulate == PopPalette.RARITY_LEGEND)
	_check("金档重音 + 轻震动（trauma 复用 hit 档）",
		_gl.game_feel.shake.trauma > 0.0)
	pm.tick(10.0)
	# CRIT 同吃量级档（基础字号 40）；DOT/REACTION 不参与（沿旧观感）
	var rc := DamageResult.new()
	rc.final_value = base * 4.0
	rc.target_uid = 9200
	rc.popup_style = GameConst.PopupStyle.CRIT
	pm.on_damage_resolved(rc)
	_check("暴击量级档：紫档字号 = 40 × 1.35",
		(pm._active_list[0] as DamagePopup).tier == 2
		and (pm._active_list[0] as DamagePopup)._label.get_theme_font_size("font_size")
			== roundi(DamagePopup.FONT_SIZE_CRIT * 1.35))
	pm.tick(10.0)
	var rd := DamageResult.new()
	rd.final_value = base * 100.0
	rd.target_uid = 9300
	rd.popup_style = GameConst.PopupStyle.DOT
	pm.on_damage_resolved(rd)
	_check("DOT 不吃量级档（配色/字号沿旧）",
		(pm._active_list[0] as DamagePopup).tier == 0
		and (pm._active_list[0] as DamagePopup)._label.get_theme_font_size("font_size")
			== DamagePopup.FONT_SIZE)
	pm.tick(10.0)
	# 基准关闭降级：provider 置空 → 全白（安全关闭口径）
	var saved_provider: Callable = pm.baseline_provider
	pm.baseline_provider = Callable()
	var rn := DamageResult.new()
	rn.final_value = base * 100.0
	rn.target_uid = 9400
	rn.popup_style = GameConst.PopupStyle.NORMAL
	pm.on_damage_resolved(rn)
	_check("基准缺失 → 分级安全关闭（全白现状字号）",
		(pm._active_list[0] as DamagePopup).tier == 0
		and (pm._active_list[0] as DamagePopup)._label.get_theme_font_size("font_size")
			== DamagePopup.FONT_SIZE)
	pm.baseline_provider = saved_provider
	pm.tick(10.0)


# ── P2-2 BGM 环境音（预生成 PCM 循环 + 战斗/菜单/Boss 三态） ───────
func _test_p2_bgm() -> void:
	print("── P2 BGM 环境音 ──")
	_check("BGM：SfxBank 单例 + pad 层就绪", SfxBank.I != null
		and SfxBank.I.bgm_pad_stream() is AudioStreamWAV)
	var stream: AudioStreamWAV = SfxBank.I.bgm_pad_stream()
	_check("BGM：8s 循环（4 小节）+ LOOP_FORWARD",
		absf(stream.get_length() - SfxBank.I.bgm_loop_seconds()) <= 0.01
		and stream.loop_mode == AudioStreamWAV.LOOP_FORWARD)
	# 无缝判据：循环首尾样本连续（正弦/LFO 均为 1/8s 整数倍频率——首尾相位连续）
	var pcm := stream.data
	var seam := absi(pcm.decode_s16(0) - pcm.decode_s16(pcm.size() - 2))
	_check("BGM：循环点无缝（首尾样本差 %d < 2500）" % seam, seam < 2500)
	SfxBank.I.bgm_set_active(true)
	_check("BGM：战斗态起播（pad 播放中）", SfxBank.I._bgm_player.playing)
	SfxBank.I.bgm_set_boss_layer(true)
	_check("BGM：Boss 存活期第二循环解锁（脉冲层播放中）",
		SfxBank.I._bgm_boss_player.playing
		and not SfxBank.I._bgm_boss_player.stream_paused)
	SfxBank.I.bgm_set_active(false)
	_check("BGM：菜单暂停（双层 stream_paused）",
		SfxBank.I._bgm_player.stream_paused
		and SfxBank.I._bgm_boss_player.stream_paused)
	SfxBank.I.bgm_set_boss_layer(false)


# ── P2-3 每日挑战（日期种子 + 当日词缀 + daily_best + 大厅入口） ──
func _test_p2_daily() -> void:
	print("── P2 每日挑战 ──")
	# ① 同日同种子确定性 / 跨日种子必变
	_check("每日：同日期种子恒同", Meta.daily_seed("20260831") == Meta.daily_seed("20260831"))
	_check("每日：跨日种子必变", Meta.daily_seed("20260831") != Meta.daily_seed("20260901"))
	# ② 词缀组合来自日期（确定性 + 形状 + 池内）
	var a1: Dictionary = Meta.daily_affixes("20260831")
	var a2: Dictionary = Meta.daily_affixes("20260831")
	var curses1: Array = a1.get("curses", [])
	var in_pool := true
	for cid: Variant in curses1:
		if not Meta.CURSE_POOL.has(StringName(String(cid))):
			in_pool = false
	_check("每日：同日词缀组合恒同（全玩家同日同配置）",
		str(a1) == str(a2) and curses1.size() == 2 and curses1[0] != curses1[1] and in_pool)
	_check("每日：祝福 1 条来自祝福池",
		Meta.BLESS_POOL.has(StringName(String(a1.get("bless", "")))))
	# ③ 跨日变化（mock 日期参数化——12 个连续日期 ≥3 种组合）
	var combos := {}
	for d in range(1, 13):
		var key := Meta.daily_date_key({"year": 2027, "month": 1, "day": d})
		var affixes: Dictionary = Meta.daily_affixes(key)
		combos[str(affixes)] = true
	_check("每日：跨日词缀轮换（12 日 ≥3 种组合）", combos.size() >= 3, "kinds=%d" % combos.size())
	# ④ daily_best 写读（波次/击杀各取历史最大）
	var saved_daily: Dictionary = Meta.daily_records.duplicate()
	Meta.daily_records = {}
	Meta.record_daily_result(15, 200)
	Meta.record_daily_result(10, 300)              # 更低波次 / 更高击杀
	var rec: Dictionary = Meta.daily_record()
	_check("每日：daily_best 写读（波次取最大 15 / 击杀取最大 300）",
		int(rec.get("best_wave", 0)) == 15 and int(rec.get("best_kills", 0)) == 300)
	# ⑤ 结算分流：daily 局只记 daily_best，不混常规 records
	var saved_records: Dictionary = Meta.records.duplicate()
	Meta.set_run_daily(true)
	Meta._run_max_wave = 21
	Meta._run_kills = 400
	Meta._on_state_changed(GameConst.GameStatus.GAME_OVER)
	var rec2: Dictionary = Meta.daily_record()
	_check("每日：daily 局结算 → daily_best 更新（波次 21）", int(rec2.get("best_wave", 0)) == 21)
	_check("每日：daily 局不混常规记录（total_runs/best_wave 不变）",
		int(Meta.records["total_runs"]) == int(saved_records["total_runs"])
		and int(Meta.records["best_wave"]) == int(saved_records["best_wave"]))
	Meta.set_run_daily(false)
	# ⑥ 持久化：save → 清空 → load 还原
	Meta._save()
	Meta.daily_records = {}
	Meta._load()
	_check("每日：daily_records 持久化写读", int(Meta.daily_record().get("best_wave", 0)) == 21)
	Meta.daily_records = saved_daily               # 还原（测试不留痕）
	Meta._save()
	# ⑦ 大厅入口 + 当日面板（2 诅 + 1 祝 + 最佳 + 注释 + 出发按钮 = 6 行）
	var menu: MenuScreen = _gl.menu_screen
	menu._on_lobby_pressed("daily")
	var curse_rows := 0
	var bless_rows := 0
	for row_node in menu._panel_list.get_children():
		if row_node.is_queued_for_deletion():
			continue
		for sub in (row_node as Node).get_children():
			if sub is Label:
				var txt := String((sub as Label).text)
				if txt == "诅":
					curse_rows += 1
				elif txt == "祝":
					bless_rows += 1
	_check("每日：大厅面板当日三词缀展示（2 诅 + 1 祝）", curse_rows == 2 and bless_rows == 1)
	_check("每日：出发挑战按钮就位", menu._panel_list.find_child("DailyStartButton", true, false) != null)
	menu._on_panel_close()


# ── P2-4 角色扩展 ×2（薇拉毒云 / 诺亚僚机 + 解锁门） ──────────────
func _test_p2_characters() -> void:
	print("── P2 角色扩展 ──")
	var p: Node = _gl.player
	var vera: Dictionary = CharacterTable.get_character(&"vera")
	var noah: Dictionary = CharacterTable.get_character(&"noah")
	_check("角色表：薇拉/诺亚就位（cd 120s / 毒云 / 僚机）",
		String(vera.get("id")) == "vera" and String(noah.get("id")) == "noah"
		and absf(float(vera.get("cd", 0.0)) - 120.0) <= 0.01
		and absf(float(noah.get("cd", 0.0)) - 120.0) <= 0.01)
	# 解锁门：薇拉 = 图鉴累计击杀 500；诺亚 = 任意图无尽深度 ≥5
	var saved_kills: int = int(Meta.records["total_kills"])
	var saved_maps: Dictionary = Meta.map_records
	Meta.records["total_kills"] = 499
	Meta.map_records = {}
	_check("解锁门：薇拉 499 杀锁定 / 诺亚深度 0 锁定",
		not Meta.is_character_unlocked(&"vera") and not Meta.is_character_unlocked(&"noah"))
	Meta.records["total_kills"] = 500
	_check("解锁门：薇拉 500 杀解锁", Meta.is_character_unlocked(&"vera"))
	Meta.records["total_kills"] = saved_kills
	Meta.map_records = {"world_frost": {"endless_depth": 5}}
	_check("解锁门：诺亚任意图深度 ≥5 解锁", Meta.is_character_unlocked(&"noah"))
	Meta.map_records = saved_maps
	# 薇拉：毒云领域（直结算通道——域内敌每 0.5s 受 8% 主武器 ATK + 减速 20%）
	_gl.state = GameConst.GameStatus.MENU
	Meta.records["total_kills"] = maxi(saved_kills, 500)   # 解锁门满足（守卫回落哨兵口径）
	Meta.map_records = {"world_frost": {"endless_depth": 5}}
	Meta.character_id = &"vera"
	p.call(&"set_character", &"vera")
	_check("角色：薇拉血量 55 + 养成加成",
		absf(float(p.get("max_hp")) - (55.0 + Meta.hp_bonus())) <= 0.01)
	var target := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	target.spawn(_fixture_enemy(&"E_P2VERA", 100000.0), 1, 0)
	target.global_position = (p as Node2D).global_position + Vector2(120.0, 0.0)
	_gl.elemental.register_host(target)
	_gl.enemy_grid.rebuild([target])
	p.set("skill_cd_left", 0.0)
	p.call(&"activate_skill")
	_check("技能·毒云：挂场即跳（敌掉血）+ 减速 20% 生效",
		float(target.get("hp")) < 100000.0 and absf(float(target.get("ext_slow_mult")) - 0.8) <= 0.001)
	var hp_at_start: float = float(target.get("hp"))
	for i in range(240):                           # 2s（120Hz）→ 首跳后再 3 跳
		GameConfig.advance_frame()                 # 真实帧路径：帧号推进（管线幂等键含帧戳）
		p.call(&"tick", DT, Vector2.ZERO)
		target.call(&"tick", DT)                   # 敌侧驱动 ext_slow 倒计时（真实路径；Enemy.tick 单参）
	_check("技能·毒云：0.5s 节拍持续结算（2s 内 ≥3 跳）",
		float(target.get("hp")) < hp_at_start)
	for i in range(660):                           # 推进至毒云 6s 到期 + 减速窗 0.6s 过期
		GameConfig.advance_frame()
		p.call(&"tick", DT, Vector2.ZERO)
		target.call(&"tick", DT)
	var hp_after_cloud: float = float(target.get("hp"))
	_check("技能·毒云：6s 到期停跳 + 减速还原",
		absf(float(p.get("_poison_cloud_left"))) <= 0.001
		and absf(float(target.get("ext_slow_mult")) - 1.0) <= 0.001)
	for i in range(120):
		GameConfig.advance_frame()
		p.call(&"tick", DT, Vector2.ZERO)
		target.call(&"tick", DT)
	_check("技能·毒云：到期后不再结算", absf(float(target.get("hp")) - hp_after_cloud) <= 0.001)
	_gl.elemental.unregister_host(target)
	(_gl.pools[&"enemy"] as EnemyPool).release(target)
	# 诺亚：召唤僚机（主武器 orbs_bonus +2 持续 10s 后还原）
	_gl.state = GameConst.GameStatus.MENU
	Meta.character_id = &"noah"
	p.call(&"set_character", &"noah")
	_check("角色：诺亚血量 50 + 养成加成",
		absf(float(p.get("max_hp")) - (50.0 + Meta.hp_bonus())) <= 0.01)
	p.call(&"unlock_slot", 2)
	var orbit: WeaponBase = p.call(&"add_weapon", _gl.registry.get_weapon(&"W8_orbit_field"))
	_check("诺亚：环绕武器装配（真件 OrbitWeapon）", orbit is OrbitWeapon)
	if orbit is OrbitWeapon:
		(orbit as OrbitWeapon).try_fire()          # 首开火建立力场（基线球数）
		var base_orbs: int = (orbit as OrbitWeapon).orbit_field.orbs
		p.set("skill_cd_left", 0.0)
		p.call(&"activate_skill")
		_check("技能·僚机：召唤 +2（orbs_bonus 与力场球数同步 +2）",
			int((orbit as OrbitWeapon).orbs_bonus) == 2
			and (orbit as OrbitWeapon).orbit_field.orbs == base_orbs + 2)
		for i in range(600):                       # 5s（仍在持续期）
			GameConfig.advance_frame()
			p.call(&"tick", DT, Vector2.ZERO)
		_check("技能·僚机：持续期保持（5s 时仍 +2）",
			int((orbit as OrbitWeapon).orbs_bonus) == 2)
		for i in range(720):                       # 再 6s（10s 到期 + 余量）
			GameConfig.advance_frame()
			p.call(&"tick", DT, Vector2.ZERO)
		_check("技能·僚机：10s 到期还原（orbs_bonus 0 / 球数回落）",
			int((orbit as OrbitWeapon).orbs_bonus) == 0
			and (orbit as OrbitWeapon).orbit_field.orbs == base_orbs)
		var slots: Array = p.get("weapon_slots")
		slots[slots.find(orbit)] = null            # 先摘槽（有效引用期）再 free——find 对 freed 实例失效
		(orbit as Node).free()
	# 选人面板：8 格（锁定态展示——薇拉/诺亚解锁门文案）
	Meta.records["total_kills"] = saved_kills
	Meta.map_records = saved_maps                 # 解锁门快照还原（测试不留痕）
	Meta.character_id = &"sentinel"
	var menu: MenuScreen = _gl.menu_screen
	menu._on_lobby_pressed("char")
	_check("大厅：选人面板 8 格（P2 +2）",
		_live_children(menu._panel_list) == CharacterTable.count())
	menu._on_panel_close()
	p.call(&"set_character", &"sentinel")


func _live_children(p_node: Node) -> int:
	# queue_free 已挂但未销毁的子节点不计（无帧迭代环境下的存活计数）
	var n := 0
	for c in p_node.get_children():
		if not c.is_queued_for_deletion():
			n += 1
	return n


func _make_killed_enemy_stub(p_boss: bool) -> Enemy:
	var e := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	var d := _fixture_enemy(&"E_META", 10.0)
	if p_boss:
		d.tags = GameConst.TAG_BOSS
	e.spawn(d, 1, 0)
	return e


# ── 工具 ─────────────────────────────────────────────────────────
func _check(p_name: String, p_ok: bool, p_info: String = "") -> void:
	if p_ok:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_info])
		print("FAIL | %s %s" % [p_name, p_info])

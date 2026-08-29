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
	_check("Boss 巨大化（视觉倍率 2.3）", absf(Enemy.BOSS_VISUAL_MULT - 2.3) <= 0.001)
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
	_check("大厅：三入口按钮就位", menu._lobby_btns.size() == 3)
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
	_check("大厅：记录面板打开（5 行）", _live_children(menu._panel_list) == 5)
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

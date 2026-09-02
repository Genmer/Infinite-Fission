# tests/runner/pkg14_cases.gd
# v1.4.0 自测用例体（由 test_pkg14.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖冻结方案 pkg14 用例组 C1~C24（A13_v1.4.0_design.md §7；每恰 1 断言）。
# 隔离纪律（pkg10 同款）：standalone MetaStore 一律 set_save_path(测试档) + 构造即 wipe；
# 每用例独立 store（首见判定互不污染）；收尾仅清测试档（不触碰默认档/真机存档）。
# 夹具分段（pkg13 执行序纪律：微夹具纯净面先行 → 拆微世界 → GameLoop boot 段）：
#   C1~C8 standalone MetaStore → C11~C13 微夹具（局部 ElementalSystem/武器挂载）
#   → C9/C10/C14 GameLoop 完整 Boot（boot 后首件事切测试档 + wipe）。
extends RefCounted

const TEST_PATH := "user://pkg14_meta_test.cfg"
const BALLISTIC_SCENE := "res://scenes/combat/projectiles/ballistic_projectile.tscn"
const TRAIT_FIR := "res://resources/traits/ELE_IGNITE.tres"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _stores: Array[MetaStore] = []               # 用例独立 store（收尾统一 free）

# ── 微夹具（pkg13 模式） ──
var _proj_pool: ProjectilePool
var _grid: SpaceGrid
var _pipeline: DamagePipeline
var _micro_weapons: Array[WeaponBase] = []
var _micro_stubs: Array[Node2D] = []
var _micro_systems: Array[ElementalSystem] = []
var _micro_enemies: Array[Enemy] = []
var _wd_counter: int = 0

# ── GameLoop 夹具（pkg10 模式） ──
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_ensure_autoloads()
	_test_c1_chip_mark()                          # C1
	_test_c2_relic_mark()                         # C2
	_test_c3_reaction_mark()                      # C3
	_test_c4_unlock_idempotent()                  # C4
	_test_c5_convert_gold()                       # C5
	_test_c6_legacy_missing_sections()            # C6
	_test_c7_dirty_keys()                         # C7
	_test_c8_wipe_clears()                        # C8
	_setup_micro()
	_test_c11_reactions()                         # C11
	_test_c12_amplify()                           # C12
	_test_c13_resonance_first()                   # C13
	_teardown_micro()
	_boot_game_loop()
	_test_c9_chip_tracking()                      # C9
	_test_c10_relic_tracking()                    # C10
	_test_c14_null_guards()                       # C14
	_test_c15_boss_tiers()                        # C15
	_test_c16_wave_tiers()                        # C16
	_test_c17_chip_judgment()                     # C17
	_test_c18_weapon_kills_judgment()             # C18
	_test_c19_list_dedup_reset()                  # C19
	_test_c20_tab_rects()                         # C20
	_test_c21_cell_row_text()                     # C21
	_test_c22_wipe_flow()                         # C22
	_test_c23_settle_screen()                     # C23
	_test_c24_closure()                           # C24
	_teardown_game_loop()
	_teardown()
	_summary()


func fail_count() -> int:
	return _fail


# ── 支撑 ──────────────────────────────────────────────────────────
func _check(p_desc: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS %s" % p_desc)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_desc, p_detail])
		print("  FAIL %s %s" % [p_desc, p_detail])


func _summary() -> void:
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("════════════════════════════════════════")


func _ensure_autoloads() -> void:
	if EventBus == null or GameConfig == null or DebugStats == null:
		push_error("[pkg14] autoload 未就绪（后续用例级联失败）")


func _new_store() -> MetaStore:
	# 用例独立 store：测试档路径 + 构造即 wipe（首见判定从零开始）
	var s := MetaStore.new()
	s.name = "Pkg14Store%d" % _stores.size()
	tree.get_root().add_child(s)
	s.set_save_path(TEST_PATH)
	s.wipe()
	_stores.append(s)
	return s


func _reload_store() -> MetaStore:
	# 即存反证：同路径新实例显式 load_save（不 wipe）
	var s := MetaStore.new()
	s.name = "Pkg14Reload%d" % _stores.size()
	tree.get_root().add_child(s)
	s.set_save_path(TEST_PATH)
	s.load_save()
	_stores.append(s)
	return s


func _teardown() -> void:
	# 隔离纪律收尾：仅清本 runner 注入的测试档（不触碰默认档——headless 产品侧走
	# meta_save_headless.cfg，真机真实存档零风险）
	for s in _stores:
		if is_instance_valid(s):
			s.wipe()
			s.free()
	_stores.clear()
	var cfg := ConfigFile.new()
	if cfg.load(TEST_PATH) == OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))


func _read_source(p_path: String) -> String:
	var f := FileAccess.open(p_path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


# ── 微夹具（pkg13 同款精简） ───────────────────────────────────────
func _setup_micro() -> void:
	_proj_pool = ProjectilePool.new()
	_proj_pool.name = "Pkg14ProjPool"
	tree.get_root().add_child(_proj_pool)
	_proj_pool.setup(&"pkg14_test", load(BALLISTIC_SCENE), 16)
	_pipeline = DamagePipeline.new()
	_pipeline.set_rng_seed(42)
	_grid = SpaceGrid.new()
	_grid.configure(Vector2(720, 1280), 192.0)


func _teardown_micro() -> void:
	for w in _micro_weapons:
		if is_instance_valid(w):
			w.free()
	_micro_weapons.clear()
	for stub in _micro_stubs:
		if is_instance_valid(stub):
			stub.free()
	_micro_stubs.clear()
	for sys in _micro_systems:
		if is_instance_valid(sys):
			sys.free()
	_micro_systems.clear()
	for e in _micro_enemies:
		if is_instance_valid(e):
			e.free()
	_micro_enemies.clear()
	if _proj_pool != null:
		_proj_pool.free()
		_proj_pool = null
	_pipeline = null
	_grid = null


func _micro_sys(p_name: String, p_store: MetaStore) -> ElementalSystem:
	var sys := ElementalSystem.new()
	sys.name = p_name
	tree.get_root().add_child(sys)
	sys.pipeline = _pipeline
	sys.enemy_grid = _grid
	sys.meta_store = p_store
	_micro_systems.append(sys)
	return sys


func _micro_enemy(_p_sys: ElementalSystem) -> Enemy:
	# 裸 Enemy（不入树不入池）：仅承载 uid/position/elemental 宿主字段
	var e := Enemy.new()
	_micro_enemies.append(e)
	return e


func _make_micro_weapon(p_sys: ElementalSystem, p_pos: Vector2) -> WeaponBase:
	_wd_counter += 1
	var d := WeaponData.new()
	d.id = StringName("W_PKG14_%d" % _wd_counter)
	d.display_name = "Pkg14 测试武器 %d" % _wd_counter
	d.form = GameConst.WeaponForm.BALLISTIC
	d.crit_rate = 0.0
	d.crit_dmg = 2.0
	d.hitbox_r = 6.0
	for i in range(5):
		var ls := WeaponLevelStats.new()
		ls.base_atk = 10.0
		ls.rof = 5.0
		ls.cd = 0.5
		ls.pierce = 1
		ls.pellets = 1
		d.upgrade_table.append(ls)
	var w: WeaponBase = BallisticWeapon.new()
	w.name = "Pkg14Weapon_%d" % _wd_counter
	tree.get_root().add_child(w)
	w.position = p_pos
	w.setup(d, null, {
		"pipeline": _pipeline,
		"projectile_pool": _proj_pool,
		"enemy_grid": _grid,
		"laser_pool": null,
		"elemental": p_sys,
	})
	_micro_weapons.append(w)
	return w


func _make_stub_player(p_weapons: Array) -> Node2D:
	var psrc := GDScript.new()
	psrc.source_code = "extends Node2D\nvar weapon_slots: Array = []\n"
	psrc.reload()
	var stub: Node2D = psrc.new()
	tree.get_root().add_child(stub)
	stub.weapon_slots = p_weapons
	_micro_stubs.append(stub)
	for w in p_weapons:
		if w is WeaponBase:
			(w as WeaponBase).player = stub
	return stub


# ── GameLoop 夹具（pkg10 模式） ────────────────────────────────────
func _boot_game_loop() -> void:
	_gl = GameLoop.new()
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU
			and _gl.meta_store != null and _gl.meta_panel != null
			and _gl.achievement_tracker != null):
		push_error("[pkg14] Boot 异常（MENU/MetaStore/MetaPanel/Tracker 未就绪，后续用例级联失败）")
	# ★ 隔离纪律：boot 后第一件事——切测试档路径 + 清残留
	_gl.meta_store.set_save_path(TEST_PATH)
	_gl.meta_store.wipe()


func _teardown_game_loop() -> void:
	tree.paused = false
	if _gl != null and _gl.meta_store != null:
		_gl.meta_store.wipe()                     # 仅清本 runner 注入测试档
	if _gl != null:
		_gl.free()
		_gl = null


# ══ C9：芯片图鉴追踪（equip 成功尾 mark） ═══════════════════════════
func _test_c9_chip_tracking() -> void:
	print("── C9 芯片追踪 ──")
	_gl.meta_store.wipe()
	_gl.chip_handler.reset_run()
	_gl.chip_handler.unlocked_slots = 3           # 解锁链夹具（equip 五门容量门）
	var ok := _gl.chip_handler.equip(&"CHIP_ATK", 0)
	ok = ok and _gl.meta_store.chip_seen(&"CHIP_ATK") \
		and not _gl.meta_store.chip_seen(&"CHIP_CRIT")
	_check("C9 芯片追踪：equip 成功尾 mark_chip_seen 首见收录（未装备键不收录）", ok)


# ══ C10：遗物图鉴追踪（activate 成功尾 mark） ═══════════════════════
func _test_c10_relic_tracking() -> void:
	print("── C10 遗物追踪 ──")
	_gl.meta_store.wipe()
	_gl.relic_handler.reset_run()
	var ok := _gl.relic_handler.activate(&"REL_MIDAS")
	ok = ok and _gl.meta_store.relic_seen(&"REL_MIDAS") \
		and not _gl.meta_store.relic_seen(&"REL_ECHO")
	_check("C10 遗物追踪：activate 成功尾 mark_relic_seen 首见收录（未激活键不收录）", ok)


# ══ C11：六剧变图鉴收录（★免疫早退仍标） ═══════════════════════════
func _test_c11_reactions() -> void:
	print("── C11 六剧变 ──")
	var s := _new_store()
	var sys := _micro_sys("Pkg14C11", s)
	var order: Array[int] = [
		GameConst.ReactionType.RXN_FIR_ICE, GameConst.ReactionType.RXN_FIR_LTG,
		GameConst.ReactionType.RXN_ICE_LTG, GameConst.ReactionType.RXN_WAT_ICE,
		GameConst.ReactionType.RXN_WAT_LTG, GameConst.ReactionType.RXN_WAT_FIR,
	]
	var pairs: Dictionary = {
		GameConst.ReactionType.RXN_FIR_ICE: [GameConst.Element.FIR, GameConst.Element.ICE],
		GameConst.ReactionType.RXN_FIR_LTG: [GameConst.Element.FIR, GameConst.Element.LTG],
		GameConst.ReactionType.RXN_ICE_LTG: [GameConst.Element.ICE, GameConst.Element.LTG],
		GameConst.ReactionType.RXN_WAT_ICE: [GameConst.Element.WAT, GameConst.Element.ICE],
		GameConst.ReactionType.RXN_WAT_LTG: [GameConst.Element.WAT, GameConst.Element.LTG],
		GameConst.ReactionType.RXN_WAT_FIR: [GameConst.Element.WAT, GameConst.Element.FIR],
	}
	var all_marked := true
	var immune_marked := false
	var immune_no_freeze := false
	for rxn in order:
		var e := _micro_enemy(sys)
		var st := ElementalState.new()
		var pair: Array = pairs[rxn]
		st.gauges[int(pair[0])] = 10.0
		st.gauges[int(pair[1])] = 10.0
		if rxn == GameConst.ReactionType.RXN_WAT_ICE:
			st.immune_mask = GameConst.IMMUNE_FREEZE   # ★免疫早退路径
		e.set("elemental", st)
		sys._trigger_reaction(e, st, rxn)
		all_marked = all_marked and s.reaction_seen(MetaStore.reaction_seen_key(rxn))
		if rxn == GameConst.ReactionType.RXN_WAT_ICE:
			immune_marked = s.reaction_seen("rxn_wat_ice")
			immune_no_freeze = st.freeze_timer <= 0.0 and st.gauges[GameConst.Element.WAT] == 0.0
	_check("C11 六剧变收录：_trigger_reaction 入口位六键全标（含★冻结免疫早退仍标——"
		+ "freeze_timer 0 + 双槽已清 + seen true）", all_marked and immune_marked and immune_no_freeze,
		"all=%s immune_marked=%s no_freeze=%s" % [str(all_marked), str(immune_marked),
			str(immune_no_freeze)])


# ══ C12：三增幅图鉴收录 + dead no-op ═════════════════════════════════
func _test_c12_amplify() -> void:
	print("── C12 三增幅 ──")
	var s := _new_store()
	var sys := _micro_sys("Pkg14C12", s)
	# dead no-op 先行（干净 store 反证）：melt 条件满足但目标已死 → 不收录
	var dead_e := _micro_enemy(sys)
	var dst := ElementalState.new()
	dst.gauges[GameConst.Element.ICE] = 10.0
	dead_e.set("elemental", dst)
	dead_e.dead = true
	sys.consume_amplify(dead_e, GameConst.Element.FIR)
	var dead_noop := not s.reaction_seen("amp_melt")
	# 三分支存活路径：melt（ICE 附 + FIR 击）/ quench（WAT 附 + FIR 击）/ vapor（FIR 附 + ICE 击）
	var e1 := _micro_enemy(sys)
	var st1 := ElementalState.new()
	st1.gauges[GameConst.Element.ICE] = 10.0
	e1.set("elemental", st1)
	sys.consume_amplify(e1, GameConst.Element.FIR)
	var e2 := _micro_enemy(sys)
	var st2 := ElementalState.new()
	st2.gauges[GameConst.Element.WAT] = 10.0
	e2.set("elemental", st2)
	sys.consume_amplify(e2, GameConst.Element.FIR)
	var e3 := _micro_enemy(sys)
	var st3 := ElementalState.new()
	st3.gauges[GameConst.Element.FIR] = 10.0
	e3.set("elemental", st3)
	sys.consume_amplify(e3, GameConst.Element.ICE)
	var ok := dead_noop and s.reaction_seen("amp_melt") and s.reaction_seen("amp_quench") \
		and s.reaction_seen("amp_vapor")
	_check("C12 三增幅收录：dead no-op（不标）+ melt/quench/vapor 三分支各标", ok,
		"dead_noop=%s melt=%s quench=%s vapor=%s" % [str(dead_noop), str(s.reaction_seen("amp_melt")),
			str(s.reaction_seen("amp_quench")), str(s.reaction_seen("amp_vapor"))])


# ══ C13：共鸣首达收录（rebuild_registries 尾） ═══════════════════════
func _test_c13_resonance_first() -> void:
	print("── C13 共鸣首达 ──")
	var s := _new_store()
	var sys := _micro_sys("Pkg14C13", s)
	var w1 := _make_micro_weapon(sys, Vector2(100.0, 40.0))
	var w2 := _make_micro_weapon(sys, Vector2(140.0, 40.0))
	var stub := _make_stub_player([w1, w2])
	var ignite: TraitData = load(TRAIT_FIR)
	w1.attach_trait(ignite)                       # rebuild：FIR=1（未达阈值不标）
	var before := s.reaction_seen("res_fire")
	w2.attach_trait(ignite)                       # rebuild：FIR=2 → 首达标 res_fire
	var ok := not before and s.reaction_seen("res_fire") \
		and not s.reaction_seen("res_ice") and not s.reaction_seen("res_wat")
	_check("C13 共鸣首达：同元素 ≥2 首达 rebuild 尾标 res_fire（1 把不标/异元素不标）",
		ok, "before=%s res_fire=%s" % [str(before), str(s.reaction_seen("res_fire"))])


# ══ C14：null 注入守卫四站点（降级不崩） ═════════════════════════════
func _test_c14_null_guards() -> void:
	print("── C14 null 守卫 ──")
	_gl.meta_store.wipe()
	# 站点 1/2：chip/relic 处理器 meta_store（与 tracker）置 null → 成功路径不崩不收录
	_gl.chip_handler.meta_store = null
	_gl.chip_handler.achievement_tracker = null
	_gl.chip_handler.unlocked_slots = 3
	var chip_ok := _gl.chip_handler.equip(&"CHIP_CRIT", 0)
	var chip_unmarked := not _gl.meta_store.chip_seen(&"CHIP_CRIT")
	_gl.relic_handler.meta_store = null
	var relic_ok := _gl.relic_handler.activate(&"REL_ECHO")
	var relic_unmarked := not _gl.meta_store.relic_seen(&"REL_ECHO")
	# 站点 3：ElementalSystem meta_store null → _trigger_reaction 不崩
	var sys := ElementalSystem.new()
	sys.name = "Pkg14C14Sys"
	tree.get_root().add_child(sys)
	var e := Enemy.new()
	var st := ElementalState.new()
	st.gauges[GameConst.Element.FIR] = 10.0
	st.gauges[GameConst.Element.ICE] = 10.0
	e.set("elemental", st)
	sys._trigger_reaction(e, st, GameConst.ReactionType.RXN_FIR_ICE)
	sys.free()
	e.free()
	# 站点 4：AchievementTracker meta_store null → 五站点判定全 no-op 不崩
	var t := AchievementTracker.new()
	t.name = "Pkg14C14Tracker"
	tree.get_root().add_child(t)
	t.setup(null)
	t.on_chip_equipped(2, 6)
	t.on_weapon_slots_changed(5)
	t.on_run_settled(1000)
	t.reset_run()
	t.new_unlock_titles()
	if EventBus.enemy_killed.is_connected(t._on_enemy_killed):
		EventBus.enemy_killed.disconnect(t._on_enemy_killed)
	if EventBus.wave_started.is_connected(t._on_wave_started):
		EventBus.wave_started.disconnect(t._on_wave_started)
	t.free()
	# 恢复 GameLoop 注入（防后续用例污染）
	_gl.chip_handler.meta_store = _gl.meta_store
	_gl.chip_handler.achievement_tracker = _gl.achievement_tracker
	_gl.relic_handler.meta_store = _gl.meta_store
	_gl.chip_handler.reset_run()
	_gl.relic_handler.reset_run()
	_check("C14 null 守卫四站点：chip/relic/elemental/tracker 注入置 null → 操作成功路径不崩"
		+ "且 store 零收录（降级）", chip_ok and chip_unmarked and relic_ok and relic_unmarked)


# ══ C1：芯片图鉴 mark（首见/重复/空 id/即存） ═══════════════════════
func _test_c1_chip_mark() -> void:
	print("── C1 芯片 mark ──")
	var s := _new_store()
	var first := s.mark_chip_seen(&"CHIP_ATK")
	var repeat := s.mark_chip_seen(&"CHIP_ATK")
	var empty := s.mark_chip_seen(&"")
	var persisted := _reload_store().chip_seen(&"CHIP_ATK")
	_check("C1 芯片 mark：首见 true / 重复 false / 空 id false / 即存（reload 反证 true）",
		first and not repeat and not empty and persisted,
		"first=%s repeat=%s empty=%s persisted=%s" % [str(first), str(repeat), str(empty),
			str(persisted)])


# ══ C2：遗物图鉴 mark（首见/重复/即存） ═════════════════════════════
func _test_c2_relic_mark() -> void:
	print("── C2 遗物 mark ──")
	var s := _new_store()
	var first := s.mark_relic_seen(&"REL_MIDAS")
	var repeat := s.mark_relic_seen(&"REL_MIDAS")
	var empty := s.mark_relic_seen(&"")
	var persisted := _reload_store().relic_seen(&"REL_MIDAS")
	_check("C2 遗物 mark：首见 true / 重复 false / 空 id false / 即存（reload 反证 true）",
		first and not repeat and not empty and persisted,
		"first=%s repeat=%s empty=%s persisted=%s" % [str(first), str(repeat), str(empty),
			str(persisted)])


# ══ C3：反应图鉴 mark（三组代表键 + 未知 id 拒绝） ═══════════════════
func _test_c3_reaction_mark() -> void:
	print("── C3 反应 mark ──")
	var s := _new_store()
	var rxn := s.mark_reaction_seen("rxn_fir_ice")
	var amp := s.mark_reaction_seen("amp_melt")
	var res := s.mark_reaction_seen("res_fire")
	var repeat := s.mark_reaction_seen("amp_melt")
	var unknown := s.mark_reaction_seen("rxn_bogus")
	var persisted := _reload_store()
	var ok := rxn and amp and res and not repeat and not unknown \
		and persisted.reaction_seen("rxn_fir_ice") and persisted.reaction_seen("amp_melt") \
		and persisted.reaction_seen("res_fire") and not persisted.reaction_seen("rxn_bogus")
	_check("C3 反应 mark：剧变/增幅/共鸣三键首见 true / 重复 false / 未知 id false（warning）"
		+ " / 即存（reload 反证）", ok,
		"rxn=%s amp=%s res=%s repeat=%s unknown=%s" % [str(rxn), str(amp), str(res),
			str(repeat), str(unknown)])


# ══ C4：成就 unlock（首解/幂等/未知 id） ═════════════════════════════
func _test_c4_unlock_idempotent() -> void:
	print("── C4 unlock 幂等 ──")
	var s := _new_store()
	var first := s.unlock_achievement(&"ach_boss1")
	var has := s.has_achievement(&"ach_boss1")
	var repeat := s.unlock_achievement(&"ach_boss1")
	var unknown := s.unlock_achievement(&"ach_nope")
	var persisted := _reload_store().has_achievement(&"ach_boss1")
	_check("C4 unlock 幂等：首解 true / has true / 重复 no-op false / 未知 id false（warning）"
		+ " / 即存（reload 反证 true）",
		first and has and not repeat and not unknown and persisted,
		"first=%s has=%s repeat=%s unknown=%s persisted=%s" % [str(first), str(has),
			str(repeat), str(unknown), str(persisted)])


# ══ C5：convert_gold 软上限（七值锚） ════════════════════════════════
func _test_c5_convert_gold() -> void:
	print("── C5 convert_gold ──")
	var ok := MetaStore.convert_gold(-1) == 0 \
		and MetaStore.convert_gold(0) == 0 \
		and MetaStore.convert_gold(250) == 250 \
		and MetaStore.convert_gold(500) == 500 \
		and MetaStore.convert_gold(501) == 500 \
		and MetaStore.convert_gold(600) == 550 \
		and MetaStore.convert_gold(1000) == 750
	_check("C5 convert_gold 七值：-1→0 / 0→0 / 250→250 / 500→500 / 501→500 / 600→550 / 1000→750", ok,
		"vals=%d,%d,%d,%d,%d,%d,%d" % [MetaStore.convert_gold(-1), MetaStore.convert_gold(0),
			MetaStore.convert_gold(250), MetaStore.convert_gold(500), MetaStore.convert_gold(501),
			MetaStore.convert_gold(600), MetaStore.convert_gold(1000)])


# ══ C6：旧档缺节容忍（v1.3.0 档零迁移） ═════════════════════════════
func _test_c6_legacy_missing_sections() -> void:
	print("── C6 旧档缺节 ──")
	var s := _new_store()                         # 先建 store（构造即 wipe）再写旧形档
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "save_version", 1)
	cfg.set_value("meta", "crystal", 7)
	cfg.set_value("levels", "atk", 2)
	cfg.set_value("levels", "hpg", 0)
	cfg.set_value("levels", "greed", 0)
	cfg.set_value("levels", "seed_gold", 0)
	cfg.set_value("levels", "xp", 0)
	cfg.set_value("stats", "total_runs", 3)
	cfg.set_value("stats", "total_kills", 40)
	cfg.set_value("stats", "best_wave", 9)
	var write_err := cfg.save(TEST_PATH)
	s.load_save()
	var ok := write_err == OK and s.crystal == 7 and s.level(&"atk") == 2 \
		and s.total_kills == 40 and s.best_wave == 9 \
		and not s.chip_seen(&"CHIP_ATK") and not s.relic_seen(&"REL_MIDAS") \
		and not s.reaction_seen("rxn_fir_ice") and not s.has_achievement(&"ach_boss1")
	_check("C6 旧档缺节容忍：v1.3.0 形档（无 [seen]/[achievements]）读入静默空——"
		+ "既有段照常载入 + 四表全空", ok)


# ══ C7：脏键容忍（非 String 键跳过 / 脏型节空） ═════════════════════
func _test_c7_dirty_keys() -> void:
	print("── C7 脏键 ──")
	var s := _new_store()                         # 先建 store（构造即 wipe）再写脏档
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "save_version", 1)
	cfg.set_value("meta", "crystal", 0)
	cfg.set_value("seen", "chips", {"CHIP_ATK": true, 123: true})
	cfg.set_value("seen", "relics", {"REL_MIDAS": true})
	cfg.set_value("seen", "reactions", "not_a_dict")
	var write_err := cfg.save(TEST_PATH)
	s.load_save()
	var ok := write_err == OK and s.chip_seen(&"CHIP_ATK") \
		and not s.chip_seen(&"CHIP_ATK2") and s.relic_seen(&"REL_MIDAS") \
		and not s.reaction_seen("rxn_fir_ice")
	_check("C7 脏键容忍：seen.chips 混入 int 键被跳过（String 键收录）/ reactions 脏型"
		+ " warning + 空表 / 其余键正常", ok)


# ══ C8：wipe 清四表 ═════════════════════════════════════════════════
func _test_c8_wipe_clears() -> void:
	print("── C8 wipe ──")
	var s := _new_store()
	s.mark_chip_seen(&"CHIP_ATK")
	s.mark_relic_seen(&"REL_MIDAS")
	s.mark_reaction_seen("amp_vapor")
	s.unlock_achievement(&"ach_wave10")
	s.wipe()
	var ok := not s.chip_seen(&"CHIP_ATK") and not s.relic_seen(&"REL_MIDAS") \
		and not s.reaction_seen("amp_vapor") and not s.has_achievement(&"ach_wave10") \
		and not FileAccess.file_exists(TEST_PATH)
	_check("C8 wipe：图鉴三表 + 成就表全清 + 存档文件删除", ok)


# ── tracker 单元夹具（直调 handler 不走总线——避免 GameLoop 自带 tracker 竞听） ──
func _new_tracker(p_store: MetaStore) -> AchievementTracker:
	var t := AchievementTracker.new()
	t.name = "Pkg14Tracker%d" % randi()
	tree.get_root().add_child(t)
	t.setup(p_store)                              # setup 连总线（真实语义）；用毕 _drop_tracker
	return t


func _drop_tracker(p_t: AchievementTracker) -> void:
	if p_t == null or not is_instance_valid(p_t):
		return
	if EventBus.enemy_killed.is_connected(p_t._on_enemy_killed):
		EventBus.enemy_killed.disconnect(p_t._on_enemy_killed)
	if EventBus.wave_started.is_connected(p_t._on_wave_started):
		EventBus.wave_started.disconnect(p_t._on_wave_started)
	p_t.free()


func _boss_enemy(p_id: StringName, p_is_boss: bool) -> Enemy:
	# 真夹具：裸 Enemy + EnemyData（spawn 走生产路径——tags 合成/波次缩放/行为降级）
	var d := EnemyData.new()
	d.id = p_id
	d.display_name = String(p_id)
	d.hp_base = 100.0
	d.spd_base = 0.0
	d.dmg_base = 8.0
	d.exp_base = 3.0
	d.tp_cost = 1.0
	d.hitbox_r = 14.0
	var e := Enemy.new()
	e.spawn(d, 1, GameConst.TAG_BOSS if p_is_boss else 0)
	return e


# ══ C15：Boss 三档真夹具 + 本地信号 ═════════════════════════════════
func _test_c15_boss_tiers() -> void:
	print("── C15 Boss 三档 ──")
	var s := _new_store()
	var t := _new_tracker(s)
	var unlocks: Array[StringName] = []
	t.achievement_unlocked.connect(func(p_id: StringName, _p_title: String) -> void:
		unlocks.append(p_id))
	# 非 Boss（无 TAG_BOSS）不标
	var minion := _boss_enemy(&"E1_testling", false)
	t._on_enemy_killed(minion)
	minion.free()
	# TAG_BOSS 但 id 非三档 → 不标（精确匹配）
	var unknown := _boss_enemy(&"E6_bossX", true)
	t._on_enemy_killed(unknown)
	unknown.free()
	var none_marked := unlocks.is_empty() and not s.has_achievement(&"ach_boss1")
	# 三档逐一解锁（各自独立、不回溯）
	for i in range(3):
		var b := _boss_enemy(AchievementTracker.BOSS_IDS[i], true)
		t._on_enemy_killed(b)
		b.free()
	var all_tiers := unlocks.size() == 3 and unlocks == AchievementTracker.BOSS_ACH_IDS \
		and s.has_achievement(&"ach_boss1") and s.has_achievement(&"ach_boss2") \
		and s.has_achievement(&"ach_boss3")
	_drop_tracker(t)
	_check("C15 Boss 三档：真夹具 E6_boss1/2/3 逐一精确解锁 + 本地信号三次 "
		+ "+ 非 Boss/未知 Boss id 不标", none_marked and all_tiers,
		"none=%s unlocks=%s" % [str(none_marked), str(unlocks)])


# ══ C16：波次三档（≥10/20/30） ══════════════════════════════════════
func _test_c16_wave_tiers() -> void:
	print("── C16 波次三档 ──")
	var s := _new_store()
	var t := _new_tracker(s)
	t._on_wave_started(5)
	var below := not s.has_achievement(&"ach_wave10")
	t._on_wave_started(10)
	var w10 := s.has_achievement(&"ach_wave10") and not s.has_achievement(&"ach_wave20")
	t._on_wave_started(20)
	var w20 := s.has_achievement(&"ach_wave20") and not s.has_achievement(&"ach_wave30")
	t._on_wave_started(30)
	var w30 := s.has_achievement(&"ach_wave30")
	_drop_tracker(t)
	_check("C16 波次三档：wave 5 不标 / 10 标 wave10 / 20 标 wave20 / 30 标 wave30",
		below and w10 and w20 and w30)


# ══ C17：芯片成就判定（套装 ≥2 / 满配 ≥6） ═══════════════════════════
func _test_c17_chip_judgment() -> void:
	print("── C17 芯片判定 ──")
	var s := _new_store()
	var t := _new_tracker(s)
	t.on_chip_equipped(1, 5)                      # 主属性 1 枚 / 5 枚 → 均不达
	var below := not s.has_achievement(&"ach_chip_set") and not s.has_achievement(&"ach_chip_full")
	t.on_chip_equipped(2, 5)                      # 套装达 / 满配未达
	var mid := s.has_achievement(&"ach_chip_set") and not s.has_achievement(&"ach_chip_full")
	t.on_chip_equipped(2, 6)                      # 满配达
	var full := s.has_achievement(&"ach_chip_full")
	_drop_tracker(t)
	_check("C17 芯片判定：(1,5) 双不标 / (2,5) 仅套装 / (2,6) 补满配", below and mid and full)


# ══ C18：武器/击杀成就判定（≥5 把 / ≥1000 累计） ═════════════════════
func _test_c18_weapon_kills_judgment() -> void:
	print("── C18 武器/击杀判定 ──")
	var s := _new_store()
	var t := _new_tracker(s)
	t.on_weapon_slots_changed(4)
	var w4 := not s.has_achievement(&"ach_weapons5")
	t.on_weapon_slots_changed(5)
	var w5 := s.has_achievement(&"ach_weapons5")
	t.on_run_settled(999)
	var k999 := not s.has_achievement(&"ach_kills1000")
	t.on_run_settled(1000)
	var k1000 := s.has_achievement(&"ach_kills1000")
	_drop_tracker(t)
	_check("C18 武器/击杀判定：4 把不标 / 5 把标 / 999 不标 / 1000 标", w4 and w5 and k999 and k1000)


# ══ C19：清单去重 + reset（信号不重放） ═════════════════════════════
func _test_c19_list_dedup_reset() -> void:
	print("── C19 清单去重 ──")
	var s := _new_store()
	var t := _new_tracker(s)
	var signal_count := [0]
	t.achievement_unlocked.connect(func(_p_id: StringName, _p_title: String) -> void:
		signal_count[0] += 1)
	t._on_wave_started(30)                        # 三档同时达 → 3 次解锁
	t._on_wave_started(30)                        # 幂等 → 0 次新解锁
	var dedup: bool = int(signal_count[0]) == 3 \
		and t.new_unlock_titles() == ["卅波传奇", "廿波征途", "十波之约"]
	t.reset_run()
	var cleared := t.new_unlock_titles().is_empty() and s.has_achievement(&"ach_wave30")
	_drop_tracker(t)
	_check("C19 清单去重 + reset：wave30 重复触发不重放信号（恰 3 次）+ 清单序表驱动 "
		+ "+ reset 清清单不清已解锁持久态", dedup and cleared,
		"count=%d" % signal_count[0])


# ══ C23：结算屏集成（软上限 + 击杀档新成就行） ═══════════════════════
func _test_c23_settle_screen() -> void:
	print("── C23 结算集成 ──")
	_gl.meta_store.wipe()
	_gl.meta_store.record_run(1000, 1)            # 预置累计击杀达千（击杀档阈值）
	var started := _gl.start_run() and _gl.state == GameConst.GameStatus.PLAYING
	_gl._add_gold(600)                            # greed 0（wipe 过）→ gold == 600
	_gl._on_player_died()
	var ok := started and _gl.state == GameConst.GameStatus.GAME_OVER
	ok = ok and _gl.game_over_screen.crystal_text() == "结晶 +550"
	ok = ok and _gl.game_over_screen.new_achievements_text() == "新成就：千锤百炼"
	ok = ok and _gl.meta_store.has_achievement(&"ach_kills1000") \
		and _gl.meta_store.crystal == 550
	if _gl.state == GameConst.GameStatus.GAME_OVER:
		_gl.goto_menu()                           # 回 MENU 供后续用例
	_check("C23 结算集成：gold=600 软上限 → 「结晶 +550」+ 新成就行「新成就：千锤百炼」"
		+ " + store 入账/解锁一致", ok,
		"crystal=%s ach=%s" % [_gl.game_over_screen.crystal_text(),
		_gl.game_over_screen.new_achievements_text()])

# ── 面板夹具 ──────────────────────────────────────────────────────
func _rects_ok(p_expected: int) -> bool:
	# layout_rects 数量 + 两两无交集（C20 分口径断言原子）
	var rects := _gl.meta_panel.layout_rects()
	if rects.size() != p_expected:
		return false
	for i in range(rects.size()):
		for j in range(i + 1, rects.size()):
			if (rects[i] as Rect2).intersects(rects[j] as Rect2):
				return false
	return true


# ══ C20：tab/rects 分口径 {10/19/18/20/14} ═══════════════════════════
func _test_c20_tab_rects() -> void:
	print("── C20 tab/rects ──")
	_gl.meta_store.wipe()
	_gl.meta_panel.open(_gl.meta_store)           # 默认 tab0
	var ok := _gl.meta_panel.current_tab() == 0 and _rects_ok(10)
	_gl.meta_panel.select_tab(1)                  # 图鉴·芯片册
	ok = ok and _gl.meta_panel.current_tab() == 1 and _rects_ok(19)
	_gl.meta_panel.select_book(0)
	ok = ok and _gl.meta_panel.current_book() == 0 and _rects_ok(19)
	_gl.meta_panel.select_book(1)                 # 遗物册
	ok = ok and _gl.meta_panel.current_book() == 1 and _rects_ok(18)
	_gl.meta_panel.select_book(2)                 # 反应册
	ok = ok and _gl.meta_panel.current_book() == 2 and _rects_ok(20)
	_gl.meta_panel.select_tab(2)                  # 成就页
	ok = ok and _gl.meta_panel.current_tab() == 2 and _rects_ok(14)
	_gl.meta_panel.select_tab(0)
	ok = ok and _rects_ok(10)
	_check("C20 tab/rects 分口径：tab0=10 / 芯片册=19 / 遗物册=18 / 反应册=20 / 成就页=14"
		+ "（隐藏页不入列且两两无交集）", ok)


# ══ C21：cell/row 文案两态 ═══════════════════════════════════════════
func _test_c21_cell_row_text() -> void:
	print("── C21 cell/row 文案 ──")
	_gl.meta_store.wipe()
	_gl.meta_panel.open(_gl.meta_store)
	_gl.meta_panel.select_tab(1)
	_gl.meta_panel.select_book(0)
	var unseen := _gl.meta_panel.cell_text(0, 0) == "？？？\n未收录"
	# 首键收录 → "display_name\ndescription"（registry 资源直读；序 = 键 String 升序）
	var names: Array[String] = []
	for k in _gl.registry.chips:
		names.append(String(k))
	names.sort()
	var first_id := StringName(names[0])
	var marked := _gl.meta_store.mark_chip_seen(first_id)
	var chip_data := _gl.registry.get_chip(first_id)
	var seen_text := _gl.meta_panel.cell_text(0, 0)
	var seen_ok := marked and chip_data != null \
		and seen_text == "%s\n%s" % [chip_data.display_name, chip_data.description]
	# 成就行两态（表序首行 = ach_boss1）
	var row_before := _gl.meta_panel.achievement_row_text(0)
	var unlocked := _gl.meta_store.unlock_achievement(&"ach_boss1")
	var row_after := _gl.meta_panel.achievement_row_text(0)
	var row_ok := row_before == "『首破强敌』击败第一位 Boss — 未达成" and unlocked \
		and row_after == "『首破强敌』击败第一位 Boss — 已达成"
	# 反应行格式（balance 就绪 → 表驱动前缀 + 数值段非空）
	var rxn_text := _gl.meta_panel.cell_text(2, 0)
	var rxn_ok := rxn_text.begins_with("【剧变】碎裂 · 火+冰")
	_check("C21 cell/row 文案两态：未收录「？？？/未收录」→ 收录「名+描述」；成就行未达成→已达成；"
		+ "反应行表驱动前缀", unseen and seen_ok and row_ok and rxn_ok,
		"unseen=%s seen=%s row=%s rxn=%s" % [str(unseen), str(seen_text.length()),
			str(row_ok), rxn_text])


# ══ C22：清档两击流（armed 文案 + 二击仲裁） ══════════════════════════
func _test_c22_wipe_flow() -> void:
	print("── C22 清档两击 ──")
	_gl.meta_store.wipe()
	_gl.meta_store.mark_chip_seen(&"CHIP_ATK")
	_gl.meta_panel.open(_gl.meta_store)           # tab0（清档钮所在页）
	var before_text := _gl.meta_panel.wipe_button_text()
	_gl.meta_panel._on_wipe_pressed()             # 首击：armed
	var armed_text := _gl.meta_panel.wipe_button_text()
	var still_seen := _gl.meta_store.chip_seen(&"CHIP_ATK")
	_gl.meta_panel._on_wipe_pressed()             # 二击：emit → GameLoop._on_meta_wipe 仲裁
	var cleared := not _gl.meta_store.chip_seen(&"CHIP_ATK")
	var reset_text := _gl.meta_panel.wipe_button_text()
	var balance_ok := String(_gl.meta_panel._balance_label.text) == "结晶：0"
	_check("C22 清档两击流：「清除存档」→ 首击「确认清除？」（未清）→ 二击仲裁清档 + 文案/armed 复位"
		+ " + 余额归零回写",
		before_text == "清除存档" and armed_text == "确认清除？" and still_seen and cleared \
			and reset_text == "清除存档" and balance_ok)


# ══ C24：收尾核对（version / PROGRESS 对账 / A13 留痕） ═══════════════
func _test_c24_closure() -> void:
	print("── C24 收尾 ──")
	var version: String = ProjectSettings.get_setting("application/config/version", "")
	var version_ok := version == "1.4.0"          # v1.4.0 授权更新：version 随版本推进
	var progress := _read_source("res://PROGRESS.md")
	var progress_ok := (not progress.is_empty()) and progress.contains("1531") \
		and progress.contains("pkg14 24") and progress.contains("v1.4.0 增量")
	var a13 := _read_source("res://docs/analysis/A13_v1.4.0_design.md")
	var a13_ok := (not a13.is_empty()) and a13.contains("H1") and a13.contains("H2") \
		and a13.contains("H3") and a13.contains("H4") and a13.contains("convert_gold") \
		and a13.contains("RESONANCE_SEEN_KEYS")
	_check("C24：收尾——version=1.4.0 + PROGRESS 对账（1531/pkg14 24/v1.4.0 增量；审查后对账修正）"
		+ " + A13 留痕含 H1~H4 与软上限/共鸣映射", version_ok and progress_ok and a13_ok,
		"version=%s progress=%s a13=%s" % [version, str(progress_ok), str(a13_ok)])

# tests/runner/pkg14_extra_cases.gd
# v1.4.0 验收补充用例体（tester 独立验收补漏；由 test_pkg14_extra.gd 入口在 autoload
# 就绪后运行时加载编译）。补 pkg14 C1~C24 之外的验收缺口，每恰 1 断言：
#   X1 convert_gold 补锚（499 / 10^6 / 大负——A13 §1.2 公式独立复算）
#   X2 reaction_seen_key 六映射 + 未知 → ""（静态映射单元，C3/C11 仅间接覆盖）
#   X3 RESONANCE_SEEN_KEYS 四映射封闭 + mark 通道（C13 仅覆盖 res_fire 单键）
#   X4 equip 失败门不标图鉴（容量门 + 未知 id 门 + 成功对照——C9 仅成功路径）
#   X5 存档双向兼容（新档写 [seen]/[achievements] → 旧读者视角原节逐项对账；
#      剥新节模拟旧版写回 → 现行读缺节容忍——任务口径「只验缺节容忍方向」）
#   X6 图鉴册选头部计数「芯片 n/12 / 遗物 n/11 / 反应 n/13」与 store 查询双向对账
#   X7 ★成就全链（真 spawner 生产路径 spawn E6_boss1 → 总线 emit enemy_killed →
#      解锁即存 + 跳字 + 成就行 + 结算屏四点同帧一致 + spawner 归还回收——
#      订阅序行为验证：tracker 读 tags/id 先于池归还清零，铁律 6）
#   X8 软上限端到端 greed 局（greed Lv4 → _add_gold(500) → gold==600 手算锚 →
#      死亡结转 convert_gold(600)==550 +「结晶 +550」）
#   X9 软上限 ≤500 全额段端到端（gold=300 → 「结晶 +300」，pkg14 C23 仅覆盖 600 档）
#   X10 结算屏新成就行两态（真结算零新解锁 → 空 + 隐藏；多条 join「新成就：A · B」）
# 隔离纪律（pkg14 同款）：standalone MetaStore 一律 set_save_path(测试档) + 构造即 wipe；
# GameLoop boot 后首件事切测试档 + wipe；收尾仅清测试档（不触碰默认档/真机存档）。
extends RefCounted

const TEST_PATH := "user://pkg14_extra_meta_test.cfg"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _stores: Array[MetaStore] = []               # 用例独立 store（收尾统一 free）

# ── GameLoop 夹具（pkg14 模式） ──
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_ensure_autoloads()
	_test_x1_convert_gold_extra_anchors()         # X1
	_test_x2_reaction_seen_key_map()              # X2
	_test_x3_resonance_seen_keys()                # X3
	_test_x5_save_bidirectional_compat()          # X5（文件面，无需 boot）
	_boot_game_loop()
	_test_x4_equip_gate_fail_no_mark()            # X4
	_test_x6_book_header_counts()                 # X6
	_test_x7_boss_full_chain()                    # X7
	_test_x8_softcap_greed_end_to_end()           # X8
	_test_x9_softcap_full_rate_segment()          # X9
	_test_x10_settle_row_two_states()             # X10
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
		push_error("[pkg14_extra] autoload 未就绪（后续用例级联失败）")


func _new_store() -> MetaStore:
	# 用例独立 store：测试档路径 + 构造即 wipe（首见判定从零开始）
	var s := MetaStore.new()
	s.name = "Pkg14ExtraStore%d" % _stores.size()
	tree.get_root().add_child(s)
	s.set_save_path(TEST_PATH)
	s.wipe()
	_stores.append(s)
	return s


func _reload_store() -> MetaStore:
	# 即存反证：同路径新实例显式 load_save（不 wipe）
	var s := MetaStore.new()
	s.name = "Pkg14ExtraReload%d" % _stores.size()
	tree.get_root().add_child(s)
	s.set_save_path(TEST_PATH)
	s.load_save()
	_stores.append(s)
	return s


func _teardown() -> void:
	# 隔离纪律收尾：仅清本 runner 注入的测试档（不触碰默认档）
	for s in _stores:
		if is_instance_valid(s):
			s.wipe()
			s.free()
	_stores.clear()
	var cfg := ConfigFile.new()
	if cfg.load(TEST_PATH) == OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))


# ── GameLoop 夹具（pkg14 模式） ────────────────────────────────────
func _boot_game_loop() -> void:
	_gl = GameLoop.new()
	_gl.name = "GameLoopUnderTestExtra"
	tree.get_root().add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU
			and _gl.meta_store != null and _gl.meta_panel != null
			and _gl.achievement_tracker != null):
		push_error("[pkg14_extra] Boot 异常（MENU/MetaStore/MetaPanel/Tracker 未就绪，"
			+ "后续用例级联失败）")
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


# ══ X1：convert_gold 补锚（499 / 10^6 / 大负） ═══════════════════════
func _test_x1_convert_gold_extra_anchors() -> void:
	print("── X1 convert_gold 补锚 ──")
	# 公式独立复算（A13 §1.2）：499≤500 全额；10^6 → 500+floor(999500×0.5)=500250；负钳 0
	var ok: bool = MetaStore.convert_gold(499) == 499 \
		and MetaStore.convert_gold(1000000) == 500250 \
		and MetaStore.convert_gold(-1000000) == 0
	_check("X1 convert_gold 补锚：499→499（阈值下沿）/ 1000000→500250（超出段 floor×0.5 手算）"
		+ " / -1000000→0（负钳）", ok,
		"vals=%d,%d,%d" % [MetaStore.convert_gold(499), MetaStore.convert_gold(1000000),
			MetaStore.convert_gold(-1000000)])


# ══ X2：reaction_seen_key 六映射 + 未知 → "" ═════════════════════════
func _test_x2_reaction_seen_key_map() -> void:
	print("── X2 reaction_seen_key 映射 ──")
	var ok: bool = MetaStore.reaction_seen_key(GameConst.ReactionType.RXN_FIR_ICE) == "rxn_fir_ice" \
		and MetaStore.reaction_seen_key(GameConst.ReactionType.RXN_FIR_LTG) == "rxn_fir_ltg" \
		and MetaStore.reaction_seen_key(GameConst.ReactionType.RXN_ICE_LTG) == "rxn_ice_ltg" \
		and MetaStore.reaction_seen_key(GameConst.ReactionType.RXN_WAT_ICE) == "rxn_wat_ice" \
		and MetaStore.reaction_seen_key(GameConst.ReactionType.RXN_WAT_LTG) == "rxn_wat_ltg" \
		and MetaStore.reaction_seen_key(GameConst.ReactionType.RXN_WAT_FIR) == "rxn_wat_fir" \
		and MetaStore.reaction_seen_key(999) == ""
	# 六键均须落在 REACTIONS 封闭表内（映射出口封闭性）
	for rxn in range(GameConst.ReactionType.RXN_FIR_ICE, GameConst.ReactionType.RXN_WAT_FIR + 1):
		ok = ok and MetaStore.REACTIONS.has(StringName(MetaStore.reaction_seen_key(rxn)))
	_check("X2 reaction_seen_key：六中性 ID → 六封闭键逐一精确 + 键均 ∈ REACTIONS + 未知 999 → \"\"", ok)


# ══ X3：RESONANCE_SEEN_KEYS 四映射封闭 + mark 通道 ═══════════════════
func _test_x3_resonance_seen_keys() -> void:
	print("── X3 共鸣键映射 ──")
	var ok: bool = MetaStore.RESONANCE_SEEN_KEYS.size() == 4 \
		and String(MetaStore.RESONANCE_SEEN_KEYS.get(GameConst.Element.FIR, "")) == "res_fire" \
		and String(MetaStore.RESONANCE_SEEN_KEYS.get(GameConst.Element.ICE, "")) == "res_ice" \
		and String(MetaStore.RESONANCE_SEEN_KEYS.get(GameConst.Element.LTG, "")) == "res_ltg" \
		and String(MetaStore.RESONANCE_SEEN_KEYS.get(GameConst.Element.WAT, "")) == "res_wat" \
		and MetaStore.RESONANCE_SEEN_KEYS.get(999, "") == ""
	# mark 通道四键逐一首见收录（C13 仅经 rebuild 覆盖 res_fire 单键）
	var s := _new_store()
	for e in range(GameConst.Element.FIR, GameConst.Element.WAT + 1):
		var key := String(MetaStore.RESONANCE_SEEN_KEYS.get(e, ""))
		ok = ok and s.mark_reaction_seen(key) and s.reaction_seen(key)
	_check("X3 RESONANCE_SEEN_KEYS：恰 4 键 FIR/ICE/LTG/WAT→res_* 精确 + 域外 → \"\""
		+ " + 四键经 mark 通道逐一收录", ok)


# ══ X5：存档双向兼容（新档写 → 旧读者视角对账 → 剥新节容忍） ══════════
func _test_x5_save_bidirectional_compat() -> void:
	print("── X5 存档双向 ──")
	var s := _new_store()
	s.crystal = 123
	s.record_run(7, 9)                            # total_runs=1 / total_kills=7 / best_wave=9
	s.mark_chip_seen(&"CHIP_ATK")
	s.mark_relic_seen(&"REL_MIDAS")
	s.mark_reaction_seen("amp_vapor")
	s.unlock_achievement(&"ach_boss1")
	var write_ok := s.save()
	# 方向①新档写 seen → 旧版代码模拟读：旧读者只解析 [meta]/[levels]/[stats]（v1.3.0 布局），
	# ConfigFile 节语义下未知节被忽略——原三节值必须逐项无损
	var cfg := ConfigFile.new()
	var load_err := cfg.load(TEST_PATH)
	var old_reader_ok: bool = write_ok and load_err == OK \
		and cfg.has_section("seen") and cfg.has_section("achievements") \
		and int(cfg.get_value("meta", "save_version", -1)) == 1 \
		and int(cfg.get_value("meta", "crystal", -1)) == 123 \
		and int(cfg.get_value("levels", "hpg", -1)) == 0 \
		and int(cfg.get_value("levels", "greed", -1)) == 0 \
		and int(cfg.get_value("stats", "total_runs", -1)) == 1 \
		and int(cfg.get_value("stats", "total_kills", -1)) == 7 \
		and int(cfg.get_value("stats", "best_wave", -1)) == 9
	# 方向②缺节容忍（任务口径）：模拟旧版读后写回（旧版 save 不含未知节）→ 剥 [seen]/
	# [achievements] 落盘 → 现行代码读入静默空 + 既有节照常
	cfg.erase_section("seen")
	cfg.erase_section("achievements")
	var stripped_err := cfg.save(TEST_PATH)
	var s2 := _reload_store()
	var legacy_ok: bool = stripped_err == OK \
		and not s2.chip_seen(&"CHIP_ATK") and not s2.relic_seen(&"REL_MIDAS") \
		and not s2.reaction_seen("amp_vapor") and not s2.has_achievement(&"ach_boss1") \
		and s2.crystal == 123 and s2.total_kills == 7 and s2.best_wave == 9
	_check("X5 存档双向：v1.4.0 新档（含 seen/achievements 节）旧读者视角原三节值逐项无损"
		+ " + 剥新节模拟旧版写回 → 现行读四表空容忍 + 既有节照常（save_version=1 零迁移）",
		old_reader_ok and legacy_ok,
		"old=%s legacy=%s" % [str(old_reader_ok), str(legacy_ok)])


# ══ X4：equip 失败门不标图鉴（容量门 + 未知 id 门 + 成功对照） ═════════
func _test_x4_equip_gate_fail_no_mark() -> void:
	print("── X4 equip 失败门不标 ──")
	_gl.meta_store.wipe()
	_gl.chip_handler.reset_run()
	_gl.chip_handler.unlocked_slots = 0           # 容量门（五门之一）：无空槽 → false
	var cap_gate := not _gl.chip_handler.equip(&"CHIP_ATK", 0) \
		and not _gl.meta_store.chip_seen(&"CHIP_ATK")
	_gl.chip_handler.unlocked_slots = 3
	var unknown_gate := not _gl.chip_handler.equip(&"CHIP_NOPE_X4", 0) \
		and not _gl.meta_store.chip_seen(&"CHIP_NOPE_X4")
	var success_ctrl := _gl.chip_handler.equip(&"CHIP_ATK", 0) \
		and _gl.meta_store.chip_seen(&"CHIP_ATK")
	_gl.chip_handler.reset_run()                  # 还原 equipped（防污染后续用例）
	_check("X4 equip 失败门不标：容量门（0 槽）false+零收录 / 未知 id 门 false+零收录 /"
		+ " 成功对照 true+收录（mark 在五门全过后的尾位）", cap_gate and unknown_gate and success_ctrl)


# ══ X6：册选头部计数与 store 查询双向对账 ═════════════════════════════
func _test_x6_book_header_counts() -> void:
	print("── X6 册选计数 ──")
	_gl.meta_store.wipe()
	_gl.meta_panel.open(_gl.meta_store)
	_gl.meta_panel.select_tab(1)
	# 独立查询真源：registry 键序收录 + store 查询计数（不复用面板内部计算）
	var chip_ids: Array[String] = []
	for k in _gl.registry.chips:
		chip_ids.append(String(k))
	chip_ids.sort()
	var relic_ids: Array[String] = []
	for k in _gl.registry.relics:
		relic_ids.append(String(k))
	relic_ids.sort()
	var chip_total := chip_ids.size()
	var relic_total := relic_ids.size()
	_gl.meta_store.mark_chip_seen(StringName(chip_ids[0]))
	_gl.meta_store.mark_chip_seen(StringName(chip_ids[1]))
	_gl.meta_panel.select_book(0)                 # 重渲册选钮文本
	var chip_text := _gl.meta_panel._book_buttons[0].text
	var chip_count := 0
	for cid in chip_ids:
		if _gl.meta_store.chip_seen(StringName(cid)):
			chip_count += 1
	_gl.meta_store.mark_relic_seen(StringName(relic_ids[0]))
	_gl.meta_panel.select_book(1)
	var relic_text := _gl.meta_panel._book_buttons[1].text
	var relic_count := 0
	for rid in relic_ids:
		if _gl.meta_store.relic_seen(StringName(rid)):
			relic_count += 1
	_gl.meta_store.mark_reaction_seen("rxn_fir_ice")
	_gl.meta_store.mark_reaction_seen("amp_melt")
	_gl.meta_panel.select_book(2)
	var rxn_text := _gl.meta_panel._book_buttons[2].text
	var rxn_count := 0
	for key in MetaStore.REACTIONS:
		if _gl.meta_store.reaction_seen(String(key)):
			rxn_count += 1
	var ok := chip_text == "芯片 %d/%d" % [chip_count, chip_total] and chip_count == 2 \
		and relic_text == "遗物 %d/%d" % [relic_count, relic_total] and relic_count == 1 \
		and rxn_text == "反应 %d/%d" % [rxn_count, MetaStore.REACTIONS.size()] and rxn_count == 2 \
		and chip_total == 12 and relic_total == 11
	_check("X6 册选计数：头部「芯片 2/12 / 遗物 1/11 / 反应 2/13」与 store 独立查询逐册一致"
		+ "（12/11 registry 出厂锚 + 13 REACTIONS 封闭表；H4）", ok,
		"%s|%s|%s" % [chip_text, relic_text, rxn_text])


# ══ X7：成就全链（真 Boss 夹具 → 总线派发 → 四点同帧一致） ════════════
func _test_x7_boss_full_chain() -> void:
	print("── X7 Boss 全链 ──")
	_gl.meta_store.wipe()
	_gl.meta_panel.open(_gl.meta_store)           # 注入 store 供成就行读取
	var started := _gl.start_run() and _gl.state == GameConst.GameStatus.PLAYING
	# 生产路径 spawn：spawner 队列 → tick 出队 → pool.acquire → E6_boss1 资源 + TAG_BOSS
	#（先清 start_run 预排的 wave-1 生成请求，保证本 tick 唯一生成体 = Boss1 夹具）
	_gl.spawner.spawn_queue.clear()
	_gl.spawner.enqueue({
		"data_id": &"E6_boss1",
		"wave": 10,
		"tags": GameConst.TAG_BOSS,
		"pos": Vector2(360.0, 300.0),
	})
	_gl.spawner.tick(1.0 / 120.0, _gl.enemy_grid)
	var boss := _gl.spawner.active.back() as Enemy
	var spawned_ok: bool = boss != null and boss.data != null \
		and boss.data.id == StringName("E6_boss1") and boss.is_boss()
	# 总线派发（连接序 = 派发序：tracker 先读 tags/data.id → spawner 后归还清零）
	EventBus.enemy_killed.emit(boss)
	# 四点同帧一致（无 await，同一帧内逐一观测）
	var persisted := _gl.meta_store.has_achievement(&"ach_boss1")
	var popup_text := ""
	for p in _gl.popup_manager._active_list:
		if is_instance_valid(p) and (p as DamagePopup)._label.text == "成就达成：首破强敌":
			popup_text = (p as DamagePopup)._label.text
	var row_text := _gl.meta_panel.achievement_row_text(0)
	var returned := not _gl.spawner.active.has(boss)
	# 即存反证（同帧落盘）
	var reload_ok := _reload_store().has_achievement(&"ach_boss1")
	# 结算屏点（死亡结算在同一局内）
	_gl._on_player_died()
	var settle_text := _gl.game_over_screen.new_achievements_text()
	if _gl.state == GameConst.GameStatus.GAME_OVER:
		_gl.goto_menu()                           # 回 MENU 供后续用例
	_check("X7 成就全链：真 spawner 产出 E6_boss1 + 总线派发 → 解锁即存（store+reload）"
		+ " + 跳字「成就达成：首破强敌」+ 成就行「已达成」+ 结算屏「新成就：首破强敌」"
		+ "四点同帧一致 + 敌已归还（订阅序先于池归还清零，铁律 6 行为验证）",
		started and spawned_ok and persisted and popup_text != "" \
			and row_text.contains("已达成") and returned and reload_ok \
			and settle_text == "新成就：首破强敌",
		"started=%s spawn=%s persist=%s popup=%s row=%s settle=%s" % [str(started),
			str(spawned_ok), str(persisted), popup_text, row_text, settle_text])


# ══ X8：软上限端到端（greed 局 → gold=600 手算 → 结转 550） ═══════════
func _test_x8_softcap_greed_end_to_end() -> void:
	print("── X8 软上限 greed 局 ──")
	_gl.meta_store.wipe()
	var cfg := ConfigFile.new()                   # greed Lv4 局外档（生产通道：载档 → 快照注入）
	cfg.set_value("meta", "save_version", 1)
	cfg.set_value("meta", "crystal", 0)
	cfg.set_value("levels", "greed", 4)
	cfg.save(TEST_PATH)
	_gl.meta_store.load_save()
	var started := _gl.start_run() and _gl.state == GameConst.GameStatus.PLAYING
	_gl._add_gold(500)                            # 手算：500 × (1 + 0.05×4) = 600
	var gold_anchor: int = _gl.gold
	_gl._on_player_died()
	var ok := started and gold_anchor == 600 \
		and _gl.meta_store.crystal == 550 \
		and _gl.game_over_screen.crystal_text() == "结晶 +550"
	if _gl.state == GameConst.GameStatus.GAME_OVER:
		_gl.goto_menu()
	_check("X8 软上限端到端 greed 局：greed Lv4 → _add_gold(500)=gold 600（手算锚）→"
		+ " 死亡结转 convert_gold(600)=550 入档 +「结晶 +550」", ok,
		"gold=%d crystal=%d text=%s" % [gold_anchor, _gl.meta_store.crystal,
			_gl.game_over_screen.crystal_text()])


# ══ X9：软上限 ≤500 全额段端到端（gold=300 → +300） ═══════════════════
func _test_x9_softcap_full_rate_segment() -> void:
	print("── X9 软上限 300 档 ──")
	_gl.meta_store.wipe()                         # greed 复 0（X8 档已 wipe）
	var started := _gl.start_run() and _gl.state == GameConst.GameStatus.PLAYING
	_gl._add_gold(300)
	_gl._on_player_died()
	var ok := started and _gl.meta_store.crystal == 300 \
		and _gl.game_over_screen.crystal_text() == "结晶 +300"
	if _gl.state == GameConst.GameStatus.GAME_OVER:
		_gl.goto_menu()
	_check("X9 软上限全额段：gold=300（≤500 不折）→ 死亡结转 crystal 300 +「结晶 +300」"
		+ "（C23 仅覆盖 600 超额档，本例补 ≤500 全额段）", ok,
		"crystal=%d text=%s" % [_gl.meta_store.crystal, _gl.game_over_screen.crystal_text()])


# ══ X10：结算屏新成就行两态（空隐藏 / 多条 join） ═════════════════════
func _test_x10_settle_row_two_states() -> void:
	print("── X10 新成就行两态 ──")
	# 空态（真结算路径：X9 局零新解锁 → 结算屏行隐藏）
	var empty_text := _gl.game_over_screen.new_achievements_text()
	var empty_hidden: bool = empty_text == "" and not _gl.game_over_screen._new_achievements_label.visible
	# 多条 join 态（真源同款入口 set_new_achievements）
	_gl.game_over_screen.set_new_achievements(["首破强敌", "十波之约"])
	var multi_text := _gl.game_over_screen.new_achievements_text()
	var multi_visible: bool = _gl.game_over_screen._new_achievements_label.visible
	_gl.game_over_screen.set_new_achievements([])  # 复位隐藏（防污染）
	var reset_hidden: bool = not _gl.game_over_screen._new_achievements_label.visible
	_check("X10 结算屏新成就行两态：零新解锁（真结算）→ 空文案 + 隐藏；多条 →「新成就：首破强敌 "
		+ "· 十波之约」可见；复位空清单恢复隐藏", empty_hidden and multi_text == "新成就：首破强敌 · 十波之约"
		and multi_visible and reset_hidden,
		"empty=%s multi=%s" % [empty_text, multi_text])

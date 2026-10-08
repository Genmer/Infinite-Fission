# tests/runner/r212_carddigest_cases.gd
# R212 用例体：选卡/升级爆帧六刀验收（vc18 真机：UI 尖峰 247ms / 感 138 / 玩 164——
# 选卡 UI 创建 + Android 字体回退链排版一帧干完是主犯）。
# 刀1=_fit_desc 量测缓存 + dots 预建（全平台）；刀2=选卡期 HUD 刷新节流（mobile 门）；
# 刀3=选卡期磁吸碎片隔帧 2δ（mobile 门，R26 收割演出语义零变化）；刀4=溢出消化预算
# 收紧 8ms（mobile 门）+ 高成本卡单迭代超帽保护；刀5=脏跳字排版每帧限批（mobile 门）；
# 刀6=LEVEL_UP/PAUSED 探针补洞（全平台，vc19 验刀口径）。
# mobile 门行为在 headless 以「测试覆写口 + 源级锚」（r207_split 先例）双轨验收；
# 桌面/headless 行为不变为回归红线。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const PLAYER_HOME := Vector2(360.0, 900.0)
const OVERFLOW_BUDGET_TEST_MS := 8.0        # 刀4 mobile 档（覆写注入）
const OVERFLOW_FRAME_TOL_MS := 7.0          # 感段逐帧容差（启动闸允许帧内<1.5ms 再起新卡故单帧可超预算；评审 8 跑实测超帽 1.2-4.5%，5ms 容差下 flaky→抬至 7ms）

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
	_test_1_face_reuse_and_dots()
	_test_2_fit_desc_cache()
	_test_3_reopen_measure_free()
	_test_4_hud_flush_throttle()
	_test_5_magnet_r26_and_mobile_gate()
	await _test_6_overflow_budget_frame()
	_test_7_popup_label_cap()
	await _test_8_levelup_probes()
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
	_gl.name = "R212GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.player.global_position = PLAYER_HOME
	# 全程不死保护（r188 P7 先例）：后续 _physics_process 驱动期场上真敌在打人
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.set("invuln_left", 9999.0)


func _teardown_game_loop() -> void:
	# 覆写口全部复位（防跨套件污染——约定 12）
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.stage_probe_enabled = false
		_gl.merged_overflow_budget_override_ms = -1.0
		_gl.hud.flush_throttle_override = -1
		_gl.popup_manager.label_refresh_cap_override = -1
		_gl.free()
		_gl = null


func _candidates(p_deal: int = 4) -> Array[Dictionary]:
	# 直发 4 张普通货架（真实 roll 链——generate_candidates 同 _open_card_flow 口径）
	return _gl.card_generator.generate_candidates({
		"player": _gl.player,
		"wave": 1,
		"level": _gl.player.level,
		"deal_count": p_deal,
		"curse_last": false,
		"min_rarity_floor": -1,
	})


func _distinct_candidates(p_deal: int = 4) -> Array[Dictionary]:
	# 「冷开零命中」断言前提=货架文案两两互异（fit_desc 缓存键=文案，同文案第二张
	# 必命中缓存——那是刀1 正确工作而非缺陷）。真实 roll 偶出同文案两手牌，
	# 重掷到互异为止；32 次上限护栏（概率上必中，防死循环兜底）。
	var cands := _candidates(p_deal)
	var guard := 0
	while guard < 32 and _has_dup_description(cands):
		cands = _candidates(p_deal)
		guard += 1
	return cands


func _has_dup_description(p_cands: Array[Dictionary]) -> bool:
	var seen := {}
	for c in p_cands:
		var d := String(c.get("description", ""))
		if seen.has(d):
			return true
		seen[d] = true
	return false


func _close_card_flow() -> void:
	# 选卡收口循环（pending 连弹同调用内重开——choose 真链逐批收口）
	var guard := 0
	while _gl.card_select_ui.is_open and guard < 64:
		_gl.card_select_ui.choose(0)
		guard += 1


# ── ① 卡面零重建复用 + dots 预建（刀1 附带微刀 + 装配模式锁现状） ──
func _test_1_face_reuse_and_dots() -> void:
	print("── ① 卡面复用 / dots 预建 ──")
	var ui: CardSelectUI = _gl.card_select_ui
	var cands := _candidates(4)
	var ids0: Array[int] = []
	for b in ui._buttons:
		ids0.append(b.get_instance_id())
	var root := ui._root
	var child0: int = root.get_child_count()
	var dot_ok_build := true
	var dot_ids0: Array[int] = []
	for f in ui._card_faces:
		var dots := f["dots"] as HBoxContainer
		if dots.get_child_count() != 4:
			dot_ok_build = false
		for c in dots.get_children():
			dot_ids0.append(c.get_instance_id())
	_check("dots 预建 4 珠（装配期一次，R212 刀1 附带）", dot_ok_build, "")
	ui.open(cands, false)
	var ids1: Array[int] = []
	for b in ui._buttons:
		ids1.append(b.get_instance_id())
	var child1: int = root.get_child_count()
	ui.open(cands, false)
	var ids2: Array[int] = []
	for b in ui._buttons:
		ids2.append(b.get_instance_id())
	var child2: int = root.get_child_count()
	_check("open×1 / open×2 后槽位 instance_id 不变（零重建锁现状）",
		ids0 == ids1 and ids1 == ids2, "")
	_check("CardSelectRoot 子节点数不变（无 AcceptDialog/面板重建）",
		child0 == child1 and child1 == child2, "%d→%d→%d" % [child0, child1, child2])
	# dots：显隐数量 == rarity+1（可见槽）；珠 instance_id 跨 open 恒等（显隐复用非重建）
	var dot_ok := true
	var vis_detail := ""
	for i in range(cands.size()):
		var dots := ui._card_faces[i]["dots"] as HBoxContainer
		var vis := 0
		for c in dots.get_children():
			if (c as TextureRect).visible:
				vis += 1
		var want: int = int(cands[i].get("rarity", 0)) + 1
		if vis != want:
			dot_ok = false
			vis_detail = "槽%d vis=%d want=%d" % [i, vis, want]
	_check("dots 显隐 == rarity+1（预建珠按稀有度显隐）", dot_ok, vis_detail)
	var dot_ids1: Array[int] = []
	for f in ui._card_faces:
		for c in (f["dots"] as HBoxContainer).get_children():
			dot_ids1.append(c.get_instance_id())
	_check("dots 珠 instance_id 跨 open×2 恒等（零 queue_free/零 new）",
		dot_ids0 == dot_ids1, "")


# ── ② _fit_desc 量测缓存（刀1 主验） ──
func _test_2_fit_desc_cache() -> void:
	print("── ② 量测缓存 ──")
	var ui: CardSelectUI = _gl.card_select_ui
	CardSelectUI._fit_desc_cache.clear()
	CardSelectUI.fit_desc_measures = 0
	CardSelectUI.fit_desc_cache_hits = 0
	var cands := _distinct_candidates(4)
	var t_cold0 := Time.get_ticks_usec()
	ui.open(cands, false)                    # 全新文案首开（冷）
	var cold_us := Time.get_ticks_usec() - t_cold0
	var m_cold: int = CardSelectUI.fit_desc_measures
	var h_cold: int = CardSelectUI.fit_desc_cache_hits
	_check("首次全新 open 量测 ≤30（4卡×7 上界）", m_cold <= 30,
		"measures=%d" % m_cold)
	_check("冷开零命中", h_cold == 0, "hits=%d" % h_cold)
	var fs0 := (ui._card_faces[0]["desc"] as Label).get_theme_font_size("font_size")
	var size0: Vector2 = (ui._card_faces[0]["desc"] as Label).size
	ui.close()
	var m_mid: int = CardSelectUI.fit_desc_measures
	var t_warm0 := Time.get_ticks_usec()
	ui.open(cands, false)                    # 同文案重开（热）
	var warm_us := Time.get_ticks_usec() - t_warm0
	var m_warm: int = CardSelectUI.fit_desc_measures - m_mid
	var h_warm: int = CardSelectUI.fit_desc_cache_hits - h_cold   # 只数热开增量（计数器累计制）
	_check("同文案 close→再 open 新增量测 ==0（缓存全命中）", m_warm == 0,
		"delta_measures=%d" % m_warm)
	_check("同文案重开命中数 == 货架卡数", h_warm == cands.size(),
		"hits=%d cards=%d" % [h_warm, cands.size()])
	var fs1 := (ui._card_faces[0]["desc"] as Label).get_theme_font_size("font_size")
	var size1: Vector2 = (ui._card_faces[0]["desc"] as Label).size
	_check("缓存命中布局逐位一致（fs/desc.size 与冷开相同）",
		fs0 == fs1 and size0 == size1, "fs %d→%d size %s→%s" % [fs0, fs1, str(size0), str(size1)])
	print("[perf-probe] 冷开 %d µs / 热开 %d µs（headless 无 Android 回退链，毫秒仅参考——以量测数为准）"
		% [cold_us, warm_us])
	ui.close()


# ── ③ 连升选卡期代理指标（真链 gain_xp → LEVEL_UP → open） ──
func _test_3_reopen_measure_free() -> void:
	print("── ③ 连升选卡期 ──")
	CardSelectUI.fit_desc_measures = 0
	CardSelectUI.fit_desc_cache_hits = 0
	var lv0: int = _gl.player.level
	_gl.player.gain_xp(_gl.player.xp_need * 40.0)   # 连升多级（≥5 级量级，含乘区余量）
	_gl.call(&"_consume_deferred_level_open")       # R215 刀A：开窗延迟帧尾（驱动等价一帧）
	var burst: int = _gl.player.level_burst_last
	var m_open: int = CardSelectUI.fit_desc_measures
	_check("巨幅连升触发选卡流（state==LEVEL_UP、货架开）",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open,
		"state=%d open=%s" % [_gl.state, str(_gl.card_select_ui.is_open)])
	_check("连升多级触发帧 _fit_desc 量测 ≤30（缓存只降不升）",
		burst >= 5 and m_open <= 30 and _gl.player.level > lv0,
		"burst=%d measures=%d" % [burst, m_open])
	# 选卡期内同货架重开（pending 批文案复看——缓存主受益形态）
	CardSelectUI.fit_desc_measures = 0
	_gl.card_select_ui.open(_gl.current_candidates, false)
	_check("选卡期内同货架重开新增量测 ==0", CardSelectUI.fit_desc_measures == 0,
		"measures=%d" % CardSelectUI.fit_desc_measures)
	_close_card_flow()
	_check("收口回 PLAYING（选卡流语义零变化）",
		_gl.state == GameConst.GameStatus.PLAYING and not _gl.card_select_ui.is_open,
		"state=%d" % _gl.state)


# ── ④ 选卡期 HUD 刷新节流（刀2，覆写口验收 mobile 行为） ──
func _test_4_hud_flush_throttle() -> void:
	print("── ④ HUD 节流 ──")
	var hud: HUD = _gl.hud
	var state_prev: int = hud._state_cur
	# 节流态：LEVEL_UP + 强制节流（=mobile 选卡期口径）→ xp_gained 风暴 60 帧
	hud._state_cur = GameConst.GameStatus.LEVEL_UP
	hud.flush_throttle_override = 1
	hud._flush_gate_left = 0.0
	var base: int = hud.refresh_stats_calls
	for i in range(60):
		EventBus.xp_gained.emit(1.0)        # 风暴：每帧置脏（R26 磁吸吸收同源）
		EventBus.xp_gained.emit(1.0)
		hud.tick(DT)
	var throttled: int = hud.refresh_stats_calls - base
	_check("LEVEL_UP 态 xp 风暴 1s 窗全量刷新 ≤5（0.25s 档 + 1Hz 兜底）",
		throttled <= 5, "calls=%d" % throttled)
	_check("节流仍活着（≥3 次刷新，非饿死）", throttled >= 3, "calls=%d" % throttled)
	# 对照态：强制不节流（=桌面口径）→ 同风暴每帧 flush
	hud.flush_throttle_override = 0
	hud._flush_gate_left = 0.0
	var base2: int = hud.refresh_stats_calls
	for i in range(30):
		EventBus.xp_gained.emit(1.0)
		hud.tick(DT)
	var unthrottled: int = hud.refresh_stats_calls - base2
	_check("不节流对照：30 帧风暴 ≥30 次刷新（每帧 flush 原样——节流是唯一变量）",
		unthrottled >= 30, "calls=%d" % unthrottled)
	# 读口旁路：displayed_* 直读即最新（读取即 flush，不经节流门）
	hud._state_cur = GameConst.GameStatus.PLAYING
	hud._stats_dirty = true
	var _peek := hud.displayed_level_text()
	_check("displayed_* 读口不经节流门（脏即读即刷）", not hud._stats_dirty, "")
	hud.flush_throttle_override = -1
	hud._state_cur = state_prev


# ── ⑤ R26 磁吸语义不回归 + 刀3 mobile 门源级锚 ──
func _test_5_magnet_r26_and_mobile_gate() -> void:
	print("── ⑤ 磁吸 R26 / 刀3 门 ──")
	var xp_pool := _gl.pools[&"xp"] as XPPool
	var shard := xp_pool.acquire() as XpShard
	shard.global_position = _gl.player.global_position + Vector2(0.0, -8.0)
	shard.activate(5.0, 0.0)
	_gl.active_shards.append(shard)
	_check("碎片入场非磁吸态（前置）", not shard.is_magnet(), "")
	_gl.player.gain_xp(_gl.player.xp_need * 2.0)   # 连升 → LEVEL_UP → 全场 force_magnet
	_gl.call(&"_consume_deferred_level_open")       # R215 刀A：开窗延迟帧尾（驱动等价一帧）
	_check("进 LEVEL_UP 全场碎片 force_magnet（R18/R26 原语义）",
		_gl.state == GameConst.GameStatus.LEVEL_UP and shard.is_magnet(),
		"state=%d magnet=%s" % [_gl.state, str(shard.is_magnet())])
	var xp0: float = _gl.player.xp
	var lv0: int = _gl.player.level
	_gl._physics_process(DT)                        # 桌面分支：磁吸碎片每帧驱动原样
	_check("选卡期磁吸碎片照常吸收（active_shards 清空 + xp 入账——R26 零回归）",
		_gl.active_shards.is_empty()
			and (_gl.player.xp > xp0 or _gl.player.level > lv0),
		"shards=%d xp %f→%f lv %d→%d" % [_gl.active_shards.size(), xp0,
			_gl.player.xp, lv0, _gl.player.level])
	_close_card_flow()
	_check("收口回 PLAYING", _gl.state == GameConst.GameStatus.PLAYING, "state=%d" % _gl.state)
	# 刀3 mobile 门源级锚（r207 先例）：隔帧 2δ 结构 + 相位计数器在位
	var src := FileAccess.get_file_as_string("res://scripts/loop/game_loop.gd")
	_check("刀3 mobile 门：磁吸隔帧 2δ 驱动源级锚",
		src.contains("_tick_magnetized_shards(p_raw_delta * 2.0)"), "缺半频驱动行")
	_check("刀3 相位计数器在位（_shard_subtick_left）", src.contains("_shard_subtick_left"),
		"缺相位计数器")


# ── ⑥ 溢出消化预算 + 逐帧感段帽（刀4） ──
func _test_6_overflow_budget_frame() -> void:
	print("── ⑥ 溢出消化分帧 ──")
	# 预算真源：桌面自动 35ms 原口径 / 覆写 mobile 档 8ms
	_check("预算真源：headless（桌面口径）自动 =35ms（R189 原值不回归）",
		is_equal_approx(_gl._merged_overflow_budget_ms(), 35.0),
		"budget=%f" % _gl._merged_overflow_budget_ms())
	_gl.merged_overflow_budget_override_ms = OVERFLOW_BUDGET_TEST_MS
	_check("预算覆写口生效（=8ms mobile 档）",
		is_equal_approx(_gl._merged_overflow_budget_ms(), OVERFLOW_BUDGET_TEST_MS),
		"budget=%f" % _gl._merged_overflow_budget_ms())
	_gl.stage_probe_enabled = true
	var lv0: int = _gl.player.level
	_gl.player.gain_xp(1.0e6)                       # ~百余级连升 → 排队 3 + 溢出批
	_gl.call(&"_consume_deferred_level_open")       # R215 刀A：开窗延迟帧尾（驱动等价一帧）
	var burst: int = _gl.player.level_burst_last
	_close_card_flow()                              # 真实弹窗批逐张收口 → 溢出批挂起
	var merged0: int = _gl.merged_overflow_level_ups
	_check("巨幅连升溢出批挂起分帧消化（PENDING 帽外全入批）",
		burst >= 50 and merged0 > 10,
		"burst=%d lv %d→%d merged=%d" % [burst, lv0, _gl.player.level, merged0])
	_check("溢出批挂起态（draining 置位，收口帧不抽卡——R189 口径）",
		_gl._merged_overflow_draining, "")
	var max_feel_us := 0
	var frames := 0
	while _gl.merged_overflow_level_ups > 0 and frames < 9000:
		_gl._physics_process(DT)
		var feel_us := int(_gl.stage_probe_us.get(&"feel", 0))
		if feel_us > max_feel_us:
			max_feel_us = feel_us
		frames += 1
	print("[perf-probe] 溢出批 %d 张 / %d 帧消化 / 感段峰值 %.2f ms（预算 %.0f ms + 容差 %.0f ms）"
		% [merged0, frames, float(max_feel_us) / 1000.0, OVERFLOW_BUDGET_TEST_MS,
			OVERFLOW_FRAME_TOL_MS])
	var cap_us := int((OVERFLOW_BUDGET_TEST_MS + OVERFLOW_FRAME_TOL_MS) * 1000.0)
	_check("消化期逐帧感段 ≤ 预算+容差（%d+%dms）"
		% [int(OVERFLOW_BUDGET_TEST_MS), int(OVERFLOW_FRAME_TOL_MS)],
		max_feel_us <= cap_us, "peak=%dµs cap=%dµs" % [max_feel_us, cap_us])
	_check("消化确分帧（≥5 帧，非同帧收口）", frames >= 5, "frames=%d" % frames)
	_check("批清零端点：merged==0 + draining 复位 + 回 PLAYING（end_persist_defer 单点结清）",
		_gl.merged_overflow_level_ups == 0 and not _gl._merged_overflow_draining
			and _gl.state == GameConst.GameStatus.PLAYING,
		"merged=%d draining=%s state=%d" % [_gl.merged_overflow_level_ups,
			str(_gl._merged_overflow_draining), _gl.state])
	_gl.merged_overflow_budget_override_ms = -1.0
	_gl.stage_probe_enabled = false


# ── ⑦ 脏跳字排版每帧限批（刀5，覆写口验收 mobile 行为） ──
func _test_7_popup_label_cap() -> void:
	print("── ⑦ 跳字限批 ──")
	var pm: PopupManager = _gl.popup_manager
	pm.label_refresh_cap_override = 6
	var popups: Array[DamagePopup] = []
	for i in range(40):
		var r := DamageResult.new()
		r.final_value = 10.0
		r.target_uid = 27000 + i
		r.pos = Vector2(360.0, 400.0)
		r.popup_style = GameConst.PopupStyle.NORMAL
		pm.on_damage_resolved(r)
	for i in range(40):                             # 同 uid 二次结算 → merge 只置脏
		var r := DamageResult.new()
		r.final_value = 5.0
		r.target_uid = 27000 + i
		r.pos = Vector2(360.0, 400.0)
		r.popup_style = GameConst.PopupStyle.NORMAL
		pm.on_damage_resolved(r)
	for p in pm._active_list:
		popups.append(p)
	_check("40 张活跃弹字全部置脏（merge 只置脏前置）",
		popups.size() == 40 and _dirty_count(pm) == 40,
		"active=%d dirty=%d" % [popups.size(), _dirty_count(pm)])
	DamagePopup.refresh_label_calls = 0
	pm.tick(DT)                                     # 下一驱动帧：限批 ≤6
	var batch1: int = DamagePopup.refresh_label_calls
	_check("下一帧排版刷新恰 ≤6（限批生效）", batch1 > 0 and batch1 <= 6,
		"batch=%d" % batch1)
	var frames := 1
	while _dirty_count(pm) > 0 and frames < 12:     # 余下帧续（轮转收敛）
		pm.tick(DT)
		frames += 1
	_check("40 张脏弹字 ≤7 帧内全部完成刷新（ceil(40/6)=7）",
		_dirty_count(pm) == 0 and frames <= 7,
		"frames=%d dirty=%d" % [frames, _dirty_count(pm)])
	var all15 := true
	for p in popups:
		if is_instance_valid(p) and String((p.get_node("Value") as Label).text) != "15":
			all15 = false
	_check("最终显示值与逐帧刷新逐位一致（全部 10+5=15）", all15, "")
	# 对照：不限批（桌面口径）→ 一帧全量刷新
	pm.label_refresh_cap_override = 0
	for i in range(40):
		var r := DamageResult.new()
		r.final_value = 5.0
		r.target_uid = 27000 + i
		r.pos = Vector2(360.0, 400.0)
		r.popup_style = GameConst.PopupStyle.NORMAL
		pm.on_damage_resolved(r)
	DamagePopup.refresh_label_calls = 0
	pm.tick(DT)
	_check("不限批对照：一帧 40 张全量刷新（桌面行为不变）",
		DamagePopup.refresh_label_calls == 40,
		"calls=%d" % DamagePopup.refresh_label_calls)
	pm.clear_all()
	pm.label_refresh_cap_override = -1


func _dirty_count(p_pm: PopupManager) -> int:
	var n := 0
	for p in p_pm._active_list:
		if p._label_dirty:
			n += 1
	return n


# ── ⑧ LEVEL_UP/PAUSED 探针补洞（刀6） ──
func _test_8_levelup_probes() -> void:
	print("── ⑧ 选卡期探针 ──")
	_gl.stage_probe_enabled = true
	_gl.diag_reset_stage_peaks()                    # 峰值通道清零（本用例独立口径）
	# PAUSED 分支
	_gl.request_pause()
	_gl._physics_process(DT)
	var paused_keys: bool = _gl.stage_probe_us.has(&"feel") and _gl.stage_probe_us.has(&"ui")
	_check("PAUSED 帧探针在位（feel/ui 两键，照 PLAYING 口径）", paused_keys,
		"keys=%s" % str(_gl.stage_probe_us.keys()))
	_check("PAUSED peak 通道同步记录", _gl.stage_probe_us_peak.has(&"feel")
		and _gl.stage_probe_us_peak.has(&"ui"), "peak=%s" % str(_gl.stage_probe_us_peak.keys()))
	_gl.request_resume()
	# LEVEL_UP 分支（选卡期探针主战场——原盲区）
	_gl.player.gain_xp(_gl.player.xp_need * 2.0)
	_gl.call(&"_consume_deferred_level_open")       # R215 刀A：开窗延迟帧尾（驱动等价一帧）
	_check("进 LEVEL_UP（选卡期探针主战场）",
		_gl.state == GameConst.GameStatus.LEVEL_UP, "state=%d" % _gl.state)
	for i in range(3):
		_gl._physics_process(DT)
	var lu_keys: bool = _gl.stage_probe_us.has(&"feel") and _gl.stage_probe_us.has(&"ui")
	_check("LEVEL_UP 帧探针在位（feel/ui——选卡期尖峰盲区补洞）", lu_keys,
		"keys=%s" % str(_gl.stage_probe_us.keys()))
	_check("LEVEL_UP peak ≥ 本帧采样值（max 通道口径，随帧更新）",
		int(_gl.stage_probe_us_peak.get(&"feel", 0)) >= int(_gl.stage_probe_us.get(&"feel", 0))
			and int(_gl.stage_probe_us_peak.get(&"ui", 0)) >= int(_gl.stage_probe_us.get(&"ui", 0)),
		"feel peak=%d cur=%d / ui peak=%d cur=%d" % [int(_gl.stage_probe_us_peak.get(&"feel", 0)),
			int(_gl.stage_probe_us.get(&"feel", 0)), int(_gl.stage_probe_us_peak.get(&"ui", 0)),
			int(_gl.stage_probe_us.get(&"ui", 0))])
	_close_card_flow()
	_gl.stage_probe_enabled = false
	_gl.diag_reset_stage_peaks()

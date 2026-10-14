# tests/runner/r220_cardprewarm_cases.gd
# R220 用例体：卡窗预热包（R219 方案书刀2 / R220 契约 §1-D/§5.4）。
# ① 变体全清单入缓存（4 稀有度数值重写 / MASTERY 等级文案 / 双列 ⇄ / value_scale>1
#    尾行各档 × 宽档 × 紧凑/普通 × 行距——逐项清点，漏拼任一即部分稀有度全 miss）；
# ② 开窗增量：预热后构造组合开窗 fit_desc_measures 增量 ≤2；Reroll 与挂机连开同口径；
# ③ 排版逐位不变：同键同值（预热前现算 vs 预热后命中 {fs,need} 逐位相等）；
# ④ 预热分帧预算（12ms/帧驱动节奏——预算用尽即停 + 单帧墙钟容忍单项粒度）；
# ⑤ 菜单期驱动（MENU 态帧推进消化 / 离开菜单暂停不偷跑战斗期帧预算）；
# ⑥ DebugStats.fit_desc_measures 计数同步（量测本体计数，预热期量测也计）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const PLAYER_HOME := Vector2(360.0, 900.0)
const BUDGET_US := 12000                      # 12ms/帧（R215 菜单期分帧口径）
const FRAME_TOL_US := 24000                   # 单帧墙钟容忍（12ms 预算 + 单项梯量测原子粒度超调）
const Prewarm := preload("res://scripts/cards/card_desc_prewarm.gd")

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
	await _test_1_menu_drive_gate()
	_test_2_variant_coverage()
	_test_3_frame_budget()
	_test_4_layout_bitwise()
	_test_5_open_window_measures()
	_test_6_real_flow_reroll()
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
	# 同步 boot（main.tscn _ready 全同步——BOOT→MENU 完成后 menu_screen 已在树且可见，
	# 其 _process 最早在下一渲染帧泵——此刻夺回控制权 reset 预热器，测试全程手动可控）
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R220CardPrewarmUnderTest"
	tree.get_root().add_child(_gl)
	Prewarm.reset_for_tests()
	CardSelectUI._fit_desc_cache.clear()
	CardSelectUI.fit_desc_measures = 0
	CardSelectUI.fit_desc_cache_hits = 0
	# 全程不死保护（r212 先例）：_test_1 离开菜单后 PLAYING 期真敌在打人
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.set("invuln_left", 9999.0)


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null
	Prewarm.reset_for_tests()


# ── ① D3：菜单期驱动 / 离开菜单暂停 ───────────────────────────────
func _test_1_menu_drive_gate() -> void:
	print("── ① 菜单期驱动门（D3）──")
	_check("boot 完成 MENU 态 + 菜单可见", _gl.state == GameConst.GameStatus.MENU
		and _gl.menu_screen.is_menu_visible(), "state=%d" % _gl.state)
	var dbg0: int = DebugStats.get_counter(&"fit_desc_measures")
	await tree.process_frame
	await tree.process_frame
	await tree.process_frame
	# menu_screen._process 在 MENU 态自动建队 + 12ms/帧泵（D3 驱动链）
	_check("MENU 帧推进自动建队（ensure_built 幂等挂载）", Prewarm.total_built() > 0,
		"total=%d" % Prewarm.total_built())
	_check("MENU 帧推进消化进度 >0", Prewarm.remaining() < Prewarm.total_built(),
		"remaining=%d total=%d" % [Prewarm.remaining(), Prewarm.total_built()])
	_check("预热期量测计入 DebugStats.fit_desc_measures（量测本体计数）",
		DebugStats.get_counter(&"fit_desc_measures") - dbg0 > 0,
		"delta=%d" % (DebugStats.get_counter(&"fit_desc_measures") - dbg0))
	# 离开菜单：R256 序1 契约翻案——PLAYING 态续泵（战斗帧 2ms/帧消化余量，
	# 每局首次升级开卡顿挫根治）；旧契约「PLAYING 不泵」随刀废止
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_check("start_run → PLAYING", _gl.state == GameConst.GameStatus.PLAYING,
		"state=%d" % _gl.state)
	var r0: int = Prewarm.remaining()
	await tree.process_frame
	await tree.process_frame
	await tree.process_frame
	_check("战斗续泵（R256 序1：PLAYING 帧推进 remaining 递减）",
		Prewarm.remaining() < r0, "%d → %d" % [r0, Prewarm.remaining()])
	# 泵门=PLAYING 态单门：PAUSED 不泵（暂停帧预算不偷跑——序1 边界侧证）
	if _gl.change_state(GameConst.GameStatus.PAUSED):
		var r1: int = Prewarm.remaining()
		await tree.process_frame
		await tree.process_frame
		_check("PAUSED 不泵（暂停帧推进 remaining 不变）",
			Prewarm.remaining() == r1, "%d → %d" % [r1, Prewarm.remaining()])
		_gl.change_state(GameConst.GameStatus.PLAYING)


# ── ② 变体全清单清点 + 全量泵 + 抽测全命中 ────────────────────────
func _variants() -> Array[Dictionary]:
	# 独立变体源（enumerate_prewarm_variants 零 rng——可重复调用对照）
	var gen := CardGenerator.new()
	gen.setup(_gl.registry)
	return gen.enumerate_prewarm_variants([])


func _drain_all(p_budget_us: int) -> Array:
	# 同步泵到清队，返回 [frames, max_frame_us]
	var frames := 0
	var max_us := 0
	while Prewarm.remaining() > 0 and frames < 200000:
		var t0 := Time.get_ticks_usec()
		Prewarm.pump(p_budget_us)
		max_us = maxi(max_us, int(Time.get_ticks_usec() - t0))
		frames += 1
	return [frames, max_us]


func _test_2_variant_coverage() -> void:
	print("── ② 变体全清单入缓存 ──")
	Prewarm.reset_for_tests()
	CardSelectUI._fit_desc_cache.clear()
	CardSelectUI.fit_desc_measures = 0
	CardSelectUI.fit_desc_cache_hits = 0
	Prewarm.ensure_built(_gl.registry)
	var total: int = Prewarm.total_built()
	_check("建队 >0（变体×宽档×紧凑×⇄×行距展开）", total > 0, "total=%d" % total)
	var variants: Array[Dictionary] = _variants()
	print("      [info] 变体文本 %d 种 × 2 宽档 = 预热键 %d" % [variants.size(), total])
	# ① _scaled_description ×4 稀有度数值重写（value_scale 四档全集在变体域）
	var vs_seen := {}
	for v in variants:
		vs_seen["%.1f" % float(v["value_scale"])] = true
	_check("① 4 稀有度数值重写全在变体（value_scale ×1.0/×1.4/×1.9/×2.6）",
		vs_seen.has("1.0") and vs_seen.has("1.4") and vs_seen.has("1.9") and vs_seen.has("2.6"),
		str(vs_seen.keys()))
	# ② MASTERY 等级文案（等级域生成——任意 ±3 近窗超集（R245 boosts 最高 +3，相邻两窗
	#    武器等级最大跳变 3）；三档分化后描述六态全在）
	var txts := {}
	for v in variants:
		txts[String(v["desc"])] = true
	_check("② MASTERY 文案全六态在变体（+1 / +2稀有连升 / +1稀有连升已触顶 / +2史诗连升×3已触顶 / +1史诗连升×3已触顶 / 已满级）",
		txts.has("武器等级 +1（终值表口径）")
			and txts.has("武器等级 +2（稀有品质连升 ×2）（终值表口径）")
			and txts.has("武器等级 +1（稀有品质连升 ×2，已触顶）（终值表口径）")
			and txts.has("武器等级 +2（史诗品质连升 ×3，已触顶）（终值表口径）")
			and txts.has("武器等级 +1（史诗品质连升 ×3，已触顶）（终值表口径）")
			and txts.has("已满级（终值表口径）"),
		"")
	# R226 有意契约变更：超帽注记退役——预热变体只余 milestone 尾注态（变体键空间收窄）
	_check("②b TRAIT 满层质变尾注变体在列、超帽注记退役（R226）",
		_has_desc_contains(variants, "满层质变") and not _has_desc_contains(variants, "收益降低 30%"),
		"")
	# ③④ ⇄ 行 / value_scale>1 尾行各档——队列键文本逐项清点
	var q: Array = Prewarm._queue
	var n_arrow := 0
	var n_plain := 0
	var tail_seen := {}
	var cw_seen := {}
	var compact_of_cw := {}
	var ls_values := {}
	for job in q:
		var t := String(job["text"])
		if t.contains("⇄ 点这张会同时带走同一行另一张"):
			n_arrow += 1
		else:
			n_plain += 1
		var m := t.find("品质加成：该词条效果 ×")
		if m >= 0:
			tail_seen[t.substr(m + "品质加成：该词条效果 ×".length(), 3)] = true
		var cw := "%.0f" % float(job["cw"])
		cw_seen[cw] = true
		compact_of_cw[cw] = bool(job["compact"])
		ls_values["%.1f" % float(job["ls"])] = true
	_check("③ 双列 ⇄ 行入预热键（对半结构：每变体普通+双列各一键）",
		n_arrow > 0 and n_arrow == n_plain, "arrow=%d plain=%d" % [n_arrow, n_plain])
	_check("④ value_scale>1 尾行各档入键（×1.4/×1.9/×2.6）",
		tail_seen.has("1.4") and tail_seen.has("1.9") and tail_seen.has("2.6"),
		str(tail_seen.keys()))
	_check("⑤ 宽档=普通600/非紧凑 + 双列324/紧凑（开窗仅有的两个有效组合）",
		cw_seen.has("600") and cw_seen.has("324") and cw_seen.size() == 2
			and compact_of_cw["600"] == false and compact_of_cw["324"] == true,
		str(cw_seen.keys()))
	_check("⑤b 行距单值同源（全队列同 line_spacing 且 >0）",
		ls_values.size() == 1 and not ls_values.has("0.0"), str(ls_values.keys()))
	# 全量泵 + DebugStats 计数同步（D1：预热期量测也计）
	var dc0: int = DebugStats.get_counter(&"fit_desc_measures")
	var m0: int = CardSelectUI.fit_desc_measures
	var drained: Array = _drain_all(BUDGET_US)
	_check("全量泵清队（分帧 %d 帧，最重帧 %dus）" % [int(drained[0]), int(drained[1])],
		Prewarm.remaining() == 0, "remaining=%d" % Prewarm.remaining())
	var measures_delta: int = CardSelectUI.fit_desc_measures - m0
	_check("预热期量测本体计数 >0（每键入缓存经真实量测）", measures_delta > 0,
		"delta=%d" % measures_delta)
	_check("⑥ DebugStats.fit_desc_measures 与静态观测口同步（每量测 +1）",
		DebugStats.get_counter(&"fit_desc_measures") - dc0 == measures_delta,
		"dbg=%d static=%d" % [DebugStats.get_counter(&"fit_desc_measures") - dc0, measures_delta])
	# 抽测全命中：每稀有度一变体 + MASTERY 六态（R245 三档分化）+ 尾注态 × 普通/双列两档
	var ls := CardSelectUI.prewarm_line_spacing()
	var samples: Array = []
	var picked_vs := {}
	for v in variants:
		var vs := float(v["value_scale"])
		var key := "%.1f" % vs
		if not picked_vs.has(key):
			picked_vs[key] = true
			samples.append({"text": CardSelectUI.compose_desc_text(String(v["desc"]), vs, false),
				"cw": 600.0, "compact": false, "ls": ls})
			samples.append({"text": CardSelectUI.compose_desc_text(String(v["desc"]), vs, true),
				"cw": 324.0, "compact": true, "ls": ls})
	for mastery_txt in ["武器等级 +1（终值表口径）",
			"武器等级 +2（稀有品质连升 ×2）（终值表口径）",
			"武器等级 +1（稀有品质连升 ×2，已触顶）（终值表口径）",
			"武器等级 +2（史诗品质连升 ×3，已触顶）（终值表口径）",
			"武器等级 +1（史诗品质连升 ×3，已触顶）（终值表口径）", "已满级（终值表口径）"]:
		samples.append({"text": mastery_txt, "cw": 600.0, "compact": false, "ls": ls})
		samples.append({"text": CardSelectUI.compose_desc_text(mastery_txt, 1.0, true),
			"cw": 324.0, "compact": true, "ls": ls})
	var m1: int = CardSelectUI.fit_desc_measures
	var h1: int = CardSelectUI.fit_desc_cache_hits
	for s in samples:
		CardSelectUI._fit_desc(String(s["text"]), float(s["cw"]), bool(s["compact"]),
			float(s["ls"]))
	_check("抽测变体全命中（4 稀有度+MASTERY+⇄+尾行 × 两宽档：量测零增量）",
		CardSelectUI.fit_desc_measures == m1,
		"delta=%d" % (CardSelectUI.fit_desc_measures - m1))
	_check("抽测命中计数 == 样本数（%d）" % samples.size(),
		CardSelectUI.fit_desc_cache_hits - h1 == samples.size(),
		"hits=%d" % (CardSelectUI.fit_desc_cache_hits - h1))


func _has_desc_contains(p_variants: Array[Dictionary], p_sub: String) -> bool:
	for v in p_variants:
		if String(v["desc"]).contains(p_sub):
			return true
	return false


# ── ③ 分帧预算（12ms/帧驱动节奏） ──────────────────────────────────
func _test_3_frame_budget() -> void:
	print("── ③ 分帧预算节奏 ──")
	# 预算语义铁证：预算 0 的泵恰处理 1 项（处理完检查 t−t0 ≥ 0 立即停——不饿死即停）
	Prewarm.reset_for_tests()
	CardSelectUI._fit_desc_cache.clear()
	Prewarm.ensure_built(_gl.registry)
	var d0: int = Prewarm.pump(0)
	_check("pump(0) 恰处理 1 项（预算用尽即停、最小粒度不饿死）", d0 == 1, "done=%d" % d0)
	var d1: int = Prewarm.pump(0)
	_check("pump(0) 二连仍恰 1 项（每帧独立计时）", d1 == 1, "done=%d" % d1)
	# 名义预算分帧节奏：重泵全量，多帧消化 + 单帧墙钟 ≤ 预算+单项粒度
	Prewarm.reset_for_tests()
	CardSelectUI._fit_desc_cache.clear()
	Prewarm.ensure_built(_gl.registry)
	var drained: Array = _drain_all(BUDGET_US)
	var frames: int = int(drained[0])
	var max_us: int = int(drained[1])
	_check("12ms 名义预算分帧消化跨 ≥2 帧（节奏断言）", frames >= 2, "frames=%d" % frames)
	_check("单帧墙钟 ≤24ms（12ms 预算 + 单项梯量测原子粒度容忍）",
		max_us <= FRAME_TOL_US, "max=%dus / %d 帧" % [max_us, frames])
	print("      [info] 全量 %d 键分帧 %d 帧，最重帧 %dus（预算 %dus）"
		% [Prewarm.total_built(), frames, max_us, BUDGET_US])


# ── ④ 排版逐位不变（同键同值） ─────────────────────────────────────
func _test_4_layout_bitwise() -> void:
	print("── ④ 排版逐位一致 ──")
	var variants: Array[Dictionary] = _variants()
	var ls := CardSelectUI.prewarm_line_spacing()
	# 样本：3 个变体 × 两档（含 MASTERY/尾行类文本优先）
	var picks: Array[Dictionary] = []
	for v in variants:
		if picks.size() >= 3:
			break
		picks.append(v)
	var xs: Array = []
	for p in picks:
		var desc := String(p["desc"])
		var vs := float(p["value_scale"])
		xs.append({"text": CardSelectUI.compose_desc_text(desc, vs, false),
			"cw": 600.0, "compact": false, "ls": ls})
		xs.append({"text": CardSelectUI.compose_desc_text(desc, vs, true),
			"cw": 324.0, "compact": true, "ls": ls})
	# A：清缓存现算（miss → 真实梯量测）
	Prewarm.reset_for_tests()
	CardSelectUI._fit_desc_cache.clear()
	var r1: Array = []
	for x in xs:
		r1.append(CardSelectUI._fit_desc(String(x["text"]), float(x["cw"]),
			bool(x["compact"]), float(x["ls"])))
	# B：清缓存 → 预热全量入缓存 → 命中路径读
	CardSelectUI._fit_desc_cache.clear()
	Prewarm.ensure_built(_gl.registry)
	_drain_all(100000000)                      # 大预算快进（同步清队）
	var m0: int = CardSelectUI.fit_desc_measures
	var r2: Array = []
	for x in xs:
		r2.append(CardSelectUI._fit_desc(String(x["text"]), float(x["cw"]),
			bool(x["compact"]), float(x["ls"])))
	_check("B 路径全命中（预热后同键零量测）", CardSelectUI.fit_desc_measures == m0,
		"delta=%d" % (CardSelectUI.fit_desc_measures - m0))
	_check("预热前后 {fs,need} 逐位一致（同键同值——预热只提前不改变结果）",
		r1.size() == r2.size() and _fits_equal(r1, r2), "")


func _fits_equal(p_a: Array, p_b: Array) -> bool:
	for i in range(p_a.size()):
		var a: Dictionary = p_a[i]
		var b: Dictionary = p_b[i]
		if int(a["fs"]) != int(b["fs"]) or absf(float(a["need"]) - float(b["need"])) > 0.0001:
			return false
	return true


# ── ⑤ 开窗增量 ≤2（组合构造 + dual ⇄） ────────────────────────────
func _test_5_open_window_measures() -> void:
	print("── ⑤ 开窗量测增量（≤2）──")
	# 前置：全量预热完成态（_test_4 已清队）
	var variants: Array[Dictionary] = _variants()
	var by_vs := {}
	for v in variants:
		var key := "%.1f" % float(v["value_scale"])
		if not by_vs.has(key):
			by_vs[key] = String(v["desc"])
	var cands: Array[Dictionary] = []
	var scales := [1.0, 1.4, 1.9, 2.6]
	for r in range(4):
		var vs: float = scales[r]
		cands.append({"kind": CardGenerator.CardKind.TRAIT, "id": &"R220PROBE",
			"rarity": r, "data": null, "display_name": "稀有度探针%d" % r,
			"description": String(by_vs["%.1f" % vs]), "value_scale": vs, "milestone": false})
	cands.append({"kind": CardGenerator.CardKind.MASTERY, "id": &"R220PROBE_M",
		"rarity": 2, "data": null, "display_name": "精通探针",
		"description": "武器等级 +2（史诗品质连升 ×3，已触顶）（终值表口径）"})
	var ui: CardSelectUI = _gl.card_select_ui
	CardSelectUI.fit_desc_measures = 0
	ui.open(cands, false)
	_check("预热后普通开窗（4 稀有度+尾行+MASTERY）量测增量 ≤2",
		CardSelectUI.fit_desc_measures <= 2, "delta=%d" % CardSelectUI.fit_desc_measures)
	CardSelectUI.fit_desc_measures = 0
	ui.open(cands, true)
	_check("预热后双列开窗（⇄ 行）量测增量 ≤2",
		CardSelectUI.fit_desc_measures <= 2, "delta=%d" % CardSelectUI.fit_desc_measures)
	ui.close()


# ── ⑥ 真链开窗 / Reroll / 挂机连开同口径 ──────────────────────────
func _test_6_real_flow_reroll() -> void:
	print("── ⑥ 真链开窗 / Reroll / 挂机连开 ──")
	var m0: int = CardSelectUI.fit_desc_measures
	_gl.player.gain_xp(_gl.player.xp_need * 2.0)
	_gl.call(&"_consume_deferred_level_open")
	_check("真链开窗（LEVEL_UP + 货架开）",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open,
		"state=%d" % _gl.state)
	var dm_open: int = CardSelectUI.fit_desc_measures - m0
	_check("真链开窗量测增量 ≤2", dm_open <= 2, "delta=%d" % dm_open)
	# Reroll：重新发牌重开（首局免费位）
	var m1: int = CardSelectUI.fit_desc_measures
	_gl.call(&"_on_card_reroll")
	var dm_reroll: int = CardSelectUI.fit_desc_measures - m1
	_check("Reroll 重发同口径（量测增量 ≤2）", dm_reroll <= 2, "delta=%d" % dm_reroll)
	_close_card_flow()
	_check("选卡收口回 PLAYING",
		_gl.state == GameConst.GameStatus.PLAYING and not _gl.card_select_ui.is_open,
		"state=%d" % _gl.state)
	# 挂机连开（连升多级批——每窗 ≤2 口径）
	var m2: int = CardSelectUI.fit_desc_measures
	_gl.player.gain_xp(_gl.player.xp_need * 40.0)
	_gl.call(&"_consume_deferred_level_open")
	var burst: int = _gl.player.level_burst_last
	var dm_burst: int = CardSelectUI.fit_desc_measures - m2
	_check("挂机连开每窗 ≤2（总增量 ≤2×连升数）",
		burst >= 2 and dm_burst <= 2 * burst, "burst=%d delta=%d" % [burst, dm_burst])
	print("      [info] 连升 %d 级批内量测增量 %d（每窗均值 %.1f）"
		% [burst, dm_burst, float(dm_burst) / float(maxi(burst, 1))])
	_close_card_flow()


func _close_card_flow() -> void:
	# 选卡收口循环（r212 先例：pending 连弹同调用内重开——choose 真链逐批收口）
	var guard := 0
	while _gl.card_select_ui.is_open and guard < 64:
		_gl.card_select_ui.choose(0)
		guard += 1

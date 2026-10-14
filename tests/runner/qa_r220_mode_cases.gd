# tests/runner/qa_r220_mode_cases.gd
# QA 独立取证用例体（R220 模式地基包 A + 卡窗预热包 D——入口 test_qa_r220_mode.gd
# 运行时 load；-s 编译期禁引工程类名纪律同 r218_simbound_cases.gd）。
# 只取证不修产品码。五域：
#   域A 设置行链：两态循环 / 写即存持久 / 立即生效（frame_priority 每读直查 + 调速器
#        模式观测口清转换计时、tier 保持）/ 旧档（磁盘真档去键 + 内存缺键双口径）
#        无 perf_mode 键回落默认 0。
#   域B PerfGovernor 注入：降档迟滞（2.0s 门槛）/ 升档迟滞（5.0s）/ 特效优先地板 2 /
#        paused·LEVEL_UP 挂起续账 / target=min(fps_cap,120) 跟随设置（144 钳 120 的
#        判别用例 + 阈值随 target 缩放）/ tier_override 帽映射 3/2/1→2/1/0。
#   域C 刀2 变体全清单：4 稀有度 × MASTERY±3 近窗（R245 boosts 最高 +3，相邻两窗等级
#        最大跳变 3）× ⇄ × 尾行 × 宽 × 紧凑 × 行距
#        组合抽查全命中 + 开窗 fit_desc_measures 增量 ≤2 + Reroll/连升批同口径。
#   域D 分帧预算 ≤12ms/帧（单帧墙钟 ≤ 预算 + 单项梯量测原子粒度上界）。
#   域E 日志头 R220 新口径声明在位（十六段/模N带*/窗口错位/⑧段前派发 + 旧锁子串
#        「采样 1Hz × N 行环形」动态保持）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const EPS := 0.0001
const BUDGET_US := 12000                      # 12ms/帧（R215 菜单期分帧口径）
const TIMER_MARGIN_US := 1500                 # 计时器读数容差（泵循环开销）
const Prewarm := preload("res://scripts/cards/card_desc_prewarm.gd")

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _saved_settings: Dictionary = {}          # 入口快照（cleanup 还原——磁盘不留测试痕）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_saved_settings = Meta._settings.duplicate()
	_boot_game_loop()
	await tree.process_frame
	await _domain_c_prewarm()                 # 刀2（先跑：MENU 期观测需开局态）
	await _domain_a_settings_chain()         # 协程（内含 await process_frame）——必须 await
	_domain_b_governor_injection()
	_domain_d_frame_budget()
	_domain_e_diag_header()
	_cleanup()
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
	# 同步 boot（main.tscn _ready 全同步——BOOT→MENU；menu_screen 在树，其 _process
	# 自下一渲染帧起泵预热器——域C 首拍观测用）。全程不死保护（r212 先例）。
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	tree.get_root().add_child(_gl)
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.set("invuln_left", 9999.0)


# ═══ 域C 刀2 卡窗预热（先跑——MENU 期驱动观测需开局态） ═══
func _variants() -> Array[Dictionary]:
	var gen := CardGenerator.new()
	gen.setup(_gl.registry)
	return gen.enumerate_prewarm_variants([])


func _drain_all(p_budget_us: int) -> Array:
	var frames := 0
	while Prewarm.remaining() > 0 and frames < 200000:
		Prewarm.pump(p_budget_us)
		frames += 1
	return [frames]


func _close_card_flow() -> void:
	var guard := 0
	while _gl.card_select_ui.is_open and guard < 64:
		_gl.card_select_ui.choose(0)
		guard += 1


func _domain_c_prewarm() -> void:
	print("── 域C 刀2 变体全清单 + 开窗增量 ≤2 ──")
	# C0 菜单期自动驱动（D3 链：menu_screen._process 建队 + 12ms 泵）
	await tree.process_frame
	await tree.process_frame
	_check("C0 MENU 帧推进自动建队 + 消化进度>0（D3 驱动链在位）",
		Prewarm.total_built() > 0 and Prewarm.remaining() < Prewarm.total_built(),
		"total=%d remaining=%d" % [Prewarm.total_built(), Prewarm.remaining()])
	# C0b 战斗续泵（R256 序1 契约翻案——同 r220_cardprewarm ①：PLAYING 态 2ms/帧续泵，
	# 旧「零泵」契约随刀废止；红断言恰为泵生效反证）
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_check("C0b start_run → PLAYING", _gl.state == GameConst.GameStatus.PLAYING,
		"state=%d" % _gl.state)
	var r0: int = Prewarm.remaining()
	await tree.process_frame
	await tree.process_frame
	await tree.process_frame
	_check("C0b 战斗续泵（PLAYING 期 remaining 递减）", Prewarm.remaining() < r0,
		"%d → %d" % [r0, Prewarm.remaining()])

	# ── 全量重泵取干净基线（清缓存清队——后续命中断言的零点） ──
	Prewarm.reset_for_tests()
	CardSelectUI._fit_desc_cache.clear()
	CardSelectUI.fit_desc_measures = 0
	CardSelectUI.fit_desc_cache_hits = 0
	Prewarm.ensure_built(_gl.registry)
	var drained: Array = _drain_all(100000000)
	_check("C0c 全量泵清队（%d 键）" % Prewarm.total_built(),
		Prewarm.remaining() == 0 and Prewarm.total_built() > 0,
		"total=%d frames=%d" % [Prewarm.total_built(), int(drained[0])])

	# C1 队列构成清点：宽×紧凑×行距（开窗仅有的两个有效组合 + 行距单值同源）
	var q: Array = Prewarm._queue
	# 注：已清队——从 ensure_built 重建清点（不动缓存）
	Prewarm.reset_for_tests()
	var cache_keep: Dictionary = CardSelectUI._fit_desc_cache.duplicate()
	Prewarm.ensure_built(_gl.registry)
	var q2: Array = Prewarm._queue
	var cw_seen := {}
	var compact_of_cw := {}
	var ls_values := {}
	var n_arrow := 0
	var n_plain := 0
	for job in q2:
		var t := String(job["text"])
		if t.contains("⇄ 点这张会同时带走同一行另一张"):
			n_arrow += 1
		else:
			n_plain += 1
		var cw := "%.0f" % float(job["cw"])
		cw_seen[cw] = true
		compact_of_cw[cw] = bool(job["compact"])
		ls_values["%.1f" % float(job["ls"])] = true
	_check("C1 宽档两组合：600 非紧凑 + 324 紧凑（无第三组合）",
		cw_seen.has("600") and cw_seen.has("324") and cw_seen.size() == 2
			and compact_of_cw["600"] == false and compact_of_cw["324"] == true,
		str(cw_seen.keys()))
	_check("C1 行距单值同源且 >0（预热键行距维=开窗实拼键）",
		ls_values.size() == 1 and not ls_values.has("0.0")
			and absf(float(Prewarm._queue[0]["ls"]) - CardSelectUI.prewarm_line_spacing()) < EPS,
		str(ls_values.keys()))
	_check("C1 ⇄ 双列对半结构（每变体普通+双列各一键）", n_arrow > 0 and n_arrow == n_plain,
		"arrow=%d plain=%d" % [n_arrow, n_plain])
	Prewarm.reset_for_tests()
	CardSelectUI._fit_desc_cache = cache_keep

	# C2 4 稀有度 × ⇄ × 尾行 × 宽 × 紧凑 组合抽查全命中（量测零增量 + 命中计数=样本数）
	var variants: Array[Dictionary] = _variants()
	var scales: Array = CardGenerator.RARITY_VALUE_SCALE
	var picked := {}                          # rarity index → 首个该稀有度变体
	for v in variants:
		var vs := float(v["value_scale"])
		for r in range(scales.size()):
			if absf(vs - float(scales[r])) < EPS and not picked.has(r):
				picked[r] = v
	_check("C2 4 稀有度数值重写变体各就位（×1.0/×1.4/×1.9/×2.6）",
		picked.size() == scales.size(), "picked=%d" % picked.size())
	var ls := CardSelectUI.prewarm_line_spacing()
	var m0: int = CardSelectUI.fit_desc_measures
	var h0: int = CardSelectUI.fit_desc_cache_hits
	var samples: Array = []
	for r in range(scales.size()):
		var v: Dictionary = picked[r]
		var desc := String(v["desc"])
		var vs2 := float(v["value_scale"])
		for dual in [false, true]:
			var text := CardSelectUI.compose_desc_text(desc, vs2, dual)
			var cw := 324.0 if dual else CardSelectUI.CARD_SIZE.x
			CardSelectUI._fit_desc(text, cw, dual, ls)
			samples.append(text)
	_check("C2 组合抽查全命中（4 稀有度 × ⇄ × 尾行 × 宽 × 紧凑：量测零增量）",
		CardSelectUI.fit_desc_measures == m0,
		"delta=%d" % (CardSelectUI.fit_desc_measures - m0))
	_check("C2 命中计数 == 样本数（%d）" % samples.size(),
		CardSelectUI.fit_desc_cache_hits - h0 == samples.size(),
		"hits=%d" % (CardSelectUI.fit_desc_cache_hits - h0))
	# C2b 尾行各档文本在键（value_scale>1 才拼「品质加成」尾行）
	var tail_ok := true
	for r in [1, 2, 3]:
		var txt := CardSelectUI.compose_desc_text(String(picked[r]["desc"]),
			float(picked[r]["value_scale"]), false)
		if not txt.contains("品质加成：该词条效果 ×%.1f" % float(scales[r])):
			tail_ok = false
	_check("C2b value_scale>1 尾行各档在键（×1.4/×1.9/×2.6 拼接同源）",
		tail_ok and not CardSelectUI.compose_desc_text(String(picked[0]["desc"]), 1.0, false)
			.contains("品质加成"), "")

	# C3 MASTERY ±3 近窗（R245 boosts 最高 +3）：任意当前级 L 的 [L-3, L+3] 窗内文本 ⊆
	# 预热全集 + 窗内键全命中
	var max_lv: int = WeaponBase.MAX_LEVEL
	var full_texts := {}
	for v in variants:
		full_texts[String(v["desc"])] = true
	var gen := CardGenerator.new()
	gen.setup(_gl.registry)
	var win_missing: Array[String] = []
	var m1: int = CardSelectUI.fit_desc_measures
	var mastery_keys := 0
	for L in range(1, max_lv + 1):
		var lo := maxi(1, L - 3)
		var hi := mini(max_lv, L + 3)
		var win: Array[Dictionary] = gen.enumerate_prewarm_variants(range(lo, hi + 1))
		for w in win:
			var txt := String(w["desc"])
			if not full_texts.has(txt):
				win_missing.append("L%d:%s" % [L, txt.substr(0, 24)])
			# MASTERY 文案（等级域产物——含「终值表口径」）窗内键全命中（两宽档）
			if txt.contains("终值表口径"):
				CardSelectUI._fit_desc(txt, CardSelectUI.CARD_SIZE.x, false, ls)
				CardSelectUI._fit_desc(CardSelectUI.compose_desc_text(txt, 1.0, true),
					CardSelectUI.DUAL_CARD_SIZE.x, true, ls)
				mastery_keys += 2
	_check("C3 MASTERY ±3 近窗 ⊆ 预热全集（L=1..%d 全窗扫描零缺失）" % max_lv,
		win_missing.is_empty(), str(win_missing.slice(0, 3)))
	_check("C3 窗内 MASTERY 键全命中（%d 键量测零增量）" % mastery_keys,
		mastery_keys > 0 and CardSelectUI.fit_desc_measures == m1,
		"keys=%d delta=%d" % [mastery_keys, CardSelectUI.fit_desc_measures - m1])

	# C4 开窗增量 ≤2（组合构造：4 稀有度 + MASTERY 窗内级；普通/双列两窗）
	var cands: Array[Dictionary] = []
	for r in range(scales.size()):
		cands.append({"kind": CardGenerator.CardKind.TRAIT, "id": &"QA_R220_MODE",
			"rarity": r, "data": null, "display_name": "QA稀有度%d" % r,
			"description": String(picked[r]["desc"]),
			"value_scale": float(picked[r]["value_scale"]), "milestone": false})
	for L in [max_lv - 2, max_lv - 1, max_lv]:
		var wdesc: Variant = null
		var win2: Array[Dictionary] = gen.enumerate_prewarm_variants([L])
		for w in win2:
			if String(w["desc"]).contains("终值表口径"):
				wdesc = w
				break
		if wdesc != null:
			cands.append({"kind": CardGenerator.CardKind.MASTERY, "id": &"QA_R220_MODE_M",
				"rarity": 2, "data": null, "display_name": "QA精通L%d" % L,
				"description": String(wdesc["desc"]), "value_scale": 1.0})
	var ui: CardSelectUI = _gl.card_select_ui
	CardSelectUI.fit_desc_measures = 0
	ui.open(cands, false)
	var dm_plain: int = CardSelectUI.fit_desc_measures
	_check("C4 预热后普通开窗量测增量 ≤2（4 稀有度+尾行+MASTERY 窗内级）",
		dm_plain <= 2, "delta=%d" % dm_plain)
	CardSelectUI.fit_desc_measures = 0
	ui.open(cands, true)
	var dm_dual: int = CardSelectUI.fit_desc_measures
	_check("C4 预热后双列开窗（⇄ 行）量测增量 ≤2", dm_dual <= 2, "delta=%d" % dm_dual)
	ui.close()

	# C5 真链开窗 / Reroll / 连升批同口径
	var m2: int = CardSelectUI.fit_desc_measures
	_gl.player.gain_xp(_gl.player.xp_need * 2.0)
	_gl.call(&"_consume_deferred_level_open")
	_check("C5 真链开窗（LEVEL_UP + 货架开）",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open,
		"state=%d" % _gl.state)
	var dm_open: int = CardSelectUI.fit_desc_measures - m2
	_check("C5 真链开窗量测增量 ≤2", dm_open <= 2, "delta=%d" % dm_open)
	var m3: int = CardSelectUI.fit_desc_measures
	_gl.call(&"_on_card_reroll")
	var dm_reroll: int = CardSelectUI.fit_desc_measures - m3
	_check("C5 Reroll 重发同口径（量测增量 ≤2）", dm_reroll <= 2, "delta=%d" % dm_reroll)
	_close_card_flow()
	_check("C5 选卡收口回 PLAYING",
		_gl.state == GameConst.GameStatus.PLAYING and not _gl.card_select_ui.is_open,
		"state=%d" % _gl.state)
	var m4: int = CardSelectUI.fit_desc_measures
	_gl.player.gain_xp(_gl.player.xp_need * 40.0)
	_gl.call(&"_consume_deferred_level_open")
	var burst: int = _gl.player.level_burst_last
	var dm_burst: int = CardSelectUI.fit_desc_measures - m4
	_check("C5 连升批每窗 ≤2（总增量 ≤2×连升数）",
		burst >= 2 and dm_burst <= 2 * burst, "burst=%d delta=%d" % [burst, dm_burst])
	print("      [info] 连升 %d 级批内量测增量 %d（每窗均值 %.1f）"
		% [burst, dm_burst, float(dm_burst) / float(maxi(burst, 1))])
	_close_card_flow()


# ═══ 域A 设置行链（两态循环/持久/立即生效/旧档回落） ═══
func _domain_a_settings_chain() -> void:
	print("── 域A 设置行两态循环 / 持久 / 立即生效 / 旧档回落 ──")
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	Meta.set_setting("perf_mode", 0)
	var sp: SettingsPanel = _gl.settings_panel
	sp.open()
	await tree.process_frame
	# A1 两态循环：点击 → 写即存 + 文案切换 + frame_priority 每读直查立即翻转
	var seq_vals: Array[int] = []
	var seq_texts: Array[String] = []
	var seq_fp: Array[bool] = []
	for i in 2:
		sp._perf_mode_btn.pressed.emit()
		seq_vals.append(int(Meta.settings("perf_mode")))
		seq_texts.append(sp._perf_mode_btn.text)
		seq_fp.append(PerfGovernor.frame_priority())
	var vals_ok := seq_vals.size() == 2 and seq_vals[0] == 1 and seq_vals[1] == 0
	var texts_ok := seq_texts.size() == 2 and seq_texts[0] == "◉ 特效优先" \
		and seq_texts[1] == "✓ 帧率优先"
	var fp_ok := seq_fp.size() == 2 and seq_fp[0] == false and seq_fp[1] == true
	_check("A1 两态循环闭合：0→1→0（写即存）", vals_ok, str(seq_vals))
	_check("A1 文案随态刷新（◉ 特效优先 ↔ ✓ 帧率优先）", texts_ok, str(seq_texts))
	_check("A1 立即生效：写口后首读 frame_priority() 即翻转（每读直查零滞后）", fp_ok,
		str(seq_fp))
	# A2 持久化磁盘回路：写 1 → _load 重读还原
	Meta.set_setting("perf_mode", 1)
	Meta._load()
	_check("A2 持久化：写 1 过 user:// 磁盘写读回路还原 1",
		int(Meta.settings("perf_mode")) == 1, "val=%s" % str(Meta.settings("perf_mode")))
	# A3 旧档磁盘回落：当前真档 settings.values 去 perf_mode 键落盘（= 昨日档）→
	#    _load → 读口回默认 0 + frame_priority() 帧率优先 + 面板文案回 ✓ 帧率优先
	var cfg := ConfigFile.new()
	cfg.load(Meta.save_path())
	var sv: Variant = cfg.get_value("settings", "values", {})
	var stripped: Dictionary = (sv as Dictionary).duplicate() if sv is Dictionary else {}
	stripped.erase("perf_mode")
	cfg.set_value("settings", "values", stripped)
	cfg.save(Meta.save_path())
	Meta._load()
	_check("A3 旧档无 perf_mode 键（磁盘真档去键）→ 读口回落默认 0",
		int(Meta.settings("perf_mode")) == 0 and not Meta._settings.has("perf_mode"),
		"val=%s" % str(Meta.settings("perf_mode")))
	_check("A3 旧档回落 → frame_priority()==true（帧率优先缺省）",
		PerfGovernor.frame_priority() == true, "fp=%s" % str(PerfGovernor.frame_priority()))
	sp._refresh_toggles()
	_check("A3 旧档回落 → 面板文案回「✓ 帧率优先」",
		sp._perf_mode_btn != null and sp._perf_mode_btn.text == "✓ 帧率优先",
		"text=%s" % (sp._perf_mode_btn.text if sp._perf_mode_btn != null else "null"))
	# A4 旧档内存缺键（r202 K③ 同款口径）：读口默认表回退
	var keep: Dictionary = Meta._settings.duplicate()
	Meta._settings.erase("perf_mode")
	_check("A4 内存缺键读口回退 0（零迁移降级不崩）",
		int(Meta.settings("perf_mode")) == 0, "val=%s" % str(Meta.settings("perf_mode")))
	Meta._settings = keep
	# A5 立即生效链·调速器侧：真设置通道模式切换 → 观测口清双侧计时、tier 保持
	PerfGovernor.set_process(false)           # 引擎侧停走——手动确定性步进
	_gl.state = GameConst.GameStatus.PLAYING
	tree.paused = false
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.tier = 3
	PerfGovernor.transitions = 0
	var t := float(PerfGovernor._target_fps())
	PerfGovernor._ema_inject = t * 0.5        # < 0.70t 与 < 0.90t 双模式都判降
	PerfGovernor._test_reset()
	Meta.set_setting("perf_mode", 0)
	PerfGovernor._process(0.0)                # 观测口吸收当前态
	for i in 3:
		PerfGovernor._process(PerfGovernor.SAMPLE_S)  # 帧率优先累计 1.5s
	_check("A5 切换前 1.5s 未降（tier 3）", PerfGovernor.tier == 3,
		"tier=%d" % PerfGovernor.tier)
	Meta.set_setting("perf_mode", 1)          # 真设置通道切换（非 override）
	PerfGovernor._process(0.0)                # 观测口：模式变化 → 双侧计时清零
	_check("A5 切换瞬间 tier 保持（3）", PerfGovernor.tier == 3,
		"tier=%d" % PerfGovernor.tier)
	for i in 3:
		PerfGovernor._process(PerfGovernor.SAMPLE_S)  # 清零后重累计 1.5s
	_check("A5 模式切换计时清零：切后再 1.5s 仍未降（未清零则第 1 拍即降）",
		PerfGovernor.tier == 3, "tier=%d" % PerfGovernor.tier)
	PerfGovernor._process(PerfGovernor.SAMPLE_S)
	_check("A5 切换后满 2.0s 降档 3→2（清零后重累计满额）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 1,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	Meta.set_setting("perf_mode", 0)
	sp.close()


# ═══ 域B PerfGovernor 注入用例 ═══
func _pg(p_tier: int, p_ema: float, p_mode: int) -> void:
	PerfGovernor.mode_override = p_mode
	PerfGovernor.tier_override = -1
	PerfGovernor.tier = p_tier
	PerfGovernor.transitions = 0
	PerfGovernor._ema_inject = p_ema
	PerfGovernor._test_reset()
	_gl.state = GameConst.GameStatus.PLAYING
	tree.paused = false


func _tick(p_n: int) -> void:
	for i in p_n:
		PerfGovernor._process(PerfGovernor.SAMPLE_S)


func _domain_b_governor_injection() -> void:
	print("── 域B PerfGovernor 注入（迟滞/地板2/挂起/target 跟随） ──")
	PerfGovernor.set_process(false)
	Meta.set_setting("fps_cap", 60)           # 域B 全程 target=60（b5 变档）
	var t := 60.0
	# B1 帧率优先降档迟滞：<0.90t 持续 2.0s 才降（1.5s 不降）；地板 1
	_pg(3, t * 0.5, 0)
	_tick(3)
	_check("B1 降迟滞：1.5s < 2.0s 不降（tier 3）", PerfGovernor.tier == 3,
		"tier=%d" % PerfGovernor.tier)
	_tick(1)
	_check("B1 满 2.0s 降档 3→2（transitions=1）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 1,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	_tick(4)
	_check("B1 再满 2.0s 降档 2→1（transitions=2）",
		PerfGovernor.tier == 1 and PerfGovernor.transitions == 2,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	_tick(4)
	_check("B1 地板 1：深降 EMA 持续不再降（transitions 仍 2）",
		PerfGovernor.tier == 1 and PerfGovernor.transitions == 2,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	# B2 升档迟滞：>0.95t 持续 5.0s 才升（4.5s 不升）；帽 3
	PerfGovernor._ema_inject = t
	PerfGovernor._test_reset()
	_tick(9)
	_check("B2 升迟滞：4.5s < 5.0s 不升（tier 1）", PerfGovernor.tier == 1,
		"tier=%d" % PerfGovernor.tier)
	_tick(1)
	_check("B2 满 5.0s 升档 1→2（transitions=3）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 3,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	_tick(10)
	_check("B2 再满 5.0s 升档 2→3（transitions=4）",
		PerfGovernor.tier == 3 and PerfGovernor.transitions == 4,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	_tick(10)
	_check("B2 帽 3：高 EMA 持续不再升（transitions 仍 4）",
		PerfGovernor.tier == 3 and PerfGovernor.transitions == 4,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	# B3 特效优先地板 2：<0.70t 降（可降至 2 不再降）；升档阈值 0.85
	_pg(3, t * 0.2, 1)
	_tick(4)
	_check("B3 特效优先 <0.70t 满 2.0s 降档 3→2（transitions=1）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 1,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	_tick(8)
	_check("B3 地板 2：深降 EMA 持续不再降（tier 仍 2 / transitions 仍 1）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 1,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	PerfGovernor._ema_inject = t * 0.92       # >0.85t（且 <0.95t——帧率优先同值不动）
	PerfGovernor._test_reset()
	PerfGovernor.tier = 2
	PerfGovernor.transitions = 1
	_tick(9)
	_check("B3 0.92t 升迟滞：4.5s < 5.0s 不升（0.85 阈值）", PerfGovernor.tier == 2,
		"tier=%d" % PerfGovernor.tier)
	_tick(1)
	_check("B3 满 5.0s 升档 2→3（0.85 阈值生效）",
		PerfGovernor.tier == 3 and PerfGovernor.transitions == 2,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	# B4a LEVEL_UP 挂起：计时冻结不清零、不清 EMA；回 PLAYING 续账
	_pg(3, t * 0.5, 0)
	_tick(3)
	_gl.state = GameConst.GameStatus.LEVEL_UP
	_tick(8)
	_check("B4a LEVEL_UP 期 8 拍不降档（选卡期挂起）",
		PerfGovernor.tier == 3 and PerfGovernor.transitions == 0,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	_check("B4a LEVEL_UP 期 EMA 不清（采样照走——值保持注入位）",
		absf(PerfGovernor._ema - t * 0.5) < EPS,
		"ema=%s want=%s" % [str(PerfGovernor._ema), str(t * 0.5)])
	_gl.state = GameConst.GameStatus.PLAYING
	_tick(1)
	_check("B4a 回 PLAYING 1 拍即降档（冻结的 1.5s 续账至 2.0s——非清零）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 1,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	# B4b paused 挂起：同口径（PROCESS_MODE_ALWAYS 采样不停、转换计时停）
	_pg(3, t * 0.5, 0)
	_tick(3)
	tree.paused = true
	_tick(8)
	_check("B4b paused 期 8 拍不降档（挂起）",
		PerfGovernor.tier == 3 and PerfGovernor.transitions == 0,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	_check("B4b paused 期 EMA 不清",
		absf(PerfGovernor._ema - t * 0.5) < EPS,
		"ema=%s want=%s" % [str(PerfGovernor._ema), str(t * 0.5)])
	tree.paused = false
	_tick(1)
	_check("B4b 解除 paused 1 拍即降档（冻结续账）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 1,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	# B5 target=min(fps_cap,120) 跟随设置：读口直查 + 阈值随 target 缩放
	Meta.set_setting("fps_cap", 144)
	var c144: int = PerfGovernor._target_fps()
	Meta.set_setting("fps_cap", 0)
	var c0: int = PerfGovernor._target_fps()
	Meta.set_setting("fps_cap", 30)
	var c30: int = PerfGovernor._target_fps()
	Meta.set_setting("fps_cap", 90)
	var c90: int = PerfGovernor._target_fps()
	var keep: Dictionary = Meta._settings.duplicate()
	Meta._settings.erase("fps_cap")
	var cdef: int = PerfGovernor._target_fps()
	Meta._settings = keep
	_check("B5 target 读口：144→120 / 0（不限）→120 / 30→30 / 90→90 / 缺键→60（默认表）",
		c144 == 120 and c0 == 120 and c30 == 30 and c90 == 90 and cdef == 60,
		"144=%d 0=%d 30=%d 90=%d def=%d" % [c144, c0, c30, c90, cdef])
	# B5b 判别用例：fps_cap=144（target 钳 120）下 EMA=115——若按 144 算则 2s 降档、
	#     按 120 算则 5s 升档。结果 tier=3 唯一指向 target=120。
	Meta.set_setting("fps_cap", 144)
	_pg(2, 115.0, 0)
	_tick(10)
	_check("B5b 钳帽判别：fps_cap=144 + EMA=115 → 5s 升档 2→3（target=120 侧；"
		+ "若误按 144 则 2s 已降档）",
		PerfGovernor.tier == 3 and PerfGovernor.transitions == 1,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	# B5c 阈值随 target 缩放：fps_cap=30（target=30）下 EMA=25 <27 → 2s 降；
	#     EMA=29 >28.5 → 5s 升
	Meta.set_setting("fps_cap", 30)
	_pg(3, 25.0, 0)
	_tick(4)
	_check("B5c target=30：EMA=25（<0.90×30）满 2.0s 降档 3→2",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 1,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	_pg(2, 29.0, 0)
	_tick(10)
	_check("B5c target=30：EMA=29（>0.95×30）满 5.0s 升档 2→3（阈值随 target 缩放）",
		PerfGovernor.tier == 3 and PerfGovernor.transitions == 1,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	Meta.set_setting("fps_cap", 60)
	# B6 tier_override 帽映射（注入直驱无视平台门）：3/2/1 → 2/1/0；-1 非 mobile 恒 2
	PerfGovernor.tier_override = 3
	var b3cap: int = PerfGovernor.fx_quality_cap()
	PerfGovernor.tier_override = 2
	var b2cap: int = PerfGovernor.fx_quality_cap()
	PerfGovernor.tier_override = 1
	var b1cap: int = PerfGovernor.fx_quality_cap()
	PerfGovernor.tier_override = -1
	_check("B6 tier_override 帽映射 3/2/1→2/1/0；释放后非 mobile 无注入恒 2（承重墙）",
		b3cap == 2 and b2cap == 1 and b1cap == 0
			and PerfGovernor.fx_quality_cap() == 2,
		"3=%d 2=%d 1=%d rel=%d" % [b3cap, b2cap, b1cap, PerfGovernor.fx_quality_cap()])


# ═══ 域D 分帧预算 ≤12ms/帧 ═══
func _domain_d_frame_budget() -> void:
	print("── 域D 分帧预算 ≤12ms/帧（12ms + 单项梯量测原子粒度） ──")
	# 单项粒度上界实测：冷缓存 pump(0) 恰处理 1 项——其墙钟=单项梯量测成本
	Prewarm.reset_for_tests()
	CardSelectUI._fit_desc_cache.clear()
	Prewarm.ensure_built(_gl.registry)
	var t0 := Time.get_ticks_usec()
	var d0: int = Prewarm.pump(0)
	var item_us: int = int(Time.get_ticks_usec() - t0)
	_check("D0 pump(0) 恰处理 1 项（预算用尽即停、最小粒度不饿死）", d0 == 1,
		"done=%d" % d0)
	# 全量重泵（清缓存）：逐帧墙钟 ≤ 12ms + 单项上界（+计时容差）
	Prewarm.reset_for_tests()
	CardSelectUI._fit_desc_cache.clear()
	Prewarm.ensure_built(_gl.registry)
	var frames := 0
	var max_us := 0
	var over: Array[int] = []
	while Prewarm.remaining() > 0 and frames < 200000:
		var tf := Time.get_ticks_usec()
		Prewarm.pump(BUDGET_US)
		var us := int(Time.get_ticks_usec() - tf)
		max_us = maxi(max_us, us)
		if us > BUDGET_US + item_us + TIMER_MARGIN_US:
			over.append(us)
		frames += 1
	_check("D1 全量泵清队（%d 键 / %d 帧）" % [Prewarm.total_built(), frames],
		Prewarm.remaining() == 0, "remaining=%d" % Prewarm.remaining())
	_check("D1 分帧消化跨 ≥2 帧（预算实际咬合）", frames >= 2, "frames=%d" % frames)
	_check("D1 每帧墙钟 ≤12ms + 单项粒度上界（实测单项 %dus，最重帧 %dus）"
		% [item_us, max_us], over.is_empty(), "over=%s" % str(over.slice(0, 4)))
	print("      [info] 单项上界 %dus / 最重帧 %dus / 预算 %dus / %d 帧"
		% [item_us, max_us, BUDGET_US, frames])


# ═══ 域E 日志头 R220 新口径声明 ═══
func _domain_e_diag_header() -> void:
	print("── 域E 日志头 R220 新口径声明在位 ──")
	var cap_keep: int = clampi(int(Meta.settings("diag_log_len")), 60, 360)
	Meta.set_setting("diag_log_len", 60)
	var res: Dictionary = DebugStats.diag_export()
	var txt := String(res.get("text", ""))
	_check("E1 导出成功（diag_export 返回文本体）", txt.length() > 0,
		"len=%d" % txt.length())
	_check("E1 R220 口径声明段在位（口径声明（R220）锚）",
		txt.contains("口径声明（R220）"), "")
	_check("E1 十六段拆键声明（card_open 开窗级联 / card_drain 溢出批消化）",
		txt.contains("十六段") and txt.contains("card_open") and txt.contains("card_drain"),
		"")
	_check("E1 模N 新口径 + 跨窗 * 标记声明（物理帧差分×1000÷墙钟窗 / 模值带 *）",
		txt.contains("物理帧差分×1000") and txt.contains("模值带 *"), "")
	_check("E1 弹段探针 vs fps 窗口错位声明（不可直接互除对账）",
		txt.contains("窗口错位"), "")
	_check("E1 派发时点声明（damage_resolved =⑧ UI 段前统一保序批化）",
		txt.contains("派发时点=⑧"), "")
	_check("E1 旧锁子串保持：「采样 1Hz × 60 行环形」随容量档刷新（r212_diaglog2 锁）",
		txt.contains("采样 1Hz × 60 行环形"), "")
	Meta.set_setting("diag_log_len", cap_keep)
	var res2: Dictionary = DebugStats.diag_export()
	_check("E1 容量回档后头随档刷新（采样 1Hz × %d 行环形）" % cap_keep,
		String(res2.get("text", "")).contains("采样 1Hz × %d 行环形" % cap_keep), "")


# ═══ 收尾 ═══
func _cleanup() -> void:
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor._ema_inject = -1.0
	PerfGovernor.tier = 3
	PerfGovernor.transitions = 0
	PerfGovernor._test_reset()
	PerfGovernor.set_process(true)
	tree.paused = false
	Meta._settings = _saved_settings           # 入口快照还原（磁盘不留测试痕）
	Meta._save()
	Prewarm.reset_for_tests()
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null

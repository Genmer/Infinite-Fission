# tests/runner/pkg9_cases.gd
# v0.9.0 自测用例体（由 test_pkg9.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖 A8_v0.9.0_design.md 冻结方案 pkg9 用例组 G1~G9（夹具沿用 pkg7 GameLoop 完整 Boot 模式）。
# 确定性：BlessingHandler 固定 seed 999（reset_run 重播种）。
extends RefCounted

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null                         # 共享 GameLoop（Boot 一次）
var _blessing_signals: int = 0                   # blessing_granted 探针计数
var _cleared_signals: int = 0                    # wave_cleared 探针计数
var _last_kind: StringName = &""                 # 最近一次 granted 的 kind（探针捕获）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_ensure_autoloads()
	_boot_game_loop()
	EventBus.blessing_granted.connect(_on_blessing_probe)
	EventBus.wave_cleared.connect(_on_cleared_probe)
	_test_g1_data_mirror()                        # G1
	_test_g2_available_pool()                     # G2
	_test_g3_weighted_roll()                      # G3
	_test_g4_offer_filter()                       # G4
	_test_g5_effects()                            # G5
	_test_g6_timing_gates()                       # G6
	_test_g7_drain_race()                         # G7
	_test_g8_ui_contract()                        # G8
	_test_g9_chip_extension()                     # G9
	EventBus.blessing_granted.disconnect(_on_blessing_probe)
	EventBus.wave_cleared.disconnect(_on_cleared_probe)
	_teardown_game_loop()
	# 汇总
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 环境引导（pkg7 夹具模式） ─────────────────────────────────────
func _ensure_autoloads() -> void:
	_check("autoload 就绪（EventBus/GameConfig/DebugStats）",
		EventBus != null and GameConfig != null and DebugStats != null)
	_check("GameConfig 非致命（balance 加载）", not GameConfig.is_fatal() and GameConfig.balance != null)


func _boot_game_loop() -> void:
	_gl = GameLoop.new()
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_check("Boot：完成且进入 MENU", _gl.boot_ready and _gl.state == GameConst.GameStatus.MENU)
	_check("Boot：BlessingHandler/BlessingUI 组装（setup 后 seed 999）",
		_gl.blessing_handler != null and _gl.blessing_ui != null
		and int(_gl.blessing_handler.rng.seed) == BlessingHandler.BLESSING_RNG_SEED)


func _teardown_game_loop() -> void:
	tree.paused = false
	if _gl != null:
		_gl.free()
		_gl = null


func _check(p_desc: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS %s" % p_desc)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_desc, p_detail])
		print("  FAIL %s %s" % [p_desc, p_detail])


func _on_blessing_probe(p_kind: StringName, _p_wave: int) -> void:
	_blessing_signals += 1
	_last_kind = p_kind


func _on_cleared_probe(_p_wave: int) -> void:
	_cleared_signals += 1


func _to_playing() -> void:
	# 夹具：合法迁移至 PLAYING（MENU→PLAYING / SHOP→PLAYING 均合法边）
	if _gl.state != GameConst.GameStatus.PLAYING:
		_gl.change_state(GameConst.GameStatus.PLAYING)


func _kinds(p_offers: Array[Dictionary]) -> Array:
	# offer 序列 → kind 序列（序列比较用）
	var out: Array = []
	for o in p_offers:
		out.append(StringName(String(o.get("kind", &""))))
	return out


func _max_hp() -> float:
	return float(_gl.player.get("max_hp"))


func _set_hp_ratio(p_ratio: float) -> void:
	_gl.player.set("hp", _max_hp() * p_ratio)


# ══ G1：数据镜像 ══════════════════════════════════════════════════
func _test_g1_data_mirror() -> void:
	print("── G1 数据镜像 ──")
	var bw: Dictionary = BlessingHandler.BLESSING_WEIGHTS
	var mirror: Dictionary = GameConfig.balance.blessing_weights
	var same: bool = bw.size() == mirror.size()
	var total := 0.0
	for key in bw:
		total += float(bw[key])
		if not mirror.has(key) or not is_equal_approx(float(bw[key]), float(mirror[key])):
			same = false
	_check("BLESSING_WEIGHTS == GameConfig.balance.blessing_weights（逐键，双源镜像）",
		same, "%s vs %s" % [str(bw), str(mirror)])
	_check("权重和 = 100.0", is_equal_approx(total, 100.0), str(total))
	_check("赐福 roll 流独立 seed 999（setup 后）",
		int(_gl.blessing_handler.rng.seed) == BlessingHandler.BLESSING_RNG_SEED
		and int(_gl.chip_handler.rng.seed) == ChipHandler.CHIP_RNG_SEED)


# ══ G2：可用池 ════════════════════════════════════════════════════
func _test_g2_available_pool() -> void:
	print("── G2 可用池 ──")
	var h := _gl.blessing_handler
	var chip := _gl.chip_handler
	chip.reset_run()
	chip.unlocked_slots = 3
	_set_hp_ratio(0.5)
	var pool := h.available_pool(2)
	_check("满状态池 7 种（槽 3/6 + 半血）", pool.size() == 7, str(pool))
	chip.bonus_slots = 3                         # capacity = 3+3 = 6
	pool = h.available_pool(2)
	_check("capacity=6 → slot1/slot2 出池（5 种）",
		pool.size() == 5 and not pool.has(BlessingHandler.KIND_SLOT1)
		and not pool.has(BlessingHandler.KIND_SLOT2), str(pool))
	chip.bonus_slots = 2                         # capacity = 5
	pool = h.available_pool(2)
	_check("capacity=5 → slot2 出池 slot1 在（6 种）",
		pool.size() == 6 and pool.has(BlessingHandler.KIND_SLOT1)
		and not pool.has(BlessingHandler.KIND_SLOT2), str(pool))
	chip.bonus_slots = 0
	_set_hp_ratio(1.0)
	pool = h.available_pool(2)
	_check("满血 → heal 出池（6 种）",
		pool.size() == 6 and not pool.has(BlessingHandler.KIND_HEAL), str(pool))
	# 池恒 ≥3 且含 gold（构造下限：gold/atk/rof/attach 恒入 = 4）
	var ok := true
	for cfg in [[3, 1.0], [0, 0.0], [6, 0.0], [2, 1.0]]:
		chip.unlocked_slots = int(cfg[0])
		chip.bonus_slots = 0
		_set_hp_ratio(float(cfg[1]))
		var p := h.available_pool(2)
		ok = ok and p.size() >= 3 and p.has(BlessingHandler.KIND_GOLD)
	_check("任意状态池 ≥3 且恒含 gold（防御下限 4）", ok)
	chip.reset_run()                             # 夹具复位
	_set_hp_ratio(1.0)


# ══ G3：加权 roll ═════════════════════════════════════════════════
func _test_g3_weighted_roll() -> void:
	print("── G3 加权 roll ──")
	var h := _gl.blessing_handler
	var chip := _gl.chip_handler
	chip.reset_run()
	chip.unlocked_slots = 3
	_set_hp_ratio(0.5)                           # 全 7 类可用
	# 同种子同序列
	h.reset_run()
	var seq_a: Array = []
	for i in range(5):
		seq_a.append(_kinds(h.roll_offers(5)))
	h.reset_run()
	var seq_b: Array = []
	for i in range(5):
		seq_b.append(_kinds(h.roll_offers(5)))
	_check("同种子（999）roll 序列可复现", seq_a == seq_b)
	# 3 项 kind 互异（无放回）
	var distinct := true
	for kinds in seq_a:
		var arr: Array = kinds
		if arr.size() != 3:
			distinct = false
			break
		var seen: Dictionary = {}
		for k in arr:
			if seen.has(k):
				distinct = false
			seen[k] = true
	_check("每次 roll 恰 3 项且 kind 互异（无放回）", distinct)
	# 1000 抽首选分布（百分比窗口，权重 ±门值）
	h.reset_run()
	var counts := {
		BlessingHandler.KIND_GOLD: 0, BlessingHandler.KIND_HEAL: 0, BlessingHandler.KIND_ATK: 0,
		BlessingHandler.KIND_ROF: 0, BlessingHandler.KIND_ATTACH: 0,
		BlessingHandler.KIND_SLOT1: 0, BlessingHandler.KIND_SLOT2: 0,
	}
	for i in range(1000):
		var offers := h.roll_offers(5)
		var k0: StringName = StringName(String((offers[0] as Dictionary).get("kind", &"")))
		counts[k0] = int(counts[k0]) + 1
	var gold_pct := int(counts[BlessingHandler.KIND_GOLD]) / 10.0
	var heal_pct := int(counts[BlessingHandler.KIND_HEAL]) / 10.0
	var atk_pct := int(counts[BlessingHandler.KIND_ATK]) / 10.0
	var rof_pct := int(counts[BlessingHandler.KIND_ROF]) / 10.0
	var attach_pct := int(counts[BlessingHandler.KIND_ATTACH]) / 10.0
	var slot1_pct := int(counts[BlessingHandler.KIND_SLOT1]) / 10.0
	var slot2_pct := int(counts[BlessingHandler.KIND_SLOT2]) / 10.0
	_check("1000 抽首选分布：gold[25,35]", gold_pct >= 25.0 and gold_pct <= 35.0, str(gold_pct))
	_check("1000 抽首选分布：heal[11,19]", heal_pct >= 11.0 and heal_pct <= 19.0, str(heal_pct))
	_check("1000 抽首选分布：atk[20,30]", atk_pct >= 20.0 and atk_pct <= 30.0, str(atk_pct))
	_check("1000 抽首选分布：rof[11,19]", rof_pct >= 11.0 and rof_pct <= 19.0, str(rof_pct))
	_check("1000 抽首选分布：attach[6.5,13.5]", attach_pct >= 6.5 and attach_pct <= 13.5, str(attach_pct))
	_check("1000 抽首选分布：slot1[2,6.5]", slot1_pct >= 2.0 and slot1_pct <= 6.5, str(slot1_pct))
	_check("1000 抽首选分布：slot2[0,2.5]", slot2_pct >= 0.0 and slot2_pct <= 2.5, str(slot2_pct))
	chip.reset_run()                             # 夹具复位
	h.reset_run()
	_set_hp_ratio(1.0)


# ══ G4：出牌过滤 ══════════════════════════════════════════════════
func _test_g4_offer_filter() -> void:
	print("── G4 出牌过滤 ──")
	var h := _gl.blessing_handler
	var chip := _gl.chip_handler
	chip.reset_run()
	chip.unlocked_slots = 3
	var ok := true
	# 门控矩阵 {bonus_slots, hp_ratio} → offers 全部 kind ∈ available_pool
	for cfg in [[0, 0.5], [3, 0.5], [2, 1.0], [0, 1.0]]:
		chip.bonus_slots = int(cfg[0])
		_set_hp_ratio(float(cfg[1]))
		var pool := h.available_pool(3)
		h.reset_run()
		for r in range(20):
			var offers := h.roll_offers(3)
			if offers.size() != 3:
				ok = false
			for o in offers:
				if not pool.has(StringName(String((o as Dictionary).get("kind", &"")))):
					ok = false
	_check("capacity/hp 门控下 offers 全部 kind ∈ available_pool（4 组 × 20 抽）", ok)
	chip.reset_run()                             # 夹具复位
	_set_hp_ratio(1.0)


# ══ G5：效果（含套装隔离精确断言） ════════════════════════════════
func _test_g5_effects() -> void:
	print("── G5 效果 ──")
	var h := _gl.blessing_handler
	var chip := _gl.chip_handler
	chip.reset_run()
	chip.unlocked_slots = 3
	h.reset_run()
	# gold 臂：增量 = 20+3w 基础值经 _add_gold（K_gold=0 → 精确）
	_gl._add_gold(-_gl.gold)                     # 余额归零
	var base_gold: int = _gl.gold
	_check("apply(gold,w7) → 余额 +41（20+3×7 基础值）",
		h.apply(BlessingHandler.KIND_GOLD, 7) and _gl.gold == base_gold + 41,
		"gold=%d" % _gl.gold)
	_check("gold 臂遥测：granted=1 + blessing_granted 信号 1 次",
		h.blessings_granted == 1 and _blessing_signals == 1)
	# heal 臂：半血 → +15%max（钳顶）
	_set_hp_ratio(0.5)
	var hp_before: float = _gl.player.get("hp")
	_check("apply(heal) → hp = min(0.5+0.15, 1)×max（钳顶）",
		h.apply(BlessingHandler.KIND_HEAL, 2)
		and is_equal_approx(float(_gl.player.get("hp")),
			minf(hp_before + _max_hp() * BlessingHandler.HEAL_RATIO, _max_hp())))
	_set_hp_ratio(1.0)
	# 套装隔离：2 枚同键 atk 芯片 → stat_bonus = (c1+c2)×1.10 + 0.04（赐福段不参与判定/不被放大）
	h.reset_run()
	chip.equip(&"CHIP_ATK", 0)                   # 0.10
	chip.equip(&"CHIP_ATK2", 0)                  # 0.12
	_check("夹具：双 atk 套装 (0.10+0.12)×1.10=0.242",
		is_equal_approx(chip.stat_bonus(&"atk_pct"), 0.242), str(chip.stat_bonus(&"atk_pct")))
	_check("apply(atk) → stat_bonus(atk_pct) = (c1+c2)×1.10 + 0.04（套装隔离精确）",
		h.apply(BlessingHandler.KIND_ATK, 2)
		and is_equal_approx(chip.stat_bonus(&"atk_pct"), 0.242 + BlessingHandler.ATK_BONUS),
		str(chip.stat_bonus(&"atk_pct")))
	_check("赐福段独立寄存（不污染套装主键计数）",
		is_equal_approx(float(chip.blessing_stats.get(&"atk_pct", 0.0)), BlessingHandler.ATK_BONUS))
	# rof / attach 臂
	h.reset_run()
	chip.reset_run()
	chip.unlocked_slots = 3
	_check("apply(rof) → stat_bonus(rof)=0.03",
		h.apply(BlessingHandler.KIND_ROF, 2)
		and is_equal_approx(chip.stat_bonus(&"rof"), BlessingHandler.ROF_BONUS))
	h.reset_run()
	chip.reset_run()
	chip.unlocked_slots = 3
	_check("apply(attach) → stat_bonus(attach_strength)=0.05",
		h.apply(BlessingHandler.KIND_ATTACH, 2)
		and is_equal_approx(chip.stat_bonus(&"attach_strength"), BlessingHandler.ATTACH_BONUS))
	# slot 臂：capacity/free_slots/snapshot locked 数
	h.reset_run()
	chip.reset_run()
	chip.unlocked_slots = 3
	_check("apply(slot1) → 返 true + capacity 4 + free 4",
		h.apply(BlessingHandler.KIND_SLOT1, 2)
		and chip.slot_capacity() == 4 and chip.free_slots() == 4)
	var snap := chip.slot_snapshot()
	var locked := 0
	for s in snap:
		if bool((s as Dictionary).get("locked", false)):
			locked += 1
	_check("slot1 后 snapshot 恒 6 格且 locked=2", snap.size() == 6 and locked == 2)
	_check("apply(slot2) → capacity 6（unlock 3+bonus 3）",
		h.apply(BlessingHandler.KIND_SLOT2, 2) and chip.slot_capacity() == 6)
	# 已满 6：slot 臂 got<=0 → false 不派发信号不计数
	var sig_before := _blessing_signals
	var granted_before: int = h.blessings_granted
	_check("capacity=6 apply(slot1) → false（无效果）", h.apply(BlessingHandler.KIND_SLOT1, 2) == false)
	_check("满槽拒绝不派发信号/不计数",
		_blessing_signals == sig_before and h.blessings_granted == granted_before)
	chip.reset_run()                             # 夹具复位
	h.reset_run()


# ══ G6：时序门控 ══════════════════════════════════════════════════
func _test_g6_timing_gates() -> void:
	print("── G6 时序门控 ──")
	var h := _gl.blessing_handler
	var bui := _gl.blessing_ui
	_gl.chip_handler.reset_run()
	h.reset_run()
	_to_playing()
	_check("夹具：PLAYING 且三浮层全关", _gl.state == GameConst.GameStatus.PLAYING
		and not _gl.shop_ui.is_open and not _gl.event_ui.is_open and not bui.is_open)
	# w==1 不弹
	_gl._on_wave_cleared_blessing(1)
	_check("w==1 wave_cleared 不弹赐福（仍 PLAYING）",
		_gl.state == GameConst.GameStatus.PLAYING and not bui.is_open)
	# w>=2 直驱 → SHOP 态 + is_open + 恰 3 选项
	_gl._on_wave_cleared_blessing(5)
	_check("w>=2 wave_cleared → SHOP 态 + 赐福开 + 恰 3 选项",
		_gl.state == GameConst.GameStatus.SHOP and bui.is_open
		and bui.current_options().size() == BlessingHandler.OFFER_COUNT)
	# 跳过 → 回 PLAYING + 遥测（无信号）
	var sig0 := _blessing_signals
	bui.skip_requested.emit()
	_check("skip → 回 PLAYING + 收起 + skipped=1（信号不派发）",
		_gl.state == GameConst.GameStatus.PLAYING and not bui.is_open
		and h.blessings_skipped == 1 and _blessing_signals == sig0)
	# choose → 回 PLAYING + granted 遥测 + blessing_granted 信号（kind 与选项一致）
	_gl._on_wave_cleared_blessing(5)
	var kind0 := StringName(String((bui.current_options()[0] as Dictionary).get("kind", &"")))
	var granted0: int = h.blessings_granted
	bui.option_chosen.emit(0)
	_check("choose(0) → 回 PLAYING + 收起 + granted +1 + 信号 kind 一致",
		_gl.state == GameConst.GameStatus.PLAYING and not bui.is_open
		and h.blessings_granted == granted0 + 1 and _blessing_signals == sig0 + 1
		and _last_kind == kind0, "kind=%s" % String(kind0))
	# 硬上限叠波：start_wave 直调不派发 wave_cleared → 天然无赐福（pkg9 固化）
	var cleared0 := _cleared_signals
	_gl.wave_director.start_wave(7)
	_check("start_wave 直调（硬上限叠波路径）不派发 wave_cleared → 无赐福",
		_cleared_signals == cleared0 and not bui.is_open
		and _gl.state == GameConst.GameStatus.PLAYING)


# ══ G7：排空竞态 ══════════════════════════════════════════════════
func _test_g7_drain_race() -> void:
	print("── G7 排空竞态 ──")
	var bui := _gl.blessing_ui
	_gl.chip_handler.reset_run()
	_gl.blessing_handler.reset_run()
	_to_playing()
	# 非 PLAYING（商店开）调 _open_blessing_flow → 暂存不开门
	_gl._open_shop_flow(9, false)
	_check("夹具：商店开（SHOP 态）", _gl.state == GameConst.GameStatus.SHOP and _gl.shop_ui.is_open)
	_gl._open_blessing_flow(9)
	_check("非 PLAYING → _deferred_blessing 暂存（不开门）",
		_gl._deferred_blessing and not bui.is_open)
	# 闭店排空 → 赐福补开
	_gl._close_shop()
	_check("闭店排空 → 赐福补开（SHOP 态 + is_open + 商店已关）",
		_gl.state == GameConst.GameStatus.SHOP and bui.is_open and not _gl.shop_ui.is_open)
	# 序：升级→赐福→商店→事件（三暂存同置 → 逐项消费，命中即停）
	bui.skip_requested.emit()                    # 收赐福 → drain（无其余暂存）→ PLAYING
	_to_playing()
	_gl._deferred_blessing = true
	_gl._deferred_shop_wave = 9
	_gl._deferred_event_wave = 9
	_gl._deferred_event_index = 0
	_gl._drain_overlays_after_resume()
	_check("排空序①赐福先开（商店/事件未开）",
		bui.is_open and not _gl.shop_ui.is_open and not _gl.event_ui.is_open)
	bui.skip_requested.emit()
	_check("排空序②赐福毕 → 商店开", _gl.shop_ui.is_open and not bui.is_open and not _gl.event_ui.is_open)
	_gl._close_shop()
	_check("排空序③商店毕 → 事件开", _gl.event_ui.is_open and not _gl.shop_ui.is_open)
	_gl._on_event_leave()
	_check("排空序④事件毕 → 回 PLAYING（全部浮层关）",
		_gl.state == GameConst.GameStatus.PLAYING and not _gl.event_ui.is_open
		and not _gl.shop_ui.is_open and not bui.is_open)
	# 暂存位清零（夹具复位）
	_gl._deferred_blessing = false
	_gl._deferred_shop_wave = 0
	_gl._deferred_event_wave = 0
	_gl._deferred_event_index = -1


# ══ G8：UI 契约 ═══════════════════════════════════════════════════
func _test_g8_ui_contract() -> void:
	print("── G8 UI 契约 ──")
	var bui := _gl.blessing_ui
	var h := _gl.blessing_handler
	# layout_rects：恰 4 项两两无交集 + 屏内
	var rects := bui.layout_rects()
	_check("layout_rects 恰 4 项（三选项+跳过）", rects.size() == 4, str(rects.size()))
	var pairwise := true
	for i in range(rects.size()):
		var r1: Rect2 = rects[i]
		if r1.position.x < 0.0 or r1.position.y < 0.0 \
				or r1.end.x > 720.0 or r1.end.y > 1280.0:
			pairwise = false
		for j in range(rects.size()):
			if i != j and r1.intersects(rects[j] as Rect2):
				pairwise = false
	_check("layout_rects 两两无交集 + 全部屏内（720×1280）", pairwise)
	# 空 option 防御：disabled + "-"
	var empty_opts: Array[Dictionary] = [{}, {}, {}]
	bui.open(empty_opts)
	var empty_ok: bool = bui.is_open
	for btn in bui._option_buttons:
		empty_ok = empty_ok and (btn as Button).disabled and (btn as Button).text == "-"
	_check("空 option 防御：disabled + \"-\"", empty_ok)
	# 连续 open→skip→open 刷新（同种子两次开门选项一致）
	_gl.chip_handler.reset_run()
	h.reset_run()
	_set_hp_ratio(0.5)
	_to_playing()
	_gl._open_blessing_flow(4)
	var first := _kinds(bui.current_options())
	bui.skip_requested.emit()                    # 经 GameLoop 仲裁 → count_skip + close
	h.reset_run()                                # 重播种 → 第二次开门同序列
	_gl._open_blessing_flow(4)
	var second := _kinds(bui.current_options())
	_check("连续 open→skip→open：第二次刷新（同种子选项一致且恰 3 项）",
		bui.is_open and second.size() == 3 and first.size() == 3 and first == second)
	# GAME_OVER 强制收起
	EventBus.emit_state_changed(GameConst.GameStatus.GAME_OVER)
	_check("state_changed(GAME_OVER) → 赐福强制收起", not bui.is_open)
	_to_playing()                                # 夹具复位（G9 用）
	h.reset_run()
	_set_hp_ratio(1.0)


# ══ G9：ChipHandler 扩展 ══════════════════════════════════════════
func _test_g9_chip_extension() -> void:
	print("── G9 ChipHandler 扩展 ──")
	var chip := _gl.chip_handler
	chip.reset_run()
	chip.unlocked_slots = 3
	_check("capacity 3 + add_bonus_slots(2) → 返 2 / capacity 5",
		chip.add_bonus_slots(2) == 2 and chip.slot_capacity() == 5)
	_check("再 add_bonus_slots(9) → 返 1（钳 6）",
		chip.add_bonus_slots(9) == 1 and chip.slot_capacity() == 6)
	chip.bonus_slots = 0                          # 已知档（unlock 3 / cap 3）——负值防御在此档验证
	_check("add_bonus_slots(-5) → 钳 0 返 0（负值防御）",
		chip.add_bonus_slots(-5) == 0 and chip.bonus_slots == 0)
	chip.add_bonus_slots(1)
	chip.add_blessing_stat(&"atk_pct", 0.02)
	chip.add_blessing_stat(&"atk_pct", 0.02)
	_check("add_blessing_stat 同键累加（0.02+0.02=0.04）",
		is_equal_approx(float(chip.blessing_stats.get(&"atk_pct", 0.0)), 0.04))
	# reset 归零（bonus_slots + blessing_stats + capacity 回解锁链档）
	chip.reset_run()
	_check("reset_run：bonus_slots/blessing_stats 归零（capacity 回解锁链）",
		chip.bonus_slots == 0 and chip.blessing_stats.is_empty() and chip.slot_capacity() == 0)
	# snapshot 恒 6 格 locked 语义（bonus 后容量内/外边界：unlock 2+bonus 1=3）
	chip.unlocked_slots = 2
	chip.bonus_slots = 1
	chip.equip(&"CHIP_ATK", 0)
	var snap := chip.slot_snapshot()
	var locked := 0
	for s in snap:
		if bool((s as Dictionary).get("locked", false)):
			locked += 1
	_check("snapshot 恒 6 格：1 装备 + 2 容量内空槽 + 3 locked",
		snap.size() == 6 and locked == 3 and (snap[1] as Dictionary).is_empty()
		and (snap[2] as Dictionary).is_empty()
		and bool((snap[3] as Dictionary).get("locked", false)), str(snap))
	chip.reset_run()

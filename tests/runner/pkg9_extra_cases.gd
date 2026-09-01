# tests/runner/pkg9_extra_cases.gd
# v0.9.0 验收补充用例体（tester 独立复核 + 补漏；由 test_pkg9_extra.gd 入口在 autoload
# 就绪后运行时加载编译）。夹具沿用 pkg9 GameLoop 完整 Boot 模式 + pkg1 管线 Enemy 真件桩。
# 补漏定位（pkg9 G1~G9 未覆盖项）：
#   X1 排空序的「升级先位」全链（G7 只测 赐福→商店→事件，无 LEVEL_UP 暂存参与）
#   X2 BlessingHandler reset_run 遥测归零（G9 只测 ChipHandler 侧）
#   X3 赐福 atk 端到端管线手算对照（G5 停在 stat_bonus 层，未穿透 ⑥b joint 公式）
#   X4 gold 臂 K_gold 路由强化（G5 在 K_gold=0 下断言，无法区分直加/乘法路径）
#   X5 slot2 门 capacity<=4 恰边界（G2 只测 3/5/6 三档，缺 capacity==4）
#   X6 EVENT_NAMES ↔ EventBus 脚本信号双源运行时恰等（pkg7 只断 size==23）
#   X7 set_chip_slots 3/5/6 档渲染（pkg7 只测 3 档一例）
extends RefCounted

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null                         # 共享 GameLoop（Boot 一次）
var _dummy_script: GDScript = null               # Enemy 真件派生测试脚本（pkg1 模式）
var _targets: Array[Node2D] = []                 # 管线 target 回收


# Enemy 真件桩（承 uid/hp/dead/resist；pkg1 同源——零抗零易伤 → V=1）
const DUMMY_ENEMY_SRC := "extends Enemy\n" \
	+ "var status_vuln: float = 0.0\n" \
	+ "var take_count: int = 0\n" \
	+ "var applied_total: float = 0.0\n" \
	+ "func take_result(p_result: DamageResult) -> void:\n" \
	+ "\ttake_count += 1\n\tapplied_total += p_result.final_value\n" \
	+ "\thp -= p_result.final_value\n" \
	+ "\tif hp <= 0.0 and not dead:\n\t\tdead = true\n"


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_ensure_autoloads()
	_boot_game_loop()
	_test_x1_drain_full_chain()                  # X1
	_test_x2_blessing_reset()                    # X2
	_test_x3_atk_pipeline_e2e()                  # X3
	_test_x4_gold_k_route()                      # X4
	_test_x5_slot2_boundary()                    # X5
	_test_x6_event_names_mirror()                # X6
	_test_x7_slot_render_tiers()                 # X7
	_teardown_game_loop()
	# 汇总
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 环境引导（pkg9 夹具模式） ─────────────────────────────────────
func _ensure_autoloads() -> void:
	_check("autoload 就绪（EventBus/GameConfig/DebugStats）",
		EventBus != null and GameConfig != null and DebugStats != null)
	_check("GameConfig 非致命（balance 加载）", not GameConfig.is_fatal() and GameConfig.balance != null)


func _boot_game_loop() -> void:
	_gl = GameLoop.new()
	_gl.name = "GameLoopUnderTestExtra"
	tree.get_root().add_child(_gl)
	_check("Boot：完成且进入 MENU", _gl.boot_ready and _gl.state == GameConst.GameStatus.MENU)


func _teardown_game_loop() -> void:
	tree.paused = false
	if _gl != null:
		_gl.free()
		_gl = null
	for t in _targets:
		if is_instance_valid(t):
			t.free()
	_targets.clear()


func _check(p_desc: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS %s" % p_desc)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_desc, p_detail])
		print("  FAIL %s %s" % [p_desc, p_detail])


func _to_playing() -> void:
	if _gl.state != GameConst.GameStatus.PLAYING:
		_gl.change_state(GameConst.GameStatus.PLAYING)


# ── X1：排空序全链实测（升级→赐福→商店；G7 未含升级先位） ──────────
func _test_x1_drain_full_chain() -> void:
	print("── X1 排空序全链（LEVEL_UP 先位） ──")
	var bui := _gl.blessing_ui
	_gl.chip_handler.reset_run()
	_gl.blessing_handler.reset_run()
	_to_playing()
	# 三暂存同置：商店开（真实路径）→ 商店期升级排队 → 商店期赐福暂存 → 商店期二次开店暂存
	_check("夹具：_open_shop_flow(9) 自 PLAYING 开店",
		_gl._open_shop_flow(9, false) and _gl.state == GameConst.GameStatus.SHOP
		and _gl.shop_ui.is_open)
	EventBus.emit_level_up(5)
	_check("商店期 level_up → pending_level_ups 排队（不弹卡）",
		_gl.pending_level_ups == 1 and _gl.state == GameConst.GameStatus.SHOP
		and not _gl.card_select_ui.is_open)
	_gl._open_blessing_flow(9)
	_check("商店期赐福 → _deferred_blessing 暂存", _gl._deferred_blessing and not bui.is_open)
	_check("商店期二次开店 → _deferred_shop_wave 暂存（开门拒绝）",
		not _gl._open_shop_flow(12, false) and _gl._deferred_shop_wave == 12)
	# 逐次 resume：①升级 → ②赐福 → ③商店 → ④回 PLAYING
	_gl._close_shop()
	_check("排空①升级先开（LEVEL_UP 态 + 卡选开；赐福/商店/事件全关）",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open
		and not bui.is_open and not _gl.shop_ui.is_open and not _gl.event_ui.is_open
		and _gl.pending_level_ups == 0)
	_gl.card_select_ui.choose(0)
	_check("排空②选卡毕 → 赐福补开（SHOP 态；卡选关/商店关/事件关）",
		_gl.state == GameConst.GameStatus.SHOP and bui.is_open
		and not _gl.card_select_ui.is_open and not _gl.shop_ui.is_open
		and not _gl.event_ui.is_open and not _gl._deferred_blessing)
	bui.skip_requested.emit()
	_check("排空③赐福毕 → 暂存商店开（wave 12）",
		_gl.state == GameConst.GameStatus.SHOP and _gl.shop_ui.is_open
		and not bui.is_open and not _gl.event_ui.is_open)
	_gl._close_shop()
	_check("排空④商店毕无暂存 → 回 PLAYING（全部浮层关）",
		_gl.state == GameConst.GameStatus.PLAYING and not _gl.shop_ui.is_open
		and not bui.is_open and not _gl.event_ui.is_open and not _gl.card_select_ui.is_open)
	# 暂存位清零（夹具复位；选卡已应用于 player，不影响后续组——各组自复位 handler）
	tree.paused = false
	_gl._deferred_blessing = false
	_gl._deferred_shop_wave = 0
	_gl._deferred_event_wave = 0
	_gl._deferred_event_index = -1
	_gl.chip_handler.reset_run()
	_gl.blessing_handler.reset_run()


# ── X2：BlessingHandler reset 全归零（遥测 + 种子） ───────────────
func _test_x2_blessing_reset() -> void:
	print("── X2 BlessingHandler reset 全归零 ──")
	var h := _gl.blessing_handler
	_gl.chip_handler.reset_run()
	_gl.chip_handler.unlocked_slots = 3
	h.reset_run()
	_gl._add_gold(-_gl.gold)                     # 余额归零便于断言
	var granted0: int = h.blessings_granted
	var skipped0: int = h.blessings_skipped
	_check("夹具：apply(gold) + count_skip 双遥测非零",
		h.apply(BlessingHandler.KIND_GOLD, 2) and h.blessings_granted == granted0 + 1)
	h.count_skip()
	_check("夹具：skipped 非零", h.blessings_skipped == skipped0 + 1)
	h.reset_run()
	_check("reset_run：granted/skipped 归零 + seed 999 重播种（W3 reset 全归零）",
		h.blessings_granted == 0 and h.blessings_skipped == 0
		and int(h.rng.seed) == BlessingHandler.BLESSING_RNG_SEED)
	_gl.chip_handler.reset_run()


# ── X3：赐福 atk 端到端（真件芯片 → Option A → ⑥b joint 手算对照） ─
func _test_x3_atk_pipeline_e2e() -> void:
	print("── X3 赐福 atk 端到端管线手算对照 ──")
	var chip := _gl.chip_handler
	var h := _gl.blessing_handler
	chip.reset_run()
	chip.unlocked_slots = 3
	h.reset_run()
	# 真件双 atk 主键芯片（同 id 唯一 → CHIP_ATK 紫 0.24 + CHIP_ATK2 紫 0.26）
	_check("夹具：装备 CHIP_ATK(2)=0.24 + CHIP_ATK2(2)=0.26",
		chip.equip(&"CHIP_ATK", 2) and chip.equip(&"CHIP_ATK2", 2))
	_check("套装段：stat_bonus = (0.24+0.26)×1.10 = 0.55",
		is_equal_approx(chip.stat_bonus(&"atk_pct"), 0.55), str(chip.stat_bonus(&"atk_pct")))
	_check("赐福 atk 出牌成功", h.apply(BlessingHandler.KIND_ATK, 5))
	_check("Option A：stat_bonus = 0.55 + 0.04 = 0.59（赐福不被 ×1.10 放大）",
		is_equal_approx(chip.stat_bonus(&"atk_pct"), 0.59), str(chip.stat_bonus(&"atk_pct")))
	# 管线对照（base_atk=100 / 零抗零易伤 / crit 0 → S=100 M=1 L=1 C=1 V=1）
	var target := _make_target()
	# 对照组：无芯片段 → final = 100
	var pipe0 := DamagePipeline.new()
	pipe0.begin_frame(301)
	var ctx0 := _make_ctx(target, 301, 301)
	var r0: DamageResult = pipe0.resolve(ctx0)
	_check("对照：无芯片 → final = 100.0", r0 != null and is_equal_approx(r0.final_value, 100.0),
		str(r0.final_value if r0 != null else -1.0))
	# 实验组：真件注入契约 contrib = stat_bonus(atk_pct)（weapon_base/projectile 同式）
	# → ⑥b chip_product = 1 + min(0.59, 1.0) = 1.59 → joint = min(1×1.59, 8) = 1.59
	# → final = 100 × 1.59 = 159.0（若赐福被套装放大：0.627 → 162.7 ≠ 159，即判 Option A 违约）
	var pipe := DamagePipeline.new()
	pipe.begin_frame(302)
	var ctx := _make_ctx(target, 302, 302)
	ctx.chip_entries.append({"stat": &"atk_pct", "contrib": chip.stat_bonus(&"atk_pct")})
	var r: DamageResult = pipe.resolve(ctx)
	_check("端到端：final = 100×(1+0.59) = 159.0（⑥b joint 手算对照）",
		r != null and is_equal_approx(r.final_value, 159.0), str(r.final_value if r != null else -1.0))
	_check("⑥b 审计：chip_product = 1.59 / 无段内截断",
		r != null and r.audit != null and is_equal_approx(r.audit.chip_product, 1.59)
		and not r.audit.clamped_chip)
	# joint 联合钳：M=9（两乘区各 contrib 3.0 钳 cap_pool 2.0 → 3×3）→ joint = min(9×1.59, 8) = 8
	var pipe2 := DamagePipeline.new()
	pipe2.begin_frame(303)
	var ctx2 := _make_ctx(target, 303, 303)
	ctx2.mult_pools = [
		{"pool_id": &"x3_zone_a", "source_uid": 1, "contrib": 3.0, "cap_pool": 2.0},
		{"pool_id": &"x3_zone_b", "source_uid": 2, "contrib": 3.0, "cap_pool": 2.0},
	]
	ctx2.chip_entries.append({"stat": &"atk_pct", "contrib": chip.stat_bonus(&"atk_pct")})
	var r2: DamageResult = pipe2.resolve(ctx2)
	_check("joint 联合钳：F9 先钳 M 9→8（compressed）→ joint=min(8×1.59,8)=8 → final = 800.0",
		r2 != null and is_equal_approx(r2.mult_product, 8.0)
		and r2.audit != null and r2.audit.compressed
		and is_equal_approx(r2.final_value, 800.0), str(r2.final_value if r2 != null else -1.0))
	# ⑥b 段内 cap：Σ 1.3 > cap_chip_zone 1.0 → 钳 1.0 → chip_product = 2 → final = 200
	var pipe3 := DamagePipeline.new()
	pipe3.begin_frame(304)
	var ctx3 := _make_ctx(target, 304, 304)
	ctx3.chip_entries = [
		{"stat": &"atk_pct", "contrib": 0.7},
		{"stat": &"atk_pct", "contrib": 0.6},
	]
	var r3: DamageResult = pipe3.resolve(ctx3)
	_check("⑥b 段 cap：Σ1.3 钳 1.0 → chip_product=2 → final = 200.0 + clamped_chip 审计",
		r3 != null and is_equal_approx(r3.final_value, 200.0)
		and r3.audit != null and r3.audit.clamped_chip
		and is_equal_approx(r3.audit.chip_product, 2.0),
		str(r3.final_value if r3 != null else -1.0))
	chip.reset_run()
	h.reset_run()


# ── X4：gold 臂 K_gold 路由强化（G5 在 K_gold=0 下无法区分路径） ───
func _test_x4_gold_k_route() -> void:
	print("── X4 gold 臂 K_gold 路由 ──")
	var chip := _gl.chip_handler
	var h := _gl.blessing_handler
	chip.reset_run()
	chip.unlocked_slots = 3
	h.reset_run()
	_check("夹具：CHIP_GOLD 白档 → stat_bonus(gold_gain)=0.10",
		chip.equip(&"CHIP_GOLD", 0) and is_equal_approx(chip.stat_bonus(&"gold_gain"), 0.10))
	_gl._add_gold(-_gl.gold)                     # 余额归零
	var base_gold: int = _gl.gold
	_check("apply(gold,w7) → 41×(1+0.10)=45.1 → round=45（经 _add_gold 吃 K_gold）",
		h.apply(BlessingHandler.KIND_GOLD, 7) and _gl.gold == base_gold + 45,
		"gold=%d（直加路径会得 41）" % _gl.gold)
	chip.reset_run()
	h.reset_run()


# ── X5：slot2 门 capacity<=4 恰边界（G2 缺 capacity==4 档） ────────
func _test_x5_slot2_boundary() -> void:
	print("── X5 slot2 门 capacity==4 边界 ──")
	var chip := _gl.chip_handler
	var h := _gl.blessing_handler
	chip.reset_run()
	chip.unlocked_slots = 3
	chip.bonus_slots = 1                         # capacity = mini(3+1, 6) = 4
	var pool := h.available_pool(2)
	_check("capacity==4 → slot1（4<6）与 slot2（4<=4）同入池（恰边界含）",
		pool.has(BlessingHandler.KIND_SLOT1) and pool.has(BlessingHandler.KIND_SLOT2)
		and not pool.has(BlessingHandler.KIND_HEAL), str(pool))
	_check("capacity==4 apply(slot2) → 返 true + capacity 6",
		h.apply(BlessingHandler.KIND_SLOT2, 2) and chip.slot_capacity() == 6)
	_check("capacity==6 apply(slot1) → false（门 4<6 拒）",
		h.apply(BlessingHandler.KIND_SLOT1, 2) == false and chip.slot_capacity() == 6)
	chip.reset_run()


# ── X6：EVENT_NAMES ↔ EventBus 脚本信号双源运行时恰等 ─────────────
func _test_x6_event_names_mirror() -> void:
	print("── X6 双源运行时对账（23 恰等） ──")
	var names: Array[StringName] = DataValidator.EVENT_NAMES
	var script_signals: Array = EventBus.get_script().get_script_signal_list()
	_check("EventBus 脚本声明信号恰 23（get_script_signal_list）", script_signals.size() == 23,
		str(script_signals.size()))
	var all_declared := true
	for n in names:
		if not EventBus.has_signal(n):
			all_declared = false
	_check("EVENT_NAMES 23 名逐一 EventBus.has_signal（注册表↔声明双源对账）",
		names.size() == 23 and all_declared, str(names.size()))
	# get_script_signal_list() 返回 Array[Dictionary]（{name, args...}）——先抽 name 再比集合
	var sig_names: Array[StringName] = []
	for sd in script_signals:
		sig_names.append(StringName(String((sd as Dictionary).get("name", ""))))
	var set_equal: bool = sig_names.size() == names.size()
	if set_equal:
		for n in names:
			if not sig_names.has(n):
				set_equal = false
	_check("两源集合恰等（无多无漏，含第 23 号 blessing_granted）",
		set_equal and names.has(&"blessing_granted"))


# ── X7：set_chip_slots 3/5/6 档渲染（locked 未解锁灰显计数） ──────
func _test_x7_slot_render_tiers() -> void:
	print("── X7 set_chip_slots 3/5/6 档渲染 ──")
	var chip := _gl.chip_handler
	var shop := _gl.shop_ui
	for cfg in [[3, 3], [5, 1], [6, 0]]:         # [capacity, locked 期望数]
		chip.reset_run()
		chip.unlocked_slots = 3
		chip.bonus_slots = int(cfg[0]) - 3
		var snap := chip.slot_snapshot()
		var locked_in_snap := 0
		for s in snap:
			if bool((s as Dictionary).get("locked", false)):
				locked_in_snap += 1
		shop.set_chip_slots(snap)
		var locked_labels := 0
		var gray_ok := true
		for lbl in shop._slot_labels:
			if String((lbl as Label).text) == "未解锁":
				locked_labels += 1
				if (lbl as Label).self_modulate != Color(0.45, 0.45, 0.5):
					gray_ok = false
		_check("capacity %d → 快照 locked %d + 渲染「未解锁」%d 处灰显" % [int(cfg[0]), int(cfg[1]), int(cfg[1])],
			snap.size() == 6 and locked_in_snap == int(cfg[1])
			and locked_labels == int(cfg[1]) and gray_ok,
			"snap=%d label=%d" % [locked_in_snap, locked_labels])
	chip.reset_run()


# ── 管线夹具（pkg1 同源） ─────────────────────────────────────────
func _make_target() -> Enemy:
	if _dummy_script == null:
		_dummy_script = GDScript.new()
		_dummy_script.source_code = DUMMY_ENEMY_SRC
		_dummy_script.reload()
	var t: Enemy = _dummy_script.new()
	t.set("hp", 1000000.0)
	t.set("uid", GameConst.next_uid())
	_targets.append(t)
	return t


func _make_ctx(p_target: Enemy, p_frame: int, p_source: int) -> DamageContext:
	var ctx := DamageContext.make()
	ctx.source_uid = p_source
	ctx.target = p_target
	var uid_v: Variant = p_target.get("uid")
	ctx.target_uid = int(uid_v) if uid_v != null else 0
	ctx.frame_stamp = p_frame
	ctx.base_atk = 100.0
	ctx.crit_chance = 0.0                        # 非暴击 → C=1 不掷骰（确定性）
	return ctx

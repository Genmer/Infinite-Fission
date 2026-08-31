# tests/runner/pkg6_extra_cases.gd
# v0.6.0 验收补漏用例体（由 test_pkg6_extra.gd 入口在 autoload 就绪后运行时加载编译）。
# tester 独立验收视角：pkg6 已覆盖项不重复；本文件只补 pkg6 未覆盖的验收口径——
#   A. T1 DataRegistry 加载 68 资源 0 剔除（report 锁数 + 表尺寸 vs 文件系统独立对账）
#   B. T4 卡池 500 抽（固定种子）AFF_GOLD_DROP / AFF_GOLD_VALUE 各 ≥1 次
#   C. T4 apply 掉率词条后 chance=0.06 大批量抽样通过率上移 ≥6.8 个百分点
#   D. T4 金币词条叠满 stack_max → 移出候选池（§6.4）
#   E. T5 apply 武器卡后 weapon_slots+1 且精通候选含新武器
#   F. T6 restart 后限购位/金币/商店库存归零 + 黑市追加申请不跨局
# 确定性：卡牌 roll / 金币 roll 均定种子；概率断言走大批量抽样 + 门值。
extends RefCounted

const DT := 1.0 / 120.0                          # 120Hz 物理帧
const GOLD_TRAIT_DROP := &"AFF_GOLD_DROP"
const GOLD_TRAIT_VALUE := &"AFF_GOLD_VALUE"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null                         # 独立 GameLoop（本 runner 独占 Boot）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_ensure_autoloads()
	_boot_game_loop()
	_test_registry_68()                           # A / T1
	_test_card_pool_500()                         # B / T4
	_test_stack_max_pool_removal()                # D / T4（先于金币抽样，夹具互不污染）
	_test_gold_drop_chance_sampling()             # C / T4
	_test_weapon_apply_mastery()                  # E / T5
	_test_restart_shop_reset()                    # F / T6
	_teardown_game_loop()
	# 汇总
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 环境引导（pkg6 夹具模式） ─────────────────────────────────────
func _ensure_autoloads() -> void:
	_check("autoload 就绪（EventBus/GameConfig/DebugStats）",
		EventBus != null and GameConfig != null and DebugStats != null)
	_check("GameConfig 非致命（balance 加载）", not GameConfig.is_fatal() and GameConfig.balance != null)


func _boot_game_loop() -> void:
	_gl = GameLoop.new()
	_gl.name = "GameLoopExtraUnderTest"
	tree.get_root().add_child(_gl)
	_check("Boot：完成且进入 MENU", _gl.boot_ready and _gl.state == GameConst.GameStatus.MENU)


func _teardown_game_loop() -> void:
	tree.paused = false
	if _gl != null:
		_gl.free()
		_gl = null


# ── A / T1：DataRegistry 加载 68 资源 0 剔除 ──────────────────────
func _test_registry_68() -> void:
	print("── A/T1 DataRegistry 68 资源 0 剔除 ──")
	var reg := _gl.registry
	var rep: Dictionary = reg.report
	_check("校验报告：total = 68 且 rejected = 0",
		int(rep.get("total", -1)) == 68 and int(rep.get("rejected", -1)) == 0,
		"total=%s rejected=%s" % [str(rep.get("total")), str(rep.get("rejected"))])
	# 独立对账（文件系统口径：resources/* + data/gamefeel 的 .tres 计数 9/8/30/11/8/1/1）
	_check("对账 weapons = 9", reg.weapons.size() == 9, str(reg.weapons.size()))
	_check("对账 enemies = 8", reg.enemies.size() == 8, str(reg.enemies.size()))
	_check("对账 traits = 30", reg.traits.size() == 30, str(reg.traits.size()))
	_check("对账 relics = 11", reg.relics.size() == 11, str(reg.relics.size()))
	_check("对账 synergies = 8", reg.synergies.size() == 8, str(reg.synergies.size()))
	_check("对账 wave_table / game_feel 各 1（单件类目）",
		reg.wave_table != null and reg.game_feel != null)
	var table_sum: int = reg.weapons.size() + reg.enemies.size() + reg.traits.size() \
		+ reg.relics.size() + reg.synergies.size() + 2
	_check("表尺寸合计 = 68（与 report.total 互证）", table_sum == 68
		and int(rep.get("total", -1)) == table_sum, "sum=%d" % table_sum)


# ── B / T4：卡池 500 抽（固定种子）金币双词条各 ≥1 次 ─────────────
func _test_card_pool_500() -> void:
	print("── B/T4 卡池 500 抽金币词条可达 ──")
	var gen := _gl.card_generator
	var player := _gl.player
	_check("夹具：基线玩家（仅 W1 / 解锁槽 1）",
		player.weapon_slots[0] != null and player.unlocked_slots == 1)
	gen.rng.seed = 20260901                       # 固定种子（确定性抽样）
	var seen_drop := 0
	var seen_value := 0
	for i in range(500):
		for c in gen.generate_candidates({"player": player, "wave": 12}):
			var cid := StringName(String(c.get("id", "")))
			if int(c.get("kind", -1)) == CardGenerator.CardKind.TRAIT:
				if cid == GOLD_TRAIT_DROP:
					seen_drop += 1
				elif cid == GOLD_TRAIT_VALUE:
					seen_value += 1
	_check("500 抽（固定种子）：AFF_GOLD_DROP 出现 ≥1 次（count=%d）" % seen_drop,
		seen_drop >= 1)
	_check("500 抽（固定种子）：AFF_GOLD_VALUE 出现 ≥1 次（count=%d）" % seen_value,
		seen_value >= 1)


# ── D / T4：金币词条叠满 stack_max → 移出候选池 ───────────────────
func _test_stack_max_pool_removal() -> void:
	print("── D/T4 叠满移出池 ──")
	var gen := _gl.card_generator
	var player := _gl.player
	var host: WeaponBase = player.weapon_slots[0]
	var drop := _gl.registry.get_trait(GOLD_TRAIT_DROP)
	var value := _gl.registry.get_trait(GOLD_TRAIT_VALUE)
	# 叠满前：两词条均在 ADD 候选池（池成员基线）
	var add_before: Array[StringName] = gen._trait_candidates("ADD", player, [])
	_check("基线：金币双词条在 ADD 候选池",
		add_before.has(GOLD_TRAIT_DROP) and add_before.has(GOLD_TRAIT_VALUE))
	# AFF_GOLD_DROP 叠满 3 层 → 移出池
	for i in range(3):
		host.attach_trait(drop)
	var add_after_drop: Array[StringName] = gen._trait_candidates("ADD", player, [])
	_check("AFF_GOLD_DROP 叠满 ×3 → 移出 ADD 候选池", not add_after_drop.has(GOLD_TRAIT_DROP))
	_check("移出不误伤：ADD 池仍有其余词条", add_after_drop.size() > 0
		and add_after_drop.has(GOLD_TRAIT_VALUE))
	# AFF_GOLD_VALUE 叠满 3 层 → 移出池（同武器 6 层 ≤ MAX_WEAPON_TRAITS 12）
	for i in range(3):
		host.attach_trait(value)
	var add_after_both: Array[StringName] = gen._trait_candidates("ADD", player, [])
	_check("AFF_GOLD_VALUE 叠满 ×3 → 移出 ADD 候选池", not add_after_both.has(GOLD_TRAIT_VALUE)
		and not add_after_both.has(GOLD_TRAIT_DROP))
	# 还原夹具（W1 初始无词条）
	host.trait_stack.clear()
	_check("夹具还原：主武器栈清空后双词条回到池",
		gen._trait_candidates("ADD", player, []).has(GOLD_TRAIT_DROP))


# ── C / T4：apply 掉率词条后 chance=0.06 大批量抽样上移 ≥6.8% ─────
func _test_gold_drop_chance_sampling() -> void:
	print("── C/T4 掉率词条 0.06 抽样上移 ──")
	_gl.start_run()
	var player := _gl.player
	var pool: GoldPool = _gl.pools[&"gold"]
	# 夹具敌：chance=0.06（A4 §4 基线掉率口径）
	var data := EnemyData.new()
	data.id = &"E_GOLD_PROBE"
	data.hp_base = 60.0
	data.spd_base = 80.0
	data.dmg_base = 8.0
	data.exp_base = 3.0
	data.tp_cost = 1.0
	data.hitbox_r = 14.0
	data.gold_drop = {"chance": 0.06, "min": 8, "max": 12}
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire() as Enemy
	enemy.spawn(data, 1, 0)
	var n := 20000
	# 基线：无词条 → 通过率 ≈ 0.06
	_gl.set_gold_rng_seed(901)
	var hits0 := _roll_drops(enemy, pool, n)
	var p0 := float(hits0) / float(n)
	_check("基线通过率锚定 0.06（±0.75pt 容差）[p0=%.4f]" % p0,
		p0 >= 0.0525 and p0 <= 0.0675)
	# 加成：1 层 AFF_GOLD_DROP（0.08/层）→ chance = 0.06 + 0.08 = 0.14
	var host: WeaponBase = player.weapon_slots[0]
	host.attach_trait(_gl.registry.get_trait(GOLD_TRAIT_DROP))
	_gl.set_gold_rng_seed(901)
	var hits1 := _roll_drops(enemy, pool, n)
	var p1 := float(hits1) / float(n)
	_check("1 层掉率词条：通过率上移 ≥6.8 个百分点（0.14-0.06=0.08，F3 首层不衰减）[p1=%.4f diff=%.4f]"
		% [p1, p1 - p0], (p1 - p0) >= 0.068)
	# 还原夹具 + 探针敌归还
	host.trait_stack.clear()
	enemy.hp = 0.0
	enemy.dead = true
	(_gl.pools[&"enemy"] as EnemyPool).release(enemy)


func _roll_drops(p_enemy: Enemy, p_pool: GoldPool, p_times: int) -> int:
	# 大批量掉落抽样：逐次判定掉落事件数（掉即归还，避免满池合并干扰事件计数）
	var hits := 0
	for i in range(p_times):
		p_enemy.global_position = Vector2(100.0 + float(i % 500), 100.0)
		var before: int = _gl.active_coins.size()
		_gl._on_enemy_killed_drop_gold(p_enemy)
		if _gl.active_coins.size() > before:
			hits += 1
			for coin in _gl.active_coins:
				if is_instance_valid(coin):
					p_pool.release(coin)
			_gl.active_coins.clear()
	return hits


# ── E / T5：apply 武器卡后精通候选含新武器 ────────────────────────
func _test_weapon_apply_mastery() -> void:
	print("── E/T5 武器卡 apply → 精通候选 ──")
	var gen := _gl.card_generator
	var player := _gl.player
	player.unlock_slot(2)                         # 保证有空槽门控（基线仅 W1）
	var slots0 := _weapon_count(player)
	var card := gen._make_weapon_card(_gl.registry.get_weapon(&"W4_pulse_beam"))
	gen.apply_choice(card, player)
	_check("apply 后 weapon_slots +1（W4 入手）",
		_weapon_count(player) == slots0 + 1 and gen._player_holds_weapon(player, &"W4_pulse_beam"))
	# 精通候选（未满级武器列表）包含新入手的 W4 实例
	var mastery_ids: Array[StringName] = []
	for w in gen._mastery_candidates(player):
		var wb := w as WeaponBase
		if wb != null and wb.data != null:
			mastery_ids.append(wb.data.id)
	_check("精通候选含新武器（W4_pulse_beam）", mastery_ids.has(&"W4_pulse_beam"), str(mastery_ids))
	_check("精通候选含既有 W1（升级通道不闭）", mastery_ids.has(&"W1_pistol"))
	# 还原夹具
	for i in range(player.weapon_slots.size()):
		var w: WeaponBase = player.weapon_slots[i]
		if w is WeaponBase and is_instance_valid(w) and (w as WeaponBase).data.id == &"W4_pulse_beam":
			player.weapon_slots[i] = null
			w.free()
	player.unlocked_slots = 1
	_check("夹具还原：仅 W1 / 解锁槽 1", _weapon_count(player) == 1 and player.unlocked_slots == 1)


# ── F / T6：restart 后限购位/金币/商店库存归零 + 黑市申请不跨局 ────
func _test_restart_shop_reset() -> void:
	print("── F/T6 restart 商店态归零 ──")
	var gen := _gl.card_generator
	var shop := _gl.shop_ui
	var player := _gl.player
	# 夹具：开店 → 消费三类限购位（卡 0 / maxhp / reroll）→ 黑市申请挂起
	var cards: Array[Dictionary] = [
		gen._make_trait_card(&"AFF_HP_UP", 9),
		gen._make_trait_card(&"AFF_ATK_UP", 9),
		gen._fallback_stat_card(),
	]
	cards[0]["rarity"] = 1                        # 定价锁定 70
	shop.open(5, false, cards, {}, 0)
	_gl.change_state(GameConst.GameStatus.SHOP)
	_gl._add_gold(500)
	_gl._on_shop_purchase(0)
	_gl._on_shop_utility(&"maxhp")
	_gl._on_shop_utility(&"reroll")
	var st: Dictionary = shop.shelf_state()
	_check("夹具：三类限购位已消费（purchased[0] / maxhp / reroll）",
		bool(st["purchased"][0]) and bool(st["maxhp_used"]) and bool(st["reroll_used"]))
	_gl.wave_director.queue_extra_shop()          # 黑市追加申请挂起
	# restart（GAME_OVER → restart_run，pkg6 T3 ⑦ 同口径）
	_gl.change_state(GameConst.GameStatus.GAME_OVER)
	_gl.restart_run()
	_check("restart：金币归零", _gl.gold == 0, "gold=%d" % _gl.gold)
	_check("restart：商店强制收起 + 武器架/货架库存清空",
		not shop.is_open and shop.shelf_state()["weapon"].is_empty()
		and (shop.shelf_state()["cards"] as Array).is_empty())
	_check("restart：黑市追加申请不跨局（extra_shop 清零）",
		not _gl.wave_director._extra_shop_pending)
	_check("restart：回到 PLAYING", _gl.state == GameConst.GameStatus.PLAYING)
	# 重开新店：限购位全复位（每店限购不残留上局记录）
	var cards2: Array[Dictionary] = [
		gen._make_trait_card(&"AFF_HP_UP", 9),
		gen._make_trait_card(&"AFF_ATK_UP", 9),
		gen._fallback_stat_card(),
	]
	shop.open(1, false, cards2, {}, _gl.gold)
	var st2: Dictionary = shop.shelf_state()
	var purchased_all_false := true
	for p in st2["purchased"]:
		if bool(p):
			purchased_all_false = false
	_check("重开新店：限购位全归零（purchased×4 / reroll / maxhp）",
		purchased_all_false and not bool(st2["reroll_used"]) and not bool(st2["maxhp_used"]))
	shop.close()
	_gl.change_state(GameConst.GameStatus.PLAYING)


# ── 工具 ──────────────────────────────────────────────────────────
func _weapon_count(p_player: Node) -> int:
	var n := 0
	var slots: Array = p_player.get("weapon_slots")
	for w in slots:
		if w is WeaponBase and is_instance_valid(w):
			n += 1
	return n


# ── 断言（pkg6 同款） ─────────────────────────────────────────────
func _check(p_msg: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_msg)
	else:
		_fail += 1
		var line := "FAIL | %s" % p_msg
		if p_detail != "":
			line += "　[%s]" % p_detail
		print(line)
		_failures.append(line)

# tests/runner/pkg6_cases.gd
# v0.6.0 自测用例体（由 test_pkg6.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖 A4_v0.6.0_design.md 增量（按 T 任务分节；夹具沿用 pkg4 GameLoop 完整 Boot 模式）。
# 确定性：固定 RNG 种子；金币掉落用 set_gold_rng_seed 定种子；概率断言走抽样/门值。
extends RefCounted

const DT := 1.0 / 120.0                          # 120Hz 物理帧

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null                         # 共享 GameLoop（Boot 一次）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_ensure_autoloads()
	_boot_game_loop()
	_test_weapon_gated_trait()                    # T1
	_test_gold_trait_data()                       # T4
	_test_gold_chain()                            # T3
	_test_weapon_cards()                          # T5
	_test_hud_layout_and_banner()                 # T2
	_test_shop()                                  # T6
	_test_boss_patterns()                         # T7
	_teardown_game_loop()
	# 汇总
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 环境引导（pkg4 夹具模式） ─────────────────────────────────────
func _ensure_autoloads() -> void:
	_check("autoload 就绪（EventBus/GameConfig/DebugStats）",
		EventBus != null and GameConfig != null and DebugStats != null)
	_check("GameConfig 非致命（balance 加载）", not GameConfig.is_fatal() and GameConfig.balance != null)


func _boot_game_loop() -> void:
	_gl = GameLoop.new()
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_check("Boot：完成且进入 MENU", _gl.boot_ready and _gl.state == GameConst.GameStatus.MENU)


func _teardown_game_loop() -> void:
	tree.paused = false
	if _gl != null:
		_gl.free()
		_gl = null


# ── T1：武器门槛词条（required_weapon） ───────────────────────────
func _test_weapon_gated_trait() -> void:
	print("── T1 武器门槛词条 ──")
	var gen := _gl.card_generator
	var player := _gl.player
	var orbit := _gl.registry.get_trait(&"MEC_ORBIT_LINK")
	_check("夹具：MEC_ORBIT_LINK 存在且 required_weapon=W8_orbit_field",
		orbit != null and orbit.required_weapon == &"W8_orbit_field")
	var plain := _gl.registry.get_trait(&"AFF_ATK_UP")
	_check("既有词条默认无门槛（required_weapon 空）",
		plain != null and plain.required_weapon == &"")
	# 无 W8：MECH 候选池不含 MEC_ORBIT_LINK
	var mech_without: Array[StringName] = gen._trait_candidates("MECH", player, [])
	_check("无 W8：MECH 候选不含 MEC_ORBIT_LINK", not mech_without.has(&"MEC_ORBIT_LINK"))
	_check("无 W8：其余 MECH 词条仍在池", mech_without.size() > 0)
	# 持 W8：候选池含 MEC_ORBIT_LINK（解锁槽 2 → 装入 W8）
	player.unlock_slot(2)
	var w8 := player.add_weapon(_gl.registry.get_weapon(&"W8_orbit_field"))
	_check("夹具：W8 装入成功", w8 != null and gen._player_holds_weapon(player, &"W8_orbit_field"))
	var mech_with: Array[StringName] = gen._trait_candidates("MECH", player, [])
	_check("持 W8：MECH 候选含 MEC_ORBIT_LINK", mech_with.has(&"MEC_ORBIT_LINK"))
	# 同批去重仍生效（picked 过滤优先级不变）
	var mech_picked: Array[StringName] = gen._trait_candidates("MECH", player,
		[&"MEC_ORBIT_LINK"] as Array[StringName])
	_check("持 W8：同批去重仍过滤 MEC_ORBIT_LINK", not mech_picked.has(&"MEC_ORBIT_LINK"))
	# apply 防御：卸下 W8 后 apply 门槛词条 → 主武器栈不变（候选漏网路径的最后一道闸）
	var primary: WeaponBase = null
	for i in range(player.weapon_slots.size()):
		if player.weapon_slots[i] is WeaponBase and (player.weapon_slots[i] as WeaponBase).data.id == &"W8_orbit_field":
			primary = player.weapon_slots[i]
			player.weapon_slots[i] = null
	if primary != null and is_instance_valid(primary):
		primary.free()
	var host: WeaponBase = player.weapon_slots[0]
	var stack0: int = host.trait_stack.size()
	gen.apply_choice({"kind": CardGenerator.CardKind.TRAIT, "id": &"MEC_ORBIT_LINK",
		"rarity": 1, "data": orbit, "display_name": "t", "description": ""}, player)
	_check("apply 防御：无 W8 时门槛词条拒绝挂载（栈不变）",
		host.trait_stack.size() == stack0)
	# 反向：持 W8 时 apply 正常挂载
	var w8b := player.add_weapon(_gl.registry.get_weapon(&"W8_orbit_field"))
	gen.apply_choice({"kind": CardGenerator.CardKind.TRAIT, "id": &"MEC_ORBIT_LINK",
		"rarity": 1, "data": orbit, "display_name": "t", "description": ""}, player)
	_check("持 W8：apply 正常挂载（任一武器栈 +1）",
		w8b != null and (host.trait_stack.size() == stack0 + 1
			or (w8b.trait_stack.size() == 1
				and w8b.trait_stack.traits[0].data.id == &"MEC_ORBIT_LINK")),
		"host=%d w8b=%s" % [host.trait_stack.size(), str(w8b != null)])
	# 卸下 W8（还原夹具，不影响后续用例）；W1 词条栈清空还原（初始无词条）
	for i in range(player.weapon_slots.size()):
		var w: WeaponBase = player.weapon_slots[i]
		if w is WeaponBase and (w as WeaponBase).data.id == &"W8_orbit_field":
			player.weapon_slots[i] = null
			if is_instance_valid(w):
				w.free()
	player.weapon_slots[0].trait_stack.clear()


# ── T4：金币词条数据 + 校验器扩项 ────────────────────────────────
func _test_gold_trait_data() -> void:
	print("── T4 金币词条数据/校验器 ──")
	var reg := _gl.registry
	var drop := reg.get_trait(&"AFF_GOLD_DROP")
	var value := reg.get_trait(&"AFF_GOLD_VALUE")
	_check("AFF_GOLD_DROP 注册加载（id/pool/pool_id）",
		drop != null and drop.pool == GameConst.PoolClass.ADD and drop.pool_id == &"add_gold_drop")
	_check("AFF_GOLD_DROP 数值（A4 §4：0.08/层 ×3 蓝 δ0.85）",
		is_equal_approx(drop.value, 0.08) and drop.stack_max == 3
		and drop.rarity == 1 and is_equal_approx(drop.decay_delta, 0.85))
	_check("AFF_GOLD_VALUE 注册加载（id/pool/pool_id）",
		value != null and value.pool == GameConst.PoolClass.ADD and value.pool_id == &"add_gold_value")
	_check("AFF_GOLD_VALUE 数值（A4 §4：0.15/层 ×3 紫 δ0.85）",
		is_equal_approx(value.value, 0.15) and value.stack_max == 3
		and value.rarity == 2 and is_equal_approx(value.decay_delta, 0.85))
	_check("金币词条 effect_id=EF_STAT（外观占位，GameLoop 侧聚合消费）",
		drop.effect_id == &"EF_STAT" and value.effect_id == &"EF_STAT")
	# 校验器封闭注册表扩项（不得入 LINEAR_ADD_POOLS——走 F3 衰减）
	var v := DataValidator.new()
	_check("ADD_POOL_IDS 含 add_gold_drop / add_gold_value",
		DataValidator.ADD_POOL_IDS.has(&"add_gold_drop")
		and DataValidator.ADD_POOL_IDS.has(&"add_gold_value"))
	_check("金币两池不入 LINEAR_ADD_POOLS（F3 衰减）",
		not TraitStack.LINEAR_ADD_POOLS.has(&"add_gold_drop")
		and not TraitStack.LINEAR_ADD_POOLS.has(&"add_gold_value"))
	_check("validate_trait：金币词条 0 错误",
		v.validate_trait(drop).is_empty() and v.validate_trait(value).is_empty())
	# gold_drop 结构校验（warning 级）
	var e := EnemyData.new()
	e.id = &"E_TEST"
	e.hp_base = 10.0
	e.tp_cost = 1.0
	_check("gold_drop 空段：无告警（合法不掉金）", v.validate_enemy(e).is_empty())
	e.gold_drop = {"chance": 1.5, "min": 8, "max": 12}
	var w_bad: Array = v.validate_enemy(e)
	_check("gold_drop.chance > 1 → warning", _has_warning_field(w_bad, "gold_drop.chance"))
	e.gold_drop = {"chance": 0.5, "min": 12, "max": 8}
	_check("gold_drop.min > max → warning", _has_warning_field(v.validate_enemy(e), "gold_drop.min"))
	e.gold_drop = {"chance": 0.06, "min": 8, "max": 12}
	_check("gold_drop 合法段：无告警", v.validate_enemy(e).is_empty())
	_check("registry 既有敌表 gold_drop 全部 0 告警", _registry_gold_warnings_zero(v, reg))


func _has_warning_field(p_verdicts: Array, p_field: String) -> bool:
	for e in p_verdicts:
		if String(e.get("field", "")) == p_field and String(e.get("severity", "")) == DataValidator.SEV_WARNING:
			return true
	return false


func _registry_gold_warnings_zero(p_v: DataValidator, p_reg: DataRegistry) -> bool:
	for id in p_reg.enemies:
		if not p_v.validate_enemy(p_reg.enemies[id]).is_empty():
			return false
	return true


# ── T3：金币链路（掉落可复现 / 满池合并守恒 / 吸收入账 / restart 归零 / chance 抽样） ──
func _test_gold_chain() -> void:
	print("── T3 金币链路 ──")
	_gl.start_run()
	var player := _gl.player
	var pool: GoldPool = _gl.pools[&"gold"]
	# 夹具：必掉敌（内存构造，chance=1.0 min=8 max=12——pkg4 _make_enemy 口径）
	var data := EnemyData.new()
	data.id = &"E_GOLD_TEST"
	data.hp_base = 60.0
	data.spd_base = 80.0
	data.dmg_base = 8.0
	data.exp_base = 3.0
	data.tp_cost = 1.0
	data.hitbox_r = 14.0
	data.gold_drop = {"chance": 1.0, "min": 8, "max": 12}
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire() as Enemy
	enemy.spawn(data, 1, 0)
	# ① chance=1.0 必掉且面值 ∈ [min,max]（无词条加成；定种子锚定后续精确比对）
	_gl.set_gold_rng_seed(20260831)
	var gold0: int = _gl.gold
	_gl._on_enemy_killed_drop_gold(enemy)
	var base_val: int = _gl.active_coins[_gl.active_coins.size() - 1].value
	_check("chance=1.0 必掉 1 枚", _gl.active_coins.size() == 1)
	_check("面值 ∈ [min,max]（8~12，无加成）", base_val >= 8 and base_val <= 12, "base=%d" % base_val)
	# ② 定种子复现：清场 → 同种子重放 60 次 → 掉落总额一致
	_gl.set_gold_rng_seed(777)
	_release_all_coins(pool)
	for i in range(60):
		enemy.global_position = Vector2(100.0 + 5.0 * float(i), 100.0)
		_gl._on_enemy_killed_drop_gold(enemy)
	var sum_a := _coins_total_value()
	_gl.set_gold_rng_seed(777)
	_release_all_coins(pool)
	for i in range(60):
		enemy.global_position = Vector2(100.0 + 5.0 * float(i), 100.0)
		_gl._on_enemy_killed_drop_gold(enemy)
	var sum_b := _coins_total_value()
	_check("定种子 60 次击杀掉落总额可复现（两轮同种子同总额）", sum_a == sum_b and sum_a > 0,
		"a=%d b=%d" % [sum_a, sum_b])
	# ③ 满池合并守恒：先摆 3 枚 → 排空空闲栈 → 第 4 枚走合并进首枚，面值和守恒
	_release_all_coins(pool)
	var vals := [10, 20, 30]
	for i in range(vals.size()):
		_gl._spawn_gold_coin(Vector2(200.0 + 20.0 * float(i), 200.0), vals[i])
	var hoard := _drain_pool(pool)               # 排空空闲栈（满池口径）
	_gl._spawn_gold_coin(Vector2(300.0, 200.0), 7)   # 满池 → merge 进 active_coins[0]
	var merged_sum := 0
	for c: GoldCoin in _gl.active_coins:
		merged_sum += c.value
	_check("满池合并数值守恒（10+20+30+7=67）", merged_sum == 67, "sum=%d" % merged_sum)
	_check("满池合并落在首枚（active 仍 3 枚，首枚=17）", _gl.active_coins.size() == 3
		and _gl.active_coins[0].value == 17)
	_release_all_coins(pool)
	_release_hoard(pool, hoard)
	# ④ 吸收入账：金币置于玩家位置 → 帧序② tick → _add_gold → HUD displayed_gold
	_gl._spawn_gold_coin(player.global_position, 25)
	_gl._tick_gold_coins(DT)
	_check("吸收入账：余额 +25 且场上清空", _gl.gold == gold0 + 25 and _gl.active_coins.is_empty(),
		"gold=%d gold0=%d" % [_gl.gold, gold0])
	_check("吸收入账：HUD displayed_gold 同步（gold_changed）",
		_gl.hud.displayed_gold() == gold0 + 25)
	# ⑤ 面值词条加成：同种子下 base 精确比对（1 层 AFF_GOLD_VALUE → amount = round(base × 1.15)）
	_gl.set_gold_rng_seed(20260831)
	_gl._on_enemy_killed_drop_gold(enemy)        # 无加成基准（与 ① 同种子同 base）
	_release_all_coins(pool)
	var host: WeaponBase = player.weapon_slots[0]
	host.attach_trait(_gl.registry.get_trait(&"AFF_GOLD_VALUE"))
	_gl.set_gold_rng_seed(20260831)
	_gl._on_enemy_killed_drop_gold(enemy)        # 有加成（consume 同一 roll 序列）
	var buffed: int = _gl.active_coins[_gl.active_coins.size() - 1].value
	host.trait_stack.clear()                     # 还原（W1 初始无词条）
	_check("面值词条 1 层：amount = round(base × 1.15)",
		buffed == int(round(float(base_val) * 1.15)), "buffed=%d base=%d" % [buffed, base_val])
	_check("夹具还原：主武器栈清空", host.trait_stack.size() == 0)
	# ⑥ 空段/零面值 guard
	enemy.data.gold_drop = {}
	var coins_before: int = _gl.active_coins.size()
	_gl._on_enemy_killed_drop_gold(enemy)
	_check("gold_drop 空段：不掉落", _gl.active_coins.size() == coins_before)
	enemy.data.gold_drop = {"chance": 1.0, "min": 0, "max": 0}
	_gl._on_enemy_killed_drop_gold(enemy)
	_check("零面值 guard：不掉落", _gl.active_coins.size() == coins_before)
	# ⑦ restart 归零：余额/场上金币全清 + HUD 同步
	enemy.data.gold_drop = {"chance": 1.0, "min": 8, "max": 12}
	for i in range(5):
		_gl._spawn_gold_coin(Vector2(400.0, 400.0), 5)
	_gl._add_gold(99)
	_gl.change_state(GameConst.GameStatus.GAME_OVER)
	_check("restart 前置：进入 GAME_OVER", _gl.state == GameConst.GameStatus.GAME_OVER)
	_gl.restart_run()
	_check("restart：金币余额归零", _gl.gold == 0)
	_check("restart：场上金币清空", _gl.active_coins.is_empty())
	_check("restart：HUD displayed_gold 归零", _gl.hud.displayed_gold() == 0)
	# 清理：场上金币归还 + 探针敌归还（死亡路径口径，触发池归还清零）
	_release_all_coins(pool)
	if not enemy.dead:
		enemy.hp = 0.0
		enemy.dead = true
		(_gl.pools[&"enemy"] as EnemyPool).release(enemy)


func _coins_total_value() -> int:
	var total := 0
	for c: GoldCoin in _gl.active_coins:
		total += c.value
	return total


func _release_all_coins(p_pool: GoldPool) -> void:
	# 场上金币全量归还（非战斗语义清理——与 GameLoop._reset_run_state 同口径的测试侧工具）
	for coin in _gl.active_coins:
		if is_instance_valid(coin):
			p_pool.release(coin)
	_gl.active_coins.clear()


func _drain_pool(p_pool: GoldPool) -> Array[GoldCoin]:
	# 排空空闲栈（满池口径构造）；取出的实例由 _release_hoard 归还
	var hoard: Array[GoldCoin] = []
	while true:
		var c := p_pool.acquire()
		if c == null:
			break
		hoard.append(c)
	return hoard


func _release_hoard(p_pool: GoldPool, p_hoard: Array[GoldCoin]) -> void:
	for c in p_hoard:
		if is_instance_valid(c):
			p_pool.release(c)


# ── T5：武器卡（候选门控 / 权重三处同值 / apply / 商店防混入） ──────
func _test_weapon_cards() -> void:
	print("── T5 武器卡 ──")
	var gen := _gl.card_generator
	var player := _gl.player
	# ① 权重表三处同值 + 和 = 100.0（精确断言，浮点容差 1e-6；A4 §5）
	var weight_sum := 0.0
	for k in CardGenerator.CATEGORY_WEIGHTS:
		weight_sum += float(CardGenerator.CATEGORY_WEIGHTS[k])
	_check("CATEGORY_WEIGHTS 权重和 = 100.0（±1e-6）", absf(weight_sum - 100.0) <= 1e-6,
		"sum=%s" % str(weight_sum))
	var bt_default := BalanceTables.new()
	_check("三处同值①：CardGenerator.CATEGORY_WEIGHTS == BalanceTables 默认",
		_weights_same(CardGenerator.CATEGORY_WEIGHTS, bt_default.category_weights))
	_check("三处同值②：CardGenerator.CATEGORY_WEIGHTS == balance_tables.tres",
		_weights_same(CardGenerator.CATEGORY_WEIGHTS, GameConfig.balance.category_weights))
	_check("三处同值③：运行时镜像（gen.category_weights）同步",
		_weights_same(CardGenerator.CATEGORY_WEIGHTS, gen.category_weights))
	# ② 满槽（1 解锁槽被 W1 占）→ 武器候选池空
	_check("夹具：仅 W1 在手 / 解锁槽 1", player.unlocked_slots == 1
		and player.weapon_slots[0] != null and player.weapon_slots[1] == null)
	_check("满槽 → 武器候选池空（槽位满后不再出现）", gen._weapon_candidates(player, []).is_empty())
	# ③ 仅 W1 在手 + 1 个已解锁空槽 → 候选恰为 W2~W9 全集（8 个，id 升序确定性）
	player.unlock_slot(2)
	var expect: Array[StringName] = [&"W2_gatling", &"W3_shotgun", &"W4_pulse_beam", &"W5_prism",
		&"W6_micro_missile", &"W7_cluster_rocket", &"W8_orbit_field", &"W9_arc_slash"]
	var ids: Array[StringName] = []
	for wd: WeaponData in gen._weapon_candidates(player, []):
		ids.append(wd.id)
	_check("候选恰为 W2~W9 全集（W1 排除）", ids == expect, str(ids))
	# ④ 卡架抽样：无 shop_exclude_weapon 时 WEAPON 卡可达；带键时 200 次零出现
	gen.rng.seed = 99
	var seen_weapon := false
	for i in range(120):
		for c in gen.generate_candidates({"player": player, "wave": 12}):
			if int(c["kind"]) == CardGenerator.CardKind.WEAPON:
				seen_weapon = true
	_check("常规卡架：WEAPON 卡可达（120 次货架抽样）", seen_weapon)
	var seen_excl := false
	for i in range(200):
		for c in gen.generate_candidates({"player": player, "wave": 12, "shop_exclude_weapon": true}):
			if int(c["kind"]) == CardGenerator.CardKind.WEAPON:
				seen_excl = true
	_check("shop_exclude_weapon：200 次卡架 roll 无武器卡（商店防混入）", not seen_excl)
	# ⑤ 已持有不重复：先解锁槽 3（保持有空槽门控）→ 装入 W8 → 候选排除 W8（剩 7 个）+ 同批去重
	player.unlock_slot(3)
	var w8 := player.add_weapon(_gl.registry.get_weapon(&"W8_orbit_field"))
	_check("夹具：W8 装入", w8 != null)
	var held_ids: Array[StringName] = []
	for wd: WeaponData in gen._weapon_candidates(player, []):
		held_ids.append(wd.id)
	_check("已持有 W8 → 候选排除（剩 7 个）", held_ids.size() == 7 and not held_ids.has(&"W8_orbit_field"),
		str(held_ids))
	var picked_ids: Array[StringName] = [&"W3_shotgun"] as Array[StringName]
	_check("同批去重：picked 排除（剩 6 个）", gen._weapon_candidates(player, picked_ids).size() == 6)
	# ⑥ 武器卡形状 + apply：weapon_slots +1（装入 W3 → 3 槽全满）
	var wdata: WeaponData = _gl.registry.get_weapon(&"W3_shotgun")
	var card := gen._make_weapon_card(wdata)
	_check("武器卡形状：kind=WEAPON / rarity=unlock_rarity=1（蓝卡档）/ 名称前缀",
		int(card["kind"]) == CardGenerator.CardKind.WEAPON and int(card["rarity"]) == 1
		and String(card["display_name"]).begins_with("武器："))
	var slots0 := _weapon_count(player)
	gen.apply_choice(card, player)
	_check("apply 后 weapon_slots +1（W3 入手）", _weapon_count(player) == slots0 + 1
		and gen._player_holds_weapon(player, &"W3_shotgun"))
	# ⑦ 满槽 apply 降级：槽满 → fallback 词条挂主武器（界面选择不白拿）
	var primary: WeaponBase = player.weapon_slots[0]
	var stack0: int = primary.trait_stack.size()
	gen.apply_choice(gen._make_weapon_card(_gl.registry.get_weapon(&"W5_prism")), player)
	_check("满槽 apply 降级：主武器栈 +1（fallback 词条）", primary.trait_stack.size() == stack0 + 1)
	# 还原夹具（卸 W3/W8、清主武器栈、解锁槽数回 1——后续用例基线）
	for i in range(player.weapon_slots.size()):
		var w: WeaponBase = player.weapon_slots[i]
		if w is WeaponBase and is_instance_valid(w) \
				and (w.data.id == &"W3_shotgun" or w.data.id == &"W8_orbit_field"):
			player.weapon_slots[i] = null
			w.free()
	primary.trait_stack.clear()
	player.unlocked_slots = 1
	_check("夹具还原：回到仅 W1 / 解锁槽 1",
		_weapon_count(player) == 1 and player.unlocked_slots == 1)


func _weights_same(p_a: Dictionary, p_b: Dictionary) -> bool:
	# 权重表逐键同值比对（键集一致 + 每键 is_equal_approx）
	if p_a.size() != p_b.size():
		return false
	for k in p_a:
		if not p_b.has(k) or not is_equal_approx(float(p_a[k]), float(p_b[k])):
			return false
	return true


func _weapon_count(p_player: Node) -> int:
	var n := 0
	var slots: Array = p_player.get("weapon_slots")
	for w in slots:
		if w is WeaponBase and is_instance_valid(w):
			n += 1
	return n


# ── T2：HUD 布局（layout_rects 不相交 / 横幅时序 / 配色 / 描边） ────
func _test_hud_layout_and_banner() -> void:
	print("── T2 HUD 布局/横幅 ──")
	var hud := _gl.hud
	# ① 顶部信息区矩形两两不相交（金币标签 vs XP 条让位契约——XP 条宽 560）
	var rects := hud.layout_rects()
	_check("layout_rects 数量 = 11（双条 + 六标签 + 诅咒标签 + 冲刺钮×2；v0.8.0 授权更新 8→11）",
		rects.size() == 11, str(rects.size()))
	var disjoint := true
	var bad_pair := ""
	for i in range(rects.size()):
		for j in range(i + 1, rects.size()):
			if rects[i].intersects(rects[j]):
				disjoint = false
				bad_pair = "%d×%d" % [i, j]
	_check("layout_rects 两两 intersects()==false", disjoint, bad_pair)
	_check("XP 条宽 560（金币标签让位，A4 §7）",
		hud.XP_BAR_SIZE == Vector2(560.0, 12.0) and hud.HP_BAR_SIZE == Vector2(600.0, 22.0))
	_check("金币标签色 = Color(1.0,0.83,0.25)",
		hud._gold_label.get_theme_color("font_color") == Color(1.0, 0.83, 0.25))
	_check("全文本描边（outline_size 4 / 黑 0.9）",
		hud._gold_label.get_theme_constant("outline_size") == 4
		and hud._build_label.get_theme_color("font_outline_color") == Color(0.0, 0.0, 0.0, 0.9))
	# ② 经验碎片配色让位（青蓝）+ 金币亮金
	_check("SHARD_COLOR = 青蓝（金色让位金币）", XpShard.SHARD_COLOR == Color(0.35, 0.8, 1.0))
	_check("COIN_COLOR = 亮金", GoldCoin.COIN_COLOR == Color(1.0, 0.78, 0.15))
	# ③ 跳字 CRIT 描边（其余样式 outline 0）
	var pm := _gl.popup_manager
	pm.tick(10.0)                                  # 清场
	var rc := DamageResult.new()
	rc.final_value = 9.0
	rc.target_uid = 7001
	rc.pos = Vector2(100, 100)
	rc.popup_style = GameConst.PopupStyle.CRIT
	pm.on_damage_resolved(rc)
	var crit_popup: DamagePopup = pm._active_list[0]
	_check("跳字 CRIT：outline_size 4 + 黑描边",
		crit_popup._label.get_theme_constant("outline_size") == 4
		and crit_popup._label.get_theme_color("font_outline_color") == Color(0.0, 0.0, 0.0, 0.9))
	var rn := DamageResult.new()
	rn.final_value = 3.0
	rn.target_uid = 7002
	rn.pos = Vector2(120, 100)
	rn.popup_style = GameConst.PopupStyle.NORMAL
	pm.on_damage_resolved(rn)
	var normal_popup: DamagePopup = pm._active_list[1]
	_check("跳字 NORMAL：outline 0", normal_popup._label.get_theme_constant("outline_size") == 0)
	pm.tick(10.0)
	# ④ 横幅 2.0s 三段时序（@120Hz 帧数分段断言：30 / 180 / 30 帧，±2 帧容差）
	EventBus.emit_wave_started(7)
	_check("wave_started → 横幅 WAVE 7", hud.banner_visible() and hud._banner_label.text == "WAVE 7")
	_check("横幅初值：alpha≈0 / y=442",
		hud._banner_label.modulate.a <= 0.05
		and absf(hud._banner_label.position.y - 442.0) <= 0.5)
	for i in range(15):                            # t=0.125s：淡入中段
		hud.tick(DT)
	_check("淡入中段（15 帧）：alpha≈0.5 / y≈436",
		absf(hud._banner_label.modulate.a - 0.5) <= 0.1
		and absf(hud._banner_label.position.y - 436.0) <= 1.0,
		"a=%s y=%s" % [str(hud._banner_label.modulate.a), str(hud._banner_label.position.y)])
	for i in range(15):                            # t=0.25s：淡入完成
		hud.tick(DT)
	_check("淡入完成（30 帧）：alpha≈1 / y=430",
		hud._banner_label.modulate.a >= 0.95
		and absf(hud._banner_label.position.y - 430.0) <= 0.5)
	for i in range(180):                           # t=1.75s：保持段结束
		hud.tick(DT)
	_check("保持段（至 210 帧）：可见且 alpha=1",
		hud.banner_visible() and hud._banner_label.modulate.a >= 0.99)
	for i in range(24):                            # t=1.95s：淡出中段
		hud.tick(DT)
	_check("淡出中段（234 帧）：alpha∈(0,1)", hud.banner_visible()
		and hud._banner_label.modulate.a > 0.0 and hud._banner_label.modulate.a < 1.0)
	for i in range(10):                            # t≥2.0s：收起
		hud.tick(DT)
	_check("2.0s 到时收起（banner_visible()==false）", not hud.banner_visible()
		and not hud._banner_label.visible)


# ── T6：商店（状态机 / w9 间隙触发 / 零推进 / 购买 / utility / 黑市 / 单间隙单店） ──
func _test_shop() -> void:
	print("── T6 商店 ──")
	var gen := _gl.card_generator
	var wd := _gl.wave_director
	var player := _gl.player
	var shop := _gl.shop_ui
	_gl.start_run()
	# ① w9 清空 → BUFFER 尽 → shop_requested(9,false) → 开店（真波表 w9 events=[SHOP]）
	wd.start_wave(9)
	wd.window_left = 0.001
	wd.tick(DT)
	while not wd.spawner.queue_empty():
		wd.tick(DT)                               # 节流出队至队列排空
	for e in wd.spawner.active.duplicate():
		wd.spawner.on_enemy_killed(e)             # 静默清场（非战斗语义，同 _clear_battlefield）
	wd.tick(DT)                                   # 清空检测 → wave_cleared(9) → BUFFER
	_check("w9 清空 → BUFFER 相位", wd._phase == WaveDirector.WavePhase.BUFFER
		and wd.current_wave == 9)
	wd.buffer_left = 0.001
	wd.tick(DT)                                   # 间隙尽 → 商店门控（当前波刚清空）
	_check("w9 间隙尽 → PLAYING→SHOP + 界面打开（black_market=false）",
		_gl.state == GameConst.GameStatus.SHOP and shop.is_open
		and not bool(shop.shelf_state()["black_market"])
		and int(shop.shelf_state()["wave"]) == 9)
	_check("商店卡架 3 张（无武器卡混入——shop_exclude_weapon）",
		(shop.shelf_state()["cards"] as Array).size() == 3)
	# ② 状态机：SHOP→PAUSED 拒绝（rejected_transitions 计数）
	var rej0: int = _gl.rejected_transitions
	_check("非法迁移拒绝：SHOP→PAUSED", not _gl.change_state(GameConst.GameStatus.PAUSED)
		and _gl.rejected_transitions == rej0 + 1 and _gl.state == GameConst.GameStatus.SHOP)
	# ③ SHOP 期 wave_director 零推进（帧序仅⑦⑧ + buffer 冻结）
	var buffer_snap: float = wd.buffer_left
	for i in range(10):
		_gl._physics_process(DT)
	_check("SHOP 期 wave_director 零推进（buffer 冻结 / 波号不变 / 帧序仅⑦⑧）",
		is_equal_approx(wd.buffer_left, buffer_snap) and wd.current_wave == 9
		and _gl.frame_order == ([&"feel", &"ui"] as Array[StringName]))
	# ④ SHOP→GAME_OVER 合法（死亡结算可达）→ 回 PLAYING 重走
	_gl.change_state(GameConst.GameStatus.GAME_OVER)
	_check("SHOP→GAME_OVER 合法（迁移矩阵）", _gl.state == GameConst.GameStatus.GAME_OVER)
	_gl.change_state(GameConst.GameStatus.PLAYING)
	# ⑤ 闭店 → 下帧 start_wave(10)（验收口径：闭店后 wave_started(10)）
	wd.buffer_left = 0.001
	_gl._close_shop()
	_check("闭店 → SHOP→PLAYING + 界面收起", _gl.state == GameConst.GameStatus.PLAYING
		and not shop.is_open)
	wd.tick(DT)
	_check("闭店后下一波 start_wave(10)（wave_started(10)）",
		wd.current_wave == 10 and _gl.hud.displayed_wave() == 10)
	wd.spawner.spawn_queue.clear()                # w10 Boss 入队清掉（不实刷）
	# ⑥ 购买仲裁（crafted 货架，确定性定价）：扣款 + apply
	player.unlock_slot(2)
	var cards: Array[Dictionary] = [
		gen._make_trait_card(&"AFF_HP_UP", 9),
		gen._make_trait_card(&"AFF_ATK_UP", 9),
		gen._fallback_stat_card(),
	]
	cards[0]["rarity"] = 1                        # 定价锁定：70
	cards[1]["rarity"] = 1
	var weapon_card := gen._make_weapon_card(_gl.registry.get_weapon(&"W6_micro_missile"))
	shop.open(9, false, cards, weapon_card, _gl.gold)
	_gl.change_state(GameConst.GameStatus.SHOP)
	_gl._add_gold(500)
	var gold0: int = _gl.gold
	var price0 := shop.price_for(0)
	_check("卡架定价（rarity 1 → 70，A4 §2）", price0 == 70, str(price0))
	var layers0 := _total_trait_layers(player)
	_gl._on_shop_purchase(0)
	_check("购买卡架 0：扣款 70 + 词条生效（层数 +1）",
		_gl.gold == gold0 - 70 and _total_trait_layers(player) == layers0 + 1)
	_check("购买后单次购买位（disabled + 已购标记）", bool(shop.shelf_state()["purchased"][0]))
	# 余额不足拒绝（index 1）
	_gl._add_gold(-(_gl.gold - 10))
	var gold_low: int = _gl.gold
	var layers_low := _total_trait_layers(player)
	_gl._on_shop_purchase(1)
	_check("余额不足：静默拒绝不扣款（余额/层数不变）",
		_gl.gold == gold_low and _total_trait_layers(player) == layers_low
		and not bool(shop.shelf_state()["purchased"][1]))
	# 重复购买拒绝
	_gl._add_gold(400)
	var gold_rep: int = _gl.gold
	_gl._on_shop_purchase(0)
	_check("重复购买拒绝（不重复扣款）", _gl.gold == gold_rep)
	# 武器架：门控成立（空槽 2）→ 扣 100 + W6 入手
	var slots0 := _weapon_count(player)
	_gl._on_shop_purchase(3)
	_check("武器架购买：扣 100 + weapon_slots +1（W6 入手）",
		_gl.gold == gold_rep - ShopUI.WEAPON_PRICE and _weapon_count(player) == slots0 + 1
		and gen._player_holds_weapon(player, &"W6_micro_missile"))
	# ⑦ utility：maxhp 每店限 1 / heal / reroll
	var maxhp0: float = player.max_hp
	_gl._on_shop_utility(&"maxhp")
	_check("max_hp+10：扣 80 + max_hp +10", _gl.gold == gold_rep - 180
		and is_equal_approx(player.max_hp, maxhp0 + 10.0))
	var gold_m: int = _gl.gold
	_gl._on_shop_utility(&"maxhp")
	_check("max_hp+10 每店限 1：第二次拒绝", _gl.gold == gold_m
		and is_equal_approx(player.max_hp, maxhp0 + 10.0))
	player.hp = 10.0
	_gl._add_gold(200)
	var gold_h: int = _gl.gold
	_gl._on_shop_utility(&"heal")
	_check("回复 30%max_hp：扣 50 + HP 回复（10 + 0.3×max）",
		_gl.gold == gold_h - 50
		and is_equal_approx(player.hp, minf(10.0 + (maxhp0 + 10.0) * 0.3, maxhp0 + 10.0)))
	var gold_r: int = _gl.gold
	var reroll_shelf: Array = shop.shelf_state()["cards"]
	_gl._on_shop_utility(&"reroll")
	_check("重随券：扣 30 + 货架更换 + 限购位",
		_gl.gold == gold_r - 30 and bool(shop.shelf_state()["reroll_used"])
		and not (shop.shelf_state()["cards"] as Array).is_empty()
		and (shop.shelf_state()["cards"] as Array) != reroll_shelf)
	var gold_r2: int = _gl.gold
	_gl._on_shop_utility(&"reroll")
	_check("重随券每店限 1：第二次拒绝", _gl.gold == gold_r2)
	_gl._close_shop()
	# ⑧ 黑市桥接：relic pending → queue_extra_shop → 间隙 black=true → 金卡价 260
	_gl.relic_handler.pending_shop_waves = 1
	EventBus.emit_wave_cleared(35)
	_check("黑市桥接：w35 清空 → pending 消费 + queue_extra_shop 生效",
		wd._extra_shop_pending and _gl.relic_handler.pending_shop_waves == 0)
	# 黑市货架：金卡价 260（非黑市 220 对照）
	var gold_card := gen._make_trait_card(&"AFF_AREA", 30)
	gold_card["rarity"] = 3
	var black_cards: Array[Dictionary] = [gold_card, gen._fallback_stat_card(),
		gen._fallback_stat_card()]
	shop.open(39, true, black_cards, {}, 500)
	_check("黑市金卡价 260（A4 §2）", shop.price_for(0) == ShopUI.CARD_PRICE_BLACK_GOLD)
	shop.open(39, false, black_cards, {}, 500)
	_check("非黑市金卡价 220（对照）", shop.price_for(0) == 220)
	shop.close()
	wd._extra_shop_pending = false
	# ⑨ 单间隙单店（独立 WaveDirector 环境：常规+黑市同波仅一次开门）
	_test_shop_single_gap()
	# 无尽段回退规则：无表项波 w%10==9
	_check("无尽段商店回退规则：39 开 / 38 不开（无表项）",
		wd._is_shop_wave(39) and not wd._is_shop_wave(38))
	# 还原夹具
	for i in range(player.weapon_slots.size()):
		var w: WeaponBase = player.weapon_slots[i]
		if w is WeaponBase and is_instance_valid(w) \
				and (w.data.id == &"W6_micro_missile"):
			player.weapon_slots[i] = null
			w.free()
	player.unlocked_slots = 2
	player.max_hp = maxhp0
	wd._shop_gapped = false


func _test_shop_single_gap() -> void:
	# 独立 WaveDirector（pkg4 escort 环境模式）：内存波表 w1=[SHOP,1 只 E1] → 清空 → 间隙 →
	# 恰一次 shop_requested（黑市 pending 同波不双开）→ 下一波推进
	var registry := DataRegistry.new()
	registry.enemies[&"E1"] = _make_shop_env_enemy(&"E1")
	var table := WaveTableData.new()
	var w1 := WaveEntryData.new()
	w1.index = 1
	w1.composition = [{"enemy_id": &"E1", "count": 1}]
	w1.events = [&"SHOP"]
	table.entries = [w1]
	var pool := EnemyPool.new()
	pool.name = "ShopGapPool"
	tree.get_root().add_child(pool)
	pool.setup(&"enemy_shopgap", load("res://scenes/combat/enemies/enemy.tscn"), 8)
	var spawner := EnemySpawner.new()
	spawner.name = "ShopGapSpawner"
	tree.get_root().add_child(spawner)
	spawner.pool = pool
	spawner.registry = registry
	var director := WaveDirector.new()
	director.name = "ShopGapDirector"
	tree.get_root().add_child(director)
	director.spawner = spawner
	director.registry = registry
	director.wave_table = table
	var requests: Array = []
	director.shop_requested.connect(func(w: int, b: bool) -> void: requests.append([w, b]))
	director.queue_extra_shop()                   # 黑市 pending 同波注入
	director.start_wave(1)
	director.window_left = 0.001
	director.tick(DT)                             # 出队 1 只
	for e in spawner.active.duplicate():
		spawner.on_enemy_killed(e)
	director.tick(DT)                             # 清空 → BUFFER
	director.buffer_left = 0.001
	director.tick(DT)                             # 间隙尽 → 开店（black=true）
	_check("单间隙单店：恰一次 shop_requested(1, black=true)",
		requests.size() == 1 and (requests[0] as Array)[0] == 1
		and bool((requests[0] as Array)[1]))
	director.tick(DT)                             # 闭店语义后：_shop_gapped 闸 → 直推下一波
	_check("同间隙不双开（第二 tick 推进到 w2）",
		director.current_wave == 2 and requests.size() == 1)
	director.free()
	spawner.free()
	pool.free()


func _make_shop_env_enemy(p_id: StringName) -> EnemyData:
	var e := EnemyData.new()
	e.id = p_id
	e.display_name = String(p_id)
	e.behavior = GameConst.EnemyBehavior.CHASE
	e.hp_base = 60.0
	e.spd_base = 80.0
	e.dmg_base = 8.0
	e.exp_base = 3.0
	e.tp_cost = 1.0
	e.hitbox_r = 14.0
	return e


func _total_trait_layers(p_player: Node) -> int:
	var total := 0
	var slots: Array = p_player.get("weapon_slots")
	for w in slots:
		if w is WeaponBase and is_instance_valid(w) and (w as WeaponBase).trait_stack != null:
			total += (w as WeaponBase).trait_stack.size()
	return total


# ── T7：Boss 弹幕三形态 + 召唤（节奏 / P2 / 敌弹伤害 / split / 停射 / wave_cleared 可达） ──
func _test_boss_patterns() -> void:
	print("── T7 Boss 弹幕 ──")
	var proj_pool: ProjectilePool = _gl.pools[&"projectile"]
	var player := _gl.player
	player.global_position = Vector2(360.0, 1100.0)
	player.invuln_left = 0.0
	player.hp = player.max_hp                     # 夹具满血（T6 heal 残留隔离）
	_release_enemy_bullets(proj_pool)
	# ① boss1 fan：P1 单轮 8 发（开场半冷却 3s 快照）+ 发射后 6s 节奏
	var boss1: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire() as Enemy
	boss1.spawn(_gl.registry.get_enemy(&"E6_boss1"), 10, GameConst.TAG_BOSS)
	boss1.position = Vector2(360.0, 200.0)
	boss1.summon_spawner = _gl.spawner
	boss1.projectile_pool = _gl.pools[&"projectile"]   # 手动取出：注入敌弹池（spawner.tick 同款）
	_check("夹具：boss1 快照（fan/6s/8 发/半冷却 3s）",
		String(boss1._boss_pattern.get("pattern")) == "fan"
		and is_equal_approx(float(boss1._boss_pattern.get("interval_s")), 6.0)
		and int(boss1._boss_pattern.get("count")) == 8
		and is_equal_approx(boss1._pattern_cd_left, 3.0))
	boss1._pattern_cd_left = DT
	boss1.tick(DT)
	_check("boss1 P1 fan 单轮 8 发", _enemy_bullet_count(proj_pool) == 8)
	var fired_at := 0
	for i in range(800):
		boss1.tick(DT)
		if _enemy_bullet_count(proj_pool) >= 16:
			fired_at = i + 1
			break
	_check("boss1 6s 节奏：第二轮恰在 +720 帧 ±2", absi(fired_at - 720) <= 2,
		"fired_at=%d" % fired_at)
	# ② boss1 P2：count_phase2 → 12 发
	boss1.boss_phase = 2
	_release_enemy_bullets(proj_pool)
	boss1._pattern_cd_left = DT
	boss1.tick(DT)
	_check("boss1 P2 fan 单轮 12 发（count_phase2，A4 §7）",
		_enemy_bullet_count(proj_pool) == 12)
	_release_enemy_bullets(proj_pool)
	# ③ 敌弹 team=1 伤害：pattern dmg → take_contact_damage 单点（player +x 方向 100px）
	player.global_position = boss1.global_position + Vector2(100.0, 0.0)
	player.invuln_left = 0.0
	var hp0: float = player.hp
	boss1._fire_boss_bullet(0.0, 300.0, 12.0)
	_check("夹具：敌弹 1 发 + 朝向玩家", _enemy_bullet_count(proj_pool) == 1)
	var bullet: ProjectileBase = null
	for proj in proj_pool.active_projectiles():
		if proj is ProjectileBase and (proj as ProjectileBase).team == 1:
			bullet = proj
	var frames := 0
	while bullet != null and is_instance_valid(bullet) and frames < 120:
		bullet.tick(DT)                           # 单弹直驱（team=1 路径免网格）
		frames += 1
		if not is_instance_valid(bullet) or not bullet._live:
			break                                 # 回收完成（_recycle 置 _live=false）
	_check("敌弹命中玩家：扣血 = pattern dmg 12（单点，双落血防线）",
		is_equal_approx(player.hp, hp0 - 12.0), "hp=%s" % str(player.hp))
	_check("敌弹命中后回收（pool 循环）", _enemy_bullet_count(proj_pool) == 0)
	# ④ boss2 ring 16 发 + P2 弹速 ×1.4 + split 召唤 hp_override
	var boss2: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire() as Enemy
	boss2.spawn(_gl.registry.get_enemy(&"E6_boss2"), 20, GameConst.TAG_BOSS)
	boss2.position = Vector2(360.0, 200.0)
	boss2.summon_spawner = _gl.spawner
	boss2.projectile_pool = _gl.pools[&"projectile"]   # 手动取出：注入敌弹池（spawner.tick 同款）
	boss2._pattern_cd_left = DT
	boss2.tick(DT)
	_check("boss2 P1 ring 单轮 16 发 + 弹速 300", _enemy_bullet_count(proj_pool) == 16
		and _enemy_bullet_speed(proj_pool) > 0.0
		and is_equal_approx(_enemy_bullet_speed(proj_pool), 300.0))
	boss2.boss_phase = 2
	_release_enemy_bullets(proj_pool)
	boss2._pattern_cd_left = DT
	boss2.tick(DT)
	_check("boss2 P2 弹速 ×1.4（speed_mult_phase2=420）",
		_enemy_bullet_count(proj_pool) == 16
		and is_equal_approx(_enemy_bullet_speed(proj_pool), 420.0))
	_release_enemy_bullets(proj_pool)
	# split 召唤（P1，count 2）：hp_override = boss max_hp × 0.08
	boss2.boss_phase = 1                          # 还原 P1（P2 时 count_phase2=3）
	var queue0: int = _gl.spawner.queue_count()
	boss2._summon_cd_left = DT
	boss2.tick(DT)
	_check("boss2 split 召唤入队 2（hp_override = max_hp × 0.08）",
		_gl.spawner.queue_count() == queue0 + 2)
	var override_expected: float = boss2.max_hp * 0.08
	_gl.spawner.tick(DT, _gl.enemy_grid)          # 出队 → spawn 消费 hp_override
	var split_hit := 0
	for e in _gl.spawner.active:
		var enemy := e as Enemy
		if enemy != null and enemy.data != null and enemy.data.id == &"E5_elite" \
				and is_equal_approx(enemy.max_hp, maxf(override_expected, 1.0)):
			split_hit += 1
	_check("hp_override 消费：spawn 后 max_hp = override（±1 下限）", split_hit == 2,
		"hit=%d expect=%s" % [split_hit, str(override_expected)])
	for e in _gl.spawner.active.duplicate():
		var enemy := e as Enemy
		if enemy != null and enemy.data != null and enemy.data.id == &"E5_elite":
			enemy.hp = 0.0
			enemy.dead = true
			_gl.spawner.on_enemy_killed(enemy)    # 静默归还（非战斗语义）
	# ⑤ boss3 spiral 20 发 + 逐轮推进 + P2 分波召唤 6×E4
	var boss3: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire() as Enemy
	boss3.spawn(_gl.registry.get_enemy(&"E6_boss3"), 30, GameConst.TAG_BOSS)
	boss3.position = Vector2(360.0, 300.0)
	boss3.summon_spawner = _gl.spawner
	boss3.projectile_pool = _gl.pools[&"projectile"]   # 手动取出：注入敌弹池（spawner.tick 同款）
	_release_enemy_bullets(proj_pool)
	boss3._pattern_cd_left = DT
	boss3.tick(DT)
	_check("boss3 P1 spiral 单轮 20 发 + 推进角 0.7rad",
		_enemy_bullet_count(proj_pool) == 20 and is_equal_approx(boss3._spiral_offset, 0.7))
	_release_enemy_bullets(proj_pool)
	var queue1: int = _gl.spawner.queue_count()
	boss3._summon_cd_left = DT
	boss3.tick(DT)
	_check("boss3 P1 召唤分波门拦截（phase 2 > boss_phase 1）",
		_gl.spawner.queue_count() == queue1)
	boss3.boss_phase = 2
	boss3._summon_cd_left = DT
	boss3.tick(DT)
	var e4_rows: int = 0
	var ring_ok := true
	for entry in _gl.spawner.spawn_queue:
		var row: Dictionary = entry
		if StringName(String(row.get("data_id", ""))) == &"E4_volatile":
			e4_rows += 1
			var pos: Vector2 = row.get("pos")
			if absf(pos.distance_to(boss3.global_position) - 90.0) > 0.5:
				ring_ok = false
	_check("boss3 P2 召唤 6×E4（90px 环形均分，无 RNG）", e4_rows == 6 and ring_ok,
		"e4=%d ring=%s" % [e4_rows, str(ring_ok)])
	_gl.spawner.spawn_queue.clear()
	_release_enemy_bullets(proj_pool)
	# ⑥ Boss 死后停射停召（快照清零 + dead 短路）
	boss1.hp = 0.0
	boss1._on_died()                              # enemy_killed → spawner 侧池归还（自动）
	_check("Boss 死亡：快照清零（弹幕/召唤/注入）",
		boss1._boss_pattern.is_empty() and boss1._boss_summons.is_empty()
		and boss1.summon_spawner == null and boss1.dead)
	var bullets_after_death: int = _enemy_bullet_count(proj_pool)
	for i in range(30):
		boss1.tick(DT)                            # dead 短路 → 零发射
	_check("死后停射（弹量不变）", _enemy_bullet_count(proj_pool) == bullets_after_death)
	_release_enemy_bullets(proj_pool)
	# ⑦ Boss 波清尽 → wave_cleared 可达（独立环境：boss 死 → 伴随闸关 → 清空判据）
	_test_boss_wave_clear()
	# 清理：Boss 死亡掉落物（xp 碎片/金币）归还 + 召唤队列清空
	for shard in _gl.active_shards:
		if is_instance_valid(shard):
			(_gl.pools[&"xp"] as XPPool).release(shard)
	_gl.active_shards.clear()
	for coin in _gl.active_coins:
		if is_instance_valid(coin):
			(_gl.pools[&"gold"] as GoldPool).release(coin)
	_gl.active_coins.clear()
	_gl.spawner.spawn_queue.clear()


func _enemy_bullet_count(p_pool: ProjectilePool) -> int:
	var n := 0
	for proj in p_pool.active_projectiles():
		if proj is ProjectileBase and (proj as ProjectileBase).team == 1:
			n += 1
	return n


func _enemy_bullet_speed(p_pool: ProjectilePool) -> float:
	for proj in p_pool.active_projectiles():
		if proj is ProjectileBase and (proj as ProjectileBase).team == 1:
			return (proj as ProjectileBase).velocity.length()
	return -1.0


func _release_enemy_bullets(p_pool: ProjectilePool) -> void:
	for proj in p_pool.active_projectiles().duplicate():
		if proj is ProjectileBase and (proj as ProjectileBase).team == 1:
			p_pool.release(proj)


func _test_boss_wave_clear() -> void:
	# 独立环境（pkg4 escort 模式）：w10 BOSS 波 → Boss 死 → 伴随闸关 → 清空判据 →
	# wave_cleared（BUFFER 相位与缓冲时长为派发证据）
	var registry := DataRegistry.new()
	registry.enemies[&"E1"] = _make_shop_env_enemy(&"E1")
	var boss_data := _make_shop_env_enemy(&"BOSS")
	boss_data.tags = GameConst.TAG_BOSS
	boss_data.tp_cost = 64.0
	registry.enemies[&"BOSS"] = boss_data
	var table := WaveTableData.new()
	var w10 := WaveEntryData.new()
	w10.index = 10
	w10.composition = []                          # Boss 由 _spawn_boss 单一入队（防双 Boss）
	w10.events = [&"BOSS"]
	table.entries = [w10]
	var pool := EnemyPool.new()
	pool.name = "BossClearPool"
	tree.get_root().add_child(pool)
	pool.setup(&"enemy_bossclear", load("res://scenes/combat/enemies/enemy.tscn"), 8)
	var spawner := EnemySpawner.new()
	spawner.name = "BossClearSpawner"
	tree.get_root().add_child(spawner)
	spawner.pool = pool
	spawner.registry = registry
	var director := WaveDirector.new()
	director.name = "BossClearDirector"
	tree.get_root().add_child(director)
	director.spawner = spawner
	director.registry = registry
	director.wave_table = table
	director.start_wave(10)
	director.window_left = 0.001
	director.tick(DT)                             # Boss 出队生成（boss_spawned → 伴随闸开）
	_check("Boss 波：Boss 登场（_boss_seen）", director._boss_seen
		and spawner.active_count() == 1)
	for e in spawner.active.duplicate():
		var boss := e as Enemy
		if boss != null:
			boss.dead = true                      # 静默击杀（不走 enemy_killed——隔离共享订阅）
			spawner.on_enemy_killed(boss)         # active 移除 + 池归还（清空判据口径）
	director.tick(DT)                             # 清空检测 → wave_cleared → BUFFER
	_check("Boss 死后清尽 → wave_cleared 可达（BUFFER 4s 缓冲）",
		director._phase == WaveDirector.WavePhase.BUFFER
		and is_equal_approx(director.buffer_left, 4.0))
	director.free()
	spawner.free()
	pool.free()


# ── 断言 ──────────────────────────────────────────────────────────
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

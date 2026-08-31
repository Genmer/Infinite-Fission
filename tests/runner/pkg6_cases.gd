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
	_check("layout_rects 数量 = 8（双条 + 六标签）", rects.size() == 8, str(rects.size()))
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

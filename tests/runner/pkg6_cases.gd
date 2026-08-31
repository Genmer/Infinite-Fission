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
	# 卸下 W8（还原夹具，不影响后续用例）
	for i in range(player.weapon_slots.size()):
		var w: WeaponBase = player.weapon_slots[i]
		if w is WeaponBase and (w as WeaponBase).data.id == &"W8_orbit_field":
			player.weapon_slots[i] = null
			if is_instance_valid(w):
				w.free()


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

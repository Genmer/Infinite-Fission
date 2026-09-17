# tests/runner/pool_wiring_cases.gd
# 加成生效审计用例体（由 test_pool_wiring.gd 入口加载）。
# 每池口径：注册表内该池真卡 → apply_choice 真挂卡链路 → 同一武器/玩家消费点
# 观测值「挂卡前 vs 挂卡后」变化断言。
# MULT 条件乘区（frost/burn/bounce/pierce/fury/opening/vuln）行为锁定在 pkg3 管线套件。
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _weapons: Array = []                       # 当前武器列表（观测基线容器）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_audit_all_add_pools()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	# 激光武器（cd 型）入列——add_cdr 消费在激光/自导/近战间隔（形态适配门）；
	# 先解锁槽 2（wave1 单槽已满会被 add_weapon 拒绝）
	_gl.player.set("unlocked_slots", 2)
	_gl.player.add_weapon(_gl.registry.get_weapon(&"W4_pulse_beam"))
	for w in _gl.player.get("weapon_slots"):
		if w != null and is_instance_valid(w):
			_weapons.append(w)


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _pool_card_id(p_pool: StringName) -> StringName:
	# 注册表内该池的真卡（上架可能性审计）
	for id in _gl.registry.traits.keys():
		var t: TraitData = _gl.registry.traits[id]
		if t != null and String(t.pool_id) == String(p_pool):
			return id
	return &""


func _weapon_has_pool(p_w: Node, p_pool: StringName) -> bool:
	var ts: Variant = p_w.get("trait_stack")
	if ts == null:
		return false
	if absf(float((ts as Object).call(&"aggregate_panel").get(String(p_pool), 0.0))) > 0.0001:
		return true
	# MECH 池（如 MEC_KNOCK 动能冲击）不进 aggregate_panel——按 pool_id 扫挂载表
	for tb: Variant in (ts as Object).get("traits"):
		var td: Variant = tb.get("data")
		if td != null and String(td.pool_id) == String(p_pool):
			return true
	return false


func _attach_pool_card(p_pool: StringName) -> Node:
	# 真卡 → apply_choice 真挂卡（R18 起挂载侧形态适配门裁定宿主）；
	# 主武器词槽满（≤12）时直挂适配武器兜底——审计聚焦消费点接线而非槽数
	var tid := _pool_card_id(p_pool)
	if tid == &"":
		return null
	var t: TraitData = _gl.registry.get_trait(tid)
	for attempt in range(2):
		var card := {
			"kind": CardGenerator.CardKind.TRAIT, "id": t.id, "rarity": 0,
			"data": t, "value_scale": 1.0,
			"display_name": t.display_name, "description": t.description,
		}
		_gl.card_generator.apply_choice(card, _gl.player)
		for w in _gl.player.get("weapon_slots"):
			if w != null and is_instance_valid(w) and _weapon_has_pool(w, p_pool):
				return w
	# 兜底：直挂仍有词槽的适配武器（_form_allows 同一门）
	for w in _gl.player.get("weapon_slots"):
		if w != null and is_instance_valid(w) \
				and not _weapon_has_pool(w, p_pool) \
				and bool(_gl.card_generator.call("_form_allows", t, w)):
			if bool(w.call("attach_trait", t)) or _weapon_has_pool(w, p_pool):
				return w
	return null


func _obs(p_w: Node, p_kind: String) -> float:
	# 消费点观测值（武器侧）
	match p_kind:
		"interval":
			return float(p_w.call("_fire_interval")) if p_w.has_method("_fire_interval") else 0.0
		"crit":
			return float((p_w.call("build_panel_snapshot") as Dictionary).get("crit_rate", 0.0))
		"crit_mult":
			return float((p_w.call("build_panel_snapshot") as Dictionary).get("crit_mult", 0.0))
		"speed":
			return float(p_w.call("_projectile_speed")) if p_w.has_method("_projectile_speed") else 0.0
		"pellets":
			return float(p_w.call("_pellet_count")) if p_w.has_method("_pellet_count") else 0.0
		"pierce":
			return float(p_w.call("_pierce_count")) if p_w.has_method("_pierce_count") else 0.0
		"knock":
			return float(p_w.call("knockback_force")) if p_w.has_method("knockback_force") else 0.0
	return 0.0


func _audit_weapon(p_name: String, p_pool: StringName, p_kind: String, p_down: bool) -> void:
	# 武器侧审计：同一武器挂卡前 vs 挂卡后（p_down=true = 数值应下降，如间隔/冷却）
	var before := {}
	for w in _weapons:
		before[w] = _obs(w, p_kind)
	var landed: Node = _attach_pool_card(p_pool)
	if landed == null or not before.has(landed):
		_check("审计 %s：真卡挂载成功" % p_name, false, "挂卡失败")
		return
	var b: float = float(before[landed])
	var a: float = _obs(landed, p_kind)
	var changed := (a < b - 0.0001) if p_down else (a > b + 0.0001)
	_check("审计 %s：消费点生效（%.3f → %.3f）" % [p_name, b, a], changed)


func _audit_player(p_name: String, p_pool: StringName, p_get: Callable, p_down: bool = false) -> void:
	var b: float = float(p_get.call())
	var landed: Node = _attach_pool_card(p_pool)
	if landed == null:
		_check("审计 %s：真卡挂载成功" % p_name, false, "挂卡失败")
		return
	var a: float = float(p_get.call())
	var changed := (a < b - 0.0001) if p_down else (a > b + 0.0001)
	_check("审计 %s：消费点生效（%.3f → %.3f）" % [p_name, b, a], changed)


func _audit_all_add_pools() -> void:
	print("── ADD 池 ×15 生效审计 ──")
	var player := _gl.player
	# 攻击（add_atk 入 add_entries → 管线步骤 3 消费；挂卡后条目在册）
	var w_atk := _attach_pool_card(&"add_atk")
	var has_atk := false
	if w_atk != null:
		for e: Dictionary in (w_atk.call("build_panel_snapshot") as Dictionary).get("add_entries", []):
			if String(e.get("pool_id", "")) == "add_atk":
				has_atk = true
	_check("审计 攻击力 add_atk：真卡上架 + add_entries 入面板（管线消费）", has_atk)
	# 攻速/射速（add_rof → 出招间隔缩短；rof 卡形态门含激光（tick 通道）——
	# 观测锁弹道主武器（间隔通道），显式指定宿主）
	var w1: Node = _weapons[0]
	var rof_card: TraitData = _gl.registry.get_trait(_pool_card_id(&"add_rof"))
	var rof_interval0 := float(w1.call("_fire_interval"))
	_gl.card_generator.apply_choice({
		"kind": CardGenerator.CardKind.TRAIT, "id": rof_card.id, "rarity": 0,
		"data": rof_card, "value_scale": 1.0,
		"display_name": rof_card.display_name, "description": rof_card.description,
		"target_weapon": w1,
	}, _gl.player)
	var rof_interval1 := float(w1.call("_fire_interval"))
	_check("审计 射速 add_rof：消费点生效（%.3f → %.3f）" % [rof_interval0, rof_interval1],
		rof_interval1 < rof_interval0 - 0.0001)
	# 冷却（add_cdr → cd 型武器脉冲间隔缩短）
	_audit_weapon("冷却 add_cdr", &"add_cdr", "interval", true)
	# 暴击率 / 爆伤
	_audit_weapon("暴击率 add_crit", &"add_crit", "crit", false)
	_audit_weapon("爆伤 add_critdmg", &"add_critdmg", "crit_mult", false)
	# 弹速 / 弹丸数（ballistic getter）
	_audit_weapon("弹速 add_spd", &"add_spd", "speed", false)
	_audit_weapon("弹丸数 add_pellets", &"add_pellets", "pellets", false)
	# 穿透（贯穿敌人数）
	_audit_weapon("穿透 add_pierce", &"add_pierce", "pierce", false)
	# 击退
	_audit_weapon("击退 add_knock", &"add_knock", "knock", false)
	# 体积（spawn 侧 hitbox ×(1+Σ)；面板聚合在册即视作接线）
	var w_size := _attach_pool_card(&"add_size")
	var size_ok := false
	if w_size != null:
		var agg: Dictionary = w_size.get("trait_stack").call(&"aggregate_panel")
		size_ok = absf(float(agg.get("add_size", 0.0))) > 0.0001
	_check("审计 弹丸体积 add_size：真卡上架 + 聚合在册（hitbox spawn 消费 pkg 锁定）", size_ok)
	# 生命
	_audit_player("生命上限 add_hp", &"add_hp",
		func() -> float: return float(player.get("max_hp")))
	# 技能冷却（玩家侧基线缩短）
	_audit_player("技能冷却 add_skillcdr", &"add_skillcdr",
		func() -> float: return float(player.get("skill_cd_base")), true)
	# 磁吸
	_audit_player("磁吸 add_pickup", &"add_pickup",
		func() -> float: return float(player.get("pickup_radius")))
	# 经验（合成增量上升）
	_audit_player("经验获取 add_xp", &"add_xp",
		func() -> float: return float(player.call("xp_gain_pct")))
	# 金币（合成增量上升）
	_audit_player("金币获取 add_gold", &"add_gold",
		func() -> float: return float(player.call("gold_gain_pct")))
	# 池完整性：15 个 ADD 池全部有真卡上架（无死池）
	var missing: Array[String] = []
	for pool in [&"add_atk", &"add_rof", &"add_cdr", &"add_crit", &"add_critdmg",
		&"add_spd", &"add_hp", &"add_skillcdr", &"add_pickup", &"add_size",
		&"add_pierce", &"add_pellets", &"add_xp", &"add_knock", &"add_gold"]:
		if _pool_card_id(pool) == &"":
			missing.append(String(pool))
	_check("池完整性：15 个 ADD 池全部有真卡上架（0 死池）", missing.is_empty(), str(missing))
	# 穿透卡面说明（用户点名「穿透是干嘛的要写出来」）
	var pierce_card: TraitData = _gl.registry.get_trait(_pool_card_id(&"add_pierce"))
	_check("卡面口径：穿透卡描述说明「贯穿敌人数」机制",
		pierce_card != null and String(pierce_card.description).contains("贯穿"))

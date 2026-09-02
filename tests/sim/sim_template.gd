# tests/sim/sim_template.gd
# v1.5.0 TTK 复校工装（A14）：构筑模板装配器（纯静态；全 registry 真件 + 真路径）。
# · 装配真路径：player.add_weapon → level_up×4（全模板 L5 终值口径）→ attach_trait×layers
#  （ELEM 词条挂载触发 elemental.rebuild_registries 全量重算——共鸣/精通与真局同路径）。
# · 模板表（A14 §3 冻结）：
#   T1  = W1×1（基线锚）
#   T2  = W1+W2+W3 全 L5（多武器面）
#   T3  = W1×2（A: ELE_IGNITE×2 层 / B: ELE_FREEZE×2 层）
#   T4  = W1×4（A: ELE_TIDE×2 层 / B/C/D: ELE_SHOCK×2 层）
#   T5  = T2 武器 + 六芯片金档（ATK/ATK2/CRIT/CRITDMG/ROF/ATTACH；add_bonus_slots(6) 开容）
#   T6  = T2 + meta 全满（scratch 档真购买 hpg5/atk5/greed5/seed_gold3/xp5；跑批尾 wipe）
#   T7a = T1 + 期望臂直注（赐福 stat 三键 n×权重×占比；n=max(w-1,0)）
#   T7b = T1 + 极值臂（仅 atk_pct n×0.04）
# · 未知 id / 悬空 assert false fail-fast。
class_name SimTemplate
extends RefCounted

const IDS: Array[String] = ["T1", "T2", "T3", "T4", "T5", "T6", "T7a", "T7b"]

const W1 := &"W1_pistol"
const W2 := &"W2_gatling"
const W3 := &"W3_shotgun"
const TRAIT_IGNITE := "res://resources/traits/ELE_IGNITE.tres"
const TRAIT_FREEZE := "res://resources/traits/ELE_FREEZE.tres"
const TRAIT_SHOCK := "res://resources/traits/ELE_SHOCK.tres"
const TRAIT_TIDE := "res://resources/traits/ELE_TIDE.tres"
const CHIP_GOLD := 3                           # 金档 rarity（白0/蓝1/紫2/金3）
const T5_CHIPS: Array[StringName] = [&"CHIP_ATK", &"CHIP_ATK2", &"CHIP_CRIT",
	&"CHIP_CRITDMG", &"CHIP_ROF", &"CHIP_ATTACH"]


static func label(p_id: String) -> String:
	match p_id:
		"T1":
			return "T1 W1基线"
		"T2":
			return "T2 W1+W2+W3"
		"T3":
			return "T3 双W1 火冰双附"
		"T4":
			return "T4 四W1 潮汐+三感电"
		"T5":
			return "T5 T2+六金芯片"
		"T6":
			return "T6 T2+meta全满"
		"T7a":
			return "T7a T1+期望臂"
		"T7b":
			return "T7b T1+极值臂"
	return p_id


static func build(p_env: SimEnv, p_id: String, p_wave: int) -> Array[WeaponBase]:
	# 装配（复用环境：先清上一轮武器栈与芯片运行态——每 cell 干净口径；
	# ★ chip.reset_run 清 equipped/bonus/blessing，meta_stats 有意保留（A9 冻结语义，
	#   T6 由 build 内 set_meta_stats 显式重载））
	_reset_weapons(p_env)
	p_env.chip.reset_run()
	match p_id:
		"T1":
			return _t1(p_env)
		"T2":
			return _t2(p_env)
		"T3":
			return _t3(p_env)
		"T4":
			return _t4(p_env)
		"T5":
			return _t5(p_env)
		"T6":
			return _t6(p_env)
		"T7a":
			return _t7(p_env, p_wave, false)
		"T7b":
			return _t7(p_env, p_wave, true)
	push_error("[SimTemplate] 未知模板 id：%s" % p_id)
	assert(false)
	return []


# ── 模板体 ────────────────────────────────────────────────────────
static func _t1(p_env: SimEnv) -> Array[WeaponBase]:
	var out: Array[WeaponBase] = [ _add(p_env, W1, []) ]
	return out


static func _t2(p_env: SimEnv) -> Array[WeaponBase]:
	var out: Array[WeaponBase] = [
		_add(p_env, W1, []), _add(p_env, W2, []), _add(p_env, W3, []),
	]
	return out


static func _t3(p_env: SimEnv) -> Array[WeaponBase]:
	var out: Array[WeaponBase] = [
		_add(p_env, W1, [_tr(TRAIT_IGNITE, 2)]),
		_add(p_env, W1, [_tr(TRAIT_FREEZE, 2)]),
	]
	return out


static func _t4(p_env: SimEnv) -> Array[WeaponBase]:
	var out: Array[WeaponBase] = [
		_add(p_env, W1, [_tr(TRAIT_TIDE, 2)]),
		_add(p_env, W1, [_tr(TRAIT_SHOCK, 2)]),
		_add(p_env, W1, [_tr(TRAIT_SHOCK, 2)]),
		_add(p_env, W1, [_tr(TRAIT_SHOCK, 2)]),
	]
	return out


static func _t5(p_env: SimEnv) -> Array[WeaponBase]:
	# T2 武器 + 六芯片金档（add_bonus_slots(6) 开容至 6——槽位门真实生效路径）
	var out := _t2(p_env)
	p_env.chip.add_bonus_slots(6)
	for chip_id in T5_CHIPS:
		var ok: bool = p_env.chip.equip(chip_id, CHIP_GOLD, [])
		assert(ok)
		if not ok:
			push_error("[SimTemplate] 芯片装备失败：%s" % String(chip_id))
	return out


static func _t6(p_env: SimEnv) -> Array[WeaponBase]:
	# T2 + meta 全满（scratch 档真购买——purchase 逐级走定价序列；快照注入 chip.meta_stats）
	var out := _t2(p_env)
	var store := p_env.meta_scratch()
	store.add_crystal(100000)
	for entry in [[&"hpg", 5], [&"atk", 5], [&"greed", 5], [&"seed_gold", 3], [&"xp", 5]]:
		while store.level(entry[0]) < int(entry[1]):
			assert(store.purchase(entry[0]))
	p_env.chip.set_meta_stats(store.meta_stats_snapshot())
	return out


static func _t7(p_env: SimEnv, p_wave: int, p_extreme: bool) -> Array[WeaponBase]:
	# T1 + 赐福臂直注（chip.add_blessing_stat + invalidate_panels——Option A 后加和通道；
	# n = max(w-1,0)：atk 4%/波×25% 取率、rof 3%/波×15%、attach 5%/波×10%；T7b 仅 atk 全额）
	var out := _t1(p_env)
	var n := maxi(p_wave - 1, 0)
	p_env.chip.add_blessing_stat(&"atk_pct", float(n) * 0.04 * 0.25)
	if not p_extreme:
		p_env.chip.add_blessing_stat(&"rof", float(n) * 0.03 * 0.15)
		p_env.chip.add_blessing_stat(&"attach_strength", float(n) * 0.05 * 0.10)
	else:
		p_env.chip.add_blessing_stat(&"atk_pct", float(n) * 0.04)
	p_env.chip.invalidate_panels()
	return out


# ── 装配支撑（真路径） ────────────────────────────────────────────
static func _add(p_env: SimEnv, p_wid: StringName, p_traits: Array) -> WeaponBase:
	# add_weapon → level_up×4 → attach_trait×layers（全部 registry 真件）
	p_env.player.unlock_slot(5)                   # 恒开满 5 槽（幂等取大；T4 四武器最大面）
	var data: WeaponData = p_env.registry.get_weapon(p_wid)
	if data == null:
		push_error("[SimTemplate] 悬空武器 id：%s" % String(p_wid))
		assert(false)
		return null
	var weapon: WeaponBase = p_env.player.add_weapon(data)
	if weapon == null:
		push_error("[SimTemplate] add_weapon 失败：%s" % String(p_wid))
		assert(false)
		return null
	for i in range(WeaponBase.MAX_LEVEL - 1):
		weapon.level_up()
	for entry in p_traits:
		var layers := int(entry.get("layers", 1))
		for j in range(layers):
			assert(weapon.attach_trait(entry.get("trait") as TraitData))
	return weapon


static func _tr(p_path: String, p_layers: int) -> Dictionary:
	var data: TraitData = load(p_path) as TraitData
	assert(data != null)
	return {"trait": data, "layers": p_layers}


static func _reset_weapons(p_env: SimEnv) -> void:
	# 复用环境口径：清上一模板武器栈（build 前置——equip/trait 残留防线）
	if p_env.player == null or not is_instance_valid(p_env.player):
		return
	for i in range(p_env.player.weapon_slots.size()):
		var w: WeaponBase = p_env.player.weapon_slots[i]
		if w != null and is_instance_valid(w):
			w.free()
		p_env.player.weapon_slots[i] = null

# scripts/meta/map_table.gd
# MapTable（META_ROADMAP M2 多地图落地，用户反馈「多种类型的地图配合多种类型的怪，
# 第一大关通关后打后面的」）：静态地图定义表——id / 名称 / 描述 / 波表加载路径 /
# 最终波（通关判据）/ 云层主题色。第一关复用注册表主表；后续关卡旁路 load() 独立
# 波表（DataRegistry 为单表单例口径，不扩注册表）。通关链 = Meta.maps_cleared 存档，
# 解锁判据 = 上一关已通关（is_map_unlocked）。
#
# 词缀二期（双词缀祝/诅咒，P1 2026-08-31 裁定——本注释块为数值真源，强度温和 ±5~12%）：
# · 祝福（bless_*，利好玩家）应用点：金币 → GameLoop 金币掉账（player.map_gold_mult）/
#   经验 → Player.gain_xp（player.map_xp_mult）/ 射速 → WeaponBase._fire_interval
#   （player.map_rof_mult）/ 每波回血 → GameLoop wave_cleared 订阅（player.map_wave_heal_pct）
# · 诅咒（curse_*，利敌）应用点：EnemySpawner._apply_map_mods（mob_hp_mult / ice_resist /
#   spd_mult / contact_mult / hp_mult）
# · 注入点：GameLoop._apply_map_affixes（start_run 调用；bless_id/curse_id → 数值映射）。
#   旧 mod_id/mod_name 单向词缀键保留（既有 pkg/验收断言锁定），应用口径已被双词缀替代
#   （frost 霜甲 = 旧 ice_resist 同值、demon 疾魔 = 旧 spd_mult 同值、swamp 泥沼由 8% 上调至
#   10%、grove 旧 xp_mult +10% 被滋养/毒肤组合替代、草原由无词缀升级为丰饶/虫群）。
class_name MapTable
extends RefCounted

# 地图定义（顺序即关卡序；tint = CloudBackdrop 云层 modulate 主题色）
const MAPS: Array[Dictionary] = [
	{
		"id": &"world_grass", "name": "晴空草原", "desc": "初启之地 · 杂兵与精英的新兵场",
		"table_path": "",                                   # 空 = 注册表主表（30 波）
		"tint": Color(1.0, 1.0, 1.0, 1.0), "final_wave": 30,
		"mod_name": "", "mod_id": &"",
		"bless_id": &"bless_harvest", "bless_name": "丰饶：金币获取 +10%",
		"curse_id": &"curse_swarm", "curse_name": "虫群：小怪生命 +8%（Boss 免除）",
	},
	{
		"id": &"world_frost", "name": "寒霜冰原", "desc": "冰霜仔与水泡怪出没 · 冰抗敌人需火炻或迸裂破阵",
		"table_path": "res://resources/maps/wave_table_frost.tres",
		"tint": Color(0.72, 0.88, 1.0, 1.0), "final_wave": 20,
		"mod_name": "霜冻之地：敌人冰抗 +20%", "mod_id": &"ice_resist",
		"bless_id": &"bless_frost_crystal", "bless_name": "寒晶：经验获取 +10%",
		"curse_id": &"curse_frost_armor", "curse_name": "霜甲：敌人冰抗 +20%",
	},
	{
		"id": &"world_demon", "name": "紫晶魔域", "desc": "恶魔小鬼成群 · 高速贴脸考验爆发",
		"table_path": "res://resources/maps/wave_table_demon.tres",
		"tint": Color(0.82, 0.72, 1.0, 1.0), "final_wave": 20,
		"mod_name": "魔血狂暴：敌人移速 +10%", "mod_id": &"spd_mult",
		"bless_id": &"bless_fervor", "bless_name": "狂热：武器射速 +6%",
		"curse_id": &"curse_swift_demon", "curse_name": "疾魔：敌人移速 +10%",
	},
	{
		"id": &"world_grove", "name": "翡翠树海", "desc": "林间飞雀与疾行者 · 速攻流走位试炼",
		"table_path": "res://resources/maps/wave_table_grove.tres",
		"tint": Color(0.74, 1.0, 0.82, 1.0), "final_wave": 20,
		"mod_name": "迅捷之风：经验获取 +10%", "mod_id": &"xp_mult",
		"bless_id": &"bless_nurture", "bless_name": "滋养：每波回复 2% 生命",
		"curse_id": &"curse_toxic_skin", "curse_name": "毒肤：敌人接触伤害 +8%",
	},
	{
		"id": &"world_swamp", "name": "翠毒沼泽", "desc": "毒泡史莱姆与沼泽巨口 · 毒爆/装甲/触手生态",
		"table_path": "res://resources/maps/wave_table_swamp.tres",
		"tint": Color(0.6, 0.9, 0.58, 1.0), "final_wave": 20,
		"mod_name": "毒性弥漫：敌人生命 +8%", "mod_id": &"hp_mult",
		"bless_id": &"bless_rich_vein", "bless_name": "富矿：经验 +8% 且金币 +8%",
		"curse_id": &"curse_mire", "curse_name": "泥沼：敌人生命 +10%",
	},
]

const FIRST_MAP_ID := &"world_grass"


static func count() -> int:
	return MAPS.size()


static func get_map(p_id: StringName) -> Dictionary:
	for m in MAPS:
		if m.id == p_id:
			return m
	return {}


static func get_map_index(p_id: StringName) -> int:
	for i in range(MAPS.size()):
		if MAPS[i].id == p_id:
			return i
	return 0


static func next_map_id(p_id: StringName) -> StringName:
	var idx := get_map_index(p_id)
	return MAPS[idx + 1].id if idx + 1 < MAPS.size() else &""


static func load_table(p_id: StringName, p_registry: DataRegistry) -> WaveTableData:
	# 波表解析：第一关 → 注册表主表；其余 → 旁路 load 独立波表（缺失 → 回退主表，降级不崩溃）
	var def := get_map(p_id)
	var path := String(def.get("table_path", ""))
	if path.is_empty() or p_registry == null:
		return p_registry.get_wave_table() if p_registry != null else null
	var res: Resource = load(path)
	return res as WaveTableData if res is WaveTableData else p_registry.get_wave_table()

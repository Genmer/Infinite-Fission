# scripts/meta/map_table.gd
# MapTable（META_ROADMAP M2 多地图落地，用户反馈「多种类型的地图配合多种类型的怪，
# 第一大关通关后打后面的」）：静态地图定义表——id / 名称 / 描述 / 波表加载路径 /
# 最终波（通关判据）/ 云层主题色。第一关复用注册表主表；后续关卡旁路 load() 独立
# 波表（DataRegistry 为单表单例口径，不扩注册表）。通关链 = Meta.maps_cleared 存档，
# 解锁判据 = 上一关已通关（is_map_unlocked）。
class_name MapTable
extends RefCounted

# 地图定义（顺序即关卡序；tint = CloudBackdrop 云层 modulate 主题色）
const MAPS: Array[Dictionary] = [
	{
		"id": &"world_grass", "name": "晴空草原", "desc": "初启之地 · 杂兵与精英的新兵场",
		"table_path": "",                                   # 空 = 注册表主表（30 波）
		"tint": Color(1.0, 1.0, 1.0, 1.0), "final_wave": 30,
	},
	{
		"id": &"world_frost", "name": "寒霜冰原", "desc": "冰霜仔与水泡怪出没 · 冰抗敌人需火炻或迸裂破阵",
		"table_path": "res://resources/maps/wave_table_frost.tres",
		"tint": Color(0.72, 0.88, 1.0, 1.0), "final_wave": 20,
	},
	{
		"id": &"world_demon", "name": "紫晶魔域", "desc": "恶魔小鬼成群 · 高速贴脸考验爆发",
		"table_path": "res://resources/maps/wave_table_demon.tres",
		"tint": Color(0.82, 0.72, 1.0, 1.0), "final_wave": 20,
	},
	{
		"id": &"world_grove", "name": "翡翠树海", "desc": "林间飞雀与疾行者 · 速攻流走位试炼",
		"table_path": "res://resources/maps/wave_table_grove.tres",
		"tint": Color(0.74, 1.0, 0.82, 1.0), "final_wave": 20,
	},
	{
		"id": &"world_swamp", "name": "翠毒沼泽", "desc": "毒泡史莱姆与沼泽巨口 · 毒爆/装甲/触手生态",
		"table_path": "res://resources/maps/wave_table_swamp.tres",
		"tint": Color(0.6, 0.9, 0.58, 1.0), "final_wave": 20,
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

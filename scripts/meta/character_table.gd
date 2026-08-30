# scripts/meta/character_table.gd
# CharacterTable（用户反馈「不同的角色有不同的技能」）：可选角色定义表——基础血量 /
# 攻击修正 / 主动技能（名称/描述/冷却）。选择持久化在 Meta.character_id；开局由
# Player.set_character 应用（含局外养成加成——META_ROADMAP M8 同批落地）。
class_name CharacterTable
extends RefCounted

const CHARACTERS: Array[Dictionary] = [
	{
		"id": &"sentinel", "name": "哨兵-9", "desc": "均衡型防御机体，容错稳定",
		"unlock_map": &"",
		"hp": 60.0, "atk_pct": 0.0,
		"skill_name": "紧急护盾", "skill_desc": "展开 3 秒无敌力场",
		"cd": 120.0,
	},
	{
		"id": &"veles", "name": "裂变者·薇拉", "desc": "高攻脆皮，输出特化（血 45 / 攻 +25%）",
		"unlock_map": &"world_grass",       # 通关①晴空草原解锁
		"hp": 45.0, "atk_pct": 0.25,
		"skill_name": "过载咆哮", "skill_desc": "4 秒内全武器射速翻倍",
		"cd": 120.0,
	},
	{
		"id": &"bulwark", "name": "堡垒·磐", "desc": "重装堡垒（血 95 / 攻 -5%），近身清场",
		"hp": 95.0, "atk_pct": -0.05,
		"unlock_map": &"world_frost",       # 通关②寒霜冰原解锁（越后面越好：攻 -15%→-5%）
		"skill_name": "震荡践踏", "skill_desc": "震退周围敌人并清除身旁弹幕",
		"cd": 120.0,
	},
	{
		"id": &"ranger", "name": "游侠·岚", "desc": "灵动刺客（血 52 / 攻 +10%），走位拉满",
		"hp": 52.0, "atk_pct": 0.10,
		"skill_name": "影袭瞬步", "skill_desc": "朝移动方向瞬步 260px 并短暂无敌",
		"cd": 120.0,
		"unlock_map": &"world_demon",
	},
	{
		"id": &"zero", "name": "演算者·零", "desc": "战术演算体（血 65 / 攻 +15%），控场终局",
		"hp": 65.0, "atk_pct": 0.15,
		"skill_name": "时滞力场", "skill_desc": "全场敌人静止 2.5 秒（无视免疫）",
		"cd": 120.0,
		"unlock_map": &"world_grove",       # 通关④翡翠树海解锁
	},
	{
		"id": &"mank", "name": "腐化者·莽", "desc": "毒沼共生体（血 58 / 攻 +12%），终局毒核",
		"hp": 58.0, "atk_pct": 0.12,
		"skill_name": "毒沼绽放", "skill_desc": "全屏毒爆：对所有敌人结算 150% 攻击",
		"cd": 120.0,
		"unlock_map": &"world_swamp",       # 通关⑤翠毒沼泽解锁
	},
]


static func get_character(p_id: StringName) -> Dictionary:
	for c in CHARACTERS:
		if c.id == p_id:
			return c
	return CHARACTERS[0]


static func count() -> int:
	return CHARACTERS.size()

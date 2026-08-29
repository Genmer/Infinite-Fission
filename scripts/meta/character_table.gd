# scripts/meta/character_table.gd
# CharacterTable（用户反馈「不同的角色有不同的技能」）：可选角色定义表——基础血量 /
# 攻击修正 / 主动技能（名称/描述/冷却）。选择持久化在 Meta.character_id；开局由
# Player.set_character 应用（含局外养成加成——META_ROADMAP M8 同批落地）。
class_name CharacterTable
extends RefCounted

const CHARACTERS: Array[Dictionary] = [
	{
		"id": &"sentinel", "name": "哨兵-9", "desc": "均衡型防御机体，容错稳定",
		"hp": 60.0, "atk_pct": 0.0,
		"skill_name": "紧急护盾", "skill_desc": "展开 3 秒无敌力场",
		"cd": 30.0,
	},
	{
		"id": &"veles", "name": "裂变者·薇拉", "desc": "高攻脆皮，输出特化（血 45 / 攻 +25%）",
		"hp": 45.0, "atk_pct": 0.25,
		"skill_name": "过载咆哮", "skill_desc": "4 秒内全武器射速翻倍",
		"cd": 26.0,
	},
	{
		"id": &"bulwark", "name": "堡垒·磐", "desc": "重装堡垒（血 95 / 攻 -15%），近身清场",
		"hp": 95.0, "atk_pct": -0.15,
		"skill_name": "震荡践踏", "skill_desc": "震退周围敌人并清除身旁弹幕",
		"cd": 20.0,
	},
]


static func get_character(p_id: StringName) -> Dictionary:
	for c in CHARACTERS:
		if c.id == p_id:
			return c
	return CHARACTERS[0]


static func count() -> int:
	return CHARACTERS.size()

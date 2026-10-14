# scripts/meta/character_table.gd
# CharacterTable（用户反馈「不同的角色有不同的技能」）：可选角色定义表——基础血量 /
# 攻击修正 / 主动技能（名称/描述/冷却）。选择持久化在 Meta.character_id；开局由
# Player.set_character 应用（含局外养成加成——META_ROADMAP M8 同批落地）。
# R246 升华键：每角色 sublime_name / sublime_desc = 升华技能名 + 卡面/选人描述
#（文案真源 docs/design/sublime/<角色>.md §文案/§5，10 角色全量落表；fission 为替代
# 升华「本命同调」）。cards 泳道 _make_sublime_card / _sublime_available 只读此键
#（_card_system.md:107-108/:204-216 契约）——本表必须先于 cards 泳道合入。
# 解锁矩阵（2026-09-13 用户反馈「一些通关，一些购买，一些成就解锁」——大部分角色
# 需要解锁而非随意使用，三类门型混合给长线目标）：
# · 通关门 unlock_map ×3：veles①草原 / bulwark②冰原 / mank⑤沼泽；
# · 购买门 unlock_price ×3（结晶永久解锁，Meta.purchase_character 扣费）：
#   ranger 80 / zero 160 / reaper 240 结晶（价梯顺延——结晶 = 局内波次+击杀+成就产出）；
# · 成就/挑战门 ×2：vera = 图鉴累计击杀 500；noah = 成就「深入敌阵」（单局 20 波）。
# · R186 通关分档门 ×2：fission = 任一地图常规局普通通关（unlock_normal_clear）；
#   echo = 任意地图困难/地狱通关（unlock_hard_clear——Meta.hard_cleared 剥 #N 后缀查表）。
# · R247 无尽深度门 unlock_endless_depth ×2：medic = 任意无尽模式深入 20 层 /
#   vortex = 深入 50 层（Meta.best_endless_depth 聚合各图各 #1/#2 分档记录的最大深度
#   ——派生谓词零存档键，与 endless_depth_20/50 成就同源同阈值；设计 _channels.md §4）。
# · sentinel 初始免费（新手底座）。
class_name CharacterTable
extends RefCounted

const CHARACTERS: Array[Dictionary] = [
	{
		"id": &"sentinel", "name": "哨兵-9", "desc": "均衡型防御机体，容错稳定",
		"unlock_map": &"",
		"hp": 60.0, "atk_pct": 0.0,
		"skill_name": "紧急护盾", "skill_desc": "展开 3 秒无敌力场",
		"cd": 120.0,
		# R246 升华键（首条带契约注）：sublime_name/sublime_desc 只作 cards 升华卡
		# 文案源（卡面描述/掷卡可用性判定），player.gd 升华行为不读此键（skills 泳道
		# 按各角色设计文档实现）；文案出典 docs/design/sublime/sentinel.md §9 文案汇总
		"sublime_name": "绝对屏障",
		"sublime_desc": "展开 5 秒绝对屏障：每 0.5 秒对身旁 120px 内敌人反冲 15% 攻击并击退；吞下来袭伤害即为屏障回充 2 秒冷却（单次施放至多回充 20 秒）",
	},
	{
		"id": &"veles", "name": "裂变者·薇拉", "desc": "高攻脆皮，输出特化（血 45 / 攻 +25%）",
		"unlock_map": &"world_grass",       # 通关①晴空草原解锁
		"hp": 45.0, "atk_pct": 0.25,
		"skill_name": "过载咆哮", "skill_desc": "4 秒内全武器射速翻倍",
		"cd": 120.0,
		"sublime_name": "临界过载",   # R246 升华（veles.md §5 文案）
		"sublime_desc": "5 秒内全武器射速由 2 倍持续爬升至 3.2 倍，越战越猛；窗口内每次击杀积攒 1 层余热（至多 5 层），结束后火力不再骤停，以每层 +4% 射速逐层冷却、缓缓熄炉",
	},
	{
		"id": &"bulwark", "name": "堡垒·磐", "desc": "重装堡垒（血 95 / 攻 -5%），近身清场",
		"hp": 95.0, "atk_pct": -0.05,
		"unlock_map": &"world_frost",       # 通关②寒霜冰原解锁（越后面越好：攻 -15%→-5%）
		"skill_name": "震荡践踏", "skill_desc": "震退周围敌人并清除身旁弹幕",
		"cd": 120.0,
		"sublime_name": "余震壁垒",   # R246 升华（bulwark.md §2/§6 卡面文案）
		"sublime_desc": "践踏化作余震壁垒——主震更猛，其后三重余震随你推进，每一颗被踩碎的弹幕都砌进壁垒的血里",
	},
	{
		"id": &"ranger", "name": "游侠·岚", "desc": "灵动刺客（血 52 / 攻 +10%），走位拉满",
		"hp": 52.0, "atk_pct": 0.10,
		"skill_name": "影袭瞬步", "skill_desc": "朝移动方向瞬步 260px 并短暂无敌",
		"cd": 120.0,
		"unlock_price": 80,                 # 结晶购买解锁（80 结晶，永久）
		"sublime_name": "百影穿袭",   # R246 升华（ranger.md §2 升华版总览）
		"sublime_desc": "瞬步化为穿袭——位移更长、无敌更久、沿途斩击敌人，身后残影延时自爆拂清弹幕；持续不受击蓄「潜影」层，下一次穿袭更远更狠",
	},
	{
		"id": &"zero", "name": "演算者·零", "desc": "战术演算体（血 65 / 攻 +15%），控场终局",
		"hp": 65.0, "atk_pct": 0.15,
		"skill_name": "时滞力场", "skill_desc": "全场敌人静止 2.5 秒（无视免疫）",
		"cd": 120.0,
		"unlock_price": 160,                # 结晶购买解锁（160 结晶，永久）
		"sublime_name": "时滞奇点",   # R246 升华（zero.md §5 文案）
		"sublime_desc": "全场时间凝滞 3.5 秒并形成持续力场——静止期间入场的敌人一并凝滞；每击杀一名凝滞之敌静止延长 0.15 秒（至多 +0.9 秒）；静止中全武器射速 +20%，无视冻结免疫",
	},
	{
		"id": &"mank", "name": "腐化者·莽", "desc": "毒沼共生体（血 58 / 攻 +12%），终局毒核",
		"hp": 58.0, "atk_pct": 0.12,
		"skill_name": "毒沼绽放", "skill_desc": "全屏毒爆：对所有敌人结算 150% 攻击",
		"cd": 120.0,
		"unlock_map": &"world_swamp",       # 通关⑤翠毒沼泽解锁
		"sublime_name": "万毒噬界",   # R246 升华（mank.md §二 卡片描述文案）
		"sublime_desc": "全屏毒爆结算 210% 攻击；毒爆击杀喂养毒核（精华每层 +2%，上限 30 层，精英 ×2 / 首领 ×5）；被毒爆击杀的敌人原地毒沼爆裂（50% 攻击）",
	},
	{
		"id": &"vera", "name": "毒系学者·薇拉", "desc": "毒理研究员（血 55 / 攻 +8%），领域控场",
		"hp": 55.0, "atk_pct": 0.08,
		"skill_name": "毒云领域", "skill_desc": "展开 300px 毒云 6 秒：域内敌人每 0.5 秒受 8% 攻击毒伤并减速 20%",
		"cd": 120.0,
		"unlock_kills": 500,                # 图鉴累计击杀 500 只解锁（挑战门）
		"sublime_name": "毒理学终章",   # R246 升华（vera.md §2 升华版总览三机制）
		"sublime_desc": "毒云在敌体内积累、自我生长、结束时引爆：每跳 +1 层毒蚀（上限 12 层，每层跳伤 +6%、减速加深 1.5%），半径自 300px 蔓延至 390px，消散瞬间按层数结算终结毒伤（每层 3% 攻击）",
	},
	{
		"id": &"noah", "name": "召唤师·诺亚", "desc": "僚机使役者（血 50 / 攻 +5%），复制增援",
		"hp": 50.0, "atk_pct": 0.05,
		# R198（P2-skillcopy）：desc 尾补伴随火力括注——12% 实存（player.gd 召唤僚机段：
		# 弹伤 = 12% 主武器 ATK 的注释与 panel_snapshot base*0.12 双证）
		"skill_name": "召唤僚机", "skill_desc": "随机复制 2 把当前武器（含全部强化），僚机携带参战 10 秒后离场（舰体伴随火力 = 主武器 ATK 的 12%）",
		"cd": 120.0,
		"unlock_achievement": &"wave_20",   # 成就「深入敌阵」（单局抵达第 20 波）解锁
		"sublime_name": "万械共鸣",   # R246 升华（noah.md §二 数值对照表）
		"sublime_desc": "复制 3 把武器、3 架僚机护航 16 秒（共鸣每 5 层 +1 秒，至长 24 秒）；僚机在场期间全场击杀 +1 层共鸣（上限 40，本局跨施放保留），副本伤害每层 +1.5%，护航舰弹伤提至 18%",
	},
	{
		# R186 第 9 角色「改造者·枢」：交换定位 技能 ↔ 首发——无技能（no_skill 契约，
		# player.activate_skill 短路 + CDR 折算射速，归 G1 机制组），开局武器任选
		#（图鉴已解锁 ∪ W1_pistol 白名单，Meta.custom_weapon 持久化）。
		# ★ cd 键必须保留（tests/runner/verify_feedback_cases.gd 遍历全角色断言 cd==120）。
		"id": &"fission", "name": "改造者·枢",
		"desc": "无技能·初始武器自定义（血 65 / 攻 +0%）",
		"unlock_normal_clear": true,         # 任一地图常规局普通通关（每日局结算分流不解锁）
		"hp": 65.0, "atk_pct": 0.0,
		"no_skill": true, "cd": 120.0,
		# R246 替代升华（fission.md §3——无技能角色的升华替代位：纯被动本命同调）：
		# cards _sublime_available 对 no_skill 角色以 sublime_desc 非空为掷卡可用判据
		"sublime_name": "本命同调",
		"sublime_desc": "本命武装觉醒。击杀叠加同调层（每层攻击 +0.13%，精英 ×3、Boss ×15），每 100 层装载一件 Ω 改装件，满层进入超频态；技能冷却折算率与射速帽提升（+30% → +45%）。抽到瞬间按已击杀数回填半数层数",
	},
	{
		# R186 第 10 角色「回响·伊可」：构筑随机性即身份——开局随机双武器（有放回，
		# P(同款)=1/9），GameLoop._grant_random_dual_loadout 注入；困难通关解锁。
		"id": &"echo", "name": "回响·伊可",
		"desc": "随机武装体（血 55 / 攻 +0%），开局随机双武器",
		"random_dual": true,                 # GameLoop 开局随机双武器注入（有技能角色）
		"unlock_hard_clear": true,           # 任意地图困难/地狱通关（map_records #N 分档键）
		"hp": 55.0, "atk_pct": 0.0,
		"skill_name": "双生回响", "skill_desc": "5 秒内全武器射速 +50%",
		"cd": 120.0,
		"sublime_name": "无尽回响",   # R246 升华（echo.md §2 升华版设计总览）
		"sublime_desc": "主窗射速更强（异款 +80% / 同款 +90%），窗口内每击杀激起一层回声（上限 6 层，异款每层 +2%）；主窗结束化作渐弱余韵（+35%，0.5~0.6 秒/层，至长 3.6 秒）——回声不灭，只是衰减",
	},
	{
		# R247 新角色①：续航生态位——全表首个治疗/减伤技能；无尽深度 20 层成就门
		#（设计 _channels.md §1.4；技能实现归 skills 泳道 player.gd）
		"id": &"medic", "name": "战地医师·苏", "desc": "后勤医疗体（血 75 / 攻 +0%），战场续航",
		"unlock_endless_depth": 20,
		"hp": 75.0, "atk_pct": 0.0,
		"skill_name": "应急修复", "skill_desc": "立即回复 30% 生命，且 4 秒内受伤减半",
		"cd": 120.0,
	},
	{
		# R247 新角色②：聚怪生态位（震退的反向位）；无尽深度 50 层成就门（终局奖励位）
		"id": &"vortex", "name": "坍缩者·汐", "desc": "引力操控者（血 55 / 攻 +10%），聚怪终结",
		"unlock_endless_depth": 50,
		"hp": 55.0, "atk_pct": 0.10,
		"skill_name": "奇点坍缩", "skill_desc": "凝聚奇点 3 秒牵引全场敌人聚拢，结束爆发 120% 攻击",
		"cd": 120.0,
	},
	{
		# R247 新角色③：伤害轴增益窗生态位；结晶直购价梯顺延 80→160→240
		"id": &"reaper", "name": "处刑者·刈", "desc": "处刑专家（血 50 / 攻 +20%），爆发窗口",
		"unlock_price": 240,
		"hp": 50.0, "atk_pct": 0.20,
		"skill_name": "处决时刻", "skill_desc": "6 秒内全武器伤害 +50%",
		"cd": 120.0,
	},
]


static func get_character(p_id: StringName) -> Dictionary:
	for c in CHARACTERS:
		if c.id == p_id:
			return c
	return CHARACTERS[0]


static func count() -> int:
	return CHARACTERS.size()


static func has_skill(p_id: StringName) -> bool:
	# R186 无技能角色契约（G1 机制组消费：player.activate_skill 短路 / HUD 技能键可见性）：
	# no_skill 键缺省 = 有技能（旧角色数据零改动兼容）
	return not bool(get_character(p_id).get("no_skill", false))

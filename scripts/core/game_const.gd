# scripts/core/game_const.gd
# M-19 附庸：全局枚举/位标志/共享常量。纯静态容器，禁止持有运行时状态。
# （唯一例外：next_uid() 的分配器计数——架构 §2.0 点名的全局递增 UID 分配器。）
class_name GameConst
extends RefCounted

enum Element { KIN, FIR, ICE, LTG, HYD, ANE, GEO, DEN }   # 伤害/附着元素
# R192 元素扩容：KIN..LTG=0..3 现役序禁动（λ/免疫位/敌 resist 按下标直索引，只追加不重排）；
# 追加 HYD=4（水）/ ANE=5（风）/ GEO=6（岩）/ DEN=7（草）——新四元素全走纯反应载体，
# 满槽钳制 GAUGE_MAX 保留为反应燃料（无 _trigger 臂不触发；旧三元素满槽清零语义不变）。

const MAX_WEAPON_SLOTS := 7                   # 槽位数组绝对上限（Player.MAX_SLOTS 同源；R185 起金卡不越帽，难度帽 5/6/6 恒在其内）
enum PoolClass { ADD, MULT, LOCAL, MECH, ELEM }           # 词条池归类（B_spec §2.5）
enum TraitEvent { ON_SPAWN, ON_TICK, ON_HIT, ON_PIERCE, ON_BOUNCE, ON_EXPIRE }  # 六大生命周期
enum WeaponForm { BALLISTIC, LASER, HOMING, MELEE }       # 武器四形态
enum EnemyBehavior { CHASE, RANGED, DASHER, ORBIT, SENTRY, BLINK }  # M1：CHASE/RANGED；BLINK R16 起支持（ENEMY_PATTERNS_BASIC §3.3）
enum GameStatus { BOOT, MENU, PLAYING, PAUSED, LEVEL_UP, GAME_OVER }
enum RecycleReason { EXPIRED, PIERCE_DEPLETED, BOUNCE_DEPLETED, NULLIFIED, FORCED }  # 回收五路径

# ── R72 难度三档（用户大活「新增困难和地狱」：复用关卡，普通=现行口径） ──────────
enum Difficulty { NORMAL = 0, HARD = 1, HELL = 2 }


static func difficulty_hp_mult(p_d: int) -> float:
	# 敌 HP 乘区：困难 ×3、地狱 ×9（困难基础上再 ×3——用户口径「最基础的数值」）
	return [1.0, 3.0, 9.0][clampi(p_d, 0, 2)]


static func difficulty_dmg_mult(p_d: int) -> float:
	# 敌接触伤害乘区：同 HP 口径（×3 / ×9）
	return [1.0, 3.0, 9.0][clampi(p_d, 0, 2)]


static func difficulty_reward_mult(p_d: int) -> float:
	# R73 风险回报（E1）：困难 ×1.5 / 地狱 ×2.5——金币与经验共用（高风险高回报闭环）
	return [1.0, 1.5, 2.5][clampi(p_d, 0, 2)]


static func difficulty_crystal_mult(p_d: int) -> float:
	# E11 难度结算加成：困难 ×1.3 / 地狱 ×1.6（局外养成风险回报）
	return [1.0, 1.3, 1.6][clampi(p_d, 0, 2)]


static func difficulty_revives(p_d: int) -> int:
	# 开局附赠复活次数：普通 0（原口径）/ 困难 1 / 地狱 3（用户裁定）
	return [0, 1, 3][clampi(p_d, 0, 2)]


static func difficulty_dual_pick(p_d: int, p_roll: float) -> bool:
	# 升级双选卡判定：地狱 100%（每次）/ 困难 5%（p_roll = [0,1) 随机数，测试可注入）
	return p_d == Difficulty.HELL or (p_d == Difficulty.HARD and p_roll < 0.05)


static func difficulty_slot_cap(p_d: int) -> int:
	# R183 分难度武器栏上限：普通 5 / 困难 6 / 地狱 6（R185：金卡「武器槽+1」只提前
	# 解锁帽内槽位、不越帽——总位数恒等于本帽，用户口径「3 解锁 2 锁」）
	return [5, 6, 6][clampi(p_d, 0, 2)]


static func difficulty_slot_default(p_d: int) -> int:
	# R183 开局默认解锁槽数：普通 2 / 困难 3 / 地狱 3（用户口径「上限有多少画多少，
	# 锁着的画上锁样式」——帽内其余槽位靠波次里程碑/金卡逐步解锁）
	return [2, 3, 3][clampi(p_d, 0, 2)]


const PLAYER_SIDE_POOLS: Array[StringName] = [&"add_hp", &"add_xp", &"add_pickup",
	&"add_skillcdr", &"add_gold"]   # 玩家侧词条池（全局生效）：卡面【通用】前缀 + 构筑详情
	                                # 「通用词条」段的归类真源（R80：此前错挂武器段误导归因）

# R196 超质变叠层注记（文案真源：词条卡/黑市/详情经卡描述带出，UI 禁手抄；用户口径原文）
const OVERCAP_NOTE := "超出质变等级的层数收益降低 30%"

# ── R199（P08）拖动操作教学文案真源（lore 菜单行 / HUD 战斗内首局一次性提示共用
#    单源，UI 禁手抄——移动是唯一输入与生存手段，全游戏此前无一处告知） ──
const TUTORIAL_MOVE_MENU := "战斗内拖动屏幕移动飞船——出发吧，链式反应，一根也不许 runaway！"
const TUTORIAL_MOVE_BATTLE := "战斗内拖动屏幕移动飞船——躲开弹幕！"

# ── R187 共享系统组常量 ───────────────────────────────────────────
# laser_subbeam_spawned 归属字段（R183 束数折减断言通道：本体可挂副束、复制体强制 0）
const SUBBEAM_OWNER_BODY := 0                 # 副激光生成自本体武器
const SUBBEAM_OWNER_COPY := 1                 # 副激光生成自诺亚复制体（新数据下恒不发生——折减断言用）
# W6/W7 引信标记（enemy.fuse_left 通用标记通道）
const FUSE_MARK_DURATION := 4.0               # 引信涂层持续 s（幂等刷新）
const FUSE_DETONATE_GUARD := 0.5              # 定向爆破每敌护栏 s（防同帧双爆双吃）
# W8 蓄能标记（enemy.charge_stacks 通用标记通道；蓄能池以目标 uid 为全局单例）
const CHARGE_STACK_DEFAULT_MAX := 5           # 满档档位缺省（真源 W8 melee.charge_max，缺省兜底）


static func weapon_note(p_weapon_id: String) -> String:
	# G8 新武器首获横幅一句话（空 = 不提示）；与 enemy_attack_note 同源纪律。
	# R187 六把重写（W4/W5/W6/W7/W8/W1 与五方向定案同步；W5 禁「折射/分光」、W8 禁「护盾」）
	match p_weapon_id:
		"W1_pistol":
			return "并行弹幕——并排编队越排越宽，L3 起跳弹回场增值"
		"W2_gatling":
			return "越打越快——预热满档倾泻如雨，停火 0.8s 归零"
		"W3_shotgun":
			return "贴脸爆发——越近越痛，散射锥覆盖整排"
		"W4_pulse_beam":
			return "常驻聚焦光束——持续照射爬坡 ×2，裂片棱镜解锁副激光分束"
		"W5_prism":
			return "万镜回廊——棱镜映照其他武器，镜面军团只吃棱镜自身词条"
		"W6_micro_missile":
			return "齐射引发器——高频小爆多点铺场，直击挂引信标记"
		"W7_cluster_rocket":
			return "攻城引爆器——慢节拍集束清屏，引信连携双倍余波"
		"W8_orbit_field":
			return "蓄能撞击——接触蓄能 x/5，满档在敌人身上引爆"
		"W9_arc_slash":
			return "弧斩化身——近身旋斩，贴脸收割"
		"W10_boomerang":
			return "定距甩满再返航——双程贯穿碰到弹开，同敌 0.4s 一跳"
		_:
			return ""


static func reaction_note(p_rxn_id: String) -> Dictionary:
	# R191#5 图鉴「反应」页文案单源（weapon_note 同源纪律：UI 不手抄、单点改这里）。
	# R192 起表驱动口径：键 = ReactionType 枚举成员 ID 字符串，随枚举扩容同步扩行
	#（图鉴行建由 UI 按枚举 keys() 动态生成——本函数只按 id 查行，坏 id 返回空字典）。
	# 字段封闭集 7 项：name 名称（单源 REACTION_NAMES，禁手抄）/ recipe 配方 /
	# elements 配方元素序（页面双色环取色用，恰 2 项）/ effect 效果句（结算语义 + 真条件
	# ——rxn 审计口径：无难度门、双槽附着即触发、同反应 2s 冷却、免疫怪拒附着）/
	# unlock 解锁句（节奏真源 MechanicGate.MAP_INTROS）/ mult_fmt 倍率行模板（数值一律
	# 不进文案——{key:spec} 取 reaction_table[key] 按 printf spec 格式化，{key_pc:spec}
	# =值 ×100，运行时由页面 token 格式化器渲染）/ sample 图鉴预览数值样张段（R192 收口2
	# 起仅 dmg 型渲染=反应名+本段；pct/stat 型页面走 DamagePopup.reaction_stat_text 读表
	# 格式化、不读本字段——本字段保持非空过 validator 双射闸，勿填渲染语义）。
	match p_rxn_id:
		"RXN_FIR_ICE":
			return {
				"name": REACTION_NAMES[ReactionType.RXN_FIR_ICE],
				"recipe": "火 + 冰",
				"elements": [GameConst.Element.FIR, GameConst.Element.ICE],
				"effect": "引爆目标身上的点燃剩余 DOT，一次性结算（不掷暴击）\n双槽附着即触发 · 同反应 2s 冷却 · 同帧碎裂>过载>超导 · 免疫怪拒附着",
				"unlock": "解锁：火 / 冰元素卡第 2 关起入手（碎裂初见）",
				"mult_fmt": "结算倍率 ×{coef:.1f}",
				"sample": "1284",
			}
		"RXN_FIR_LTG":
			return {
				"name": REACTION_NAMES[ReactionType.RXN_FIR_LTG],
				"recipe": "火 + 雷",
				"elements": [GameConst.Element.FIR, GameConst.Element.LTG],
				"effect": "火力雷光即时爆炸，波及半径内敌人（独立结算不掷暴击）\n双槽附着即触发 · 同反应 2s 冷却 · 同帧碎裂>过载>超导 · 免疫怪拒附着",
				"unlock": "解锁：雷元素卡（感电）第 3 关起入手 · 过载随之可发",
				"mult_fmt": "×{coef:.1f} · 半径 {radius:.0f}",
				"sample": "976",
			}
		"RXN_ICE_LTG":
			return {
				"name": REACTION_NAMES[ReactionType.RXN_ICE_LTG],
				"recipe": "冰 + 雷",
				"elements": [GameConst.Element.ICE, GameConst.Element.LTG],
				"effect": "削减目标全抗持续一段时间，全队伤害随之提高（纯减益）\n双槽附着即触发 · 同反应 2s 冷却 · 同帧碎裂>过载>超导 · 免疫怪拒附着",
				"unlock": "解锁：雷元素卡（感电）第 3 关起入手 · 超导随之可发",
				"mult_fmt": "全抗 {resist_delta_pc:.0f}% · {duration:.0f}s",
				"sample": "超导",
			}
		"RXN_FIR_HYD":
			return {
				"name": REACTION_NAMES[ReactionType.RXN_FIR_HYD],
				"recipe": "火 + 水",
				"elements": [GameConst.Element.FIR, GameConst.Element.HYD],
				"effect": "火遇水汽即时蒸发，按最近一次攻击快照追加一击（独立结算不掷暴击）\n双槽附着即触发 · 同反应 2s 冷却 · 免疫怪拒附着",
				"unlock": "解锁：水元素卡第 4 关起入手 · 蒸发随之可发",
				"mult_fmt": "结算倍率 ×{coef:.1f}",
				"sample": "1560",
			}
		"RXN_HYD_DEN":
			return {
				"name": REACTION_NAMES[ReactionType.RXN_HYD_DEN],
				"recipe": "水 + 草",
				"elements": [GameConst.Element.HYD, GameConst.Element.DEN],
				"effect": "水草交融凝成草原核，短暂延迟后绽放爆开，波及半径内敌人\n双槽附着即触发 · 同反应 2s 冷却 · 免疫怪拒附着",
				"unlock": "解锁：草元素卡第 5 关起入手 · 绽放随之可发",
				"mult_fmt": "结算倍率 ×{coef:.1f} · 半径 {radius:.0f} · 延迟 {delay:.1f}s",
				"sample": "1320",
			}
		"RXN_FIR_ANE":
			return {
				"name": REACTION_NAMES[ReactionType.RXN_FIR_ANE],
				"recipe": "风 + 火",
				"elements": [GameConst.Element.ANE, GameConst.Element.FIR],
				"effect": "风卷火势扩散：主目标受扩散一击，火附着满槽转移给周围敌人\n双槽附着即触发 · 同反应 2s 冷却 · 免疫怪拒附着",
				"unlock": "解锁：风元素卡第 5 关起入手 · 扩散随之可发",
				"mult_fmt": "×{coef:.1f} · 半径 {radius:.0f}",
				"sample": "760",
			}
		"RXN_ICE_ANE":
			return {
				"name": REACTION_NAMES[ReactionType.RXN_ICE_ANE],
				"recipe": "风 + 冰",
				"elements": [GameConst.Element.ANE, GameConst.Element.ICE],
				"effect": "风卷冰晶扩散：主目标受扩散一击，冰附着满槽转移给周围敌人\n双槽附着即触发 · 同反应 2s 冷却 · 免疫怪拒附着",
				"unlock": "解锁：风元素卡第 5 关起入手 · 扩散随之可发",
				"mult_fmt": "×{coef:.1f} · 半径 {radius:.0f}",
				"sample": "760",
			}
		"RXN_LTG_ANE":
			return {
				"name": REACTION_NAMES[ReactionType.RXN_LTG_ANE],
				"recipe": "风 + 雷",
				"elements": [GameConst.Element.ANE, GameConst.Element.LTG],
				"effect": "风引雷光扩散：主目标受扩散一击，雷附着满槽转移给周围敌人\n双槽附着即触发 · 同反应 2s 冷却 · 免疫怪拒附着",
				"unlock": "解锁：风元素卡第 5 关起入手 · 扩散随之可发",
				"mult_fmt": "×{coef:.1f} · 半径 {radius:.0f}",
				"sample": "760",
			}
		"RXN_HYD_ANE":
			return {
				"name": REACTION_NAMES[ReactionType.RXN_HYD_ANE],
				"recipe": "风 + 水",
				"elements": [GameConst.Element.ANE, GameConst.Element.HYD],
				"effect": "风携水汽扩散：主目标受扩散一击，水附着满槽转移给周围敌人\n双槽附着即触发 · 同反应 2s 冷却 · 免疫怪拒附着",
				"unlock": "解锁：风元素卡第 5 关起入手 · 扩散随之可发",
				"mult_fmt": "×{coef:.1f} · 半径 {radius:.0f}",
				"sample": "760",
			}
		"RXN_ANE_DEN":
			return {
				"name": REACTION_NAMES[ReactionType.RXN_ANE_DEN],
				"recipe": "风 + 草",
				"elements": [GameConst.Element.ANE, GameConst.Element.DEN],
				"effect": "风送草籽扩散：主目标受扩散一击，草附着满槽转移给周围敌人\n双槽附着即触发 · 同反应 2s 冷却 · 免疫怪拒附着",
				"unlock": "解锁：风元素卡第 5 关起入手 · 扩散随之可发",
				"mult_fmt": "×{coef:.1f} · 半径 {radius:.0f}",
				"sample": "760",
			}
		"RXN_ICE_HYD":
			return {
				"name": REACTION_NAMES[ReactionType.RXN_ICE_HYD],
				"recipe": "冰 + 水",
				"elements": [GameConst.Element.ICE, GameConst.Element.HYD],
				"effect": "冰水激凝：目标完全定身，解冻后转为寒滞减速并陷入易伤（免疫定身怪不定身）\n双槽附着即触发 · 同反应 2s 冷却 · 免疫怪拒附着",
				"unlock": "解锁：水元素卡第 4 关起入手 · 冻结随之可发",
				"mult_fmt": "定身 {freeze_dur:.1f}s · 寒滞 {chill_dur:.1f}s",
				"sample": "冻结",
			}
		"RXN_LTG_HYD":
			return {
				"name": REACTION_NAMES[ReactionType.RXN_LTG_HYD],
				"recipe": "雷 + 水",
				"elements": [GameConst.Element.LTG, GameConst.Element.HYD],
				"effect": "雷入水体连锁传导：伤害向周围敌人逐层跳跃（受连锁冷却护栏限频）\n双槽附着即触发 · 同反应 2s 冷却 · 免疫怪拒附着",
				"unlock": "解锁：水元素卡第 4 关起入手 · 感电随之可发",
				"mult_fmt": "连锁传导",
				"sample": "感电",
			}
		"RXN_FIR_DEN":
			return {
				"name": REACTION_NAMES[ReactionType.RXN_FIR_DEN],
				"recipe": "火 + 草",
				"elements": [GameConst.Element.FIR, GameConst.Element.DEN],
				"effect": "火遇草即刻燃起满层烈焰，持续灼烧（快照取最近一次攻击面板）\n双槽附着即触发 · 同反应 2s 冷却 · 免疫怪拒附着",
				"unlock": "解锁：草元素卡第 5 关起入手 · 燃烧随之可发",
				"mult_fmt": "点燃 {burn_dur:.1f}s · 至多 {burn_layers_max:.0f} 层",
				"sample": "燃烧",
			}
		"RXN_LTG_DEN":
			return {
				"name": REACTION_NAMES[ReactionType.RXN_LTG_DEN],
				"recipe": "雷 + 草",
				"elements": [GameConst.Element.LTG, GameConst.Element.DEN],
				"effect": "雷激草木：目标陷入易伤，全队伤害随之提高（纯减益）\n双槽附着即触发 · 同反应 2s 冷却 · 免疫怪拒附着",
				"unlock": "解锁：草元素卡第 5 关起入手 · 激化随之可发",
				"mult_fmt": "易伤 ×{vuln_mult:.2f} · {vuln_dur:.0f}s",
				"sample": "激化",
			}
		"RXN_FIR_GEO":
			return {
				"name": REACTION_NAMES[ReactionType.RXN_FIR_GEO],
				"recipe": "岩 + 火",
				"elements": [GameConst.Element.GEO, GameConst.Element.FIR],
				"effect": "岩与火凝出晶护：为玩家附加减伤护体（刷新不叠加）\n双槽附着即触发 · 同反应 2s 冷却 · 免疫怪拒附着",
				"unlock": "解锁：岩元素卡第 5 关起入手 · 结晶随之可发",
				"mult_fmt": "减伤 {dr_pc:.0f}% · {dr_dur:.0f}s",
				"sample": "结晶·火",
			}
		"RXN_ICE_GEO":
			return {
				"name": REACTION_NAMES[ReactionType.RXN_ICE_GEO],
				"recipe": "岩 + 冰",
				"elements": [GameConst.Element.GEO, GameConst.Element.ICE],
				"effect": "岩与冰凝出晶护：为玩家附加减伤护体（刷新不叠加）\n双槽附着即触发 · 同反应 2s 冷却 · 免疫怪拒附着",
				"unlock": "解锁：岩元素卡第 5 关起入手 · 结晶随之可发",
				"mult_fmt": "减伤 {dr_pc:.0f}% · {dr_dur:.0f}s",
				"sample": "结晶·冰",
			}
		"RXN_LTG_GEO":
			return {
				"name": REACTION_NAMES[ReactionType.RXN_LTG_GEO],
				"recipe": "岩 + 雷",
				"elements": [GameConst.Element.GEO, GameConst.Element.LTG],
				"effect": "岩与雷凝出晶护：为玩家附加减伤护体（刷新不叠加）\n双槽附着即触发 · 同反应 2s 冷却 · 免疫怪拒附着",
				"unlock": "解锁：岩元素卡第 5 关起入手 · 结晶随之可发",
				"mult_fmt": "减伤 {dr_pc:.0f}% · {dr_dur:.0f}s",
				"sample": "结晶·雷",
			}
		"RXN_HYD_GEO":
			return {
				"name": REACTION_NAMES[ReactionType.RXN_HYD_GEO],
				"recipe": "岩 + 水",
				"elements": [GameConst.Element.GEO, GameConst.Element.HYD],
				"effect": "岩与水凝出晶护：为玩家附加减伤护体（刷新不叠加）\n双槽附着即触发 · 同反应 2s 冷却 · 免疫怪拒附着",
				"unlock": "解锁：岩元素卡第 5 关起入手 · 结晶随之可发",
				"mult_fmt": "减伤 {dr_pc:.0f}% · {dr_dur:.0f}s",
				"sample": "结晶·水",
			}
		"RXN_DEN_GEO":
			return {
				"name": REACTION_NAMES[ReactionType.RXN_DEN_GEO],
				"recipe": "岩 + 草",
				"elements": [GameConst.Element.GEO, GameConst.Element.DEN],
				"effect": "岩与草凝出晶护：为玩家附加减伤护体（刷新不叠加）\n双槽附着即触发 · 同反应 2s 冷却 · 免疫怪拒附着",
				"unlock": "解锁：岩元素卡第 5 关起入手 · 结晶随之可发",
				"mult_fmt": "减伤 {dr_pc:.0f}% · {dr_dur:.0f}s",
				"sample": "结晶·草",
			}
		"RXN_ANE_GEO":
			return {
				"name": REACTION_NAMES[ReactionType.RXN_ANE_GEO],
				"recipe": "风 + 岩",
				"elements": [GameConst.Element.ANE, GameConst.Element.GEO],
				"effect": "岩与风凝出晶护：为玩家附加减伤护体（刷新不叠加；风不扩散岩，归结晶单占）\n双槽附着即触发 · 同反应 2s 冷却 · 免疫怪拒附着",
				"unlock": "解锁：岩元素卡第 5 关起入手 · 结晶随之可发",
				"mult_fmt": "减伤 {dr_pc:.0f}% · {dr_dur:.0f}s",
				"sample": "结晶·风",
			}
		_:
			return {}


static func enemy_attack_note(p_enemy_id: String) -> String:
	# E5/R72 新形态机制一句话（图鉴行 + 首遇提示条共用；空 = 旧怪不提示）
	match p_enemy_id:
		"E25_phase_bomber":
			return "闪现到你身边自爆——落地红圈就是走位窗"
		"E26_shield_lancer":
			return "正面盾面减伤 85%——绕到侧面或背后打"
		"E27_warden_orb":
			return "符文环亮起时弹开你的子弹——等冷却窗口"
		"E28_hexcaster":
			return "在你脚下施放法术圈——读条结束前移开"
		"E29_longbowhawk":
			return "高速箭矢带预判——别走直线"
		"E30_hellfire_revenant":
			return "大范围闪现自爆——引信更短，快速脱离"
		_:
			return ""


static func difficulty_name(p_d: int) -> String:
	return ["普通", "困难", "地狱"][clampi(p_d, 0, 2)]


static func difficulty_desc(p_d: int) -> String:
	# 选难度行副文案（图鉴口径同源）
	match clampi(p_d, 0, 2):
		Difficulty.HARD:
			return "敌 HP/攻击 ×3 · 复活 +1 · 升级 5% 概率成对抉择"
		Difficulty.HELL:
			return "敌 HP/攻击 ×9 · 复活 +3 · 每次升级成对抉择（2 列 6 卡选同行两张）"
		_:
			return "现行口径 · 无附赠复活"
enum PopupStyle { NORMAL, CRIT, REACTION, DOT, HEAL, XP, IMMUNE, CHARGE_BURST }   # IMMUNE：R22 元素免疫跳字；CHARGE_BURST：R187 W8 蓄能满档引爆（独立桶——同 uid 合并不吞引爆大数字）
enum FeelLevel { HIT, CRIT, CATALYST, BOSS_DEATH }        # GameFeel 分级（Q-12）
enum ReactionType {                                                 # 反应中性 ID（唯一真源 idContract §3.3）
	RXN_FIR_ICE, RXN_FIR_LTG, RXN_ICE_LTG,                         # 现役三名 0..2 追加不重排（R191 锁）
	RXN_FIR_HYD, RXN_HYD_DEN,                                      # R192 具名：蒸发 / 绽放
	RXN_FIR_ANE, RXN_ICE_ANE, RXN_LTG_ANE, RXN_HYD_ANE, RXN_ANE_DEN,   # R192 扩散族 ×5（族模板）
	RXN_ICE_HYD, RXN_LTG_HYD, RXN_FIR_DEN, RXN_LTG_DEN,            # R192 具名：冻结 / 感电 / 燃烧 / 激化
	RXN_FIR_GEO, RXN_ICE_GEO, RXN_LTG_GEO, RXN_HYD_GEO, RXN_DEN_GEO, RXN_ANE_GEO,   # R192 结晶族 ×6
}   # id 惯例 = 低枚举序元素在前；结算优先级另见 ElementalSystem.RXN_ORDER（枚举序 ≠ 优先级序）

# R192 反应中文名单源（枚举序 int 键 → 中文名；REACTION_LOOKS.name / reaction_note.name /
# 图鉴行建统一引此表，禁各处手抄）。冰+草无反应成员——留白标注行见 REACTION_BLANK_NOTE。
const REACTION_NAMES: Dictionary = {
	ReactionType.RXN_FIR_ICE: "碎裂", ReactionType.RXN_FIR_LTG: "过载", ReactionType.RXN_ICE_LTG: "超导",
	ReactionType.RXN_FIR_HYD: "蒸发", ReactionType.RXN_HYD_DEN: "绽放",
	ReactionType.RXN_FIR_ANE: "扩散·火", ReactionType.RXN_ICE_ANE: "扩散·冰",
	ReactionType.RXN_LTG_ANE: "扩散·雷", ReactionType.RXN_HYD_ANE: "扩散·水",
	ReactionType.RXN_ANE_DEN: "扩散·草",
	ReactionType.RXN_ICE_HYD: "冻结", ReactionType.RXN_LTG_HYD: "感电",
	ReactionType.RXN_FIR_DEN: "燃烧", ReactionType.RXN_LTG_DEN: "激化",
	ReactionType.RXN_FIR_GEO: "结晶·火", ReactionType.RXN_ICE_GEO: "结晶·冰",
	ReactionType.RXN_LTG_GEO: "结晶·雷", ReactionType.RXN_HYD_GEO: "结晶·水",
	ReactionType.RXN_DEN_GEO: "结晶·草", ReactionType.RXN_ANE_GEO: "结晶·风",
}
# 冰+草 反应留白标注（图鉴「反应」页枚举行循环后追加的降透明标注行；R191#4『选了没反应』
# 误报教训——把空白变规则。数值不进文案，本行不承载任何表值）
const REACTION_BLANK_NOTE := "冰 + 草：暂无反应（设计留白 · 如实标注，非图鉴遗漏）"
enum TargetStrategy { NEAREST, FOREMOST, LOWEST_HP, LOCKED }  # 武器目标策略
enum ConditionId {                                        # 乘区条件封闭枚举（§三.5）
	TARGET_FROZEN, TARGET_BURNING, TARGET_SHOCKED, AFTER_BOUNCE,
	PIERCE_INDEX_GE, PLAYER_HP_BELOW, WAVE_FIRST_HIT, TARGET_TAG_IN,
	TARGET_HP_BELOW, PLAYER_HP_ABOVE,               # R72：处决线 / 满血壁垒
	NONE,
}

# DamageContext.hit_flags 位标志
const HIT_IS_BOUNCE := 1            # 本次命中发生在反弹之后
const HIT_AFTER_PIERCE := 2         # 穿透序数 ≥2 的命中
const HIT_IS_SPLIT_CHILD := 4       # 分裂子代
const HIT_IS_REACTION := 8          # 元素反应独立结算（不掷暴击）
const HIT_IS_DOT := 16              # DOT 跳伤（不掷暴击）
const HIT_IS_AOE_SECONDARY := 32    # 爆炸溅射次级目标
const HIT_NO_CRIT := 24             # 掩码：HIT_IS_REACTION | HIT_IS_DOT

# Enemy tags / immune_mask 位标志
const TAG_ELITE := 1
const TAG_BOSS := 2
const TAG_FINAL_BOSS := 4      # 最终 Boss（地图最终波巨 Boss——1/3 屏，用户反馈）
const ELEM_IMMUNE_FIR := 2          # 元素伤害免疫位（R22 P1：bit = 1 << Element）
const ELEM_IMMUNE_ICE := 4          #   FIR=2 / ICE=4 / LTG=8——KIN 无位 = 物理恒有效保底
const ELEM_IMMUNE_LTG := 8
const ELEM_IMMUNE_HYD := 16         # R192 元素扩容续位（bit = 1 << Element 通用式直继承）：
const ELEM_IMMUNE_ANE := 32         #   HYD=16 / ANE=32 / GEO=64 / DEN=128——新四元素
const ELEM_IMMUNE_GEO := 64         #   免疫位与旧三位同构（elem_immune 白名单随 validator
const ELEM_IMMUNE_DEN := 128        #   R192 拓宽；immune 怪对新元素拒附着＝拒反应燃料）
const IMMUNE_FREEZE := 1            # 定身免疫（Boss 默认置位，F-17）
const IMMUNE_CHILL := 2
const IMMUNE_BURN := 4
const IMMUNE_SHOCK := 8

# UID 位宽（§4.1 幂等键位拼接约束：UID < 2^20，帧号 < 2^24）
const UID_MAX := 0xFFFFF            # 2^20 − 1

# 分配器计数（静态；单主线程访问，无需线程安全）
static var _uid_counter: int = 0


static func next_uid() -> int:
	# 全局递增实例 UID（投射物/武器/词条实例幂等键组成部分）；线程安全性不需要（单主线程）。
	# 超出 20bit 位宽时回绕（§4.1：分配器层面钳制）。
	_uid_counter += 1
	if _uid_counter > UID_MAX:
		_uid_counter = 1
	return _uid_counter

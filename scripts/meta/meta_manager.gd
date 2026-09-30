# scripts/meta/meta_manager.gd
# Meta 外部成长管理器（META_ROADMAP §1/§3 M4+M6 首批落地，用户反馈「大厅、图鉴、成就」）：
# · 图鉴：怪物（击杀解锁+累计计数）/ 武器（获得解锁）/ 词条（抽取解锁）——遇解锁口径。
# · 成就：定义表驱动（累计击杀 / 单局波次 / 单局等级 / 持有武器 / 单局词条 / 击败Boss /
#   完成局数 + R191 阶梯扩容：单敌击杀 / 图鉴收集 / 地图通关——手写 11 条原 id/原 reward
#   逐字保留 + 模板启动期展开 ~128 条），事件即时判定，解锁即存档（R191：批量补检
#   单次落盘，_save 不再在解锁循环内逐条写盘）。
# · 记录：历史最高（波次/击杀/单局等级）+ 累计（局数/击杀），GAME_OVER 结算落盘。
# 持久化：user://meta_save.cfg（ConfigFile 多段：codex/achievements/records/maps/daily/
# meta/settings）；autoload 不声明 class_name（§九纪律）。
# 事件消费只读（enemy_killed 的敌人节点读 data.id / tags；card_chosen 读 kind——解锁写入
# 均在本管理器，零数值副作用）。
extends Node

signal codex_changed()                        # 图鉴解锁（大厅面板刷新用）
signal achievements_changed(ach_id: StringName)   # 成就解锁提示（大厅面板刷新用）
signal settings_changed(p_key: String)        # 设置变更（P3：SfxBank 音量实时应用等）
signal fissioner_unlocked()                   # R186：改造者·枢普通通关解锁（结算兑现点派发；HUD toast/大厅角标消费）
signal echo_unlocked()                        # R198（二aw-6）：回响·伊可困难/地狱通关解锁（结算兑现点派发；大厅角标消费——menu_screen 复用 fissioner 处理器）

static func save_path() -> String:
	# 存档路径（headless = 自动化测试 → 独立测试档）：杜绝测试套件把通关/购买位/
	# 成就写进真实存档（2026-09-13 用户实测「角色基本都解锁了」根因即此）
	return "user://meta_save_test.cfg" if DisplayServer.get_name() == "headless" \
		else "user://meta_save.cfg"

# 成就定义表（id → {id, reward, name, desc, type, target[, enemy]}；type: total_kills/
# run_wave/run_level/run_weapons_drawn/run_traits_drawn/run_reactions（R192 反应族）/
# boss_slain/total_runs/
# enemy_kills/codex_weapons/codex_traits/maps_cleared——后四族为 R191 阶梯扩容新增）。
# R191：const 改启动期构建 var（名不变，下游 Meta.ACHIEVEMENTS 零改动兼容）——手写
# 11 条原 id/原 reward 逐字保留（存档兼容 + noah 门 character_table unlock_achievement）；
# _ready 首步 _expand_achievements() 按下方阶梯模板表展开 ≈+117 条合并入表（全表 ~128
# 条落 120~200 区间；id 规则 <type>[_<enemy>]_<target>，撞档跳过手写优先，每条显式写
# reward 键堵 get("reward",10) 隐性通胀口）。目标数量级裁定 ~128：体裁天花板 + 经济封顶
# + 全量重建 UI 墙 + 结算写风暴（架构按 500 条零劣化预留，超 500 须先做 UI 虚拟化）。
var ACHIEVEMENTS: Array[Dictionary] = [
	{"id": &"first_blood", "reward": 10, "name": "初次裂变", "desc": "累计击杀 1 只敌人", "type": "total_kills", "target": 1},
	{"id": &"kill_500", "reward": 25, "name": "弹幕清道夫", "desc": "累计击杀 500 只敌人", "type": "total_kills", "target": 500},
	{"id": &"kill_2000", "reward": 60, "name": "裂变风暴", "desc": "累计击杀 2000 只敌人", "type": "total_kills", "target": 2000},
	{"id": &"wave_10", "reward": 20, "name": "站稳脚跟", "desc": "单局抵达第 10 波", "type": "run_wave", "target": 10},
	{"id": &"wave_20", "reward": 40, "name": "深入敌阵", "desc": "单局抵达第 20 波", "type": "run_wave", "target": 20},
	{"id": &"wave_30", "reward": 80, "name": "无尽之门", "desc": "单局抵达第 30 波", "type": "run_wave", "target": 30},
	{"id": &"level_15", "reward": 30, "name": "成长曲线", "desc": "单局等级达到 15 级", "type": "run_level", "target": 15},
	{"id": &"weapons_3", "reward": 25, "name": "军火大亨", "desc": "单局获得 2 把新武器（共持 3 把）", "type": "run_weapons_drawn", "target": 2},
	{"id": &"traits_8", "reward": 25, "name": "词条收藏家", "desc": "单局获得 8 张词条卡", "type": "run_traits_drawn", "target": 8},
	{"id": &"boss_slay", "reward": 30, "name": "屠戮聚合体", "desc": "击败首个 Boss", "type": "boss_slain", "target": 1},
	{"id": &"runs_10", "reward": 50, "name": "不屈哨兵", "desc": "完成 10 局", "type": "total_runs", "target": 10},
]

# ── R191 成就阶梯模板表（启动期展开真源，_expand_achievements 消费） ─────────
# targets/rewards/names 三数组等长；desc 由 desc_fmt 生成。奖励曲线裁定：中间档 0 结晶 /
# 链终档 10~100 结晶，全表（手写 395 + 生成 1040 + R192 反应族 30）合计 1465 结晶 ≤ 1500 封顶。
#（R196 注释卫生：结晶 emoji 字面量清零——P1 源码扫描禁非 BMP 码点，apk_menu_no_icons 定案）
const ACH_TIER_TABLE: Array[Dictionary] = [
	# 全局 7 族扩档（+22 条）
	{"type": "total_kills", "targets": [100, 5000, 10000], "rewards": [0, 0, 100],
		"names": ["小试牛刀", "杀戮美学", "裂变传说"], "desc_fmt": "累计击杀 %d 只敌人"},
	{"type": "run_wave", "targets": [40, 50, 60], "rewards": [0, 0, 100],
		"names": ["稳步推进", "无尽行者", "无尽征服"], "desc_fmt": "单局抵达第 %d 波"},
	{"type": "run_level", "targets": [25, 30, 35, 40], "rewards": [0, 0, 0, 100],
		"names": ["炉火纯青", "登峰造极", "超凡入圣", "裂变之心"], "desc_fmt": "单局等级达到 %d 级"},
	{"type": "run_weapons_drawn", "targets": [3, 4], "rewards": [0, 40],
		"names": ["小军火库", "满编火力"], "desc_fmt": "单局获得 %d 把新武器"},
	{"type": "run_traits_drawn", "targets": [12, 16, 20], "rewards": [0, 0, 40],
		"names": ["词条猎人", "词条大师", "词条百科"], "desc_fmt": "单局获得 %d 张词条卡"},
	{"type": "boss_slain", "targets": [3, 5, 8], "rewards": [0, 0, 60],
		"names": ["猎首者", "弑王者", "群王克星"], "desc_fmt": "单局击败 %d 个 Boss"},
	{"type": "total_runs", "targets": [25, 50, 75, 100], "rewards": [0, 0, 0, 80],
		"names": ["常客", "老练哨兵", "不屈意志", "百战传说"], "desc_fmt": "完成 %d 局"},
	# R192 反应族（+3 条：单局触发反应数——既有 3 反应与新矩阵同被计数；targets/rewards
	# 按 wire 定案 [10,25,50]/[0,0,30]，终档 +30 结晶落 1465 封顶内；id 由展开器按
	# <type>_<target> 规则生成 = run_reactions_10/25/50）
	{"type": "run_reactions", "targets": [10, 25, 50], "rewards": [0, 0, 30],
		"names": ["初窥反应", "连锁反应", "元素大师"], "desc_fmt": "单局触发 %d 次元素反应"},
	# 收集族（+5 条：图鉴武器 10 种 / 词条 66 种——终档留余量不顶满）
	{"type": "codex_weapons", "targets": [5, 10], "rewards": [0, 50],
		"names": ["武器鉴赏家", "全械收藏家"], "desc_fmt": "图鉴收录 %d 种武器"},
	{"type": "codex_traits", "targets": [10, 30, 50], "rewards": [0, 0, 80],
		"names": ["初窥门径", "融会贯通", "词条宗师"], "desc_fmt": "图鉴收录 %d 种词条"},
	# 地图族（+3 条：5 图通关链，MapTable.MAPS 真源）
	{"type": "maps_cleared", "targets": [1, 3, 5], "rewards": [0, 0, 100],
		"names": ["破土前行", "开疆拓土", "行遍万境"], "desc_fmt": "通关 %d 张地图"},
]

# 单敌阶梯模板（+87 条 = 29 敌 × [50, 250, 1000]）：id/name 摘自 resources/enemies/
# *.tres display_name（E5_elite 通用变异模板取短名「精英」）。MetaManager 为 autoload，
# _ready 先于 GameLoop 的 DataRegistry 注入——敌名清单只能内联模板（工程内唯一允许的
# 副本；敌表增删时两处同步，展开侧撞 id 守卫兜底）。
const ACH_ENEMY_TIERS: Array[Dictionary] = [
	{"id": &"E1_grunt", "name": "杂兵"}, {"id": &"E2_runner", "name": "疾冲者"},
	{"id": &"E3_bastion", "name": "重甲"}, {"id": &"E4_volatile", "name": "爆虫"},
	{"id": &"E5_elite", "name": "精英"}, {"id": &"E6_boss1", "name": "聚合体"},
	{"id": &"E6_boss2", "name": "裂变之核"}, {"id": &"E6_boss3", "name": "无穷裂母"},
	{"id": &"E7_spitter", "name": "喷吐者"}, {"id": &"E8_imp", "name": "恶魔小鬼"},
	{"id": &"E9_frostling", "name": "冰霜仔"}, {"id": &"E10_woodbird", "name": "林间飞雀"},
	{"id": &"E11_aquasquirt", "name": "水泡怪"}, {"id": &"E12_bogslime", "name": "毒泡史莱姆"},
	{"id": &"E13_bogspitter", "name": "毒沼喷手"}, {"id": &"E14_boguard", "name": "沼泽卫士"},
	{"id": &"E15_bogleaper", "name": "毒跳蛙"}, {"id": &"E16_marshmaw", "name": "沼泽巨口"},
	{"id": &"E17_frost_sovereign", "name": "霜魄君王"}, {"id": &"E18_demon_lord", "name": "熔核魔尊"},
	{"id": &"E19_grove_warden", "name": "古树守卫"}, {"id": &"E20_swamp_hydra", "name": "九头沼龙"},
	{"id": &"E24_rift_demon", "name": "裂隙爆魔"}, {"id": &"E25_phase_bomber", "name": "幻影爆袭者"},
	{"id": &"E26_shield_lancer", "name": "壁垒枪兵"}, {"id": &"E27_warden_orb", "name": "秘纹守卫"},
	{"id": &"E28_hexcaster", "name": "咒术师"}, {"id": &"E29_longbowhawk", "name": "长弓隼卫"},
	{"id": &"E30_hellfire_revenant", "name": "狱焰归魂"},
]
const ACH_ENEMY_TARGETS: Array[int] = [50, 250, 1000]
const ACH_ENEMY_REWARDS: Array[int] = [0, 0, 10]          # 链终档 10 结晶 × 29 链 = 290 结晶
const ACH_ENEMY_NAME_SFX: Array[String] = ["克星", "猎手", "末日"]

var _ach_expanded: bool = false                # R191：展开幂等位（重复调用零新增条目）


func _expand_achievements() -> void:
	# R191 成就阶梯展开（_ready 首步，先于 _load/_build_ach_buckets——分桶与存档读入
	# 均消费全表）：模板表 → 生成条目合并入 ACHIEVEMENTS。id 规则 <type>[_<enemy>]_
	# <target>；撞 id / 撞 type+target 档跳过（手写 11 条原 id/原 reward 逐字优先）；
	# 生成条目显式写 reward 键（堵 get("reward",10) 隐性通胀口）；幂等（防重复展开
	# 产生重复 id——新 id 全局唯一纪律）。
	if _ach_expanded:
		return
	_ach_expanded = true
	var seen_ids := {}
	var seen_slots := {}                      # "<type>/<target>" 档位（enemy 族另带敌 id，同档不同敌不算撞）
	for a in ACHIEVEMENTS:
		seen_ids[String(a.id)] = true
		seen_slots["%s/%s" % [String(a.type), str(a.target)]] = true
	for tpl in ACH_TIER_TABLE:
		var atype := String(tpl["type"])
		var targets: Array = tpl["targets"]
		var rewards: Array = tpl["rewards"]
		var names: Array = tpl["names"]
		for i in range(targets.size()):
			var target := int(targets[i])
			var aid := "%s_%d" % [atype, target]
			if seen_ids.has(aid) or seen_slots.has("%s/%s" % [atype, str(target)]):
				push_warning("[Meta] 成就阶梯撞档跳过（手写优先）：%s" % aid)
				continue
			seen_ids[aid] = true
			seen_slots["%s/%s" % [atype, str(target)]] = true
			ACHIEVEMENTS.append({
				"id": StringName(aid), "reward": int(rewards[i]),
				"name": String(names[i]),
				"desc": String(tpl["desc_fmt"]) % target,
				"type": atype, "target": target,
			})
	for etpl in ACH_ENEMY_TIERS:
		var eid := StringName(String(etpl["id"]))
		var ename := String(etpl["name"])
		for i in range(ACH_ENEMY_TARGETS.size()):
			var target := ACH_ENEMY_TARGETS[i]
			var aid := "enemy_kills_%s_%d" % [String(eid), target]
			if seen_ids.has(aid):
				push_warning("[Meta] 成就阶梯撞 id 跳过：%s" % aid)
				continue
			seen_ids[aid] = true
			ACHIEVEMENTS.append({
				"id": StringName(aid), "reward": ACH_ENEMY_REWARDS[i],
				"name": ename + ACH_ENEMY_NAME_SFX[i],
				"desc": "累计击杀 %d 只%s" % [target, ename],
				"type": "enemy_kills", "target": target, "enemy": eid,
			})

# 运行期状态（存档落盘口径）
var codex_kills: Dictionary = {}              # enemy_id(String) → 累计击杀数
var codex_first_met: Dictionary = {}          # E5：enemy_id(String) → true（首次遭遇已提示）
var codex_weapons: Dictionary = {}            # weapon_id(String) → true（获得解锁）
var codex_traits: Dictionary = {}             # trait_id(String) → true（抽取解锁）
var reaction_seen: Dictionary = {}            # R196：rxn_id(String) → true（图鉴「已触发」标记；
                                              # 键集⊆ReactionType 20 成员 id，旧档缺键→空表）
var achievements_done: Dictionary = {}        # ach_id(String) → true
var records: Dictionary = {
	"best_wave": 0, "best_kills": 0, "best_level": 1,
	"total_runs": 0, "total_kills": 0,
}
var maps_cleared: Dictionary = {}             # map_id(String) → true（通关解锁链，M2）
var map_records: Dictionary = {}              # map_id(String) → {best_wave, best_kills, best_level, endless_depth}
var daily_records: Dictionary = {}            # 日期键(YYYYMMDD String) → {best_wave, best_kills}（每日挑战独立口径，P2）
# 单局计数（GAME_OVER 结算后清零）
var _run_kills: int = 0
var _run_max_wave: int = 0
var _run_max_level: int = 1
var _run_weapons_drawn: int = 0
var _run_traits_drawn: int = 0
var _run_reactions: int = 0                    # R192：单局触发反应数（run_reactions 成就族计数）
var _run_boss_slain: int = 0
var _run_map: StringName = MapTable.FIRST_MAP_ID   # 当前局地图（GameLoop.start_run 注入）
var _run_difficulty: int = 0                 # E11：本局难度档（GameLoop 注入；结算分档键）
var _run_daily: bool = false                  # 当前局为每日挑战（结算只记 daily_best，P2）
# 局外养成（META_ROADMAP M8 落地，用户反馈「局外养成」）：裂变结晶 + 永久升级
var crystals: int = 0                         # 裂变结晶（每局结算产出）
var upgrades: Dictionary = {}                 # upgrade_id(String) → 等级
var character_id: StringName = &"sentinel"    # 当前选用角色（大厅选人）
var unlocked_characters: Dictionary = {}      # 购买解锁的角色 id(String) → true（永久，存档）
var custom_weapon_id: String = ""             # R186：改造者·枢（fission）自定义首发武器 id
                                              #（"" = 手枪兜底；单键全局归属 fission，换角/重开不清）

# 永久升级定义表（cost = base_cost × (当前级+1)）
const UPGRADES: Array[Dictionary] = [
	{"id": &"life", "name": "装甲强化", "desc": "生命上限 +10/级", "max_lv": 5, "base_cost": 20},
	{"id": &"atk", "name": "火力校准", "desc": "全武器攻击 +4%/级", "max_lv": 5, "base_cost": 30},
	{"id": &"magnet", "name": "磁力线圈", "desc": "拾取半径 +15%/级", "max_lv": 3, "base_cost": 25},
	{"id": &"cdr", "name": "技能超频", "desc": "角色技能冷却 -8%/级", "max_lv": 3, "base_cost": 35},
	{"id": &"xp_gain", "name": "经验萃取", "desc": "经验获取 +8%/级", "max_lv": 3, "base_cost": 30},
	{"id": &"start_gold", "name": "初始资金", "desc": "开局金币 +20/级", "max_lv": 3, "base_cost": 25},
	{"id": &"reroll", "name": "预案推演", "desc": "每局选卡「换一批」次数 +1/级", "max_lv": 3, "base_cost": 30},
	# R198（二aw-4）：无敌时长文案 2s→3s 对齐真值 REVIVE_INVULN_S=3.0（player.gd:104，
	# E2 r2 调档 2.0→3.0 时漏改本句——文案从实现取值，此处仅追平）
	{"id": &"revive", "name": "应急协议", "desc": "每局可复活 1 次/级（满血复活 + 3s 无敌）", "max_lv": 2, "base_cost": 80},
]


# ── 设置段（P3 设置页，META_ROADMAP §5.10）：随 user:// 存档落盘 ────
# 10 项：sfx/bgm 音量（0~1，写口钳制）+ 震屏/伤害数字开关（GameFeel/Popup 入口短路）
# + 特效质量三档（R19）+ 挂机自动选择开关 / 自动重开档（R188 idle，GameLoop 消费）
# + R194：fx_opacity 特效透明度观感旋钮 / fps_cap 移动端帧率上限（两键双注册缺一不可——
#   SETTINGS_DEFAULTS 缺行则读口回 null，_normalized_setting 缺分支则写口静默丢弃）。
# 读口缺键 = 默认表回退（旧档无 settings 段自动出厂值，降级不崩；R194 新键旧档
# 缺键同口径零迁移）。
const SETTINGS_DEFAULTS: Dictionary = {
	"sfx_volume": 0.8,                        # 音效音量（线性 0~1）
	"bgm_volume": 0.6,                        # 音乐音量（线性 0~1）
	"shake_on": true,                         # 震屏开关（只关震动，顿帧打击感保留）
	"damage_numbers_on": true,                # 伤害数字开关（低端机福音；结算不受影响）
	"fx_quality": 2,                          # 特效质量（R19：2 高 / 1 中 / 0 低——跳字上限/
	                                          # 合并窗/粒子爆发/元素特效全档位化，buff 叠多层卡顿救）
	"fx_opacity": 1.0,                        # R194：特效透明度观感旋钮（写口 clampf 0.3~1.0；
	                                          # 乘 modulate.a 口径，非提帧手段——提帧走 fx_quality 档）
	"auto_select_on": false,                  # R188 挂机：升级选卡自动选择 + 黑市自动出击（HUD 右上 AUTO 开关）
	"auto_restart_mode": 0,                   # R188 挂机重开档（0 停在结算 / 1 死亡自动重开 / 2 通关自动无尽+死亡重开）
	"fps_cap": 60,                            # R194：移动端帧率上限（写口 clampi 0~144；0=不限；
	                                          # 仅 mobile 门内应用 Engine.max_fps，桌面/headless 保持 0 不被改）
	"panel_pos": 0,                           # R196 构筑面板位置（0=右上 1=右下 2=左下；HUD 三档锚/offset 落位）
}
var _settings: Dictionary = {}                # key(String) → 值（缺键 = 默认表回退）


func settings(p_key: String) -> Variant:
	# 读口：已存值优先，否则默认表回退（未知键 → null）
	if _settings.has(p_key):
		return _settings[p_key]
	return SETTINGS_DEFAULTS.get(p_key)


func set_setting(p_key: String, p_value: Variant) -> void:
	# 写口：类型/范围归一 → 写即存（同 character_id 口径）；未知键忽略（防脏写穿档）
	var normed: Variant = _normalized_setting(p_key, p_value)
	if normed == null:
		return
	_settings[p_key] = normed
	_save()
	settings_changed.emit(p_key)


func _normalized_setting(p_key: String, p_value: Variant) -> Variant:
	# 键白名单 + 类型/范围归一（写口与 _load 共用真源；未知键 → null）
	match p_key:
		"sfx_volume", "bgm_volume":
			return clampf(float(p_value), 0.0, 1.0)
		"shake_on", "damage_numbers_on", "auto_select_on":
			return bool(p_value)
		"fx_quality":
			return clampi(int(p_value), 0, 2)
		"auto_restart_mode":
			return clampi(int(p_value), 0, 2)
		"fx_opacity":                             # R194：观感旋钮 clampf(0.3,1.0)——双注册另一半，
		                                          # 缺本分支则写口静默丢弃（settings() 读回默认 1.0）
			return clampf(float(p_value), 0.3, 1.0)
		"fps_cap":                                # R194：帧率上限 clampi(int,0,144)，0=不限——
		                                          # 应用侧仅 mobile 门内生效（_apply_fps_cap）
			return clampi(int(p_value), 0, 144)
		"panel_pos":                              # R196：构筑面板位置 clampi(int,0,2)——双注册另一半，
		                                          # 缺本分支则写口静默丢弃（settings() 读回默认 0）
			return clampi(int(p_value), 0, 2)
	return null


func upgrade_level(p_id: StringName) -> int:
	return int(upgrades.get(String(p_id), 0))


func upgrade_cost(p_id: StringName) -> int:
	for u in UPGRADES:
		if u.id == p_id:
			return int(u.base_cost) * (upgrade_level(p_id) + 1)
	return 1 << 30


func buy_upgrade(p_id: StringName) -> bool:
	# 购买永久升级（ crystals 不足 / 已满级 → false，大厅按钮置灰口径）
	var max_lv := 0
	for u in UPGRADES:
		if u.id == p_id:
			max_lv = int(u.max_lv)
	if upgrade_level(p_id) >= max_lv:
		return false
	var cost := upgrade_cost(p_id)
	if crystals < cost:
		return false
	crystals -= cost
	upgrades[String(p_id)] = upgrade_level(p_id) + 1
	_save()
	return true


func hp_bonus() -> float:
	return float(upgrade_level(&"life")) * 10.0


func atk_pct() -> float:
	return float(upgrade_level(&"atk")) * 0.04


func magnet_pct() -> float:
	return float(upgrade_level(&"magnet")) * 0.15


func skill_cdr_pct() -> float:
	return float(upgrade_level(&"cdr")) * 0.08


func xp_pct() -> float:
	return float(upgrade_level(&"xp_gain")) * 0.08


func start_gold() -> int:
	return int(upgrade_level(&"start_gold")) * 20


func reroll_bonus() -> int:
	return int(upgrade_level(&"reroll"))


func revive_charges() -> int:
	return int(upgrade_level(&"revive"))


func set_character_id(p_id: StringName) -> void:
	# 选择守卫（2026-09-13 解锁矩阵）：锁定角色拒绝选用（UI 选用按钮本就只对解锁
	# 角色上架——此为程序化路径兜底；直接字段写不受守卫约束 = 测试探针口径）
	if not is_character_unlocked(p_id):
		push_warning("[Meta] 角色未解锁（%s）——拒绝选用" % String(p_id))
		return
	character_id = p_id
	_save()


func is_character_unlocked(p_id: StringName) -> bool:
	# 角色解锁矩阵（2026-09-13 用户反馈「一些通关，一些购买，一些成就解锁」）：
	# unlock_map = 通关某图（派生自 maps_cleared——零新增存档字段）；
	# unlock_kills = 图鉴累计击杀；unlock_achievement = 成就达成（achievements_done）；
	# unlock_price = 结晶购买（unlocked_characters 永久记录——唯一新增存档键）。
	# 空 = 初始角色（sentinel）恒解锁。
	var def := CharacterTable.get_character(p_id)
	var unlock_map: StringName = def.get("unlock_map", &"")
	if unlock_map != &"":
		return is_map_cleared(unlock_map)
	if bool(def.get("unlock_normal_clear", false)):
		return normal_cleared()               # R186：改造者·枢（任一地图常规局普通通关）
	if bool(def.get("unlock_hard_clear", false)):
		return hard_cleared()                 # R186：回响·伊可（任意地图困难/地狱通关）
	var unlock_kills := int(def.get("unlock_kills", 0))
	if unlock_kills > 0:
		return int(records["total_kills"]) >= unlock_kills
	var unlock_achievement: StringName = def.get("unlock_achievement", &"")
	if unlock_achievement != &"":
		return achievements_done.has(String(unlock_achievement))
	var unlock_price := int(def.get("unlock_price", 0))
	if unlock_price > 0:
		return unlocked_characters.has(String(p_id))
	return true


func purchase_character(p_id: StringName) -> bool:
	# 结晶购买角色（永久解锁；不足/已解锁/无价格 → false——UI 解锁按钮置灰口径）
	var def := CharacterTable.get_character(p_id)
	var price := int(def.get("unlock_price", 0))
	if price <= 0 or unlocked_characters.has(String(p_id)):
		return false
	if crystals < price:
		return false
	crystals -= price
	unlocked_characters[String(p_id)] = true
	_save()
	return true


# ── 每日挑战（P2：固定种子 + 当日词缀 + daily_best，不混常规记录） ──
# 诅咒/祝福池（与 map_table.gd 双词缀同源同值——复用 GameLoop._apply_affix_ids 数值表）
const CURSE_POOL: Array[StringName] = [&"curse_swarm", &"curse_frost_armor",
	&"curse_swift_demon", &"curse_toxic_skin", &"curse_mire"]
const BLESS_POOL: Array[StringName] = [&"bless_harvest", &"bless_frost_crystal",
	&"bless_fervor", &"bless_nurture", &"bless_rich_vein"]


static func daily_date_key(p_ymd: Dictionary = {}) -> String:
	# 本地日期键 YYYYMMDD（p_ymd = {year,month,day} 参数化供测试 mock 跨日；缺省 = 系统当日）
	var ymd: Dictionary = p_ymd if not p_ymd.is_empty() else Time.get_date_dict_from_system()
	return "%04d%02d%02d" % [int(ymd.get("year", 0)), int(ymd.get("month", 0)), int(ymd.get("day", 0))]


static func daily_seed(p_date_key: String) -> int:
	# 当日固定种子（日期字符串哈希）：同日恒同 / 跨日必变——全玩家同日同配置口径
	return p_date_key.hash()


static func daily_affixes(p_date_key: String) -> Dictionary:
	# 当日词缀组合（由日期种子决定）：日期种子 RNG → 诅咒池不重复抽 2 + 祝福池抽 1
	#（局部 RandomNumberGenerator，零全局 RNG 副作用）
	var rng := RandomNumberGenerator.new()
	rng.seed = daily_seed(p_date_key)
	var pool := CURSE_POOL.duplicate()
	var curses: Array[StringName] = []
	for i in range(2):
		var idx := rng.randi_range(0, pool.size() - 1)
		curses.append(pool[idx])
		pool.remove_at(idx)
	var bless: StringName = BLESS_POOL[rng.randi_range(0, BLESS_POOL.size() - 1)]
	return {"curses": curses, "bless": bless}


static func affix_name(p_id: StringName) -> String:
	# 词缀展示名（复用 map_table 双词缀命名——零重复文案源）
	for m in MapTable.MAPS:
		if StringName(String(m.get("curse_id", ""))) == p_id:
			return String(m.get("curse_name", ""))
		if StringName(String(m.get("bless_id", ""))) == p_id:
			return String(m.get("bless_name", ""))
	return String(p_id)


func set_run_daily(p_daily: bool) -> void:
	# 当前局每日标记（GameLoop.start_run 注入；结算分流判据）
	_run_daily = p_daily


func is_run_daily() -> bool:
	return _run_daily


func daily_record(p_date_key: String = "") -> Dictionary:
	# 当日（或指定日）daily_best：{best_wave, best_kills}；无记录 → 空 Dictionary
	var key: String = p_date_key if p_date_key != "" else daily_date_key()
	var rec: Variant = daily_records.get(key, {})
	return rec if rec is Dictionary else {}


func record_daily_result(p_wave: int, p_kills: int) -> void:
	# daily_best 落账（波次/击杀各取历史最大；随结算落盘）
	var key := daily_date_key()
	var rec := daily_record(key)
	rec["best_wave"] = maxi(int(rec.get("best_wave", 0)), p_wave)
	rec["best_kills"] = maxi(int(rec.get("best_kills", 0)), p_kills)
	daily_records[key] = rec
	_save()


func _ready() -> void:
	_expand_achievements()   # R191：阶梯展开先行（_load 存档读入 / _build_ach_buckets 分桶均消费全表）
	_load()
	_apply_fps_cap()         # R194：_load 后按存档值应用移动端帧率上限（桌面/headless 空操作）
	_build_ach_buckets()
	settings_changed.connect(_on_settings_changed)   # R194：fps_cap 写口即时重应用
	EventBus.enemy_killed.connect(_on_enemy_killed)
	EventBus.card_chosen.connect(_on_card_chosen)
	EventBus.wave_started.connect(_on_wave_started)
	EventBus.level_up.connect(_on_level_up)
	EventBus.wave_cleared.connect(_on_wave_cleared)
	EventBus.reaction_triggered.connect(_on_reaction_triggered)   # R192：反应族成就计数
	EventBus.state_changed.connect(_on_state_changed)


# ── R194：移动端帧率上限应用器（设置底座单点） ────────────────────
func _apply_fps_cap() -> void:
	# 仅 OS.has_feature("mobile") 门内应用到 Engine.max_fps——桌面/headless 保持 0
	# 不被改（护桌面 120Hz 高刷基准；headless 探针口径：本门 false 时零写点）。
	# 禁写 project.godot 全局 max_fps/vsync；physics_ticks_per_second=120 与
	# DebugStats FRAME_BUFFER_CAPACITY=7200 均不动。
	# R194 修复环：fps_cap=0（不限）须显式归零复位——本函数经 settings_changed 即时
	# 重应用（:481），60/90/120 切「不限」时若沿旧口径 cap==0 不赋值，Engine.max_fps
	# 残留旧帽（UI 显示不限实际仍被钳，重启才解除）；「缺省即 0」仅 boot 冷启动成立。
	if not OS.has_feature("mobile"):
		return
	Engine.max_fps = int(settings("fps_cap"))    # clampi(0,144)：0=不限（复位帽）


func _on_settings_changed(p_key: String) -> void:
	# R194：设置变更即响——本管理器目前只消费 fps_cap（fx_opacity 由 GameLoop
	# 单源应用器订阅，勿在此并入）；其余键沿用各自消费侧既有订阅口径。
	if p_key == "fps_cap":
		_apply_fps_cap()


func _on_wave_cleared(p_wave: int) -> void:
	# 地图通关判定（M2）：清场波次 ≥ 当前地图最终波 → 标记通关（解锁下一关，用户反馈）
	var final_wave := int(MapTable.get_map(_run_map).get("final_wave", 1 << 30))
	if p_wave >= final_wave:
		mark_map_cleared(_run_map)


# ── 地图进度（M2 多地图，用户反馈「第一大关通关后打后面的」） ──────
func set_run_difficulty(p_d: int) -> void:
	# E11：GameLoop 开局/续档注入（结算分档键 + 结晶乘区源）
	_run_difficulty = clampi(p_d, 0, 2)


func set_run_map(p_map_id: StringName) -> void:
	_run_map = p_map_id


func run_map_id() -> StringName:
	# 当前局地图 id（MechanicGate 解锁门查询口）；无局 → 空串（门控全开口径）
	return _run_map


func is_map_cleared(p_map_id: StringName) -> bool:
	return maps_cleared.has(String(p_map_id))


func is_map_unlocked(p_map_id: StringName) -> bool:
	# 第一关恒解锁；其余 = 上一关已通关
	var idx := MapTable.get_map_index(p_map_id)
	if idx <= 0:
		return true
	return is_map_cleared(MapTable.MAPS[idx - 1].id)


func mark_map_cleared(p_map_id: StringName) -> void:
	if not maps_cleared.has(String(p_map_id)):
		maps_cleared[String(p_map_id)] = true
		_check_achievements_of([&"maps_cleared"])   # R191：地图族成就桶查（通关数前进才可能新解锁）
		_save()


func endless_depth(p_map_id: StringName) -> int:
	# 分图无尽深度（P1 无尽分图延伸 2026-08-31）：该图历史最深的「超出最终波波数」；
	# 旧档无键 / 未记录 → 0（降级不崩）
	var mr: Variant = map_records.get(String(p_map_id), {})
	if mr is Dictionary:
		return int((mr as Dictionary).get("endless_depth", 0))
	return 0


func cleared_count() -> int:
	return maps_cleared.size()


# ── 查询口（大厅 UI） ─────────────────────────────────────────────
func is_ach_done(p_id: StringName) -> bool:
	return achievements_done.has(String(p_id))


func achievement_count() -> Vector2i:
	# (已完成, 总数)
	var done := 0
	for a in ACHIEVEMENTS:
		if is_ach_done(a.id):
			done += 1
	return Vector2i(done, ACHIEVEMENTS.size())


func codex_kill_count(p_enemy_id: StringName) -> int:
	return int(codex_kills.get(String(p_enemy_id), 0))


func normal_cleared() -> bool:
	# R88 高难度解锁门：任意地图普通难度通关（best_wave ≥ final_wave，键无 # 后缀）
	for key: Variant in map_records.keys():
		var ks := String(key)
		if ks.contains("#"):
			continue                          # 困难/地狱分档记录不算
		var final_wave := int(MapTable.get_map(ks).get("final_wave", 1 << 30))
		if int(map_records[key].get("best_wave", 0)) >= final_wave:
			return true
	return false


func hard_cleared() -> bool:
	# R186 echo 解锁门：任意地图困难（#1）/地狱（#2）通关。★必须剥掉 "#N" 后缀再查
	# MapTable——get_map 是精确 id 匹配（map_table.gd 未命中返回 {}），带后缀查表必空 →
	# final_wave 回退 1<<30 → 恒 false（echo 永不解锁）。normal_cleared 既有口径不动。
	for key: Variant in map_records.keys():
		var ks := String(key)
		if not (ks.ends_with("#1") or ks.ends_with("#2")):
			continue                          # 普通键（无后缀）不算
		var map_id := StringName(ks.get_slice("#", 0))   # 剥后缀还原地图 id
		var final_wave := int(MapTable.get_map(map_id).get("final_wave", 1 << 30))
		if int(map_records[key].get("best_wave", 0)) >= final_wave:
			return true
	return false


func mark_first_met(p_enemy_id: StringName) -> bool:
	# E5 首遇提示：第一次实际刷出 → true（调用方发机制提示条）；此后 false 不再打扰
	var key := String(p_enemy_id)
	if codex_first_met.has(key):
		return false
	codex_first_met[key] = true
	# 首遇标记与击杀计数同口径：不立即落盘（GAME_OVER 结算统一 _save——防高频 IO）
	return true


func is_weapon_unlocked(p_id: StringName) -> bool:
	return codex_weapons.has(String(p_id))


func custom_weapon() -> StringName:
	# R186：fission 自定义首发读口（"" → StringName("")，GameLoop 侧兜底手枪）
	return StringName(custom_weapon_id)


func set_custom_weapon(p_id: StringName) -> void:
	# R186：fission 自定义首发写口——W1_pistol 白名单（卡池永久排除 W1，必须放行）∪
	# 图鉴已解锁；校验不过 push_warning 忽略（不写不落盘）。写即落盘。
	if p_id != &"W1_pistol" and not is_weapon_unlocked(p_id):
		push_warning("[Meta] 首发武器未解锁（%s）——忽略" % String(p_id))
		return
	custom_weapon_id = String(p_id)
	_save()


func mark_weapon_codex(p_id: StringName) -> bool:
	# R186：武器注入即计图鉴（开局首发/echo 随机武装白拿口径——不增 _run_weapons_drawn，
	# 军火大亨成就仍是卡池抽卡口径）。幂等：已解锁 → false 不重复发 codex_changed。
	# 不立即落盘（同 mark_first_met——随结算统一 _save，防高频 IO）。
	var key := String(p_id)
	if key.is_empty() or codex_weapons.has(key):
		return false
	codex_weapons[key] = true
	codex_changed.emit()
	return true


func reset_weapon_codex() -> int:
	# R196 自救口（定案 wunlock T5 可选自救——设置页「重置武器图鉴」动作消费；2026-09-13
	# 前测试套件写真实档可致武器图鉴满档残留，此前无自救路径）：只清 codex_weapons 全部
	# + codex_first_met 的 W_ 前缀键（首遇横幅随重抽重走）。不碰 achievements_done（已
	# 达成成就不回收——正奖励不追惩）、不动存档段结构与 settings 键（codex 段键集不变，
	# 零 DataValidator 负担）。返回清除的武器图鉴条目数（UI 反馈文案用）。
	var cleared := codex_weapons.size()
	codex_weapons.clear()
	for key_v: Variant in codex_first_met.keys():
		if String(key_v).begins_with("W_"):
			codex_first_met.erase(key_v)
	codex_changed.emit()
	_save()
	return cleared


func is_trait_unlocked(p_id: StringName) -> bool:
	return codex_traits.has(String(p_id))


# ── R196 反应图鉴「已触发」标记（图鉴锁读口：menu_screen 反应行锁定态消费） ──
func is_reaction_seen(p_rxn_id: StringName) -> bool:
	# 读口：键 = GameConst.ReactionType 成员 id 字符串（如 "RXN_FIR_ICE"）→ true
	return reaction_seen.has(String(p_rxn_id))


func mark_reaction_seen(p_rxn_id: StringName) -> bool:
	# 首见标记（幂等：已标记 → false 不重复发 codex_changed）。reaction_seen 即存档键
	#（codex/reaction_seen）——首见写 dict + codex_changed + 即时 _save；批内
	#（_persist_defer_depth>0）_save 自挂起、由 end_persist_defer 收口统一落盘（口径同成就）。
	var key := String(p_rxn_id)
	if key.is_empty() or reaction_seen.has(key):
		return false
	reaction_seen[key] = true
	codex_changed.emit()
	if _persist_defer_depth == 0:
		_save()
	return true


# ── 事件消费 ──────────────────────────────────────────────────────
func _on_enemy_killed(p_enemy: Node2D) -> void:
	var data: Variant = p_enemy.get("data")
	var eid := StringName(str(data.get("id"))) if data != null else &""
	_run_kills += 1
	records["total_kills"] = int(records["total_kills"]) + 1
	if eid != &"":
		codex_kills[String(eid)] = codex_kill_count(eid) + 1
	# 位运算次序：先归一取值再 & TAG_BOSS（旧写法 `& TAG_BOSS` 只作用于三元 else 的字面量
	# 0，真实 tags 整值放行——精英击杀误计 Boss 击杀，「击败首个 Boss」成就提前解锁发结晶）
	var etags: int = int(p_enemy.get("tags")) if p_enemy.get("tags") != null else 0
	if (etags & GameConst.TAG_BOSS) != 0:
		_run_boss_slain += 1
		# R189 成就增量检查：击杀事件只动 total_kills/enemy_kills/boss_slain 三类计数——按桶查
		#（此前每次击杀构建 7 键字典 + 11 项全表扫，为击杀热路径常量税；语义不变：
		# 其余类型计数本事件未动，不可能新解锁。R191：enemy_kills 单敌阶梯桶并入——
		# 计数同源 codex_kills，本事件至多推进一只敌；eid 空（无 data）则本桶扫为空操作）
		_check_achievements_of([&"total_kills", &"boss_slain", &"enemy_kills"])
	else:
		_check_achievements_of([&"total_kills", &"enemy_kills"])
	# 击杀侧不落盘（高频事件；计数随 GAME_OVER 结算统一落盘——防测试/高频帧 IO 风暴）


func _on_card_chosen(p_card_id: StringName, p_kind: int) -> void:
	# kind = CardGenerator.CardKind（1=TRAIT / 4=WEAPON；菜单图鉴解锁口径）
	match p_kind:
		4:
			if String(p_card_id) != "" and not codex_weapons.has(String(p_card_id)):
				codex_weapons[String(p_card_id)] = true
				_run_weapons_drawn += 1
				codex_changed.emit()
			_check_achievements_of([&"run_weapons_drawn", &"codex_weapons"])   # R191：收集桶并入
		1:
			if String(p_card_id) != "" and not codex_traits.has(String(p_card_id)):
				codex_traits[String(p_card_id)] = true
				_run_traits_drawn += 1
				codex_changed.emit()
			_check_achievements_of([&"run_traits_drawn", &"codex_traits"])     # R191：收集桶并入
	# R189 连升溢出批摊薄：批内抑制落盘（批收口统一 _save；单卡逐张 ConfigFile 同步
	# 磁盘写是溢出批收口巨冻的主头——47,954 张 × 同步写）；批外单卡语义保持
	if _persist_defer_depth == 0:
		_save()


func _on_wave_started(p_wave: int) -> void:
	_run_max_wave = maxi(_run_max_wave, p_wave)
	_check_achievements_of([&"run_wave"])


func _on_level_up(p_level: int) -> void:
	_run_max_level = maxi(_run_max_level, p_level)
	_check_achievements_of([&"run_level"])


func _on_reaction_triggered(p_rxn: int, _pos: Vector2, _target_uid: int) -> void:
	# R196 首行：图鉴「已触发」标记（标记接线在既有订阅内，event_bus.gd 零改动、战斗
	# 代码零改动）——find_key 转成员 id 字符串；坏 rxn → find_key 为 null → 显式跳过
	#（String(null) 在 4.3 为运行期错不能裸转），键集恒 ⊆ReactionType id，降级不崩。
	var rxn_key: Variant = GameConst.ReactionType.find_key(p_rxn)
	if rxn_key != null:
		mark_reaction_seen(StringName(String(rxn_key)))
	# R192 反应族成就计数（run 域，沿 run_traits_drawn 全链模式零存档键——计数随
	# GAME_OVER 结算统一落盘）。每反应恰 1 计：既有 3 反应与新矩阵同被计数，双计防护
	# 在总线发点侧（真管线 + 超导补发共用 reaction_triggered，每反应恰 1 发）。
	# R199 F17 口径更正：燎原传火已改发独立表现通道 burn_spread_ignited（elemental_system
	# 传火臂），不再冒用 reaction_triggered——本口自此恒只认真反应（无配对事件可混入，
	# 无需本口过滤）；图鉴「已触发」/成就计数不再被非反应事件虚增。
	# _check_achievements_of 批内抑制语义同其余事件口（deferral 期挂起，收口统一补检）。
	_run_reactions += 1
	_check_achievements_of([&"run_reactions"])


func _on_state_changed(p_state: int) -> void:
	if p_state != GameConst.GameStatus.GAME_OVER:
		return
	# R62 通关延迟结算：通关屏「继续挑战·无尽」决策期不结算——玩家选重开/回菜单时由
	# GameLoop 调 settle_now() 兑现；选无尽继续则整局合并到死亡 GAME_OVER 时一次结算
	#（防重复 total_runs++ / 重复结晶产出）
	if _settle_deferred:
		return
	_settle_run_result()


func _settle_run_result() -> void:
	# 局结算（每日分流 → 全局/分图记录 + 结晶 + 成就 + 落盘 + 单局计数复位）
	# 每日挑战结算分流（P2）：只记 daily_best（波次+击杀）——不混常规 records/map_records/
	# 结晶/成就（当日独立口径），单局计数复位后即返
	if _run_daily:
		record_daily_result(_run_max_wave, _run_kills)
		_reset_run_counters()
		return
	# 局结算：最高记录（全局 + 分图）+ 局数 + 成就 + 落盘 + 单局计数复位
	var normal_before := normal_cleared()     # R186：解锁翻转基线（落账前快照——胜利屏当场查询必 false，提示只挂结算兑现点）
	var hard_before := hard_cleared()         # R198（二aw-6）：echo 解锁翻转基线（落账前快照——同 normal_before 口径）
	records["best_wave"] = maxi(int(records["best_wave"]), _run_max_wave)
	records["best_kills"] = maxi(int(records["best_kills"]), _run_kills)
	records["best_level"] = maxi(int(records["best_level"]), _run_max_level)
	records["total_runs"] = int(records["total_runs"]) + 1
	crystals += int(ceil((_run_max_wave * 1.5 + _run_kills / 25.0)
		* GameConst.difficulty_crystal_mult(_run_difficulty)))   # E11：难度结算加成
	var mkey := String(_run_map) + ("" if _run_difficulty == 0 else "#%d" % _run_difficulty)
	if not map_records.has(mkey):
		map_records[mkey] = {"best_wave": 0, "best_kills": 0, "best_level": 1}
	var mr: Dictionary = map_records[mkey]
	mr["best_wave"] = maxi(int(mr["best_wave"]), _run_max_wave)
	mr["best_kills"] = maxi(int(mr["best_kills"]), _run_kills)
	mr["best_level"] = maxi(int(mr["best_level"]), _run_max_level)
	# 无尽深度（分图无尽 P1）：本局最深超出该图最终波的波数（不足为 0）
	var final_wave := int(MapTable.get_map(_run_map).get("final_wave", 1 << 30))
	mr["endless_depth"] = maxi(int(mr.get("endless_depth", 0)), maxi(0, _run_max_wave - final_wave))
	_check_achievements()
	_save()
	if not normal_before and normal_cleared():
		fissioner_unlocked.emit()             # R186：普通通关当场兑现（恰发一次；每日分流不走此路天然不解锁）
	if not hard_before and hard_cleared():
		echo_unlocked.emit()                  # R198（二aw-6）：困难/地狱通关当场兑现（恰发一次，同上行注释口径；
		                                      # 每日分流语义与 fission 对齐——每日局提前返程不落分档记录，天然不解锁）
	_reset_run_counters()


var _settle_deferred: bool = false             # R62 通关延迟结算位（见 _on_state_changed 注释）


func defer_settle_once() -> void:
	# R62：标记下一局 GAME_OVER 先不自动结算（GameLoop 通关路径调用；本局仅一次）
	_settle_deferred = true


func cancel_deferred_settle() -> void:
	# R62：玩家选「继续挑战·无尽」——延迟结算取消（本局合并到之后死亡时一次结算）
	_settle_deferred = false


func settle_now() -> void:
	# R62：兑现延迟结算（通关屏玩家选重开/回菜单时 GameLoop 调用；无待兑现则空操作）
	if not _settle_deferred:
		return
	_settle_deferred = false
	_settle_run_result()


func _reset_run_counters() -> void:
	# 单局计数复位（常规/每日结算共用收尾）
	_run_kills = 0
	_run_max_wave = 0
	_run_max_level = 1
	_run_weapons_drawn = 0
	_run_traits_drawn = 0
	_run_reactions = 0                        # R192：反应族计数随结算复位
	_run_boss_slain = 0


var _ach_by_type: Dictionary = {}            # R189：成就按计数类型分桶（事件侧增量检查）
var _persist_defer_depth: int = 0            # R189：批量收口抑制深度（成就扫描/落盘摊薄）


func _build_ach_buckets() -> void:
	# R189：ACHIEVEMENTS 按计数类型（a.type）分桶——事件处理器只查本事件能推进的
	# 计数桶（计数不变则不可能新解锁，语义与全表扫逐位一致）
	for a in ACHIEVEMENTS:
		var t := String(a.type)
		if not _ach_by_type.has(t):
			_ach_by_type[t] = []
		_ach_by_type[t].append(a)


func _check_achievements_of(p_types: Array) -> void:
	# R189：按类型桶增量检查（_check_achievements 的子集口——语义一致，热路径减负）
	if _persist_defer_depth > 0:
		return
	for t in p_types:
		for a in _ach_by_type.get(String(t), []):
			_try_unlock(a)


func _counter_value(p_type: String, p_def: Dictionary = {}) -> int:
	match p_type:
		"total_kills":
			return int(records["total_kills"])
		"run_wave":
			return _run_max_wave
		"run_level":
			return _run_max_level
		"run_weapons_drawn":
			return _run_weapons_drawn
		"run_traits_drawn":
			return _run_traits_drawn
		"run_reactions":                          # R192：反应族——单局触发反应数
			return _run_reactions
		"boss_slain":
			return _run_boss_slain
		"total_runs":
			return int(records["total_runs"])
		"enemy_kills":                            # R191：单敌阶梯——按 def.enemy 子键读（同源 codex_kills）
			return codex_kill_count(StringName(String(p_def.get("enemy", ""))))
		"codex_weapons":                          # R191：收集族——图鉴已解锁武器种数
			return codex_weapons.size()
		"codex_traits":                           # R191：收集族——图鉴已解锁词条种数
			return codex_traits.size()
		"maps_cleared":                           # R191：地图族——已通关地图数
			return maps_cleared.size()
	return 0


func _try_unlock(p_ach: Dictionary) -> void:
	var aid := String(p_ach.id)
	if achievements_done.has(aid):
		return
	if _counter_value(String(p_ach.type), p_ach) >= int(p_ach.target):
		achievements_done[aid] = true
		crystals += int(p_ach.get("reward", 0))     # 成就奖励结晶（M8 养成闭环；R191：兜底 0 堵隐性通胀）
		achievements_changed.emit(aid)
		if _persist_defer_depth == 0:
			_save()


func begin_persist_defer() -> void:
	# R189：批量收口抑制（连升溢出批/巨量自动抽卡）——批内成就扫描与 ConfigFile
	# 同步落盘全部挂起，批收口 end_persist_defer 一次结清（成就解锁判定延迟到
	# 批内终态，计数口径与逐张扫描逐位一致）
	_persist_defer_depth += 1


func end_persist_defer() -> void:
	if _persist_defer_depth > 0:
		_persist_defer_depth -= 1
	if _persist_defer_depth == 0:
		_check_achievements()
		_save()


func cancel_persist_defer() -> void:
	# 强制结清（重开/回菜单/结算等批中断路径——不许把抑制态带出批作用域）
	if _persist_defer_depth > 0:
		_persist_defer_depth = 0
		_check_achievements()
		_save()


func _check_achievements() -> void:
	if _persist_defer_depth > 0:
		return
	var counters := {
		"total_kills": int(records["total_kills"]),
		"run_wave": _run_max_wave,
		"run_level": _run_max_level,
		"run_weapons_drawn": _run_weapons_drawn,
		"run_traits_drawn": _run_traits_drawn,
		"run_reactions": _run_reactions,          # R192：反应族计数并入（漏登记 = 补检永久漏检——必加）
		"boss_slain": _run_boss_slain,
		"total_runs": int(records["total_runs"]),
		"codex_weapons": codex_weapons.size(),    # R191：收集/地图族计数并入（enemy_kills per-def 不入单一字典）
		"codex_traits": codex_traits.size(),
		"maps_cleared": maps_cleared.size(),
	}
	var unlocked_any := false
	for a in ACHIEVEMENTS:
		var aid := String(a.id)
		if achievements_done.has(aid):
			continue
		var atype := String(a.type)
		var val: int = _counter_value(atype, a) if atype == "enemy_kills" \
			else int(counters.get(atype, 0))
		if val >= int(a.target):
			achievements_done[aid] = true
			crystals += int(a.get("reward", 0))   # 成就奖励结晶（M8 养成闭环；R191：兜底 0 堵隐性通胀）
			achievements_changed.emit(a.id)
			unlocked_any = true
	if unlocked_any:
		_save()                                   # R191：循环内逐条 _save 移出为函数尾单次（批量补检 K 条恰 1 次写盘）


# ── 持久化 ────────────────────────────────────────────────────────
func _save() -> void:
	if _persist_defer_depth > 0:
		return                                    # R189：批内挂起（收口统一落盘）
	var cfg := ConfigFile.new()
	cfg.set_value("codex", "kills", codex_kills)
	cfg.set_value("codex", "first_met", codex_first_met)
	cfg.set_value("codex", "weapons", codex_weapons.keys())
	cfg.set_value("codex", "traits", codex_traits.keys())
	cfg.set_value("codex", "reaction_seen", reaction_seen.keys())   # R196：反应图鉴已触发集
	cfg.set_value("achievements", "done", achievements_done.keys())
	for key in records:
		cfg.set_value("records", key, records[key])
	cfg.set_value("maps", "cleared", maps_cleared.keys())
	cfg.set_value("maps", "records", map_records)
	cfg.set_value("daily", "records", daily_records)
	cfg.set_value("meta", "crystals", crystals)
	cfg.set_value("meta", "upgrades", upgrades)
	cfg.set_value("meta", "character", String(character_id))
	cfg.set_value("characters", "unlocked", unlocked_characters.keys())
	cfg.set_value("characters", "custom_weapon", custom_weapon_id)   # R186：fission 自定义首发
	cfg.set_value("settings", "values", _settings)
	cfg.save(save_path())


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(save_path()) != OK:
		return                                  # 首启无档（默认值起步）
	var kills: Variant = cfg.get_value("codex", "kills", {})
	if kills is Dictionary:
		codex_kills = kills
		codex_first_met = cfg.get_value("codex", "first_met", {})
	for wid in cfg.get_value("codex", "weapons", []):
		codex_weapons[String(wid)] = true
	for tid in cfg.get_value("codex", "traits", []):
		codex_traits[String(tid)] = true
	for rid in cfg.get_value("codex", "reaction_seen", []):   # R196：逐键回填（旧档缺键→空表）
		reaction_seen[String(rid)] = true
	for aid in cfg.get_value("achievements", "done", []):
		achievements_done[String(aid)] = true
	for key in records:
		records[key] = int(cfg.get_value("records", key, records[key]))
	for mid in cfg.get_value("maps", "cleared", []):
		maps_cleared[String(mid)] = true
	var mrecords: Variant = cfg.get_value("maps", "records", {})
	if mrecords is Dictionary:
		map_records = mrecords
	var drecords: Variant = cfg.get_value("daily", "records", {})
	if drecords is Dictionary:
		daily_records = drecords
	crystals = int(cfg.get_value("meta", "crystals", 0))
	var ups: Variant = cfg.get_value("meta", "upgrades", {})
	if ups is Dictionary:
		upgrades = ups
	character_id = StringName(String(cfg.get_value("meta", "character", "sentinel")))
	unlocked_characters = {}
	for cid in cfg.get_value("characters", "unlocked", []):
		unlocked_characters[String(cid)] = true
	custom_weapon_id = String(cfg.get_value("characters", "custom_weapon", ""))   # R186：旧档缺键回退空→手枪
	# 设置段（P3）：逐键白名单归一（脏档键值丢弃 → 缺键回默认表）
	_settings = {}
	var saved_settings: Variant = cfg.get_value("settings", "values", {})
	if saved_settings is Dictionary:
		for key: Variant in (saved_settings as Dictionary):
			var normed: Variant = _normalized_setting(String(key), (saved_settings as Dictionary)[key])
			if normed != null:
				_settings[String(key)] = normed

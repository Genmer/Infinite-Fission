# scripts/meta/mechanic_gate.gd
# MechanicGate（2026-09-13 用户反馈「机制太多，包括元素反应……大关卡大关卡地解锁，
# 每关都有新体验」）：战斗机制解锁节奏的单一真源。
#
# 设计原则（对齐 A3 §6 掉卡节奏与 M2 通关链）：
# · 节奏表按大关（MapTable.MAPS 下标）推进，小关（波次）不再塞新机制——每张大关一个
#   「新体验主题」，开局 HUD 横幅宣告（EventBus.mechanics_intro），选关面板同步展示。
# · 第 1 关纯射击 + 基础构筑（强化/乘区/机械词条 + 精通 + 初始武器批 + 换一批）；
#   元素状态第 2 关入门（火/冰；双元素齐备时碎裂反应自然初见——预告不压教学）；
#   感电 + 过载/超导第 3 关（紫晶魔域「爆发关」主题呼应）；满层质变第 4 关（构筑
#   深化期才触发得起来）；诅咒博弈第 5 关（终关高风险玩法）。
# · R196 武器准入门（用户反馈「武器需要解锁好像没生效」定案 wunlock）：武器与词条/
#   遗物同范式接大关节奏表（WEAPON_UNLOCK_MAPS 矩阵 + weapon_allowed，门只设在
#   「来源侧」——卡池上架 + echo 双武装池，图鉴「获得解锁」语义与存档面零改动）。
# · 门只设在「来源侧」（卡池上架 + 质变挂载），不动 ElementalSystem 结算核——
#   反应可发生性由元素附着可得性自然涌现（第 1 关无元素卡 → 无状态无反应）。
# · 查询口径：无局态（菜单/测试，Meta.run_map_id 未注入）一律全开——既有行为与
#   293+731 验收基线不受门控影响；进局（start_run/continue_run 已 set_run_map）才收口。
class_name MechanicGate
extends RefCounted

# 各大关「新解锁」文案（下标 = MapTable.MAPS 下标；空串 = 该关无新机制行）。
# 真源注释块：数值/解锁位调整只改这里 + _unlock_flags/WEAPON_UNLOCK_MAPS，两处保持同步。
# R196：第 1 关「新武器」主题改「初始武器批」，第 2 关起各大关补各自新武器行（与矩阵同批定稿）。
const MAP_INTROS: Array[String] = [
	"起点：词条构筑 · 武器精通 · 初始武器批（手枪 · 加特林 · 霰弹枪） · 换一批",
	"元素一期：火 / 冰元素卡（点燃 · 寒滞 · 碎裂初见）｜遗物卡｜新武器：脉冲光束 · 万镜棱镜",
	"感电卡｜新反应：过载 · 超导｜新武器：微型导弹 · 集束火箭",
	"满层质变：词条满层数值 ×1.6｜水元素卡｜新反应：蒸发 · 冻结 · 感电｜新武器：天狼刀 · 旋风刀 · 灵剑 · 裂地斧（环绕力场 · 周期挥斩 重铸归刀）",
	"诅咒博弈：赌徒硬币（第 4 张卡必带诅咒）｜草/风/岩元素卡｜新反应：燃烧 · 激化 · 绽放 · 扩散族 · 结晶族｜新武器：阔剑 · 回旋刃",
]


static func map_index() -> int:
	# 当前局大关下标；无局（菜单/测试）→ -1 = 门控全开口径
	var mid := Meta.run_map_id()
	return MapTable.get_map_index(mid) if mid != StringName("") else -1


# ── 机制门（进局收口，无局全开） ─────────────────────────────────
static func elements_basic_unlocked() -> bool:
	# 火 / 冰元素卡（点燃 / 寒滞）——第 2 关「寒霜冰原」起
	var idx := map_index()
	return idx < 0 or idx >= 1


static func shock_unlocked() -> bool:
	# 感电卡——第 3 关「紫晶魔域」起（过载 / 超导随雷元素补齐而自然可发生）
	var idx := map_index()
	return idx < 0 or idx >= 2


static func water_unlocked() -> bool:
	# 水元素卡——第 4 关「翡翠树海」起（蒸发 / 冻结 / 感电随水元素补齐而自然可发生）
	var idx := map_index()
	return idx < 0 or idx >= 3


static func final_elem_unlocked() -> bool:
	# 风 / 岩 / 草元素卡——第 5 关「翠毒沼泽」起（扩散族 / 结晶族 / 燃烧 / 激化 / 绽放）
	var idx := map_index()
	return idx < 0 or idx >= 4


static func relics_unlocked() -> bool:
	# 遗物卡类目——第 2 关起
	var idx := map_index()
	return idx < 0 or idx >= 1


static func milestone_unlocked() -> bool:
	# 满层质变（×1.6）——第 4 关「翡翠树海」起
	var idx := map_index()
	return idx < 0 or idx >= 3


static func curse_relic_unlocked() -> bool:
	# 赌徒硬币（诅咒卡）——第 5 关「翠毒沼泽」起
	var idx := map_index()
	return idx < 0 or idx >= 4


# ── 消费侧辅助 ───────────────────────────────────────────────────
static func trait_allowed(p_trait: TraitData) -> bool:
	# ELEM 池细粒度过滤：火/冰 第 2 关、雷 第 3 关、水 第 4 关、风/岩/草 第 5 关
	#（R192 八元素显式 match 臂——禁落兜底静默上架）；无 element 键 = 反应家族词条
	# （ELE_REACTION_VOID 反应强化）→ 随反应体系第 3 关开放。
	# MULT 池元素条件乘区（SYN_BURN_DEVOUR 点燃 / SYN_FROST_EXEC 寒滞冻结 / 感电条件）
	# 随对应元素同关开放——无元素的第 1 关不上架死卡；其余池不设门。
	if p_trait == null:
		return true
	if p_trait.pool == GameConst.PoolClass.ELEM:
		match int(p_trait.params.get("element", GameConst.Element.KIN)):
			GameConst.Element.FIR, GameConst.Element.ICE:
				return elements_basic_unlocked()
			GameConst.Element.LTG:
				return shock_unlocked()
			GameConst.Element.HYD:
				return water_unlocked()
			GameConst.Element.ANE, GameConst.Element.GEO, GameConst.Element.DEN:
				return final_elem_unlocked()
		return shock_unlocked()
	if p_trait.pool == GameConst.PoolClass.MULT:
		match int(p_trait.condition.get("condition_id", GameConst.ConditionId.NONE)):
			GameConst.ConditionId.TARGET_FROZEN, GameConst.ConditionId.TARGET_BURNING:
				return elements_basic_unlocked()
			GameConst.ConditionId.TARGET_SHOCKED:
				return shock_unlocked()
	return true


# R199 D06 角色门登记：计费口依赖技能 CD 的遗物。每击谐振（REL_ATTACK_CDR）的收益口
# = relic_handler.gd:386-388 `skill_cd_left <= 0 恒早退`——无技能角色（改造者·枢，
# CharacterTable no_skill 契约）技能 CD 恒 0，且无时之沙式 CDR→射速折算兜底
#（player.gd:559-565 折算清单不含本遗物）→ 金卡零收益。来源侧（上架）收口，
# relic_handler 计费口零改动；有技能角色全角色照常上架。
const SKILL_REQUIRED_RELICS: Array[StringName] = [&"REL_ATTACK_CDR"]


static func relic_allowed(p_relic_id: StringName) -> bool:
	# 遗物按 ID 细粒度过滤：赌徒硬币（诅咒源）仅终关上架，其余随 RELIC 类目同关开放。
	# R199 D06 角色门：技能依赖遗物对无技能角色不上架（has_skill 与 player.gd:649-655
	# activate_skill 短路同源同语义——CharacterTable.has_skill 真源，键缺省 = 有技能；
	# 未知角色 id 回落哨兵 = 有技能，不静默上锁）。无局态（菜单/测试）character_id
	# 缺省哨兵有技能 → 门开，既有验收基线不受扰。
	if p_relic_id == &"REL_GAMBLER":
		return curse_relic_unlocked()
	if SKILL_REQUIRED_RELICS.has(p_relic_id) \
			and not CharacterTable.has_skill(Meta.character_id):
		return false
	return relics_unlocked()


# ── 武器准入门（R196 定案 wunlock；与 trait_allowed/relic_allowed 同款 static） ──
# 矩阵：weapon_id → 首个「可获取」大关下标（MapTable.MAPS 下标；0 = 初始批恒开放）。
# · 零新增存档键：门 = 大关进度派生（同角色 unlock_map 口径 meta_manager.gd:344-353，
#   maps_cleared 既有键即全部持久化面）。
# · 与 MAP_INTROS 同批定稿（上方「两处保持同步」纪律）：矩阵分批 ↔ 选关「新武器」行。
# · 图鉴「获得解锁」语义不变（meta_manager.is_weapon_unlocked 照旧）：门只收窄来源侧
#   上架（卡池 _weapon_candidates + echo 双武装池）；老档 codex_weapons 保留不清洗——
#   获得优先于门，门外已获得武器照常首发/复用。
const WEAPON_UNLOCK_MAPS: Dictionary = {
	&"W1_pistol": 0,          # 首发手枪（恒解锁——白名单语义锚，卡池永久排除）
	&"W2_gatling": 0,         # 初始武器批（第 1 关「起点」）
	&"W3_shotgun": 0,
	&"W4_pulse_beam": 1,      # 激光家族（第 2 关「元素一期」起）
	&"W5_prism": 1,
	&"W6_micro_missile": 2,   # 爆导家族（第 3 关「感电」起）
	&"W7_cluster_rocket": 2,
	&"W8_orbit_field": 3,     # 质变期武器（第 4 关「满层质变」起）
	&"W9_arc_slash": 3,
	&"W11_spirit_sword": 3,   # R243 法器·灵剑（第 4 关「满层质变」起）
	&"W12_ground_axe": 3,     # R243 法器·裂地斧（第 4 关「满层质变」起）
	&"W10_boomerang": 4,      # 终关压轴（第 5 关「诅咒博弈」起）
	&"W13_great_sword": 4,    # R243 近战·阔剑（第 5 关「诅咒博弈」起）
}

# 二dc 难度武器门（用户 2026-10-10「普通不解锁近战和法器，困难解锁一个法器和一
# 个近战，炼狱全部解锁」）：近战/法器族五武器（R243 重组批——W10 回旋刃为投掷类
# 不属此族）按难度分批开放。矩阵：wid → 最低难度（0 普通/1 困难/2 地狱）；未登记
# = 0 不受限（与 WEAPON_UNLOCK_MAPS「漏登记不上锁」同哲学）。与大关门 AND 叠加：
# 难度放行仍须大关进度到位（困难第 1 关不直接出旋风刀——节奏保留，用户可否决）。
const WEAPON_DIFFICULTY_GATE: Dictionary = {
	&"W8_orbit_field": 1,     # 困难起：近战入门（环绕·天狼刀——melee 批首位/挡弹 30% 基线款）
	&"W9_arc_slash": 1,       # 困难起：法器入门（旋风刀——slash 基础形态）
	&"W11_spirit_sword": 2,   # 地狱起：法器·灵剑
	&"W12_ground_axe": 2,     # 地狱起：法器·裂地斧
	&"W13_great_sword": 2,    # 地狱起：近战·阔剑
}


static func weapon_difficulty_min(p_wid: StringName) -> int:
	# 难度矩阵查询（门判定 + 图鉴锁行同源）
	return int(WEAPON_DIFFICULTY_GATE.get(p_wid, 0))


# 二dc H1：族武器名 → 最低难度（intro_for_map 文案过滤单源——名字须与各武器
# display_name 保持同步；非族武器不入表 = 恒保留）
const GATED_WEAPON_NAMES := {
	&"天狼刀": 1, &"旋风刀": 1, &"灵剑": 2, &"裂地斧": 2, &"阔剑": 2,
}


static func weapon_unlock_map_index(p_wid: StringName) -> int:
	# 矩阵查询：未登记武器 → 0（恒开放——新武器入库漏登记不静默上锁，同 map 首关口径）
	return int(WEAPON_UNLOCK_MAPS.get(p_wid, 0))


static func weapon_allowed(p_wid: StringName) -> bool:
	# 武器准入门（无局态全开——菜单图鉴/首发候选/既有 293+731 验收基线不受扰）：
	# 当前局大关下标 ≥ 矩阵下标即开放。二dc：再叠难度门（AND）——近战/法器族按
	# 难度分批；未进局（run_gate_difficulty==-1）不设门（同 map 无局口径）。
	var idx := map_index()
	if idx >= 0 and idx < weapon_unlock_map_index(p_wid):
		return false
	var d := Meta.run_gate_difficulty()
	return d < 0 or d >= weapon_difficulty_min(p_wid)


static func weapon_allowed_progress(p_wid: StringName) -> bool:
	# 进度派生门（R196 评审修复——图鉴三态专用）：菜单态 run_map 是「上一局地图」残留
	#（冷启动默认 FIRST_MAP_ID、quit_to_menu 不清），weapon_allowed 在大厅不可用作
	# 门态基准（冷启动全亮「可获取」假话 / 局后按末局地图漂移）。改按玩家进度派生：
	# 可达关 = 已通关大关数（Meta.cleared_count()，maps_cleared 既有键零新增存档），
	# 可达关 ≥ 矩阵下标即「可获取」；与选关页 MAP_INTROS「新武器」行天然一致。
	return Meta.cleared_count() >= weapon_unlock_map_index(p_wid)


# ── R263 祝福送武器（武器绑定词条 → 附赠武器解析；两门矩阵所在类·纯数据零 rng） ──
static func blessing_gift_weapon(p_td: TraitData, p_weapons: Dictionary) -> StringName:
	# 送武通道单源（GameLoop 挂载口与 BlessingPickUI 附赠行同源复用，不二算）：
	# ① 入通道 = params 含 required_weapon（R65 单值/数组双口径）或 required_class；
	#   二者皆无（纯 required_forms 形态类/无键通用词条）→ 空串不送（形态类无法唯一
	#   确定送哪把，维持不适配不上池）。② 候选集 = required_weapon 武器列表，或仅
	#   required_class 时全武器中 form==MELEE(3) 且 melee.weapon_class∈所列者
	#   （card_generator.mount_gate_allows 同源口径——talisman 法器天然排除）。
	# ③ 选择规则全确定性、与存档状态无关（同一词条恒送同一把——付费可预期）：
	#   难度门最小 → 大关门最早 → id 字典序兜底。拍序比较走 String 字典序
	#   （StringName↔StringName 排序静默无效——_blessing_pool 同源坑；本实现用
	#   最小值扫描非 sort()，语义与 Array[String] 字典序拍序等价）。
	# ④ 送得出 = 候选集非空且 registry 实有（脏 id 剔除后空 → 空串）。p_weapons 由
	#   调用方注入（registry.weapons——MechanicGate 无 registry 实例依赖，
	#   weapon_allowed 纯静态纪律同源）。
	if p_td == null or p_weapons == null or p_weapons.is_empty():
		return StringName("")
	var weapon_req: Variant = p_td.params.get("required_weapon", null)
	var class_req: Variant = p_td.params.get("required_class", null)
	if weapon_req == null and class_req == null:
		return StringName("")                 # 纯形态/通用词条不进送通道
	var candidates: Array[String] = []
	if weapon_req != null:
		if weapon_req is Array:
			for wv in (weapon_req as Array):
				var cand := String(wv)
				if not cand.is_empty() and not candidates.has(cand):
					candidates.append(cand)
		else:
			candidates.append(String(weapon_req))
	else:
		var classes: Array[String] = []
		if class_req is Array:
			for cv in (class_req as Array):
				classes.append(String(cv))
		else:
			classes.append(String(class_req))
		for wid_v: Variant in p_weapons.keys():
			var wd: WeaponData = p_weapons[wid_v]
			if wd == null or int(wd.form) != GameConst.WeaponForm.MELEE:
				continue                  # 类别门只认 MELEE 族（R243 weapon_class 契约）
			var wclass := "melee"
			if wd.melee is Dictionary:
				wclass = String((wd.melee as Dictionary).get("weapon_class", "melee"))
			if classes.has(wclass):
				candidates.append(String(wid_v))
	if candidates.is_empty():
		return StringName("")
	var best := ""
	var best_diff := 1 << 30
	var best_map := 1 << 30
	for cid: String in candidates:
		if not p_weapons.has(StringName(cid)):
			continue                      # 脏 id（registry 无此武器）剔除
		var d := weapon_difficulty_min(StringName(cid))
		var m := weapon_unlock_map_index(StringName(cid))
		if best.is_empty() or d < best_diff or (d == best_diff and m < best_map) \
				or (d == best_diff and m == best_map and cid < best):
			best = cid
			best_diff = d
			best_map = m
	return StringName(best) if not best.is_empty() else StringName("")


static func weapon_locked_line(p_wid: StringName) -> String:
	# 图鉴三态「未解锁」句（单源——UI 禁手抄；大关名走 MapTable 真源）。语义：门开
	# 时点 = 进入矩阵下标大关，其前提 = 通关前一关 → 句子点名「须通关的那一关」。
	# 二dc：难度门需求 >0 的武器尾注难度句（图鉴三态判定仍是进度视角——玩家进度够
	# 但普通局抽不出时，这句解释「为什么图鉴说可获取却不出」）。
	var idx := weapon_unlock_map_index(p_wid)
	var dmin := weapon_difficulty_min(p_wid)
	var dnote := ""
	if dmin >= 2:
		dnote = "（仅地狱难度对局可获取）"
	elif dmin == 1:
		dnote = "（困难起可获取；地狱全开）"
	if idx <= 0:
		return "初始武器批（第 1 关起可获取）%s" % dnote
	var mname := "?"
	if idx - 1 < MapTable.MAPS.size():
		mname = String(MapTable.MAPS[idx - 1].get("name", "?"))
	return "通关「%s」后开放%s" % [mname, dnote]


static func intro_for_map(p_index: int, p_difficulty: int = -1) -> String:
	# 某大关的新机制文案（选关面板行 + 开局横幅共用；越界/第 1 关起有值）。
	# 二dc H1（评审）：p_difficulty ≥0 时按难度过滤「新武器」段中的近战/法器族名
	# （普通局第 4 关行原承诺「天狼刀·旋风刀·灵剑·裂地斧」是假话——与难度门横幅
	# 同屏自相矛盾）；滤空改真实句。默认 -1 = 原文（无难度语境的既有断言/测试面不动）。
	if p_index < 0 or p_index >= MAP_INTROS.size():
		return ""
	var line: String = MAP_INTROS[p_index]
	if p_difficulty < 0 or not line.contains("新武器："):
		return line
	var parts := line.split("｜")
	for i in range(parts.size()):
		if not parts[i].begins_with("新武器："):
			continue
		var seg: String = parts[i].substr("新武器：".length())
		var note := ""
		var paren := seg.find("（")
		if paren >= 0:
			note = seg.substr(paren)
			seg = seg.substr(0, paren)
		var kept: Array[String] = []
		for n_v in seg.split(" · "):
			var n := String(n_v).strip_edges()
			if n.is_empty():
				continue
			if int(GATED_WEAPON_NAMES.get(StringName(n), 0)) <= p_difficulty:
				kept.append(n)
		if kept.is_empty():
			parts[i] = "新武器：无新增（近战/法器族待更高难度解锁）"
		else:
			parts[i] = "新武器：" + " · ".join(kept) + note
		break
	return "｜".join(parts)

# scripts/ui/damage_popup.gd
# M-16 DamagePopup（架构 §2.15）：伤害跳字实体（池化——popup_pool 真件，包 4 收紧目标）。
# 动画：果冻弹跳出现（scale 弹性曲线）+ 上浮 + 淡出（raw 通道驱动，由 PopupManager.tick
# 统一推进——顿帧期间跳字照常，Q-14）。合并：merge() 数值累加 + 重置漂浮计时（E-17）。
# 样式分级：GameConst.PopupStyle（NORMAL/CRIT/REACTION/DOT/HEAL/XP）——圆胖数字 + 藏青描边
# （亮底贴纸字：白色描边托底，任何背景可读）。
# 量级分级（P2，META_ROADMAP §5.10「伤害数字分级」）：单次伤害相对玩家单发基准伤害分
# 白/蓝/紫/金 4 档——大小/颜色/音效三联动（档位判定在 PopupManager 入口，本实体只承担
# 表现：字号乘区 + 档位配色；仅 NORMAL/CRIT 直击样式参与，REACTION/DOT/HEAL/XP 沿旧观感）。
# R186 反应字体：style==REACTION 专属分支——1.8× 大字（54px）+ 加粗描边（12px）+ 每反应
# 描边+填充双色（真主题双通道，替代 self_modulate 单乘色）+ 反应专属字型；element 在反应
# 通道承载 ReactionType 中性 ID（elemental_system.gd:213 约定），先判 style 再查
# REACTION_LOOKS（与元素色同值域中性 ID，防错套）。
# R192 反应矩阵/元素矩阵表现扩容：跳字文案纯函数化——dmg 型 = 反应名+合并值直读、stat 型 =
# 反应名+rxn_stat 短文案段（超导-30%/激化+25%/结晶-15%/冻结1.2s；空串只显名，数值由
# manager 起字读表格式化、禁进 const 文案表）；REACTION_LOOKS 扩 20 反应（名称单源
# GameConst.REACTION_NAMES）；元素配色单源 PopPalette.ELEMENT_COLORS（本地副本已删）。
# R225 渲染首刀·跳字位图化（mobile 门，桌面 Label 路径零扰动）：深载满载跳字 Label 文本
# +描边是渲染 dc 大头——位图门内数值臂（NORMAL/CRIT/DOT/HEAL/XP/IMMUNE/CHARGE_BURST）
# 改走 PopupGlyphAtlas 共享图集的 Sprite2D 序列（同贴图同材质=全跳字合并 1 dc/桶语义），
# _ready 不建 Label（数值臂结构断言=零 Label 节点）；REACTION 臂（反应名大字/文字标签）
# 保留 Label 路径（图集不烘焙反应名——低频必显通道，首次经 _ensure_label 惰性补建）。
# 文本/tint/字号口径与 Label 分支逐位同源（_numeric_text/_bitmap_tint/_bitmap_px）；
# 位图字形刷新无字体排版成本 → R212 限批/R221 脏龄保底逻辑原样保留（保底自然恒满足）。
class_name DamagePopup
extends Node2D

var merged_value: float = 0.0                 # 合并累加值
var style: int = 0                            # GameConst.PopupStyle
var tier: int = 0                             # 量级档 0 白/1 蓝/2 紫/3 金（仅 NORMAL/CRIT 生效）
var target_uid: int = 0                       # 合并窗口判据（同目标）
var is_active: bool = false                   # 池外活跃标记
var text_mode: bool = false                   # §5 契约：REACTION 纯文字桶标记（超导标签；manager 分桶/清退判据）
var rxn_stat: String = ""                     # R192 stat 型反应短文案段（-30%/+25%/1.2s…——manager 起字读
                                              # reaction_table 一次性格式化后前置入；空串 = 只显反应名。
                                              # 池复用经 _reset_state/_clear_reaction_overrides 清空防串文案）

var _label: Label = null
var _glyph_sprites: Array[Sprite2D] = []      # R225 位图臂：数值字形 Sprite 序列（共享图集；
                                              # 池化复用只增不删，退役置 hidden）
var _reaction_styled: bool = false            # §5 契约：反应观感装配标志（_apply/_clear 成对翻转）
var _life_left: float = 0.0                   # 剩余展示时长（s）
var _rise_from: Vector2 = Vector2.ZERO        # 上浮起点（相对坐标基准）
var _bounce_left: float = 0.0                 # 果冻弹跳剩余（合并时小幅重弹）

const LIFE_TIME := 0.6                        # 单段展示时长（s）
const RISE_PX := 42.0                         # 上浮距离 px
const MERGE_LIFE_RESET := 0.35                # 合并后重置的展示时长（短于新起，观感收敛）
const BOUNCE_TIME := 0.22                     # 弹跳时长（s）
const FONT_SIZE := 30                         # 圆胖数字常规字号
const FONT_SIZE_CRIT := 40                    # 暴击加大
const OUTLINE_PX := 8                         # 藏青描边（贴纸感）
const FONT_SIZE_REACTION := 54                # R186 反应大字 1.8×（roundi(30×1.8)；不吃量级档乘区）
const OUTLINE_PX_REACTION := 12               # R186 加粗描边（贴近 8/30 贴纸比例的等比放大）
const CODEX_PREVIEW_SCALE := 0.5              # R192 图鉴反应预览缩放（54px 样张 → 140×78 格内 0.5×；menu_screen 预览 Label 引用）

# 样式配色（方向 C 调色板单源；NORMAL 白底描边 = 亮底可读贴纸字）
const STYLE_COLORS := {
	GameConst.PopupStyle.NORMAL: Color(1.0, 1.0, 1.0),
	GameConst.PopupStyle.CRIT: PopPalette.XP,
	GameConst.PopupStyle.REACTION: PopPalette.SHOCK,
	GameConst.PopupStyle.DOT: Color(1.0, 0.72, 0.45),
	GameConst.PopupStyle.HEAL: PopPalette.SUCCESS,
	GameConst.PopupStyle.XP: PopPalette.INK_SOFT,
	GameConst.PopupStyle.IMMUNE: Color(0.62, 0.68, 0.8),   # R22 免疫：灰蓝（打不动读感）
}

# R22 元素配色（用户点名「反馈数字改为对应颜色」）：R192 起单源 PopPalette.ELEMENT_COLORS
# （键 = Element 序 int 七键，本实体不再持本地副本）——图鉴配方环 / 死亡迸色 / 跳字同源。
# 元素色覆盖量级色；量级信息保留在字号乘区与档音/档震（颜色读元素、大小读量级）

# R186/R192 反应字体规格表：element（反应通道 = ReactionType 中性 ID）→ 名称 + 双色 + 字型 + 文案型。
# 仅 style==REACTION 分支查此表（与元素色同值域中性 ID——先判 style 再索引，防错套）；
# 色值单源 PopPalette.RXN_*（R192 扩 20 反应），名称单源 GameConst.REACTION_NAMES（UI 不手抄）。
# fmt（R192 跳字纯函数口径）：dmg = 名+合并值直读（碎裂1284）；pct/stat = 名+rxn_stat 短文案段
# （超导-30%=pct 百分比统计段 / 激化+25%/结晶-15%/冻结1.2s=stat；rxn_stat 空串 = 只显名——
# 数值一律 manager 起字时读 reaction_table 一次性格式化，禁进 const 文案表；结算分支只认
# dmg，pct 与 stat 同走「名+rxn_stat」臂）。variant 复用 0/1/2 三字型按族分配：
# 0 直立重击（伤害转化直读）/ 1 斜体爆发·连锁（过载/感电/扩散族）/ 2 斜体减益·标签（超导/激化/冻结/燃烧/结晶族）。
const REACTION_LOOKS: Dictionary = {
	GameConst.ReactionType.RXN_FIR_ICE: {
		"name": GameConst.REACTION_NAMES[GameConst.ReactionType.RXN_FIR_ICE],
		"fill": PopPalette.RXN_FILL_SHATTER,
		"outline": PopPalette.RXN_LINE_SHATTER,
		"variant": 0,
		"fmt": "dmg",
	},
	GameConst.ReactionType.RXN_FIR_LTG: {
		"name": GameConst.REACTION_NAMES[GameConst.ReactionType.RXN_FIR_LTG],
		"fill": PopPalette.RXN_FILL_OVERLOAD,
		"outline": PopPalette.RXN_LINE_OVERLOAD,
		"variant": 1,
		"fmt": "dmg",
	},
	GameConst.ReactionType.RXN_ICE_LTG: {
		"name": GameConst.REACTION_NAMES[GameConst.ReactionType.RXN_ICE_LTG],
		"fill": PopPalette.RXN_FILL_SUPER,
		"outline": PopPalette.RXN_LINE_SUPER,
		"variant": 2,
		"fmt": "pct",                            # 超导百分比统计段（-30% 读表 resist_delta×100）
	},
	GameConst.ReactionType.RXN_FIR_HYD: {
		"name": GameConst.REACTION_NAMES[GameConst.ReactionType.RXN_FIR_HYD],
		"fill": PopPalette.RXN_FILL_FIR_HYD,
		"outline": PopPalette.RXN_LINE_FIR_HYD,
		"variant": 0,
		"fmt": "dmg",
	},
	GameConst.ReactionType.RXN_HYD_DEN: {
		"name": GameConst.REACTION_NAMES[GameConst.ReactionType.RXN_HYD_DEN],
		"fill": PopPalette.RXN_FILL_HYD_DEN,
		"outline": PopPalette.RXN_LINE_HYD_DEN,
		"variant": 0,
		"fmt": "dmg",
	},
	GameConst.ReactionType.RXN_FIR_ANE: {
		"name": GameConst.REACTION_NAMES[GameConst.ReactionType.RXN_FIR_ANE],
		"fill": PopPalette.RXN_FILL_FIR_ANE,
		"outline": PopPalette.RXN_LINE_FIR_ANE,
		"variant": 1,
		"fmt": "stat",
	},
	GameConst.ReactionType.RXN_ICE_ANE: {
		"name": GameConst.REACTION_NAMES[GameConst.ReactionType.RXN_ICE_ANE],
		"fill": PopPalette.RXN_FILL_ICE_ANE,
		"outline": PopPalette.RXN_LINE_ICE_ANE,
		"variant": 1,
		"fmt": "stat",
	},
	GameConst.ReactionType.RXN_LTG_ANE: {
		"name": GameConst.REACTION_NAMES[GameConst.ReactionType.RXN_LTG_ANE],
		"fill": PopPalette.RXN_FILL_LTG_ANE,
		"outline": PopPalette.RXN_LINE_LTG_ANE,
		"variant": 1,
		"fmt": "stat",
	},
	GameConst.ReactionType.RXN_HYD_ANE: {
		"name": GameConst.REACTION_NAMES[GameConst.ReactionType.RXN_HYD_ANE],
		"fill": PopPalette.RXN_FILL_HYD_ANE,
		"outline": PopPalette.RXN_LINE_HYD_ANE,
		"variant": 1,
		"fmt": "stat",
	},
	GameConst.ReactionType.RXN_ANE_DEN: {
		"name": GameConst.REACTION_NAMES[GameConst.ReactionType.RXN_ANE_DEN],
		"fill": PopPalette.RXN_FILL_ANE_DEN,
		"outline": PopPalette.RXN_LINE_ANE_DEN,
		"variant": 1,
		"fmt": "stat",
	},
	GameConst.ReactionType.RXN_ICE_HYD: {
		"name": GameConst.REACTION_NAMES[GameConst.ReactionType.RXN_ICE_HYD],
		"fill": PopPalette.RXN_FILL_ICE_HYD,
		"outline": PopPalette.RXN_LINE_ICE_HYD,
		"variant": 2,
		"fmt": "stat",
	},
	GameConst.ReactionType.RXN_LTG_HYD: {
		"name": GameConst.REACTION_NAMES[GameConst.ReactionType.RXN_LTG_HYD],
		"fill": PopPalette.RXN_FILL_LTG_HYD,
		"outline": PopPalette.RXN_LINE_LTG_HYD,
		"variant": 1,
		"fmt": "stat",
	},
	GameConst.ReactionType.RXN_FIR_DEN: {
		"name": GameConst.REACTION_NAMES[GameConst.ReactionType.RXN_FIR_DEN],
		"fill": PopPalette.RXN_FILL_FIR_DEN,
		"outline": PopPalette.RXN_LINE_FIR_DEN,
		"variant": 2,
		"fmt": "stat",
	},
	GameConst.ReactionType.RXN_LTG_DEN: {
		"name": GameConst.REACTION_NAMES[GameConst.ReactionType.RXN_LTG_DEN],
		"fill": PopPalette.RXN_FILL_LTG_DEN,
		"outline": PopPalette.RXN_LINE_LTG_DEN,
		"variant": 2,
		"fmt": "stat",
	},
	GameConst.ReactionType.RXN_FIR_GEO: {
		"name": GameConst.REACTION_NAMES[GameConst.ReactionType.RXN_FIR_GEO],
		"fill": PopPalette.RXN_FILL_FIR_GEO,
		"outline": PopPalette.RXN_LINE_FIR_GEO,
		"variant": 2,
		"fmt": "stat",
	},
	GameConst.ReactionType.RXN_ICE_GEO: {
		"name": GameConst.REACTION_NAMES[GameConst.ReactionType.RXN_ICE_GEO],
		"fill": PopPalette.RXN_FILL_ICE_GEO,
		"outline": PopPalette.RXN_LINE_ICE_GEO,
		"variant": 2,
		"fmt": "stat",
	},
	GameConst.ReactionType.RXN_LTG_GEO: {
		"name": GameConst.REACTION_NAMES[GameConst.ReactionType.RXN_LTG_GEO],
		"fill": PopPalette.RXN_FILL_LTG_GEO,
		"outline": PopPalette.RXN_LINE_LTG_GEO,
		"variant": 2,
		"fmt": "stat",
	},
	GameConst.ReactionType.RXN_HYD_GEO: {
		"name": GameConst.REACTION_NAMES[GameConst.ReactionType.RXN_HYD_GEO],
		"fill": PopPalette.RXN_FILL_HYD_GEO,
		"outline": PopPalette.RXN_LINE_HYD_GEO,
		"variant": 2,
		"fmt": "stat",
	},
	GameConst.ReactionType.RXN_DEN_GEO: {
		"name": GameConst.REACTION_NAMES[GameConst.ReactionType.RXN_DEN_GEO],
		"fill": PopPalette.RXN_FILL_DEN_GEO,
		"outline": PopPalette.RXN_LINE_DEN_GEO,
		"variant": 2,
		"fmt": "stat",
	},
	GameConst.ReactionType.RXN_ANE_GEO: {
		"name": GameConst.REACTION_NAMES[GameConst.ReactionType.RXN_ANE_GEO],
		"fill": PopPalette.RXN_FILL_ANE_GEO,
		"outline": PopPalette.RXN_LINE_ANE_GEO,
		"variant": 2,
		"fmt": "stat",
	},
}


# R192-low1（R198）：stat 统计段读表缺键/枚举错位告警会话一次闸（rxn 键 → true）——
# 静态函数域的「_empty_comp_errored」先例（wave_director.gd:43 同族口径）；可观测供测试断言。
static var _missing_stat_rule_warned: Dictionary = {}


static func reaction_stat_text(p_rxn: int) -> String:
	# R192 收口2：标签统计段格式化器自 popup_manager 上提为静态单源——跳字起字（manager）
	# 与图鉴预览（menu_screen「反应名+数字」组合）共用本函数，防两处文案漂移。
	# 读 reaction_table 一次性格式化（数值真源=表，禁写进 const 文案）：
	# 冻结「1.2s」/ 超导「-30%」/ 结晶「-15%」/ 激化「+25%」/ 燃烧「5层」；
	# 感电/扩散族无统计段 → 空串（只显名——链伤/扩散一击走自身伤害通道另跳数字）。
	# R192-low1（R198）：表缺键/枚举错位（此前静默落 {} → 恒空串不可见）→ push_warning
	# 会话一次（rxn 键闸）后仍返回空串；「表键在位而规则为空 {}」的合法无统计段
	# （感电 RXN_LTG_HYD 等）保持静默零告警——:220 注释口径，禁误报。
	var rule: Dictionary = {}
	if GameConfig.balance != null:
		var key_v: Variant = GameConst.ReactionType.find_key(p_rxn)
		if key_v == null:
			# 枚举错位（rxn 不在 ReactionType 值域——表键无从谈起）
			if not _missing_stat_rule_warned.has(p_rxn):
				_missing_stat_rule_warned[p_rxn] = true
				push_warning("[DamagePopup] reaction_stat_text 枚举错位 rxn=%d（无表键）——返回空串（R192-low1）" % p_rxn)
		else:
			var key := String(key_v)
			if not GameConfig.balance.reaction_table.has(key):
				# 表缺键（键集双射被破坏——DataValidator 闸外的运行时残缺）
				if not _missing_stat_rule_warned.has(key):
					_missing_stat_rule_warned[key] = true
					push_warning("[DamagePopup] reaction_stat_text 表缺键 %s——返回空串（R192-low1）" % key)
			rule = GameConfig.balance.reaction_table.get(key, {})
	if rule.has("freeze_dur"):
		return "%ss" % String.num(float(rule["freeze_dur"]), 1)
	if rule.has("resist_delta"):
		return "%d%%" % roundi(float(rule["resist_delta"]) * 100.0)
	if rule.has("dr"):
		return "-%d%%" % roundi(float(rule["dr"]) * 100.0)
	if rule.has("vuln_mult"):
		return "+%d%%" % roundi((float(rule["vuln_mult"]) - 1.0) * 100.0)
	if rule.has("burn_layers_max"):
		return "%d层" % int(rule["burn_layers_max"])
	return ""

# 量级分档表现参数（P2 数值真源：档位阈值在 PopupManager；此处只落规格——
# 字号乘区 白 1.0 / 蓝 +15% / 紫 +35% / 金 +60%；配色对齐稀有度四色（调色板单源））
const TIER_SCALES: Array[float] = [1.0, 1.15, 1.35, 1.6]
const TIER_COLORS: Array[Color] = [
	Color(1.0, 1.0, 1.0),                        # 白（现状大小/颜色）
	PopPalette.RARITY_RARE,                      # 蓝（天蓝）
	PopPalette.RARITY_EPIC,                      # 紫（葡萄紫）
	PopPalette.RARITY_LEGEND,                    # 金（柠檬金）
]

# R194 fx_opacity：特效透明度全局乘区（Meta settings 键 fx_opacity，clampf(0.3,1.0)，默认 1.0）。
# 跨组契约：乘区 helper 先落本文件（组5·表现），GameLoop 单源应用器（组4·战斗核持有）只写本
# static 值（Meta.settings_changed 订阅侧）；本实体仅在 tick() / _reset_state() 两处 alpha 写点
# 折乘该系数——只乘根 modulate.a，永不写 visible/self_modulate/theme/position/scale
# （fx_quality_cases/elem_immune_cases/verify_feedback_cases 既有锁零触碰）。
static var fx_opacity := 1.0

# ── R230 K1：跳字根 alpha 四分档量化（R229 刀2 elemental_fx_layer.Q_ALPHA_STEPS 同定律） ──
# 根 modulate.a 的全部写点（tick 淡出① / _reset_state 复位②）过 _qa() 落 0.25 步进——
# 跳字根逐帧连续 alpha=逐件唯一 modulate=逐张独立 dc（vc33 定案：位图同图集也不合并）；
# 量化后同图集（位图字形 Sprite 或字体图集 Label）+ 同档位共享 modulate 可合批，dc 从
# live 跳字数坍缩到 ~档数（F8 族夹具预期 34-40→8-16）。位图路径（R227 PopupGlyphAtlas）
# 与 Label 兜底路径行为不变——两路径同走根 modulate，本刀不分路径；渐隐时序语义不变
# （t 驱动逐帧照跑，只改 alpha 写入粒度=4 档阶梯，R229/R217 先例已过评审）。QA 契约：
# tests/runner/test_r230_k1_popup_quant.gd（写点全覆盖 grep 钉 + 双路径回归 + 不串档）。
const Q_ALPHA_STEPS := 4                       # 渐隐量化档数（a ∈ {0, 0.25, 0.5, 0.75, 1.0}）


static func _qa(p_a: float) -> float:
	# alpha 四分档量化（写点处包整体表达式——最终乘积量化；R229 _qa 同式）
	return float(roundi(clampf(p_a, 0.0, 1.0) * Q_ALPHA_STEPS)) / float(Q_ALPHA_STEPS)


func _ready() -> void:
	# 池化实例化期组装。R225 位图门：mobile（或覆写）走共享图集 Sprite 序列且不建 Label
	#（数值臂零 Label 节点/零 Label dc）；桌面门保持既有 Label 装配逐位不变（零扰动）。
	# 门在 _ready 一次性求值，实例生命周期内恒定（池化实例构成不随门翻转重建）。
	if bitmap_gate():
		_label = null
	else:
		_ensure_label()
	visible = false


func _ensure_label() -> Label:
	# R225：Label 惰性装配——位图门 _ready 不建；REACTION 臂（mobile 保留 Label 路径）
	# 首次起字经此一次性补建（低频豁免路径，节点创建 µs 级、排版仍走 R212 限批通道）
	if _label == null:
		_label = Label.new()
		_label.name = "Value"
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		StickerTheme.label_sticker(_label, FONT_SIZE, Color.WHITE, OUTLINE_PX, PopPalette.OUTLINE, true)
		add_child(_label)
	return _label


var element: int = GameConst.Element.KIN      # 命中元素（R22：跳字元素配色）
var _label_dirty: bool = false                # R189：合并期文字脏标记（reset_size 字形
                                              # 排版 ~10µs/次——同帧多合并推迟到 tick 一次刷新）
var _dirty_age: float = 0.0                   # R221 修轮 M5：脏持续时长（秒；清脏即清零）——
                                              # 与寿命无关的饥饿计量（merge 重置寿命不影响龄）
# R221 Fix B/C 测试覆写口：-1=平台自动（mobile 延迟首排版/桌面立即）；0=强制立即；1=强制延迟
static var defer_first_layout: int = -1

# R225 位图门测试覆写口（先例 defer_first_layout 同款 static 口径）：-1=平台自动
#（mobile=位图/桌面=Label）；0=强制 Label 路径；1=强制位图路径（图集未就绪仍回退）。
# 用毕复位 -1（套件纪律，同 label_refresh_cap_override）。
static var bitmap_override: int = -1

# R225 位图门真源：override 优先；平台自动 = mobile。图集未烤完（boot 菜单预热未消化
# 完即开局）恒回退 Label 路径——表现不劣化于现状（R215 先例口径），战斗期零烤图红线。
static func bitmap_gate() -> bool:
	if bitmap_override >= 0:
		return bitmap_override == 1 and PopupGlyphAtlas.ready()
	if not OS.has_feature("mobile"):
		return false
	return PopupGlyphAtlas.ready()


func _defer_first_layout() -> bool:
	# R221 Fix C：首排版分流真源（show_popup 用）——mobile 限批延迟（跳字束刺尖峰
	# 只在 Android 字体排版贵），桌面立即保持字节级零扰动
	if defer_first_layout >= 0:
		return defer_first_layout == 1
	return OS.has_feature("mobile")
# R212 刀5 测试观测口：_refresh_label 执行次数（跳字排版限批断言——40 张脏弹字
# 下一帧刷新数 ≤6 / 全部脏弹字 ≤7 帧内收敛）；进程级累计，套件自取基线差值
static var refresh_label_calls: int = 0

func show_popup(p_pos: Vector2, p_value: float, p_style: int, p_target_uid: int = 0,
		p_tier: int = 0, p_element: int = GameConst.Element.KIN) -> void:
	# 池取出后初始化 + 动画启动（p_tier：量级档，PopupManager 入口判定后传入）
	position = p_pos
	_rise_from = p_pos
	merged_value = maxf(p_value, 0.0)
	style = p_style
	element = p_element
	text_mode = false                             # 起字权威复位（文字桶标记仅超导路径置 true）
	tier = clampi(p_tier, 0, TIER_SCALES.size() - 1)
	target_uid = p_target_uid
	_life_left = LIFE_TIME
	_bounce_left = BOUNCE_TIME
	is_active = true
	# R221 Fix C：首排版按平台分流——mobile 并入 tick 限批通道（新起突发波一帧 20+
	# 新跳字也 ≤6 排版/帧，vc27「跳」尖峰主源；驱动序成立：dispatch 在 ⑧段前、
	# PopupManager.tick 在 _tick_ui，当帧入 _active_list 当帧消化）；桌面（限批帽 0）
	# 保持立即排版——排版结果与既有口径字节级一致，零扰动。
	# R225：位图门下驱动通道原样保留（首刷照走 deferred/tick）——位图字形刷新无字体
	# 排版成本，限批/脏龄保底（R221）逻辑照跑，饥饿面自然恒满足。
	if _defer_first_layout():
		if _label != null:
			_label.text = ""                  # 清上一命残留（避免限批延迟期闪旧数）
		_hide_glyphs()                        # R225：位图字形臂同口径清残留（等 tick 首刷）
		_label_dirty = true
	else:
		_refresh_label()
		_label_dirty = false
	visible = true


func merge(p_value: float, p_style: int = -1, p_element: int = -1) -> void:
	# 合并：数值累加 + 重置漂浮计时（E-17）+ 小幅重弹（果冻反馈）。
	# R189：文字刷新推迟到本帧 tick（风暴形态同帧数十次合并 × reset_size 字形排版
	# 是结算链消费方大头；一帧只渲染一次，中间值本就不可见——显示语义不变）
	#
	# R202 层1 扩参（尾部可选参，默认 -1 = 未传）：默认路径零语义变化——全仓测试唯一
	# 直调 r192_element_cases.gd:727 `p0.merge(34.0)`（宿主 REACTION：升格条件为假、
	# element 不改写，其后断言文本纯函数 f(look, merged_value) 不受影响）；加必选参
	# 该套件编译红且不在五组任何清单——签名扩展硬约束。
	# ① p_style==CRIT 且宿主 NORMAL → 照 upgrade_to_reaction(:318-328) 先例升样式
	#   （_refresh_label 在 tick 读 style——CRIT 基础字号 40px 立即生效）；量级档重判
	#   与档音/档震由 manager 承担（baseline_provider 在彼处，档音 tier>=3 先例）。
	# ② p_element 仅直击宿主（NORMAL/CRIT）改写——异元素连击颜色不得停在第跳；
	#   REACTION 宿主 element 承载 ReactionType 中性 ID（名称/双色真源），并入不改写
	#   保旧语义；DOT/HEAL/XP 等非直击样式不吃元素配色，同样不改写。
	merged_value += maxf(p_value, 0.0)
	if p_style == GameConst.PopupStyle.CRIT and style == GameConst.PopupStyle.NORMAL:
		style = GameConst.PopupStyle.CRIT
	if p_element >= 0 and (style == GameConst.PopupStyle.NORMAL
			or style == GameConst.PopupStyle.CRIT):
		element = p_element
	_life_left = MERGE_LIFE_RESET
	_bounce_left = maxf(_bounce_left, BOUNCE_TIME * 0.6)
	_label_dirty = true


func upgrade_to_reaction(p_value: float, p_rxn: int) -> void:
	# R186 反应升格（PopupManager R2b 专用）：同 uid 直击小字在合并窗内吃到大额反应
	# 结算 → 数值并入 + 原地换反应样式重弹（实例不换、_active_list 不涨）。
	# p_rxn 为反应通道 ReactionType 中性 ID；tier 清零（REACTION 不参与量级档）。
	merged_value += maxf(p_value, 0.0)
	style = GameConst.PopupStyle.REACTION
	element = p_rxn
	tier = 0
	_life_left = MERGE_LIFE_RESET
	_bounce_left = maxf(_bounce_left, BOUNCE_TIME * 0.6)
	# R268 性能刀 P1：升格臂并入 R212 tick 限批（置脏走 tick 刷新，与 merge 通道 :409
	# 同契约）——ms 级 Label 排版（反应臂 _apply_reaction_look+reset_size）逐出派发段
	# （整窗计 diag「派µs」键，vc77 尖峰带 1017-17478µs 实锤成分）；桌面帽 0 同帧
	# tick 刷零扰动，mobile ≤6/帧收敛，超龄保底（popup_manager :500-506 强制臂）不饿死。
	# 零 rng/零分配/popup_manager.gd 零改。
	_label_dirty = true


func tick(p_raw_delta: float, p_refresh_label: bool = true) -> void:
	# 果冻弹跳 + 上浮 + 淡出（raw 通道；到期由管理器归还池）
	# R202 微优化：alpha/position/scale 等值跳过写点——弹跳收敛后（>0.22s）每帧
	# scale==ONE 的重复 Node2D 属性 setter 是 80 池满载时的稳定写开销（80 弹 × 满屏
	# 密度 × 每帧 3 写）；值比较远廉于 setter（写穿 transform 重算），等值跳过零显示
	# 语义差（曲线值不变，只是不再重复写同一个值）
	# R212 刀5：p_refresh_label=false 时排版让渡（脏标记保留，下一驱动帧续）——
	# PopupManager.tick 限批用；默认 true 保持既有调用方（测试直调/管理器不限批
	# 路径）零变化
	if not is_active:
		return
	if _label_dirty and p_refresh_label:
		_refresh_label()                          # R189：本帧合并值一次性排版（帧渲染前）
		_label_dirty = false
		_dirty_age = 0.0                          # R221 修轮 M5：清脏即清龄
	else:
		_dirty_age = _dirty_age + p_raw_delta if _label_dirty else 0.0
	_life_left -= p_raw_delta
	var t := 1.0 - clampf(_life_left / LIFE_TIME, 0.0, 1.0)
	var pos := _rise_from + Vector2(0.0, -RISE_PX * t)
	if pos != position:
		position = pos
	# R194 alpha 写点①：淡出曲线 × fx_opacity 全局特效透明度（只乘根 modulate.a——
	# _label.self_modulate / theme / position / scale 零触碰，fx_quality 既有观感锁不变）。
	# R230 K1：整体表达式过 _qa() 四分档量化——同档共享 modulate 合批；时序语义不变
	# （t 逐帧照算，等值跳过写点纪律原样：同档内重复拍不再触发 setter 写）。
	var a := _qa(fx_opacity * clampf(1.0 - t * t, 0.0, 1.0))
	if a != modulate.a:
		modulate.a = a
	if _bounce_left > 0.0:
		_bounce_left = maxf(_bounce_left - p_raw_delta, 0.0)
		# 弹性生长 + 过冲（0.25 → 峰值 ~1.3 → 1；手绘曲线，无 Tween——池化安全）
		var bt := 1.0 - _bounce_left / BOUNCE_TIME
		var grow := 0.25 + 0.75 * minf(bt * 5.0, 1.0)
		var s := grow * (1.0 + 0.52 * exp(-4.0 * bt) * sin(bt * 14.0))
		scale = Vector2(s, 2.0 - s)
	else:
		if scale != Vector2.ONE:
			scale = Vector2.ONE


func life_left() -> float:
	# 管理器回收判据
	return _life_left


func _reset_state() -> void:
	# 归还清零契约（E-04/E-05）；R186：反应双色主题覆盖同步复位（防池复用串色——
	# 复用槽把小字染成大字残留）
	merged_value = 0.0
	style = 0
	tier = 0
	element = GameConst.Element.KIN
	rxn_stat = ""                                 # R192：stat 型短文案段一并清空（防池复用串文案）
	target_uid = 0
	is_active = false
	_life_left = 0.0
	_bounce_left = 0.0
	# R230 K1：复位同过 _qa()（写点②全包）——复位值恒等 tick 首拍 _qa(fx_opacity×1)，
	# 「复位即带乘区防首帧闪帧」契约在量化口径下原样成立（首帧值与复位值同档）。
	modulate.a = _qa(fx_opacity)                  # R194 alpha 写点②：复位即带乘区（池复用直取可见
	                                             # 前已落 fx_opacity，防 fx_opacity<1 时首帧满亮闪帧）
	scale = Vector2.ONE
	position = Vector2.ZERO
	_rise_from = Vector2.ZERO
	_hide_glyphs()                               # R225：位图字形臂随池归还隐藏（Sprite 节点保留复用）
	_clear_reaction_overrides()


func _refresh_label() -> void:
	# 数值 + 样式刷新（圆胖数字：CRIT 加大字号；量级档叠乘字号 + 档位配色——
	# 仅直击样式 NORMAL/CRIT 吃量级档，REACTION/DOT/HEAL/XP 沿既有配色观感）
	# R225 位图门分流：数值臂（非 REACTION）走共享图集 Sprite 序列（_refresh_bitmap_
	# glyphs——零 Label 排版；判据=门+样式，非 _label==null——池复用实例吃过 REACTION
	# 后 _label 已惰性补建，按 null 判会让后续数值臂永久退化 Label 路径）；REACTION 臂
	# 与桌面门走既有 Label 路径逐位不变。
	refresh_label_calls += 1                     # R212 刀5：测试观测口
	if bitmap_gate() and style != GameConst.PopupStyle.REACTION:
		_refresh_bitmap_glyphs()
		return
	_ensure_label()
	if style == GameConst.PopupStyle.REACTION:
		# R186 反应大字专属分支（规格表分流）：双色主题通道 + 专属字型 + 1.8× 字号——
		# 不走 self_modulate 乘色、不吃量级档（_tier_for 对非直击恒返 0 契约不变）
		# R225：REACTION 走 Label——位图字形臂退位（升格 REACTION 的宿主原为数值臂
		# Sprite 序列显示中，藏之防双渲染）；Label 显示回归（池复用数值臂→REACTION
		# 时 Label 被位图臂置过 hidden，对称复位防文字消失）
		_hide_glyphs()
		_label.visible = true
		_apply_reaction_look()
		_label.reset_size()
		_label.position = -_label.size * 0.5
		return
	# 非 REACTION 分支：复位反应覆盖（池复用串色防线——R186 起每次刷新先还原贴纸底色）
	_clear_reaction_overrides()
	var crit := style == GameConst.PopupStyle.CRIT
	var direct := style == GameConst.PopupStyle.NORMAL or crit
	var base_size := FONT_SIZE_CRIT if crit else FONT_SIZE
	# DOT 样式向上取整（2026-08-31「烧伤 0」观感修复：跳伤 0.5~0.9 显示为 1——燃烧中
	# 永远读得见；直击/暴击维持 round 口径）
	# R22 元素免疫：数值归零 →「免疫」灰蓝字（直读反馈：这个元素对它没用）
	if style == GameConst.PopupStyle.IMMUNE:
		_label.text = "免疫"
		_label.self_modulate = STYLE_COLORS[GameConst.PopupStyle.IMMUNE]
		_label.add_theme_font_size_override("font_size", base_size)
		return
	if style == GameConst.PopupStyle.DOT and merged_value > 0.0:
		_label.text = str(ceili(merged_value))
	else:
		_label.text = str(int(round(merged_value)))
	if direct:
		# R22 元素配色优先（颜色读元素），量级档保留字号（大小读暴击量级）——
		# R192 单源改读 PopPalette.ELEMENT_COLORS（键 = Element 序 int 七键，.has 守卫保新元素越界安全）
		if element != GameConst.Element.KIN and PopPalette.ELEMENT_COLORS.has(element):
			_label.self_modulate = PopPalette.ELEMENT_COLORS[element]
		else:
			_label.self_modulate = TIER_COLORS[clampi(tier, 0, TIER_COLORS.size() - 1)]
		_label.add_theme_font_size_override("font_size",
			roundi(base_size * float(TIER_SCALES[clampi(tier, 0, TIER_SCALES.size() - 1)])))
	else:
		_label.self_modulate = STYLE_COLORS.get(style, Color.WHITE)
		_label.add_theme_font_size_override("font_size", base_size)
	_label.reset_size()
	_label.position = -_label.size * 0.5


# ── R225 位图字形臂（mobile 门数值臂：共享图集 Sprite 序列） ──────────────
func _numeric_text() -> String:
	# 数值臂文本口径——与 _refresh_label Label 分支逐位同源（DOT ceil「烧伤 0」修复 /
	# IMMUNE 文案 / 其余 round）。merged_value = maxf(p_value,0) 累加恒非负 → 无负号；
	# str 无千分位 → 无万/亿；CRIT 无文字标记（字号/色升格）——字形集审计见
	# PopupGlyphAtlas 文件头。
	if style == GameConst.PopupStyle.IMMUNE:
		return "免疫"
	if style == GameConst.PopupStyle.DOT and merged_value > 0.0:
		return str(ceili(merged_value))
	return str(int(round(merged_value)))


func _bitmap_tint() -> Color:
	# 色真源与 Label 分支同表：直击样式元素色优先（颜色读元素）→ 量级档色兜底（大小读
	# 量级）；非直击走 STYLE_COLORS。元素/档色经 sprite.modulate 染填充（白填充 × tint），
	# 描边恒藏青由图集 shader 承担——元素色只染填充不染描边，读感与 Label 一致。
	var crit := style == GameConst.PopupStyle.CRIT
	var direct := style == GameConst.PopupStyle.NORMAL or crit
	if direct:
		if element != GameConst.Element.KIN and PopPalette.ELEMENT_COLORS.has(element):
			return PopPalette.ELEMENT_COLORS[element]
		return TIER_COLORS[clampi(tier, 0, TIER_COLORS.size() - 1)]
	return STYLE_COLORS.get(style, Color.WHITE)


func _bitmap_px() -> int:
	# 字号真源与 Label 分支同表：直击吃 CRIT 基准 × 量级档乘区；其余基准字号（不吃档）
	var crit := style == GameConst.PopupStyle.CRIT
	var direct := style == GameConst.PopupStyle.NORMAL or crit
	var base_size := FONT_SIZE_CRIT if crit else FONT_SIZE
	if direct:
		return roundi(base_size * float(TIER_SCALES[clampi(tier, 0, TIER_SCALES.size() - 1)]))
	return base_size


func _refresh_bitmap_glyphs() -> void:
	# 位图字形刷新：数值文本 → 逐字形 Sprite（region 指向共享图集格 / modulate=tint /
	# scale=显示px÷烘焙px）——同贴图同材质合批；无 reset_size 字体排版（位图无排版
	# 成本，R212 限批/R221 脏龄保底契约在驱动层原样保留，保底自然恒满足）。
	if _label != null:
		_label.visible = false                 # 池复用防御：上一命 REACTION Label 残留退位
	var txt := _numeric_text()
	var tint := _bitmap_tint()
	var px := _bitmap_px()
	var scale_f := float(px) / float(PopupGlyphAtlas.BAKED_PX)
	var total_w := 0.0
	var metas: Array[Dictionary] = []
	for ch in txt:
		var m: Dictionary = PopupGlyphAtlas.glyph_meta(ch.unicode_at(0))
		if m.is_empty():
			continue                           # 字形缺字守卫（集外字符跳过——审计内不触达）
		metas.append(m)
		total_w += float(m["adv"])
	var pen := 0.0
	var idx := 0
	for m in metas:
		var sp := _ensure_glyph_sprite(idx)
		sp.texture = PopupGlyphAtlas.glyph_texture()
		sp.region_enabled = true
		sp.region_rect = m["rect"]
		sp.material = PopupGlyphAtlas.glyph_material()
		sp.scale = Vector2(scale_f, scale_f)
		# 居中口径与 Label 一致（_label.position = -size*0.5）：pen 累计 advance，
		# 字形中心 = lsb+半宽（cx_off），整体 −总宽/2；行基线由图集 cell 内 bbox 居中承担
		sp.position = Vector2(pen + float(m["cx_off"]) - total_w * 0.5, 0.0)
		sp.modulate = tint
		sp.visible = true
		pen += float(m["adv"])
		idx += 1
	for k in range(idx, _glyph_sprites.size()):
		_glyph_sprites[k].visible = false      # 位数收缩（池复用位数变短）多余 Sprite 隐藏


func _ensure_glyph_sprite(p_idx: int) -> Sprite2D:
	# Sprite 惰性增长（池化实例生命周期内只增不删——位数峰值复用，无运行期反复实例化）
	while p_idx >= _glyph_sprites.size():
		var sp := Sprite2D.new()
		add_child(sp)
		_glyph_sprites.append(sp)
	return _glyph_sprites[p_idx]


func _hide_glyphs() -> void:
	# 位图字形臂退位（REACTION 升格 / 池归还 / deferred 首刷前清残留）
	for sp in _glyph_sprites:
		if is_instance_valid(sp):
			sp.visible = false


func _apply_reaction_look() -> void:
	# R186 反应观感装配：按 element（=ReactionType）查 REACTION_LOOKS——
	# 双色真分通道（font_color=填充 / font_outline_color=描边，替代 self_modulate 单乘色）
	# + 加粗描边 + 专属字型（StickerTheme.font_reaction）。
	# R192 跳字纯函数化：文案 = f(look, merged_value, rxn_stat)——废除旧「表内带文字且
	# merged_value≤0.5 翻字」gate。dmg 型 = 名+合并值直读（碎裂1284）；pct/stat 型 =
	# 名+rxn_stat 短文案段（超导-30%；rxn_stat 空串只显名——分支只认 dmg）。
	# R189 tick 每帧一次 _refresh_label 契约不变（merge/upgrade 只改数值置脏，文案重推导
	# 幂等）；数值禁进 const 文案表。
	if _label == null:
		return
	var look: Dictionary = REACTION_LOOKS.get(element, {})
	if look.is_empty():
		push_error("[DamagePopup] REACTION_LOOKS 缺 reaction id=%d（落首个反应观感兜底）" % element)
		look = REACTION_LOOKS[GameConst.ReactionType.RXN_FIR_ICE]   # 坏 ID 兜底（首个反应观感，禁静默）
	var fill: Color = look["fill"]
	var line: Color = look["outline"]
	_reaction_styled = true
	_label.self_modulate = Color.WHITE            # 乘色退位（双色由主题双通道承担）
	_label.add_theme_color_override("font_color", fill)
	_label.add_theme_color_override("font_outline_color", line)
	_label.add_theme_constant_override("outline_size", OUTLINE_PX_REACTION)
	_label.add_theme_font_override("font", StickerTheme.font_reaction(int(look["variant"])))
	_label.add_theme_font_size_override("font_size", FONT_SIZE_REACTION)
	if String(look["fmt"]) == "dmg":
		_label.text = String(look["name"]) + str(int(round(merged_value)))
	else:
		_label.text = String(look["name"]) + rxn_stat


func _clear_reaction_overrides() -> void:
	# R186 反应覆盖复位（贴纸字出厂态，§5 契约：5 项 theme override + 乘色/标志归零）：
	# 池复用串色防线——非 REACTION 分支与 _reset_state 都经此还原 WHITE 填充 /
	# 藏青描边 / 8px 描边宽 / 30px 常规字号 / 常规字型
	text_mode = false
	rxn_stat = ""                                 # R192：stat 型短文案段一并清空（防池复用串文案）
	_reaction_styled = false
	if _label == null:
		return
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_outline_color", PopPalette.OUTLINE)
	_label.add_theme_constant_override("outline_size", OUTLINE_PX)
	_label.add_theme_font_override("font", StickerTheme.font())
	_label.add_theme_font_size_override("font_size", FONT_SIZE)
	_label.self_modulate = Color.WHITE

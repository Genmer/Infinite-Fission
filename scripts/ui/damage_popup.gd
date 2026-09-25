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
# REACTION_LOOKS（与 ELEMENT_COLORS 同值域 0/1/2，防错套）。
class_name DamagePopup
extends Node2D

var merged_value: float = 0.0                 # 合并累加值
var style: int = 0                            # GameConst.PopupStyle
var tier: int = 0                             # 量级档 0 白/1 蓝/2 紫/3 金（仅 NORMAL/CRIT 生效）
var target_uid: int = 0                       # 合并窗口判据（同目标）
var is_active: bool = false                   # 池外活跃标记
var text_mode: bool = false                   # §5 契约：REACTION 纯文字桶标记（超导标签；manager 分桶/清退判据）

var _label: Label = null
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

# R22 元素配色（用户点名「反馈数字改为对应颜色」）：KIN 白 / FIR 橙 / ICE 冰蓝 / LTG 紫。
# 元素色覆盖量级色；量级信息保留在字号乘区与档音/档震（颜色读元素、大小读量级）
const ELEMENT_COLORS := {
	GameConst.Element.KIN: Color(1.0, 1.0, 1.0),
	GameConst.Element.FIR: Color(1.0, 0.6, 0.25),
	GameConst.Element.ICE: Color(0.62, 0.85, 1.0),
	GameConst.Element.LTG: PopPalette.SHOCK,
}

# R186 反应字体规格表：element（反应通道 = ReactionType 中性 ID）→ 双色 + 字型 + 文字。
# 仅 style==REACTION 分支查此表（与 ELEMENT_COLORS 同值域 0/1/2——先判 style 再索引，
# 防错套）；色值单源 PopPalette.RXN_*，超导无 DamageResult 通道 → text 作纯文字标签
# （复用 IMMUNE 纯文字先例：merged_value≤0.5 时显示）。
const REACTION_LOOKS: Dictionary = {
	GameConst.ReactionType.RXN_FIR_ICE: {
		"fill": PopPalette.RXN_FILL_SHATTER,
		"outline": PopPalette.RXN_LINE_SHATTER,
		"variant": 0,
		"text": "",
	},
	GameConst.ReactionType.RXN_FIR_LTG: {
		"fill": PopPalette.RXN_FILL_OVERLOAD,
		"outline": PopPalette.RXN_LINE_OVERLOAD,
		"variant": 1,
		"text": "",
	},
	GameConst.ReactionType.RXN_ICE_LTG: {
		"fill": PopPalette.RXN_FILL_SUPER,
		"outline": PopPalette.RXN_LINE_SUPER,
		"variant": 2,
		"text": "超导",
	},
}

# 量级分档表现参数（P2 数值真源：档位阈值在 PopupManager；此处只落规格——
# 字号乘区 白 1.0 / 蓝 +15% / 紫 +35% / 金 +60%；配色对齐稀有度四色（调色板单源））
const TIER_SCALES: Array[float] = [1.0, 1.15, 1.35, 1.6]
const TIER_COLORS: Array[Color] = [
	Color(1.0, 1.0, 1.0),                        # 白（现状大小/颜色）
	PopPalette.RARITY_RARE,                      # 蓝（天蓝）
	PopPalette.RARITY_EPIC,                      # 紫（葡萄紫）
	PopPalette.RARITY_LEGEND,                    # 金（柠檬金）
]


func _ready() -> void:
	# 池化实例化期组装：Label 子节点（贴纸字：粗字重 + 藏青描边）
	_label = Label.new()
	_label.name = "Value"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	StickerTheme.label_sticker(_label, FONT_SIZE, Color.WHITE, OUTLINE_PX, PopPalette.OUTLINE, true)
	add_child(_label)
	visible = false


var element: int = GameConst.Element.KIN      # 命中元素（R22：跳字元素配色）

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
	_refresh_label()
	visible = true


func merge(p_value: float) -> void:
	# 合并：数值累加 + 重置漂浮计时（E-17）+ 小幅重弹（果冻反馈）
	merged_value += maxf(p_value, 0.0)
	_life_left = MERGE_LIFE_RESET
	_bounce_left = maxf(_bounce_left, BOUNCE_TIME * 0.6)
	_refresh_label()


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
	_refresh_label()


func tick(p_raw_delta: float) -> void:
	# 果冻弹跳 + 上浮 + 淡出（raw 通道；到期由管理器归还池）
	if not is_active:
		return
	_life_left -= p_raw_delta
	var t := 1.0 - clampf(_life_left / LIFE_TIME, 0.0, 1.0)
	position = _rise_from + Vector2(0.0, -RISE_PX * t)
	modulate.a = clampf(1.0 - t * t, 0.0, 1.0)
	if _bounce_left > 0.0:
		_bounce_left = maxf(_bounce_left - p_raw_delta, 0.0)
		# 弹性生长 + 过冲（0.25 → 峰值 ~1.3 → 1；手绘曲线，无 Tween——池化安全）
		var bt := 1.0 - _bounce_left / BOUNCE_TIME
		var grow := 0.25 + 0.75 * minf(bt * 5.0, 1.0)
		var s := grow * (1.0 + 0.52 * exp(-4.0 * bt) * sin(bt * 14.0))
		scale = Vector2(s, 2.0 - s)
	else:
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
	target_uid = 0
	is_active = false
	_life_left = 0.0
	_bounce_left = 0.0
	modulate.a = 1.0
	scale = Vector2.ONE
	position = Vector2.ZERO
	_rise_from = Vector2.ZERO
	_clear_reaction_overrides()


func _refresh_label() -> void:
	# 数值 + 样式刷新（圆胖数字：CRIT 加大字号；量级档叠乘字号 + 档位配色——
	# 仅直击样式 NORMAL/CRIT 吃量级档，REACTION/DOT/HEAL/XP 沿既有配色观感）
	if _label == null:
		return
	if style == GameConst.PopupStyle.REACTION:
		# R186 反应大字专属分支（规格表分流）：双色主题通道 + 专属字型 + 1.8× 字号——
		# 不走 self_modulate 乘色、不吃量级档（_tier_for 对非直击恒返 0 契约不变）
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
		# R22 元素配色优先（颜色读元素），量级档保留字号（大小读暴击量级）
		if ELEMENT_COLORS.has(element) and element != GameConst.Element.KIN:
			_label.self_modulate = ELEMENT_COLORS[element]
		else:
			_label.self_modulate = TIER_COLORS[clampi(tier, 0, TIER_COLORS.size() - 1)]
		_label.add_theme_font_size_override("font_size",
			roundi(base_size * float(TIER_SCALES[clampi(tier, 0, TIER_SCALES.size() - 1)])))
	else:
		_label.self_modulate = STYLE_COLORS.get(style, Color.WHITE)
		_label.add_theme_font_size_override("font_size", base_size)
	_label.reset_size()
	_label.position = -_label.size * 0.5


func _apply_reaction_look() -> void:
	# R186 反应观感装配：按 element（=ReactionType）查 REACTION_LOOKS——
	# 双色真分通道（font_color=填充 / font_outline_color=描边，替代 self_modulate 单乘色）
	# + 加粗描边 + 专属字型（StickerTheme.font_reaction）。R1/§5：表内带文字且
	# merged_value≤0.5 时显示纯文字（超导标签；小值并入不翻字），否则数值直读。
	if _label == null:
		return
	var look: Dictionary = REACTION_LOOKS.get(element, {})
	if look.is_empty():
		look = REACTION_LOOKS[GameConst.ReactionType.RXN_FIR_ICE]   # 坏 ID 兜底（首个反应观感）
	var fill: Color = look["fill"]
	var line: Color = look["outline"]
	_reaction_styled = true
	_label.self_modulate = Color.WHITE            # 乘色退位（双色由主题双通道承担）
	_label.add_theme_color_override("font_color", fill)
	_label.add_theme_color_override("font_outline_color", line)
	_label.add_theme_constant_override("outline_size", OUTLINE_PX_REACTION)
	_label.add_theme_font_override("font", StickerTheme.font_reaction(int(look["variant"])))
	_label.add_theme_font_size_override("font_size", FONT_SIZE_REACTION)
	var text: String = look["text"]
	if text != "" and merged_value <= 0.5:
		_label.text = text
	else:
		_label.text = str(int(round(merged_value)))


func _clear_reaction_overrides() -> void:
	# R186 反应覆盖复位（贴纸字出厂态，§5 契约：5 项 theme override + 乘色/标志归零）：
	# 池复用串色防线——非 REACTION 分支与 _reset_state 都经此还原 WHITE 填充 /
	# 藏青描边 / 8px 描边宽 / 30px 常规字号 / 常规字型
	text_mode = false
	_reaction_styled = false
	if _label == null:
		return
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_outline_color", PopPalette.OUTLINE)
	_label.add_theme_constant_override("outline_size", OUTLINE_PX)
	_label.add_theme_font_override("font", StickerTheme.font())
	_label.add_theme_font_size_override("font_size", FONT_SIZE)
	_label.self_modulate = Color.WHITE

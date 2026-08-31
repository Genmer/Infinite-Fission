# scripts/ui/damage_popup.gd
# M-16 DamagePopup（架构 §2.15）：伤害跳字实体（池化——popup_pool 真件，包 4 收紧目标）。
# 动画：果冻弹跳出现（scale 弹性曲线）+ 上浮 + 淡出（raw 通道驱动，由 PopupManager.tick
# 统一推进——顿帧期间跳字照常，Q-14）。合并：merge() 数值累加 + 重置漂浮计时（E-17）。
# 样式分级：GameConst.PopupStyle（NORMAL/CRIT/REACTION/DOT/HEAL/XP）——圆胖数字 + 藏青描边
# （亮底贴纸字：白色描边托底，任何背景可读）。
# 量级分级（P2，META_ROADMAP §5.10「伤害数字分级」）：单次伤害相对玩家单发基准伤害分
# 白/蓝/紫/金 4 档——大小/颜色/音效三联动（档位判定在 PopupManager 入口，本实体只承担
# 表现：字号乘区 + 档位配色；仅 NORMAL/CRIT 直击样式参与，REACTION/DOT/HEAL/XP 沿旧观感）。
class_name DamagePopup
extends Node2D

var merged_value: float = 0.0                 # 合并累加值
var style: int = 0                            # GameConst.PopupStyle
var tier: int = 0                             # 量级档 0 白/1 蓝/2 紫/3 金（仅 NORMAL/CRIT 生效）
var target_uid: int = 0                       # 合并窗口判据（同目标）
var is_active: bool = false                   # 池外活跃标记

var _label: Label = null
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

# 样式配色（方向 C 调色板单源；NORMAL 白底描边 = 亮底可读贴纸字）
const STYLE_COLORS := {
	GameConst.PopupStyle.NORMAL: Color(1.0, 1.0, 1.0),
	GameConst.PopupStyle.CRIT: PopPalette.XP,
	GameConst.PopupStyle.REACTION: PopPalette.SHOCK,
	GameConst.PopupStyle.DOT: Color(1.0, 0.72, 0.45),
	GameConst.PopupStyle.HEAL: PopPalette.SUCCESS,
	GameConst.PopupStyle.XP: PopPalette.INK_SOFT,
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


func show_popup(p_pos: Vector2, p_value: float, p_style: int, p_target_uid: int = 0,
		p_tier: int = 0) -> void:
	# 池取出后初始化 + 动画启动（p_tier：量级档，PopupManager 入口判定后传入）
	position = p_pos
	_rise_from = p_pos
	merged_value = maxf(p_value, 0.0)
	style = p_style
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
	# 归还清零契约（E-04/E-05）
	merged_value = 0.0
	style = 0
	tier = 0
	target_uid = 0
	is_active = false
	_life_left = 0.0
	_bounce_left = 0.0
	modulate.a = 1.0
	scale = Vector2.ONE
	position = Vector2.ZERO
	_rise_from = Vector2.ZERO


func _refresh_label() -> void:
	# 数值 + 样式刷新（圆胖数字：CRIT 加大字号；量级档叠乘字号 + 档位配色——
	# 仅直击样式 NORMAL/CRIT 吃量级档，REACTION/DOT/HEAL/XP 沿既有配色观感）
	if _label == null:
		return
	var crit := style == GameConst.PopupStyle.CRIT
	var direct := style == GameConst.PopupStyle.NORMAL or crit
	var base_size := FONT_SIZE_CRIT if crit else FONT_SIZE
	# DOT 样式向上取整（2026-08-31「烧伤 0」观感修复：跳伤 0.5~0.9 显示为 1——燃烧中
	# 永远读得见；直击/暴击维持 round 口径）
	if style == GameConst.PopupStyle.DOT and merged_value > 0.0:
		_label.text = str(ceili(merged_value))
	else:
		_label.text = str(int(round(merged_value)))
	if direct:
		_label.self_modulate = TIER_COLORS[clampi(tier, 0, TIER_COLORS.size() - 1)]
		_label.add_theme_font_size_override("font_size",
			roundi(base_size * float(TIER_SCALES[clampi(tier, 0, TIER_SCALES.size() - 1)])))
	else:
		_label.self_modulate = STYLE_COLORS.get(style, Color.WHITE)
		_label.add_theme_font_size_override("font_size", base_size)
	_label.reset_size()
	_label.position = -_label.size * 0.5

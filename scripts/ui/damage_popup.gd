# scripts/ui/damage_popup.gd
# M-16 DamagePopup（架构 §2.15）：伤害跳字实体（池化——popup_pool 真件，包 4 收紧目标）。
# 动画：上浮 + 淡出（raw 通道驱动，由 PopupManager.tick 统一推进——顿帧期间跳字照常，Q-14）。
# 合并：merge() 数值累加 + 重置漂浮计时（E-17 同目标短窗合并）。
# 样式分级：GameConst.PopupStyle（NORMAL/CRIT/REACTION/DOT/HEAL/XP）——颜色/字号占位美术。
class_name DamagePopup
extends Node2D

var merged_value: float = 0.0                 # 合并累加值
var style: int = 0                            # GameConst.PopupStyle
var target_uid: int = 0                       # 合并窗口判据（同目标）
var element_hint: int = -1                    # 元素提示（REACTION 按元素分色；PopupManager 注入）
var is_active: bool = false                   # 池外活跃标记

var _label: Label = null
var _life_left: float = 0.0                   # 剩余展示时长（s）
var _rise_from: Vector2 = Vector2.ZERO        # 上浮起点（相对坐标基准）

const LIFE_TIME := 0.6                        # 单段展示时长（s）
const RISE_PX := 42.0                         # 上浮距离 px
const MERGE_LIFE_RESET := 0.35                # 合并后重置的展示时长（短于新起，观感收敛）
const OUTLINE_SIZE := 6                       # 描边（深空底上的可读性）

# 跳字分级配色（视觉单源 Palette；深空霓虹分级）：
#   NORMAL 正文白 / CRIT 品红加大 / REACTION 按元素（点燃橙/冰冻青/感电紫，element_hint）
#   / DOT 点燃橙 / HEAL 成功绿 / XP 弱化灰青
const STYLE_COLORS := {
	GameConst.PopupStyle.NORMAL: Palette.TEXT_MAIN,
	GameConst.PopupStyle.CRIT: Palette.MAGENTA,
	GameConst.PopupStyle.REACTION: Palette.LTG,
	GameConst.PopupStyle.DOT: Palette.FIR,
	GameConst.PopupStyle.HEAL: Palette.GREEN,
	GameConst.PopupStyle.XP: Palette.TEXT_DIM,
}


func _ready() -> void:
	# 池化实例化期组装：Label 子节点（等宽加重 + 深描边；基数比正文大一档——可读性硬性要求）
	_label = Label.new()
	_label.name = "Value"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", Palette.FONT_POPUP)
	_label.add_theme_color_override("font_outline_color", Palette.OUTLINE_COLOR)
	_label.add_theme_constant_override("outline_size", OUTLINE_SIZE)
	_label.add_theme_font_override("font", UITheme.font_mono())
	add_child(_label)
	visible = false


func show_popup(p_pos: Vector2, p_value: float, p_style: int, p_target_uid: int = 0) -> void:
	# 池取出后初始化 + 动画启动
	position = p_pos
	_rise_from = p_pos
	merged_value = maxf(p_value, 0.0)
	style = p_style
	target_uid = p_target_uid
	_life_left = LIFE_TIME
	is_active = true
	_refresh_label()
	visible = true


func merge(p_value: float) -> void:
	# 合并：数值累加 + 重置漂浮计时（E-17）
	merged_value += maxf(p_value, 0.0)
	_life_left = MERGE_LIFE_RESET
	_refresh_label()


func tick(p_raw_delta: float) -> void:
	# 上浮 + 淡出（raw 通道；到期由管理器归还池）
	if not is_active:
		return
	_life_left -= p_raw_delta
	var t := 1.0 - clampf(_life_left / LIFE_TIME, 0.0, 1.0)
	position = _rise_from + Vector2(0.0, -RISE_PX * t)
	modulate.a = clampf(1.0 - t * t, 0.0, 1.0)


func life_left() -> float:
	# 管理器回收判据
	return _life_left


func _reset_state() -> void:
	# 归还清零契约（E-04/E-05）
	merged_value = 0.0
	style = 0
	target_uid = 0
	is_active = false
	_life_left = 0.0
	modulate.a = 1.0
	position = Vector2.ZERO
	_rise_from = Vector2.ZERO


func _refresh_label() -> void:
	# 数值 + 样式刷新（CRIT 品红加大字号；REACTION 按 element_hint 元素分色）
	if _label == null:
		return
	_label.text = str(int(round(merged_value)))
	var col: Color = STYLE_COLORS.get(style, Palette.TEXT_MAIN)
	if style == GameConst.PopupStyle.REACTION and element_hint > 0:
		col = Palette.element_color(element_hint)
	_label.self_modulate = col
	_label.scale = Vector2.ONE * (1.55 if style == GameConst.PopupStyle.CRIT else 1.0)

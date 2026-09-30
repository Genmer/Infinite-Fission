# scripts/ui/playfield_outline.gd
# R195 适配底座：逻辑域边界线——res_logic（720×1280，F-01 钉死 fatal）四边 1px 低透明描边。
# 动因：aspect=expand 后平板（960 宽画布）横向延展区可见「世界反弹沿」（域右缘 x=720
# 落屏内 x=840，相机 res_logic×0.5 居中几何实证），玩家需要看见「场地到哪」；16:9
# 默认窗（含 540×960）下边线贴屏缘不可见=零副作用。
# 纪律：Node2D _draw 纯读 GameConfig.balance.res_logic（零缓存、零每帧分配）；仅
# viewport size_changed 事件时 queue_redraw（域几何恒定，重绘不重算）；取色走
# PopPalette 单源（禁止散落字面量色值）。逻辑域只读不写（combat/entities/wave 零改动域）。
class_name PlayfieldOutline
extends Node2D

const OUTLINE_ALPHA := 0.22                   # 低透明（氛围提示，不抢弹幕不抢 UI）

var base_z: int = -10                         # z 压云（-20）不压弹幕（实体/弹 z≥0）


func _ready() -> void:
	z_index = base_z
	var vp := get_viewport()
	if vp != null:
		vp.size_changed.connect(_on_viewport_size_changed)


func _on_viewport_size_changed() -> void:
	# 仅事件驱动重绘（线宽 1 canvas px 随 stretch 缩放由引擎管线处理，本侧不重建几何）
	queue_redraw()


func _draw() -> void:
	# 四边描 res_logic 逻辑域（unfilled 1px 矩形边框）
	var domain := Rect2(Vector2.ZERO, Vector2(GameConfig.balance.res_logic))
	draw_rect(domain, Color(PopPalette.INK_SOFT, OUTLINE_ALPHA), false, 1.0)

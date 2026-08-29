# scripts/ui/boss_death_fx.gd
# 方向 A 签名瞬间：Boss 死亡 = 冲击波扩散环 + 全屏白闪。纯表现层：
# 不申请顿帧/不写 time_scale/hit_stop（数值归 GameFeelDirector 契约管）；
# _process 自驱动画（raw 通道语义——结算/暂停期间表现自然收尾）。
# 触发方：BossBar._on_enemy_killed（引用相等判定 Boss 本体，见彼处注释）。
class_name BossDeathFX
extends CanvasLayer

var _ring: ShockRing = null                   # 冲击波扩散环
var _flash: ColorRect = null                  # 全屏白闪
var _flash_left: float = 0.0

const FLASH_TIME := 0.45
const FLASH_PEAK := 0.85
const RING_TIME := 0.7
const RING_RADIUS_MAX := 280.0
const LAYER_ORDER := 45


func _ready() -> void:
	layer = LAYER_ORDER
	_ring = ShockRing.new()
	_ring.name = "ShockRing"
	_ring.visible = false
	add_child(_ring)
	_flash = ColorRect.new()
	_flash.name = "Flash"
	_flash.color = Color(1.0, 1.0, 1.0, 0.0)
	_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_flash)


func burst(p_pos: Vector2) -> void:
	# 触发（Boss 世界坐标；相机 1:1 锚定中心 → 屏幕坐标同值）
	_ring.position = p_pos
	_ring.t = 0.0
	_ring.visible = true
	_flash_left = FLASH_TIME


func _process(p_delta: float) -> void:
	# 白闪衰减
	if _flash_left > 0.0:
		_flash_left = maxf(_flash_left - p_delta, 0.0)
		var t := 1.0 - _flash_left / FLASH_TIME
		_flash.color.a = FLASH_PEAK * (1.0 - t) * (1.0 - t * 0.5)
	else:
		_flash.color.a = 0.0
	# 冲击波推进
	if _ring != null and _ring.visible:
		_ring.t += p_delta / RING_TIME
		if _ring.t >= 1.0:
			_ring.visible = false
		else:
			_ring.queue_redraw()


# 冲击波扩散环（双环：亮内环 + 柔外环，扩散渐隐）
class ShockRing:
	extends Node2D

	var t: float = 0.0                          # 0~1 归一化进度

	func _draw() -> void:
		var r := RING_RADIUS_MAX * (1.0 - pow(1.0 - t, 3.0))   # ease-out 扩散
		var fade := 1.0 - t
		draw_arc(Vector2.ZERO, r, 0.0, TAU, 64, Color(Palette.TEXT_MAIN, 0.9 * fade), 6.0, true)
		draw_arc(Vector2.ZERO, r * 1.12, 0.0, TAU, 64, Color(Palette.CYAN, 0.5 * fade), 10.0, true)
		draw_arc(Vector2.ZERO, r * 0.7, 0.0, TAU, 48, Color(Palette.RED, 0.45 * fade), 3.0, true)

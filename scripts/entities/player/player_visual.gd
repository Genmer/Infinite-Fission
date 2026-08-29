# scripts/entities/player/player_visual.gd
# 方向 A 玩家舰体视觉「哨兵-9」：青色箭形舰（霓虹描边 + 半透明填充 + 底光晕）
# + 引擎喷焰（逐帧抖动）+ 移动倾斜 + 受击闪白 + 无敌呼吸。纯表现层：
# 由 Player.tick 驱动（apply_motion/flash），不持有任何逻辑数值。
class_name NeonShip
extends Node2D

var _radius: float = 16.0                     # 舰体基准半径（= hitbox_radius）
var _flash: float = 0.0                       # 受击闪白 0~1
var _invuln: bool = false                     # 无敌呼吸开关
var _breath_t: float = 0.0                    # 呼吸相位
var _tilt: float = 0.0                        # 当前倾斜（rad，lerp 平滑）
var _flame: float = 1.0                       # 喷焰长度系数（抖动）
var _halo: Sprite2D = null                    # 底光晕（共享柔光贴图 + 加色）

const FLASH_TIME := 0.12
const TILT_MAX := 0.28                        # 最大倾斜 rad（≈16°）
const TILT_PER_PX := 0.035                    # 每像素横移的倾斜目标


func _ready() -> void:
	# 底光晕（加色柔光，青色系主色单源）
	_halo = Sprite2D.new()
	_halo.name = "Halo"
	_halo.texture = TextureFactory.glow_dot()
	_halo.material = TextureFactory.mat_add()
	_halo.self_modulate = Color(Palette.CYAN, 0.5)
	_halo.show_behind_parent = true
	add_child(_halo)


func setup(p_radius: float) -> void:
	_radius = maxf(p_radius, 1.0)
	if _halo != null:
		_halo.scale = Vector2.ONE * (_radius * 4.4 / float(TextureFactory.GLOW_DOT_SIZE))


func apply_motion(p_move_px: Vector2, p_delta: float, p_invuln: bool) -> void:
	# Player.tick 每帧投递：倾斜目标 + 呼吸相位 + 喷焰抖动（触发重绘）
	_tilt = lerp_float(_tilt, clampf(p_move_px.x * TILT_PER_PX, -TILT_MAX, TILT_MAX),
		minf(p_delta * 14.0, 1.0))
	rotation = _tilt
	if p_invuln != _invuln:
		_invuln = p_invuln
	if _invuln:
		_breath_t += p_delta * 9.0
		modulate.a = 0.62 + 0.38 * absf(sin(_breath_t))
	else:
		modulate.a = 1.0
	_flame = randf_range(0.75, 1.3)
	queue_redraw()


func flash() -> void:
	# 受击闪白入口（Player.take_contact_damage 调用；纯视觉）
	_flash = 1.0
	queue_redraw()


func tick_visual(p_delta: float) -> void:
	# 闪白衰减（无受击时不重绘）
	if _flash > 0.0:
		_flash = maxf(_flash - p_delta / FLASH_TIME, 0.0)
		queue_redraw()


func _draw() -> void:
	# 箭形舰：弹头朝上（前）。_fill 半透明 + _line 霓虹描边 + 中脊细节。
	var r := _radius
	var hull := PackedVector2Array([
		Vector2(0.0, -r * 1.55),
		Vector2(r * 0.95, r * 1.05),
		Vector2(0.0, r * 0.55),
		Vector2(-r * 0.95, r * 1.05),
	])
	# 引擎喷焰（舰尾）：抖动三角（青→透明渐弱两段）
	var fl := r * (1.1 + 0.7 * _flame)
	var flame := PackedVector2Array([
		Vector2(-r * 0.34, r * 0.9),
		Vector2(0.0, r * 0.9 + fl),
		Vector2(r * 0.34, r * 0.9),
	])
	draw_colored_polygon(flame, Color(Palette.CYAN, 0.30))
	draw_colored_polygon(PackedVector2Array([
		Vector2(-r * 0.16, r * 0.9),
		Vector2(0.0, r * 0.9 + fl * 0.55),
		Vector2(r * 0.16, r * 0.9),
	]), Color(Palette.TEXT_MAIN, 0.5))
	# 舰体
	draw_colored_polygon(hull, Color(Palette.CYAN, 0.26))
	draw_polyline(hull + PackedVector2Array([hull[0]]), Palette.CYAN, 2.0, true)
	# 中脊 + 翼线（矢量细节）
	draw_line(Vector2(0.0, -r * 1.2), Vector2(0.0, r * 0.4),
		Color(Palette.TEXT_MAIN, 0.65), 1.2, true)
	draw_line(Vector2(-r * 0.55, r * 0.55), Vector2(-r * 0.2, -r * 0.35),
		Color(Palette.CYAN.lightened(0.2), 0.5), 1.0, true)
	draw_line(Vector2(r * 0.55, r * 0.55), Vector2(r * 0.2, -r * 0.35),
		Color(Palette.CYAN.lightened(0.2), 0.5), 1.0, true)
	# 受击闪白覆盖
	if _flash > 0.0:
		draw_colored_polygon(hull, Color(1.0, 1.0, 1.0, 0.85 * _flash))


func lerp_float(p_from: float, p_to: float, p_weight: float) -> float:
	# 标量 lerp（避免依赖 lerp 全局函数的 Variant 返回标注）
	return p_from + (p_to - p_from) * clampf(p_weight, 0.0, 1.0)

# scripts/entities/enemy/enemy_visual.gd
# 方向 A 敌方分型视觉（霓虹描边 + 半透明填充统一语言；品红系敌方阵营色）：
#   E1_grunt    → TRIANGLE 品红小三角（尖朝下=扑向玩家）
#   E2_runner   → DART     细长镖形 + 渐隐拖尾
#   E3_bastion  → HEX      六边形装甲（双层甲板）
#   E4_volatile → VOLATILE 红橙脉动爆虫（警示圈仍由 Enemy.FuseRing 承担）
#   E5_elite    → TRIANGLE 基底形 + 金圈（精英通用模板）
#   Boss(E6_*)  → BOSS     多层旋转聚合体（裂纹发光核心 + 双旋转环）
# 单 canvas_item 自绘（fill+outline 一次 draw pass）；脉动/旋转类才逐帧重绘。
class_name EnemyVisual
extends Node2D

enum Kind { TRIANGLE, DART, HEX, VOLATILE, BOSS }

var kind: int = Kind.TRIANGLE
var radius: float = 14.0
var elite_ring: bool = false                  # 精英金圈（E5/精英 tag）
var _flash: float = 0.0
var _pulse_t: float = 0.0                     # 脉动相位（VOLATILE）
var _ring_a: RingNode = null                  # Boss 旋转环（内层顺时针）
var _ring_b: RingNode = null                  # Boss 旋转环（外层逆时针）

const FLASH_TIME := 0.12
# 分型主色（品红敌方阵营；Boss 红 / 爆虫红橙——色彩单源 Palette）
const KIND_COLORS := {
	Kind.TRIANGLE: Palette.MAGENTA,
	Kind.DART: Color("ff7ce4"),
	Kind.HEX: Color("e43fc4"),
	Kind.VOLATILE: Color("ff7a4f"),
	Kind.BOSS: Palette.RED,
}


static func kind_for(p_id: StringName, p_is_boss: bool) -> int:
	# 按 .tres id 分型（enemy.gd 现有判定同源：id 约定 + boss tag）
	if p_is_boss:
		return Kind.BOSS
	match p_id:
		&"E2_runner":
			return Kind.DART
		&"E3_bastion":
			return Kind.HEX
		&"E4_volatile":
			return Kind.VOLATILE
		_:
			return Kind.TRIANGLE


func setup(p_kind: int, p_radius: float, p_elite: bool) -> void:
	kind = p_kind
	radius = maxf(p_radius, 1.0)
	elite_ring = p_elite and kind != Kind.BOSS
	_ensure_rings()
	queue_redraw()


func set_flash(p_amount: float) -> void:
	# 受击闪白（Enemy._apply_flash 委托）
	var clamped := clampf(p_amount, 0.0, 1.0)
	if _flash == clamped:
		return
	_flash = clamped
	queue_redraw()


func tick_anim(p_game_delta: float) -> void:
	# 脉动/旋转推进（Enemy.tick 每帧投递；静态分型零开销——不重绘）
	match kind:
		Kind.VOLATILE:
			_pulse_t += p_game_delta * 9.0
			queue_redraw()
		Kind.BOSS:
			_pulse_t += p_game_delta
			if _ring_a != null:
				_ring_a.rotation += p_game_delta * 0.9
				_ring_b.rotation -= p_game_delta * 0.6
			queue_redraw()
		_:
			pass
	if _flash > 0.0:
		_flash = maxf(_flash - p_game_delta / FLASH_TIME, 0.0)
		queue_redraw()


func _draw() -> void:
	var col: Color = KIND_COLORS.get(kind, Palette.MAGENTA)
	match kind:
		Kind.TRIANGLE:
			_draw_triangle(col)
		Kind.DART:
			_draw_dart(col)
		Kind.HEX:
			_draw_hex(col)
		Kind.VOLATILE:
			_draw_volatile(col)
		Kind.BOSS:
			_draw_boss(col)
	# 精英金圈（基底形外环）
	if elite_ring:
		draw_arc(Vector2.ZERO, radius * 1.55, 0.0, TAU, 40,
			Color(Palette.AMBER, 0.75 + 0.2 * sin(_pulse_t * 4.0)), 2.0, true)
	# 受击闪白覆盖（分型轮廓白闪）
	if _flash > 0.0:
		_draw_flash_overlay(col)


# ── 分型绘制 ─────────────────────────────────────────────────────
func _draw_triangle(p_col: Color) -> void:
	# 小三角（尖朝下——敌自上而下扑向玩家）
	var r := radius
	var pts := _poly([
		Vector2(0.0, r * 1.35), Vector2(r * 1.15, -r * 0.9),
		Vector2(-r * 1.15, -r * 0.9),
	])
	draw_colored_polygon(pts, _fill(p_col))
	draw_polyline(pts + PackedVector2Array([pts[0]]), p_col, 2.0, true)
	draw_circle(Vector2(0.0, -r * 0.45), r * 0.22, _core(p_col))


func _draw_dart(p_col: Color) -> void:
	# 细长镖形（纵向 3:1）+ 渐隐拖尾（尾后三段递弱）
	var r := radius
	var pts := _poly([
		Vector2(0.0, r * 2.0), Vector2(r * 0.55, 0.0),
		Vector2(0.0, -r * 1.9), Vector2(-r * 0.55, 0.0),
	])
	# 拖尾（镖尾 = 上方；运动方向朝下）
	var trail_alpha := 0.4
	for i in range(3):
		var y0 := -r * (1.9 + 1.5 * float(i))
		draw_line(Vector2(0.0, y0), Vector2(0.0, y0 - r * 1.3),
			Color(p_col, trail_alpha * (1.0 - 0.3 * float(i))), 3.0 - float(i), true)
	draw_colored_polygon(pts, _fill(p_col))
	draw_polyline(pts + PackedVector2Array([pts[0]]), p_col, 1.8, true)
	draw_line(Vector2(0.0, r * 1.6), Vector2(0.0, -r * 1.5),
		Color(Palette.TEXT_MAIN, 0.4), 1.0, true)


func _draw_hex(p_col: Color) -> void:
	# 六边形装甲：外甲 + 内甲板 + 铆点
	var r := radius
	var outer := _ngon(6, r * 1.2, PI / 6.0)
	var inner := _ngon(6, r * 0.72, PI / 6.0)
	draw_colored_polygon(outer, _fill(p_col))
	draw_polyline(outer + PackedVector2Array([outer[0]]), p_col, 2.4, true)
	draw_polyline(inner + PackedVector2Array([inner[0]]),
		Color(p_col.lightened(0.25), 0.8), 1.2, true)
	for i in range(3):
		var ang := PI / 6.0 + TAU * float(i) / 3.0
		draw_circle(Vector2.from_angle(ang) * r * 0.95, r * 0.1, _core(p_col))


func _draw_volatile(p_col: Color) -> void:
	# 爆虫：脉动棘球（8 棘，半径 sin 调制）+ 亮核（警示圈由 FuseRing 承担）
	var r := radius * (1.0 + 0.14 * sin(_pulse_t))
	var pts := PackedVector2Array()
	var spikes := 8
	for i in range(spikes * 2):
		var ang := TAU * float(i) / float(spikes * 2)
		var rr := r * (1.25 if i % 2 == 0 else 0.78)
		pts.append(Vector2.from_angle(ang) * rr)
	draw_colored_polygon(pts, _fill(p_col))
	draw_polyline(pts + PackedVector2Array([pts[0]]), p_col, 1.8, true)
	draw_circle(Vector2.ZERO, r * 0.42,
		Color(Palette.TEXT_MAIN, 0.5 + 0.4 * sin(_pulse_t * 2.0)))


func _draw_boss(p_col: Color) -> void:
	# 聚合体核心：亮核 + 裂纹发光（6 道固定相角裂纹）+ 半透明体
	var r := radius * 0.62
	var pulse := 0.5 + 0.5 * sin(_pulse_t * 3.0)
	draw_circle(Vector2.ZERO, r * (1.05 + 0.06 * pulse), _fill(p_col))
	draw_arc(Vector2.ZERO, r * 1.12, 0.0, TAU, 48, p_col, 2.6, true)
	draw_circle(Vector2.ZERO, r * 0.45,
		Color(Palette.TEXT_MAIN, 0.55 + 0.35 * pulse))
	# 裂纹（固定相角放射线——核心不稳定观感）
	for i in range(6):
		var ang := TAU * float(i) / 6.0 + 0.35
		var dir := Vector2.from_angle(ang)
		draw_line(dir * r * 0.4, dir * r * (1.0 + 0.35 * pulse),
			Color(p_col.lightened(0.3), 0.75), 1.6, true)


# ── 闪光覆盖（分型近似轮廓白闪） ─────────────────────────────────
func _draw_flash_overlay(p_col: Color) -> void:
	var a := 0.85 * _flash
	match kind:
		Kind.DART:
			draw_circle(Vector2.ZERO, radius * 1.6, Color(1.0, 1.0, 1.0, a * 0.6))
		Kind.BOSS:
			draw_circle(Vector2.ZERO, radius * 0.68, Color(1.0, 1.0, 1.0, a))
		_:
			draw_circle(Vector2.ZERO, radius * 1.3, Color(1.0, 1.0, 1.0, a * 0.7))


# ── Boss 旋转环 ──────────────────────────────────────────────────
func _ensure_rings() -> void:
	if kind != Kind.BOSS:
		return
	if _ring_a == null:
		_ring_a = RingNode.new()
		_ring_a.setup(radius * 1.45, 3, 2.0, Color(Palette.RED, 0.7))
		add_child(_ring_a)
	if _ring_b == null:
		_ring_b = RingNode.new()
		_ring_b.setup(radius * 1.8, 5, 1.4, Color(Palette.MAGENTA, 0.55))
		add_child(_ring_b)


# ── 几何辅助 ─────────────────────────────────────────────────────
func _poly(p_points: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in p_points:
		out.append(p)
	return out


func _ngon(p_sides: int, p_r: float, p_phase: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(p_sides):
		pts.append(Vector2.from_angle(p_phase + TAU * float(i) / float(p_sides)) * p_r)
	return pts


func _fill(p_col: Color) -> Color:
	return Color(p_col, 0.20)


func _core(p_col: Color) -> Color:
	return Color(p_col.lightened(0.35), 0.9)


# 旋转虚线环（Boss 专属子节点；rotation 由宿主 tick 推进——transform 旋转零重绘）
class RingNode:
	extends Node2D

	var _r: float = 10.0
	var _segments: int = 3
	var _width: float = 2.0
	var _col: Color = Color.WHITE

	func setup(p_r: float, p_segments: int, p_width: float, p_col: Color) -> void:
		_r = p_r
		_segments = maxi(p_segments, 1)
		_width = p_width
		_col = p_col
		queue_redraw()

	func _draw() -> void:
		# 虚线弧段环（segments 段等分，留 40% 缺口 = 旋转可读性）
		var arc_len := TAU * 0.6 / float(_segments)
		for i in range(_segments):
			var start := TAU * float(i) / float(_segments)
			draw_arc(Vector2.ZERO, _r, start, start + arc_len, 12, _col, _width, true)

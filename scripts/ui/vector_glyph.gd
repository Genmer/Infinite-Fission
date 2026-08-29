# scripts/ui/vector_glyph.gd
# 矢量磷光线框绘制件（方向 B 实体语言：亮描边为主 + 暗半透明填充 + 磷光辉光）。
# 辉光 = 三段描边（宽淡/中淡/细亮）模拟磷光晕开，无 shader、无贴图——逐实体成本可控
#（性能红线：禁止逐实体跑屏后 shader；本类只增画布 draw 调用）。
# 形状生成器输出局部坐标点集（半径约定 = 传入 radius，实体侧按 hitbox_r 构形）。
class_name WireGlyph
extends Node2D

var points: PackedVector2Array = PackedVector2Array()  # 主轮廓（闭合）
var extra_lines: Array[PackedVector2Array] = []        # 装饰线（辐射刻度/内层装甲，开放线）
var extra_color := Color(1, 1, 1, 0.4)                 # 装饰线色
var stroke := Palette.HOT_RED                          # 主描边
var fill := Color(0, 0, 0, 0)                          # 主填充（透明 = 不画）
var flash: float = 0.0                                 # 受击闪白 0~1
var stroke_width: float = 1.6                          # 核心描边宽（局部 px）
var glow: bool = true                                  # 磷光辉光开关（静态形可关省绘制）


func _draw() -> void:
	# 闪烁 = 描边/填充向白热插值（代替旧 Sprite2D flash shader）
	var s := stroke.lerp(Palette.WHITE_HOT, flash)
	var f := Color(fill.r, fill.g, fill.b, fill.a).lerp(Color(1, 1, 1, 0.45), flash * 0.7)
	if points.size() >= 3:
		if fill.a > 0.004:
			draw_colored_polygon(points, f)
		if glow:
			draw_polyline(_closed_loop(points), Color(s.r, s.g, s.b, 0.14 * s.a), stroke_width * 3.4, true)
			draw_polyline(_closed_loop(points), Color(s.r, s.g, s.b, 0.40 * s.a), stroke_width * 1.8, true)
		draw_polyline(_closed_loop(points), s, stroke_width, true)
	for line in extra_lines:
		if glow:
			draw_polyline(line, Color(extra_color.r, extra_color.g, extra_color.b, 0.30 * extra_color.a), stroke_width * 1.6, false)
		draw_polyline(line, extra_color, stroke_width * 0.8, false)


func redraw() -> void:
	queue_redraw()


# ── 形状生成器（静态；局部坐标，半径 = p_radius） ─────────────────
static func regular(p_sides: int, p_radius: float, p_phase: float = 0.0) -> PackedVector2Array:
	# 正多边形（E1 三角 / E3 双层六边 / Boss 八边聚合体）
	var n := maxi(p_sides, 3)
	var out := PackedVector2Array()
	out.resize(n)
	for i in range(n):
		var a := p_phase + TAU * float(i) / float(n)
		out[i] = Vector2(cos(a), sin(a)) * p_radius
	return out


static func arrow(p_radius: float) -> PackedVector2Array:
	# 玩家矢量箭形（Asteroids 舰体；尖端朝 -Y，rotation=0 时面朝屏幕上方）
	return PackedVector2Array([
		Vector2(0.0, -p_radius),
		Vector2(0.72 * p_radius, 0.62 * p_radius),
		Vector2(0.0, 0.28 * p_radius),
		Vector2(-0.72 * p_radius, 0.62 * p_radius),
	])


static func dart(p_radius: float) -> PackedVector2Array:
	# E2 镖形（四点风筝；尖端朝 -Y）
	return PackedVector2Array([
		Vector2(0.0, -p_radius),
		Vector2(0.52 * p_radius, 0.12 * p_radius),
		Vector2(0.0, 0.78 * p_radius),
		Vector2(-0.52 * p_radius, 0.12 * p_radius),
	])


static func radial_ticks(p_radius_in: float, p_radius_out: float, p_count: int,
		p_phase: float = 0.0) -> Array[PackedVector2Array]:
	# 辐射刻度线组（E4 脉动圆刻度 / E5 外圈刻度环；开放线段集合）
	var out: Array[PackedVector2Array] = []
	var n := maxi(p_count, 3)
	for i in range(n):
		var a := p_phase + TAU * float(i) / float(n)
		var seg := PackedVector2Array()
		seg.append(Vector2(cos(a), sin(a)) * p_radius_in)
		seg.append(Vector2(cos(a), sin(a)) * p_radius_out)
		out.append(seg)
	return out


# ── 内部 ──────────────────────────────────────────────────────────
static func _closed_loop(p_points: PackedVector2Array) -> PackedVector2Array:
	# draw_polyline 闭合环（首点补尾）
	var loop := p_points.duplicate()
	if loop.size() > 0:
		loop.append(loop[0])
	return loop

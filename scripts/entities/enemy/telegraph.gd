# scripts/entities/enemy/telegraph.gd
# 预警（Telegraph）组件（ENEMY_BOSS_TELEGRAPH.md §1.2/§1.4，P1 批次落地）：
# TelegraphCircle = 爆虫 FuseRing 泛化（radius/color/progress 三参；红=爆炸/定点 AOE，
# 金=信息性，绿=毒区）——爆虫警示圈调用点已改为本件，行为零变化（pkg 验收锁定）；
# TelegraphFan = 扇形警示（紫=扇形狙击，B2 锁定扇射前摇）。
# 程序化 _draw()；节点随 Enemy 池实例存活（惰性创建、复用仅显隐），运行期零 instantiate；
# progress 由宿主每帧推进（game_delta 通道——顿帧/冻结自然停摆）。
# 色彩纪律（§1.2）：红/橙/紫/金/绿五色只表达既定语义；前摇色 = 结算表现色。
class_name Telegraph
extends RefCounted


class TelegraphCircle:
	extends Node2D

	var radius: float = 110.0
	var color: Color = Color(1.0, 0.36, 0.36)   # 红 = 爆炸/定点 AOE（§1.2）
	var progress: float = 0.0                    # 引导进度 0~1（宿主推进）

	func _draw() -> void:
		# 虚线警戒圈（亮底风格：虚线圆 + 淡填充 + 进度弧，爆虫 FuseRing 同款程序化绘制）
		var fill := Color(color.r, color.g, color.b, 0.05 + 0.13 * progress)
		draw_circle(Vector2.ZERO, radius, fill)
		var segs := 28
		var seg_arc := TAU / float(segs * 2)
		var edge := Color(color.r, color.g, color.b, 0.4 + 0.5 * progress)
		for i in range(segs):
			var a0 := float(i) * seg_arc * 2.0
			draw_arc(Vector2.ZERO, radius, a0, a0 + seg_arc, 8, edge, 3.5, true)
		# 进度弧（柠檬金，贴近倒计时紧迫感）
		if progress > 0.01:
			draw_arc(Vector2.ZERO, radius * 0.86, -PI * 0.5,
				-PI * 0.5 + TAU * progress, 48, PopPalette.XP, 5.0, true)


class TelegraphLine:
	extends Node2D

	var length: float = 1400.0
	var width: float = 26.0
	var color: Color = Color(0.7, 0.5, 1.0)      # 紫 = 狙击线/激光（§1.2）
	var progress: float = 0.0                    # 读条进度 0~1（宿主推进）

	func setup_dir(p_dir: Vector2) -> void:
		rotation = p_dir.angle()                 # 起角锁定（带内不追踪，§2 B7）

	func _draw() -> void:
		# 矩形长带（端点起自施法者）+ 边线 + 沿带充能亮斑（进度=充能流动）
		var fill := Color(color.r, color.g, color.b, 0.08 + 0.12 * progress)
		draw_rect(Rect2(0.0, -width * 0.5, length, width), fill, true)
		var edge := Color(color.r, color.g, color.b, 0.4 + 0.45 * progress)
		draw_line(Vector2(0.0, -width * 0.5), Vector2(length, -width * 0.5), edge, 2.5, true)
		draw_line(Vector2(0.0, width * 0.5), Vector2(length, width * 0.5), edge, 2.5, true)
		var head := length * progress
		draw_circle(Vector2(head, 0.0), width * 0.5,
			Color(color.r, color.g, color.b, 0.85))
		draw_circle(Vector2(head, 0.0), width * 0.9,
			Color(color.r, color.g, color.b, 0.35))


class TelegraphFan:
	extends Node2D

	var radius: float = 240.0
	var arc_deg: float = 44.0
	var color: Color = Color(0.7, 0.5, 1.0)      # 紫 = 扇形狙击/狙击线（§1.2）
	var progress: float = 0.0                    # 读条进度 0~1（宿主推进）

	func setup_dir(p_dir: Vector2) -> void:
		# 朝向锁定（起手瞬间快照——前摇内不追踪，警示即弹道：§8.4 Archero 同形同色）
		rotation = p_dir.angle()

	func _draw() -> void:
		var half := deg_to_rad(arc_deg) * 0.5
		# 扇面淡填充（随读条渐亮）
		var fill := Color(color.r, color.g, color.b, 0.05 + 0.10 * progress)
		var pts := PackedVector2Array([Vector2.ZERO])
		var segs := 14
		for i in range(segs + 1):
			var a := -half + half * 2.0 * float(i) / float(segs)
			pts.append(Vector2(cos(a), sin(a)) * radius)
		draw_colored_polygon(pts, fill)
		# 两条半径边 + 外弧（随读条变亮）
		var edge := Color(color.r, color.g, color.b, 0.45 + 0.4 * progress)
		draw_line(Vector2.ZERO, Vector2(cos(-half), sin(-half)) * radius, edge, 3.0, true)
		draw_line(Vector2.ZERO, Vector2(cos(half), sin(half)) * radius, edge, 3.0, true)
		draw_arc(Vector2.ZERO, radius, -half, half, 32, edge, 3.5, true)
		# 中轴充能线（原点 → 半径×progress，读条感）
		if progress > 0.02:
			draw_line(Vector2.ZERO, Vector2(radius * progress, 0.0),
				Color(color.r, color.g, color.b, 0.85), 4.0, true)


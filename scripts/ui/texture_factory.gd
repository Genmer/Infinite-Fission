# scripts/ui/texture_factory.gd
# 方向 C「晴空糖果」程序贴图工厂（美术派发单：无外部资源，程序化生成 + 惰性缓存）。
# 全部贴图 = SDF 光栅化（本体填充 + 厚描边 + AA），Boot 后首次使用时生成一次并缓存；
# 运行期零重生成（静态缓存命中）。亮底风格三件套：厚描边 / 高饱和填充 / 白高光点。
class_name TextureFactory
extends RefCounted

static var _cache: Dictionary = {}            # 键 -> ImageTexture（惰性生成）


# ── 实体贴图 ──────────────────────────────────────────────────────
static func bead(p_fill: Color, p_size: int = 64, p_highlight: bool = true) -> ImageTexture:
	# 圆珠（弹幕/卫星/相位点）：厚描边圆 + 左上白高光点（亮底辨识度核心）。
	# 描边占径 ~18%——小半径弹珠（r5~14）缩放后描边仍 ≥1.6px，亮底可辨
	var key := "bead_%s_%d_%s" % [p_fill.to_html(), p_size, str(p_highlight)]
	return _cached(key, func() -> ImageTexture:
		var r := float(p_size) * 0.5 - 9.0
		var layers: Array = [
			{"sd": _circle_at(Vector2.ZERO, r), "fill": p_fill, "ow": 9.0},
		]
		if p_highlight:
			layers.append({"sd": _circle_at(Vector2(-r * 0.34, -r * 0.38), r * 0.3),
				"fill": Color(1.0, 1.0, 1.0, 0.95), "ow": 0.0})
		return _render(p_size, p_size, _shade(layers)))


static func ship(p_silhouette: bool = false) -> ImageTexture:
	# 玩家「哨兵-9」圆舰：天空蓝厚描边圆舰 + 白肚皮 + 舷窗（克制无脸；96px 画布）
	var key := "ship_%s" % str(p_silhouette)
	return _cached(key, func() -> ImageTexture:
		if p_silhouette:
			# 受击闪白剪影（白色圆轮廓，叠加在舰体上）
			return _render(96, 96, _shade([
				{"sd": _circle_at(Vector2(0.0, -2.0), 38.0), "fill": Color.WHITE, "ow": 0.0},
			]))
		var body := {"sd": _circle_at(Vector2(0.0, -2.0), 38.0), "fill": PopPalette.PLAYER, "ow": 7.0}
		var belly := {"sd": _circle_at(Vector2(0.0, 15.0), 24.0), "fill": Color(1.0, 1.0, 1.0, 0.96), "ow": 3.0}
		var window := {"sd": _circle_at(Vector2(0.0, -12.0), 10.0), "fill": Color(1.0, 1.0, 1.0, 0.95), "ow": 5.0}
		var wing_l := {"sd": _circle_at(Vector2(-30.0, 10.0), 12.0), "fill": PopPalette.PLAYER, "ow": 6.0}
		var wing_r := {"sd": _circle_at(Vector2(30.0, 10.0), 12.0), "fill": PopPalette.PLAYER, "ow": 6.0}
		return _render(96, 96, _shade([body, wing_l, wing_r, belly, window])))


static func ship_flame() -> ImageTexture:
	# 喷气小尾巴（朝下的水滴；柠檬外焰 + 白内焰；挂舰体尾部，运行期只做缩放抖动）
	var key := "ship_flame"
	return _cached(key, func() -> ImageTexture:
		var pts_outer := PackedVector2Array([Vector2(-11.0, -12.0), Vector2(11.0, -12.0), Vector2(0.0, 22.0)])
		var pts_inner := PackedVector2Array([Vector2(-5.5, -10.0), Vector2(5.5, -10.0), Vector2(0.0, 10.0)])
		return _render(44, 60, _shade([
			{"sd": _poly_sd(pts_outer), "fill": PopPalette.XP, "ow": 5.0},
			{"sd": _poly_sd(pts_inner), "fill": Color(1.0, 1.0, 1.0, 0.92), "ow": 0.0},
		])))


static func enemy_tex(p_kind: StringName, p_angry: bool = false) -> ImageTexture:
	# 敌人分型贴图（64px 画布，逻辑半径 32 = hitbox 口径；E3 画布内方胖块）：
	# grunt=E1 珊瑚圆球怪（好奇眼睛）/ dart=E2 尖头飞镖（朝上，引擎侧旋转）/
	# bastion=E3 方胖装甲块（描边特厚）/ volatile=E4 爆虫（angry=充能红脸）/
	# boss=大型圆滚滚聚合体（多层身体 + 大眼睛）；elite=E5 复用 grunt 基底 + 皇冠挂件。
	# （图层装配拆至 _enemy_layers——lambda 体不以 match 臂收尾，规避 Godot 4.3 解析器限制）
	var key := "enemy_%s_%s" % [String(p_kind), str(p_angry)]
	return _cached(key, func() -> ImageTexture:
		var canvas := 96 if p_kind == &"boss" else 64
		return _render(canvas, canvas, _shade(_enemy_layers(p_kind, p_angry))))


static func _enemy_layers(p_kind: StringName, p_angry: bool) -> Array:
	# 分型图层装配（普通函数体内的 match，无解析器歧义）
	match p_kind:
		&"dart":
			var pts := PackedVector2Array([Vector2(0.0, -28.0), Vector2(24.0, 22.0), Vector2(-24.0, 22.0)])
			return [
				{"sd": _poly_sd(pts), "fill": PopPalette.ENEMY, "ow": 6.5},
				{"sd": _circle_at(Vector2(-6.0, 4.0), 4.2), "fill": Color.WHITE, "ow": 2.2},
				{"sd": _circle_at(Vector2(6.0, 4.0), 4.2), "fill": Color.WHITE, "ow": 2.2},
			]
		&"bastion":
			var layers: Array = [
				{"sd": _box_at(Vector2.ZERO, Vector2(22.0, 22.0), 9.0), "fill": PopPalette.ENEMY, "ow": 8.5},
			]
			for corner in [Vector2(-12.0, -12.0), Vector2(12.0, -12.0), Vector2(-12.0, 12.0), Vector2(12.0, 12.0)]:
				layers.append({"sd": _circle_at(corner, 2.6), "fill": PopPalette.OUTLINE, "ow": 0.0})
			return layers
		&"volatile":
			if p_angry:
				# 充能态：深红脸 + 斜眉 + 大嘴（越滚越大由引擎侧缩放承担）
				return [
					{"sd": _circle_at(Vector2.ZERO, 25.0), "fill": PopPalette.ENEMY_DEEP, "ow": 6.5},
					{"sd": _box_rot_at(Vector2(-8.5, -12.0), Vector2(6.0, 1.6), 1.2, -0.5), "fill": PopPalette.OUTLINE, "ow": 0.0},
					{"sd": _box_rot_at(Vector2(8.5, -12.0), Vector2(6.0, 1.6), 1.2, 0.5), "fill": PopPalette.OUTLINE, "ow": 0.0},
					{"sd": _circle_at(Vector2(-8.0, -4.0), 5.4), "fill": Color.WHITE, "ow": 2.2},
					{"sd": _circle_at(Vector2(8.0, -4.0), 5.4), "fill": Color.WHITE, "ow": 2.2},
					{"sd": _circle_at(Vector2(-8.0, -3.0), 2.2), "fill": PopPalette.OUTLINE, "ow": 0.0},
					{"sd": _circle_at(Vector2(8.0, -3.0), 2.2), "fill": PopPalette.OUTLINE, "ow": 0.0},
					{"sd": _circle_at(Vector2(0.0, 10.0), 5.0), "fill": PopPalette.OUTLINE, "ow": 0.0},
				]
			return [
				{"sd": _circle_at(Vector2.ZERO, 25.0), "fill": PopPalette.ENEMY, "ow": 6.5},
				{"sd": _circle_at(Vector2(-8.0, -4.0), 5.8), "fill": Color.WHITE, "ow": 2.4},
				{"sd": _circle_at(Vector2(8.0, -4.0), 5.8), "fill": Color.WHITE, "ow": 2.4},
				{"sd": _circle_at(Vector2(-8.0, -3.5), 2.2), "fill": PopPalette.OUTLINE, "ow": 0.0},
				{"sd": _circle_at(Vector2(8.0, -3.5), 2.2), "fill": PopPalette.OUTLINE, "ow": 0.0},
				{"sd": _circle_at(Vector2(0.0, 9.0), 3.4), "fill": PopPalette.OUTLINE, "ow": 0.0},
			]
		&"boss":
			# 聚合体：中央大球 + 两侧鼓包 union；大眼 + 张嘴 + 腮红
			var body_sd := _multi_circle_min([
				[Vector2(0.0, 0.0), 40.0], [Vector2(-30.0, 14.0), 17.0], [Vector2(30.0, 14.0), 17.0],
			])
			return [
				{"sd": body_sd, "fill": PopPalette.ENEMY, "ow": 8.0},
				{"sd": _circle_at(Vector2(-13.0, -8.0), 8.6), "fill": Color.WHITE, "ow": 3.6},
				{"sd": _circle_at(Vector2(13.0, -8.0), 8.6), "fill": Color.WHITE, "ow": 3.6},
				{"sd": _circle_at(Vector2(-12.0, -7.0), 4.0), "fill": PopPalette.OUTLINE, "ow": 0.0},
				{"sd": _circle_at(Vector2(14.0, -7.0), 4.0), "fill": PopPalette.OUTLINE, "ow": 0.0},
				{"sd": _circle_at(Vector2(0.0, 16.0), 6.0), "fill": PopPalette.OUTLINE, "ow": 0.0},
				{"sd": _circle_at(Vector2(-24.0, 10.0), 4.6), "fill": Color(1.0, 1.0, 1.0, 0.45), "ow": 0.0},
				{"sd": _circle_at(Vector2(24.0, 10.0), 4.6), "fill": Color(1.0, 1.0, 1.0, 0.45), "ow": 0.0},
			]
		_:
			# grunt（E1 基底 / E5 精英基底）：珊瑚圆球怪 + 两只好奇眼睛
			return [
				{"sd": _circle_at(Vector2.ZERO, 26.0), "fill": PopPalette.ENEMY, "ow": 6.5},
				{"sd": _circle_at(Vector2(-8.5, -4.0), 6.0), "fill": Color.WHITE, "ow": 2.6},
				{"sd": _circle_at(Vector2(8.5, -4.0), 6.0), "fill": Color.WHITE, "ow": 2.6},
				{"sd": _circle_at(Vector2(-7.5, -3.0), 2.6), "fill": PopPalette.OUTLINE, "ow": 0.0},
				{"sd": _circle_at(Vector2(9.5, -3.0), 2.6), "fill": PopPalette.OUTLINE, "ow": 0.0},
			]


static func crown() -> ImageTexture:
	# 精英金色皇冠小标（挂件，引擎侧定位头顶）
	var key := "crown"
	return _cached(key, func() -> ImageTexture:
		var pts := PackedVector2Array([
			Vector2(-15.0, 11.0), Vector2(-15.0, -3.0), Vector2(-7.5, 4.0), Vector2(0.0, -10.0),
			Vector2(7.5, 4.0), Vector2(15.0, -3.0), Vector2(15.0, 11.0),
		])
		return _render(40, 30, _shade([
			{"sd": _poly_sd(pts), "fill": PopPalette.GOLD, "ow": 3.6},
		])))


static func star(p_size: int = 44, p_fill: Color = PopPalette.XP) -> ImageTexture:
	# 经验柠檬五角星（经验碎片/精通卡图标）
	var key := "star_%d_%s" % [p_size, p_fill.to_html()]
	return _cached(key, func() -> ImageTexture:
		var outer := float(p_size) * 0.5 - 5.0
		return _render(p_size, p_size, _shade([
			{"sd": _poly_sd(_star_pts(outer, outer * 0.46)), "fill": p_fill, "ow": outer * 0.3},
		])))


static func cloud(p_w: int = 190, p_h: int = 110) -> ImageTexture:
	# 大圆/胶囊云（世界基调：淡云蓝白上的低对比云；引擎侧 self_modulate 控制透明度）
	var key := "cloud_%d_%d" % [p_w, p_h]
	return _cached(key, func() -> ImageTexture:
		var body := _multi_circle_min([
			[Vector2(-p_w * 0.26, p_h * 0.12), p_h * 0.3],
			[Vector2(0.0, -p_h * 0.08), p_h * 0.4],
			[Vector2(p_w * 0.26, p_h * 0.12), p_h * 0.3],
		])
		return _render(p_w, p_h, _shade([{"sd": body, "fill": Color.WHITE, "ow": 0.0}])))


static func soft_dot(p_size: int = 64) -> ImageTexture:
	# 径向柔边白点（远层大气泡/粒子贴图）
	var key := "soft_dot_%d" % p_size
	return _cached(key, func() -> ImageTexture:
		var img := Image.create(p_size, p_size, false, Image.FORMAT_RGBA8)
		var c := float(p_size) * 0.5
		for y in range(p_size):
			for x in range(p_size):
				var t := clampf(1.0 - Vector2(float(x) + 0.5 - c, float(y) + 0.5 - c).length() / c, 0.0, 1.0)
				img.set_pixel(x, y, Color(1.0, 1.0, 1.0, t * t))
		return ImageTexture.create_from_image(img))


static func confetti_piece(p_kind: int) -> ImageTexture:
	# 彩纸屑（0=小矩形 1=圆点；白色本体，运行期 modulate 上多色）。
	# 圆点用细描边（bead 厚描边在小画布上会反超本体——多色糖粒观感优先）
	var key := "confetti_%d" % p_kind
	return _cached(key, func() -> ImageTexture:
		if p_kind == 0:
			return _render(14, 20, _shade([
				{"sd": _box_at(Vector2.ZERO, Vector2(6.0, 9.0), 2.5), "fill": Color.WHITE, "ow": 0.0},
			]))
		return _render(24, 24, _shade([
			{"sd": _circle_at(Vector2.ZERO, 10.0), "fill": Color.WHITE, "ow": 2.2},
		])))


static func type_icon(p_kind: int, p_pool: int) -> ImageTexture:
	# 选卡类型圆章：白圆章 + 藏青描边，内嵌类别形（ADD 菱 / MULT 三角 / LOCAL 圆角方 /
	# MECH 六边 / ELEM 圆环 / MASTERY 金星 / RELIC 葡萄钻 / FALLBACK 灰菱）
	var key := "type_icon_%d_%d" % [p_kind, p_pool]
	return _cached(key, func() -> ImageTexture:
		var layers: Array = [
			{"sd": _circle_at(Vector2.ZERO, 26.0), "fill": PopPalette.PANEL, "ow": 5.0},
		]
		var ink := PopPalette.OUTLINE
		match p_kind:
			1:                                    # TRAIT：按 PoolClass 分形
				match p_pool:
					0: layers.append({"sd": _poly_sd(_regular_pts(4, 13.5)), "fill": PopPalette.SUCCESS, "ow": 0.0})
					1: layers.append({"sd": _poly_sd(_regular_pts(3, 14.5)), "fill": PopPalette.ENEMY, "ow": 0.0})
					2: layers.append({"sd": _box_at(Vector2.ZERO, Vector2(10.5, 10.5), 4.5), "fill": ink, "ow": 0.0})
					3: layers.append({"sd": _poly_sd(_regular_pts(6, 14.0)), "fill": PopPalette.PLAYER, "ow": 0.0})
					_: layers.append({"sd": _ring_at(9.0, 4.6), "fill": PopPalette.SHOCK, "ow": 0.0})
			0: layers.append({"sd": _poly_sd(_star_pts(14.0, 6.4)), "fill": PopPalette.GOLD, "ow": 0.0})   # MASTERY
			2: layers.append({"sd": _poly_sd(_regular_pts(4, 13.5, 0.0)), "fill": PopPalette.SHOCK, "ow": 0.0})  # RELIC
			_: layers.append({"sd": _poly_sd(_regular_pts(4, 13.5)), "fill": PopPalette.INK_SOFT, "ow": 0.0})  # FALLBACK
		return _render(64, 64, _shade(layers)))


static func ring_tex(p_fill: Color, p_size: int = 32, p_thickness: float = 4.5) -> ImageTexture:
	# 圆环（Boss 相位空心点 / ELEM 章）
	var key := "ring_%s_%d_%.1f" % [p_fill.to_html(), p_size, p_thickness]
	return _cached(key, func() -> ImageTexture:
		var r := float(p_size) * 0.5 - 5.0
		return _render(p_size, p_size, _shade([
			{"sd": _ring_at(r, p_thickness), "fill": p_fill, "ow": 0.0},
		])))


# ── 光栅化内核 ────────────────────────────────────────────────────
static func _render(p_w: int, p_h: int, p_shade: Callable) -> ImageTexture:
	# 逐像素着色（Boot/首次使用一次性成本；缓存后运行期零生成）
	var img := Image.create(p_w, p_h, false, Image.FORMAT_RGBA8)
	var half_w := float(p_w) * 0.5
	var half_h := float(p_h) * 0.5
	for y in range(p_h):
		var py := float(y) + 0.5 - half_h
		for x in range(p_w):
			img.set_pixel(x, y, p_shade.call(float(x) + 0.5 - half_w, py))
	return ImageTexture.create_from_image(img)


static func _cached(p_key: String, p_builder: Callable) -> ImageTexture:
	if _cache.has(p_key):
		return _cache[p_key] as ImageTexture
	var tex := p_builder.call() as ImageTexture
	_cache[p_key] = tex
	return tex


static func _shade(p_layers: Array) -> Callable:
	# 图层合成器：[{sd: Callable(x,y)->float, fill: Color, ow: 描边宽, oc: 描边色}]
	# 先绘制在下、后绘制在上；描边在下层、填充在上层，统一 1px AA。
	return func(p_x: float, p_y: float) -> Color:
		var col := Color(0.0, 0.0, 0.0, 0.0)
		for layer_v: Variant in p_layers:
			var layer: Dictionary = layer_v
			var sd: Callable = layer["sd"]
			var d: float = sd.call(p_x, p_y)
			var fill: Color = layer["fill"]
			var ow := float(layer.get("ow", 0.0))
			var oc: Color = layer.get("oc", PopPalette.OUTLINE)
			var body := clampf(0.5 - d, 0.0, 1.0)
			var with_edge := clampf(0.5 - d + ow, 0.0, 1.0)
			col = _over(col, Color(oc.r, oc.g, oc.b, oc.a * (with_edge - body)))
			col = _over(col, Color(fill.r, fill.g, fill.b, fill.a * body))
		return col


static func _over(p_dst: Color, p_src: Color) -> Color:
	# src-over 标准合成
	var a := p_src.a + p_dst.a * (1.0 - p_src.a)
	if a <= 0.0005:
		return Color(0.0, 0.0, 0.0, 0.0)
	var c := (p_src * p_src.a + p_dst * (p_dst.a * (1.0 - p_src.a))) / a
	c.a = a
	return c


# ── SDF 基元 ──────────────────────────────────────────────────────
static func _circle_at(p_center: Vector2, p_r: float) -> Callable:
	return func(p_x: float, p_y: float) -> float:
		return sqrt(pow(p_x - p_center.x, 2.0) + pow(p_y - p_center.y, 2.0)) - p_r


static func _multi_circle_min(p_circles: Array) -> Callable:
	# 多圆 union（[[center, radius], ...]）
	return func(p_x: float, p_y: float) -> float:
		var best := 1e9
		for entry: Variant in p_circles:
			var pair: Array = entry
			var c: Vector2 = pair[0]
			var r: float = pair[1]
			var d := sqrt(pow(p_x - c.x, 2.0) + pow(p_y - c.y, 2.0)) - r
			best = minf(best, d)
		return best


static func _box_at(p_center: Vector2, p_half: Vector2, p_rad: float) -> Callable:
	return func(p_x: float, p_y: float) -> float:
		return _sd_box(p_x - p_center.x, p_y - p_center.y, p_half, p_rad)


static func _box_rot_at(p_center: Vector2, p_half: Vector2, p_rad: float, p_angle: float) -> Callable:
	# 旋转圆角盒（爆虫斜眉）
	return func(p_x: float, p_y: float) -> float:
		var rel := Vector2(p_x - p_center.x, p_y - p_center.y).rotated(-p_angle)
		return _sd_box(rel.x, rel.y, p_half, p_rad)


static func _ring_at(p_r: float, p_thickness: float) -> Callable:
	return func(p_x: float, p_y: float) -> float:
		return absf(sqrt(p_x * p_x + p_y * p_y) - p_r) - p_thickness


static func _poly_sd(p_pts: PackedVector2Array) -> Callable:
	# 多边形 SDF（负在内：交叉计数 + 边最近距离）
	return func(p_x: float, p_y: float) -> float:
		var inside := false
		var best := 1e9
		var n := p_pts.size()
		var p := Vector2(p_x, p_y)
		for i in range(n):
			var a := p_pts[i]
			var b := p_pts[(i + 1) % n]
			var ab := b - a
			var ap := p - a
			var t := clampf(ap.dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
			best = minf(best, (ap - ab * t).length())
			if (a.y > p_y) != (b.y > p_y):
				var xint := a.x + (p_y - a.y) / (b.y - a.y) * (b.x - a.x)
				if p_x < xint:
					inside = not inside
		return -best if inside else best


static func _sd_box(p_x: float, p_y: float, p_half: Vector2, p_rad: float) -> float:
	var qx := absf(p_x) - p_half.x + p_rad
	var qy := absf(p_y) - p_half.y + p_rad
	return Vector2(maxf(qx, 0.0), maxf(qy, 0.0)).length() + minf(maxf(qx, qy), 0.0) - p_rad


static func _regular_pts(p_sides: int, p_radius: float, p_rot: float = -PI * 0.5) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(p_sides):
		var a := p_rot + TAU * float(i) / float(p_sides)
		pts.append(Vector2(cos(a), sin(a)) * p_radius)
	return pts


static func _star_pts(p_outer: float, p_inner: float, p_rot: float = -PI * 0.5) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(10):
		var r := p_outer if i % 2 == 0 else p_inner
		var a := p_rot + TAU * float(i) / 10.0
		pts.append(Vector2(cos(a), sin(a)) * r)
	return pts

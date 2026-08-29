# scripts/ui/texture_factory.gd
# 程序贴图集中工厂（主控派发单 §纪律：惰性生成 + 缓存；无外部资源）。
# 只服务 Sprite2D 批量渲染路径（投射物/经验碎片/粒子）——线框实体走 VectorGlyph
# _draw 矢量绘制，不经此工厂。全部静态；Image 像素级生成，一次性成本 <1ms。
class_name TextureFactory
extends RefCounted

static var _cache: Dictionary = {}            # StringName -> ImageTexture

# 生成尺寸（纹理内含辉光余量；实体侧按需等比缩放）
const SEGMENT_SIZE := Vector2i(20, 6)         # 玩家弹短亮线段（矢量弹）
const DOT_SIZE := 14                          # 敌弹红点（辉光点）
const SQUARE_SIZE := 10                       # 经验琥珀小方（像素感，无抗锯齿）


static func bullet_segment() -> ImageTexture:
	# 横向短亮线段：白热核心 + 软辉光衰减（白模，self_modulate 染元素色）
	return _cached(&"segment", func() -> Image: return _segment_image())


static func glow_dot() -> ImageTexture:
	# 径向辉光点：热核 + 平方衰减（敌弹红点/追踪弹头）
	return _cached(&"dot", func() -> Image: return _dot_image())


static func pixel_square() -> ImageTexture:
	# 实心小方（经验碎块；保留 1px 暗边做像素感）
	return _cached(&"square", func() -> Image: return _square_image())


# ── 内部：缓存与生成 ──────────────────────────────────────────────
static func _cached(p_key: StringName, p_builder: Callable) -> ImageTexture:
	var hit: Variant = _cache.get(p_key, null)
	if hit is ImageTexture:
		return hit
	var img: Image = p_builder.call()
	var tex := ImageTexture.create_from_image(img)
	_cache[p_key] = tex
	return tex


static func _segment_image() -> Image:
	var w := SEGMENT_SIZE.x
	var h := SEGMENT_SIZE.y
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var cy := float(h) * 0.5 - 0.5
	var core_w := float(w) * 0.55                # 前段白热核心长度
	for y in range(h):
		for x in range(w):
			var dy := absf(float(y) - cy)
			var t := float(x) / float(w - 1)     # 0 尾 → 1 头
			# 横向：头亮尾暗；纵向：高斯样衰减成辉光
			var long_f := 0.25 + 0.75 * t
			var cross := maxf(1.0 - dy / (cy + 0.5), 0.0)
			var a := pow(cross, 1.8) * long_f
			var hot := (t >= 1.0 - core_w / float(w)) and dy <= 0.5
			var col := Palette.WHITE_HOT if hot else Palette.WHITE_HOT.lerp(Color.TRANSPARENT, 1.0 - a)
			img.set_pixel(x, y, Color(col.r, col.g, col.b, clampf(a if not hot else 1.0, 0.0, 1.0)))
	return img


static func _dot_image() -> Image:
	var s := DOT_SIZE
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var c := float(s) * 0.5 - 0.5
	for y in range(s):
		for x in range(s):
			var d := Vector2(float(x) - c, float(y) - c).length() / (c + 0.5)
			var a := pow(maxf(1.0 - d, 0.0), 2.2)
			if d < 0.35:
				a = 1.0                          # 白热核心
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(a, 0.0, 1.0)))
	return img


static func _square_image() -> Image:
	var s := SQUARE_SIZE
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 1.0, 1.0, 1.0))
	# 1px 暗边（像素碎块感；self_modulate 染琥珀后边为暗琥珀）
	for i in range(s):
		img.set_pixel(i, 0, Color(0.55, 0.55, 0.55, 1.0))
		img.set_pixel(i, s - 1, Color(0.55, 0.55, 0.55, 1.0))
		img.set_pixel(0, i, Color(0.55, 0.55, 0.55, 1.0))
		img.set_pixel(s - 1, i, Color(0.55, 0.55, 0.55, 1.0))
	return img

# scripts/ui/texture_factory.gd
# 方向 A 程序化贴图工厂：全部贴图运行期惰性生成 + 静态缓存（无外部资源/插件）。
# 纪律：同类型实体共享同一 Texture2D / CanvasItemMaterial 实例（禁止每弹新建材质）；
# 生成集中在 Boot 后首帧惰性触发，运行期零实例化（缓存命中直接返回）。
class_name TextureFactory
extends RefCounted

# ── 缓存（Texture2D / Material 各一表） ──────────────────────────
static var _textures: Dictionary = {}         # StringName -> Texture2D
static var _materials: Dictionary = {}        # StringName -> Material

const GLOW_DOT_SIZE := 64                     # 柔光圆点（弹丸光晕/引擎/粒子）
const COMET_SIZE := 64                        # 我方弹（含拖尾，弹头朝上）
const ORB_SIZE := 48                          # 敌弹光珠（各向同性）
const DIAMOND_SIZE := 32                      # 经验晶体（菱形）
const STRIPE_SIZE := 28                       # Boss 警报条纹（可平铺）


# ── 贴图 ─────────────────────────────────────────────────────────
static func glow_dot() -> Texture2D:
	# 柔光圆点：径向衰减白光（染色交 modulate/self_modulate）
	if _textures.has(&"glow_dot"):
		return _textures.get(&"glow_dot") as Texture2D
	var img := Image.create(GLOW_DOT_SIZE, GLOW_DOT_SIZE, false, Image.FORMAT_RGBA8)
	var c := float(GLOW_DOT_SIZE) * 0.5 - 0.5
	for y in range(GLOW_DOT_SIZE):
		for x in range(GLOW_DOT_SIZE):
			var d := Vector2(float(x) - c, float(y) - c).length() / c
			var a := clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a * a))    # 平方衰减=柔光
	return _cache_tex(&"glow_dot", img)


static func comet() -> Texture2D:
	# 我方弹丸：弹头（实心亮点）+ 预烘焙拖尾（朝上渐隐）——零逐帧拖尾成本。
	# 逐像素合成：以柔光场叠加「头部圆斑 + 尾部指数渐隐条」。
	if _textures.has(&"comet"):
		return _textures.get(&"comet") as Texture2D
	var img := Image.create(COMET_SIZE, COMET_SIZE, false, Image.FORMAT_RGBA8)
	var c := float(COMET_SIZE) * 0.5 - 0.5
	var head_y := c * 0.55
	for y in range(COMET_SIZE):
		for x in range(COMET_SIZE):
			var px := float(x) - c
			var py := float(y) - c
			# 头部：偏上实心圆斑（r≈9px）
			var dh := Vector2(px, py - head_y).length()
			var a_head := clampf(1.0 - dh / 9.0, 0.0, 1.0)
			var core := clampf(1.0 - dh / 3.5, 0.0, 1.0)
			# 尾部：竖向指数渐隐（头以下），横向高斯收窄
			var tail_t := clampf((head_y - py) / (head_y + c), 0.0, 1.0)
			var a_tail := exp(-6.5 * tail_t) * exp(-pow(px / 5.5, 2.0))
			var a := clampf(a_head * 0.85 + a_tail * 0.8 + core, 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return _cache_tex(&"comet", img)


static func orb() -> Texture2D:
	# 敌弹：品红光珠（实心核 + 宽柔光晕；各向同性不随朝向旋转）
	if _textures.has(&"orb"):
		return _textures.get(&"orb") as Texture2D
	var img := Image.create(ORB_SIZE, ORB_SIZE, false, Image.FORMAT_RGBA8)
	var c := float(ORB_SIZE) * 0.5 - 0.5
	for y in range(ORB_SIZE):
		for x in range(ORB_SIZE):
			var d := Vector2(float(x) - c, float(y) - c).length() / c
			var glow := pow(clampf(1.0 - d, 0.0, 1.0), 2.2)
			var core := clampf(1.0 - d * 2.6, 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(glow * 0.7 + core, 0.0, 1.0)))
	return _cache_tex(&"orb", img)


static func diamond() -> Texture2D:
	# 经验晶体：琥珀菱形 + 微光晕（旋转对称十字采样近似）
	if _textures.has(&"diamond"):
		return _textures.get(&"diamond") as Texture2D
	var img := Image.create(DIAMOND_SIZE, DIAMOND_SIZE, false, Image.FORMAT_RGBA8)
	var c := float(DIAMOND_SIZE) * 0.5 - 0.5
	for y in range(DIAMOND_SIZE):
		for x in range(DIAMOND_SIZE):
			var m := (absf(float(x) - c) + absf(float(y) - c)) / c
			var fill := clampf(1.0 - m, 0.0, 1.0)             # 菱形体内
			var glow := pow(clampf(1.15 - m, 0.0, 1.0), 3.0) * 0.4
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(fill + glow, 0.0, 1.0)))
	return _cache_tex(&"diamond", img)


static func soft_particle() -> Texture2D:
	# 粒子发射器贴图：32×32 柔光点（替换旧 4×4 硬块）
	if _textures.has(&"soft_particle"):
		return _textures.get(&"soft_particle") as Texture2D
	var size := 32
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := float(size) * 0.5 - 0.5
	for y in range(size):
		for x in range(size):
			var d := Vector2(float(x) - c, float(y) - c).length() / c
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, pow(clampf(1.0 - d, 0.0, 1.0), 1.6)))
	return _cache_tex(&"soft_particle", img)


static func hp_gradient() -> Texture2D:
	# HP 条填充：水平渐变（左 青 → 中 白青 → 右 深青，能量槽观感；32×4 足够拉伸）
	if _textures.has(&"hp_gradient"):
		return _textures.get(&"hp_gradient") as Texture2D
	var img := _hstrip(32, 4, [
		[Palette.CYAN.darkened(0.25), 0.0],
		[Palette.CYAN, 0.55],
		[Palette.TEXT_MAIN, 0.85],
		[Palette.CYAN.lightened(0.2), 1.0],
	])
	return _cache_tex(&"hp_gradient", img)


static func hp_low_gradient() -> Texture2D:
	# 低血压红态填充（≤30% 呼吸切换用：暗红 → 亮红）
	if _textures.has(&"hp_low_gradient"):
		return _textures.get(&"hp_low_gradient") as Texture2D
	var img := _hstrip(32, 4, [
		[Palette.RED.darkened(0.35), 0.0],
		[Palette.RED, 0.7],
		[Palette.RED.lightened(0.25), 1.0],
	])
	return _cache_tex(&"hp_low_gradient", img)


static func xp_gradient() -> Texture2D:
	# 经验条填充：琥珀渐变
	if _textures.has(&"xp_gradient"):
		return _textures.get(&"xp_gradient") as Texture2D
	var img := _hstrip(32, 4, [
		[Palette.AMBER.darkened(0.3), 0.0],
		[Palette.AMBER, 0.7],
		[Palette.AMBER.lightened(0.25), 1.0],
	])
	return _cache_tex(&"xp_gradient", img)


static func stripes() -> ImageTexture:
	# Boss 警报条纹：45° 红黑斜纹（可平铺；UV 滚动做流动警报）
	if _textures.has(&"stripes"):
		return _textures.get(&"stripes") as ImageTexture
	var img := Image.create(STRIPE_SIZE, STRIPE_SIZE, false, Image.FORMAT_RGBA8)
	for y in range(STRIPE_SIZE):
		for x in range(STRIPE_SIZE):
			var band := int(float(x + y) / 7.0) % 2 == 0
			var col := Palette.RED if band else Color(Palette.RED.darkened(0.75), 0.0)
			img.set_pixel(x, y, col)
	var tex := ImageTexture.create_from_image(img)
	_textures[&"stripes"] = tex
	return tex


static func white_px() -> Texture2D:
	# 4×4 纯白（进度条底/通用占位）
	if _textures.has(&"white_px"):
		return _textures.get(&"white_px") as Texture2D
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	return _cache_tex(&"white_px", img)


# ── 共享材质（同类型实体共享实例——禁止逐弹新建） ────────────────
static func mat_add() -> CanvasItemMaterial:
	# 加色混合（发光体标准通道：弹丸/光晕/激光/引擎）
	if _materials.has(&"add"):
		return _materials.get(&"add") as CanvasItemMaterial
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_materials[&"add"] = mat
	return mat


static func mat_add_pulse() -> ShaderMaterial:
	# 加色 + 呼吸脉冲（u_time 驱动；Boss 光环/选卡微光共用，同 shader 单实例）
	if _materials.has(&"add_pulse"):
		return _materials.get(&"add_pulse") as ShaderMaterial
	var shader := Shader.new()
	shader.code = "\
shader_type canvas_item;\n\
uniform float speed : hint_range(0.1, 8.0) = 2.0;\n\
uniform float base_alpha : hint_range(0.0, 1.0) = 0.55;\n\
uniform float amp : hint_range(0.0, 1.0) = 0.35;\n\
void fragment() {\n\
\tfloat pulse = base_alpha + amp * 0.5 * (1.0 + sin(TIME * speed));\n\
\tCOLOR = vec4(COLOR.rgb, COLOR.a * pulse);\n\
}\n"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	_materials[&"add_pulse"] = mat
	return mat


# ── 内部 ─────────────────────────────────────────────────────────
static func _cache_tex(p_key: StringName, p_img: Image) -> ImageTexture:
	var tex := ImageTexture.create_from_image(p_img)
	_textures[p_key] = tex
	return tex


static func _hstrip(p_w: int, p_h: int, p_stops: Array) -> Image:
	# 水平渐变条：p_stops = [[Color, t], ...]（t 升序 0~1）
	var img := Image.create(p_w, p_h, false, Image.FORMAT_RGBA8)
	for x in range(p_w):
		var t := float(x) / float(maxi(p_w - 1, 1))
		var col := Color(1.0, 1.0, 1.0, 1.0)
		var i := 0
		while i < p_stops.size() - 1 and t > float(p_stops[i + 1][1]):
			i += 1
		if i >= p_stops.size() - 1:
			col = p_stops[p_stops.size() - 1][0]
		else:
			var a: Color = p_stops[i][0]
			var b: Color = p_stops[i + 1][0]
			var span := float(p_stops[i + 1][1]) - float(p_stops[i][1])
			var k := 0.0 if span <= 0.0 else (t - float(p_stops[i][1])) / span
			col = a.lerp(b, clampf(k, 0.0, 1.0))
		for y in range(p_h):
			img.set_pixel(x, y, col)
	return img

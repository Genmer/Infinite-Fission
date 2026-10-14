# scripts/combat/weapon/melee/crystal_blade_factory.gd
# R267 视觉刀 §2.2：水晶质感刀生成器（static 工具，纯确定性零 rng）。
# 反馈 B「法器旋风刀后期颜色发棕……所有近战/法器武器染色改为对应元素透明刀、
# 水晶质感而非简单颜色」——§2.1 棕根因五点链的拆法 = **明度策略反转**：
# 弃「刀背压暗」（arc_slash.gd:706-714 darkened 梯度——暖相+高饱和+低明度=棕
# 的第三个条件正是压暗自己造的），改「外壳半透 + 亮核提亮 + 白色刃缘」——
# 亮核明度地板 CORE_V_MIN=0.75 > 棕判据 v≤0.62 上界，发棕区在数学上不可达。
# · 路线拍板（§2.2）：多层多边形双形态——烘焙贴图（Sprite2D 弹体站点 W10/W11/W12）
#   + 即时顶点色（W8 环刀 / W9 saber / W13 greatsword 本体）；不选 Shader
#   （逐实例 ShaderMaterial 断批——enemy.gd:2743 教训）、不选 Gradient2D
#   （4.4 类，4.3 ClassDB 不存在——API 探针实证）。
# · 形状不发明（§2.2）：顶点表全部自既有武器脚本**同形拷贝**（saber/greatsword ←
#   arc_slash.gd:649-676；灵剑刃 ← flying_sword_weapon.gd:361-364；裂地斧头 ←
#   ground_axe_weapon.gd:519-523；回旋刃月牙 ← texture_factory.gd:1178-1179），
#   生成器只做「同形外扩 + 分层装色」。
# · 烘焙内核 = **直排逐像素循环**（boomerang_tex 内核风格，实测 44px≈0.2ms），
#   不走 _shade 闭包（实测 64px×4 层≈24.5ms——闭包逐像素调用是慢源，超 §2.6
#   「贴图首生成 ≤10ms」门 2 倍+；探针 archive/repo_logs/r267_crystal_smoke2 实测）。
#   多边形距离函数与 TextureFactory._poly_sd（texture_factory.gd:1999-2017）同式
#   直排拷贝（负在内；闭包改直调——同公式，逐像素省闭包开销）。
# · KIN/身份形态豁免（§2.2 评审⑦）：入参命中身份表 → 不进分层装色、不钳饱和、
#   不提亮（W13 黑金 s≈0.06 被钳 0.55 再提亮 =「黑金巨剑」读感尽毁；_t2_fill
#   greatsword 暗黑契约 arc_slash.gd:640-646 同守）。豁免判在调用侧先行（刀体/
#   弹体站点 KIN 直走原路径零改动），本表为生成器内兜底二道闸。
# · 缓存纪律（§2.5-1）：烘焙键 "<style>|<fill.to_html()>|<t2>|<quality>"、即时
#   色表键 "|<layer>" 进本类 static 缓存（勿写 TextureFactory 共享 _cache——
#   flying_sword_weapon.gd:323 单一写者纪律先例）；quality 进键（改档重生成不遮蔽）。
# · 降档矩阵（§2.5-4，照 elemental_fx_layer.gd:54-55 预算表先例）：
#   档2 = 外壳/过渡/亮核/白刃缘/内折射线 五层；档1 = 过渡+亮核+刃缘 三层；
#   档0 = 单层 α0.50 平涂 + 刃缘 两层。KIN 豁免路径不参与降档（本就零增量）。
class_name CrystalBladeFactory
extends RefCounted

# ── 层配方常量（处方建议值——真机 vc 轮判读定档，§2.6 调参声明） ──────────────
const SAT_FLOOR := 0.55               # 饱和度下限钳制（§2.6-a：入参 s<0.55 → 输出 0.55）
const CORE_V_MIN := 0.75              # 亮核明度地板（> 棕判据 v≤0.62 上界——发棕不可达）
const SHELL_EXPAND := 1.32            # 外壳外扩倍率（§2.5-4）
# R268 真透明重调（用户反馈：「砍出去并非透明还是实色——要能量感/透明塑料玩具那种，
# 反正要透明，参照阔剑转圈的蓝色透明」）：主体层 α 全线下调——旧核 0.92/过渡 0.45/
# 平涂 0.85 大面积近实色=「实色刀」读感根因；新值刀体透底（能量感），轮廓描边+白刃缘
# 双硬边保剪影与可读（透明塑料玩具=透光芯+硬边）。棕防线零动（SAT_FLOOR/CORE_V_MIN
# 色相明度侧与 α 正交）；白刃缘/折射线 α 不动（细线高光不吃透明预算）。
const ALPHA_SHELL := 0.18             # 外壳层 α（档2）
const ALPHA_TRANSITION := 0.32        # 过渡层 α
const ALPHA_CORE := 0.60              # 亮核层 α
const ALPHA_EDGE := 0.9               # 白刃缘 α
const ALPHA_FLAT := 0.50              # 档0 平涂 α
const ALPHA_REFRACT := 0.55           # 内折射亮线 α（档2）
const T2_SHELL_ALPHA_BONUS := 0.08    # 质变外壳加浓（替代旧 T2_TINT_DARKEN 加深——
                                      # 加深正是棕链第 4 环，质变改「更亮更浓」）
const T2_CORE_V_BONUS := 0.08         # 质变亮核再提亮
const ICON_SHELL_ALPHA := 0.30        # 图标水晶外壳 α（c′ 防混搭特征层）
const ICON_SHELL_EXPAND := 1.45       # 图标壳层外扩（修轮①：1.28 外扩环大半被本体
                                      # ow2.2-2.8 不透明描边盖掉——W9/W11/W13 实测仅
                                      # 2px 低于感知阈值；1.45 环带露出可读。W13 刃尖
                                      # 壳环超出 56px 画布上缘属可接受裁切——环带沿刃
                                      # 身两侧可见即达成可读性）

# ── 样式键（与各站点 blade_style/弹体样式对齐） ──────────────────────────────
const STYLE_SABER := &"saber"                 # W9 旋风刀本体（即时形态）
const STYLE_GREATSWORD := &"greatsword"       # W13 裂地斩本体（即时形态）
const STYLE_WOLF := &"wolf"                   # W8 天狼刀环刀（即时形态——顶点动态，壳层站点内联）
const STYLE_SPIRIT_SWORD := &"spirit_sword"   # W11 灵剑弹体（烘焙）
const STYLE_GROUND_AXE := &"ground_axe"       # W12 裂地斧弹体（烘焙）
const STYLE_BOOMERANG := &"boomerang"         # W10 回旋刃弹体（烘焙）

# 即时形态色表层键
const LAYER_SHELL := &"shell"
const LAYER_BODY := &"body"

# 身份色豁免表（§2.2：KIN/空池回落色——命中即不进水晶配方）
const IDENTITY_FILLS: Array[Color] = [
	Color(0.35, 0.92, 0.55),          # W9 SABER_TINT 青绿（arc_slash.gd:56 同值拷贝）
	Color(0.16, 0.15, 0.2),           # W13 GREATSWORD_TINT 暗黑底（arc_slash.gd:57）
	PopPalette.PLAYER,                # W8 狼刀蓝身 / W11 灵剑银蓝缺省
	Color(0.62, 0.68, 0.78),          # W12 FLIGHT_STEEL 岩钢（ground_axe_weapon.gd:492）
	PopPalette.GOLD,                  # W10 回旋刃金（KIN 缺省）
]

# 顶点角色表（crystal_cols 装色映射：1=过渡色位 / 2=亮核色位；序 = 各刀顶点表序）
# saber 8 顶点（arc_slash.gd:670-673 刀背 0-2 → 刀尖 3 → 刃口 4-6 → 刃根 7）：
#   刀背=过渡、尖与刃=亮核（原 darkened→lightened 梯度的明度反转位对应）
# greatsword 8 顶点（arc_slash.gd:665-668 序同构）；wolf 7 顶点（orbit_field.gd
#   _draw_wolf_knife body 表序：tip/spine_mid/spine_root/root_fwd/root_back/edge_*）
const _ROLES := {
	&"saber": [1, 1, 2, 2, 2, 2, 2, 1],
	&"greatsword": [1, 1, 2, 2, 2, 2, 1, 1],
	&"wolf": [2, 1, 1, 1, 1, 2, 2],
}


# ── 缓存与观测口（测试读回——缓存命中零重建断言 §2.6-c/g） ────────────────────
static var _cols_cache: Dictionary = {}    # 即时形态色表（键 style|fill|t2|q|layer）
static var _shell_cache: Dictionary = {}   # 即时形态外壳顶点（键 style|t2|expand）
static var _tex_cache: Dictionary = {}     # 烘焙贴图（键 style|fill|t2|q）
static var _metrics: Dictionary = {        # 构建命中计数（g 零分配断言的判读源）
	"cols_builds": 0, "cols_hits": 0,
	"shell_builds": 0, "shell_hits": 0,
	"tex_builds": 0, "tex_hits": 0,
}
static var _icon_builds: Dictionary = {}   # 图标水晶版构建计数（c′ 防混搭机制标记）


# ── 豁免判与单层配色（数据面读回口——测试 §2.6-a/a′/b 直驱） ──────────────────
static func is_identity_fill(p_fill: Color) -> bool:
	# KIN/身份回落色判（§2.2 评审⑦）——元素混色 blend_element_color 输出恒 ≠ 表值
	for c in IDENTITY_FILLS:
		if p_fill == c:
			return true
	return false


static func _clamped_tint(p_fill: Color, p_identity: bool, p_v_floor: float,
		p_v_scale := 1.0) -> Color:
	# 元素染色路径：sat 下限钳制 + 明度分层（修轮①评审②：七元素表色 v 全 ≥0.757
	# 高于任一地板——纯地板在元素域是空操作，分层实际只靠 α；过渡层改 v×p_v_scale
	# 乘式（0.92）造真实明度层次，地板仅对 blend 低明度混色入参兜底）；两断言
	# §2.6-a：s≥0.55、v≥地板。身份路径：直返零偏移（§2.6-a′：不钳不提亮）。
	if p_identity:
		return p_fill
	var v := minf(maxf(p_fill.v * p_v_scale, p_v_floor), 1.0)
	return Color.from_hsv(p_fill.h, maxf(p_fill.s, SAT_FLOOR), v)


static func layer_count(p_quality: int) -> int:
	# 降档矩阵层数（§2.6-b：档2 五层 / 档1 三层 / 档0 两层=平涂+刃缘）
	match clampi(p_quality, 0, 2):
		2:
			return 5
		1:
			return 3
		0:
			return 2
	return 5


static func layer_color(p_fill: Color, p_t2: bool, p_quality: int, p_layer: int) -> Color:
	# 单层配色单源（p_layer：0=外壳 1=过渡 2=亮核 3=白刃缘 4=折射线 5=档0平涂）。
	# α 与层可用性随档位：外壳/折射线档2 专属（低档 α=0 即「层不绘制」）；
	# 身份入参 → RGB 零偏移直返（仅补层 α——兜底路径，站点侧本不进水晶配方）。
	var q := clampi(p_quality, 0, 2)
	var identity := is_identity_fill(p_fill)
	var col := p_fill
	var a := 0.0
	match p_layer:
		0:
			col = _clamped_tint(p_fill, identity, 0.70)
			a = (ALPHA_SHELL + (T2_SHELL_ALPHA_BONUS if p_t2 else 0.0)) if q >= 2 else 0.0
		1:
			# 修轮①：过渡层 v×0.92 真明度分层（< 亮核 v；旧纯地板对元素域零作用）
			col = _clamped_tint(p_fill, identity, 0.68, 0.92)
			a = ALPHA_TRANSITION
		2:
			col = _clamped_tint(p_fill, identity,
				CORE_V_MIN + (T2_CORE_V_BONUS if p_t2 else 0.0))
			a = ALPHA_CORE
		3:
			col = Color.WHITE                      # 白刃缘（§2.2 棕修手法第三件）
			a = ALPHA_EDGE
		4:
			col = _clamped_tint(p_fill, identity, CORE_V_MIN)
			a = ALPHA_REFRACT if q >= 2 else 0.0
		5:
			col = _clamped_tint(p_fill, identity, 0.75)
			a = ALPHA_FLAT
	col.a = a
	return col


# ── 即时形态：色表 + 外壳顶点（W8/W9/W13 本体绘制站点消费） ────────────────────
static func crystal_cols(p_style: StringName, p_fill: Color, p_t2: bool,
		p_quality: int, p_layer: StringName) -> PackedColorArray:
	# 按顶点角色表的装色输出（§2.6-a 棕判据采样面 = &"body" 数组；&"shell" = 壳层
	# 均色表）。缓存键含 quality（§2.5-4 改档不遮蔽）；档1/0 的 shell 层返回空表
	# （调用侧按 layer_count/表空判层可用——「层不绘制」的数据面表达）。
	var q := clampi(p_quality, 0, 2)
	var key := "%s|%s|%s|%d|%s" % [String(p_style), p_fill.to_html(),
		str(p_t2), q, String(p_layer)]
	if _cols_cache.has(key):
		_metrics["cols_hits"] = int(_metrics["cols_hits"]) + 1
		return _cols_cache[key]
	var roles: Array = _ROLES.get(p_style, [2])
	var out := PackedColorArray()
	if p_layer == LAYER_SHELL:
		if q >= 2:
			var shell_col := layer_color(p_fill, p_t2, q, 0)
			for i in range(roles.size()):
				out.append(shell_col)
	elif q == 0:
		var flat := layer_color(p_fill, p_t2, q, 5)     # 档0 单层平涂
		for i in range(roles.size()):
			out.append(flat)
	else:
		for role in roles:                              # 档1+：过渡→亮核按角色
			out.append(layer_color(p_fill, p_t2, q, int(role)))
	_cols_cache[key] = out
	_metrics["cols_builds"] = int(_metrics["cols_builds"]) + 1
	return out


static func crystal_shell_poly(p_style: StringName, p_t2: bool,
		p_expand: float) -> PackedVector2Array:
	# 即时形态外壳顶点（static 缓存；§2.6-d 包围盒 ⊇ 本体断言的读回口）。
	# wolf 例外：环刀顶点逐刀动态（orbit-local 随 motion 变），壳层由站点经
	# expand_poly 内联外扩（本函数对其返回空表）。
	var key := "%s|%s|%d" % [String(p_style), str(p_t2), roundi(p_expand * 100.0)]
	if _shell_cache.has(key):
		_metrics["shell_hits"] = int(_metrics["shell_hits"]) + 1
		return _shell_cache[key]
	var out := PackedVector2Array()
	if p_style == STYLE_SABER or p_style == STYLE_GREATSWORD:
		out = expand_poly(_body_poly(p_style, p_t2), p_expand)
	_shell_cache[key] = out
	_metrics["shell_builds"] = int(_metrics["shell_builds"]) + 1
	return out


static func expand_poly(p_pts: PackedVector2Array, p_expand: float) -> PackedVector2Array:
	# 绕质心等比外扩（外壳/图标壳层单源——§2.6-d 外扩单调性的算子本体）
	if p_pts.is_empty() or absf(p_expand - 1.0) < 0.0001:
		return p_pts
	var centroid := Vector2.ZERO
	for pt in p_pts:
		centroid += pt
	centroid /= float(p_pts.size())
	var out := PackedVector2Array()
	out.resize(p_pts.size())
	for i in range(p_pts.size()):
		out[i] = centroid + (p_pts[i] - centroid) * p_expand
	return out


static func _body_poly(p_style: StringName, p_t2: bool) -> PackedVector2Array:
	# saber/greatsword 本体顶点表（arc_slash.gd:649-676 同形拷贝——形状不发明，
	# §2.2；greatsword w = 1.6（基）/×1.3 质变加宽（arc_slash.gd:663-664 同式））
	if p_style == STYLE_GREATSWORD:
		var w := 1.6 * (1.3 if p_t2 else 1.0)
		return PackedVector2Array([
			Vector2(36.0, 9.0 * w), Vector2(118.0, 9.0 * w), Vector2(150.0, -1.0 * w),
			Vector2(118.0, -9.0 * w), Vector2(84.0, -9.0 * w), Vector2(52.0, -9.0 * w),
			Vector2(36.0, -9.0 * w), Vector2(28.0, 0.0),
		])
	return PackedVector2Array([
		Vector2(38.0, 6.0), Vector2(95.0, 14.0), Vector2(128.0, 6.0),
		Vector2(150.0, -10.0),
		Vector2(140.0, -20.0), Vector2(100.0, -13.0), Vector2(65.0, -11.0),
		Vector2(38.0, -6.0),
	])


# ── 烘焙形态：弹体水晶贴图（W10/W11/W12 Sprite2D 站点消费） ───────────────────
static func crystal_tex(p_style: StringName, p_fill: Color, p_t2: bool,
		p_quality: int) -> ImageTexture:
	# 烘焙水晶贴图（缓存键含 quality——§2.5-4）。身份入参走单层平涂兜底
	#（站点侧 KIN 本不进此口；二道闸防未守卫调用方拿七层洗掉身份色）。
	var q := clampi(p_quality, 0, 2)
	var key := "%s|%s|%s|%d" % [String(p_style), p_fill.to_html(), str(p_t2), q]
	if _tex_cache.has(key):
		_metrics["tex_hits"] = int(_metrics["tex_hits"]) + 1
		return _tex_cache[key]
	var tex := _bake_tex(p_style, p_fill, p_t2, q)
	_tex_cache[key] = tex
	_metrics["tex_builds"] = int(_metrics["tex_builds"]) + 1
	return tex


static func _bake_tex(p_style: StringName, p_fill: Color, p_t2: bool,
		p_quality: int) -> ImageTexture:
	match p_style:
		STYLE_SPIRIT_SWORD:
			return _bake_spirit_sword(p_fill, p_t2, p_quality)
		STYLE_GROUND_AXE:
			return _bake_ground_axe(p_fill, p_t2, p_quality)
		STYLE_BOOMERANG:
			return _bake_boomerang(p_fill, p_t2, p_quality)
	# 未注册样式/身份兜底：32px 单层平涂刃形（不进分层装色——§2.2 豁免精神）
	return _bake_flat_blade(p_fill)


static func _bake_spirit_sword(p_fill: Color, p_t2: bool, p_q: int) -> ImageTexture:
	# W11 灵剑弹体（64px 朝上 -Y，flying_sword_weapon.gd:361-364 刃形同形拷贝；
	# 十字护手/短柄/尾珠结构位同形保留，取色自 fill 派生（同原 metal/grip 推导式））。
	# 层序（外→内）：外壳（档2）→ 藏青描边 → 白刃缘 → 亮核 → 过渡（芯深处）
	# → 内折射线（档2，刃脊）→ 护手/柄/尾珠（结构件，不参与降档）。
	var w := 64
	var h := 64
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var blade := PackedVector2Array([
		Vector2(0.0, -30.0), Vector2(1.4, -22.0), Vector2(2.6, -12.0),
		Vector2(2.0, 2.0), Vector2(-2.0, 2.0), Vector2(-2.6, -12.0), Vector2(-1.4, -22.0),
	])
	var shell := expand_poly(blade, SHELL_EXPAND)
	var bb_blade := _poly_bbox(blade)
	var bb_shell := _poly_bbox(shell)
	var c_shell := layer_color(p_fill, p_t2, p_q, 0)
	var c_trans := layer_color(p_fill, p_t2, p_q, 1)
	var c_core := layer_color(p_fill, p_t2, p_q, 2)
	var c_edge := layer_color(p_fill, p_t2, p_q, 3)
	var c_refract := layer_color(p_fill, p_t2, p_q, 4)
	var c_flat := layer_color(p_fill, p_t2, p_q, 5)
	var metal := Color.from_hsv(p_fill.h, maxf(p_fill.s, SAT_FLOOR), p_fill.v * 0.55)
	var grip := Color.from_hsv(p_fill.h, maxf(p_fill.s, SAT_FLOOR), p_fill.v * 0.38)
	var ink := PopPalette.OUTLINE
	for y in range(h):
		var py := float(y) + 0.5 - float(h) * 0.5
		for x in range(w):
			var px := float(x) + 0.5 - float(w) * 0.5
			# 结构件优先（护手/柄/尾珠——同原结构位，直排盒/圆距离）
			if _dist_circle(px, py, 0.0, 13.5, 1.5) <= 0.0:
				img.set_pixel(x, y, metal)
				continue
			if _dist_box(px, py, 0.0, 9.0, 1.6, 4.0, 0.5) <= 0.0:
				img.set_pixel(x, y, grip)
				continue
			if _dist_box(px, py, 0.0, 3.5, 5.5, 1.5, 0.5) <= 0.0:
				img.set_pixel(x, y, metal)
				continue
			var d_blade := _poly_dist(blade, px, py) if bb_blade.has_point(Vector2(px, py)) else 1e9
			if d_blade <= 0.0:
				# 修轮①评审 W11：深度常量按斧头 ~33px 宽刃调的（1.3/2.4/5.5），灵剑刃
				# 最宽仅 ±2.6px（最大深度 ≈2.6）——旧常量下亮核带（≥2.4）与档0 平涂带
				# 恒 0 像素、q0/q1 逐像素同带。细刃式收窄：描边 0.9 / 白缘至 1.8 /
				# 亮核（≥1.8 至 5.5）/ 过渡芯深；折射线补 depth 守卫（原中脊线吃白缘）。
				var depth := -d_blade
				if depth < 0.9:
					# R268：描边 RGB 向核色混 25% 保旧读感，α 保描边本体（OUTLINE a=1）——
					# 核层降透明后整色 lerp 会拖低描边 α 至 0.90 与白刃缘带撞带。
					var rim := ink.lerp(c_core, 0.25)
					rim.a = ink.a
					img.set_pixel(x, y, rim)                        # 藏青描边（亮底可读）
				elif depth < 1.8:
					img.set_pixel(x, y, c_edge)                    # 白刃缘
				elif p_q == 0:
					img.set_pixel(x, y, c_flat)                    # 档0 平涂
				elif depth < 5.5:
					img.set_pixel(x, y, c_core)                    # 亮核
				else:
					img.set_pixel(x, y, c_trans)                   # 过渡（芯深）
				if p_q >= 2 and depth >= 1.8 and absf(px) < 0.55 \
						and py < -1.0 and py > -23.0:
					img.set_pixel(x, y, c_refract)                 # 内折射线（刃脊·亮核区内）
				continue
			if p_q >= 2 and bb_shell.has_point(Vector2(px, py)) \
					and _poly_dist(shell, px, py) <= 0.0:
				img.set_pixel(x, y, c_shell)                       # 外壳半透
	return ImageTexture.create_from_image(img)


static func _bake_ground_axe(p_fill: Color, p_t2: bool, p_q: int) -> ImageTexture:
	# W12 裂地斧弹体（64px 朝上 -Y，ground_axe_weapon.gd:519-523 斧头弧刃同形拷贝；
	# 柄木褐为既定土岩主题色保持（§2.4 非目标——CRACK_BROWN 系不动））。
	var w := 64
	var h := 64
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var head := PackedVector2Array([
		Vector2(-16.5, -6.0), Vector2(-15.0, -17.0), Vector2(-7.0, -24.5),
		Vector2(4.0, -26.5), Vector2(14.0, -21.5), Vector2(17.0, -11.0),
		Vector2(16.0, -3.5), Vector2(9.5, -10.0), Vector2(0.0, -12.5), Vector2(-9.5, -11.0),
	])
	var shell := expand_poly(head, SHELL_EXPAND)
	var bb_head := _poly_bbox(head)
	var bb_shell := _poly_bbox(shell)
	var c_shell := layer_color(p_fill, p_t2, p_q, 0)
	var c_trans := layer_color(p_fill, p_t2, p_q, 1)
	var c_core := layer_color(p_fill, p_t2, p_q, 2)
	var c_edge := layer_color(p_fill, p_t2, p_q, 3)
	var c_refract := layer_color(p_fill, p_t2, p_q, 4)
	var c_flat := layer_color(p_fill, p_t2, p_q, 5)
	var brown := Color(0.45, 0.3, 0.18)     # 柄木褐（ground_axe_weapon.gd:510 同值——土岩主题）
	var deep := Color(0.22, 0.26, 0.36)
	var ink := PopPalette.OUTLINE
	for y in range(h):
		var py := float(y) + 0.5 - float(h) * 0.5
		for x in range(w):
			var px := float(x) + 0.5 - float(w) * 0.5
			if _dist_box(px, py, 0.0, 21.5, 3.8, 4.0, 1.0) <= 0.0:
				img.set_pixel(x, y, deep)
				continue
			if _dist_box(px, py, 0.0, 8.0, 2.8, 22.0, 1.2) <= 0.0:
				img.set_pixel(x, y, brown)
				continue
			var d_head := _poly_dist(head, px, py) if bb_head.has_point(Vector2(px, py)) else 1e9
			if d_head <= 0.0:
				var depth := -d_head
				if depth < 1.3:
					var rim := ink.lerp(c_core, 0.25)              # R268：α 保描边本体
					rim.a = ink.a
					img.set_pixel(x, y, rim)
				elif depth < 2.6:
					img.set_pixel(x, y, c_edge)
				elif p_q == 0:
					img.set_pixel(x, y, c_flat)
				elif depth < 6.0:
					img.set_pixel(x, y, c_core)
				else:
					img.set_pixel(x, y, c_trans)
				if p_q >= 2 and depth >= 2.6 and depth < 6.0 \
						and absf(px - py * 0.35) < 0.8 and py < -6.0:
					img.set_pixel(x, y, c_refract)                 # 内折射线（斜贯刃面）
				continue
			if _dist_box(px, py, -0.5, -4.5, 4.5, 2.4, 1.0) <= 0.0:
				img.set_pixel(x, y, deep)                          # 套环（结构位同原）
				continue
			if p_q >= 2 and bb_shell.has_point(Vector2(px, py)) \
					and _poly_dist(shell, px, py) <= 0.0:
				img.set_pixel(x, y, c_shell)
	return ImageTexture.create_from_image(img)


static func _bake_boomerang(p_fill: Color, p_t2: bool, p_q: int) -> ImageTexture:
	# W10 回旋刃弹体（44px，texture_factory.gd:1178-1179 双圆月牙 SDF 同形：
	# 外圆 (18,22) r15 − 偏心内圆 (13,22) r13.5；外壳 = 双圆外扩月牙带）。
	# 深度分带与灵剑同式（描边/白刃缘/亮核/过渡/折射线内缘）；KIN 金色路径
	# 不进此口（texture_factory.boomerang_tex 原配方零改动——§2.3 豁免）。
	var w := 44
	var h := 44
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var outer_c := Vector2(18.0, 22.0)
	var inner_c := Vector2(13.0, 22.0)
	var c_shell := layer_color(p_fill, p_t2, p_q, 0)
	var c_trans := layer_color(p_fill, p_t2, p_q, 1)
	var c_core := layer_color(p_fill, p_t2, p_q, 2)
	var c_edge := layer_color(p_fill, p_t2, p_q, 3)
	var c_refract := layer_color(p_fill, p_t2, p_q, 4)
	var c_flat := layer_color(p_fill, p_t2, p_q, 5)
	var ink := PopPalette.OUTLINE
	for y in range(h):
		var py := float(y) + 0.5 - float(h) * 0.5
		for x in range(w):
			var px := float(x) + 0.5 - float(w) * 0.5
			# 月牙双圆心为 0..44 画布系（texture_factory 同值拷贝）——中心系坐标换算
			var pc := Vector2(px + 22.0, py + 22.0)
			var d_out := pc.distance_to(outer_c) - 15.0
			var d_in := pc.distance_to(inner_c) - 13.5
			var sd := maxf(d_out, -d_in)
			if sd <= 0.0:
				var depth := -sd
				if depth < 1.3:
					var rim := ink.lerp(c_core, 0.25)              # R268：α 保描边本体
					rim.a = ink.a
					img.set_pixel(x, y, rim)                       # 藏青描边（原口径）
				elif depth < 2.4:
					img.set_pixel(x, y, c_edge)                    # 白刃缘（外缘）
				elif p_q == 0:
					img.set_pixel(x, y, c_flat)
				elif depth < 5.0:
					img.set_pixel(x, y, c_core)
				else:
					img.set_pixel(x, y, c_trans)
				# 修轮①评审 W10：原条件 d_in > -2.6 在月牙体内（d_in 恒 ≥0）恒真——
				# q2 整刃被 α0.55 折射色平涂洗掉（描边/白缘/亮核全不渲染，最高档
				# 低于中档）。改 d_in < 2.6 = 内缘 2.6px 亮带（刀体内才有意义——
				# 本分支已在 sd<=0 刃体内）。
				if p_q >= 2 and d_in < 2.6:
					img.set_pixel(x, y, c_refract)                 # 内折射线（内缘亮带）
				continue
			if p_q >= 2:
				var sd_shell := maxf(pc.distance_to(outer_c) - 17.8,
					-(pc.distance_to(inner_c) - 15.6))
				if sd_shell <= 0.0:
					img.set_pixel(x, y, c_shell)                   # 外壳半透月牙带
	return ImageTexture.create_from_image(img)


static func _bake_flat_blade(p_fill: Color) -> ImageTexture:
	# 身份/未注册样式兜底：32px 单层平涂刃形（§2.2 豁免——不进分层装色）
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	var blade := PackedVector2Array([
		Vector2(0.0, -14.0), Vector2(2.0, -4.0), Vector2(1.4, 8.0),
		Vector2(-1.4, 8.0), Vector2(-2.0, -4.0),
	])
	for y in range(32):
		var py := float(y) - 16.0
		for x in range(32):
			var px := float(x) - 16.0
			if _poly_dist(blade, px, py) <= 0.0:
				img.set_pixel(x, y, p_fill)
	return ImageTexture.create_from_image(img)


# ── 直排 SDF 辅助（与 texture_factory.gd:1999-2023 同式直排拷贝——负在内） ─────
static func _poly_bbox(p_pts: PackedVector2Array) -> Rect2:
	# 顶点表包围盒（烤图内核逐像素预检——画布大半像素在形外，先两次比较挡掉
	# 整轮逐边距离；实测 64px×多边形 12.8→<10ms 的关键步）
	var mn := Vector2(1e9, 1e9)
	var mx := Vector2(-1e9, -1e9)
	for pt in p_pts:
		mn = Vector2(minf(mn.x, pt.x), minf(mn.y, pt.y))
		mx = Vector2(maxf(mx.x, pt.x), maxf(mx.y, pt.y))
	return Rect2(mn, mx - mn).grow(1.0)


static func _poly_dist(p_pts: PackedVector2Array, p_x: float, p_y: float) -> float:
	# 多边形 SDF（texture_factory._poly_sd 同式：交叉计数 + 边最近距离；闭包改直调）
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


static func _dist_box(p_x: float, p_y: float, p_cx: float, p_cy: float,
		p_hx: float, p_hy: float, p_rad: float) -> float:
	# 圆角盒 SDF（texture_factory._sd_box 同式直排——中心平移版）
	var qx := absf(p_x - p_cx) - p_hx + p_rad
	var qy := absf(p_y - p_cy) - p_hy + p_rad
	return Vector2(maxf(qx, 0.0), maxf(qy, 0.0)).length() \
		+ minf(maxf(qx, qy), 0.0) - p_rad


static func _dist_circle(p_x: float, p_y: float, p_cx: float, p_cy: float,
		p_r: float) -> float:
	return sqrt((p_x - p_cx) * (p_x - p_cx) + (p_y - p_cy) * (p_y - p_cy)) - p_r


# ── 档位真源与预烤域 ─────────────────────────────────────────────────────
static func live_fx_quality() -> int:
	# 特效档真源（arc_slash._fx_quality :557-562 / elemental_fx_layer 同口径镜像：
	# 钳 [0,2] + mobile 降 1 档）。经 root 查找调 settings——不走编译期 autoload
	# 标识（-s 直跑双文件先例的编译期约束同守）；Meta 缺席回落高档 2（只影响
	# 视觉层缺省，不影响任何确定性路径）。
	var q := 2
	var ml := Engine.get_main_loop() as SceneTree
	if ml != null and ml.root != null:
		var meta: Node = ml.root.get_node_or_null("Meta")
		if meta != null and meta.has_method("settings"):
			q = clampi(int(meta.call("settings", "fx_quality")), 0, 2)
	if OS.has_feature("mobile"):
		q = mini(q, 1)
	return q


static func prewarm_default_domain() -> int:
	# R267 §2.5-5：缺省色域预烤（三弹体样式 × 七元素表色 × 档2，21 键）——
	# 供 texture_factory.prewarm_shared 登记；首击元素弹体零冷 miss（§2.6 微基准
	# 「prewarm 预烤后首击零冷 miss」计数断言的烤源）。KIN 白在豁免域不烤。
	var built := 0
	for e in PopPalette.ELEMENT_COLORS.keys():
		var fill: Color = PopPalette.ELEMENT_COLORS[e]
		if int(e) == 0 or is_identity_fill(fill):
			continue
		for style in [STYLE_SPIRIT_SWORD, STYLE_GROUND_AXE, STYLE_BOOMERANG]:
			crystal_tex(style, fill, false, 2)
			built += 1
	return built


# ── 图标水晶版辅助（c′ 防混搭——六 id 图标壳层 + 构建标记） ───────────────────
static func icon_shell_color(p_fill: Color) -> Color:
	# 图标水晶外壳层色（身份色**未钳**——图标非元素染色路径，§2.2 钳制仅限
	# 元素配方的延伸口径；W13 黑金/W12 岩钢图标身份不被洗）
	return Color(p_fill.r, p_fill.g, p_fill.b, ICON_SHELL_ALPHA)


static func crystal_outline_color() -> Color:
	# 修轮①评审：即时形态水晶刀全轮廓描边（PopPalette.OUTLINE #22254a α0.65——
	# ICE/ANE 淡元素过渡层合成到亮底 BG#eef3ff 上亮度差仅 ~8% 近隐形，旧 darkened
	# 剪影对比拆除后须有替代；与烘焙态藏青描边风格对齐——palette.gd 单源教义）。
	var c := PopPalette.OUTLINE
	c.a = 0.65
	return c


static func note_icon_built(p_style: StringName) -> void:
	# c′ 机制标记：六图标站点水晶版构建计数（headless 无像素判读时的命中证据）
	_icon_builds[String(p_style)] = int(_icon_builds.get(String(p_style), 0)) + 1


static func icon_build_count(p_style: StringName) -> int:
	return int(_icon_builds.get(String(p_style), 0))


static func metrics() -> Dictionary:
	# 构建命中计数读回口（§2.6-c/g 断言判读源——只读快照）
	return _metrics.duplicate()


static func tex_cache_size() -> int:
	return _tex_cache.size()

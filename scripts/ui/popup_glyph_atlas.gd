# scripts/ui/popup_glyph_atlas.gd
# R225 渲染首刀·跳字位图化：伤害数字字形共享图集（mobile 位图门专用，桌面 Label 路径零扰动）。
# 背景：深载满载时跳字是渲染 dc 大头（Label 文本+描边逐跳多 draw call）。本模块把跳字
# 数值臂的**真实字形集**烤成一张共享 ImageTexture，每张跳字 = 共享图集的 Sprite2D 序列
# ——全部跳字同贴图同材质 → 渲染端天然合并 draw call（同贴图同桶语义）。
#
# 字形审计（与 DamagePopup 文本口径逐分支核对，damage_popup.gd _refresh_label）：
#   · 数值臂文本 = str(int(round(v))) / str(ceili(v))——纯 0-9 十字形；merged_value =
#     maxf(p_value, 0.0) 累加恒非负 → 无负号；str 无千分位 → 无万/亿缩写；CRIT 无文字
#     标记（表现 = 字号 30→40 升格 + 色变，非文本）。HEAL/XP/DOT/CHARGE_BURST 全走数字臂。
#   · IMMUNE 臂文案 =「免疫」（两个 CJK 字形，一并入集）。
#   · REACTION 臂（反应名+数值大字「碎裂1284」/ 文字标签「超导-30%」——20 反应名 × 双色
#     × 3 字型 + 统计段符号 -+% .s 层）本刀**不烘焙**：mobile 上保留既有 Label 路径
#     （低频必显通道；图集预算另判，披露为刀面豁免）。
#
# 烤法（TextureFactory 缓存键先例 + R216 碎片烤色变体先例）：
#   TextServer.font_get_glyph_contours（4.3 CPU 侧字形轮廓，headless 实测可用）→
#   二次贝塞尔细分折线 → 扫描线 even-odd inside + 逐边影响盒
#   距离场 → 双通道掩码图集（R = 填充掩码 / G = 描边掩码）。白填充 × sprite modulate
#   （= 元素色/量级色 tint）+ 描边恒藏青（shader uniform 单源 PopPalette.OUTLINE）——
#   描边预烤进图集，读感与 Label 藏青描边一致（元素色只染填充不染描边，零视觉口径变更）。
# 合批：全跳字共享同一图集 texture + 同一 ShaderMaterial 实例 → 同状态 canvas item
# 自动合批；R214 树序分桶（reparent）不适用也不需要——popup 池本就同纹理。
# 预热：逐字形 cell 挂 GameLoop._tex_prewarm_queue（op:6；R215 菜单挂机门 / R216 逐项
# 拆粒先例）——战斗期零烤图红线。ready() 前 bitmap 门自动回退 Label 路径（开局早预热
# 未消化完 = 表现不劣化于现状，先例口径同 R215）。R227：cell 前移队首（整套 12 cell
# 实测 ~42ms → 菜单停留 ~0.3s 即就绪）+ 新局入口 ensure_runstart_bake 结构化兜底
# （vc32 全轮 位图R=0 实证：原队列位+仅 MENU 消化使真实玩家永远等不到激活）。
class_name PopupGlyphAtlas
extends RefCounted

const BAKED_PX := 64                 # 烘焙字号（显示 30px = 2.13× / CRIT 40px = 1.6× 超采样，下采样锐利）
const CELL := 112                    # cell 边长（CJK bbox+描边 pad 余量：~92px 贴边可容）
const COLS := 4                      # 图集列数（12 字形 → 4×3）
const SUBDIV := 6                    # 二次贝塞尔每段细分折线数（圆弧平滑度/点数折中）
const OUTLINE_PX_AT_BASE := 8.0      # Label OUTLINE_PX（30px 基准）等比换算源
const BASE_FONT_PX := 30.0           # 既有常规字号（描边等比基准）
const GLYPHS := "0123456789免疫"     # 数值臂真实字形集（审计见文件头；只增不改）

static var _img: Image = null                  # 图集画布（首 cell 烤时分配）
static var _tex: ImageTexture = null           # 成品图集（全部 cell 烤完一次性上传）
static var _cell_done: Array[bool] = []        # 逐 cell 完成标记（分帧幂等）
static var _meta: Array[Dictionary] = []       # 逐字形排版元数据（code/rect/adv/cx_off）
static var _by_code: Dictionary = {}           # code → meta（热路径 O(1)——每字形刷新查表）
static var _flattened: Array = []              # 逐字形细分折线（bbox 本地图像坐标，烤时消费）
static var _mat: ShaderMaterial = null         # 共享材质（全跳字单实例——合批前提）
static var _layout_done: bool = false

const SHADER_CODE := "
shader_type canvas_item;
uniform vec4 outline_col : source_color = vec4(0.133333, 0.145098, 0.290196, 1.0);
void fragment() {
	vec2 m = texture(TEXTURE, UV).rg;
	float fa = m.r * COLOR.a;
	float oa = m.g * COLOR.a * (1.0 - m.r);
	float a = fa + oa;
	vec3 rgb = a > 0.0001 ? (COLOR.rgb * fa + outline_col.rgb * oa) / a : vec3(0.0);
	COLOR = vec4(rgb, a);
}
"


static func ready() -> bool:
	# 位图门就绪判定：全部字形烤完（未就绪 = bitmap 门回退 Label 路径）
	return _tex != null


static func glyph_texture() -> ImageTexture:
	return _tex


static func glyph_material() -> ShaderMaterial:
	# 共享 ShaderMaterial（懒建单例）：R/G 双通道掩码 → 填充×tint（modulate 链）+ 描边恒
	# 藏青（uniform 单源 PopPalette.OUTLINE）。同材质同纹理是合批前提，禁 per-sprite 实例化。
	if _mat == null:
		var sh := Shader.new()
		sh.code = SHADER_CODE
		_mat = ShaderMaterial.new()
		_mat.shader = sh
		_mat.set_shader_parameter("outline_col", PopPalette.OUTLINE)
	return _mat


static func glyph_meta(p_code: int) -> Dictionary:
	# 排版元数据：{code, rect(图集坐标), adv(advance px), cx_off(bbox 中心相对排版原点 x)}
	return _by_code.get(p_code, {})


static func glyph_count() -> int:
	return GLYPHS.length()


static func glyph_code_at(p_index: int) -> int:
	# 索引 → 码点（测试反查：sprite region_rect → cell 索引 → 字形解码）
	if p_index < 0 or p_index >= GLYPHS.length():
		return 0
	return GLYPHS.unicode_at(p_index)


static func built_count() -> int:
	# 测试/诊断观测：已完成 cell 数
	return _cell_done.count(true)


static func build_all() -> void:
	# 同步整图集口（测试/诊断；产品路径走 build_cell 逐项分帧——R215 拆粒先例）
	for i in range(GLYPHS.length()):
		build_cell(i)


# ── R267 刀P1：layout 单列通道 + 观测口（设计 §1.1 处方 3/4）──────────
# 模态开帧（祝福弹层）同步做掉 layout + 未烤 cell——出发帧 ensure 恒短路（常态档
# ≤8ms）；模态缺席（祝福池空直达）走 start_run 兜底档（≤30ms 分档落账）。
# 与设计「layout+前 ≤4 cell」的偏差：确认即 _finish_menu_start 直达 start_run，
# 模态后无 MENU 泵窗口（R260 模态期 tex 泵挂起）——剩 8 cell 仍落出发帧（12-25ms
# >8ms 门）。故模态暖全量（layout+全部未烤 ≈42ms 一次性菜单过渡帧，量级同设计
# 35ms 估计；总功不变，整体挪出出发帧）。桌面自动门恒关 → 本口零扰动。

static func layout_done() -> bool:
	# 观测口：一次性 layout（≈23.7ms——首 cell 内隐成本）是否已做
	return _layout_done


static func unbaked_cells() -> int:
	# 观测口：未烤 cell 数（ready() 前的分档判读源）
	return GLYPHS.length() - built_count()


static func ensure_layout() -> void:
	# 单列口：只做 layout 不烤 cell（幂等；测试/诊断）
	_ensure_layout()


static func warm_runstart_cells() -> int:
	# R267 刀P1 模态暖口：门开着且未就绪 → layout + 全部未烤 cell（一次性，幂等——
	# 就绪/门关零成本直返）。返回本次烤制 cell 数；耗时入 bitmap_modal_warm_us
	# （与 bitmap_bake_us〔ensure 兜底档〕分档落账——验收 b 判读源）。
	if ready() or not runstart_gate():
		return 0
	var t0 := Time.get_ticks_usec()
	var n0 := built_count()
	_ensure_layout()
	for i in range(GLYPHS.length()):
		build_cell(i)
	DebugStats.count(&"bitmap_modal_warm_us", int(Time.get_ticks_usec() - t0))
	return built_count() - n0


# R227 新局补烤覆写口（先例 bitmap_override 同款 static 口径）：-1=平台自动
#（mobile=补 / 桌面=不补）；0=强制不补；1=强制补（headless 真链测）。用毕复位 -1。
static var runstart_bake_override: int = -1


static func runstart_gate() -> bool:
	# 新局补烤门真源：override 优先；平台自动 = mobile（桌面 bitmap 门恒 Label，
	# 补了也无消费方——桌面零扰动保持）
	if runstart_bake_override >= 0:
		return runstart_bake_override == 1
	return OS.has_feature("mobile")


static func ensure_runstart_bake() -> bool:
	# R227 激活结构化保证：新局入口（start_run/restart_run/continue_run/continue_endless，
	# notify_new_run 同址）未就绪则一次性烤完剩余 cell。全量实测 ~42ms（首 cell 含
	# 一次性布局 23.7ms、余 1-2.7ms；headless 口径——真机量级待 vc33 补N 首读校准）
	# ≈开局既有首帧尖峰的零头；战斗期零烤图红线不破——只在局切换帧执行，非战斗帧。
	# 返回是否本口执行了补烤（diag 补N 源）；bitmap_ensure_calls 计挂点覆盖（评审 L3）。
	DebugStats.count(&"bitmap_ensure_calls")
	if ready():
		return false
	if not runstart_gate():
		return false
	var t0 := Time.get_ticks_usec()
	build_all()
	DebugStats.count(&"bitmap_bake_us", int(Time.get_ticks_usec() - t0))
	return true


static func build_cell(p_index: int) -> void:
	# 烤第 p_index 个字形 cell（GameLoop 菜单预热 op:6 消费；幂等——重复入队零成本）
	if p_index < 0 or p_index >= GLYPHS.length():
		return
	_ensure_layout()
	if _cell_done[p_index]:
		return
	if _img == null:
		_img = Image.create(COLS * CELL, _rows() * CELL, false, Image.FORMAT_RGB8)
	var m: Dictionary = _meta[p_index]
	var rect: Rect2 = m["rect"]
	var polys: Array = _flattened[p_index]
	var w := int(rect.size.x)
	var h := int(rect.size.y)
	var inside := _scan_inside(polys, w, h)
	var reach := _outline_px() + 2.0                 # 边界带半径（带外饱和，带内精确）
	var dist := _dist_field(polys, w, h, reach)
	var ow := _outline_px()
	var ox := int(rect.position.x)
	var oy := int(rect.position.y)
	for y in range(h):
		for x in range(w):
			var d := dist[y * w + x]
			var sd := -d if inside[y * w + x] == 1 else d
			var fill := clampf(0.5 - sd, 0.0, 1.0)
			var edge := clampf(0.5 - sd + ow, 0.0, 1.0) - fill
			_img.set_pixel(ox + x, oy + y, Color(fill, edge, 0.0))
	_cell_done[p_index] = true
	if built_count() == GLYPHS.length():
		_tex = ImageTexture.create_from_image(_img)   # 全量完成一次性上传（战斗期零烤图）
		_img = null                                   # 释放 CPU 侧画布


# ── 布局 ──────────────────────────────────────────────────────────
static func _rows() -> int:
	return int(ceil(float(GLYPHS.length()) / float(COLS)))


static func _outline_px() -> float:
	# 描边等比换算：Label 8px@30px → BAKED_PX 字号下等比（显示侧再随 sprite scale 缩放）
	return OUTLINE_PX_AT_BASE * float(BAKED_PX) / BASE_FONT_PX


static func _ensure_layout() -> void:
	if _layout_done:
		return
	_layout_done = true
	var font := StickerTheme.font()
	var ts: TextServer = TextServerManager.get_primary_interface()
	var rids: Array = font.get_rids()
	var ascent := font.get_ascent(BAKED_PX)
	for i in range(GLYPHS.length()):
		var code := GLYPHS.unicode_at(i)
		var pts := _flatten_glyph(ts, rids, code)
		# 字体坐标（y 向上）→ 图像坐标：iy = ascent − y（基线对齐），原点 = pen
		var minv := Vector2(INF, INF)
		var maxv := Vector2(-INF, -INF)
		var imgs: Array = []
		for poly: PackedVector2Array in pts:
			var out := PackedVector2Array()
			out.resize(poly.size())
			for k in range(poly.size()):
				out[k] = Vector2(poly[k].x, ascent - poly[k].y)
				minv = minv.min(out[k])
				maxv = maxv.max(out[k])
			imgs.append(out)
		var pad := _outline_px() + 2.0               # 描边外扩 + AA 留白（图集渗色隔离）
		var bw := ceilf(maxv.x - minv.x + pad * 2.0)
		var bh := ceilf(maxv.y - minv.y + pad * 2.0)
		var col := i % COLS
		var row := i / COLS
		var rect := Rect2(float(col * CELL) + (float(CELL) - bw) * 0.5,
			float(row * CELL) + (float(CELL) - bh) * 0.5, bw, bh)
		# 折线平移进 bbox 本地（含 pad 居中）
		var locals: Array = []
		for poly: PackedVector2Array in imgs:
			var off := rect.position + Vector2(pad, pad) - minv
			var out := PackedVector2Array()
			out.resize(poly.size())
			for k in range(poly.size()):
				out[k] = poly[k] + off
			locals.append(out)
		var m := {
			"code": code,
			"rect": rect,
			"adv": font.get_string_size(String.chr(code), HORIZONTAL_ALIGNMENT_LEFT,
				-1, BAKED_PX).x,
			"cx_off": minv.x + (maxv.x - minv.x) * 0.5,   # bbox 中心相对 pen（lsb + 半宽）
		}
		_meta.append(m)
		_by_code[code] = m
		_flattened.append(locals)
	_cell_done.resize(GLYPHS.length())
	_cell_done.fill(false)


static func _flatten_glyph(p_ts: TextServer, p_rids: Array, p_code: int) -> Array:
	# 取字形轮廓并细分二次贝塞尔（TrueType on/off 曲线点：z≥0.5 = on_curve）——
	# fallback 链逐 RID 找首个含此字形的字体（探针实测 Windows 雅黑单 RID 直命中）
	for rid_v: RID in p_rids:
		var gi: int = p_ts.font_get_glyph_index(rid_v, BAKED_PX, p_code, 0)
		if gi == 0:
			continue
		var data: Dictionary = p_ts.font_get_glyph_contours(rid_v, BAKED_PX, gi)
		var points: PackedVector3Array = data.get("points", PackedVector3Array())
		var ends: PackedInt32Array = data.get("contours", PackedInt32Array())
		if points.is_empty() or ends.is_empty():
			continue
		var polys: Array = []
		var start := 0
		for e in range(ends.size()):
			polys.append(_flatten_contour(points, start, int(ends[e])))
			start = int(ends[e]) + 1
		return polys
	push_error("[PopupGlyphAtlas] 字形轮廓缺失 code=%d（字体链无此字形）" % p_code)
	return []


static func _flatten_contour(p_points: PackedVector3Array, p_start: int, p_end: int) -> PackedVector2Array:
	# 单轮廓 [p_start, p_end]（闭区间，闭合多边形）→ 细分折线：
	# on-off-on = 二次贝塞尔细分；连续 off = 隐式 on（中点，TrueType 规范）
	var n := p_end - p_start + 1
	if n <= 0:
		return PackedVector2Array()
	var out := PackedVector2Array()
	var first := Vector2(p_points[p_start].x, p_points[p_start].y)
	out.append(first)
	var prev := first
	var pending := Vector2(INF, INF)             # 待消费控制点（INF = 无）
	for k in range(1, n + 1):
		var p3 := p_points[p_start + (k % n)]    # 末点回绕首点（闭合）
		var p := Vector2(p3.x, p3.y)
		if p3.z >= 0.5:
			if pending.x != INF:
				_quad_subdiv(prev, pending, p, out)
				pending = Vector2(INF, INF)
			else:
				out.append(p)
			prev = p
		elif pending.x != INF:
			var mid := (pending + p) * 0.5       # 连续控制点：隐式 on
			_quad_subdiv(prev, pending, mid, out)
			prev = mid
			pending = p
		else:
			pending = p
	if pending.x != INF:
		_quad_subdiv(prev, pending, out[0], out)  # 末点 off 收尾回绕首 on
	return out


static func _quad_subdiv(p_a: Vector2, p_c: Vector2, p_b: Vector2, p_out: PackedVector2Array) -> void:
	# 二次贝塞尔 a-c-b 细分 SUBDIV 段折线
	for k in range(1, SUBDIV + 1):
		var t := float(k) / float(SUBDIV)
		var it := 1.0 - t
		p_out.append(it * it * p_a + 2.0 * it * t * p_c + t * t * p_b)


# ── 光栅化内核（even-odd 掩码 + 逐边影响盒距离场——像素成本 ∝ 边界带，非全画布） ──
static func _scan_inside(p_polys: Array, p_w: int, p_h: int) -> PackedByteArray:
	# 扫描线 even-odd inside（多轮廓带洞天然正确——'0' 外圈+内洞 / CJK 部件）
	var inside := PackedByteArray()
	inside.resize(p_w * p_h)
	for j in range(p_h):
		var sy := float(j) + 0.5
		var xs := PackedFloat32Array()
		for poly_v: PackedVector2Array in p_polys:
			var n := poly_v.size()
			for i in range(n):
				var a := poly_v[i]
				var b := poly_v[(i + 1) % n]
				if (a.y > sy) != (b.y > sy):
					xs.append(a.x + (sy - a.y) / (b.y - a.y) * (b.x - a.x))
		if xs.size() < 2:
			continue
		xs.sort()
		var k := 0
		while k + 1 < xs.size():
			var x0 := maxi(int(floor(xs[k])), 0)
			var x1 := mini(int(ceil(xs[k + 1])), p_w)
			for x in range(x0, x1):
				if inside[j * p_w + x] == 0 and float(x) + 0.5 > xs[k] \
						and float(x) + 0.5 < xs[k + 1]:
					inside[j * p_w + x] = 1
			k += 2
	return inside


static func _dist_field(p_polys: Array, p_w: int, p_h: int, p_reach: float) -> PackedFloat32Array:
	# 逐边影响盒 min 距离场（reach 外不精确——由饱和 clamp + inside 符号兜底正确）
	var dist := PackedFloat32Array()
	dist.resize(p_w * p_h)
	dist.fill(1e9)
	for poly_v: PackedVector2Array in p_polys:
		var n := poly_v.size()
		for i in range(n):
			var a := poly_v[i]
			var b := poly_v[(i + 1) % n]
			var x0 := maxi(int(floor(minf(a.x, b.x) - p_reach)), 0)
			var x1 := mini(int(ceil(maxf(a.x, b.x) + p_reach)), p_w)
			var y0 := maxi(int(floor(minf(a.y, b.y) - p_reach)), 0)
			var y1 := mini(int(ceil(maxf(a.y, b.y) + p_reach)), p_h)
			if x0 >= x1 or y0 >= y1:
				continue
			var ab := b - a
			var ab2 := maxf(ab.length_squared(), 0.0001)
			for y in range(y0, y1):
				var py := float(y) + 0.5
				var row := y * p_w
				for x in range(x0, x1):
					var rel := Vector2(float(x) + 0.5, py) - a
					var t := clampf(rel.dot(ab) / ab2, 0.0, 1.0)
					var d := (rel - ab * t).length()
					var idx := row + x
					if d < dist[idx]:
						dist[idx] = d
	return dist

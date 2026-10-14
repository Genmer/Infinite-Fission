# tests/qa_r268_transparent_cases.gd — R268：透明基准校准 + 匕首感修复用例体。
# 五契约面（任务书门禁契约一字不差）：t=α 带断言 / u=棕判据 0/8 复验 / v=KIN 豁免逐位 /
# w=匕首感几何断言 / x=缓存零重建；另收虚影锚锁定（arc_slash ga 表/轮廓乘式防漂移）。
# 判读口径：无像素判读处断生成器数据面与源面；headless _draw 会执行（r267 g 用例复证），
# x 用例据此做真绘制帧验证。零全局 rng（全部确定性注入）。
extends RefCounted

const FACTORY_PATH := "res://scripts/combat/weapon/melee/crystal_blade_factory.gd"
const ORBIT_PATH := "res://scripts/combat/weapon/melee/orbit_field.gd"
const ARC_PATH := "res://scripts/combat/weapon/melee/arc_slash.gd"
const W8_TRES_PATH := "res://resources/weapons/W8_orbit_field.tres"

var _pass := 0
var _fail := 0


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_ok: bool, p_detail: String = "") -> void:
	if p_ok:
		_pass += 1
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		print("  FAIL | %s（%s）" % [p_name, p_detail])


# ── 棕判据（r267 同式：h∈[0.02,0.16] ∧ s≥0.35 ∧ v≤0.62） ─────────────────────
func _is_brown(p_c: Color) -> bool:
	return p_c.h >= 0.02 and p_c.h <= 0.16 and p_c.s >= 0.35 and p_c.v <= 0.62


# ── α 带像素计数（r267 同式：8bit 量化步 ≈0.0039——tol 0.008 可分 0.55/0.60 与
#    0.90/1.00 相邻带，R268 迁后对带口径） ─────────────────────────────────────
func _band_count(p_img: Image, p_target: float, p_tol := 0.008) -> int:
	var n := 0
	for y in range(p_img.get_height()):
		for x in range(p_img.get_width()):
			var a: float = p_img.get_pixel(x, y).a
			if absf(a - p_target) <= p_tol:
				n += 1
	return n


# ── 元素武器桩（r267 同式：生产 weapon_base + trait_stack + ELEM 词条直装） ──
func _make_elem_weapon(p_pool: Array) -> Node:
	var wb: Node = load("res://scripts/combat/weapon/weapon_base.gd").new()
	var ts: RefCounted = load("res://scripts/combat/trait/trait_stack.gd").new()
	var td_script: GDScript = load("res://scripts/core/data/resources/trait_data.gd")
	var tb_script: GDScript = load("res://scripts/combat/trait/trait_base.gd")
	for e in p_pool:
		var td: Resource = td_script.new()
		td.set("pool", 4)                      # PoolClass.ELEM（game_const.gd:13）
		td.set("params", {"element": int(e)})
		var tb: RefCounted = tb_script.new()
		tb.set("data", td)
		tb.set("layers", 1)
		(ts.get("traits") as Array).append(tb)
	wb.set("trait_stack", ts)
	return wb


func _free_weapon(p_wb: Node) -> void:
	if p_wb != null and is_instance_valid(p_wb):
		p_wb.free()


# ══ 契约面 t：α 带断言（V2 迁移后钉值抽检 + 真透明常量契约） ═════════════════
func _case_t_alpha_bands() -> void:
	print("── t) R268：α 带断言（层 α 单源 + 真透明契约 + q2/q1/q0 带像素抽检） ──")
	var fire: Color = PopPalette.ELEMENT_COLORS[GameConst.Element.FIR]
	# t-1 层 α 单源常量（在途 α 基准 v1 定版——壳 0.18/过渡 0.32/核 0.60/缘 0.9/
	# 平涂 0.50，crystal_blade_factory.gd:43-48；折射 0.55）
	var got := [
		CrystalBladeFactory.layer_color(fire, false, 2, 0).a,
		CrystalBladeFactory.layer_color(fire, false, 2, 1).a,
		CrystalBladeFactory.layer_color(fire, false, 2, 2).a,
		CrystalBladeFactory.layer_color(fire, false, 2, 3).a,
		CrystalBladeFactory.layer_color(fire, false, 0, 5).a,
	]
	var want := [CrystalBladeFactory.ALPHA_SHELL, CrystalBladeFactory.ALPHA_TRANSITION,
		CrystalBladeFactory.ALPHA_CORE, CrystalBladeFactory.ALPHA_EDGE,
		CrystalBladeFactory.ALPHA_FLAT]
	var alpha_ok := true
	var alpha_detail := ""
	for i in range(got.size()):
		if absf(got[i] - want[i]) > 0.001:
			alpha_ok = false
			alpha_detail += "层%d got=%.3f want=%.3f " % [i, got[i], want[i]]
	var vals_ok := absf(CrystalBladeFactory.ALPHA_SHELL - 0.18) < 0.001 \
		and absf(CrystalBladeFactory.ALPHA_TRANSITION - 0.32) < 0.001 \
		and absf(CrystalBladeFactory.ALPHA_CORE - 0.60) < 0.001 \
		and absf(CrystalBladeFactory.ALPHA_FLAT - 0.50) < 0.001 \
		and absf(CrystalBladeFactory.ALPHA_REFRACT - 0.55) < 0.001
	_check("t-1 层 α 单源 + v1 基准值（壳0.18/过渡0.32/核0.60/缘0.9/平涂0.50/折射0.55）",
		alpha_ok and vals_ok, alpha_detail)
	# t-2 真透明契约（b-5 同式：主体 α≤0.70 且层序单调；SAT_FLOOR/CORE_V_MIN 棕
	# 防线常量零动旁证）
	_check("t-2 真透明契约（核 ≤0.70 ∧ 平涂 ≤0.60 ∧ 壳<过渡<核）+ 棕防线零动"
			+ "（SAT_FLOOR 0.55/CORE_V_MIN 0.75/SHELL_EXPAND 1.32）",
		CrystalBladeFactory.ALPHA_CORE <= 0.70
		and CrystalBladeFactory.ALPHA_FLAT <= 0.60
		and CrystalBladeFactory.ALPHA_SHELL < CrystalBladeFactory.ALPHA_TRANSITION
		and CrystalBladeFactory.ALPHA_TRANSITION < CrystalBladeFactory.ALPHA_CORE
		and absf(CrystalBladeFactory.SAT_FLOOR - 0.55) < 0.001
		and absf(CrystalBladeFactory.CORE_V_MIN - 0.75) < 0.001
		and absf(CrystalBladeFactory.SHELL_EXPAND - 1.32) < 0.001)
	# t-3 W10 q2 五带像素抽检（判据 = 探针 r268_ghost_band_probe_run.log 落档值
	# 174/120/54/34/22；阈值 ≥100/50/30/20/10 零改）
	var boom_q2: Image = CrystalBladeFactory.crystal_tex(&"boomerang", fire, false, 2).get_image()
	var b_shell := _band_count(boom_q2, 0.18, 0.012)
	var b_refract := _band_count(boom_q2, 0.55)
	var b_rim := _band_count(boom_q2, 1.0)
	var b_edge := _band_count(boom_q2, 0.90)
	var b_core := _band_count(boom_q2, 0.60)
	_check("t-3 q2 五带齐全（壳 %d/折射 %d/描边 %d/白缘 %d/亮核 %d ≥100/50/30/20/10）"
			% [b_shell, b_refract, b_rim, b_edge, b_core],
		b_shell >= 100 and b_refract >= 50 and b_rim >= 30 and b_edge >= 20 and b_core >= 10)
	# t-4 折射带占刃体 <70%（W10b 派生门抽检——旧 bug 特征 = 100%）
	var blade_px := b_refract + b_rim + b_edge + b_core
	_check("t-4 折射带占刃体 <70%%（折射 %d / 刃体 %d）" % [b_refract, blade_px],
		b_refract * 10 < blade_px * 7)
	# t-5 W11 深度带抽检（q1 亮核 0.60 / q0 平涂 0.50 且互异 / q2 白缘 0.90——
	# 探针落档 18/18/42）
	var sw_q1: Image = CrystalBladeFactory.crystal_tex(&"spirit_sword", fire, false, 1).get_image()
	var sw_q0: Image = CrystalBladeFactory.crystal_tex(&"spirit_sword", fire, false, 0).get_image()
	var sw_q2: Image = CrystalBladeFactory.crystal_tex(&"spirit_sword", fire, false, 2).get_image()
	_check("t-5 W11 带（q1 亮核 %d / q0 平涂 %d ∧ q0≠q1 / q2 白缘 %d ≥10/10/30）" % [
			_band_count(sw_q1, 0.60), _band_count(sw_q0, 0.50),
			_band_count(sw_q2, 0.90)],
		_band_count(sw_q1, 0.60) >= 10 and _band_count(sw_q0, 0.50) >= 10
		and sw_q0.get_data() != sw_q1.get_data() and _band_count(sw_q2, 0.90) >= 30)
	# t-6 即时形态核区等效 α = 1−(1−壳)(1−核) = 0.672 ≈ 虚影轮廓档 0.646（设计
	# §3.2①「配方最实区域」同值域——用户 C 校准处方的代数复核）
	var core_eq := 1.0 - (1.0 - CrystalBladeFactory.ALPHA_SHELL) \
		* (1.0 - CrystalBladeFactory.ALPHA_CORE)
	_check("t-6 即时核区等效 α %.3f ≈ 虚影轮廓档 0.646（|Δ|<0.03 同值域）" % core_eq,
		absf(core_eq - 0.646) < 0.03)
	# t-7 虚影锚锁定（arc_slash.gd:518-519 防漂移——ga 表 [0.34,0.16] + 轮廓乘式
	# minf(ga×1.9,0.7) + 填充 RGB(0.62,0.85,1.0) 源面逐串锁定）
	var arc_src := FileAccess.get_file_as_string(ARC_PATH)
	_check("t-7 虚影锚源面锁定（ga=[0.34,0.16] ∧ 轮廓 minf(ga×1.9,0.7) ∧ 填充 RGB）",
		arc_src.find("[0.34, 0.16][k]") >= 0
		and arc_src.find("minf(ga * 1.9, 0.7)") >= 0
		and arc_src.find("Color(0.62, 0.85, 1.0, ga)") >= 0)


# ══ 契约面 u：棕判据 0/8 复验（暖池全采样——R268 α 迁移后棕防线不回潮） ══════
func _case_u_brown_recheck() -> void:
	print("── u) R268：棕判据 0/8 复验（六暖池 × 三式 × 两态 × 三档 = 棒命中恒 0） ──")
	var warm_pools: Array = [
		[GameConst.Element.FIR],
		[GameConst.Element.FIR, GameConst.Element.GEO],
		[GameConst.Element.FIR, GameConst.Element.GEO, GameConst.Element.DEN],
		[GameConst.Element.FIR, GameConst.Element.DEN],
		[GameConst.Element.GEO, GameConst.Element.DEN],
		[GameConst.Element.FIR, GameConst.Element.ICE],
	]
	# u-1 判据自证：旧配方（darkened/lightened 梯度）暖池确有棕档——判据有效性套内自证
	var self_proof := false
	for pool in warm_pools:
		var wb: Node = _make_elem_weapon(pool)
		var blend: Color = wb.call("blend_element_color")
		for stop in [blend.darkened(0.45), blend.darkened(0.30), blend.lightened(0.10),
				blend.lightened(0.45), blend.lightened(0.70), blend.lightened(0.45),
				blend.lightened(0.25), blend.darkened(0.20)]:
			if _is_brown(stop):
				self_proof = true
		_free_weapon(wb)
	_check("u-1 判据自证：暖池旧配方梯度存在棕档（≥1 处）", self_proof)
	# u-2 新配方全采样 0/8（saber/greatsword/wolf × t2 × q0-2——α 迁移只动 α 位，
	# 色相/明度侧棕链不可达）
	var all_zero := true
	var detail := ""
	for pool in warm_pools:
		var wb2: Node = _make_elem_weapon(pool)
		var slash: Node = load(ARC_PATH).new()
		slash.set("weapon", wb2)
		slash.set("_tint_gen", -1)
		var tint: Color = slash.call("_live_blade_tint")
		for style in [&"saber", &"greatsword", &"wolf"]:
			for t2 in [false, true]:
				for q in [0, 1, 2]:
					var cols: PackedColorArray = CrystalBladeFactory.crystal_cols(
						style, tint, t2, q, CrystalBladeFactory.LAYER_BODY)
					var browns := 0
					for c in cols:
						if _is_brown(c):
							browns += 1
					if browns > 0:
						all_zero = false
						detail = "池%s %s t2=%s q=%d 棕 %d" % [str(pool), String(style),
							str(t2), q, browns]
		_free_weapon(wb2)
		slash.free()
	_check("u-2 六暖池 × 三式 × 两态 × 三档：水晶输出棕命中 0", all_zero, detail)


# ══ 契约面 v：KIN 豁免逐位（身份路径零偏移 + 冻结线源面锁定） ═══════════════
func _case_v_kin_exempt() -> void:
	print("── v) R268：KIN 豁免逐位（身份表命中/RGB 逐位零偏移/冻结线未触） ──")
	var identities: Array = [ArcSlash.SABER_TINT, ArcSlash.GREATSWORD_TINT,
		PopPalette.PLAYER, Color(0.62, 0.68, 0.78), PopPalette.GOLD]
	# v-1 身份入参各层 RGB 逐位 == 入参（a′-3 同式——含 W13 黑金 s≈0.06 不被钳）
	var no_shift := true
	var no_shift_detail := ""
	for c in identities:
		for layer in [0, 1, 2, 4, 5]:
			var out: Color = CrystalBladeFactory.layer_color(c, false, 2, layer)
			if absf(out.r - c.r) > 0.0005 or absf(out.g - c.g) > 0.0005 \
					or absf(out.b - c.b) > 0.0005:
				no_shift = false
				no_shift_detail = "层%d %s → %s" % [layer, c.to_html(false), out.to_html(false)]
	_check("v-1 五身份色各层 RGB 逐位零偏移（KIN 豁免路径零改动实证）",
		no_shift, no_shift_detail)
	# v-2 七元素表色全不命中豁免表（元素恒走水晶）
	var miss := true
	for e in [1, 2, 3, 4, 5, 6, 7]:
		if CrystalBladeFactory.is_identity_fill(PopPalette.ELEMENT_COLORS[e]):
			miss = false
	_check("v-2 七元素表色全不命中豁免表", miss)
	# v-3 W8 KIN 面零动（_wolf_body_color 恒 PLAYER 蓝单源 + 无宿主豁免判）
	var field: Node = load(ORBIT_PATH).new()
	_check("v-3 W8 KIN 面（_wolf_body_color == PLAYER ∧ 无宿主 _crystal_active=false）",
		field.call("_wolf_body_color") == PopPalette.PLAYER
		and field.call("_crystal_active") == false)
	field.free()
	# v-4 冻结线源面锁定（红线 7 仍受约束面逐串：:954 全轮廓描边线 / plain 臂白高光
	# 0.92 / 白獠牙 0.95 / plain 臂体 0.95 填充——本批零触的逐位证据）
	var of_src := FileAccess.get_file_as_string(ORBIT_PATH)
	_check("v-4 冻结线源面锁定（全轮廓描边 crystal_outline_color 1.6 ∧ plain 白高光 0.92"
			+ " ∧ 白獠牙 0.95 ∧ plain 蓝身 0.95）",
		of_src.find("CrystalBladeFactory.crystal_outline_color(), 1.6, true") >= 0
		and of_src.find("Color(1.0, 1.0, 1.0, 0.92), 2.2, true") >= 0
		and of_src.find("Color(1.0, 1.0, 1.0, 0.95)") >= 0
		and of_src.find("draw_colored_polygon(body, Color(blue.r, blue.g, blue.b, 0.95))") >= 0)
	# v-5 greatsword KIN 暗黑契约（a′-4 同式——KIN _t2_fill 恒暗黑不加色）
	var slash: Node = load(ARC_PATH).new()
	slash.call("spawn", {"blade_style": ArcSlash.STYLE_GREATSWORD, "transcended": true})
	var t2_fill: Color = slash.call("_t2_fill")
	_check("v-5 greatsword KIN _t2_fill 暗黑契约（== GREATSWORD_TINT）",
		t2_fill == ArcSlash.GREATSWORD_TINT, t2_fill.to_html(false))
	slash.free()
	# v-6 生产口 KIN 缺省调用零工厂构建（a′-6 同式——KIN 原配方路径实证）
	var m0: Dictionary = CrystalBladeFactory.metrics()
	FlyingSwordWeapon.flight_tex(false)
	FlyingSwordWeapon.flight_tex(true)
	GroundAxeWeapon.flight_tex(false)
	TextureFactory.boomerang_tex(PopPalette.GOLD)
	var m1: Dictionary = CrystalBladeFactory.metrics()
	_check("v-6 W10/W11/W12 KIN 缺省调用零工厂构建（tex_builds %d→%d）" % [
			int(m0["tex_builds"]), int(m1["tex_builds"])],
		int(m0["tex_builds"]) == int(m1["tex_builds"]))


# ══ 契约面 w：匕首感几何断言（V1——代数复制设计公式，不读像素） ═════════════
func _case_w_dagger_geometry() -> void:
	print("── w) R268：匕首感几何（W8 tres 端值 → 刀参数带/成长穿透/长宽比/残影门） ──")
	# w-1 从 W8_orbit_field.tres 读 orb_r_levels → 代数断言处方式基础长 ∈[50,60]
	# 且随 orb_radius 严格递增（成长穿透——旧式全等级恒 35.7 零成长）；全参数
	# （punch=0 基线 ×1.05 乘链后）随半径同样严格递增
	var tres := FileAccess.get_file_as_string(W8_TRES_PATH)
	var idx := tres.find("\"orb_r_levels\"")
	var parse_ok := idx >= 0
	var levels: Array[float] = []
	if parse_ok:
		var lbr := tres.find("[", idx)
		var rbr := tres.find("]", lbr)
		for tok in tres.substr(lbr + 1, rbr - lbr - 1).split(","):
			levels.append(float(tok))
	var blade_vals: Array[float] = []
	var base_vals: Array[float] = []
	for r in levels:
		blade_vals.append(OrbitField.wolf_blade_len(r, 0.0, 1.0))
		base_vals.append(OrbitField.wolf_blade_base(r))
	var band_ok := parse_ok and not levels.is_empty()
	var band_detail := "levels=%s base=%s blades=%s" % [str(levels), str(base_vals),
		str(blade_vals)]
	if band_ok:
		for b in base_vals:
			if b < 50.0 or b > 60.0:
				band_ok = false
	var chain_ok := band_ok
	for i in range(levels.size()):
		if not is_equal_approx(blade_vals[i], base_vals[i] * 1.05):
			chain_ok = false
	var strict_ok := band_ok
	for i in range(levels.size() - 1):
		if levels[i] < levels[i + 1] and blade_vals[i] >= blade_vals[i + 1]:
			strict_ok = false
		if levels[i] == levels[i + 1] \
				and not is_equal_approx(blade_vals[i], blade_vals[i + 1]):
			strict_ok = false
	_check("w-1 W8 orb_r_levels %s → 处方基础长 ∈[50,60] 全等级 + 随半径严格递增"
			% str(levels),
		band_ok and strict_ok and chain_ok, band_detail)
	# w-2 宽 ≥5.2（A2 地板全等级命中——刀宽 9.8→15px 级）
	var w_ok := true
	for r in levels:
		if OrbitField.wolf_blade_w(r, 1.0) < 5.2:
			w_ok = false
	_check("w-2 wolf_blade_w ≥5.2 全等级（实测 %.1f）" % OrbitField.wolf_blade_w(16.0, 1.0),
		w_ok and not levels.is_empty())
	# w-3 长宽比 ≤3.4:1（从单源顶点表实测投影：长 = x 投影极差、宽 = y 投影极差）
	var ratio_ok := true
	var ratio_detail := ""
	for r in levels:
		var bl := OrbitField.wolf_blade_len(r, 0.0, 1.0)
		var bw := OrbitField.wolf_blade_w(r, 1.0)
		var poly := OrbitField.wolf_blade_poly(Vector2.ZERO, Vector2.RIGHT, bl, bw)
		var x_min := INF
		var x_max := -INF
		var y_min := INF
		var y_max := -INF
		for v in poly:
			x_min = minf(x_min, v.x)
			x_max = maxf(x_max, v.x)
			y_min = minf(y_min, v.y)
			y_max = maxf(y_max, v.y)
		var ratio := (x_max - x_min) / maxf(y_max - y_min, 0.001)
		if ratio > 3.4:
			ratio_ok = false
			ratio_detail += "r=%.0f 比值%.2f " % [r, ratio]
	_check("w-3 刀身长宽比 ≤3.4:1（顶点表投影实测，全等级）", ratio_ok, ratio_detail)
	# w-4 判据自证：旧公式恒 35.7 < 新地板 50（「匕首」→「弯刀」量级差实证）
	var old_blade := maxf(16.0 * 1.05, 34.0) * 1.05
	_check("w-4 判据自证：旧式 L1 刀参数 %.1fpx < 新式 %.1fpx（地板 34→50）"
			% [old_blade, OrbitField.wolf_blade_len(16.0, 0.0, 1.0)],
		old_blade < 36.0 and OrbitField.wolf_blade_len(16.0, 0.0, 1.0) >= 50.0)
	# w-5 顶点形状逐位保持（wolf_blade_poly 与 R243 原表逐顶点同式——V1 只动长宽
	# 标量不动形状；用旧参数 35.7/3.4 复算原表对照）
	var blade0 := 35.7
	var w0 := 3.4
	var side := Vector2(0.0, 1.0)                       # motion=RIGHT 的刃口法向
	var old_poly := PackedVector2Array([
		Vector2.RIGHT * blade0 * 0.60 + side * blade0 * 0.12,
		Vector2.RIGHT * blade0 * 0.34 + side * blade0 * 0.16,
		Vector2.RIGHT * blade0 * 0.06 + side * blade0 * 0.15,
		-Vector2.RIGHT * blade0 * 0.30 + side * blade0 * 0.04,
		-Vector2.RIGHT * blade0 * 0.30 - side * blade0 * 0.02,
		Vector2.RIGHT * blade0 * 0.06 - side * (w0 * 1.6),
		Vector2.RIGHT * blade0 * 0.36 - side * (w0 * 1.2),
	])
	var new_poly := OrbitField.wolf_blade_poly(Vector2.ZERO, Vector2.RIGHT, blade0, w0)
	var verts_ok := new_poly.size() == old_poly.size()
	if verts_ok:
		for i in range(old_poly.size()):
			if (new_poly[i] as Vector2).distance_to(old_poly[i]) > 0.0001:
				verts_ok = false
	_check("w-5 顶点形状逐位保持（wolf_blade_poly 7 顶点 == R243 原表）", verts_ok)
	# w-6 巨刃乘链保持（punch/knife_scale 通道零动——MEC_GIANT_BLADE）
	var giant := OrbitField.wolf_blade_len(16.0, 1.0, 2.0)
	_check("w-6 巨刃乘链保持（punch=1/scale=2 → %.1f == 50×1.27×2）" % giant,
		absf(giant - 50.0 * 1.27 * 2.0) < 0.001)
	# w-7 C 残影门（fx_quality==0 砍残影/档 1、2 存在）+ 常量带（滞后 10-14° 中值
	# 12°/body α≈0.22）+ 源面接线（缺省分支 ghost_gate + 残影同几何复用）
	var of_src := FileAccess.get_file_as_string(ORBIT_PATH)
	_check(("w-7 残影门 ghost_gate（q0=false ∧ q1/q2=true）+ 常量（滞后 %s∈[10,14]°/"
			+ "α %.2f≈0.22）+ 源面接线") % [str(OrbitField.GHOST_LAG_DEG),
			OrbitField.GHOST_BODY_ALPHA],
		OrbitField.ghost_gate(0) == false and OrbitField.ghost_gate(1) == true
		and OrbitField.ghost_gate(2) == true
		and OrbitField.GHOST_LAG_DEG >= 10.0 and OrbitField.GHOST_LAG_DEG <= 14.0
		and absf(OrbitField.GHOST_BODY_ALPHA - 0.22) < 0.04
		and of_src.find("ghost_gate(_fx_quality())") >= 0
		and of_src.find("wolf_blade_poly(gpos") >= 0)
	# w-8 B 拖尾常量（α 0.30/宽 ×2.2/弧跨 42°）+ 逐刀接线与档位门源面（R268 评审
	# 修①④(a)：fx_quality==0 回落单段——q0 最弱机不加逐刀未降档增量）+ D 白缘
	# （站点色 lightened(0.55) ∧ 纯白站点色已拆 ∧ α 走 ALPHA_EDGE ∧ 七元素提亮色
	# ≠ 纯白）
	var d_ok := true
	for e in [1, 2, 3, 4, 5, 6, 7]:
		var lit: Color = PopPalette.ELEMENT_COLORS[e].lightened(0.55)
		if lit.r >= 0.999 and lit.g >= 0.999 and lit.b >= 0.999:
			d_ok = false
	_check(("w-8 B 拖尾（α%.2f/宽%.1f/%s°逐刀+档位门）+ D 白缘（lightened(0.55) 站点色"
			+ "≠纯白 ∧ ALPHA_EDGE α ∧ 旧纯白站点色已拆）")
			% [OrbitField.TRAIL_ALPHA, OrbitField.TRAIL_WIDTH_N,
			str(OrbitField.TRAIL_SPAN_DEG)],
		absf(OrbitField.TRAIL_ALPHA - 0.30) < 0.001
		and absf(OrbitField.TRAIL_WIDTH_N - 2.2) < 0.001
		and absf(OrbitField.TRAIL_SPAN_DEG - 42.0) < 0.001
		and of_src.find("b_phase - trail_span, b_phase") >= 0
		and of_src.find("orbs <= 6 and ghost_gate(_fx_quality())") >= 0
		and of_src.find("tint.lightened(0.55)") >= 0
		and of_src.find("edge_col.a = CrystalBladeFactory.ALPHA_EDGE") >= 0
		and of_src.find("Color(1.0, 1.0, 1.0, CrystalBladeFactory.ALPHA_EDGE)") < 0
		and d_ok)


# ══ 契约面 x：缓存零重建（数据面 + 图标 + arc_slash/orbit 真绘制帧） ═════════
func _case_x_cache_no_rebuild(p_tree: SceneTree) -> void:
	print("── x) R268：缓存零重建（数据面独占键 + 图标幂等 + 双站点真绘制帧） ──")
	# x-1 数据面：独占键首取建表 +1、二次调用零构建全命中（g-1 同式）
	var uniq := Color(0.72, 0.18, 0.24)      # 套内独占色（防前序用例预热误判）
	var m0: Dictionary = CrystalBladeFactory.metrics()
	CrystalBladeFactory.crystal_cols(&"saber", uniq, false, 2, CrystalBladeFactory.LAYER_BODY)
	CrystalBladeFactory.crystal_shell_poly(&"saber", true, 1.18)
	var m1: Dictionary = CrystalBladeFactory.metrics()
	CrystalBladeFactory.crystal_cols(&"saber", uniq, false, 2, CrystalBladeFactory.LAYER_BODY)
	CrystalBladeFactory.crystal_shell_poly(&"saber", true, 1.18)
	var m2: Dictionary = CrystalBladeFactory.metrics()
	_check("x-1 独占键首取建表（cols/shell 各 +1）后二次调用零构建全命中",
		int(m1["cols_builds"]) - int(m0["cols_builds"]) == 1
		and int(m1["shell_builds"]) - int(m0["shell_builds"]) == 1
		and int(m2["cols_builds"]) == int(m1["cols_builds"])
		and int(m2["shell_builds"]) == int(m1["shell_builds"])
		and int(m2["cols_hits"]) - int(m1["cols_hits"]) == 1
		and int(m2["shell_hits"]) - int(m1["shell_hits"]) == 1,
		"cols %d→%d→%d shell %d→%d→%d" % [int(m0["cols_builds"]),
			int(m1["cols_builds"]), int(m2["cols_builds"]), int(m0["shell_builds"]),
			int(m1["shell_builds"]), int(m2["shell_builds"])])
	# x-2 图标二次调用零重建（c′-2 同式——六 id 构建计数恒 1）
	var icon_ids: Array = [&"W8_orbit_field", &"W9_arc_slash", &"W10_boomerang",
		&"W11_spirit_sword", &"W12_ground_axe", &"W13_great_sword"]
	for wid in icon_ids:
		TextureFactory.weapon_icon(wid)
	for wid in icon_ids:
		TextureFactory.weapon_icon(wid)
	var stable := true
	for wid in icon_ids:
		if CrystalBladeFactory.icon_build_count(wid) != 1:
			stable = false
	_check("x-2 六 id 图标二次调用零重建（构建计数恒 1）", stable)
	# x-3 arc_slash 真绘制帧零新建（g-3 同式——水晶挥斩体两帧 builds 逐位不变）
	var wb: Node = _make_elem_weapon([GameConst.Element.FIR])
	var slash: Node = load(ARC_PATH).new()
	slash.set("name", "QASlashR268Draw")
	p_tree.root.add_child(slash)
	slash.set("weapon", wb)
	slash.call("spawn", {"crystal": true, "blade_style": ArcSlash.STYLE_SABER})
	slash.call("open_window", 0.0, Vector2(200.0, 200.0))
	await p_tree.process_frame
	await p_tree.process_frame
	var d1: Dictionary = CrystalBladeFactory.metrics()
	slash.call("open_window", 0.6, Vector2(200.0, 200.0))
	await p_tree.process_frame
	await p_tree.process_frame
	var d2: Dictionary = CrystalBladeFactory.metrics()
	_check("x-3 arc_slash 真绘制帧零新建（cols/shell/tex builds 逐位不变）",
		int(d2["cols_builds"]) == int(d1["cols_builds"])
		and int(d2["shell_builds"]) == int(d1["shell_builds"])
		and int(d2["tex_builds"]) == int(d1["tex_builds"]))
	slash.free()
	# x-4 orbit_field 水晶真绘制帧（V1 改动后）：工厂 builds 逐位不变 + 水晶列确实
	# 在消费（cols_hits 增长）——匕首感修复零缓存重建压力实证
	var field: Node = load(ORBIT_PATH).new()
	field.set("name", "QAOrbitR268Draw")
	p_tree.root.add_child(field)
	field.set("weapon", wb)
	await p_tree.process_frame
	await p_tree.process_frame
	var f1: Dictionary = CrystalBladeFactory.metrics()
	field.queue_redraw()
	await p_tree.process_frame
	await p_tree.process_frame
	var f2: Dictionary = CrystalBladeFactory.metrics()
	var drew := int(f2["cols_hits"]) > int(f1["cols_hits"])
	_check("x-4 orbit_field 真绘制帧零新建（builds 逐位不变 ∧ cols_hits %d→%d 增长）"
			% [int(f1["cols_hits"]), int(f2["cols_hits"])],
		drew and int(f2["cols_builds"]) == int(f1["cols_builds"])
		and int(f2["tex_builds"]) == int(f1["tex_builds"])
		and int(f2["shell_builds"]) == int(f1["shell_builds"]))
	_free_weapon(wb)
	field.free()


# ══ 主流程 ═══════════════════════════════════════════════════════════════════
func run(p_tree: SceneTree) -> void:
	print("══ R268 透明基准 + 匕首感验收（qa_r268_transparent）══")
	_case_t_alpha_bands()
	_case_u_brown_recheck()
	_case_v_kin_exempt()
	_case_w_dagger_geometry()
	await _case_x_cache_no_rebuild(p_tree)
	print("验收汇总：PASS %d / FAIL %d" % [_pass, _fail])

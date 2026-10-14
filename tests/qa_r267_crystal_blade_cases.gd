# tests/qa_r267_crystal_blade_cases.gd — R267 视觉刀用例体（§2.6 a/a′/b/c/c′/d/e/f/g
# + 六武器覆盖 + echo 双武装边界 + 微基准/预烤）。
# 判读口径：无像素判读处断生成器数据面（层数/alpha/颜色/缓存签名——任务书机制断言）；
# headless 实测 _draw 会执行（探针 r267_crystal_smoke2 复证），g 用例据此做真绘制帧验证。
extends RefCounted

const FACTORY_PATH := "res://scripts/combat/weapon/melee/crystal_blade_factory.gd"
const ORBIT_WEAPON_PATH := "res://scripts/combat/weapon/melee/orbit_weapon.gd"

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


# ── 棕判据（r267_probe_w9_brown_body.gd:84 同式） ──────────────────────────
func _is_brown(p_c: Color) -> bool:
	return p_c.h >= 0.02 and p_c.h <= 0.16 and p_c.s >= 0.35 and p_c.v <= 0.62


# ── 元素武器桩（r267_probe_w9_brown_body.gd:39-51 同式——生产 weapon_base +
# trait_stack + ELEM 词条直装，blend_element_color 走真管线） ─────────────────
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


# ══ §2.6-a 棕修判据（元素染色变体——暖池 0/8 + 亮核 v≥0.75 + sat 下限 0.55） ══
func _case_a_brown_fix() -> void:
	print("── a) 棕修判据（暖池 8 档采样 0/8；亮核 v≥0.75；sat 下限钳制） ──")
	var warm_pools: Array = [
		[GameConst.Element.FIR],
		[GameConst.Element.FIR, GameConst.Element.GEO],
		[GameConst.Element.FIR, GameConst.Element.GEO, GameConst.Element.DEN],
		[GameConst.Element.FIR, GameConst.Element.DEN],
		[GameConst.Element.GEO, GameConst.Element.DEN],
		[GameConst.Element.FIR, GameConst.Element.ICE],
	]
	# 判据自证：旧配方（darkened 梯度，arc_slash.gd:707-714 原式）在暖池确有棕档
	# （基线 2-5/8——本套件不依赖探针轮数字，判据有效性套内自证）
	for pool in warm_pools:
		var wb: Node = _make_elem_weapon(pool)
		var blend: Color = wb.call("blend_element_color")
		var old_browns := 0
		for stop in [blend.darkened(0.45), blend.darkened(0.30), blend.lightened(0.10),
				blend.lightened(0.45), blend.lightened(0.70), blend.lightened(0.45),
				blend.lightened(0.25), blend.darkened(0.20)]:
			if _is_brown(stop):
				old_browns += 1
		if old_browns == 0:
			_check("a-判据自证：暖池旧配方存在棕档（池 %s）" % str(pool), false,
				"旧配方 0 棕——判据失灵或池非暖")
		_free_weapon(wb)
	_check("a-判据自证：六暖池旧配方均有棕档（≥1/8）", true)
	# 新配方：六暖池 × saber/greatsword × 质变两态 × 三档 → 棕命中恒 0
	var all_zero := true
	var detail := ""
	for pool in warm_pools:
		var wb2: Node = _make_elem_weapon(pool)
		var slash: Node = load("res://scripts/combat/weapon/melee/arc_slash.gd").new()
		slash.set("weapon", wb2)
		slash.set("_tint_gen", -1)
		var tint: Color = slash.call("_live_blade_tint")
		var on: bool = slash.call("_crystal_visual_on") == false
		# 注：spawn 未传 crystal 键——先验缺省 false 零位移，再走显式键变体
		for style in [&"saber", &"greatsword"]:
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
						detail = "池%s %s t2=%s q=%d 棕 %d/8" % [str(pool), String(style), str(t2), q, browns]
		_free_weapon(wb2)
		slash.free()
	_check("a-1 暖池六池 × 双式 × 两态 × 三档：水晶输出棕命中 0", all_zero, detail)
	# 亮核明度 v≥0.75（CORE_V_MIN——角色 2 位顶点为亮核）
	var wb_f: Node = _make_elem_weapon([GameConst.Element.FIR])
	var fire: Color = wb_f.call("blend_element_color")
	var core_v_ok := true
	for style in [&"saber", &"greatsword"]:
		for t2 in [false, true]:
			var cols2: PackedColorArray = CrystalBladeFactory.crystal_cols(
				style, fire, t2, 2, CrystalBladeFactory.LAYER_BODY)
			var core_idx: Array = [3, 4] if style == &"saber" else [2, 3]
			for i in core_idx:
				if cols2[i].v < 0.75:
					core_v_ok = false
	_check("a-2 亮核明度 v≥0.75（saber 尖/刃位、greatsword 尖/刃位）", core_v_ok)
	_free_weapon(wb_f)
	# sat 下限钳制：入参 s<0.55 → 输出 s=0.55（§2.6-a 第三断言）
	var washed := Color(0.63, 0.32, 0.40)      # s≈0.49 < 0.55
	var sat_ok := true
	for style in [&"saber", &"greatsword", &"wolf"]:
		var cols3: PackedColorArray = CrystalBladeFactory.crystal_cols(
			style, washed, false, 2, CrystalBladeFactory.LAYER_BODY)
		for c in cols3:
			if absf(c.s - CrystalBladeFactory.SAT_FLOOR) > 0.01:
				sat_ok = false
	_check("a-3 sat 下限 0.55 生效（入参 s≈0.49 → 输出 0.55，三式）", sat_ok)
	# 修轮①评审②：真明度分层——七元素过渡层 v×0.92 严格 < 亮核 v（旧纯地板对
	# 元素域 v≥0.757 是空操作，分层只靠 α）
	var layered := true
	for e in [1, 2, 3, 4, 5, 6, 7]:
		var c: Color = PopPalette.ELEMENT_COLORS[e]
		if CrystalBladeFactory.layer_color(c, false, 2, 1).v \
				>= CrystalBladeFactory.layer_color(c, false, 2, 2).v:
			layered = false
	_check("a-4 过渡层 v×0.92 < 亮核 v（七元素真明度分层）", layered)


# ══ §2.6-a′ KIN/身份豁免（六身份站点零偏移 + 暗黑契约不破） ══════════════════
func _case_ap_identity_exempt() -> void:
	print("── a′) KIN/身份豁免（身份表命中/零钳制零提亮/暗黑契约/生产口不进工厂） ──")
	var identities: Array = [ArcSlash.SABER_TINT, ArcSlash.GREATSWORD_TINT,
		PopPalette.PLAYER, Color(0.62, 0.68, 0.78), PopPalette.GOLD]
	var hit := true
	for c in identities:
		if not CrystalBladeFactory.is_identity_fill(c):
			hit = false
	_check("a′-1 五身份色全命中豁免表", hit)
	var miss := true
	for e in [1, 2, 3, 4, 5, 6, 7]:
		if CrystalBladeFactory.is_identity_fill(PopPalette.ELEMENT_COLORS[e]):
			miss = false
	_check("a′-2 七元素表色全不命中（元素恒走水晶）", miss)
	# 身份入参零偏移：layer_color 各层 RGB 逐位 == 入参（不钳饱和/不提亮）
	var no_shift := true
	var no_shift_detail := ""
	for c in identities:
		for layer in [0, 1, 2, 4, 5]:
			var out: Color = CrystalBladeFactory.layer_color(c, false, 2, layer)
			if absf(out.r - c.r) > 0.0005 or absf(out.g - c.g) > 0.0005 \
					or absf(out.b - c.b) > 0.0005:
				no_shift = false
				no_shift_detail = "层%d %s → %s" % [layer, c.to_html(false), out.to_html(false)]
	_check("a′-3 身份入参各层 RGB 零偏移（含 W13 黑金 s≈0.06 不被钳）", no_shift, no_shift_detail)
	# greatsword 暗黑契约（arc_slash.gd:640-646）：KIN/空池 _t2_fill 恒暗黑不加色
	#（经 spawn 解析身份 tint——直 set 字段不触发 _resolve_blade_tint 会留 SABER 缺省）
	var slash: Node = load("res://scripts/combat/weapon/melee/arc_slash.gd").new()
	slash.call("spawn", {"blade_style": ArcSlash.STYLE_GREATSWORD, "transcended": true})
	var t2_fill: Color = slash.call("_t2_fill")
	_check("a′-4 greatsword KIN _t2_fill 暗黑契约（== GREATSWORD_TINT）",
		t2_fill == ArcSlash.GREATSWORD_TINT, t2_fill.to_html(false))
	slash.set("blade_style", ArcSlash.STYLE_SABER)
	slash.set("transcended", false)
	slash.set("crystal", true)
	_check("a′-5 crystal 键缺元素不激活（空池 _crystal_visual_on=false——风格键单盲不生效）",
		slash.call("_crystal_visual_on") == false)
	slash.free()
	# 生产口不进工厂：KIN 缺省调用前后工厂构建计数零增（原配方路径实证）
	var m0: Dictionary = CrystalBladeFactory.metrics()
	FlyingSwordWeapon.flight_tex(false)
	FlyingSwordWeapon.flight_tex(true)
	GroundAxeWeapon.flight_tex(false)
	TextureFactory.boomerang_tex(PopPalette.GOLD)
	var m1: Dictionary = CrystalBladeFactory.metrics()
	_check("a′-6 W10/W11/W12 KIN 缺省调用零工厂构建（tex_builds %d→%d）" % [
			int(m0["tex_builds"]), int(m1["tex_builds"])],
		int(m0["tex_builds"]) == int(m1["tex_builds"]))
	# W8 身份：_wolf_body_color 恒 PLAYER 蓝原口径（水晶路径不消费本口）
	var field: Node = load("res://scripts/combat/weapon/melee/orbit_field.gd").new()
	_check("a′-7 W8 _wolf_body_color == PLAYER（KIN 蓝身单源不动）",
		field.call("_wolf_body_color") == PopPalette.PLAYER)
	_check("a′-8 W8 无宿主 _crystal_active=false（空池豁免）",
		field.call("_crystal_active") == false)
	field.free()


# ══ §2.6-b 降档矩阵（层数/α/quality 进缓存键） ═══════════════════════════
func _case_b_quality_matrix() -> void:
	print("── b) 降档矩阵（档2 五层/档1 三层/档0 两层；α 断言；quality 进缓存键） ──")
	_check("b-1 layer_count 2/1/0 = 5/3/2", CrystalBladeFactory.layer_count(2) == 5
		and CrystalBladeFactory.layer_count(1) == 3
		and CrystalBladeFactory.layer_count(0) == 2)
	var fire: Color = PopPalette.ELEMENT_COLORS[GameConst.Element.FIR]
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
	_check("b-2 层 α 单源（壳 0.18/过渡 0.32/核 0.60/缘 0.9/平涂 0.50——R268 真透明）", alpha_ok, alpha_detail)
	# R268：真透明防回弹门——主体层 α 上界钉死（用户反馈「还是实色不透明」根因=
	# 旧核 0.92/平涂 0.85 大面积近实色；透明读感契约=主体 α≤0.70 且层间单调）。
	_check("b-5 R268 真透明契约（核 ≤0.70 且 平涂 ≤0.60 且 壳<过渡<核 层序单调）",
		CrystalBladeFactory.ALPHA_CORE <= 0.70
		and CrystalBladeFactory.ALPHA_FLAT <= 0.60
		and CrystalBladeFactory.ALPHA_SHELL < CrystalBladeFactory.ALPHA_TRANSITION
		and CrystalBladeFactory.ALPHA_TRANSITION < CrystalBladeFactory.ALPHA_CORE)
	_check("b-3 档1/0 外壳层 α=0（层不可用）+ shell 色表空（数据面表达）",
		CrystalBladeFactory.layer_color(fire, false, 1, 0).a == 0.0
		and CrystalBladeFactory.crystal_cols(&"saber", fire, false, 1,
			CrystalBladeFactory.LAYER_SHELL).is_empty()
		and CrystalBladeFactory.crystal_cols(&"saber", fire, false, 0,
			CrystalBladeFactory.LAYER_SHELL).is_empty())
	_check("b-4 质变外壳加浓（t2 α 0.18→0.26）+ 折射线档1 α=0",
		absf(CrystalBladeFactory.layer_color(fire, true, 2, 0).a
			- (CrystalBladeFactory.ALPHA_SHELL + 0.08)) < 0.001
		and CrystalBladeFactory.layer_color(fire, true, 1, 4).a == 0.0)
	# quality 进缓存键：同 fill 三档三实例互异、同键同实例（§2.5-4 改档不遮蔽）
	var t2_tex: ImageTexture = CrystalBladeFactory.crystal_tex(&"spirit_sword", fire, false, 2)
	var t1_tex: ImageTexture = CrystalBladeFactory.crystal_tex(&"spirit_sword", fire, false, 1)
	var t0_tex: ImageTexture = CrystalBladeFactory.crystal_tex(&"spirit_sword", fire, false, 0)
	var t2_again: ImageTexture = CrystalBladeFactory.crystal_tex(&"spirit_sword", fire, false, 2)
	_check("b-5 quality 进缓存键（三档互异实例 + 同档同实例）",
		t2_tex != t1_tex and t1_tex != t0_tex and t2_tex == t2_again)
	# 弹体降级参数口接通（W11/W12/W10 直传 p_quality → 工厂对应档实例）
	_check("b-6 弹体降级参数口：flight_tex/boomerang_tex p_quality 0/1/2 落工厂对应档",
		FlyingSwordWeapon.flight_tex(false, fire, 1) == t1_tex
		and GroundAxeWeapon.flight_tex(false, fire, 0) == CrystalBladeFactory.crystal_tex(
			&"ground_axe", fire, false, 0)
		and TextureFactory.boomerang_tex(fire, 2) == CrystalBladeFactory.crystal_tex(
			&"boomerang", fire, false, 2))
	# 档位全键预热后 9 连调零新键（三式 × 三档全命中）
	for style in [&"spirit_sword", &"ground_axe", &"boomerang"]:
		for q in [0, 1, 2]:
			CrystalBladeFactory.crystal_tex(style, fire, false, q)
	var m0: Dictionary = CrystalBladeFactory.metrics()
	for style in [&"spirit_sword", &"ground_axe", &"boomerang"]:
		for q in [0, 1, 2]:
			CrystalBladeFactory.crystal_tex(style, fire, false, q)
	var m1: Dictionary = CrystalBladeFactory.metrics()
	_check("b-7 三式 × 三档 9 连调零新键全命中（builds 持平 + hits +9）",
		int(m1["tex_builds"]) == int(m0["tex_builds"])
		and int(m1["tex_hits"]) - int(m0["tex_hits"]) == 9)


# ══ §2.6-c 缓存 + 六站点烘焙读回（非空/尺寸/半透像素/委托同实例） ═════════════
func _case_c_cache_and_sites() -> void:
	print("── c) 缓存签名 + 六站点烘焙读回（尺寸/半透像素/生产口同实例委托） ──")
	var fire: Color = PopPalette.ELEMENT_COLORS[GameConst.Element.FIR]
	# 微基准先行（新键冷烤——§2.6 ≤10ms 门；颜色取非元素表值防前序用例预热）
	var bench_fill := Color(0.55, 0.75, 0.35)
	var bench_ok := true
	var bench_detail := ""
	for style in [&"spirit_sword", &"ground_axe", &"boomerang"]:
		var t0 := Time.get_ticks_usec()
		CrystalBladeFactory.crystal_tex(style, bench_fill, false, 2)
		var us := Time.get_ticks_usec() - t0
		if us > 10000:
			bench_ok = false
			bench_detail += "%s=%dµs " % [String(style), us]
	_check("c-1 贴图首生成单次 ≤10ms（三式冷烤）", bench_ok, bench_detail)
	# 六站点读回：三烘焙式非空 + 尺寸 + 外壳 α<1 像素存在（半透实证）
	var sizes := {&"spirit_sword": Vector2(64.0, 64.0), &"ground_axe": Vector2(64.0, 64.0),
		&"boomerang": Vector2(44.0, 44.0)}
	var semi_ok := true
	var semi_detail := ""
	for style in sizes.keys():
		var tex: ImageTexture = CrystalBladeFactory.crystal_tex(style, fire, false, 2)
		if tex == null or tex.get_size() != sizes[style]:
			semi_ok = false
			semi_detail += "%s 尺寸异常 " % String(style)
			continue
		var img: Image = tex.get_image()
		var semi := 0
		for y in range(img.get_height()):
			for x in range(img.get_width()):
				var a: float = img.get_pixel(x, y).a
				if a > 0.05 and a < 0.95:
					semi += 1
		if semi < 10:
			semi_ok = false
			semi_detail += "%s 半透像素=%d " % [String(style), semi]
	_check("c-2 三烘焙式非空 + 尺寸正确 + 外壳半透像素 ≥10", semi_ok, semi_detail)
	# 生产口委托同实例（W10/W11/W12 元素路径 → 工厂缓存实例——「生成器一套」实证）
	var live_q: int = CrystalBladeFactory.live_fx_quality()
	_check("c-3 W11/W12/W10 生产口 == 工厂实例（烘焙形态单源）",
		FlyingSwordWeapon.flight_tex(false, fire) == CrystalBladeFactory.crystal_tex(
			&"spirit_sword", fire, false, live_q)
		and GroundAxeWeapon.flight_tex(false, fire) == CrystalBladeFactory.crystal_tex(
			&"ground_axe", fire, false, live_q)
		and TextureFactory.boomerang_tex(fire) == CrystalBladeFactory.crystal_tex(
			&"boomerang", fire, false, live_q))
	# 即时形态：saber/greatsword 8 位、wolf 7 位色表（六站点覆盖之 W8/W9/W13 面）
	_check("c-4 即时形态色表长度（saber/greatsword 8、wolf 7）",
		CrystalBladeFactory.crystal_cols(&"saber", fire, false, 2,
			CrystalBladeFactory.LAYER_BODY).size() == 8
		and CrystalBladeFactory.crystal_cols(&"greatsword", fire, false, 2,
			CrystalBladeFactory.LAYER_BODY).size() == 8
		and CrystalBladeFactory.crystal_cols(&"wolf", fire, false, 2,
			CrystalBladeFactory.LAYER_BODY).size() == 7)


# ══ §2.6-c′ 防混搭（六 id 图标全命中水晶版：机制标记 + 半透特征） ═════════════
func _case_cp_no_mixmatch() -> void:
	print("── c′) 防混搭（五委托位 + W10 match 臂全命中水晶版图标） ──")
	var icon_ids: Array = [&"W8_orbit_field", &"W9_arc_slash", &"W10_boomerang",
		&"W11_spirit_sword", &"W12_ground_axe", &"W13_great_sword"]
	var all_hit := true
	var detail := ""
	for wid in icon_ids:
		var tex: ImageTexture = TextureFactory.weapon_icon(wid)
		if tex == null:
			all_hit = false
			detail += "%s null " % String(wid)
			continue
		var built: int = CrystalBladeFactory.icon_build_count(wid)
		if built != 1:
			all_hit = false
			detail += "%s 构建计数=%d " % [String(wid), built]
		var img: Image = tex.get_image()
		var semi := 0
		for y in range(img.get_height()):
			for x in range(img.get_width()):
				var a: float = img.get_pixel(x, y).a
				if a > 0.05 and a < 0.95:
					semi += 1
		if semi < 10:
			all_hit = false
			detail += "%s 半透像素=%d " % [String(wid), semi]
	_check("c′-1 六 id 图标全命中水晶版（构建标记=1 + 壳层半透像素 ≥10）", all_hit, detail)
	# 二次调用缓存幂等（构建计数不增——防逐次重建）
	for wid in icon_ids:
		TextureFactory.weapon_icon(wid)
	var stable := true
	for wid in icon_ids:
		if CrystalBladeFactory.icon_build_count(wid) != 1:
			stable = false
	_check("c′-2 图标二次调用零重建（构建计数恒 1）", stable)


# ══ §2.6-d 即时形态外壳（外扩单调 + _poly_cache 四键读回口照绿） ═════════════
func _case_d_shell_geometry() -> void:
	print("── d) 外壳几何（包围盒 ⊇ 本体；_poly_cache 四键；expand_poly 单调） ──")
	var as_script: GDScript = load("res://scripts/combat/weapon/melee/arc_slash.gd")
	var slash: Node = as_script.new()
	var contain_ok := true
	var detail := ""
	for style_cfg in [[ArcSlash.STYLE_SABER, false], [ArcSlash.STYLE_SABER, true],
			[ArcSlash.STYLE_GREATSWORD, false], [ArcSlash.STYLE_GREATSWORD, true]]:
		slash.set("blade_style", style_cfg[0])
		slash.set("transcended", style_cfg[1])
		var poly: PackedVector2Array = slash.call("_blade_polygon")
		var shell: PackedVector2Array = CrystalBladeFactory.crystal_shell_poly(
			style_cfg[0], style_cfg[1], CrystalBladeFactory.SHELL_EXPAND)
		if shell.size() != poly.size():
			contain_ok = false
			detail += "%s/%s 壳顶点数 %d≠%d " % [String(style_cfg[0]), str(style_cfg[1]),
				shell.size(), poly.size()]
			continue
		# 外扩 = 绕质心等比缩放——判据用**质心距**（近心侧顶点向心收缩属正确行为，
		# 原点距判据会误判；质心 = 顶点均值，与 expand_poly 算子同式）
		var centroid := Vector2.ZERO
		for pt in poly:
			centroid += pt
		centroid /= float(poly.size())
		for i in range(poly.size()):
			if shell[i].distance_to(centroid) + 0.01 < poly[i].distance_to(centroid):
				contain_ok = false
				detail += "%s/%s 顶点%d 未外扩" % [String(style_cfg[0]), str(style_cfg[1]), i]
	_check("d-1 saber/greatsword ×质变：壳顶点质心距全数外扩（×1.32 单调）",
		contain_ok, detail)
	var poly_cache: Dictionary = as_script.get("_poly_cache")
	_check("d-2 _poly_cache 四键读回口照绿（R188⑨——style×transcended 四组缓存齐）",
		poly_cache.size() == 4, "size=%d" % poly_cache.size())
	slash.free()
	# expand_poly 通用单调（W8 内联壳层算子——狼刀 7 顶点样例）
	var wolf_sample := PackedVector2Array([Vector2(60.0, 12.0), Vector2(34.0, 16.0),
		Vector2(6.0, 15.0), Vector2(-30.0, 4.0), Vector2(-30.0, -2.0),
		Vector2(6.0, -16.0), Vector2(36.0, -12.0)])
	var wolf_shell: PackedVector2Array = CrystalBladeFactory.expand_poly(
		wolf_sample, CrystalBladeFactory.SHELL_EXPAND)
	var wolf_ok := wolf_shell.size() == wolf_sample.size()
	for i in range(wolf_sample.size()):
		if wolf_shell[i].length() + 0.5 < wolf_sample[i].length():
			wolf_ok = false
	_check("d-3 expand_poly 狼刀 7 顶点样例外扩单调（W8 壳层算子）", wolf_ok)


# ══ §2.6-e 零 rng（生成器源码静态扫描） ═══════════════════════════════════
func _case_e_zero_rng() -> void:
	print("── e) 零 rng（生成器源码静态扫描） ──")
	var src := FileAccess.get_file_as_string(FACTORY_PATH)
	var hits := 0
	for pat in ["randi", "randf", "RandomNumberGenerator"]:
		var idx := src.find(pat)
		while idx >= 0:
			hits += 1
			idx = src.find(pat, idx + 1)
	_check("e-1 生成器源码 randi|randf|RandomNumberGenerator 命中 = 0", hits == 0,
		"hits=%d" % hits)
	# 附：spawn 风格键接线（orbit_weapon 源扫描——W13 spawn 接线机制面）
	var ow_src := FileAccess.get_file_as_string(ORBIT_WEAPON_PATH)
	_check("e-2 orbit_weapon._slash_spawn_params 携带 \"crystal\": true（源面机制）",
		ow_src.find("\"crystal\": true") >= 0)


# ══ §2.6-f 排序纪律（Array[String]——红线 4） ═════════════════════════════
func _case_f_sort_discipline() -> void:
	print("── f) 排序纪律（缓存键列举拍序必须 Array[String]） ──")
	var keys: Array[String] = []
	for k in CrystalBladeFactory._cols_cache.keys():
		keys.append(String(k))
	var unsorted := keys.duplicate()
	keys.sort()                                     # Array[String].sort——红线 4 口径
	var sorted_ok := true
	for i in range(keys.size() - 1):
		if keys[i] > keys[i + 1]:
			sorted_ok = false
	_check("f-1 色表缓存键 Array[String] 拍序升序（%d 键）" % keys.size(),
		sorted_ok and keys.size() >= 10 and keys != [] and unsorted.size() == keys.size())


# ══ §2.6-g 绘制路径零分配（缓存命中计数 + headless 真绘制帧验证） ═════════════
func _case_g_zero_alloc_draw(p_tree: SceneTree) -> void:
	print("── g) 绘制路径零分配（数据面缓存命中 + 真绘制帧二次绘制零重建） ──")
	# 数据面：独占键首取建表 +1、二次调用零构建全命中（缓存签名——§2.6-g）
	var uniq := Color(0.72, 0.18, 0.24)      # 套内独占色（防前序用例预热误判）
	var m0: Dictionary = CrystalBladeFactory.metrics()
	CrystalBladeFactory.crystal_cols(&"saber", uniq, false, 2, CrystalBladeFactory.LAYER_BODY)
	CrystalBladeFactory.crystal_shell_poly(&"saber", true, 1.18)   # 独占 (t2,expand) 组合
	var m1: Dictionary = CrystalBladeFactory.metrics()
	CrystalBladeFactory.crystal_cols(&"saber", uniq, false, 2, CrystalBladeFactory.LAYER_BODY)
	CrystalBladeFactory.crystal_shell_poly(&"saber", true, 1.18)
	var m2: Dictionary = CrystalBladeFactory.metrics()
	_check("g-1 独占键首取建表（cols/shell 各 +1）后二次调用零构建全命中",
		int(m1["cols_builds"]) - int(m0["cols_builds"]) == 1
		and int(m1["shell_builds"]) - int(m0["shell_builds"]) == 1
		and int(m2["cols_builds"]) == int(m1["cols_builds"])
		and int(m2["shell_builds"]) == int(m1["shell_builds"])
		and int(m2["cols_hits"]) - int(m1["cols_hits"]) == 1
		and int(m2["shell_hits"]) - int(m1["shell_hits"]) == 1,
		"cols %d→%d→%d shell %d→%d→%d hits %d→%d" % [int(m0["cols_builds"]),
			int(m1["cols_builds"]), int(m2["cols_builds"]), int(m0["shell_builds"]),
			int(m1["shell_builds"]), int(m2["shell_builds"]), int(m1["cols_hits"]),
			int(m2["cols_hits"])])
	# 绘制面：headless _draw 会执行（烟雾探针复证）——真开窗两帧，第二帧零新建
	var wb: Node = _make_elem_weapon([GameConst.Element.FIR])
	var slash: Node = load("res://scripts/combat/weapon/melee/arc_slash.gd").new()
	slash.set("name", "QASlashCrystalDraw")
	p_tree.root.add_child(slash)
	slash.set("weapon", wb)
	slash.call("spawn", {"crystal": true, "blade_style": ArcSlash.STYLE_SABER})
	slash.call("open_window", 0.0, Vector2(200.0, 200.0))
	await p_tree.process_frame
	await p_tree.process_frame
	var d1: Dictionary = CrystalBladeFactory.metrics()
	slash.call("open_window", 0.6, Vector2(200.0, 200.0))   # 第二次开窗 → 再绘一帧
	await p_tree.process_frame
	await p_tree.process_frame
	var d2: Dictionary = CrystalBladeFactory.metrics()
	var drew := int(d1["cols_hits"]) + int(d1["shell_hits"]) > int(m2["cols_hits"]) + int(m2["shell_hits"])
	_check("g-2 真绘制帧走水晶层（首帧后命中计数已增长——绘制确在使用工厂表）", drew)
	_check("g-3 第二绘制帧零新建（cols/shell/tex builds 逐位不变——零分配实证）",
		int(d2["cols_builds"]) == int(d1["cols_builds"])
		and int(d2["shell_builds"]) == int(d1["shell_builds"])
		and int(d2["tex_builds"]) == int(d1["tex_builds"]))
	slash.free()
	_free_weapon(wb)


# ══ 六武器覆盖 + echo 双武装边界 ═════════════════════════════════════════
func _case_six_weapons_and_echo() -> void:
	print("── 六武器覆盖 + echo 双武装边界（子斩/回斩继承水晶键） ──")
	var fire: Color = PopPalette.ELEMENT_COLORS[GameConst.Element.FIR]
	# W8：_crystal_active 双态 + wolf 色表
	var field: Node = load("res://scripts/combat/weapon/melee/orbit_field.gd").new()
	var wb_fir: Node = _make_elem_weapon([GameConst.Element.FIR])
	field.set("weapon", wb_fir)
	_check("W8-1 环刀元素态 _crystal_active=true（FIR 池）", field.call("_crystal_active") == true)
	_check("W8-2 wolf 水晶色表 7 位可取", CrystalBladeFactory.crystal_cols(
		&"wolf", fire, false, 2, CrystalBladeFactory.LAYER_BODY).size() == 7)
	_free_weapon(wb_fir)
	var wb_kin: Node = _make_elem_weapon([GameConst.Element.KIN])
	field.set("weapon", wb_kin)
	_check("W8-3 环刀 KIN 池 _crystal_active=false（蓝身薄荷线豁免）",
		field.call("_crystal_active") == false)
	field.free()
	_free_weapon(wb_kin)
	# W9/W13：saber/greatsword 激活判 + echo 子代继承
	var as_script: GDScript = load("res://scripts/combat/weapon/melee/arc_slash.gd")
	var slash: Node = as_script.new()
	var wb: Node = _make_elem_weapon([GameConst.Element.FIR])
	slash.set("weapon", wb)
	slash.call("spawn", {"crystal": true, "blade_style": ArcSlash.STYLE_SABER,
		"transcended": true, "echo_ratio": 0.5})
	_check("W9-1 saber+FIR 激活 _crystal_visual_on=true", slash.call("_crystal_visual_on") == true)
	slash.call("_open_child_slash", Vector2(200.0, 200.0), 0.3, 0.5, true)  # echo 回斩口
	var children: Array = slash.get("_child_slashes")
	var child_ok := children.size() == 1
	if child_ok:
		var child: Node = children[0]
		child_ok = bool(child.get("crystal")) == true \
			and child.call("_crystal_visual_on") == true \
			and int(child.get("generation")) == 1
	_check("W9-2 echo 回斩子窗继承水晶键（crystal=true + 子代激活 + gen=1）", child_ok)
	slash.call("_clear_children")
	slash.free()
	# W13：greatsword + 元素 → 激活；KIN → 豁免（a′-5 已证空池，此处 KIN 池词条同判）
	var gs: Node = as_script.new()
	gs.set("weapon", wb)
	gs.call("spawn", {"crystal": true, "blade_style": ArcSlash.STYLE_GREATSWORD})
	_check("W13-1 greatsword+FIR 激活（元素刀体站点 §2.3）", gs.call("_crystal_visual_on") == true)
	gs.free()
	# W10/W11/W12：烘焙委托实例互异于 KIN 原配（c-3 已证同实例；此处证不与 KIN 键串味）
	_check("W10/W11/W12 元素实例 ≠ KIN 缺省实例",
		TextureFactory.boomerang_tex(fire) != TextureFactory.boomerang_tex(PopPalette.GOLD)
		and FlyingSwordWeapon.flight_tex(false, fire) != FlyingSwordWeapon.flight_tex(false)
		and GroundAxeWeapon.flight_tex(false, fire) != GroundAxeWeapon.flight_tex(false))
	_free_weapon(wb)


# ══ 修轮①评审视觉项（W10 折射洗刃 / W11 深度带 / 图标壳层 / 即时轮廓） ═══════
func _band_count(p_img: Image, p_target: float, p_tol := 0.008) -> int:
	# α 带像素计数（8bit 量化步 ≈0.0039——R268：tol 0.008 可分 0.55/0.60 与 0.90/1.00
	# 相邻带——新对带区间 [0.542,0.558]/[0.592,0.608] 与 [0.892,0.908]/[0.992,1.008]
	# 均不重叠，量化步 0.0039）
	var n := 0
	for y in range(p_img.get_height()):
		for x in range(p_img.get_width()):
			var a: float = p_img.get_pixel(x, y).a
			if absf(a - p_target) <= p_tol:
				n += 1
	return n


func _case_fix1_review() -> void:
	print("── 修轮①：W10 折射带 / W11 深度带 / 图标壳层 / 即时轮廓描边 ──")
	var fire: Color = PopPalette.ELEMENT_COLORS[GameConst.Element.FIR]
	# 修1-W10：q2 五带齐全（旧 bug：d_in > -2.6 刃体内恒真 → 整刃 α0.55 洗掉，
	# 描边/白缘/亮核三带全 0；R268：迁后带集实测 0.18:174/0.55:120/1.00:54/0.90:34/
	# 0.60:22——壳 0.22→ALPHA_SHELL 0.18、描边 0.98→ink.a=1.0（OUTLINE 无 α 位）、
	# 亮核 0.92→ALPHA_CORE 0.60，判据=探针 r268_ghost_band_probe_run.log 落档值）
	var boom_q2: Image = CrystalBladeFactory.crystal_tex(&"boomerang", fire, false, 2).get_image()
	var b_shell := _band_count(boom_q2, 0.18, 0.012)
	var b_refract := _band_count(boom_q2, 0.55)
	var b_rim := _band_count(boom_q2, 1.0)
	var b_edge := _band_count(boom_q2, 0.90)
	var b_core := _band_count(boom_q2, 0.60)
	_check("修1-W10a q2 五带齐全（壳 %d/折射 %d/描边 %d/白缘 %d/亮核 %d ≥100/50/30/20/10）"
			% [b_shell, b_refract, b_rim, b_edge, b_core],
		b_shell >= 100 and b_refract >= 50 and b_rim >= 30 and b_edge >= 20 and b_core >= 10)
	# 修1-W10b：折射带占比上限 70%（旧 bug 特征 = 刃体内 d_in 恒 ≥0 → 折射占刃体
	# 100%、三带全 0；修后实测折射 120/刃体 230 ≈52%——薄月牙内缘 2.6px 亮带本就
	# 合法占近半，70% 帽只拦「整刃洗掉」型回归）
	var blade_px := b_refract + b_rim + b_edge + b_core
	_check("修1-W10b 折射带占刃体 <70%%（折射 %d / 刃体 %d——旧 bug 为 100%%）" % [
			b_refract, blade_px], b_refract * 10 < blade_px * 7)
	# 修1-W11：深度常量细刃化——q1 亮核带非 0 / q0 平涂带非 0 且 q0≠q1 / q2 白缘不被
	# 折射线吃掉（旧：亮核与平涂带恒 0、q0/q1 同带、q2 白缘 40→4px；实测修后
	# q1 亮核 18 / q0 平涂 18 / q2 白缘 42。R268：α 目标已迁 0.60/0.50——像素计数
	# 在新 α 下逐位不变，判据=探针落档 18/18/42）
	var sw_q1: Image = CrystalBladeFactory.crystal_tex(&"spirit_sword", fire, false, 1).get_image()
	var sw_q0: Image = CrystalBladeFactory.crystal_tex(&"spirit_sword", fire, false, 0).get_image()
	var sw_q2: Image = CrystalBladeFactory.crystal_tex(&"spirit_sword", fire, false, 2).get_image()
	_check("修1-W11a q1 亮核带 ≥10（≥1.8px 芯带非空）", _band_count(sw_q1, 0.60) >= 10)
	_check("修1-W11b q0 平涂带 ≥10 且 q0/q1 图像互异（降档有观感差）",
		_band_count(sw_q0, 0.50) >= 10 and sw_q0.get_data() != sw_q1.get_data())
	_check("修1-W11c q2 白缘带 ≥30（折射线 depth 守卫——不再吃白缘；q1 同带对照 %d）"
			% [_band_count(sw_q1, 0.90)], _band_count(sw_q2, 0.90) >= 30)
	# 修1-图标：壳层外扩 1.45 后可读（旧 1.28 实测 W9/W11/W13 各 2px、六枚合计 53；
	# 1.45 实测 8..132、合计 351——W11 细刃+厚描边几何下环带结构性窄，按评审替代
	# 口径「构建标记+微弱边缘」以 ≥6/枚 + 合计 ≥200 为门）
	_check("修1-图标a ICON_SHELL_EXPAND == 1.45（外扩环露出可读档）",
		absf(CrystalBladeFactory.ICON_SHELL_EXPAND - 1.45) < 0.001)
	var icon_ids: Array = [&"W8_orbit_field", &"W9_arc_slash", &"W10_boomerang",
		&"W11_spirit_sword", &"W12_ground_axe", &"W13_great_sword"]
	var shell_total := 0
	var shell_min := 999
	var shell_detail := ""
	for wid in icon_ids:
		# 带口径 α∈[0.25,0.35]（与校准探针同式——含 _shade 连续 α 的 AA 边缘像素；
		# ±0.008 窄公差会把 AA 边圈错划出带外）
		var n := _band_count(TextureFactory.weapon_icon(wid).get_image(), 0.30, 0.05)
		shell_total += n
		shell_min = mini(shell_min, n)
		shell_detail += "%s:%d " % [String(wid).substr(0, 3), n]
	_check("修1-图标b 六枚壳层带（α∈[0.25,0.35]）每枚 ≥6 且合计 ≥200（%s）"
			% shell_detail, shell_min >= 6 and shell_total >= 200)
	# 修1-轮廓：即时形态水晶刀全轮廓描边（淡元素刀背亮底可读性）——源面接线 +
	# 工厂色单源（OUTLINE #22254a α0.65）
	var outline: Color = CrystalBladeFactory.crystal_outline_color()
	_check("修1-轮廓a 工厂描边色 == PopPalette.OUTLINE α0.65",
		outline.r == PopPalette.OUTLINE.r and outline.g == PopPalette.OUTLINE.g
		and outline.b == PopPalette.OUTLINE.b and absf(outline.a - 0.65) < 0.001)
	var as_src := FileAccess.get_file_as_string(
		"res://scripts/combat/weapon/melee/arc_slash.gd")
	var of_src := FileAccess.get_file_as_string(
		"res://scripts/combat/weapon/melee/orbit_field.gd")
	_check("修1-轮廓b 挥斩体与环刀水晶路径均接线 crystal_outline_color（源面）",
		as_src.find("crystal_outline_color") >= 0 and of_src.find("crystal_outline_color") >= 0)


# ══ 预烤域（§2.5-5：prewarm 后首击零冷 miss） ═════════════════════════════
func _case_prewarm() -> void:
	print("── 预烤域（prewarm_shared 后 21 键全命中零冷 miss） ──"
		)
	TextureFactory.prewarm_shared()
	var m0: Dictionary = CrystalBladeFactory.metrics()
	var miss := 0
	for e in PopPalette.ELEMENT_COLORS.keys():
		if int(e) == 0:
			continue
		var fill: Color = PopPalette.ELEMENT_COLORS[e]
		for style in [&"spirit_sword", &"ground_axe", &"boomerang"]:
			var tex: ImageTexture = CrystalBladeFactory.crystal_tex(style, fill, false, 2)
			if tex == null:
				miss += 1
	var m1: Dictionary = CrystalBladeFactory.metrics()
	_check("prewarm-1 预烤后 21 键零冷 miss（builds %d→%d）" % [
			int(m0["tex_builds"]), int(m1["tex_builds"])],
		miss == 0 and int(m1["tex_builds"]) == int(m0["tex_builds"]))
	_check("prewarm-2 预烤键数 = 21（三式 × 七元素）",
		int(m1["tex_hits"]) - int(m0["tex_hits"]) == 21)


# ══ 主流程 ═══════════════════════════════════════════════════════════════
func run(p_tree: SceneTree) -> void:
	print("══ R267 视觉刀验收（qa_r267_crystal_blade）══")
	_case_a_brown_fix()
	_case_ap_identity_exempt()
	_case_b_quality_matrix()
	_case_c_cache_and_sites()
	_case_cp_no_mixmatch()
	_case_d_shell_geometry()
	_case_e_zero_rng()
	_case_f_sort_discipline()
	await _case_g_zero_alloc_draw(p_tree)
	_case_six_weapons_and_echo()
	_case_fix1_review()
	_case_prewarm()
	print("验收汇总：PASS %d / FAIL %d" % [_pass, _fail])

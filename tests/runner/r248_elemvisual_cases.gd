# tests/runner/r248_elemvisual_cases.gd
# R248 元素弹体染色收口·用例体（由 test_r248_elemvisual.gd 入口加载）。
# 簇2 收口面（R211 收口报告 :128/:130 明示保留遗留 + R243 flight_tex 无色参漏登记项）：
#   M1 W6/W7 导弹弹体（missile_tex 参数化）：FIRE 染色与缺省键互异各白实例、
#      缺省调用像素=原浅灰蓝 body_col（0.78,0.84,0.95）、FIRE 像素=元素表色。
#   R1 镜面弹体（c2-② 弹侧接线消费 mirror_bead 带色键）：FIRE 表色同实例稳定、
#      与 KIN 银白珠实例互异；KIN 珠心=冰青派生（PLAYER.lerp(WHITE,0.62)）、
#      FIRE 珠心=表色与冰青对半混（fire.lerp(ice,0.5)，mirror_bead 混冰青口径）。
#   F1 飞剑 flight_tex 双参：FIRE 双参≠缺省蓝（键互异）、一参缺省调用同实例、
#      FIRE+t2 不落鎏金（元素优先——t2 键归并 base 同实例，且≠鎏金 t2 实例）。
#   F2 掷斧 flight_tex 双参：同 F1 口径（缺省=岩钢 FLIGHT_STEEL 非 PLAYER）。
# 像素断言口径：_render 内部深处 body=1 时像素=fill 原值（texture_factory.gd:1890-1893），
# 8bit 量化误差 ≤0.5/255——比较容差 0.002。headless 下 get_image() 可用
#（rcu_faqi_cases.gd:244-247 G1b 先例）。纯 static 贴图断言，无需装配 GameLoop。
extends RefCounted

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []

const FILL_FIRE: Color = Color(0.78, 0.84, 0.95)   # 导弹缺省原弹体浅灰蓝（与实现同字面）
const PX_EPS := 0.004                              # 8bit 量化容差——set_pixel 截断向下取整，误差最大近 1/255≈0.00392


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_test_m1_missile_tex()
	_test_r1_mirror_bead()
	_test_f1_sword_flight_tex()
	_test_f2_axe_flight_tex()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s（%s）" % [p_name, p_detail])
		print("  FAIL | %s（%s）" % [p_name, p_detail])


func _px_eq(p_px: Color, p_ref: Color) -> bool:
	# 像素色近似相等（8bit 量化容差）
	return absf(p_px.r - p_ref.r) <= PX_EPS and absf(p_px.g - p_ref.g) <= PX_EPS \
		and absf(p_px.b - p_ref.b) <= PX_EPS


func _tex_px(p_tex: ImageTexture, p_x: int, p_y: int) -> Color:
	var img: Image = p_tex.get_image()
	return img.get_pixel(p_x, p_y)


func _elem_color(p_elem: int) -> Color:
	return PopPalette.ELEMENT_COLORS[p_elem]


# ── M1 W6/W7 导弹弹体（missile_tex 参数化——c2-①） ──────────────────
func _test_m1_missile_tex() -> void:
	print("── M1 导弹弹体元素染色（missile_tex 带色键） ──")
	var fire := _elem_color(GameConst.Element.FIR)
	var t_def: ImageTexture = TextureFactory.missile_tex()
	var t_fire: ImageTexture = TextureFactory.missile_tex(fire)
	_check("M1a 键互异：missile_tex(FIRE) ≠ 缺省 missile_tex()（带色缓存键分离）",
		t_fire != null and t_def != null and t_fire != t_def,
		"fire=%s def=%s" % [str(t_fire != null), str(t_def != null)])
	_check("M1b 各白实例：缺省二次调用同实例（缓存稳定不重烤）",
		TextureFactory.missile_tex() == t_def, "re-call mismatch")
	_check("M1c 各白实例：FIRE 二次调用同实例（同色零重绘）",
		TextureFactory.missile_tex(fire) == t_fire, "re-call mismatch")
	_check("M1d 缺省调用像素=原浅灰蓝 body_col（画布 22×30 弹体内部点 11,16）",
		_px_eq(_tex_px(t_def, 11, 16), FILL_FIRE),
		"px=%s" % str(_tex_px(t_def, 11, 16)))
	_check("M1e FIRE 调用像素=元素表色（同采样点）",
		_px_eq(_tex_px(t_fire, 11, 16), fire),
		"px=%s" % str(_tex_px(t_fire, 11, 16)))


# ── R1 镜面弹体（mirror_bead 带色键——c2-② 弹侧消费） ───────────────
func _test_r1_mirror_bead() -> void:
	print("── R1 镜面弹体元素染色（mirror_bead） ──")
	var fire := _elem_color(GameConst.Element.FIR)
	var kin: Color = PopPalette.PLAYER
	var ice := kin.lerp(Color.WHITE, 0.62)             # mirror_bead 内壳冰青派生（实现同式）
	var t_fire: ImageTexture = TextureFactory.mirror_bead(fire, 64)
	_check("R1a FIRE 同色同实例：mirror_bead(FIRE) 二次调用同实例（带色缓存键稳定）",
		t_fire != null and TextureFactory.mirror_bead(fire, 64) == t_fire, "re-call mismatch")
	_check("R1b FIRE 珠 ≠ KIN 银白珠（实例互异=键互异）",
		t_fire != TextureFactory.mirror_bead(kin, 64), "instance collision")
	var px_kin := _tex_px(TextureFactory.mirror_bead(kin, 64), 32, 32)
	var px_fire := _tex_px(t_fire, 32, 32)
	_check("R1c KIN 银白珠心像素=冰青派生 PLAYER.lerp(WHITE,0.62)（原观感不变锚）",
		_px_eq(px_kin, ice), "px=%s exp=%s" % [str(px_kin), str(ice)])
	_check("R1d FIRE 珠心像素=表色与冰青对半混（mirror_bead 非 PLAYER 混色口径）且≠KIN 珠心",
		_px_eq(px_fire, fire.lerp(ice, 0.5)) and not _px_eq(px_fire, px_kin),
		"px=%s exp=%s" % [str(px_fire), str(fire.lerp(ice, 0.5))])


# ── F1 飞剑 flight_tex 双参（c2-③ W11） ────────────────────────────
func _test_f1_sword_flight_tex() -> void:
	print("── F1 飞剑弹体元素染色（flight_tex 双参） ──")
	var fire := _elem_color(GameConst.Element.FIR)
	var t_def: ImageTexture = FlyingSwordWeapon.flight_tex(false)
	_check("F1a 双参 FIRE ≠ 缺省蓝（键互异两实例）",
		t_def != null and FlyingSwordWeapon.flight_tex(false, fire) != t_def, "collided")
	_check("F1b 一参缺省调用同实例：flight_tex(false) == flight_tex(false, PLAYER)（缺省参路径确定性）",
		t_def == FlyingSwordWeapon.flight_tex(false, PopPalette.PLAYER), "default path drift")
	var t_fire_t2: ImageTexture = FlyingSwordWeapon.flight_tex(true, fire)
	_check("F1c FIRE+t2 不落鎏金（元素优先）：与 FIRE 基础版同实例（t2 键归并 base）",
		t_fire_t2 == FlyingSwordWeapon.flight_tex(false, fire), "element did not win")
	_check("F1d FIRE+t2 ≠ 鎏金 t2 实例（KIN 才落鎏金）",
		t_fire_t2 != FlyingSwordWeapon.flight_tex(true), "gilt leaked")
	_check("F1e KIN 两态互异保持：flight_tex(true) ≠ flight_tex(false)（鎏金键仍在）",
		FlyingSwordWeapon.flight_tex(true) != t_def, "t2 lost")


# ── F2 掷斧 flight_tex 双参（c2-③ W12，缺省=岩钢） ──────────────────
func _test_f2_axe_flight_tex() -> void:
	print("── F2 掷斧弹体元素染色（flight_tex 双参） ──")
	var fire := _elem_color(GameConst.Element.FIR)
	var t_def: ImageTexture = GroundAxeWeapon.flight_tex(false)
	_check("F2a 双参 FIRE ≠ 缺省岩钢（键互异两实例）",
		t_def != null and GroundAxeWeapon.flight_tex(false, fire) != t_def, "collided")
	_check("F2b 一参缺省调用同实例：flight_tex(false) == flight_tex(false, FLIGHT_STEEL)（KIN 回落确定性——弹侧 KIN 一参与测试直调同键）",
		t_def == GroundAxeWeapon.flight_tex(false, GroundAxeWeapon.FLIGHT_STEEL),
		"default path drift")
	var t_fire_t2: ImageTexture = GroundAxeWeapon.flight_tex(true, fire)
	_check("F2c FIRE+t2 不落岩纹（元素优先）：与 FIRE 基础版同实例（t2 键归并 base）",
		t_fire_t2 == GroundAxeWeapon.flight_tex(false, fire), "element did not win")
	_check("F2d FIRE+t2 ≠ 岩纹 t2 实例（KIN 才落岩纹）",
		t_fire_t2 != GroundAxeWeapon.flight_tex(true), "rock leaked")
	_check("F2e KIN 两态互异保持：flight_tex(true) ≠ flight_tex(false)（岩纹键仍在）",
		GroundAxeWeapon.flight_tex(true) != t_def, "t2 lost")

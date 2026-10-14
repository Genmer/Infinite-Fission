# tests/runner/r208_fivefix_cases.gd
# R208 五项混合批·用例体：①清空日志按钮 ②锁图标放大（r197 C⑥b 行为覆盖）
# ③XP 五色递进（r196 ④ 契约覆盖）④FPS 截断+面板瘦身 ⑤加特林/激光元素染色。
# 本套件收口四件的行为/静态锚（②③由既有套件联动覆盖，双处锁死）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	await _test_1_clear_log_button()
	_test_2_fps_label_width()
	_test_3_panel_slim()
	_test_4_element_tint_paths()
	_teardown_game_loop()
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


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R208GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


# ── ① 清空日志按钮：存在/相邻/链路清空 ──
func _test_1_clear_log_button() -> void:
	print("── ① 清空日志按钮 ──")
	var menu: MenuScreen = _gl.menu_screen
	var clear_btn: Button = menu.find_child("ClearLogButton", true, false) as Button
	var export_btn: Button = menu.find_child("ExportLogButton", true, false) as Button
	_check("按钮存在且文案「清空日志」", clear_btn != null and clear_btn.text == "清空日志",
		"btn=%s" % str(clear_btn))
	_check("与导出按钮同排右侧（y 等高、x 更右）",
		clear_btn != null and export_btn != null
			and absf(clear_btn.offset_top - export_btn.offset_top) < 0.01
			and clear_btn.offset_left > export_btn.offset_left,
		"clear=(%f,%f) export=(%f,%f)" % [clear_btn.offset_left if clear_btn != null else -1,
			clear_btn.offset_top if clear_btn != null else -1,
			export_btn.offset_left if export_btn != null else -1,
			export_btn.offset_top if export_btn != null else -1])
	# 链路：塞 3 行 → 清空返回 3 → 缓冲空 → 空再清返回 0
	DebugStats._diag_lines.clear()
	for i in range(3):
		DebugStats._diag_push("line%d" % i)
	var n: int = DebugStats.diag_clear()
	_check("diag_clear 清掉 3 行且缓冲空", n == 3 and DebugStats._diag_lines.is_empty(),
		"n=%d size=%d" % [n, DebugStats._diag_lines.size()])
	_check("空缓冲再清返回 0", DebugStats.diag_clear() == 0, "")
	# 按下链路不炸 + 文字反馈
	if clear_btn != null:
		menu._on_clear_log_pressed()
		_check("按下后按钮文字瞬时反馈「已清空0」", clear_btn.text == "已清空0",
			"text=%s" % clear_btn.text)


# ── ② FPS 标签：290px 宽承载 dc/o 诊断行（原 100px 左半截断） ──
func _test_2_fps_label_width() -> void:
	print("── ② FPS 标签宽度 ──")
	var hud: HUD = _gl.hud
	var lbl: Label = hud.find_child("FpsLabel", true, false) as Label
	_check("FpsLabel 在位", lbl != null, "无节点")
	if lbl != null:
		var w: float = lbl.offset_right - lbl.offset_left
		_check("带宽 274px（x426..704；原 100 装不下「FPS 10 dc 412 o 891」@20pt≈215px）",
			absf(w - 274.0) < 0.01, "w=%f" % w)


# ── ③ 构筑面板瘦身：118 宽 + 短文案 ──
func _test_3_panel_slim() -> void:
	print("── ③ 面板瘦身 ──")
	var hud: HUD = _gl.hud
	var panel: Control = hud._build_panel
	_check("面板宽 118（原 140 右列空白收缩）", panel != null and absf(panel.size.x - 118.0) < 0.01,
		"w=%s" % str(panel.size.x if panel != null else -1))
	var txt: Label = hud.find_child("BuildText", true, false) as Label
	# 运行期 refresh_stats 会把底行改写为「构筑 W:n T:n」摘要——两形态都以「构筑」起头
	# 且均 ≤118px（初始短文案 76 / 摘要 ~110），锁前缀+宽度承载
	_check("底行前缀「构筑」且面板 118 承载（初始文案改短式「构筑 · 详情」76px）",
		txt != null and txt.text.begins_with("构筑"), "text=%s" % (txt.text if txt != null else "?"))


# ── ④ 元素染色两路径：行为断言（R211 翻案——R208 仅静态源码锚，激光主束常驻
#    断点漏网；本批起改锁端到端行为：挂 ELE_IGNITE 即拍变色/重染） ──
func _test_4_element_tint_paths() -> void:
	print("── ④ 元素染色 ──")
	var t_kin: ImageTexture = TextureFactory.tracer_tex()
	var t_fire: ImageTexture = TextureFactory.tracer_tex(PopPalette.ELEMENT_COLORS[GameConst.Element.FIR])
	_check("曳光贴图分色缓存（火橙 ≠ 藏青缺省）", t_kin != null and t_fire != null
		and t_kin.get_rid() != t_fire.get_rid(), "kin=%s fire=%s" % [str(t_kin), str(t_fire)])
	var t_fire2: ImageTexture = TextureFactory.tracer_tex(PopPalette.ELEMENT_COLORS[GameConst.Element.FIR])
	_check("同色同实例（缓存键带色零重绘）", t_fire.get_rid() == t_fire2.get_rid(), "")
	_gl.player.set("unlocked_slots", 4)
	# 行为锚 A：加特林链路（挂 ELE_IGNITE → try_fire → 弹体/贴图全档火橙）
	var gat: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	_check("前置：加特林装配", gat != null, "gat=%s" % str(gat))
	if gat != null:
		gat.try_fire()
		var kin_b := _bullet_of(gat)
		_check("行为锚：挂卡前弹 KIN 藏青（tracer_tex() 同实例——缺省观感回归）",
			kin_b != null and kin_b.element == GameConst.Element.KIN
				and (kin_b.get("_sprite") as Sprite2D).texture.get_rid() == t_kin.get_rid(),
			"b=%s" % str(kin_b))
		_nullify_bullets_of(gat)
		gat.attach_trait(_gl.registry.get_trait(&"ELE_IGNITE"))
		gat.try_fire()
		var fire_b := _bullet_of(gat)
		_check("行为锚：挂 ELE_IGNITE 后弹 element==FIR / 变体 4 / 火橙曳光贴图",
			fire_b != null and fire_b.element == GameConst.Element.FIR
				and int(fire_b.get("_vis_variant")) == 4
				and (fire_b.get("_sprite") as Sprite2D).texture.get_rid() == t_fire.get_rid(),
			"elem=%s" % str(fire_b.element if fire_b != null else -1))
		_nullify_bullets_of(gat)
	# 行为锚 B：激光主束常驻重染（R211 断点修复——静态锚时代此断点漏网）
	var laser: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W4_pulse_beam"))
	_check("前置：激光 W4 装配为 LaserWeapon", laser is LaserWeapon, "lw=%s" % str(laser))
	if laser is LaserWeapon:
		var lw := laser as LaserWeapon
		lw.try_fire()
		var beam: LaserBeam = lw._main_beam
		var uid0: int = beam.uid if beam != null else 0
		lw.attach_trait(_gl.registry.get_trait(&"ELE_IGNITE"))
		for i in range(4):
			lw._on_tick_post(1.0 / 60.0)       # 逐拍回写通道（挂卡即拍生效）
		_check("行为锚：常驻主束挂卡逐拍后 element==FIR 且束色=element_tint(FIR)（同实例）",
			beam != null and is_instance_valid(beam) and beam == lw._main_beam
				and beam.uid == uid0 and beam.element == GameConst.Element.FIR
				and (beam.get("_line") as Line2D).default_color.is_equal_approx(
					LaserBeam.element_tint(GameConst.Element.FIR)),
			"elem=%s" % str(beam.element if beam != null else -1))


func _bullet_of(p_weapon: WeaponBase) -> ProjectileBase:
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		if p is ProjectileBase and (p as ProjectileBase).team == 0 \
				and (p as ProjectileBase).get("weapon_ref") == p_weapon:
			return p
	return null


func _nullify_bullets_of(p_weapon: WeaponBase) -> void:
	var hits: Array[ProjectileBase] = []
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		if p is ProjectileBase and (p as ProjectileBase).team == 0 \
				and (p as ProjectileBase).get("weapon_ref") == p_weapon:
			hits.append(p)
	for b in hits:
		b.nullify()

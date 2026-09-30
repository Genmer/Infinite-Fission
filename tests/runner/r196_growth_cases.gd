# tests/runner/r196_growth_cases.gd
# R196 成长与体验五连修 + 三定案（wunlock / pistol_trait_family / apk_menu_no_icons）
# headless 自动化套件·用例体（由 test_r196_growth.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖（对照 docs/design/R196_GROWTH_FIXES.md + 三份缺陷定案）：
#   ① AFF_RANGE 广域印刻（add_range 池）：登记/进池/环绕轨道半径与挥砍范围消费端
#   ② 超质变叠层：超帽可叠（ADD 池帽 stack_max+OVERCAP_EXT_MAX）、收益 ×0.7/层、
#     卡面 OVERCAP_NOTE 注记（文案真源 GameConst）、卡池上架帽放宽
#   ③ 构筑面板位置三选（右上默认，不与暂停钮/金币 pill/AUTO 重叠）+ 面板区 ScreenDrag 不断链
#   ④ 经验四色档位：xp_tier_of 阈值→档位映射（含七彩档）+ 档色单源 PopPalette
#   ⑤ 图鉴反应锁：未触发锁定 / mark_reaction_seen 解锁（幂等）/ 存档兼容（旧档缺键不炸）
#   ⑥ 武器准入门（wunlock 定案）：矩阵/逐关上架集/UI 三态读取/echo 双武装同门/首发守卫
#   ⑦ 手枪词条家族（pistol_trait_family 修复后契约）：多重装填实发 N 发可辨 +
#     穿透弹头逐目标贯穿（R196 FIX-2 有意契约变更——原 pkg2「同敌多跳耗尽」语义退役）
#   ⑧ 图标（apk_menu_no_icons 定案）：ui_lock/ui_gem/ui_trophy 贴纸在位 +
#     10 武器图标两两互异 + 源码零 >0xFFFF 码点（emoji 字面量禁入闸门）
# 纪律：headless 测试档自动隔离（meta_save_test.cfg）；用例收尾还原 Meta 状态防跨套件污染。
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"
const DESIGN_DOMAIN := Rect2(0.0, 0.0, 720.0, 1280.0)
const PANEL_SIZE := Vector2(140.0, 258.0)
# R197 竖排两列改版：252×132 横排 → 140×258 窄高；三档绝对落位（canvas 域 720×1280）
const PANEL_RECT_POS0 := Rect2(556.0, 196.0, 140.0, 258.0)    # 右上（默认）
const PANEL_RECT_POS1 := Rect2(444.0, 998.0, 140.0, 258.0)    # 右下
const PANEL_RECT_POS2 := Rect2(24.0, 998.0, 140.0, 258.0)     # 左下（贴底/左沿保持 R195 口径）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _w: Array[WeaponBase] = []                     # 预建 W1（每例独占防词条串扰）
# Meta 状态快照（teardown 还原——测试档虽隔离，仍防本套件内用例间污染）
var _snap_reaction_seen: Dictionary = {}
var _snap_codex_weapons: Dictionary = {}
var _snap_first_met: Dictionary = {}
var _snap_custom_weapon: String = ""
var _snap_panel_pos: int = 0
var _snap_shake_on: bool = true
var _snap_maps_cleared: Dictionary = {}


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_snapshot_meta()
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_test_1_range_trait()                          # ①
	_test_2_overcap()                              # ②
	await _test_3_panel_pos_and_drag()             # ③（需布局帧落定）
	_test_4_xp_tiers()                             # ④
	_test_5_codex_reaction_lock()                  # ⑤
	_test_7_pistol_family()                        # ⑦（先于 ⑥——echo 双武装会清槽）
	_test_6_weapon_gate()                          # ⑥
	_test_8_icon_audit()                           # ⑧
	_restore_meta()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])


func fail_count() -> int:
	return _fail


# ── 环境 ──────────────────────────────────────────────────────────
func _snapshot_meta() -> void:
	# 快照 + 清场（图鉴清零/首发回手枪/反应锁清零）——断言确定性前置
	_snap_reaction_seen = Meta.reaction_seen.duplicate()
	_snap_codex_weapons = Meta.codex_weapons.duplicate()
	_snap_first_met = Meta.codex_first_met.duplicate()
	_snap_custom_weapon = String(Meta.custom_weapon_id)
	_snap_panel_pos = int(Meta.settings("panel_pos"))
	Meta.reaction_seen = {}
	Meta.custom_weapon_id = ""
	Meta.reset_weapon_codex()                      # R196 自救口（清 codex_weapons + W_ 首遇）


func _restore_meta() -> void:
	Meta.reaction_seen = _snap_reaction_seen
	Meta.codex_weapons = _snap_codex_weapons
	Meta.codex_first_met = _snap_first_met
	Meta.custom_weapon_id = _snap_custom_weapon
	Meta.set_setting("panel_pos", _snap_panel_pos)
	Meta.set_setting("shake_on", _snap_shake_on)   # 还原写口（「写即存」防测试档残留污染后续套件）
	Meta.maps_cleared = _snap_maps_cleared         # R196 评审：进度段同还原（三态门态真源）
	Meta.set_run_map(&"")
	Meta._save()


func _normalize_window_for_boot() -> void:
	# -s 脚本模式根窗口不应用工程 stretch（r194/r195 同款归一）：canvas_items + 工程 aspect
	# + 默认窗 override 540×960（与设计域 720×1280 同 9:16 → canvas 域恒等）
	var win: Window = tree.root
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	match String(ProjectSettings.get_setting("display/window/stretch/aspect", "keep")):
		"keep_width":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP_WIDTH
		"keep_height":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP_HEIGHT
		"expand":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
		"ignore":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
		_:
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	win.size = Vector2i(
		int(ProjectSettings.get_setting("display/window/size/window_width_override", 540)),
		int(ProjectSettings.get_setting("display/window/size/window_height_override", 960)))


func _boot_game_loop() -> void:
	_normalize_window_for_boot()
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R196GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU          # 冻结波次刷怪（用例自管夹具敌）
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.set("unlocked_slots", 6)
	_gl.player.global_position = Vector2(360.0, 900.0)
	_snap_shake_on = bool(Meta.settings("shake_on"))
	Meta.set_setting("shake_on", false)
	# 预建 3 把 W1（开局枪占槽 0，另补 2 把——每测试例独占一把防词条串扰）
	for i in range(3):
		_w.append(_gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol")))


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _set_map_idx(p_idx: int) -> void:
	Meta.set_run_map(MapTable.MAPS[p_idx].id)


func _fresh_pistol(p_idx: int, p_level: int) -> WeaponBase:
	# 每例独占一把预建 W1（trait_stack.clear 清例间词条串扰）；弹幕态计时器清零
	if p_idx < 0 or p_idx >= _w.size():
		return null
	var w := _w[p_idx]
	if w == null or not is_instance_valid(w):
		return null
	w.trait_stack.clear()
	w.level = clampi(p_level, 1, 5)
	w.set("_volley_left", 0.0)
	w.set("_volley_cd_left", 0.0)
	w.call("_invalidate_panel")
	return w


# ══ ① AFF_RANGE 广域印刻（add_range 池） ═════════════════════════
func _test_1_range_trait() -> void:
	print("── ① AFF_RANGE 武器范围词条（登记/进池/消费端） ──")
	var t: TraitData = _gl.registry.get_trait(&"AFF_RANGE")
	_check("①夹具：AFF_RANGE 入注册表（.tres 数据底座产出）", t != null)
	if t == null:
		return
	_check("①登记：add_range 入 DataValidator.ADD_POOL_IDS（第 16 员追加）",
		DataValidator.ADD_POOL_IDS.has(&"add_range"))
	_check("①数值：value=0.18 / stack_max=3 / required_forms=[3] 近战架",
		absf(float(t.value) - 0.18) < 0.0001 and int(t.stack_max) == 3
		and (t.params.get("required_forms", []) as Array).has(3))
	_set_map_idx(0)
	_check("①门：第 1 关 ADD 池不受大关门（trait_allowed 真）",
		MechanicGate.trait_allowed(t))
	var gen := CardGenerator.new()
	gen.setup(_gl.registry)
	var w9 := OrbitWeapon.new()
	tree.root.add_child(w9)
	w9.setup(_gl.registry.get_weapon(&"W9_arc_slash"), null, {})
	var pool_add := gen._trait_candidates("ADD", _gl.player, [], w9)
	_check("①进池：第 1 关 ADD 类目候选含 AFF_RANGE", pool_add.has(&"AFF_RANGE"),
		"pool=%s" % [pool_add])
	# 消费端（挥砍范围）：W9 effective_slash_radius = 逐级表值 × 巨刃乘区 × range_mult
	var r0: float = w9.effective_slash_radius()
	w9.attach_trait(t)
	var r1: float = w9.effective_slash_radius()
	_check("①消费端：挂 1 层挥砍半径 ×1.18（150→177）",
		absf(r0 - 150.0) < 0.01 and absf(r1 - 150.0 * 1.18) < 0.01,
		"r0=%.2f r1=%.2f" % [r0, r1])
	w9.attach_trait(t)
	w9.attach_trait(t)
	var r3: float = w9.effective_slash_radius()
	_check("①消费端：满 3 层 ×1.54（150→231）", absf(r3 - 150.0 * 1.54) < 0.01,
		"r3=%.2f" % r3)
	# 消费端（环绕轨道半径）：W8 _orbit_params.orbit_radius ×(1+Σadd_range)
	var w8 := OrbitWeapon.new()
	tree.root.add_child(w8)
	w8.setup(_gl.registry.get_weapon(&"W8_orbit_field"), null, {})
	var orb0: float = float(w8._orbit_params()["orbit_radius"])
	w8.attach_trait(t)
	var orb1: float = float(w8._orbit_params()["orbit_radius"])
	_check("①消费端：环绕轨道半径 90→106.2（×1.18，置于 copy 分支后本体/复制体同享）",
		absf(orb0 - 90.0) < 0.01 and absf(orb1 - 106.2) < 0.01,
		"orb0=%.2f orb1=%.2f" % [orb0, orb1])
	w9.queue_free()
	w8.queue_free()
	Meta.set_run_map(&"")


# ══ ② 超质变叠层（R196 有意契约变更——原「至 stack_max 拒绝」） ════
func _test_2_overcap() -> void:
	print("── ② 超质变叠层（超帽可叠 / ×0.7 加算 / 卡面注记） ──")
	_check("②常量：OVERCAP_VALUE_MULT=0.7 / OVERCAP_EXT_MAX=5（单源 trait_stack）",
		absf(TraitStack.OVERCAP_VALUE_MULT - 0.7) < 0.0001 and TraitStack.OVERCAP_EXT_MAX == 5)
	_check("②文案：GameConst.OVERCAP_NOTE 在（真源逐字）",
		GameConst.OVERCAP_NOTE == "超出质变等级的层数收益降低 30%",
		GameConst.OVERCAP_NOTE)
	var t: TraitData = _gl.registry.get_trait(&"AFF_ATK_UP")   # ADD 池 stack_max=3 value=0.15
	var w := BallisticWeapon.new()
	tree.root.add_child(w)
	w.setup(_gl.registry.get_weapon(&"W1_pistol"), null, {})
	_check("②夹具：W1 + AFF_ATK_UP 在册", t != null and w.trait_stack != null)
	if t == null:
		return
	# 第 1 关注入：质变门未开（milestone_unlocked 假）→ value_mult 恒 1.0，×0.7 口径单独可辨
	#（无局态 milestone_unlocked()==true——挂满层即 ×1.6，会与超帽乘子混淆）
	_set_map_idx(0)
	var full_ok := true
	for i in range(3 + TraitStack.OVERCAP_EXT_MAX):           # 8 层全收（3 满额 + 5 超帽）
		full_ok = full_ok and w.attach_trait(t)
	_check("②超帽可叠：ADD 池 stack_max+5 层连挂全成功（原第 4 层即拒——R196 契约变更）",
		full_ok and w.trait_stack.traits[0].layers == 8,
		"layers=%d" % int(w.trait_stack.traits[0].layers))
	_check("②帽外拒绝：第 9 层（>stack_max+OVERCAP_EXT_MAX）拒绝",
		not w.attach_trait(t) and w.trait_stack.traits[0].layers == 8)
	# 聚合收益：前 stack_max 层全额 + 超帽层 ×0.7 → 3×0.15 + 5×0.105 = 0.975
	var agg: float = float(w.trait_stack.aggregate_panel().get("add_atk", 0.0))
	_check("②收益：逐层路 3×0.15 + 5×(0.15×0.7) = 0.975", absf(agg - 0.975) < 0.001,
		"agg=%.4f" % agg)
	var entries := w.trait_stack.aggregate_add_entries()
	var oc_contrib := 0.0
	if entries.size() > 3:
		oc_contrib = float(entries[3].get("contrib", 0.0))
	_check("②收益：add_entries 第 4 层（首个超帽层）contrib=0.105", absf(oc_contrib - 0.105) < 0.001,
		"contrib=%.4f entries=%d" % [oc_contrib, entries.size()])
	# R196 评审修复锁定：add_hp 直挂消费端（weapon_base 挂载口 → apply_max_hp_up）
	# 超帽层同步 ×OVERCAP_VALUE_MULT——卡面 OVERCAP_NOTE「收益降低 30%」对实际血条
	# 成立（原实现在直挂口全额回加，与面板聚合 ×0.7 失诺）
	var hp0: float = float(_gl.player.get("max_hp"))
	var hpv0: float = float(_gl.player.get("hp"))
	var hp_t: TraitData = _gl.registry.get_trait(&"AFF_HP_UP")   # ADD 池 stack_max=4 value=25
	var whp := BallisticWeapon.new()
	tree.root.add_child(whp)
	whp.setup(_gl.registry.get_weapon(&"W1_pistol"), _gl.player, {})
	var hp_ok := true
	for i in range(4 + TraitStack.OVERCAP_EXT_MAX):          # 9 层全收（4 满额 + 5 超帽）
		hp_ok = hp_ok and whp.attach_trait(hp_t)
	var hp_gain: float = float(_gl.player.get("max_hp")) - hp0
	_check("②直挂消费端：AFF_HP_UP 9 层 → 血条恰 +4×25 + 5×(25×0.7)=187.5（×0.7 落血条）",
		hp_ok and absf(hp_gain - 187.5) < 0.0001, "gain=%.2f" % hp_gain)
	_gl.player.set("max_hp", hp0)                  # 夹具还原（后续用例血量锚不串扰）
	_gl.player.set("hp", hpv0)
	whp.queue_free()
	Meta.set_run_map(&"")
	# 质变乘区兼容：满层质变 ×1.6 仍乘每层终值（超帽层 = value×0.7×1.6）
	_set_map_idx(3)                                # 第 4 关满层质变解锁
	var w2 := BallisticWeapon.new()
	tree.root.add_child(w2)
	w2.setup(_gl.registry.get_weapon(&"W1_pistol"), null, {})
	for i in range(4):
		w2.attach_trait(t)
	var mult := 1.0
	for tb in w2.trait_stack.traits:
		if tb.data.id == &"AFF_ATK_UP":
			mult = float(tb.value_mult)
	var agg2: float = float(w2.trait_stack.aggregate_panel().get("add_atk", 0.0))
	_check("②质变兼容：满层质变 ×1.6 触发，4 层聚合 = 3×0.24 + 1×0.168 = 0.888",
		absf(mult - 1.6) < 0.001 and absf(agg2 - 0.888) < 0.001,
		"mult=%.2f agg=%.4f" % [mult, agg2])
	w2.queue_free()
	Meta.set_run_map(&"")
	# 非 ADD 池保持原帽（MULT 取优/ELEM 语义不变）
	var elem: TraitData = _gl.registry.get_trait(&"ELE_IGNITE")   # ELEM 池 stack_max=2
	var w3 := BallisticWeapon.new()
	tree.root.add_child(w3)
	w3.setup(_gl.registry.get_weapon(&"W1_pistol"), null, {})
	var elem_ok := true
	for i in range(2):
		elem_ok = elem_ok and w3.attach_trait(elem)
	_check("②非 ADD 帽：ELEM 池 2 层挂满成功、第 3 层拒绝（原帽语义不变）",
		elem_ok and not w3.attach_trait(elem) and w3.trait_stack.traits[0].layers == 2)
	w3.queue_free()
	# 卡面注记：超帽态描述尾追 GameConst.OVERCAP_NOTE（双写 card + data 副本）
	var gen := CardGenerator.new()
	gen.setup(_gl.registry)
	var w_full := BallisticWeapon.new()
	tree.root.add_child(w_full)
	w_full.setup(_gl.registry.get_weapon(&"W1_pistol"), null, {})
	for i in range(3):
		w_full.attach_trait(t)
	var card_oc := gen._make_trait_card(&"AFF_ATK_UP", 1, w_full)
	_check("②卡面：满层目标 → card.overcap 真 + 描述含 OVERCAP_NOTE（card+data 双写）",
		bool(card_oc.get("overcap", false))
		and String(card_oc.get("description", "")).contains(GameConst.OVERCAP_NOTE)
		and card_oc.get("data") != null
		and String((card_oc.get("data") as TraitData).description).contains(GameConst.OVERCAP_NOTE))
	var w_zero := BallisticWeapon.new()
	tree.root.add_child(w_zero)
	w_zero.setup(_gl.registry.get_weapon(&"W1_pistol"), null, {})
	var card_zero := gen._make_trait_card(&"AFF_ATK_UP", 1, w_zero)
	_check("②卡面：零层目标 → overcap 假 + 描述不含注记（基描述干净）",
		not bool(card_zero.get("overcap", false))
		and not String(card_zero.get("description", "")).contains(GameConst.OVERCAP_NOTE))
	# 卡池上架帽：满 3 层仍上架（原「至 stack_max 移出池」——R196 契约变更），满 8 层才移出
	var pool_at_full := gen._trait_candidates("ADD", _gl.player, [], w_full)
	_check("②上架帽：目标满 3 层时 AFF_ATK_UP 仍上架（帽放宽至 stack_max+5）",
		pool_at_full.has(&"AFF_ATK_UP"))
	for i in range(5):
		w_full.attach_trait(t)
	var pool_at_ext := gen._trait_candidates("ADD", _gl.player, [], w_full)
	_check("②上架帽：目标满 8 层（stack_max+5）时移出候选池",
		not pool_at_ext.has(&"AFF_ATK_UP"))
	w.queue_free()
	w_full.queue_free()
	w_zero.queue_free()


# ══ ③ 构筑面板位置三选 + 面板区拖动不断链 ════════════════════════
func _test_3_panel_pos_and_drag() -> void:
	print("── ③ 构筑面板三档落位 + 面板区 ScreenDrag 不断链 ──")
	var hud := _gl.hud
	_check("③前置：HUD/构筑面板/设置面板句柄在",
		hud != null and hud._build_panel != null and _gl.settings_panel != null
		and _gl.player != null)
	if hud == null or hud._build_panel == null:
		return
	var panel: Control = hud._build_panel
	# 0 右上（默认）：写口 → settings_changed → _apply_build_panel_pos 即时重挂
	Meta.set_setting("panel_pos", 0)
	await tree.process_frame
	var rect0: Rect2 = panel.get_global_rect()
	_check("③默认右上：落位 x556-696×y196-454（锚/offset 逐位，R197 竖两列）",
		rect0.position == PANEL_RECT_POS0.position and rect0.size == PANEL_SIZE,
		"rect=%s" % str(rect0))
	_check("③右上锚：l/r=1 t/b=0，offset(-164,196,-24,454)",
		panel.anchor_left == 1.0 and panel.anchor_right == 1.0
		and panel.anchor_top == 0.0 and panel.anchor_bottom == 0.0
		and panel.offset_left == -164.0 and panel.offset_top == 196.0
		and panel.offset_right == -24.0 and panel.offset_bottom == 454.0)
	# 持久元素零冲突：暂停钮 / 金币 pill / AUTO（均在右上带 y<196）
	var pause_r: Rect2 = hud._pause_btn.get_global_rect()
	var gold := hud.find_child("GoldPill", true, false) as Control
	var auto_r: Rect2 = hud._auto_btn.get_global_rect()
	_check("③前置：金币 pill 句柄在（GoldPill）", gold != null)
	_check("③右上零重叠：不压暂停钮/金币 pill/AUTO（持久元素）",
		not rect0.intersects(pause_r) and not rect0.intersects(auto_r)
		and (gold == null or not rect0.intersects(gold.get_global_rect())),
		"pause=%s auto=%s" % [str(pause_r), str(auto_r)])
	# 1 右下：避开技能键（x444-584，右沿 W-136）
	Meta.set_setting("panel_pos", 1)
	await tree.process_frame
	var rect1: Rect2 = panel.get_global_rect()
	_check("③右下档：落位 x444-584×y998-1256（R197 竖两列）", rect1.position == PANEL_RECT_POS1.position
		and rect1.size == PANEL_SIZE, "rect=%s" % str(rect1))
	# R196 评审修复锁定：右下档 × 960×1280（3:4 平板，expand 逻辑域宽 960）——技能键
	# 右缘锚后左沿恒 W-110 > 面板右沿恒 W-136，任意宽度零重叠（720/960 域均验）
	var size0: Vector2i = tree.root.size
	tree.root.size = Vector2i(960, 1280)
	for _rz in range(3):
		await tree.process_frame              # 时序纪律：resize 后 ≥2 帧再断言
	var rect1w: Rect2 = panel.get_global_rect()
	var skill1w: Rect2 = hud._skill_btn.get_global_rect()
	_check("③右下档@960×1280：面板右沿 ≤ 技能键左沿（不压关键 HUD）",
		rect1w.end.x <= skill1w.position.x + 0.5,
		"panel=%s skill=%s" % [str(rect1w), str(skill1w)])
	tree.root.size = size0
	for _rz in range(3):
		await tree.process_frame
	# 2 左下（原位 R195 现几何逐位）
	Meta.set_setting("panel_pos", 2)
	await tree.process_frame
	var rect2: Rect2 = panel.get_global_rect()
	_check("③左下档：落位 x24-164×y998-1256（R197 竖两列；贴底 24/左沿 24 保持）",
		rect2.position == PANEL_RECT_POS2.position and rect2.size == PANEL_SIZE,
		"rect=%s" % str(rect2))
	# 设置页循环行：(cur+1)%3 一整圈（写即存 + HUD 随 settings_changed 即时重挂）；
	# 上文 rect2 校验后 panel_pos==2——从 2 起整圈 2→0→1→2 逐档验证
	_gl.settings_panel._on_panel_pos_cycle()
	_check("③循环①：2→0 回默认右上（Meta 写口 + HUD 即时重挂）",
		int(Meta.settings("panel_pos")) == 0 and panel.get_global_rect().position
		== PANEL_RECT_POS0.position)
	_gl.settings_panel._on_panel_pos_cycle()
	_check("③循环②：0→1 落位右下", int(Meta.settings("panel_pos")) == 1
		and panel.get_global_rect().position == PANEL_RECT_POS1.position)
	_gl.settings_panel._on_panel_pos_cycle()
	_check("③循环③：1→2 落位左下原位", int(Meta.settings("panel_pos")) == 2
		and panel.get_global_rect().position == PANEL_RECT_POS2.position)
	Meta.set_setting("panel_pos", 0)           # 拖动用例回到默认右上（面板在 POS0 域）
	await tree.process_frame
	# R197 竖两列结构契约：左列武器槽同 x、右列宝石同 x，宝石列在武器列右侧（防回退横排）
	var b_before: Array = []
	for kid in panel.get_children():
		b_before.append(kid)
	_gl.hud.call(&"_refresh_build")
	var b_content: Control = null
	for kid in panel.get_children():
		if not b_before.has(kid) and String(kid.name) != "BuildBg":
			b_content = kid                  # 刷新后新增唯一子 = 新 content（引用差集，同 verify R183 口径）
	var w_col_x := -1.0
	var g_col_x := -1.0
	var cols_same := true
	if b_content != null:
		for kid in b_content.get_children():
			var kn := String(kid.name)
			if kn.begins_with("Wpn"):
				if w_col_x < 0.0:
					w_col_x = (kid as Control).position.x
				elif absf((kid as Control).position.x - w_col_x) > 0.5:
					cols_same = false
			elif kn.begins_with("Gem"):
				if g_col_x < 0.0:
					g_col_x = (kid as Control).position.x
				elif absf((kid as Control).position.x - g_col_x) > 0.5:
					cols_same = false
	_check("③竖两列：武器列同 x + 宝石列同 x，宝石列在武器列右侧",
		b_content != null and cols_same and w_col_x >= 0.0
		and (g_col_x < 0.0 or g_col_x > w_col_x),
		"w=%s g=%s" % [str(w_col_x), str(g_col_x)])
	# 断触修复：结构面——面板底 MOUSE_FILTER_STOP → PASS（R196 契约变更）
	_check("③断触①：build_root.mouse_filter == PASS（STOP 吃拖动根因已除）",
		panel.mouse_filter == Control.MOUSE_FILTER_PASS)
	# 断触修复：行为面——ScreenDrag 穿越面板区，拖动累计不中断（player._unhandled_input 链）。
	# 投递走 root Window.push_input（同步全链：_input → GUI（build_root PASS 放行）→
	# unhandled）；位置用 canvas 域 + in_local_coords=true（窗口内容缩放不重标定 relative）
	var p := _gl.player
	p.input_enabled = true
	p.set("_drag_accum", Vector2.ZERO)
	p.set("_active_drag_index", -1)
	var drag := InputEventScreenDrag.new()
	drag.index = 0
	drag.position = PANEL_RECT_POS0.get_center()
	drag.relative = Vector2(12.0, 0.0)
	tree.root.push_input(drag, true)
	var accum: Vector2 = p.get("_drag_accum")
	_check("③断触②：面板区投递 ScreenDrag(rel=12,0) → player 拖动累计不中断",
		accum == Vector2(12.0, 0.0), "accum=%s" % str(accum))
	var drag2 := InputEventScreenDrag.new()
	drag2.index = 0
	drag2.position = PANEL_RECT_POS0.get_center() + Vector2(40.0, 20.0)   # 穿越面板（仍 PanelRect 内）
	drag2.relative = Vector2(5.0, 5.0)
	tree.root.push_input(drag2, true)
	accum = p.get("_drag_accum")
	_check("③断触③：穿越面板连续拖动累计连续（(17,5)——无断链/无吞事件）",
		accum == Vector2(17.0, 5.0), "accum=%s" % str(accum))


# ══ ④ 经验四色档位（白/绿/金/七彩） ═══════════════════════════════
func _test_4_xp_tiers() -> void:
	print("── ④ 经验面值四色档位（阈值→档位→颜色） ──")
	var thresholds_ok := XpShard.XP_TIER_THRESHOLDS.size() == 3 \
		and is_equal_approx(XpShard.XP_TIER_THRESHOLDS[0], 3.0) \
		and is_equal_approx(XpShard.XP_TIER_THRESHOLDS[1], 8.0) \
		and is_equal_approx(XpShard.XP_TIER_THRESHOLDS[2], 20.0)
	_check("④阈值表：XP_TIER_THRESHOLDS == [3.0, 8.0, 20.0]（单源 pickup）", thresholds_ok)
	_check("④映射：比 2.9→白 / 3.0→绿 / 7.9→绿 / 8.0→金 / 19.9→金 / 20.0→七彩",
		XpShard.xp_tier_of(2.9, 1.0) == 0 and XpShard.xp_tier_of(3.0, 1.0) == 1
		and XpShard.xp_tier_of(7.9, 1.0) == 1 and XpShard.xp_tier_of(8.0, 1.0) == 2
		and XpShard.xp_tier_of(19.9, 1.0) == 2 and XpShard.xp_tier_of(20.0, 1.0) == 3)
	_check("④降级：基线≤0 恒白档（旧调用/无通胀路径不崩）",
		XpShard.xp_tier_of(5.0, 0.0) == 0 and XpShard.xp_tier_of(5.0, -1.0) == 0)
	_check("④色源：白 fff1b8 / 绿 2ed573(SUCCESS) / 金 ffc93c(XP) 单源 PopPalette",
		PopPalette.xp_tier_color(0) == Color("fff1b8")
		and PopPalette.xp_tier_color(1) == Color("2ed573")
		and PopPalette.xp_tier_color(2) == Color("ffc93c"))
	_check("④色源：越界钳制（-1→白档色 / 9→占位色不崩）",
		PopPalette.xp_tier_color(-1) == Color("fff1b8")
		and PopPalette.xp_tier_color(9) == PopPalette.XP_TIER_COLORS[3])
	# 实件：掉落分档 + 满池合并重分档（基线取 max）
	_gl._spawn_xp_shard(Vector2(360.0, 300.0), 30.0, 1.0)
	var shard: XpShard = _gl.active_shards.back()
	_check("④实件：wave1 基线 1.0 投 30 面值 → 七彩档（≥20）",
		shard != null and shard.value == 30.0 and int(shard.get("_tier")) == 3)
	shard.merge_value(10.0, 0.0)
	_check("④实件：merge_value 面值 40、基线取 max 保持 1.0 → 仍七彩",
		shard.value == 40.0 and int(shard.get("_tier")) == 3)
	_gl._spawn_xp_shard(Vector2(500.0, 300.0), 5.0, 1.0)
	var shard2: XpShard = _gl.active_shards.back()
	_check("④实件：5/1.0 → 绿档（<8）", shard2 != null and int(shard2.get("_tier")) == 1)
	shard2.merge_value(50.0, 1.0)
	_check("④实件：合并爬档 55/1.0 → 重分档七彩（满池合并珠随面值爬档）",
		shard2.value == 55.0 and int(shard2.get("_tier")) == 3)
	_check("④通胀锚：exp_inflation_per_wave=1.085（balance_tables 真源连通）",
		GameConfig.balance != null
		and absf(float(GameConfig.balance.exp_inflation_per_wave) - 1.085) < 0.0001)


# ══ ⑤ 图鉴反应锁（未触发锁定 / 标记解锁 / 存档兼容） ══════════════
func _test_5_codex_reaction_lock() -> void:
	print("── ⑤ 图鉴反应锁（reaction_seen 标记 + 存档兼容） ──")
	Meta.reaction_seen = {}
	var rid: StringName = &"RXN_FIR_ICE"
	_check("⑤读口：未标记 is_reaction_seen 假", not Meta.is_reaction_seen(rid))
	var menu: MenuScreen = _gl.menu_screen
	var note: Dictionary = GameConst.reaction_note(String(rid))
	_check("⑤文案：解锁关提示单源 GameConst.reaction_note().unlock 非空（含关数）",
		String(note.get("unlock", "")).length() > 0, String(note.get("unlock", "")))
	# 未标记 → 锁定行（R196：锁定只改样式不改行集合）——必须先建行后标记
	var row_locked: Control = menu._make_codex_reaction_row(int(GameConst.ReactionType.RXN_FIR_ICE))
	var badge := row_locked.find_child("RxnLockBadge", true, false) as TextureRect
	var lock_note := row_locked.find_child("RxnLockNote", true, false) as Label
	_check("⑤锁定行：降透明 0.55 + 锁徽贴纸（ui_lock 非 emoji 字面量）+「未触发」小字",
		absf(row_locked.modulate.a - 0.55) < 0.01 and badge != null
		and badge.texture != null and badge.texture == TextureFactory.ui_lock()
		and lock_note != null and lock_note.text == "未触发")
	_check("⑤标记：mark 首见真 + 幂等（二标假）",
		Meta.mark_reaction_seen(rid) and not Meta.mark_reaction_seen(rid))
	_check("⑤读口：标记后 is_reaction_seen 真", Meta.is_reaction_seen(rid))
	# 标记 → 解锁行（同参重建无锁件）
	var row_open: Control = menu._make_codex_reaction_row(int(GameConst.ReactionType.RXN_FIR_ICE))
	_check("⑤解锁行：modulate 恢复 1.0、无 RxnLockBadge/RxnLockNote（行集合不变仅样式）",
		absf(row_open.modulate.a - 1.0) < 0.01
		and row_open.find_child("RxnLockBadge", true, false) == null
		and row_open.find_child("RxnLockNote", true, false) == null)
	# 持久化：codex/reaction_seen 键集落盘（settings 段 panel_pos 同批验证——R196 两新键）
	Meta.set_setting("panel_pos", 1)
	Meta._save()
	var cfg := ConfigFile.new()
	cfg.load(Meta.save_path())
	var saved_rxn: Array = cfg.get_value("codex", "reaction_seen", [])
	var saved_vals: Dictionary = cfg.get_value("settings", "values", {})
	_check("⑤落盘：codex/reaction_seen 含 RXN_FIR_ICE + settings/values 含 panel_pos",
		saved_rxn.has("RXN_FIR_ICE") and saved_vals.has("panel_pos"),
		"rxn=%s vals_keys=%s" % [str(saved_rxn), str(saved_vals.keys())])
	# 存档兼容：旧档无 reaction_seen/panel_pos 键 → _load 空表 + 默认 0，不炸（结构禁改；
	# _load 对各字典为累积回填（同 codex_weapons 口径）——测试先清零再载模拟首启旧档）
	var sfx_before: float = float(saved_vals.get("sfx_volume", 0.8))
	saved_vals.erase("panel_pos")
	cfg.set_value("settings", "values", saved_vals)
	cfg.erase_section_key("codex", "reaction_seen")
	cfg.save(Meta.save_path())
	Meta.reaction_seen = {}
	Meta._load()
	_check("⑤旧档兼容：缺 reaction_seen 键 → 空表（降级不崩）",
		Meta.reaction_seen.is_empty())
	_check("⑤旧档兼容：缺 panel_pos 键 → 读口回默认 0（SETTINGS_DEFAULTS 回退）",
		int(Meta.settings("panel_pos")) == 0)
	_check("⑤旧档兼容：settings 段结构不变（其余键原值保留）",
		absf(float(Meta.settings("sfx_volume")) - sfx_before) < 0.0001)
	# 写口归一（DataValidator 口径）：越档值 clamp 0..2
	Meta.set_setting("panel_pos", 7)
	_check("⑤写口归一：panel_pos=7 → clamp 2；负值 → clamp 0",
		int(Meta.settings("panel_pos")) == 2)
	Meta.set_setting("panel_pos", -3)
	_check("⑤写口归一②：-3 → 0", int(Meta.settings("panel_pos")) == 0)


# ══ ⑦ 手枪词条家族（修复后契约：pistol_trait_family RC1/RC3b） ════
func _spawn_e(p_pos: Vector2, p_hp: float = 1000000.0) -> Node2D:
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(_gl.registry.get_enemy(&"E1_grunt"), 1, 0)
	enemy.set("speed", 0.0)
	enemy.set("max_hp", p_hp)
	enemy.set("hp", p_hp)
	enemy.global_position = p_pos
	_gl.spawner.active.append(enemy)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	return enemy


func _clear_all() -> void:
	var snapshot: Array = (_gl.pools[&"projectile"] as ProjectilePool) \
		.active_projectiles().duplicate()
	for p in snapshot:
		if p is ProjectileBase:
			(p as ProjectileBase).nullify()
	for e in _gl.spawner.active.duplicate():
		_gl.spawner.active.erase(e)
		(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_gl.enemy_grid.rebuild(_gl.spawner.active)


func _player_bullets() -> Array:
	var out: Array = []
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		if p is ProjectileBase and (p as ProjectileBase).team == 0:
			out.append(p)
	return out


func _max_spread_deg() -> float:
	var bs := _player_bullets()
	if bs.size() < 2:
		return 0.0
	var worst := 0.0
	for i in range(bs.size()):
		for j in range(bs.size()):
			worst = maxf(worst, rad_to_deg(absf(angle_difference(
				(bs[i] as ProjectileBase).velocity.angle(),
				(bs[j] as ProjectileBase).velocity.angle()))))
	return worst


func _all_forward() -> bool:
	for b in _player_bullets():
		var dev := rad_to_deg(absf(angle_difference(-PI / 2.0,
			(b as ProjectileBase).velocity.angle())))
		if dev >= 90.0:
			return false
	return true


func _spawn_collinear_triple(p_w: WeaponBase, p_hp1: float) -> Array:
	# 共线三敌夹具（探针 C1 几何的鲁棒化）：E1/E2/E3 沿「当前枪口正上方」同轴排列——
	# 瞄准最近敌 E1 → 弹道直线贯穿 E2/E3（枪口随化身公转角漂移，探针原固定坐标仅在
	# 枪口恰在玩家正上时共线——本夹具按 fire 时刻 muzzle_position 现算，任意公转角成立）
	var m: Vector2 = p_w.muzzle_position()
	var e1 := _spawn_e(m + Vector2(0.0, -140.0), p_hp1)
	var e2 := _spawn_e(m + Vector2(0.0, -340.0))
	var e3 := _spawn_e(m + Vector2(0.0, -580.0))
	return [e1, e2, e3]


func _test_7_pistol_family() -> void:
	print("── ⑦ 手枪：多重装填实发可辨 + 穿透逐目标贯穿（修复后契约） ──")
	# 复位玩家（③拖动用例会位移玩家/占用拖动锁——弹道几何钉死 (360,900) 前向）
	_gl.player.global_position = Vector2(360.0, 900.0)
	_gl.player.input_enabled = true
	_gl.player.set("_drag_accum", Vector2.ZERO)
	_gl.player.set("_active_drag_index", -1)
	# A 多重装填（RC1 修复验收）：L1 + AFF_MULTI → 实发 2 弹且弹间可辨
	_clear_all()
	var w := _fresh_pistol(0, 1)
	if w == null:
		_check("⑦A 前置：装配", false)
		return
	w.attach_trait(_gl.registry.get_trait(&"AFF_MULTI"))
	_check("⑦A：_pellet_count==2（聚合链生效）", int(w.call("_pellet_count")) == 2,
		"_pellet_count=%d" % int(w.call("_pellet_count")))
	seed(42)
	w.try_fire()
	var bs := _player_bullets()
	_check("⑦A：实发 2 弹", bs.size() == 2, "实发 %d" % bs.size())
	# R196 FIX-1 契约变更：编队退化（L1 gap=0/converge=0）回落逐丸锥形分布——原探针
	# A2「两弹完全重合=视觉单发」根因断言随修复退役（r196_pistol_trait_probe_cases.gd
	# 旧断言按定案应改写翻绿，本套件按修复后契约正向锁定）
	_check("⑦A：两弹可辨（速度散角>0.1°——不再像素重合）", _max_spread_deg() > 0.1,
		"散角 %.2f°" % _max_spread_deg())
	_check("⑦A：无背向弹（全弹偏角<90°）", _all_forward())
	_clear_all()
	# B 穿透逐目标贯穿（RC3b 修复验收）：pierce=2 → E1 恰 1 击、E2 贯穿、E3 金丝雀
	var w2 := _fresh_pistol(1, 1)
	w2.attach_trait(_gl.registry.get_trait(&"AFF_PIERCE"))
	_check("⑦B：_pierce_count==2（1+1）", int(w2.call("_pierce_count")) == 2)
	var triple := _spawn_collinear_triple(w2, 1000000.0)
	var e1: Node2D = triple[0]
	var e2: Node2D = triple[1]
	var e3: Node2D = triple[2]
	seed(42)
	w2.try_fire()
	bs = _player_bullets()
	_check("⑦B：实发 1 弹且方向朝前（偏角<30°——无「往后面射」）",
		bs.size() == 1 and _all_forward()
		and rad_to_deg(absf(angle_difference(-PI / 2.0,
			(bs[0] as ProjectileBase).velocity.angle()))) < 30.0)
	for i in range(90):
		GameConfig.advance_frame()
		for b in _player_bullets().duplicate():
			(b as ProjectileBase).tick(DT)
		if _player_bullets().is_empty():
			break
	var dmg1 := float(e1.get("max_hp")) - float(e1.get("hp"))
	var dmg2 := float(e2.get("max_hp")) - float(e2.get("hp"))
	var dmg3 := float(e3.get("max_hp")) - float(e3.get("hp"))
	_check("⑦B：首敌命中（实伤>0）", dmg1 > 0.0, "dmg1=%.1f" % dmg1)
	# R196 FIX-2 契约变更（原 pkg2_cases「pierce=3 同敌多跳耗尽回收」语义退役）：
	# 生命周期级逐目标已命中表——同敌不重击耗预算，预算花在换目标上
	_check("⑦B：★贯穿第 2 敌成立（pierce=2 → E1 1 击 + E2 受伤——修复前 E2 恒零伤）",
		dmg2 > 0.0, "dmg2=%.1f" % dmg2)
	_check("⑦B：金丝雀满血（预算恰尽——无超发）", dmg3 == 0.0, "dmg3=%.1f" % dmg3)
	_clear_all()
	# C 命中即杀对照保持（E-06 死亡短路贯穿——C2 已证基线不回归）
	var w3 := _fresh_pistol(2, 1)
	w3.attach_trait(_gl.registry.get_trait(&"AFF_PIERCE"))
	var ktriple := _spawn_collinear_triple(w3, 10.0)
	var k1: Node2D = ktriple[0]
	var k2: Node2D = ktriple[1]
	seed(42)
	w3.try_fire()
	for i in range(90):
		GameConfig.advance_frame()
		for b in _player_bullets().duplicate():
			(b as ProjectileBase).tick(DT)
		if _player_bullets().is_empty():
			break
	_check("⑦C：首敌被杀（hp=10 < 14）", bool(k1.get("dead")))
	_check("⑦C：命中即杀时贯穿第 2 敌成立（击杀门控基线不回归）",
		float(k2.get("max_hp")) - float(k2.get("hp")) > 0.0)
	_clear_all()
	# D 面板反馈（FIX-1 配套）：弹道武器属性行含「弹丸 N」且数值==_pellet_count
	var line: String = _gl.pause_overlay._weapon_stat_line(w)
	var expect := "弹丸 %d" % int(w.call("_pellet_count"))
	_check("⑦D：暂停面板属性行含「弹丸 2」（多重装填可视化，has_method 守卫口径）",
		line.contains(expect), "line=%s" % line)
	var w9 := OrbitWeapon.new()
	tree.root.add_child(w9)
	w9.setup(_gl.registry.get_weapon(&"W9_arc_slash"), null, {})
	var line_melee: String = _gl.pause_overlay._weapon_stat_line(w9)
	_check("⑦D：近战武器不列「弹丸 0」误导段（显示不能乱）",
		not line_melee.contains("弹丸"), "line=%s" % line_melee)
	w9.queue_free()


# ══ ⑥ 武器准入门（wunlock 定案：门=大关派生，UI 读取与数据源一致） ══
func _expected_allowed_set(p_idx: int) -> Array[StringName]:
	# 数据源真值：矩阵允许集（weapon_unlock_map_index ≤ p_idx）；未登记 → 0 恒开放
	var out: Array[StringName] = []
	for wid_v: Variant in _gl.registry.weapons.keys():
		var wid := StringName(String(wid_v))
		if MechanicGate.weapon_unlock_map_index(wid) <= p_idx:
			out.append(wid)
	return out


func _same_set(p_a: Array[StringName], p_b: Array[StringName]) -> bool:
	if p_a.size() != p_b.size():
		return false
	for x in p_a:
		if not p_b.has(x):
			return false
	return true


func _test_6_weapon_gate() -> void:
	print("── ⑥ 武器准入门（矩阵/逐关上架/图鉴三态/echo 同门/首发守卫） ──")
	_check("⑥矩阵：W1/W2/W3→0 · W4/W5→1 · W6/W7→2 · W8/W9→3 · W10→4",
		MechanicGate.weapon_unlock_map_index(&"W1_pistol") == 0
		and MechanicGate.weapon_unlock_map_index(&"W2_gatling") == 0
		and MechanicGate.weapon_unlock_map_index(&"W3_shotgun") == 0
		and MechanicGate.weapon_unlock_map_index(&"W4_pulse_beam") == 1
		and MechanicGate.weapon_unlock_map_index(&"W5_prism") == 1
		and MechanicGate.weapon_unlock_map_index(&"W6_micro_missile") == 2
		and MechanicGate.weapon_unlock_map_index(&"W7_cluster_rocket") == 2
		and MechanicGate.weapon_unlock_map_index(&"W8_orbit_field") == 3
		and MechanicGate.weapon_unlock_map_index(&"W9_arc_slash") == 3
		and MechanicGate.weapon_unlock_map_index(&"W10_boomerang") == 4)
	_check("⑥矩阵：未登记 id → 0 恒开放（新武器入库漏登记不上锁）",
		MechanicGate.weapon_unlock_map_index(&"W_UNREGISTERED") == 0)
	# 无局态全开（既有验收基线不受扰）
	Meta.set_run_map(&"")
	var all_open := true
	for wid_v: Variant in _gl.registry.weapons.keys():
		all_open = all_open and MechanicGate.weapon_allowed(StringName(String(wid_v)))
	_check("⑥无局全开：map_index==-1 → 全武器 weapon_allowed 真", all_open)
	# 逐关上架矩阵：_weapon_candidates 恰等于「矩阵允许集 − 已持有」（P2 探针口径）
	var gen := CardGenerator.new()
	gen.setup(_gl.registry)
	for idx in range(MapTable.count()):
		_set_map_idx(idx)
		var cands: Array[WeaponData] = gen._weapon_candidates(_gl.player)
		var cand_ids: Array[StringName] = []
		for wd in cands:
			cand_ids.append(StringName(String(wd.id)))
		var expected := _expected_allowed_set(idx)
		var owned_expected: Array[StringName] = []
		for wid in expected:
			if StringName("W1_pistol") != wid:        # 玩家开局持有 W1（owned 唯一员）
				owned_expected.append(wid)
		_check("⑥第%d关上架集：恰等于矩阵允许集−已持有（越门武器 0 命中）" % (idx + 1),
			_same_set(cand_ids, owned_expected),
			"cands=%s expected=%s" % [str(cand_ids), str(owned_expected)])
	# MAP_INTROS 与矩阵同步（T4「两处保持同步」纪律）
	_check("⑥文案同步：第1关「初始武器批」/第2关脉冲光束/第3关微型导弹/第4关环绕力场/第5关回旋刃",
		MechanicGate.intro_for_map(0).contains("初始武器批")
		and MechanicGate.intro_for_map(1).contains("脉冲光束")
		and MechanicGate.intro_for_map(2).contains("微型导弹")
		and MechanicGate.intro_for_map(3).contains("环绕力场")
		and MechanicGate.intro_for_map(4).contains("回旋刃"))
	# 图鉴三态「未解锁」句单源（UI 禁手抄）
	_check("⑥锁定句：W10 →「通关『翡翠树海』后开放」（MapTable 真源）；W1 → 初始批句",
		MechanicGate.weapon_locked_line(&"W10_boomerang") == "通关「翡翠树海」后开放"
		and MechanicGate.weapon_locked_line(&"W1_pistol").contains("初始武器批"),
		MechanicGate.weapon_locked_line(&"W10_boomerang"))
	# 抽卡闭环（P3 收口）：写口 mark_weapon_codex 不设门——候选上架才可被抽，门自然收口
	_set_map_idx(3)
	Meta.mark_weapon_codex(&"W8_orbit_field")
	_check("⑥写口：mark_weapon_codex 后 is_weapon_unlocked 翻真（获得解锁语义不变）",
		Meta.is_weapon_unlocked(&"W8_orbit_field"))
	Meta.set_run_map(&"")
	# 图鉴三态 UI 行（menu_screen 消费面）：行集合 10 不变，锁定行=门未开且未获得
	# R196 评审修复：三态门态改进度派生（weapon_allowed_progress = cleared_count）
	# ——本段钉 maps_cleared 空（进度=第 1 关，与 _set_map_idx(0) 同语境），防其它
	# 用例/套件 maps 段残留串扰；收尾还原
	_snap_maps_cleared = Meta.maps_cleared.duplicate()
	Meta.maps_cleared = {}
	_set_map_idx(0)
	Meta.mark_weapon_codex(&"W8_orbit_field")     # 门外已获得（P6：获得优先于门，老档无损）
	var menu: MenuScreen = _gl.menu_screen
	menu._codex_tab = "武器"
	menu._rebuild_codex()
	var rows: Array = []
	for c in menu._panel_list.get_children():
		if c is Panel and not (c as Node).is_queued_for_deletion():
			rows.append(c)
	var locked_rows: Array = []
	for r: Panel in rows:
		if absf(r.modulate.a - 0.55) < 0.01:
			locked_rows.append(r)
	# 「未解锁」态行 = 锁定样式 ∧ 名称 ？？？（未获得且门外——W4/W5/W6/W7/W9/W10 共 6 行）
	var locked_q_rows: Array = []
	var badge_ok := true
	for r: Panel in locked_rows:
		var q_found := false
		for sub in r.get_children():
			if sub is Label and (sub as Label).text == "？？？":
				q_found = true
		if q_found:
			locked_q_rows.append(r)
		if (r.find_child("WeaponLockBadge", true, false) as TextureRect) == null:
			badge_ok = false
	_check("⑥图鉴三态：第1关行集合 10 行（行数口径不变）", rows.size() == 10,
		"rows=%d" % rows.size())
	_check("⑥图鉴三态：未获得且门外 6 行「未解锁」态（？？？+锁徽+压暗）",
		locked_q_rows.size() == 6 and badge_ok,
		"locked=%d ？？？=%d badge_ok=%s" % [locked_rows.size(), locked_q_rows.size(), str(badge_ok)])
	# W8 已获得 → 门外仍按「已获得」态展示（wunlock P6：获得优先于门，老档 10/10 无损）
	var w8_got_ok := false
	for r: Panel in rows:
		if absf(r.modulate.a - 1.0) < 0.01 and r.find_child("WeaponLockBadge", true, false) == null:
			for sub in r.get_children():
				if sub is Label and (sub as Label).text == "环绕力场":
					w8_got_ok = true
	_check("⑥[定案 P6] 获得优先于门：门外已获得 W8 行应为已获得态（显示名+无锁徽+不压暗）",
		w8_got_ok)
	# R196 评审修复锁定：进度门正向语义——通关第 1 关（晴空草原）→ W4 可获取，
	# W8（第 4 关起）仍门外；门态真源 = cleared_count 不随上局 run_map 漂移
	Meta.maps_cleared = {String(MapTable.MAPS[0].id): true}
	_check("⑥进度门：通关晴空草原 → weapon_allowed_progress(W4) 真 / W8 仍假",
		MechanicGate.weapon_allowed_progress(&"W4_pulse_beam")
			and not MechanicGate.weapon_allowed_progress(&"W8_orbit_field"))
	Meta.maps_cleared = _snap_maps_cleared        # 进度还原（防跨用例/跨套件串扰）
	# R196 评审修复锁定：首发候选「获得优先于门」——候选过滤不再按门态滤已获得武器
	# （原 run_map 残留把老档 10 把缩到 3 把 + 循环钮静默降级首发落盘）；W8 已获得
	# 且进度门外仍入选，W1 白名单恒在
	var cands6: Array[StringName] = menu._custom_weapon_candidates()
	_check("⑥首发候选：已获得∧门外 W8 仍入选（获得优先于门——老档无损）",
		cands6.has(&"W8_orbit_field") and cands6.has(&"W1_pistol"),
		"cands=%s" % [cands6])
	Meta.set_run_map(&"")
	# echo 双武装同门（P4）：固定 seed → 双武器均门内 + 池空回退双首发不空手
	_gl.player.character_id = &"echo"
	_set_map_idx(0)
	_gl._grant_random_dual_loadout(7)
	var s0 := _gl.player.weapon_slots[0] as WeaponBase
	var s1 := _gl.player.weapon_slots[1] as WeaponBase
	_check("⑥echo：双持不空手（槽 0/1 均装配）", s0 != null and s1 != null)
	if s0 != null and s1 != null:
		var id0 := StringName(String((s0.get("data") as WeaponData).id))
		var id1 := StringName(String((s1.get("data") as WeaponData).id))
		_check("⑥echo：双武器均 weapon_allowed（第1关门内集）且 ≠W1（门内池排除首发）",
			MechanicGate.weapon_allowed(id0) and MechanicGate.weapon_allowed(id1)
			and id0 != &"W1_pistol" and id1 != &"W1_pistol",
			"%s+%s" % [String(id0), String(id1)])
	# 槽位门护栏（防武器门与槽位门串扰）：双持占满 2 槽（unlocked_slots=2）→ 候选空
	Meta.set_run_map(&"")
	_gl.player.set("unlocked_slots", 2)
	_check("⑥槽位门独立：槽满（无空槽）→ 武器候选空（与门开关无关）",
		gen._weapon_candidates(_gl.player).is_empty())
	_gl.player.set("unlocked_slots", 6)
	# 首发守卫（P5）：门外 id 拒写；已获得 id 放行（set_custom_weapon 不落盘不脏档）
	Meta.reset_weapon_codex()
	var custom_before := String(Meta.custom_weapon_id)
	Meta.set_custom_weapon(&"W10_boomerang")
	_check("⑥首发守卫：未解锁 W10 写口被拒（custom_weapon 不变）",
		String(Meta.custom_weapon_id) == custom_before)
	Meta.mark_weapon_codex(&"W10_boomerang")
	Meta.set_custom_weapon(&"W10_boomerang")
	_check("⑥首发守卫：已获得后放行（获得优先于门——老档无损）",
		Meta.custom_weapon() == &"W10_boomerang")
	Meta.custom_weapon_id = custom_before       # 还原（快照恢复前先回本局口径）


# ══ ⑧ 图标审计（apk_menu_no_icons 定案 P1/P4 口径） ═══════════════
func _tex_has_alpha_pixel(p_tex: ImageTexture) -> bool:
	var img := p_tex.get_image()
	for x in range(0, img.get_width(), 4):
		for y in range(0, img.get_height(), 4):
			if img.get_pixel(x, y).a > 0.01:
				return true
	return false


func _scan_high_codepoints(p_dir: String, p_hits: Array) -> void:
	var da := DirAccess.open(p_dir)
	if da == null:
		return
	da.list_dir_begin()
	var fname := da.get_next()
	while fname != "":
		var path := p_dir.path_join(fname)
		if da.current_is_dir() and not fname.begins_with("."):
			_scan_high_codepoints(path, p_hits)
		elif fname.ends_with(".gd"):
			var text := FileAccess.get_file_as_string(path)
			for i in range(text.length()):
				if text.unicode_at(i) > 0xFFFF:
					p_hits.append("%s:%d" % [path, i])
					break
		fname = da.get_next()
	da.list_dir_end()


func _test_8_icon_audit() -> void:
	print("── ⑧ 图标资源审计（贴纸在位/互异/emoji 字面量闸门） ──")
	_check("⑧贴纸：ui_lock/ui_gem/ui_trophy 非空", TextureFactory.ui_lock() != null
		and TextureFactory.ui_gem() != null and TextureFactory.ui_trophy() != null)
	_check("⑧贴纸：三枚程序贴纸均含可见像素（alpha>0）",
		_tex_has_alpha_pixel(TextureFactory.ui_lock())
		and _tex_has_alpha_pixel(TextureFactory.ui_gem())
		and _tex_has_alpha_pixel(TextureFactory.ui_trophy()))
	# 10 武器图标非空 + 两两互异（r187_rework_cases 先例口径）
	var icon_hashes: Array = []
	var icons_ok := true
	for wid_v: Variant in _gl.registry.weapons.keys():
		var tex := TextureFactory.weapon_icon(StringName(String(wid_v)))
		if tex == null:
			icons_ok = false
			continue
		icons_ok = icons_ok and _tex_has_alpha_pixel(tex)
		icon_hashes.append(hash(tex.get_image().get_data()))
	var dup := false
	for a in range(icon_hashes.size()):
		for b in range(a + 1, icon_hashes.size()):
			if icon_hashes[a] == icon_hashes[b]:
				dup = true
	_check("⑧武器图标：全 10 枚非空且含可见像素", icons_ok and icon_hashes.size() == 10,
		"count=%d" % icon_hashes.size())
	_check("⑧武器图标：像素两两互异（无重图）", not dup)
	# 消费接线：menu_screen/hud 源级引用新贴纸（emoji 位已换贴纸；地图/提示行按定案
	# 「删符号不动词」——🏆/🔒 前缀移除不补贴纸为可选支，ui_trophy 无强制消费点）
	var menu_src := FileAccess.get_file_as_string("res://scripts/ui/menu_screen.gd")
	var hud_src := FileAccess.get_file_as_string("res://scripts/ui/hud.gd")
	_check("⑧消费接线：menu_screen 引用 ui_lock + ui_gem（R196 T2 替换面）",
		menu_src.contains("TextureFactory.ui_lock()")
		and menu_src.contains("TextureFactory.ui_gem()"))
	_check("⑧消费接线：hud 引用 ui_lock（R196 T3 替换面）",
		hud_src.contains("TextureFactory.ui_lock()"))
	_check("⑧文案：解锁提示删 🏆 前缀词义保留（「　通关「%s」解锁」）",
		menu_src.contains("通关「%s」解锁") and not menu_src.contains("🏆"))
	_check("⑧文案：成就 toast 删 🏆/💎（主体保留「成就达成 ×%d」）",
		hud_src.contains("成就达成 ×%d：%s") and not hud_src.contains("🏆")
		and not hud_src.contains("💎"))
	# 源码卫生闸门（P1）：scripts + autoload 全 .gd 零 >0xFFFF 码点（emoji 字面量禁入）
	var hits: Array = []
	_scan_high_codepoints("res://scripts", hits)
	_scan_high_codepoints("res://autoload", hits)
	_check("⑧emoji 闸门：scripts/autoload 全 .gd 零 >0xFFFF 码点（Android 缺字根因永久闸）",
		hits.is_empty(), str(hits))
	# 零污染护栏（P8）：headless 存档路径断言测试档（真实档零接触）
	_check("⑧零污染：headless save_path == meta_save_test.cfg（测试档隔离）",
		Meta.save_path() == "user://meta_save_test.cfg")

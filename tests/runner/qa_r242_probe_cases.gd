# tests/runner/qa_r242_probe_cases.gd
# R242 QA 探针用例体（probe_r242_qa.gd 入口运行期 load——零编译期工程类直引纪律）。
# 静态审查疑点实证（只读产品码，零修改）：
#   S1  R242b 复刻：默认图（world_grass）下 3/3 金品词条名字色（MechanicGate 门态取证）
#   S2  R242c 复刻：AFF_GOLD stack_max=2 → far_is_near 恒真（断言空转取证）
#   S3  混号词条（描述 -N%、value 正存）2 层改写符号（AFF_CDR/AFF_SKILL_HASTE/MEC_SLASH_TEMPO）
#   S4  r188_idle_cases ⑧f 旧断言复刻（"攻击 +10%" + 负值 2 层 → 是否仍逐字不变）
#   S5  卡面名字色 override：诅咒×质变同卡压序 + 跨 open 残留（stale override）
#   S6  compose_desc_text 诅咒尾行（信息性打印）
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree = null
var _fail: int = 0
var _gl: GameLoop = null
var _overlay: PauseOverlay = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot()
	_s1_r242b_gate()
	_s2_r242c_vacuous()
	_s3_mixed_sign_rewrite()
	_s4_r188_old_assert()
	_s5_card_name_override()
	_s6_compose_info()
	_teardown()
	print("────────────────────────────────────────")
	print("R242 QA 探针汇总：FAIL %d" % _fail)


func fail_count() -> int:
	return _fail


func _boot() -> void:
	RunSave.clear()
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "QaR242Loop"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_check("Boot：MENU 且默认图未改（world_grass）",
		_gl.current_map_id == MapTable.FIRST_MAP_ID)
	_gl.start_run()
	print("[S0] MechanicGate.map_index()=%d milestone_unlocked()=%s run_map=%s"
		% [MechanicGate.map_index(), str(MechanicGate.milestone_unlocked()),
			String(Meta.run_map_id())])


func _teardown() -> void:
	tree.paused = false
	RunSave.clear()
	Meta.set_run_map(MapTable.FIRST_MAP_ID)
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.free()
	if _gl != null:
		_gl.free()


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		print("FAIL | %s | %s" % [p_name, p_detail])


# ── S1：R242b 复刻（verify_feedback_cases.gd:636-639 同态） ─────────
func _s1_r242b_gate() -> void:
	print("── S1 R242b 复刻：3/3 金品词条名字色（默认图门态） ──")
	var w: WeaponBase = _gl.player.weapon_slots[0]
	var crit_t: TraitData = _gl.registry.get_trait(&"AFF_CRIT_RATE")
	w.attach_trait(crit_t)
	w.attach_trait(crit_t)
	var gold_t: TraitData = crit_t.duplicate()
	gold_t.rarity = 3
	w.attach_trait(gold_t)
	_gl.pause_overlay._on_state_changed(GameConst.GameStatus.PAUSED)
	_gl.pause_overlay.open_details(_gl.player, [])
	var lbl: Label = _find_label_by_text(_gl.pause_overlay._details_list, "◆金")
	var col: Color = lbl.get_theme_color("font_color") if lbl != null else Color.BLACK
	print("[S1] label=%s color=%s GOLD=%s INK=%s gate=%s"
		% [str(lbl.text if lbl != null else "<null>"), str(col),
			str(PopPalette.GOLD), str(PopPalette.INK),
			str(MechanicGate.milestone_unlocked())])
	_check("S1 信息：3/3 金品词条名字色（判定见输出——verify R242b 断言 GOLD）",
		lbl != null, "color=%s" % str(col))
	# 断言实证：门关时名字=INK → verify_feedback R242b（期望 GOLD）必红
	if not MechanicGate.milestone_unlocked():
		_check("S1 判定：门关（默认图）→ 名字 INK 非 GOLD → verify R242b 必红",
			col == PopPalette.INK, "color=%s" % str(col))
	else:
		_check("S1 判定：门开 → 名字 GOLD（R242b 绿）", col == PopPalette.GOLD,
			"color=%s" % str(col))
	_gl.pause_overlay._on_state_changed(GameConst.GameStatus.MENU)
	_gl.pause_overlay._details_mode = false


# ── S2：R242c 空转取证（AFF_GOLD stack_max=2 → far_is_near 恒真） ──
func _s2_r242c_vacuous() -> void:
	print("── S2 R242c 复刻：远质变断言空转取证 ──")
	var far_t: TraitData = _gl.registry.get_trait(&"AFF_GOLD")
	var far_max := int(far_t.get("stack_max"))
	var far_layers := 1
	var far_is_near: bool = far_layers >= far_max - 1
	var w: WeaponBase = _gl.player.weapon_slots[0]
	w.attach_trait(far_t)
	_gl.pause_overlay._on_state_changed(GameConst.GameStatus.PAUSED)
	_gl.pause_overlay.open_details(_gl.player, [])
	var lbl: Label = _find_label_by_text(_gl.pause_overlay._details_list, "点金")
	print("[S2] AFF_GOLD stack_max=%d layers=1 far_is_near=%s（true=断言 or 分支空转）label=%s"
		% [far_max, str(far_is_near), str(lbl.text if lbl != null else "<null>")])
	_check("S2 判定：far_is_near 恒真 → R242c 颜色断言空转（假绿）",
		far_is_near, "stack_max=%d" % far_max)
	_gl.pause_overlay._on_state_changed(GameConst.GameStatus.MENU)
	_gl.pause_overlay._details_mode = false


# ── S3：混号词条符号反转（描述 -N% + value 正存） ─────────────────
func _mk_tb(p_td: TraitData, p_layers: int) -> TraitBase:
	var tb := TraitBase.new()
	tb.setup(p_td)
	tb.layers = p_layers
	var vals: Array[float] = []
	for i in range(p_layers):
		vals.append(float(p_td.value))
	tb.layer_values = vals
	return tb


func _s3_mixed_sign_rewrite() -> void:
	print("── S3 混号词条（描述 -N%、value 正存）≥2 层改写符号 ──")
	if _overlay == null:
		_overlay = PauseOverlay.new()            # 不进树：纯函数段
	if _overlay == null or not is_instance_valid(_overlay):
		_check("S3 前置：PauseOverlay 实例", false, "")
		return
	for tid in [&"AFF_CDR", &"AFF_SKILL_HASTE", &"MEC_SLASH_TEMPO"]:
		var td0: TraitData = _gl.registry.get_trait(tid)
		if td0 == null:
			_check("S3 前置：%s 在注册表" % String(tid), false, "")
			continue
		var sm := int(td0.get("stack_max"))
		var n := mini(2, sm)
		var out := _overlay._trait_desc_bbcode(_mk_tb(td0, n))
		var desc := String(td0.description)
		print("[S3] %s | value=%s 层=%d/%d" % [String(tid), str(td0.value), n, sm])
		print("[S3]   原: " + desc)
		print("[S3]   改: " + out)
		# 语义：描述负号形态（收益=减少），改写后应保持负号「-N%」；
		# 若出现「+N%」即符号反转（读作间隔/冷却增加=负收益）
		var bad := false
		for seg in out.split("[b]"):
			if seg.begins_with("+"):
				bad = true
		_check("S3 判定：%s %d 层改写不出现「+N%」（负号形态保持）" % [String(tid), n],
			not bad, out)
	_gl.pause_overlay._on_state_changed(GameConst.GameStatus.MENU)


# ── S4：r188_idle_cases ⑧f 旧断言复刻 ─────────────────────────────
func _s4_r188_old_assert() -> void:
	print("── S4 r188⑧f 复刻：攻击 +10% + 负值×2 → 是否仍逐字不变 ──")
	if _overlay == null:
		_overlay = PauseOverlay.new()
	var td := TraitData.new()
	td.id = &"QA_R242_NEG"
	td.display_name = "qa_neg"
	td.description = "攻击 +10%"
	td.pool = GameConst.PoolClass.ADD
	td.pool_id = &"add_atk"
	td.effect_id = &"EF_STAT"
	td.value = -0.10
	td.stack_max = 99
	var out := _overlay._trait_desc_bbcode(_mk_tb(td, 2))
	print("[S4]   原: 攻击 +10%")
	print("[S4]   改: " + out)
	_check("S4 判定：改写发生（≠原文）→ r188_idle_cases ⑧f 旧断言（==原文）必红",
		out != "攻击 +10%", out)


# ── S5：卡面名字色 override 压序 + 跨 open 残留 ───────────────────
func _mk_card(p_name: String, p_cursed: bool, p_milestone: bool) -> Dictionary:
	return {"kind": 2, "id": &"QA_CARD", "rarity": 0, "value_scale": 1.0,
		"data": null, "display_name": p_name, "description": "探针描述 +10%",
		"milestone": p_milestone, "cursed": p_cursed}


func _face_name_color(p_ui: CardSelectUI, p_slot: int) -> Color:
	var lbl: Label = p_ui._card_faces[p_slot]["name"]
	return lbl.get_theme_color("font_color")


func _s5_card_name_override() -> void:
	print("── S5 卡面名字色：诅咒压质变 + 跨 open 残留 ──")
	var ui: CardSelectUI = _gl.card_select_ui
	# 货架 A：槽0 质变、槽1 质变+诅咒、槽3 诅咒
	var shelf_a: Array[Dictionary] = [
		_mk_card("A0质变", false, true),
		_mk_card("A1质变诅咒", true, true),
		_mk_card("A2普通", false, false),
		_mk_card("A3诅咒", true, false),
	]
	ui.open(shelf_a, false)
	var c0 := _face_name_color(ui, 0)
	var c1 := _face_name_color(ui, 1)
	var c3 := _face_name_color(ui, 3)
	print("[S5] 货架A 槽0(质变)=%s 槽1(质变+诅咒)=%s 槽3(诅咒)=%s"
		% [str(c0), str(c1), str(c3)])
	_check("S5① 质变卡名字 GOLD", c0 == PopPalette.GOLD, str(c0))
	_check("S5② 诅咒压过质变（同卡红优先）", c1 == PopPalette.ENEMY, str(c1))
	_check("S5③ 诅咒卡名字 ENEMY 红", c3 == PopPalette.ENEMY, str(c3))
	ui.close()
	# 货架 B：全部普通卡（无质变无诅咒）——同槽位复用
	var shelf_b: Array[Dictionary] = [
		_mk_card("B0普通", false, false),
		_mk_card("B1普通", false, false),
		_mk_card("B2普通", false, false),
		_mk_card("B3普通", false, false),
	]
	ui.open(shelf_b, false)
	var b0 := _face_name_color(ui, 0)
	var b1 := _face_name_color(ui, 1)
	var b3 := _face_name_color(ui, 3)
	print("[S5] 货架B 槽0=%s 槽1=%s 槽3=%s（INK=%s 为正确还原）"
		% [str(b0), str(b1), str(b3), str(PopPalette.INK)])
	_check("S5④ 普通货架槽0 名字还原 INK（无残留 GOLD）", b0 == PopPalette.INK, str(b0))
	_check("S5⑤ 普通货架槽1 名字还原 INK（无残留 ENEMY）", b1 == PopPalette.INK, str(b1))
	_check("S5⑥ 普通货架槽3 名字还原 INK（无残留 ENEMY）", b3 == PopPalette.INK, str(b3))
	ui.close()


# ── S6：compose_desc_text 诅咒尾行（信息性） ───────────────────────
func _s6_compose_info() -> void:
	print("── S6 compose_desc_text 诅咒尾行 ──")
	var t := CardSelectUI.compose_desc_text("攻击力 +15%", 1.4, true, true)
	print("[S6] %s" % t)
	_check("S6 三尾行叠放（品质+⇄+⚠代价）顺序与内容",
		t.contains("品质加成") and t.contains("⇄") and t.contains("⚠ 代价：攻击力 -10%"), t)


func _find_label_by_text(p_node: Node, p_needle: String) -> Label:
	if p_node is Label and String((p_node as Label).text).contains(p_needle):
		return p_node
	for c in p_node.get_children():
		var hit: Label = _find_label_by_text(c, p_needle)
		if hit != null:
			return hit
	return null

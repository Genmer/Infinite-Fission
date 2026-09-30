# tests/runner/r199_g4_cases.gd
# R199 G4 武器数据与面板文案组 用例体（由 test_r199_g4.gd 入口在 autoload 就绪后
# 运行时加载编译；r190b_tips_cases 同款引导式）。全部断言 R199 起登记：
#   A. N02 W3_shotgun L3 pellets 9→8（A3 §3.3 真源；L3→L4 恢复真实增益 140.8→158.4）
#   B. N05+F08 暂停面板 _trait_desc_bbcode 超帽 ×0.7 折算（aggregate_panel 同口径）
#   C. N06 十武器 note 文案卫生（剥离 R187 §2.4/A3 §/p1_polish/内部词条 id 等行话）
#   D. P08 拖动教学：GameConst 文案真源 + lore 菜单行 + HUD 首局一次性提示
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"

# N06 文案卫生黑名单（开发变更号 / 设计文档号 / 内部术语 / 内部词条与字段 id）
const JARGON: Array[String] = ["R187", "R10 ", "A3 §", "旧 note", "旧 L5", "bounce 预算",
	"TH_", "p1_polish", "retro", "规格", "倒退回归", "R78", "R27", "R36", "蓄能改版",
	"sub_count", "blast_r", "tick_atk", "mirror_ratio", "orbit_radius", "rof ", "pellets",
	"orb_atk", "arc_deg"]
const WEAPON_IDS: Array[StringName] = [&"W1_pistol", &"W2_gatling", &"W3_shotgun",
	&"W4_pulse_beam", &"W5_prism", &"W6_micro_missile", &"W7_cluster_rocket",
	&"W8_orbit_field", &"W9_arc_slash", &"W10_boomerang"]

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_test_w3_truth()            # A（N02）
	_test_panel_overcap_desc()  # B（N05+F08）
	_test_note_hygiene()        # C（N06）
	_test_tutorial_copy()       # D（P08）
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s | %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	# 测试档卫生（r190b_tips_cases 同款：清角色解锁位防残留往返携带）
	Meta.unlocked_characters = {}
	Meta.character_id = &"sentinel"
	_gl.start_run()
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()                          # 局内存档清档（防测试残留污染继续入口）
	if _gl != null:
		_gl.free()
		_gl = null


# ── A. N02 W3 真值回修（A3 §3.3：L1..L5 = 9×7 / 9×8 / 11×8 / 11×9 / 14×9） ──
func _test_w3_truth() -> void:
	print("── A. N02 W3 霰弹枪 L3 pellets 回修（R199） ──")
	var d: Variant = _gl.registry.get_weapon(&"W3_shotgun")
	_check("A0 注册表有 W3_shotgun", d != null)
	if d == null:
		return
	var pellets_expect: Array[int] = [7, 8, 8, 9, 9]
	var atk_expect: Array[float] = [9.0, 9.0, 11.0, 11.0, 14.0]
	var dps_expect: Array[float] = [100.8, 115.2, 140.8, 158.4, 201.6]
	for i in range(5):
		var lv: Variant = (d as Object).get("upgrade_table")[i]
		_check("A1 L%d pellets==%d（R199：L3 由 9 回修 8）" % [i + 1, pellets_expect[i]],
			int(lv.get("pellets")) == pellets_expect[i], "实得 %d" % int(lv.get("pellets")))
		_check("A2 L%d base_atk==%.1f（其余字段不受波及）" % [i + 1, atk_expect[i]],
			absf(float(lv.get("base_atk")) - atk_expect[i]) < 0.001,
			"实得 %.2f" % float(lv.get("base_atk")))
		var dps: float = float(lv.get("base_atk")) * float(lv.get("rof")) \
			* float(int(lv.get("pellets")))
		_check("A3 L%d 贴脸面板 DPS %.1f（±0.1）" % [i + 1, dps_expect[i]],
			absf(dps - dps_expect[i]) <= 0.1, "实得 %.2f" % dps)
	_check("A4 L3 其余数值字段与修前一致（rof/cd/pierce）",
		absf(float((d as Object).get("upgrade_table")[2].get("rof")) - 1.6) < 0.001
		and absf(float((d as Object).get("upgrade_table")[2].get("cd"))) < 0.001
		and int((d as Object).get("upgrade_table")[2].get("pierce")) == 1)
	var dps_l3: float = 11.0 * 1.6 * 8.0
	var dps_l4: float = 11.0 * 1.6 * 9.0
	_check("A5 L3→L4 恢复真实增益（%.1f → %.1f）" % [dps_l3, dps_l4], dps_l4 > dps_l3,
		"%.2f -> %.2f" % [dps_l3, dps_l4])


# ── B. N05+F08 暂停面板词条总值：超帽层 ×0.7 折算（aggregate_panel 同口径） ──
func _test_panel_overcap_desc() -> void:
	print("── B. N05+F08 暂停面板超帽折算（R199） ──")
	var t: TraitData = _gl.registry.get_trait(&"AFF_ATK_UP")
	var w: BallisticWeapon = BallisticWeapon.new()
	tree.get_root().add_child(w)
	w.setup(_gl.registry.get_weapon(&"W1_pistol"), null, {})
	# 超帽态：stack_max=3 + OVERCAP_EXT_MAX=5 → 8 层（体检探针 A0 同场景）
	for i in range(3 + TraitStack.OVERCAP_EXT_MAX):
		w.attach_trait(t)
	var agg: float = float(w.trait_stack.aggregate_panel().get("add_atk", 0.0))
	_check("B0 真值源 aggregate_panel = 0.975（前 3 层全额 + 超帽 5 层 ×0.7）",
		absf(agg - 0.975) < 0.001, "agg=%.4f" % agg)
	var tb: TraitBase = w.trait_stack.traits[0]
	var desc: String = _gl.pause_overlay._trait_desc_bbcode(tb)
	var rx: RegEx = RegEx.create_from_string("\\+([\\d.]+)%")
	var m: RegExMatch = rx.search(desc)
	var shown: float = float(m.get_string(1)) if m != null else -1.0
	_check("B1 超帽态面板显示 +97.5%（实际生效值，R199 前虚标 +120%）",
		absf(shown - 97.5) < 0.11, "显示 %s%% vs 实际 97.5%%" % str(shown))
	w.queue_free()
	# 未超帽回归护栏：2/3 层仍全额（2×0.15=0.30 → +30%）
	var w2: BallisticWeapon = BallisticWeapon.new()
	tree.get_root().add_child(w2)
	w2.setup(_gl.registry.get_weapon(&"W1_pistol"), null, {})
	w2.attach_trait(t)
	w2.attach_trait(t)
	var desc2: String = _gl.pause_overlay._trait_desc_bbcode(w2.trait_stack.traits[0])
	_check("B2 未超帽 2/3 层仍显示全额 +30%（回归护栏）", desc2.contains("+30%"),
		desc2)
	# 1 层护栏：保持原描述不改写（既有 R11 语义）
	var w1: BallisticWeapon = BallisticWeapon.new()
	tree.get_root().add_child(w1)
	w1.setup(_gl.registry.get_weapon(&"W1_pistol"), null, {})
	w1.attach_trait(t)
	var td: TraitData = w1.trait_stack.traits[0].data
	var desc1: String = _gl.pause_overlay._trait_desc_bbcode(w1.trait_stack.traits[0])
	_check("B3 1 层保持原描述不改写（既有语义）", desc1 == String(td.description), desc1)
	w1.queue_free()
	w2.queue_free()


# ── C. N06 十武器 note 文案卫生 + 渲染链实捕 ──
func _test_note_hygiene() -> void:
	print("── C. N06 武器 note 文案卫生（R199） ──")
	var bad: Array[String] = []
	for id: StringName in WEAPON_IDS:
		var d: Variant = _gl.registry.get_weapon(id)
		if d == null:
			bad.append("%s 不在注册表" % id)
			continue
		var table: Array = (d as Object).get("upgrade_table")
		for i in range(table.size()):
			var note := String(table[i].get("note"))
			if note.is_empty():
				bad.append("%s L%d 空 note" % [id, i + 1])
				continue
			for j: String in JARGON:
				if note.contains(j):
					bad.append("%s L%d ←「%s」" % [id, i + 1, j])
	_check("C1 十武器 ×5 级 note 全量零开发行话/内部 id（R199）", bad.is_empty(), str(bad))
	# 渲染链实捕（probe_note_entry 同路径：暂停面板 Lv3/Lv5 质变行 + HUD 下一级提示）
	var w: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol"))
	w.level = 5
	w.call("_invalidate_panel")
	var sec: Control = _gl.pause_overlay.call("_make_weapon_section", w)
	var l3 := ""
	var l5 := ""
	if sec != null:
		var texts: Array[String] = []
		_collect_labels(sec, texts)
		for s in texts:
			if s.begins_with("【3 级质变】"):
				l3 = s
			elif s.begins_with("【5 级质变】"):
				l5 = s
	_check("C2 【3 级质变】行实捕（渲染链走通）", l3 != "", l3)
	_check("C3 【5 级质变】行实捕", l5 != "", l5)
	var hits: Array[String] = []
	for s: String in [l3, l5]:
		for j: String in JARGON:
			if s.contains(j):
				hits.append("%s←%s" % [j, s])
	_check("C4 质变行零内部术语（R199 文案卫生）", hits.is_empty(), str(hits))
	if sec != null:
		# _make_weapon_section 只构建不入树（调用方挂树）——无父直接 free
		var par: Node = sec.get_parent()
		if par != null:
			par.remove_child(sec)
		sec.free()
	# HUD 下一级提示（悬停 tooltip 真源 _next_level_note）
	var tip2: String = _gl.hud._next_level_note(w, 1)
	var tip5: String = _gl.hud._next_level_note(w, 5)
	_check("C5 HUD L1→L2 提示 = W1 L2 note（零行话）",
		tip2 == String(((_gl.registry.get_weapon(&"W1_pistol") as Object)
			.get("upgrade_table") as Array)[1].get("note")) and not _hit_jargon(tip2),
		tip2)
	_check("C6 HUD 满级（L5）提示空串（帽语义）", tip5 == "", tip5)


func _hit_jargon(p_text: String) -> bool:
	for j: String in JARGON:
		if p_text.contains(j):
			return true
	return false


func _collect_labels(p_node: Node, p_out: Array[String]) -> void:
	for c in p_node.get_children():
		if c is Label and not c.is_queued_for_deletion():
			p_out.append((c as Label).text)
		_collect_labels(c, p_out)


# ── D. P08 拖动教学：文案真源 + lore 菜单行 + HUD 首局一次性提示 ──
func _test_tutorial_copy() -> void:
	print("── D. P08 拖动教学（R199） ──")
	_check("D1 真源非空且含「拖动」操作说明",
		GameConst.TUTORIAL_MOVE_MENU.contains("拖动")
		and GameConst.TUTORIAL_MOVE_BATTLE.contains("拖动"),
		"%s / %s" % [GameConst.TUTORIAL_MOVE_MENU, GameConst.TUTORIAL_MOVE_BATTLE])
	_check("D2 lore 菜单行保持 3 行（menu_screen 几何契约，第 4 行撞继续钮）",
		Lore.MENU_LINES.size() == 3, "size=%d" % Lore.MENU_LINES.size())
	_check("D3 lore 菜单行第 3 行 = 真源原句（单源不手抄）",
		Lore.MENU_LINES[2] == GameConst.TUTORIAL_MOVE_MENU, Lore.MENU_LINES[2])
	_check("D4 原风味行保留（第 1/2 行不受波及）",
		Lore.MENU_LINES[0] == "反应堆今天也在打喷嚏。"
		and Lore.MENU_LINES[1] == "防御机器人「哨兵-9」决定用弹幕帮它冷静一下。",
		str(Lore.MENU_LINES))
	# HUD 首局一次性提示（行为级：武装 → PLAYING 走秒 → 非战斗冻结 → 到点弹一次）
	var hud: HUD = _gl.hud
	HUD._move_hint_shown = false                     # R199 静态一次性标志重置（测试观测）
	hud._move_hint_wait = -1.0                       # 清 boot 期真实状态机残留，保确定性
	hud._on_state_changed(GameConst.GameStatus.PLAYING)
	_check("D5 首次进 PLAYING 排程倒计时 = MOVE_HINT_DELAY",
		absf(hud._move_hint_wait - HUD.MOVE_HINT_DELAY) < 0.0001,
		"wait=%.2f" % hud._move_hint_wait)
	hud.tick(1.0)
	_check("D6 PLAYING 走秒（2.2→1.2）",
		absf(hud._move_hint_wait - (HUD.MOVE_HINT_DELAY - 1.0)) < 0.0001,
		"wait=%.2f" % hud._move_hint_wait)
	var wait_frozen: float = hud._move_hint_wait
	hud._on_state_changed(GameConst.GameStatus.PAUSED)
	hud.tick(5.0)
	_check("D7 非 PLAYING（暂停/升级/结算）倒计时冻结",
		absf(hud._move_hint_wait - wait_frozen) < 0.0001,
		"wait=%.2f（期望 %.2f）" % [hud._move_hint_wait, wait_frozen])
	hud._on_state_changed(GameConst.GameStatus.PLAYING)
	hud.tick(3.0)
	_check("D8 到点弹一次性提示（toast 文本 = 真源 TUTORIAL_MOVE_BATTLE）",
		HUD._move_hint_shown
		and hud._toast_label.text == GameConst.TUTORIAL_MOVE_BATTLE,
		"shown=%s text=%s" % [str(HUD._move_hint_shown), hud._toast_label.text])
	hud._on_state_changed(GameConst.GameStatus.PLAYING)
	hud.tick(5.0)
	_check("D9 已提示后不重排不重弹（一次性）",
		hud._move_hint_wait < 0.0
		and hud._toast_label.text == GameConst.TUTORIAL_MOVE_BATTLE,
		"wait=%.2f" % hud._move_hint_wait)
	HUD._move_hint_shown = false                     # 还原静态（同进程后续用例零残留）

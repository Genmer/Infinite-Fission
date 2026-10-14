# tests/runner/r251_first_encounter_cases.gd
# R251 需求③ 首遇卡片 + 需求② 咒术师降频·用例体（test_r251_first_encounter.gd 入口
# 在 autoload 就绪后运行时加载编译——r246/r196 同式）。
# 纪律（照 r196_growth_cases.gd:78-92 隔离先例）：套件首尾 codex_first_met/reaction_seen
# 快照-清场-还原；headless 测试档自动隔离（meta_save_test.cfg）；用例收尾还原防污染。
# 频率段 B3 照 verify_feedback_cases.gd:3604 先例经 _roll_composition(wave) 统计，
# seed() 固定 + 三档分波区间断言（理论 ±4σ，档间互斥）。
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"
const B3_N := 1000                               # B3 每档 roll 次数（设计 §2.5）
const CARD_LIFE_PROBE := 4.5                     # 单张自动消散探针（设计 §3.3）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _snap_first_met: Dictionary = {}
var _snap_reaction_seen: Dictionary = {}


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_snapshot_meta()
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_test_c1_enemy_card()
	_test_c2_codex_persist()
	_test_c3_boss_and_grunt_card()
	_test_c4_weapon_shelf_card()
	_test_c5_weapon_gain_fallback_card()
	_test_c6_reaction_card()
	_test_c7_queue()
	await _test_c_layout_declaration()             # 含 await 布局帧——挂起等待（防协程交错收卡）
	await _test_c_pause_freeze()                   # 含 await 真帧推进——必须挂起等待
	_test_c_icon_regression()
	_test_c8_hygiene()
	_test_c9_frequency()                           # B1~B3（需求②）
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


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s（%s）" % [p_name, p_detail])
		print("FAIL | %s（%s）" % [p_name, p_detail])


# ── 环境 ──────────────────────────────────────────────────────────
func _snapshot_meta() -> void:
	# 快照 + 清场（首遇/反应锁清零）——断言确定性前置（r196 :78 先例）
	_snap_reaction_seen = Meta.reaction_seen.duplicate()
	_snap_first_met = Meta.codex_first_met.duplicate()
	Meta.reaction_seen = {}
	Meta.codex_first_met = {}


func _restore_meta() -> void:
	Meta.reaction_seen = _snap_reaction_seen
	Meta.codex_first_met = _snap_first_met


func _boot_game_loop() -> void:
	_normalize_window_for_boot()                  # QA B-2：布局断言需设计域 canvas 恒等（r196 同式）
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R251GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU          # 冻结波次刷怪（用例自管夹具敌）
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.set("unlocked_slots", 6)
	_gl.player.global_position = Vector2(360.0, 900.0)


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _normalize_window_for_boot() -> void:
	# -s 脚本模式根窗口归一（r196_growth_cases 同式）：canvas_items + 工程 aspect
	# + 默认窗 override → 设计域 720×1280 canvas 恒等（QA B-2 布局断言坐标前提）
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


func _sp_for_test() -> EnemySpawner:
	# 夹具 spawner（verify E5 先例：独立实例注入真池/注册表——不扰 _gl.spawner 计数面）
	var sp := EnemySpawner.new()
	sp.pool = _gl.pools[&"enemy"]
	sp.registry = _gl.registry
	return sp


func _release_sp_active(p_sp: EnemySpawner) -> void:
	# 出队敌回收（verify E5 收尾同式——clear 后逐只还池）
	while p_sp.active.size() > 0:
		var se: Enemy = p_sp.active[0]
		p_sp.active.clear()
		(_gl.pools[&"enemy"] as EnemyPool).release(se)


func _capture_cards() -> Array[Dictionary]:
	# 首遇卡计数容器（连信号用方法引用 _card_cb——写回 _card_sink 成员，无捕贝）
	var seen: Array[Dictionary] = []
	_card_sink = seen
	return seen


var _card_sink: Array[Dictionary] = []


func _card_cb(p_title: String, p_body: String, p_kind: StringName, p_id: StringName) -> void:
	# 具名回调（方法引用连信号——本套件不用 lambda 捕贝，直接绑 sink 容器）
	if _card_sink != null:
		_card_sink.append({"title": p_title, "body": p_body, "kind": p_kind, "id": p_id})


func _reset_card_ui() -> void:
	# 卡 UI 复位（清展示/队列/间隔——用例间隔离观测面）
	var ui := _gl.first_encounter_card_ui
	ui._showing = false
	ui._life = 0.0
	ui._gap = 0.0
	ui._queue.clear()
	ui._card.visible = false
	ui._root.visible = false


# ── C1 敌卡 ───────────────────────────────────────────────────────
func _test_c1_enemy_card() -> void:
	print("── C1 敌卡：出队首遇弹卡（恰 1 次/二次不弹） ──")
	Meta.codex_first_met.clear()
	_capture_cards()
	EventBus.first_encounter_card.connect(_card_cb)
	var sp := _sp_for_test()
	sp.enqueue({"data_id": &"E28_hexcaster", "wave": 1, "tags": 0})
	sp.tick(0.016, _gl.enemy_grid)
	_check("C1：首次出队 → 恰 1 张卡", _card_sink.size() == 1, str(_card_sink))
	_check("C1：title 含【首次遭遇】+ 咒术师",
		_card_sink.size() == 1 and String(_card_sink[0]["title"]).contains("【首次遭遇】")
			and String(_card_sink[0]["title"]).contains("咒术师"), str(_card_sink))
	_check("C1：body 含法术圈 ∧ kind==enemy ∧ id==E28",
		_card_sink.size() == 1 and String(_card_sink[0]["body"]).contains("法术圈")
			and StringName(_card_sink[0]["kind"]) == &"enemy"
			and StringName(_card_sink[0]["id"]) == &"E28_hexcaster", str(_card_sink))
	sp.enqueue({"data_id": &"E28_hexcaster", "wave": 1, "tags": 0})
	sp.tick(0.016, _gl.enemy_grid)
	_check("C1：二次遭遇不再弹卡", _card_sink.size() == 1, str(_card_sink))
	EventBus.first_encounter_card.disconnect(_card_cb)
	_release_sp_active(sp)
	sp.free()


# ── C2 持久化 ─────────────────────────────────────────────────────
func _test_c2_codex_persist() -> void:
	print("── C2 敌卡持久化（codex_first_met 落账） ──")
	_check("C2：codex_first_met.has(E28_hexcaster)（C1 落账；套件尾还原快照）",
		Meta.codex_first_met.has("E28_hexcaster"))


# ── C3 Boss 卡 + E1 卡 ────────────────────────────────────────────
func _test_c3_boss_and_grunt_card() -> void:
	print("── C3 Boss 卡 + 旧怪首遇卡（零打扰契约废止） ──")
	Meta.codex_first_met.erase("E6_boss1")
	Meta.codex_first_met.erase("E1_grunt")
	_capture_cards()
	EventBus.first_encounter_card.connect(_card_cb)
	var sp := _sp_for_test()
	sp.enqueue({"data_id": &"E6_boss1", "wave": 5, "tags": 0})
	sp.tick(0.016, _gl.enemy_grid)
	sp.enqueue({"data_id": &"E1_grunt", "wave": 1, "tags": 0})
	sp.tick(0.016, _gl.enemy_grid)
	EventBus.first_encounter_card.disconnect(_card_cb)
	_check("C3：Boss 出队弹卡（聚合体 + 机制句）",
		_card_sink.size() >= 1 and String(_card_sink[0]["title"]).contains("聚合体")
			and String(_card_sink[0]["body"]).contains("弹幕环"), str(_card_sink))
	_check("C3：E1_grunt 首遇也弹卡（杂兵）",
		_card_sink.size() == 2 and String(_card_sink[1]["title"]).contains("杂兵"),
		str(_card_sink))
	_release_sp_active(sp)
	sp.free()


# ── C4 武器上架卡 ─────────────────────────────────────────────────
func _test_c4_weapon_shelf_card() -> void:
	print("── C4 武器上架卡（选卡窗定稿路径） ──")
	Meta.codex_first_met.erase("W_W10_boomerang")
	# W2/W3 预烧键（夹具批其余 WEAPON 项已首见——隔离「恰 W10 弹 1 张」断言面）
	Meta.codex_first_met["W_W2_gatling"] = true
	Meta.codex_first_met["W_W3_shotgun"] = true
	var gen := StubWeaponGen.new()
	gen.fixed = [_weapon_card(&"W10_boomerang"), _weapon_card(&"W2_gatling"),
		_weapon_card(&"W3_shotgun")]
	var real_gen: CardGenerator = _gl.card_generator
	_gl.card_generator = gen                       # 定稿路径夹具（:2018 首 roll / :2068 reroll 同链）
	_capture_cards()
	EventBus.first_encounter_card.connect(_card_cb)
	_gl._open_card_flow(2)                         # 候选定稿 → WEAPON 项首见 → 发卡
	_check("C4：上架弹【新武器】回旋刃卡（恰 1 次）",
		_card_sink.size() == 1 and String(_card_sink[0]["title"]) == "【新武器】回旋刃",
		str(_card_sink))
	_check("C4：body 含双程 ∧ kind==weapon ∧ id==W10",
		_card_sink.size() == 1 and String(_card_sink[0]["body"]).contains("双程")
			and StringName(_card_sink[0]["kind"]) == &"weapon"
			and StringName(_card_sink[0]["id"]) == &"W10_boomerang", str(_card_sink))
	_check("C4：W_ 键落账", Meta.codex_first_met.has("W_W10_boomerang"))
	_card_sink.clear()
	_gl._on_card_reroll()                          # 同窗二次定稿（:2068 路径）——键已烧静默
	_check("C4：同窗二次定稿不再弹", _card_sink.is_empty(), str(_card_sink))
	EventBus.first_encounter_card.disconnect(_card_cb)
	_gl.card_generator = real_gen
	_gl.card_select_ui.close()
	_gl.state = GameConst.GameStatus.MENU          # 收口（防 LEVEL_UP 挂机臂误触发）


func _weapon_card(p_wid: StringName) -> Dictionary:
	# 候选 WEAPON 卡 dict（字段集照 card_generator.gd:847-855 全量——CardSelectUI 渲染容错）
	var wd: WeaponData = _gl.registry.get_weapon(p_wid)
	return {
		"kind": CardGenerator.CardKind.WEAPON,
		"id": p_wid,
		"rarity": 2,
		"data": wd,
		"display_name": "新武器：%s" % (wd.display_name if wd != null else String(p_wid)),
		"description": "形态武器，装配至空槽位",
		"value_scale": 1.0,
	}


# ── C5 武器获取回退卡 ─────────────────────────────────────────────
func _test_c5_weapon_gain_fallback_card() -> void:
	print("── C5 武器获取回退卡（add_weapon 与上架同键互斥） ──")
	var wdata: WeaponData = _gl.registry.get_weapon(&"W10_boomerang")
	_check("C5 前置：W10 注册可加载", wdata != null)
	if wdata == null:
		return
	_capture_cards()
	EventBus.first_encounter_card.connect(_card_cb)
	_gl.player.add_weapon(wdata)                   # C4 已烧键 → 静默（无双弹）
	_check("C5：键已烧时 add_weapon 静默", _card_sink.is_empty(), str(_card_sink))
	Meta.codex_first_met.erase("W_W10_boomerang")
	_gl.player.add_weapon(wdata)                   # erase 后直获 → 回退口单弹
	_check("C5：erase 后直获弹卡（恰 1 次）",
		_card_sink.size() == 1 and String(_card_sink[0]["title"]) == "【新武器】回旋刃"
			and StringName(_card_sink[0]["kind"]) == &"weapon", str(_card_sink))
	EventBus.first_encounter_card.disconnect(_card_cb)


# ── C6 反应卡 ─────────────────────────────────────────────────────
func _test_c6_reaction_card() -> void:
	print("── C6 反应卡（真反应首触发） ──")
	Meta.reaction_seen.erase("RXN_FIR_ICE")
	_capture_cards()
	EventBus.first_encounter_card.connect(_card_cb)
	# 真反应事件消费口（r199 F17 口径：_on_reaction_triggered 恒只认真反应）——
	# 首见分支 mark_reaction_seen==true → 发卡；语义（幂等/codex_changed/落盘）零变化
	Meta._on_reaction_triggered(GameConst.ReactionType.RXN_FIR_ICE, Vector2.ZERO, -1)
	var note: Dictionary = GameConst.reaction_note("RXN_FIR_ICE")
	_check("C6：首触发弹卡（【新反应】碎裂 + recipe 要点 + reaction 域）",
		_card_sink.size() == 1 and String(_card_sink[0]["title"]) == "【新反应】碎裂"
			and String(_card_sink[0]["body"]).contains(String(note.get("recipe", "")))
			and StringName(_card_sink[0]["kind"]) == &"reaction"
			and StringName(_card_sink[0]["id"]) == &"RXN_FIR_ICE", str(_card_sink))
	_check("C6：reaction_seen 落账（原语义零变化）",
		Meta.reaction_seen.has("RXN_FIR_ICE"))
	_card_sink.clear()
	Meta._on_reaction_triggered(GameConst.ReactionType.RXN_FIR_ICE, Vector2.ZERO, -1)
	_check("C6：再次触发不重弹（幂等）", _card_sink.is_empty(), str(_card_sink))
	Meta._on_reaction_triggered(9999, Vector2.ZERO, -1)   # 坏 rxn：find_key null → 跳过
	_check("C6：坏 rxn 不点亮不弹卡", _card_sink.is_empty(), str(_card_sink))
	EventBus.first_encounter_card.disconnect(_card_cb)


# ── C7 队列 ───────────────────────────────────────────────────────
func _test_c7_queue() -> void:
	print("── C7 队列（单卡可见/上限 4/点击即关/自动消散） ──")
	var ui := _gl.first_encounter_card_ui
	_check("C7 前置：卡 UI 挂载在位", ui != null)
	if ui == null:
		return
	_reset_card_ui()
	for i in range(6):
		EventBus.emit_first_encounter_card("测试卡%d" % i, "正文", &"enemy", &"E1_grunt")
	_check("C7：连发 6 张 → 任一时刻至多 1 张可见", ui.is_open() and ui.pending_count() == 4,
		"open=%s pending=%d" % [str(ui.is_open()), ui.pending_count()])
	# 逐张播完收标题（丢最旧：播 0、丢 1、播 2~5）
	var shown: Array[String] = []
	var guard := 0
	while (ui.is_open() or ui.pending_count() > 0) and guard < 64:
		guard += 1
		if ui.is_open():
			shown.append(ui._title_l.text)
			ui._process(4.6)                       # 单张到点消散
		else:
			ui._process(0.3)                       # 间隔放行下一张
	var expect := ["测试卡0", "测试卡2", "测试卡3", "测试卡4", "测试卡5"]
	_check("C7：队列上限 4 丢最旧（1 号被挤掉）", shown == expect, str(shown))
	# 点击即关
	_reset_card_ui()
	EventBus.emit_first_encounter_card("点击关", "正文", &"enemy", &"E1_grunt")
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ui._unhandled_input(ev)
	_check("C7：点击任意处立即关闭", not ui.is_open())
	# 4.5s 自动消散
	_reset_card_ui()
	EventBus.emit_first_encounter_card("寿命卡", "正文", &"enemy", &"E1_grunt")
	ui._process(CARD_LIFE_PROBE)
	_check("C7：4.5s 自动消散", not ui.is_open())
	_reset_card_ui()


# ── C 布局声明：卡矩形 vs HUD 顶带读数组（QA B-2 规格固化） ──────────
func _test_c_layout_declaration() -> void:
	print("── C 布局声明：卡矩形 vs HUD 顶带（避让面规格化） ──")
	var ui := _gl.first_encounter_card_ui
	_reset_card_ui()
	EventBus.emit_first_encounter_card("布局卡", "正文", &"enemy", &"E28_hexcaster")
	await tree.process_frame                       # anchor 布局帧末解析——先等一帧再读
	await tree.process_frame
	# 局部坐标 = 设计域坐标（_root 满幅 CanvasLayer；global 会叠 window stretch 缩放）
	var cr := Rect2(ui._card.position, ui._card.size)
	_check("C 布局：卡 @ 设计域 (100,260) 520×96（R253 下移落位——顶带+BossBar+Boss 战带全让开）",
		cr == Rect2(100.0, 260.0, 520.0, 96.0), str(cr))
	# BossBar 带（hud.gd:170 注释「BossBar 占 y112-184」）：卡顶 260 > 184——结构性不相交
	_check("C 布局：卡与 BossBar 带（y112-184）不相交（顶沿 260 > 184）",
		not cr.intersects(Rect2(0.0, 112.0, 720.0, 72.0)), str(cr))
	# 评审 M1 二次让位：Boss 战带 = TargetBar 让位 y190-216（hud.gd:169-171）+ 降临横幅
	# y210-256 全宽（hud.gd:1626-1629）——Boss 首遇卡恰在出场瞬间触发（game_const.gd
	# E6_boss1/2/3 首遇文案），188 落位会盖住目标血条+登场横幅；260 起全让开
	_check("C 布局：卡与 Boss 战带（TargetBar y190-216 + 横幅 y210-256）不相交（260 > 256，4px 缝）",
		not cr.intersects(Rect2(0.0, 190.0, 720.0, 66.0)), str(cr))
	# 顶带读数组（QA B-2 实测坐标，与 hud.gd :1362/:1404/:1606/:1767 源码锚逐一吻合）：
	# 当前几何为相交 = 登记让位需求（QA丙-1 登记主张采信——96px 卡在顶带纵向无
	# 无碰撞空带，卡位本体调整无自由解，登记设计拍板；拍板落位后本组断言翻转为
	# not intersects）
	var hp_bar := Rect2(24.0, 24.0, 340.0, 30.0)     # HP 血条面板（HP_BAR_SIZE，hud.gd:154/:1362）
	var r187 := Rect2(368.0, 30.0, 224.0, 20.0)      # R187 读数（hud.gd:1404-1405）
	var gold := Rect2(464.0, 92.0, 132.0, 36.0)      # 金币 pill（hud.gd:1606）
	var pause := Rect2(514.0, 20.0, 72.0, 72.0)      # 暂停钮（hud.gd:1767-1768）
	_check("C 布局：卡与 HP/R187/金币/暂停钮全不相交（R253 下移让位落地——QA B-2 登记项收口）",
		not cr.intersects(hp_bar) and not cr.intersects(r187)
			and not cr.intersects(gold) and not cr.intersects(pause),
		"hp=%s r187=%s gold=%s pause=%s" % [
			str(cr.intersects(hp_bar)), str(cr.intersects(r187)),
			str(cr.intersects(gold)), str(cr.intersects(pause))])
	_reset_card_ui()


# ── C 暂停冻结：PAUSABLE（QA B-1 规格固化——设计 §3.3「暂停不推进/恢复续播」） ──
func _test_c_pause_freeze() -> void:
	print("── C 暂停冻结：LEVEL_UP/PAUSED 期计时冻结、恢复续播 ──")
	var ui := _gl.first_encounter_card_ui
	tree.paused = false                           # 起底（前置用例 LEVEL_UP 残留 paused 兜底）
	_reset_card_ui()
	tree.paused = true                            # 模拟 LEVEL_UP/PAUSED（game_loop.gd:1038-1039 同置）
	EventBus.emit_first_encounter_card("冻结卡", "正文", &"enemy", &"E28_hexcaster")
	print("DBG pause: showing=%s visible=%s is_open=%s queue=%d life=%.3f gap=%.3f pm=%d paused=%s"
		% [str(ui._showing), str(ui._card.visible), str(ui.is_open()), ui.pending_count(),
		ui._life, ui._gap, ui.process_mode, str(tree.paused)])
	var l0: float = ui._life
	await tree.create_timer(0.15, true).timeout   # 真实 0.15s 流逝（process_always 计时器）
	_check("C 暂停：暂停期发卡照常显示（队列不丢）", ui.is_open())
	_check("C 暂停：暂停期计时冻结（PAUSABLE——0.15s 零推进）",
		ui._life - l0 < 0.02, "life=%.3f (+%.3f)" % [ui._life, ui._life - l0])
	tree.paused = false
	await tree.create_timer(0.15).timeout         # 解除暂停后续播
	_check("C 暂停：解除暂停续播（计时恢复推进）", ui._life - l0 >= 0.1,
		"life=%.3f (+%.3f)" % [ui._life, ui._life - l0])
	_reset_card_ui()


# ── C 回归：E24 分型图标前缀优先级 + 反应双色环（校验问题1/2 防退化锚） ──
func _test_c_icon_regression() -> void:
	print("── C 回归：E24 图标（多字符 id 先于 E2 短前缀）+ 反应双色环 ──")
	var ui := _gl.first_encounter_card_ui
	if ui == null:
		_check("C 回归：卡 UI 挂载在位", false, "ui null")
		return
	# 问题1 回归：E24_rift_demon 不撞 E2 短前缀（图标 = phase 贴图，非 dart）
	var e24_tex: ImageTexture = ui._enemy_icon_tex(&"E24_rift_demon")
	_check("C 回归：E24 图标 = phase 非 dart（E24 分支先于 E2 短前缀）",
		e24_tex == TextureFactory.enemy_tex(&"phase")
			and e24_tex != TextureFactory.enemy_tex(&"dart"))
	# 问题2 回归：反应卡双色环并排（规格 §3.3——两环取 elements[0]/[1] 互异色）
	_reset_card_ui()
	EventBus.emit_first_encounter_card("环卡", "正文", &"reaction", &"RXN_FIR_ICE")
	_check("C 回归：反应卡双色环并排可见（两环 texture 互异）",
		ui.is_open() and ui._icon_rect2.visible
			and ui._icon_rect.texture != ui._icon_rect2.texture,
		"open=%s icon2=%s" % [str(ui.is_open()), str(ui._icon_rect2.visible)])
	_reset_card_ui()
	EventBus.emit_first_encounter_card("单图卡", "正文", &"enemy", &"E28_hexcaster")
	_check("C 回归：敌/武器域第二环隐藏、单图 64px",
		ui.is_open() and not ui._icon_rect2.visible
			and ui._icon_rect.size == Vector2(64.0, 64.0))
	_reset_card_ui()


# ── C8 卫生 ───────────────────────────────────────────────────────
func _test_c8_hygiene() -> void:
	print("── C8 卫生（本批新改文件 emoji 闸门） ──")
	var hits: Array = []
	for p: String in [
		"res://scripts/ui/first_encounter_card_ui.gd",
		"res://tests/runner/r251_first_encounter_cases.gd",
		"res://autoload/event_bus.gd",
		"res://scripts/entities/wave/enemy_spawner.gd",
		"res://scripts/entities/wave/wave_director.gd",
		"res://scripts/meta/meta_manager.gd",
		"res://scripts/loop/game_loop.gd",
		"res://scripts/core/game_const.gd",
		"res://scripts/ui/hud.gd",
		# QA B-4：A 面新增文案文件并入（R251 本批双套件文案面全覆盖——
		# 与 r196 全仓闸门互为冗余）
		"res://scripts/entities/player/player.gd",
		"res://scripts/entities/enemy/enemy.gd",
		"res://tests/runner/r251_dodge_bomber_cases.gd",
	]:
		_scan_file_codepoints(p, hits)
	_check("C8：本批 12 文件（B 面 9 + A 面 3）零 >0xFFFF 码点（r196 ⑧ 同款闸门）",
		hits.is_empty(), str(hits))


func _scan_file_codepoints(p_path: String, p_hits: Array) -> void:
	var text := FileAccess.get_file_as_string(p_path)
	for i in range(text.length()):
		if text.unicode_at(i) > 0xFFFF:
			p_hits.append("%s:%d" % [p_path, i])
			break


# ── C9 频率段（需求② B1~B3） ─────────────────────────────────────
func _test_c9_frequency() -> void:
	print("── C9 频率段：B1 表值 / B2 施法节奏 / B3 织入份额三档 ──")
	# B1 表值：registry 加载后 fire_cd == 4.8
	var ed: EnemyData = _gl.registry.get_enemy(&"E28_hexcaster")
	_check("B1：E28 ranged.fire_cd == 4.8（tres 降频生效）",
		ed != null and absf(float(ed.ranged.get("fire_cd", 0.0)) - 4.8) <= 0.001,
		"fire_cd=%s" % str(ed.ranged.get("fire_cd") if ed != null else "null"))
	# B2 单只节奏：spawn E28 → 两次施法间隔 == 4.8 ± 0.05（fire_cd_left 回满跳变计数）
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	if ed == null or e == null:
		_check("B2：两次施法间隔 == 4.8±0.05", false,
			"ed=%s e=%s" % [str(ed != null), str(e != null)])
		return
	var cast_ok := false
	if e != null:
		e.spawn(ed, 1, 0)
		# 池敌已挂 bucket_host 桶（树内）——_cast_spell 的 get_parent() 即桶，ring 落桶
		e.global_position = _gl.player.global_position + Vector2(200.0, 0.0)
		var casts: Array[float] = []
		var t := 0.0
		for i in range(120 * 12):
			var prev: float = e.fire_cd_left
			e.tick(DT)
			t += DT
			if e.fire_cd_left >= e.fire_cd - 0.01 and prev < e.fire_cd - 0.01:
				casts.append(t)                    # 施法帧：冷却回满跳变
		cast_ok = casts.size() >= 2
		_check("B2：两次施法间隔 == 4.8±0.05",
			cast_ok and absf(casts[casts.size() - 1] - casts[casts.size() - 2] - 4.8) <= 0.05,
			"casts=%s" % str(casts))
		e.free()                                   # 挂树夹具敌直接销毁（不还池——防 timer 回调悬垂）
	else:
		_check("B2：两次施法间隔 == 4.8±0.05", false, "pool.acquire null")
	# B3 织入份额三档分波（seed 固定；_roll_composition 统计——verify:3604 先例）
	seed(20261010)
	var wd := _gl.wave_director
	wd.wave_table = MapTable.load_table(MapTable.FIRST_MAP_ID, _gl.registry)
	wd.difficulty = GameConst.Difficulty.HARD
	var s3 := _b3_share(wd, 3)
	var s7 := _b3_share(wd, 7)
	wd.difficulty = GameConst.Difficulty.HELL
	var s9 := _b3_share(wd, 9)
	wd.difficulty = GameConst.Difficulty.NORMAL
	_check("B3：HARD w3 E28 份额 ∈ [19%,31%]（理论 25.0）",
		s3 >= 0.19 and s3 <= 0.31, "share=%.3f" % s3)
	_check("B3：HARD w7 E28 份额 ∈ [13%,24%]（理论 18.2）",
		s7 >= 0.13 and s7 <= 0.24, "share=%.3f" % s7)
	_check("B3：HELL w9 E28 份额 ∈ [7%,16%]（理论 11.8）",
		s9 >= 0.07 and s9 <= 0.16, "share=%.3f" % s9)


func _b3_share(p_wd: WaveDirector, p_wave: int) -> float:
	# 织入份额：E28 计数 / 织入总数（extra×n——分母只含织入 id 集，不含波表本体）
	var e28 := 0
	var weave := 0
	for i in range(B3_N):
		var roll: Array[Dictionary] = p_wd._roll_composition(p_wave)
		for en in roll:
			var sid := String(en.get("data_id", ""))
			if sid.begins_with("E25") or sid.begins_with("E26") or sid.begins_with("E28") \
					or sid.begins_with("E27") or sid.begins_with("E29") or sid.begins_with("E30"):
				weave += 1
				if sid.begins_with("E28"):
					e28 += 1
	if weave == 0:
		return -1.0
	return float(e28) / float(weave)


# ── 夹具：定稿路径 stub 卡生成器（extends 真类——game_loop.card_generator 类型化字段；
#    返回签名对齐 Array[Dictionary]——current_candidates 类型化赋值） ──
class StubWeaponGen extends CardGenerator:
	var fixed: Array = []

	func generate_candidates(_p_context: Dictionary) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for c: Variant in fixed:
			out.append(c as Dictionary)
		return out

# tests/runner/auto_idle_cases.gd
# R188-3 挂机全链路验收用例体（由 test_auto_idle.gd 入口在 autoload 就绪后运行时加载）。
# 真源：R188 idle 定案（A 设置 / B 开关 / C 选卡 / D 商店 / E 结算 / F soak 六组）。
# 夹具口径：seed(42) + main.tscn 全栈启动（GameLoop 真件）+ DT=1/120 手动计帧驱动
#（r187/pkg4 同模式：手动驱动 _physics_process，禁自动帧保证确定性）。
# 跨组依赖：Meta 设置双键（auto_select_on / auto_restart_mode）、HUD AUTO 开关、
# GameLoop _tick_auto_idle / GAME_OVER 帧序分支由同定案并行任务落地——对应断言 FAIL
# 即为接线缺口信号（非本文件放宽口径）。
extends RefCounted

const DT := 1.0 / 120.0                       # 120Hz 物理帧
const MAIN_SCENE := "res://scenes/main.tscn"
const PICK_WINDOW_FRAMES := 72                # 0.6s（0.5s 选卡展示窗 + 裕量）
const SHOP_WINDOW_FRAMES := 140               # 1.2s（0.8s 商店窗 + 裕量）
const RESTART_WINDOW_FRAMES := 420            # 3.5s（3s 重开倒计时 + 裕量）
const VICTORY_WINDOW_FRAMES := 300            # 2.5s（2.2s 通关收尾窗 + 裕量）
const SOAK_FRAMES := 3120                     # 26s ≥ 3000 帧（验收下限）
const STREAK_CAP := 1200                      # 10s（LEVEL_UP/GAME_OVER 连续停留上限 @120Hz）
const BADGE_RECT := Rect2(598.0, 16.0, 106.0, 106.0)   # 波次圆形徽章（hud.gd:889 锁定布局）
const CURSE_SCAN_SEEDS := 200                 # 诅咒硬不变量扫描规模（≥200）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _choice_sizes: Array[int] = []            # choice_made 载荷行宽（普通=1 / 成对=2）
var _card_chosen_count: int = 0               # EventBus.card_chosen 计数（图鉴口径）
var _wave_started_count: int = 0              # EventBus.wave_started 计数（二次重开侦测）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_normalize_window_for_boot()
	_boot_game_loop()
	EventBus.card_chosen.connect(_on_card_chosen_spy)
	EventBus.wave_started.connect(_on_wave_started_spy)
	_gl.card_select_ui.choice_made.connect(_on_choice_made_spy)
	_test_a_settings()
	_test_b_toggle()
	_test_c_auto_pick()
	_test_d_shop()
	_test_e_settle()
	_test_f_soak()
	_gl.card_select_ui.choice_made.disconnect(_on_choice_made_spy)
	EventBus.card_chosen.disconnect(_on_card_chosen_spy)
	EventBus.wave_started.disconnect(_on_wave_started_spy)
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("R188-3 用例分账：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 通用夹具 ──────────────────────────────────────────────────────
func _normalize_window_for_boot() -> void:
	# R195 环境归一（r195_adapt/r194 矩阵套件同款协议）：-s headless 根窗口恒 64×64
	#（override 540×960 不生效），而工程 stretch 设置生效——aspect=expand 下画布随窗
	# 延展为 1280×1280 方幅，B 组钉带几何断言（x∈[644,704] 系默认窗口径）即失配。
	# 归一到引擎 boot 等价位：默认窗 = override 540×960（9:16 下 EXPAND≡KEEP，
	# vis==(720,1280) 设计域）；aspect 读 ProjectSettings 单源。断言零改动，仅环境对齐。
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
	RunSave.clear()
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_check("Boot：完成且进入 MENU", _gl.boot_ready and _gl.state == GameConst.GameStatus.MENU)
	# Meta 测试隔离（pkg4 同口径）：局外养成清零——字面断言（HP/复活/开局金）假定全新档案
	Meta.upgrades = {}
	Meta.crystals = 0
	Meta.character_id = &"sentinel"


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	Meta.set_setting("auto_select_on", false)     # 收尾还原（磁盘测试档不留挂机态）
	Meta.set_setting("auto_restart_mode", 0)
	if _gl != null:
		_gl.free()
		_gl = null


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s | %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _drive_frames(p_n: int) -> void:
	for i in range(p_n):
		_gl._physics_process(DT)


func _drive_until_state(p_state: int, p_max: int) -> int:
	# 逐帧驱动至目标状态（返回用时帧数；超时 -1）
	for i in range(p_max):
		_gl._physics_process(DT)
		if _gl.state == p_state:
			return i + 1
	return -1


func _drive_until_shop_closed(p_max: int) -> int:
	for i in range(p_max):
		_gl._physics_process(DT)
		if not _gl.shop_ui.is_shop_visible():
			return i + 1
	return -1


func _kill_player() -> void:
	# 必死一击（pkg4 Q-16 简化路径）：清复活/护盾/无敌 → 接触伤害超血线
	var p := _gl.player
	p.set("revives_left", 0)
	p.set("shield_ready", false)
	p.set("invuln_left", 0.0)
	p.take_contact_damage(float(p.get("hp")) + 1.0)


func _find_node(p_root: Node, p_name: String) -> Node:
	if String(p_root.name) == p_name:
		return p_root
	for c in p_root.get_children():
		var found := _find_node(c, p_name)
		if found != null:
			return found
	return null


func _find_auto_btn(p_root: Node) -> Button:
	# AUTO 开关通用定位（并行落地名未锁死：name Auto* 或 text 含 AUTO）
	if p_root is Button:
		var b := p_root as Button
		if String(b.name).begins_with("Auto") or b.text.to_upper().contains("AUTO"):
			return b
	for c in p_root.get_children():
		var found := _find_auto_btn(c)
		if found != null:
			return found
	return null


func _on_choice_made_spy(p_cards: Array) -> void:
	_choice_sizes.append(p_cards.size())


func _on_card_chosen_spy(_p_id: StringName, _p_kind: int) -> void:
	_card_chosen_count += 1


func _on_wave_started_spy(_p_wave: int) -> void:
	_wave_started_count += 1


# ── A 设置段（settings 白名单双接线） ─────────────────────────────
func _test_a_settings() -> void:
	print("── A 设置段（auto_select_on / auto_restart_mode 双接线） ──")
	# 出厂默认（旧档缺键回默认零迁移——内存抹键模拟缺键，读口回默认表）
	Meta._settings.erase("auto_select_on")
	Meta._settings.erase("auto_restart_mode")
	_check("A 出厂默认：auto_select_on == false", Meta.settings("auto_select_on") == false,
		str(Meta.settings("auto_select_on")))
	_check("A 出厂默认：auto_restart_mode == 0", Meta.settings("auto_restart_mode") == 0,
		str(Meta.settings("auto_restart_mode")))
	# 越界钳制（照 fx_quality clampi(0,2) 行口径）
	Meta.set_setting("auto_restart_mode", 9)
	_check("A 越界钳制：9 → 2", Meta.settings("auto_restart_mode") == 2,
		str(Meta.settings("auto_restart_mode")))
	Meta.set_setting("auto_restart_mode", -3)
	_check("A 越界钳制：-3 → 0", Meta.settings("auto_restart_mode") == 0,
		str(Meta.settings("auto_restart_mode")))
	Meta.set_setting("auto_restart_mode", 1)
	_check("A 合法值：1 → 1", Meta.settings("auto_restart_mode") == 1)
	# 未知键忽略（白名单外静默丢弃——写读双侧）
	Meta.set_setting("auto_pick_unknown", 1)
	_check("A 未知键忽略：读口 null", Meta.settings("auto_pick_unknown") == null)
	_check("A 未知键忽略：未入 _settings", not Meta._settings.has("auto_pick_unknown"))
	# 磁盘回路：写即落盘 → _load() 回读 true
	Meta.set_setting("auto_select_on", true)
	var cfg := ConfigFile.new()
	var err := cfg.load(Meta.save_path())
	var vals: Variant = cfg.get_value("settings", "values", {}) if err == OK else {}
	_check("A 磁盘回路：写即落盘（settings/values.auto_select_on==true）",
		vals is Dictionary and bool((vals as Dictionary).get("auto_select_on", false)),
		str(vals))
	var snap: Dictionary = Meta._settings.duplicate()
	Meta._settings = {}
	Meta._load()
	_check("A 磁盘回路：_load() 回读 true", bool(Meta._settings.get("auto_select_on", false)),
		str(Meta._settings))
	# 快照还原（_load 重读磁盘全段——还原后重放测试隔离）
	Meta._settings = snap.duplicate()
	Meta._save()
	_check("A 快照还原：_settings 一致", Meta._settings == snap)
	Meta.upgrades = {}
	Meta.crystals = 0
	Meta.character_id = &"sentinel"
	Meta.set_setting("auto_select_on", false)     # B/C/D 组前置：OFF
	Meta.set_setting("auto_restart_mode", 0)


# ── B AUTO 开关（存在性 / 几何 / 落盘 / 四态可见性） ───────────────
func _test_b_toggle() -> void:
	print("── B AUTO 开关（几何与可见性） ──")
	var btn := _find_auto_btn(_gl.hud)
	_check("B 开关存在（AUTO 胶囊按钮挂 HUD）", btn != null)
	if btn == null:
		return
	_check("B 开关几何：落位 x∈[644,704]×y∈[126,190] 唯一空闲带",
		btn.position.x >= 644.0 and btn.position.x + btn.size.x <= 704.0
		and btn.position.y >= 126.0 and btn.position.y + btn.size.y <= 190.0,
		"pos=%s size=%s" % [str(btn.position), str(btn.size)])
	var auto_rect := Rect2(btn.position, btn.size)
	var pause_rect := Rect2(_gl.hud._pause_btn.position, _gl.hud._pause_btn.size)
	_check("B 开关几何：与暂停钮矩形不相交", not auto_rect.intersects(pause_rect),
		"auto=%s pause=%s" % [str(auto_rect), str(pause_rect)])
	_check("B 开关几何：与波次徽章矩形不相交", not auto_rect.intersects(BADGE_RECT),
		"auto=%s badge=%s" % [str(auto_rect), str(BADGE_RECT)])
	# 点击翻转落盘（读写走 Meta 单一真源，无缓存 bool）
	var st0: bool = bool(Meta.settings("auto_select_on"))
	btn.pressed.emit()
	_check("B 点击翻转：Meta 落值取反", bool(Meta.settings("auto_select_on")) == (not st0),
		str(Meta.settings("auto_select_on")))
	var cfg := ConfigFile.new()
	var ok := cfg.load(Meta.save_path()) == OK
	var vals: Variant = cfg.get_value("settings", "values", {}) if ok else {}
	_check("B 点击翻转：写即落盘", vals is Dictionary
		and bool((vals as Dictionary).get("auto_select_on", false)) == (not st0), str(vals))
	btn.pressed.emit()
	_check("B 二次点击：回原值（无缓存态）", bool(Meta.settings("auto_select_on")) == st0)
	# 可见态：PLAYING + LEVEL_UP（不照抄暂停钮仅 PLAYING）；MENU/PAUSED/GAME_OVER 隐藏
	_check("B 可见性：MENU 隐藏", not btn.visible)
	_check("B 可见性：PLAYING 显示",
		_gl.start_run() and _gl.state == GameConst.GameStatus.PLAYING and btn.visible)
	_gl._on_level_up(2)
	_check("B 可见性：LEVEL_UP 显示",
		_gl.state == GameConst.GameStatus.LEVEL_UP and btn.visible)
	_gl.card_select_ui.choose(0)
	_check("B 清场：选卡回 PLAYING", _gl.state == GameConst.GameStatus.PLAYING)
	_gl.request_pause()
	_check("B 可见性：PAUSED 隐藏",
		_gl.state == GameConst.GameStatus.PAUSED and not btn.visible)
	_gl.request_resume()
	_kill_player()
	_check("B 可见性：GAME_OVER 隐藏",
		_gl.state == GameConst.GameStatus.GAME_OVER and not btn.visible)
	_gl.quit_to_menu()
	_check("B 可见性：回 MENU 隐藏",
		_gl.state == GameConst.GameStatus.MENU and not btn.visible)


# ── C 选卡真链（0.5s 展示窗 / 成对协议 / 诅咒硬不变量 / OFF 零干预） ──
func _test_c_auto_pick() -> void:
	print("── C 选卡真链 ──")
	Meta.set_setting("auto_select_on", true)
	_gl.card_generator.rng.seed = 4242
	_check("C 前置：常规局开局", _gl.start_run() and _gl.state == GameConst.GameStatus.PLAYING)
	# C1 ON 自动选：升级 → 0.6s 内恰一次（含 pkg4_cases.gd:296 文案口径）
	_choice_sizes.clear()
	var cc0 := _card_chosen_count
	_gl.player.gain_xp(_gl.player.xp_need)
	_check("C1 前置：升级弹卡（LEVEL_UP）",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open)
	_check("C1 pkg4:296 口径：0.5s 展示窗内 LEVEL UP 文案不变",
		_gl.hud._state_label.text == "LEVEL UP - choose a card",
		str(_gl.hud._state_label.text))
	var used := _drive_until_state(GameConst.GameStatus.PLAYING, PICK_WINDOW_FRAMES)
	_check("C1 0.6s 内自动选完成", used > 0 and used <= PICK_WINDOW_FRAMES,
		"frames=%d" % used)
	_check("C1 choice_made 恰一次（普通单张）",
		_choice_sizes.size() == 1 and _choice_sizes[0] == 1, str(_choice_sizes))
	_check("C1 card_chosen 恰 +1（图鉴口径）", _card_chosen_count == cc0 + 1,
		"%d → %d" % [cc0, _card_chosen_count])
	_check("C1 state 回 PLAYING", _gl.state == GameConst.GameStatus.PLAYING)
	# C2 双级连升逐次消化（排队 → 每级各选一次）。R189 同 r188_idle_cases 口径：
	# 经验余量随击杀拾取浮动（spawner rng randomize 非确定性夹具），固定 2.5×xp_need
	# 单发投喂在高等级段只跨一个阈值——改按 1.2×need 逐次投喂至恰 +2 级（每次投喂
	# 至多跨 1 阈值，曲线单调递增保证），连升形态确定。
	_choice_sizes.clear()
	var cc1 := _card_chosen_count
	var lv0 := int(_gl.player.get("level"))
	var feeds := 0
	while int(_gl.player.get("level")) < lv0 + 2 and feeds < 40:
		_gl.player.gain_xp(_gl.player.xp_need * 1.2)
		feeds += 1
	_check("C2 前置：双级连升首级弹卡 + 排队 1（投喂 %d 次）" % feeds,
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.pending_level_ups == 1,
		"pending=%d lv=%d" % [_gl.pending_level_ups, int(_gl.player.get("level"))])
	var used2 := -1
	for i in range(200):
		_gl._physics_process(DT)
		if _gl.state == GameConst.GameStatus.PLAYING and _gl.pending_level_ups == 0:
			used2 = i + 1
			break
	_check("C2 逐次消化：两次各选 1 次后回 PLAYING",
		used2 > 0 and _choice_sizes.size() == 2 and _gl.pending_level_ups == 0,
		"frames=%d sizes=%s" % [used2, str(_choice_sizes)])
	_check("C2 card_chosen 恰 +2", _card_chosen_count == cc1 + 2,
		"%d → %d" % [cc1, _card_chosen_count])
	# C3 成对槽位协议（地狱 → dual）：策略槽位 ∈[4,9]，choose 后整行 2 张
	_choice_sizes.clear()
	_gl._difficulty = 2                           # 地狱 → GameConst.difficulty_dual_pick 恒真
	var cc2 := _card_chosen_count
	_gl.player.gain_xp(_gl.player.xp_need)
	_check("C3 前置：地狱成对货架 6 卡",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.current_candidates.size() == 6,
		"n=%d" % _gl.current_candidates.size())
	var slot_probe := AutoIdleStrategy.pick(_gl.current_candidates, true)
	_check("C3 成对策略槽位 ∈[4,9]", slot_probe >= 4 and slot_probe <= 9, "slot=%d" % slot_probe)
	var used3 := _drive_until_state(GameConst.GameStatus.PLAYING, PICK_WINDOW_FRAMES)
	_check("C3 成对整行：choice_made 载荷 2 张",
		used3 > 0 and _choice_sizes.size() == 1 and _choice_sizes[0] == 2,
		"frames=%d sizes=%s" % [used3, str(_choice_sizes)])
	_check("C3 card_chosen 恰 +2（成对两卡各应用一次）", _card_chosen_count == cc2 + 2,
		"%d → %d" % [cc2, _card_chosen_count])
	_gl._difficulty = 0                           # 还原难度（后续组常规口径）
	# C4 诅咒硬不变量：200 seed 扫描（GAMBLER 诅咒局面，含成对 6 卡）恒指向非诅咒卡/行
	var gen := _gl.card_generator
	var ctx := {"player": _gl.player, "wave": 30, "deal_count": 6, "curse_last": true,
		"min_rarity_floor": -1}
	var scenarios := 0
	var ok_curse := true
	var detail := ""
	for s in range(CURSE_SCAN_SEEDS):
		gen.rng.seed = s
		gen._slot_rng.seed = s
		var cands := gen.generate_candidates(ctx)
		if cands.size() < 4 or not bool(cands[3].get("cursed", false)):
			ok_curse = false
			detail = "seed=%d 非诅咒局面（夹具失真）" % s
			break
		scenarios += 1
		var i_single := AutoIdleStrategy.pick(cands, false)
		if i_single < 0 or i_single >= cands.size() \
				or bool(cands[i_single].get("cursed", false)):
			ok_curse = false
			detail = "seed=%d 普通输出指向诅咒（i=%d）" % [s, i_single]
			break
		var slot := AutoIdleStrategy.pick(cands, true)
		if slot < 4 or slot > 9:
			ok_curse = false
			detail = "seed=%d 成对输出越界（slot=%d）" % [s, slot]
			break
		for k in range(2):
			var li := slot - 4 + k
			if li < cands.size() and bool(cands[li].get("cursed", false)):
				ok_curse = false
				detail = "seed=%d 成对行含诅咒（slot=%d）" % [s, slot]
				break
		if not ok_curse:
			break
	_check("C4 诅咒硬不变量：%d seed 扫描（含成对 6 卡）恒指向非诅咒卡/行"
		% CURSE_SCAN_SEEDS, ok_curse and scenarios == CURSE_SCAN_SEEDS, detail)
	# C5 OFF 零干预
	Meta.set_setting("auto_select_on", false)
	_choice_sizes.clear()
	_gl.player.gain_xp(_gl.player.xp_need)
	_check("C5 前置：OFF 弹卡",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open)
	_drive_frames(120)                            # 1s > 0.6s 窗
	_check("C5 OFF 零干预：1s 后仍 LEVEL_UP 未选",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open
		and _choice_sizes.is_empty(), str(_choice_sizes))
	_gl.card_select_ui.choose(0)
	_check("C5 清场：回 PLAYING", _gl.state == GameConst.GameStatus.PLAYING)


# ── D 商店自动离店（零损失；三源汇总口 + 战前补给源） ──────────────
func _test_d_shop() -> void:
	print("── D 商店自动离店 ──")
	Meta.set_setting("auto_select_on", true)
	# D1 三源汇总口（波表 SHOP / REL_BLACK_MARKET 中继同汇 _on_shop_requested）
	var g0 := int(_gl.player.get("gold"))
	_gl._on_shop_requested(5)
	_check("D1 前置：黑市开店（LEVEL_UP）",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.shop_ui.is_shop_visible())
	var used := _drive_until_shop_closed(SHOP_WINDOW_FRAMES)
	_check("D1 0.8s 后自动离店", used > 0 and used <= SHOP_WINDOW_FRAMES, "frames=%d" % used)
	_check("D1 state 回 PLAYING", _gl.state == GameConst.GameStatus.PLAYING)
	_check("D1 金币零变动（不代买不烧金）", int(_gl.player.get("gold")) == g0,
		"%d → %d" % [g0, int(_gl.player.get("gold"))])
	# D2 战前补给源（final Boss 波前一波清空 → 固定商店）
	var final_wave := int(MapTable.get_map(_gl.current_map_id).get("final_wave", 10))
	var g1 := int(_gl.player.get("gold"))
	_gl._on_wave_cleared_pre_boss_shop(final_wave - 1)
	_check("D2 前置：战前补给开店",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.shop_ui.is_shop_visible())
	var used2 := _drive_until_shop_closed(SHOP_WINDOW_FRAMES)
	_check("D2 战前补给自动离店", used2 > 0 and used2 <= SHOP_WINDOW_FRAMES,
		"frames=%d" % used2)
	_check("D2 金币零变动", int(_gl.player.get("gold")) == g1,
		"%d → %d" % [g1, int(_gl.player.get("gold"))])
	Meta.set_setting("auto_select_on", false)


# ── E 结算四案（mode0 负向 / mode1 重开+点按取消 / mode2 自动无尽 / 每日回退） ──
func _test_e_settle() -> void:
	print("── E 结算自动重开 ──")
	Meta.set_setting("auto_select_on", false)     # E 组只测重开域（选卡域 C 组已锁）
	Meta.set_setting("auto_restart_mode", 0)
	# E1 mode0 负向：死亡 5s 不重开、无倒计时挂起、结算恰 +1
	var runs0 := int(Meta.records["total_runs"])
	_kill_player()
	_check("E1 前置：死亡进 GAME_OVER", _gl.state == GameConst.GameStatus.GAME_OVER)
	_drive_frames(600)                            # 5s
	_check("E1 mode0 负向：5s 仍 GAME_OVER 不重开", _gl.state == GameConst.GameStatus.GAME_OVER)
	_check("E1 mode0 负向：无倒计时挂起", not _gl.game_over_screen.is_auto_countdown_active())
	_check("E1 mode0 结算恰 +1", int(Meta.records["total_runs"]) == runs0 + 1,
		"%d → %d" % [runs0, int(Meta.records["total_runs"])])
	_check("E1 mode0 手动重开放行（既有契约）",
		_gl.restart_run() and _gl.state == GameConst.GameStatus.PLAYING)
	# E2 mode1 点按取消：倒计时挂起 → 按 RestartButton → 取消不重开（无双记）
	Meta.set_setting("auto_restart_mode", 1)
	var runs1 := int(Meta.records["total_runs"])
	_kill_player()
	_drive_frames(120)                            # 1s（< 3s 倒计时）
	var cd_label := _find_node(_gl.game_over_screen, "AutoCountdownLabel") as Label
	_check("E2 mode1 倒计时挂起（GameLoop 每帧喂秒）",
		_gl.game_over_screen.is_auto_countdown_active()
		and _gl.game_over_screen.auto_countdown_left() > 0.0,
		"active=%s left=%f" % [str(_gl.game_over_screen.is_auto_countdown_active()),
		_gl.game_over_screen.auto_countdown_left()])
	_check("E2 倒计时文案：卡面内 Label（N 秒后自动再来一局 · 点按取消）",
		cd_label != null and cd_label.visible
		and cd_label.text.contains("秒后自动再来一局")
		and cd_label.text.contains("点按取消"),
		str(cd_label.text if cd_label != null else "<null>"))
	var restart_btn := _find_node(_gl.game_over_screen, "RestartButton") as Button
	_check("E2 前置：RestartButton 在", restart_btn != null)
	restart_btn.pressed.emit()
	_check("E2 点按取消：立即回 PLAYING", _gl.state == GameConst.GameStatus.PLAYING)
	_check("E2 点按取消：倒计时撤销 + 文案收起",
		not _gl.game_over_screen.is_auto_countdown_active()
		and (cd_label == null or not cd_label.visible))
	var ws_mark := _wave_started_count
	_drive_frames(360)                            # 再 3s：残留计时若未取消会二次重开
	_check("E2 点按取消：无二次重开（wave_started 不再派发）",
		_wave_started_count == ws_mark, "%d vs %d" % [_wave_started_count, ws_mark])
	_check("E2 mode1 结算恰 +1（无双记）", int(Meta.records["total_runs"]) == runs1 + 1,
		"%d → %d" % [runs1, int(Meta.records["total_runs"])])
	# E3 mode1 不干预：~3s 自动重开 + total_runs 恰 +1
	var runs2 := int(Meta.records["total_runs"])
	_kill_player()
	var used := _drive_until_state(GameConst.GameStatus.PLAYING, RESTART_WINDOW_FRAMES)
	_check("E3 mode1 ~3s 自动重开", used > 0 and used <= RESTART_WINDOW_FRAMES,
		"frames=%d" % used)
	_check("E3 mode1 结算恰 +1（无双记）", int(Meta.records["total_runs"]) == runs2 + 1,
		"%d → %d" % [runs2, int(Meta.records["total_runs"])])
	# E4 mode2 通关自动无尽：通关屏 ~3s → continue_endless 真链（波次越过 final_wave）
	Meta.set_setting("auto_restart_mode", 2)
	_check("E4 前置：非每日局", not Meta.is_run_daily())
	var final_wave := int(MapTable.get_map(_gl.current_map_id).get("final_wave", 10))
	_gl._on_wave_cleared_victory(final_wave)      # 清 final 波 → 2.2s 收尾窗 → 通关屏
	var vused := _drive_until_state(GameConst.GameStatus.GAME_OVER, VICTORY_WINDOW_FRAMES)
	_check("E4 前置：通关收尾窗 → 通关屏（无尽出口可见）",
		vused > 0 and _gl.game_over_screen.is_endless_offer_visible(),
		"frames=%d" % vused)
	var eused := _drive_until_state(GameConst.GameStatus.PLAYING, RESTART_WINDOW_FRAMES)
	_check("E4 mode2 ~3s 自动无尽", eused > 0, "frames=%d" % eused)
	_check("E4 波次越过 final_wave（continue_endless 真链）",
		_gl.wave_director.current_wave > final_wave,
		"wave=%d final=%d" % [_gl.wave_director.current_wave, final_wave])
	_gl.request_pause()
	_gl.quit_to_menu()                            # PAUSED → MENU（清场）
	# E5 每日局回退：mode1/2 一律停结算（5s 后仍 GAME_OVER）
	_check("E5 前置：每日局开局",
		_gl.start_run(Meta.daily_seed(Meta.daily_date_key())) and Meta.is_run_daily())
	_kill_player()
	_drive_frames(600)                            # 5s
	_check("E5 每日局 mode2 回退：5s 仍 GAME_OVER", _gl.state == GameConst.GameStatus.GAME_OVER)
	Meta.set_setting("auto_restart_mode", 1)
	_check("E5 每日局手动重开放行", _gl.restart_run()
		and _gl.state == GameConst.GameStatus.PLAYING)
	_kill_player()
	_drive_frames(600)
	_check("E5 每日局 mode1 回退：5s 仍 GAME_OVER", _gl.state == GameConst.GameStatus.GAME_OVER)
	Meta.set_setting("auto_restart_mode", 0)
	_gl.quit_to_menu()                            # GAME_OVER → MENU（清场）


# ── F 全链 soak（全开 + mode2 ≥3000 帧；无 >10s 停留 / 波次单调不减） ──
func _test_f_soak() -> void:
	print("── F 全链 soak ──")
	Meta.set_setting("auto_select_on", true)
	Meta.set_setting("auto_restart_mode", 2)
	_check("F 前置：常规局开局", _gl.start_run() and _gl.state == GameConst.GameStatus.PLAYING)
	_gl.player.set("max_hp", 1000000.0)           # 存活性垫层（ soak 不测死亡数值，测出口不漏接）
	_gl.player.set("hp", 1000000.0)
	_choice_sizes.clear()
	var prev_wave := _gl.wave_director.current_wave
	var prev_state := _gl.state
	var lu_streak := 0
	var go_streak := 0
	var max_lu := 0
	var max_go := 0
	var wave_violations := 0
	var max_wave := prev_wave
	for i in range(SOAK_FRAMES):
		_gl._physics_process(DT)
		var st := _gl.state
		lu_streak = (lu_streak + 1) if st == GameConst.GameStatus.LEVEL_UP else 0
		go_streak = (go_streak + 1) if st == GameConst.GameStatus.GAME_OVER else 0
		max_lu = maxi(max_lu, lu_streak)
		max_go = maxi(max_go, go_streak)
		# 重开瞬间（GAME_OVER→PLAYING）波次合法归 1——单帧豁免；其余波次回退均计违例
		var grace := prev_state == GameConst.GameStatus.GAME_OVER \
			and st == GameConst.GameStatus.PLAYING
		var w := _gl.wave_director.current_wave
		if w < prev_wave and not grace:
			wave_violations += 1
		prev_wave = w
		max_wave = maxi(max_wave, w)
		prev_state = st
	_check("F soak：LEVEL_UP 连续停留 ≤10s（1200 帧）", max_lu <= STREAK_CAP,
		"max=%d" % max_lu)
	_check("F soak：GAME_OVER 连续停留 ≤10s（1200 帧）", max_go <= STREAK_CAP,
		"max=%d" % max_go)
	_check("F soak：波次单调不减（重开瞬间豁免）", wave_violations == 0,
		"violations=%d" % wave_violations)
	# 遥测（如实报告，不作硬断言：推进速度依赖自然战斗强度）
	print("[auto_idle soak] 遥测：max_wave=%d 自动选卡 %d 次 max_lu=%d帧 max_go=%d帧 波次违例=%d"
		% [max_wave, _choice_sizes.size(), max_lu, max_go, wave_violations])

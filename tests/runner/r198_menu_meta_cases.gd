# tests/runner/r198_menu_meta_cases.gd
# R198 组4「菜单成长」用例体（由 test_r198_menu_meta.gd 入口在 autoload 就绪后运行时加载）。
# 覆盖 A~G 七组（分组见套件头注）；文案断言一律对表/真值（Meta.UPGRADES、
# CharacterTable、MapTable final_wave），禁止硬抄数值口径。
# 夹具：MenuScreen 裸实例 + DataRegistry 裸载（manifest 直驱，game_loop._boot_load_data
# 同式）——本套件零战斗零 GameLoop（菜单/结算兑现/大厅几何均在 MENU 域自足）。
# 纪律：headless 测试档自动隔离（meta_save_test.cfg）；套件首尾快照/还原 Meta 全量
# 运行态防跨套件污染（verify_feedback/r191 F17 同式）；窗口尺寸改后必还原。
extends RefCounted

const MANIFEST_PATH := "res://data/manifest.cfg"   # game_loop.MANIFEST_PATH 同值（组2 文件零依赖）
const CHAR_IDS: Array[StringName] = [&"sentinel", &"veles", &"bulwark", &"ranger",
	&"zero", &"mank", &"vera", &"noah", &"fission", &"echo"]
const NAME_L_WIDTH_PX := 406.0       # 选人卡 name_l 格宽（menu_screen authoring 值）
const NAME_L_FONT_PX := 20.0         # name_l 20pt——估宽口径：全角 1em / 半角 0.5em

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _menu: MenuScreen = null
var _registry: DataRegistry = null
var _bk: Dictionary = {}
var _win_size0 := Vector2i(540, 960)


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(198)
	_snapshot_meta()
	_boot_menu()
	await tree.process_frame
	await tree.process_frame
	_test_a_revive_desc()               # A 二aw-4（无行为：表断言）
	_test_b_skill_icons()               # B 二aw-5（贴纸像素采样哈希）
	_test_f_rxn_mult_wrap()             # F R192-low8（图鉴反应行）
	_test_g_noah_companion()            # G P2-skillcopy（表 + 选人行）
	await _test_c_echo_edge_badge()     # C 二aw-6（结算兑现边沿 + 角标）
	await _test_d_fission_hint_wrap()   # D 二aw-7（锁定句 + autowrap）
	await _test_e_lobby_scroll_center() # E r195-4（居中锚几何，最后跑——动窗口）
	_restore_meta()
	_teardown_menu()
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
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


# ── 环境（r197_build_panel_cases 同式） ───────────────────────────
func _snapshot_meta() -> void:
	_bk = {
		"records": Meta.records.duplicate(true),
		"map_records": Meta.map_records.duplicate(true),
		"maps_cleared": Meta.maps_cleared.duplicate(true),
		"daily_records": Meta.daily_records.duplicate(true),
		"achievements_done": Meta.achievements_done.duplicate(true),
		"codex_kills": Meta.codex_kills.duplicate(true),
		"codex_weapons": Meta.codex_weapons.duplicate(true),
		"codex_traits": Meta.codex_traits.duplicate(true),
		"unlocked_characters": Meta.unlocked_characters.duplicate(true),
		"upgrades": Meta.upgrades.duplicate(true),
		"crystals": Meta.crystals,
		"character_id": Meta.character_id,
		"custom_weapon_id": Meta.custom_weapon_id,
	}


func _restore_meta() -> void:
	Meta.records = _bk["records"]
	Meta.map_records = _bk["map_records"]
	Meta.maps_cleared = _bk["maps_cleared"]
	Meta.daily_records = _bk["daily_records"]
	Meta.achievements_done = _bk["achievements_done"]
	Meta.codex_kills = _bk["codex_kills"]
	Meta.codex_weapons = _bk["codex_weapons"]
	Meta.codex_traits = _bk["codex_traits"]
	Meta.unlocked_characters = _bk["unlocked_characters"]
	Meta.upgrades = _bk["upgrades"]
	Meta.crystals = int(_bk["crystals"])
	Meta.character_id = _bk["character_id"]
	Meta.custom_weapon_id = String(_bk["custom_weapon_id"])
	Meta.set_run_map(MapTable.FIRST_MAP_ID)
	Meta.set_run_difficulty(GameConst.Difficulty.NORMAL)
	Meta.set_run_daily(false)
	Meta._save()


func _normalize_window_for_boot() -> void:
	# 同 r194/r195/r196/r197：-s 脚本模式根窗口归一（canvas 域恒等 720×1280）
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
	_win_size0 = Vector2i(
		int(ProjectSettings.get_setting("display/window/size/window_width_override", 540)),
		int(ProjectSettings.get_setting("display/window/size/window_height_override", 960)))
	win.size = _win_size0


func _boot_menu() -> void:
	# MenuScreen 裸实例 + DataRegistry 裸载（game_loop._boot_load_data 同式）——
	# 零 GameLoop：组2 并行期 player.gd/game_loop.gd 的解析态不影响本套件
	_normalize_window_for_boot()
	_registry = DataRegistry.new()
	_registry.load_all(MANIFEST_PATH)
	_menu = MenuScreen.new()
	_menu.name = "R198MenuScreenUnderTest"
	_menu.registry = _registry
	tree.get_root().add_child(_menu)               # _ready：建 UI + 挂 Meta 信号（:70-72）
	_check("前置：MenuScreen/registry 就绪",
		_menu != null and _menu.registry != null
		and _menu.registry.enemies.size() > 0)


func _teardown_menu() -> void:
	tree.paused = false
	RunSave.clear()
	var win: Window = tree.root
	win.size = _win_size0                          # 窗口尺寸还原（E 段动过）
	if _menu != null:
		_menu.free()
		_menu = null


# ══ A 二aw-4：养成 revive desc 2s→3s（真值 REVIVE_INVULN_S=3.0） ══
func _test_a_revive_desc() -> void:
	print("── A 二aw-4：养成面板复活文案对齐 REVIVE_INVULN_S=3.0 ──")
	var found := false
	var desc := ""
	for u in Meta.UPGRADES:
		if String(u.id) == "revive":
			found = true
			desc = String(u.desc)
	_check("A1 revive 项在册且 desc 含「3s 无敌」",
		found and desc.contains("3s 无敌"), "desc=%s" % desc)
	_check("A2 revive desc 无「2s」残留（全表唯一文案源）",
		found and not desc.contains("2s"), "desc=%s" % desc)
	# A3 真值锚走源级（不静态引 Player 类——组2 文件并行期解析态不受制于人）：
	# REVIVE_INVULN_S := 3.0（player.gd 复活无敌常量，文案从实现取值）
	var psrc := FileAccess.get_file_as_string("res://scripts/entities/player/player.gd")
	_check("A3 真值锚：player.gd 含「REVIVE_INVULN_S := 3.0」（文案从实现取值）",
		psrc.contains("REVIVE_INVULN_S := 3.0"))


# ══ B 二aw-5：skill_icon 10 角色两两互异 + fission/echo 非默认星 ══
func _tex_sample_hash(p_tex: ImageTexture) -> int:
	# 像素采样哈希（隔行隔列步进 2——覆盖整幅的确定性采样；Image.get_image 副本零副作用）
	var img := p_tex.get_image()
	var acc := PackedFloat32Array()
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			acc.append(c.r)
			acc.append(c.g)
			acc.append(c.b)
			acc.append(c.a)
	return hash(acc)


func _test_b_skill_icons() -> void:
	print("── B 二aw-5：fission/echo 专属技能图标（贴纸口径 64px） ──")
	var hashes: Dictionary = {}
	var sizes_ok := true
	for cid in CHAR_IDS:
		var tex := TextureFactory.skill_icon(cid)
		if tex == null or tex.get_width() != 64 or tex.get_height() != 64:
			sizes_ok = false
			continue
		hashes[String(cid)] = _tex_sample_hash(tex)
	_check("B1 10 角色 skill_icon 64px 画布全就绪（既有口径）", sizes_ok and hashes.size() == 10,
		"n=%d" % hashes.size())
	var distinct := true
	var ids: Array = hashes.keys()
	for i in range(ids.size()):
		for j in range(i + 1, ids.size()):
			if int(hashes[ids[i]]) == int(hashes[ids[j]]):
				distinct = false
	_check("B2 10 角色 skill_icon 像素采样哈希两两互异", distinct)
	var default_hash := _tex_sample_hash(TextureFactory.skill_icon(StringName("__default_probe__")))
	_check("B3 fission 非默认星（与 `_:` 通用星产物不等）",
		int(hashes.get("fission", -1)) != default_hash)
	_check("B4 echo 非默认星（与 `_:` 通用星产物不等）",
		int(hashes.get("echo", -1)) != default_hash)
	_check("B5 默认分支保留（未知 id 仍落通用星兜底）", default_hash != 0)


# ══ C 二aw-6：echo_unlocked 边沿恰发一次 + 角标 + fission 不回退 ══
func _settle_one_run(p_wave: int) -> void:
	# 单局结算夹具（verify_feedback R186/E11 同式：直调 _settle_run_result）
	Meta._run_max_wave = p_wave
	Meta._run_kills = 0
	Meta._run_max_level = 5
	Meta._settle_run_result()


func _test_c_echo_edge_badge() -> void:
	print("── C 二aw-6：echo 解锁角标 + toast（边沿信号） ──")
	var echo_fired: Array[int] = [0]
	var fis_fired: Array[int] = [0]
	var cb_echo := func() -> void: echo_fired[0] += 1
	var cb_fis := func() -> void: fis_fired[0] += 1
	Meta.echo_unlocked.connect(cb_echo)
	Meta.fissioner_unlocked.connect(cb_fis)
	var bk_maps: Dictionary = Meta.map_records.duplicate(true)
	var bk_records: Dictionary = Meta.records.duplicate(true)
	var bk_crystals: int = Meta.crystals
	var bk_badge: bool = _menu._char_new_badge
	var final_wave := int(MapTable.get_map(&"world_grass").get("final_wave", 10))
	# ① 硬通关结算前无档 → echo_unlocked 恰发一次 + badge 置位
	Meta.map_records = {}
	_menu._char_new_badge = false
	Meta.set_run_map(&"world_grass")
	Meta.set_run_difficulty(GameConst.Difficulty.HARD)
	Meta.set_run_daily(false)
	_settle_one_run(final_wave)
	_check("C1 硬通关（HARD）结算前无档 → echo_unlocked 恰发一次",
		echo_fired[0] == 1, "fired=%d" % echo_fired[0])
	_check("C2 大厅「角色 ·新」角标置位（复用 fissioner 处理器）", _menu._char_new_badge)
	_check("C3 hard_cleared 落档翻真（#1 分档键）", Meta.hard_cleared())
	_check("C4 fissioner 边沿未误触（普通门不吃 #1 分档键——R186 口径不回退）", fis_fired[0] == 0)
	# ② 已困难通关存档重复结算 → 不重发（恰发一次边沿）
	_settle_one_run(final_wave + 2)
	_check("C5 已困难通关重复结算 → echo_unlocked 不重发（边沿恰一次）",
		echo_fired[0] == 1, "fired=%d" % echo_fired[0])
	# ③ 每日分流语义与 fission 对齐：每日局不落分档记录 → 无新边沿
	Meta.map_records = {}
	_menu._char_new_badge = false
	Meta.set_run_daily(true)
	_settle_one_run(final_wave)
	_check("C6 每日局硬通关结算 → 不发 echo_unlocked（分流语义对齐 fission）",
		echo_fired[0] == 1 and not Meta.hard_cleared(), "fired=%d" % echo_fired[0])
	Meta.set_run_daily(false)
	# ④ fission 旧边沿不回退：普通通关结算恰发一次，重复结算不重发
	Meta.map_records = {}
	Meta.set_run_difficulty(GameConst.Difficulty.NORMAL)
	_settle_one_run(final_wave)
	_check("C7 首次普通通关结算 → fissioner_unlocked 恰发一次（R186 行为不回退）",
		fis_fired[0] == 1, "fired=%d" % fis_fired[0])
	_settle_one_run(final_wave + 1)
	_check("C8 已普通通关重复结算 → fissioner_unlocked 不重发",
		fis_fired[0] == 1, "fired=%d" % fis_fired[0])
	Meta.echo_unlocked.disconnect(cb_echo)
	Meta.fissioner_unlocked.disconnect(cb_fis)
	Meta.map_records = bk_maps
	Meta.records = bk_records
	Meta.crystals = bk_crystals
	_menu._char_new_badge = bk_badge
	Meta._save()
	await tree.process_frame


# ══ D 二aw-7：fission 锁定句压缩 + name_l autowrap 兜底 ══
func _est_text_w(p_text: String, p_px: float) -> float:
	# 估宽：>0x2E7F（CJK/全角区）计 1em，其余计 0.5em（20pt 汉字 advance ≈ 字号）
	var w := 0.0
	for i in range(p_text.length()):
		w += p_px if p_text.unicode_at(i) > 0x2E7F else p_px * 0.5
	return w


func _find_char_name_label(p_name_prefix: String) -> Label:
	for row_v in _menu._panel_list.get_children():
		var row := row_v as Control
		if row == null or row.is_queued_for_deletion():
			continue                              # 页签重建 queue_free 残留行（帧末才除名）不参与
		for ch_v in row.get_children():
			var l := ch_v as Label
			if l != null and l.text.begins_with(p_name_prefix):
				return l
	return null


func _test_d_fission_hint_wrap() -> void:
	print("── D 二aw-7：fission 锁定句溢出收敛 + autowrap 兜底 ──")
	var bk_maps: Dictionary = Meta.map_records.duplicate(true)
	var bk_char: StringName = Meta.character_id
	Meta.map_records = {}                          # 无档 → fission 锁定（hint 分支可进）
	Meta.character_id = &"sentinel"                # 探针口径直写（防「✓ 当前」段混入估宽）
	_menu._on_lobby_pressed("char")                # 打开选人面板（badge 清除逻辑同区验证）
	var name_l := _find_char_name_label("改造者·枢")
	_check("D1 fission 行 name_l 定位", name_l != null)
	if name_l == null:
		Meta.map_records = bk_maps
		Meta.character_id = bk_char
		return
	var txt := name_l.text
	var name_len := String(CharacterTable.get_character(&"fission").get("name", "改造者·枢")).length()
	var hint := txt.substr(name_len).trim_prefix("　")   # 剥角色名 + 行首全角空格 = hint 段
	_check("D2 fission hint 以「通关普通难度解锁」开头（压缩句式）",
		hint.begins_with("通关普通难度解锁"), "hint=%s" % hint)
	_check("D3 fission hint 已删「当前最佳/任一地图」段（取舍：记录/成就面可见）",
		not txt.contains("当前最佳") and not txt.contains("任一地图"), "txt=%s" % txt)
	var est := _est_text_w(txt, NAME_L_FONT_PX)
	# D4 双口径：规划估宽式（全角 1em/半角 0.5em）+ 真字型实测（theme font() @20pt）——
	# 实测为准、估宽对账规划口径
	var measured := StickerTheme.font().get_string_size(
		txt, HORIZONTAL_ALIGNMENT_LEFT, -1.0, int(NAME_L_FONT_PX)).x
	_check("D4 20pt 估宽 ≤406px 格（规划式估宽 + 真字型实测双口径，单行不裁字）",
		est <= NAME_L_WIDTH_PX and measured <= NAME_L_WIDTH_PX,
		"est=%.0f measured=%.0f" % [est, measured])
	_check("D5 name_l.autowrap_mode==AUTOWRAP_WORD_SMART（兜底折行已设）",
		name_l.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART)
	_check("D6 name_l 高度 28 不变（未触发兜底=真单行）",
		name_l.size.y == 28.0, "h=%.1f" % name_l.size.y)
	_check("D7 打开选人面板清除「·新」角标逻辑不变（:572 同区）",
		not _menu._char_new_badge)
	Meta.map_records = bk_maps
	Meta.character_id = bk_char
	await tree.process_frame


# ══ E r195-4：大厅滚动列横向居中锚 ══
func _get_lobby_card_and_scroll() -> Array:
	var card := _menu.get_node("MenuRoot/LobbyPanelRoot/LobbyPanel") as Control
	var scroll := card.get_node("LobbyScroll") as Control
	return [card, scroll]


func _test_e_lobby_scroll_center() -> void:
	print("── E r195-4：LobbyScroll 横向居中锚 ──")
	var pair := _get_lobby_card_and_scroll()
	var card := pair[0] as Control
	var scroll := pair[1] as Control
	_check("E1 LobbyScroll/LobbyPanel 节点定位", card != null and scroll != null)
	if scroll == null or card == null:
		return
	# 静态锚恒等：720 设计域 父卡宽 648 → 锚 0.5=324 → 324±296 = 28..620（逐位恒等）
	_check("E2 居中锚在位：anchor_l==anchor_r==0.5 且 offset ±296",
		scroll.anchor_left == 0.5 and scroll.anchor_right == 0.5
		and scroll.offset_left == -296.0 and scroll.offset_right == 296.0)
	_check("E3 720 域恒等：卡内左缘 28 / 右缘 620 / 宽 592（零变化）",
		absf(scroll.position.x - 28.0) <= 0.5 and absf((scroll.position.x
			+ scroll.size.x) - 620.0) <= 0.5 and absf(scroll.size.x - 592.0) <= 0.5,
		"x=%.1f w=%.1f" % [scroll.position.x, scroll.size.x])
	_check("E4 纵向锚不动：卡内 y=156 / 高 812（下锚随卡底）",
		absf(scroll.position.y - 156.0) <= 0.5 and absf(scroll.size.y - 812.0) <= 0.5,
		"y=%.1f h=%.1f" % [scroll.position.y, scroll.size.y])
	# 宽画布域（win 960×1280 → canvas 960 宽，expand）下滚动列随卡居中
	var win: Window = tree.root
	win.size = Vector2i(960, 1280)
	await tree.process_frame
	await tree.process_frame
	await tree.process_frame
	var card_w := card.size.x
	var center_off := absf((scroll.position.x + scroll.size.x * 0.5) - card_w * 0.5)
	# 居中生效判据 = 精确恒等式（列中点==卡中点）+ 左缘较钉左旧值(28)右移。
	# 注：规划验收行「左缘 > 卡左缘+200」与其 how 自身算式矛盾（960 宽画布卡 888、
	# 列 592 → 居中左缘 = (888-592)/2 = 148 < 200；+200 需画布 ≥1065 宽）——按 how 实装、
	# 以恒等式断言证明居中（更强判定），不凑阈值。
	_check("E5 960 宽画布域：滚动列中点==卡中点（居中恒等式，±0.5px）",
		center_off <= 0.5, "card_w=%.1f off=%.2f" % [card_w, center_off])
	_check("E6 960 宽画布域：列左缘 > 28（钉左旧位，右侧留白消除）",
		scroll.position.x > 28.0, "x=%.1f" % scroll.position.x)
	_check("E7 960 宽画布域：列宽不变 592（±296 偏移恒定）",
		absf(scroll.size.x - 592.0) <= 0.5, "w=%.1f" % scroll.size.x)
	win.size = _win_size0
	await tree.process_frame
	await tree.process_frame


# ══ F R192-low8：图鉴绽放倍率行折行（UI 侧 autowrap） ══
func _test_f_rxn_mult_wrap() -> void:
	print("── F R192-low8：RxnMult autowrap + 高 34 ──")
	_menu._on_lobby_pressed("codex")
	_menu._on_codex_tab("反应")
	var mult_l: Label = null
	var bloom_mult_l: Label = null
	for row_v in _menu._panel_list.get_children():
		var row := row_v as Control
		if row == null or row.is_queued_for_deletion() \
				or not String(row.name).begins_with("RxnRow_"):
			continue
		var ml := row.get_node_or_null("RxnMult") as Label
		if mult_l == null:
			mult_l = ml
		if String(row.name) == "RxnRow_RXN_HYD_DEN":
			bloom_mult_l = ml
	_check("F1 反应页 RxnMult 节点定位", mult_l != null)
	if mult_l == null:
		return
	_check("F2 RxnMult.autowrap_mode==AUTOWRAP_WORD_SMART（折行已设）",
		mult_l.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART)
	_check("F3 RxnMult 高 18→34（宽 148 不变）",
		mult_l.size == Vector2(148.0, 34.0), "size=%s" % str(mult_l.size))
	_check("F4 绽放（RXN_HYD_DEN）倍率行三段串非空（GameConst mult_fmt 真源不动）",
		bloom_mult_l != null and not bloom_mult_l.text.is_empty(),
		"txt=%s" % (bloom_mult_l.text if bloom_mult_l != null else "-"))


# ══ G P2-skillcopy：noah 技能描述补 12% 伴随火力 ══
func _test_g_noah_companion() -> void:
	print("── G P2-skillcopy：诺亚 skill_desc 12% 伴随火力 ──")
	var desc := String(CharacterTable.get_character(&"noah").get("skill_desc", ""))
	_check("G1 noah skill_desc 含「12%」（伴随火力括注）", desc.contains("12%"), "desc=%s" % desc)
	_check("G2 noah skill_desc 含「伴随火力」措辞", desc.contains("伴随火力"))
	# 选人行行为级：技能行渲染同现 + 换行区自检（autowrap + 行底 36 在 140 行高内）
	_menu._on_lobby_pressed("char")
	var noah_skill: Label = null
	for row_v in _menu._panel_list.get_children():
		var row := row_v as Control
		if row == null or row.is_queued_for_deletion():
			continue                              # 页签重建 queue_free 残留行不参与
		for ch_v in row.get_children():
			var l := ch_v as Label
			if l != null and l.text.contains("召唤僚机"):
				noah_skill = l
	_check("G3 选人卡 noah 技能行同现「12%」（menu_screen 渲染链）",
		noah_skill != null and noah_skill.text.contains("12%"),
		"txt=%s" % (noah_skill.text if noah_skill != null else "-"))
	_check("G4 技能行换行区自检：autowrap 已设且高 36（y72..108 ⊂ 行高 140）",
		noah_skill != null and noah_skill.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART
		and noah_skill.size.y == 36.0)

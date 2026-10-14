# tests/runner/r246_ui_cases.gd
# R246「升华卡 UI 呈现」用例体（由 test_r246_ui.gd 入口在 autoload 就绪后运行时加载）。
# 覆盖 G1~G6 六组（分组见套件头注）；文案断言一律对单源真值派生，禁止硬抄波数/名。
# 夹具：MenuScreen / CardSelectUI / HUD 裸实例（r198/r245 同式，零 GameLoop——UI 域
# 自足）。卡面用手工构造卡 dict 直测（kind 6 = CardKind.SUBLIME 对位——cards 泳道
# 枚举合入前先按 int 位锁 UI 侧行为，合入后同位）。
# 纪律：headless 测试档自动隔离（meta_save_test.cfg）；首尾快照/还原 Meta 全量运行态
# 防跨套件污染（r198 F17/r245 同式）；窗口尺寸改后必还原；不 add_child 池化节点。
extends RefCounted

const MANIFEST_PATH := "res://data/manifest.cfg"   # game_loop.MANIFEST_PATH 同值

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _menu: MenuScreen = null
var _registry: DataRegistry = null
var _cards_ui: CardSelectUI = null
var _hud: HUD = null
var _bk: Dictionary = {}
var _win_size0 := Vector2i(540, 960)


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(246)
	_snapshot_meta()
	_boot_all()
	await tree.process_frame
	await tree.process_frame
	_test_g1_palette()
	await _test_g2_sublime_face()
	await _test_g3_highlight_skip()
	_test_g4_icons()
	await _test_g5_hud_ring()
	await _test_g6_menu()
	_restore_meta()
	_teardown_all()
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


# ── 环境（r198_menu_meta / r245_diff_star 同式） ───────────────────
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
	# G6 判定/文案组前提：清零地图域（_locked_hint「当前 %d」两态同值稳定——meta 读口
	# 未合入守卫回 0 / 合入后空表亦 0）；快照在先，末尾整表还原
	Meta.maps_cleared.clear()
	Meta.map_records.clear()


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
	# 同 r194/r195/r196/r197/r198/r245：-s 脚本模式根窗口归一（canvas 域恒等 720×1280）
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


func _boot_all() -> void:
	_normalize_window_for_boot()
	_registry = DataRegistry.new()
	_registry.load_all(MANIFEST_PATH)
	_menu = MenuScreen.new()
	_menu.name = "R246MenuScreenUnderTest"
	_menu.registry = _registry
	tree.get_root().add_child(_menu)               # _ready：建 UI + 挂 Meta 信号（P2 角标链）
	_cards_ui = CardSelectUI.new()
	_cards_ui.name = "R246CardSelectUnderTest"
	tree.get_root().add_child(_cards_ui)          # _ready：建 10 槽贴纸货架
	_hud = HUD.new()
	_hud.name = "R246HudUnderTest"
	tree.get_root().add_child(_hud)               # _ready：建 HUD（含 R246 升华红环覆盖层）
	_check("前置：MenuScreen/CardSelectUI/HUD/registry 就绪",
		_menu != null and _menu.registry != null and _cards_ui != null and _hud != null
		and _registry.enemies.size() > 0
		and _hud._skill_sublime_ring != null)


func _teardown_all() -> void:
	tree.paused = false
	RunSave.clear()
	var win: Window = tree.root
	win.size = _win_size0                          # 窗口尺寸还原
	if _hud != null:
		_hud.free()
		_hud = null
	if _cards_ui != null:
		_cards_ui.free()
		_cards_ui = null
	if _menu != null:
		_menu.free()
		_menu = null


# ── 夹具口 ─────────────────────────────────────────────────────
func _sublime_card() -> Dictionary:
	# R246 升华卡 dict（_card_system.md §2.1 _make_sublime_card 结构对位；kind 6 =
	# CardKind.SUBLIME 追加位——cards 泳道合入前按 int 位直测卡面）
	return {
		"kind": 6, "id": &"SUBLIME_SKILL", "rarity": 4, "value_scale": 1.0,
		"data": null, "display_name": "技能升华",
		"description": "本局技能升级为升华版 · 爆率 0.001%（红色传说）",
		"milestone": false, "overcap": false, "cursed": false,
	}


func _trait_card(p_rarity: int) -> Dictionary:
	return {
		"kind": 1, "id": &"T_R246_TEST", "rarity": p_rarity,
		"value_scale": 1.0 if p_rarity <= 1 else 1.4 + 0.5 * float(p_rarity - 2),
		"data": null, "display_name": "测试词条",
		"description": "测试描述", "milestone": false, "cursed": false,
	}


func _band_color(p_slot: int) -> Color:
	var band: Panel = _cards_ui._card_faces[p_slot]["band"]
	var sb := band.get_theme_stylebox("panel") as StyleBoxFlat
	return sb.bg_color


func _kind_text(p_slot: int) -> String:
	return String((_cards_ui._card_faces[p_slot]["kind"] as Label).text)


func _dots_visible(p_slot: int) -> int:
	var dots: HBoxContainer = _cards_ui._card_faces[p_slot]["dots"]
	var vis := 0
	for c in dots.get_children():
		if (c as TextureRect).visible:
			vis += 1
	return vis


func _dots_built(p_slot: int) -> int:
	return (_cards_ui._card_faces[p_slot]["dots"] as HBoxContainer).get_child_count()


# ══ G1：品质表扩档（palette 单源——D1/D2） ══
func _test_g1_palette() -> void:
	print("── G1：品质表扩档（红档 [4]=传说 / 金档 [3]=辉煌 / clamp 安全） ──")
	_check("G1a RARITY_NAMES 5 档且 [3]=辉煌 [4]=传说",
		PopPalette.RARITY_NAMES.size() == 5 and PopPalette.RARITY_NAMES[3] == "辉煌"
		and PopPalette.RARITY_NAMES[4] == "传说",
		"names=%s" % str(PopPalette.RARITY_NAMES))
	_check("G1b RARITY_COLORS 5 档且 [4]==RARITY_SUBLIME（#ff2e63）",
		PopPalette.RARITY_COLORS.size() == 5
		and PopPalette.RARITY_COLORS[4] == PopPalette.RARITY_SUBLIME
		and PopPalette.RARITY_SUBLIME.to_html(false) == "ff2e63")
	_check("G1c 升华红与既有警示红互异（ENEMY/ENEMY_DEEP 三重避让）",
		PopPalette.RARITY_SUBLIME != PopPalette.ENEMY
		and PopPalette.rarity_color(4) != PopPalette.ENEMY
		and PopPalette.rarity_color(4) != PopPalette.ENEMY_DEEP)
	_check("G1d 取色/取名 clamp 安全（越界钳制不崩）",
		PopPalette.rarity_color(5) == PopPalette.rarity_color(4)
		and PopPalette.rarity_color(-1) == PopPalette.RARITY_NORMAL
		and PopPalette.rarity_name(99) == "传说")
	_check("G1e 金档色值不动（D1 只换字：#ffc93c 保留）",
		PopPalette.RARITY_COLORS[3] == Color("ffc93c"))


# ══ G2：升华卡卡面（KIND_NAMES 第 7 位 / 类别行 / 红顶带 / 5 圆珠 / 无诅咒染名） ══
func _test_g2_sublime_face() -> void:
	print("── G2：升华卡卡面（类别行「升华 · 传说」/ 红顶带 / 5 圆珠） ──")
	_check("G2a KIND_NAMES 第 7 位=升华（kind 6 对位）",
		_cards_ui.KIND_NAMES.size() == 7 and _cards_ui.KIND_NAMES[6] == "升华",
		"names=%s" % str(_cards_ui.KIND_NAMES))
	# 圆珠预建 5（R246：4→5——red 卡 5 珠；0..3 卡显隐口径 rarity+1 不回归）
	var prebuild_ok := true
	for s in range(_cards_ui._card_faces.size()):
		if _dots_built(s) != 5:
			prebuild_ok = false
	_check("G2b 全槽圆珠预建 5 枚（rarity=4 显 5 珠的上限扩一）", prebuild_ok)
	_cards_ui.open([_sublime_card(), _trait_card(2), _trait_card(3)], false)
	await tree.process_frame
	_check("G2c 类别行单源拼接自动出「升华 · 传说」",
		_kind_text(0) == "升华 · 传说", "kind0=%s" % _kind_text(0))
	_check("G2d 金档改名露出（rarity 3 类别行「词条 · 辉煌」）",
		_kind_text(2) == "词条 · 辉煌", "kind2=%s" % _kind_text(2))
	_check("G2e 顶带=升华红（rarity_color(4) 自动放行）",
		_band_color(0) == PopPalette.rarity_color(4),
		"band=%s want=%s" % [_band_color(0).to_html(), PopPalette.rarity_color(4).to_html()])
	_check("G2f 红卡 5 圆珠全显（rarity+1 扩展口径）",
		_dots_visible(0) == 5, "vis=%d" % _dots_visible(0))
	_check("G2g 0..3 卡显隐口径不回归（紫卡 3 珠 / 金卡 4 珠）",
		_dots_visible(1) == 3 and _dots_visible(2) == 4,
		"epic=%d gold=%d" % [_dots_visible(1), _dots_visible(2)])
	_check("G2h 诅咒染名不触发（cursed 恒 false——类别行无「诅咒」段）",
		not _kind_text(0).contains("诅咒"))
	var desc := CardSelectUI.compose_desc_text(
		String(_sublime_card().get("description")), 1.0, false, false)
	_check("G2i 描述单源无品质尾行（value_scale=1.0 守卫）",
		desc == String(_sublime_card().get("description")) and desc.contains("0.001%"))


# ══ G3：挂机描金跳描（D11——红卡自带最高视觉优先级） ══
func _test_g3_highlight_skip() -> void:
	print("── G3：highlight_candidate 对 rarity==4 槽位跳过描金 ──")
	_cards_ui.open([_sublime_card(), _trait_card(2)], false)
	await tree.process_frame
	_cards_ui.highlight_candidate(0)              # 预选红卡槽
	_check("G3a 红卡槽跳过描金（顶带仍升华红）",
		_band_color(0) == PopPalette.rarity_color(4),
		"band0=%s" % _band_color(0).to_html())
	_check("G3b 红卡槽仍记录预选（highlighted_slots 观测口语义保持）",
		_cards_ui.highlighted_slots().size() == 1
		and _cards_ui.highlighted_slots()[0] == 0,
		"slots=%s" % str(_cards_ui.highlighted_slots()))
	_cards_ui.highlight_candidate(1)              # 预选紫卡槽（对照——描金机制不回归）
	_check("G3c 非红槽描金照常（紫槽顶带→GOLD）",
		_band_color(1) == PopPalette.GOLD,
		"band1=%s want=%s" % [_band_color(1).to_html(), PopPalette.GOLD.to_html()])
	_cards_ui.highlight_candidate(0)              # 二次预选红卡（幂等复验）
	_check("G3d 二次预选红卡幂等（_clear_highlight 重上稀有度色无害）",
		_cards_ui.highlighted_slots().size() == 1
		and _cards_ui.highlighted_slots()[0] == 0
		and _band_color(0) == PopPalette.rarity_color(4)
		and _band_color(1) == PopPalette.rarity_color(2))
	_cards_ui.close()
	_check("G3e close 后预选清空", _cards_ui.highlighted_slots().is_empty())


# ══ G4：类型圆章 + 技能图标（texture_factory 程序化图形） ══
func _test_g4_icons() -> void:
	print("── G4：type_icon kind6 红环菱 / skill_icon 三新角色补齐 ──")
	var t6 := TextureFactory.type_icon(6, -1)
	var t6b := TextureFactory.type_icon(6, -1)
	var t_fallback := TextureFactory.type_icon(3, -1)
	var t_relic := TextureFactory.type_icon(2, -1)
	_check("G4a kind6 圆章生成且缓存命中（同键同实例）",
		t6 != null and t6 == t6b)
	_check("G4b kind6 ≠ 灰菱 fallback ≠ RELIC 紫钻（勿重蹈 R185 kind5 前科）",
		t6 != t_fallback and t6 != t_relic)
	var c := t6.get_image().get_pixel(32, 32)     # 画布中心=红菱内填
	_check("G4c kind6 中心像素红系（红环菱形非灰/紫）",
		c.r > c.g and c.r > c.b,
		"px=%s" % c.to_html(true))
	_cards_ui.open([_sublime_card()], false)     # 圆章消费路径自包含复验
	var stamp_tex: TextureRect = _cards_ui._card_faces[0]["stamp"]
	_check("G4d 升华卡槽圆章走 kind6 分支（贴图同缓存实例）",
		stamp_tex.texture == t6)
	var m := TextureFactory.skill_icon(&"medic")
	var v := TextureFactory.skill_icon(&"vortex")
	var r := TextureFactory.skill_icon(&"reaper")
	var fallback_star := TextureFactory.skill_icon(&"r246_no_such_char")
	_check("G4e 三新角色技能图标非空且两两互异（医疗十字/漩涡/镰刃）",
		m != null and v != null and r != null and m != v and m != r and v != r)
	_check("G4f 三图标均脱离 `_:` 通用星默认分支（R198 二aw-5 口径）",
		m != fallback_star and v != fallback_star and r != fallback_star
		and m != TextureFactory.skill_icon(&"sentinel"))


# ══ G5：HUD 升华红环（skill_sublime 态读口——has_method 守卫 R186 同式） ══
func _make_stub_player(p_has_skill: bool, p_sublime_api: bool,
		p_sublime: bool) -> Node2D:
	# 动态脚本桩（不 add_child——refresh_stats 纯属性/方法读，树外即可）
	var src := "extends Node2D\n"
	src += "var hp := 100.0\nvar max_hp := 100.0\nvar xp := 0.0\nvar xp_need := 10.0\n"
	src += "var level := 1\nvar gold := 0\nvar shield_interval := 0.0\n"
	src += "var shield_ready := false\nvar shield_timer := 0.0\n"
	src += "var weapon_slots: Array = []\n"
	src += "var character_id := &\"sentinel\"\n"
	src += "var skill_cd_left := 0.0\nvar revives_left := 0\n"
	src += "func has_skill() -> bool:\n\treturn %s\n" % str(p_has_skill)
	src += "func skill_ready() -> bool:\n\treturn true\n"
	src += "func skill_active_ratio() -> float:\n\treturn 0.0\n"
	if p_sublime_api:
		src += "var skill_sublime := %s\n" % str(p_sublime)
		src += "func enable_sublime() -> void:\n\tpass\n"
	var s := GDScript.new()
	s.source_code = src
	if s.reload() != OK:
		return null
	var p := Node2D.new()
	p.set_script(s)
	return p


func _hud_ring_visible_for(p_stub: Node2D) -> bool:
	_hud.setup(p_stub)
	_hud.refresh_stats()
	var vis: bool = _hud._skill_sublime_ring.visible
	p_stub.free()
	return vis


func _test_g5_hud_ring() -> void:
	print("── G5：HUD 技能键升华红环（守卫生效/置位亮环/无技能不动） ──")
	# ① skills 契约未落地（无 enable_sublime/skill_sublime）→ 维持现状（守卫回退）
	var stub_plain := _make_stub_player(true, false, false)
	_check("G5a 契约未落地桩：红环隐藏（has_method 守卫 R186 同式）",
		stub_plain != null and not _hud_ring_visible_for(stub_plain))
	# ② 契约落地 + 未升华 → 隐藏
	var stub_off := _make_stub_player(true, true, false)
	_check("G5b 有契约未升华（skill_sublime=false）：红环隐藏",
		stub_off != null and not _hud_ring_visible_for(stub_off))
	# ③ 升华置位 → 红环亮（且贴图非空——RARITY_SUBLIME 单源取色 ring_tex）
	var stub_on := _make_stub_player(true, true, true)
	_hud.setup(stub_on)
	_hud.refresh_stats()
	var ring_vis: bool = _hud._skill_sublime_ring.visible
	var ring_tex_ok: bool = _hud._skill_sublime_ring.texture != null
	stub_on.free()
	_check("G5c 升华置位（skill_sublime=true）：红环亮显 + 贴图非空",
		ring_vis and ring_tex_ok)
	# ④ 无技能角色 + 升华置位 → 红环不亮（置灰逻辑不动——深置灰键不叠加红反馈）
	var stub_noskill := _make_stub_player(false, true, true)
	_hud.setup(stub_noskill)
	_hud.refresh_stats()
	var noskill_ring: bool = _hud._skill_sublime_ring.visible
	var noskill_grey: bool = is_equal_approx(float(_hud._skill_btn.modulate.a), 0.3)
	stub_noskill.free()
	_check("G5d 无技能角色：红环不亮且深置灰不动（0.3）",
		not noskill_ring and noskill_grey)


# ══ G6：选人卡（ACH_TYPE_CATEGORY / _locked_hint 新门 + 链序 / P2「·新」角标） ══
func _test_g6_menu() -> void:
	print("── G6：选人卡无尽深度门文案 + 成就归类 + P2 角标 ──")
	# 成就墙归类显式登记（未知 type 兜底本就「进阶」——显式行为可读性）
	_check("G6a ACH_TYPE_CATEGORY 显式 endless_depth=进阶",
		String(MenuScreen.ACH_TYPE_CATEGORY.get("endless_depth", "")) == "进阶")
	# 新门型文案（_channels.md §4 单源句式；map_records 清空态「当前 0」两态稳定——
	# meta 读口未合入守卫回 0 / 合入后空表亦 0）
	var h20 := _menu._locked_hint({"unlock_endless_depth": 20})
	_check("G6b 无尽深度门文案（20 层 + 当前进度括注）",
		h20 == "　任意无尽模式深入 20 层解锁（当前 0）", "h=%s" % h20)
	var h50 := _menu._locked_hint({"unlock_endless_depth": 50})
	_check("G6c 终局档同句式（50 层）",
		h50 == "　任意无尽模式深入 50 层解锁（当前 0）", "h=%s" % h50)
	# 链序与 meta 判定链同位同序（hard 在前 / kills、price 在后）
	_check("G6d 链序：hard_clear 优先于 endless_depth",
		_menu._locked_hint({"unlock_hard_clear": true, "unlock_endless_depth": 50})
		== "　任意地图·困难难度通关解锁")
	_check("G6e 链序：endless_depth 优先于 kills/price",
		_menu._locked_hint({"unlock_endless_depth": 20, "unlock_kills": 500})
		== "　任意无尽模式深入 20 层解锁（当前 0）"
		and _menu._locked_hint({"unlock_endless_depth": 20, "unlock_price": 240})
		== "　任意无尽模式深入 20 层解锁（当前 0）")
	_check("G6f 边缘：unlock_endless_depth=0 视为无门键（落入 price 分支）",
		_menu._locked_hint({"unlock_endless_depth": 0, "unlock_price": 240})
		== "　结晶解锁 240（当前 %d）" % Meta.crystals)
	# 存量六门文案回归（提取 _locked_hint 逐字节等价）
	_check("G6g 存量回归：通关门/购买门句式不变",
		_menu._locked_hint({"unlock_map": &"world_grass"}).begins_with("　通关「")
		and _menu._locked_hint({"unlock_price": 80})
		== "　结晶解锁 80（当前 %d）" % Meta.crystals)
	# P2「·新」角标：订阅 achievements_changed 对 {endless_depth_20, endless_depth_50} 置位
	_menu._char_new_badge = false
	Meta.achievements_changed.emit(&"endless_depth_20")
	_check("G6h endless_depth_20 解锁边沿 →「角色 ·新」角标",
		_menu._char_new_badge
		and (_menu._lobby_btns["char"] as Button).text == "角色 ·新",
		"badge=%s text=%s" % [str(_menu._char_new_badge),
			(_menu._lobby_btns["char"] as Button).text])
	_menu._char_new_badge = false
	Meta.achievements_changed.emit(&"endless_depth_50")
	var badge_50: bool = _menu._char_new_badge
	_menu._char_new_badge = false
	Meta.achievements_changed.emit(&"run_wave_60")
	_check("G6i 终局档同置位 / 无关成就不置位",
		badge_50 and not _menu._char_new_badge)
	_menu._char_new_badge = false                # 还原（打开面板清除口径同效）
	# R245 星标烟测（别回退——选关面板构建不崩 + 难度三键在；星标分档断言归 r245 套件）
	_menu._sel_difficulty = 0
	_menu._open_map_select()
	await tree.process_frame
	_check("G6j R245 选关面板烟测：构建不崩 + 难度三键在",
		_menu._diff_btns.size() == 3)
	# 全路径合验（meta 泳道已落表时执行；未合入则跳过不误报——_locked_hint 直测已覆盖
	# 文案链）：真实锁定角色行经 _rebuild_char_select 渲染出新门文案（判定链 × 文案链
	# 双侧同位同序的端到端证据）
	var depth_char: Dictionary = {}
	for c in CharacterTable.CHARACTERS:
		if int(c.get("unlock_endless_depth", 0)) > 0 and not Meta.is_character_unlocked(c.id):
			depth_char = c
			break
	if not depth_char.is_empty():
		_menu._on_lobby_pressed("char")
		await tree.process_frame
		var want := "　任意无尽模式深入 %d 层解锁（当前 0）" \
			% int(depth_char.get("unlock_endless_depth", 0))
		var found := false
		for row_v in _menu._panel_list.get_children():
			var row := row_v as Panel
			if row == null or row.get_child_count() < 2:
				continue
			var nl := row.get_child(1) as Label   # 角色行子件序：skill_ico(0)/name_l(1)
			if nl != null and String(nl.text).contains(want):
				found = true
		_check("G6k 全路径：真实锁定角色行渲染新门文案（meta 已落表合验）", found,
			"want=%s" % want)
	else:
		_check("G6k（跳过：表无无尽深度门锁定角色——meta 泳道未合入，文案链由 G6b~G6f 覆盖）",
			true)

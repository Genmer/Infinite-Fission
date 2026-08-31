# scripts/ui/menu_screen.gd
# 集成包 A：主菜单屏（MENU 状态宿主）—— 方向 C「晴空糖果」贴纸风重设计。
# 淡云天空底 + 「INFINITE FISSION」双色字母大 logo + 副题「∞ 链式裂变乐园」+ 哨兵-9
# 圆舰吉祥物漂浮 idle + 「出发！」果冻脉动按钮 + lore 引导文案。
# GameLoop 状态机（迁移矩阵冻结）MENU → PLAYING 唯一入口 start_run()——本屏仅申请：
# start_requested 信号 → GameLoop.start_run（仲裁权在 GameLoop，E-16 同源）。
# 可见性绑定 state_changed（仅 MENU 显示）。process_mode = ALWAYS（Q-14 口径）。
# 大厅扩展（META_ROADMAP M4+M6 落地，用户反馈「大厅、图鉴、成就」）：出发按钮下方
# 三入口（图鉴 / 成就 / 记录）→ 全屏详情面板（图鉴 = 怪物/武器/词条三页签，遇解锁口径）。
class_name MenuScreen
extends CanvasLayer

signal start_requested()                      # → GameLoop.start_run()（MENU → PLAYING，兼容口）
signal start_map_requested(map_id: StringName)   # 选图启动（M2 多地图 → GameLoop._on_menu_start）
signal start_daily_requested()                # 每日挑战启动（P2 → GameLoop._on_menu_start_daily）

var registry: DataRegistry = null             # GameLoop Boot 期注入（图鉴全量清单）

var _root: Control = null
var _start_btn: Button = null
var _pulse_tween: Tween = null                # 出发按钮果冻脉动（隐藏时暂停）
var _mascot: TextureRect = null
var _bob_tween: Tween = null                  # 吉祥物漂浮 idle
var _lobby_btns: Dictionary = {}              # 入口按钮（kind → Button，刷新计数角标）
# 详情面板运行期
var _panel_root: Control = null
var _panel_title: Label = null
var _panel_list: Control = null
var _codex_tabs: Dictionary = {}              # 页签按钮（页名 → Button）
var _codex_tab: String = "怪物"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_build_lobby()
	_build_panel()
	_root.visible = false
	EventBus.state_changed.connect(_on_state_changed)
	Meta.codex_changed.connect(_refresh_lobby_counts)


func _on_state_changed(p_state: int) -> void:
	# 仅 MENU 态显示（PLAYING/LEVEL_UP/PAUSED/GAME_OVER 均隐藏）；动效随可见性启停
	var show := p_state == GameConst.GameStatus.MENU
	_root.visible = show
	if _pulse_tween != null:
		if show:
			_pulse_tween.play()
		else:
			_pulse_tween.pause()
	if _bob_tween != null:
		if show:
			_bob_tween.play()
		else:
			_bob_tween.pause()


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "MenuRoot"
	_root.theme = StickerTheme.theme()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# 淡云天空底（不透明 #EEF3FF，盖住战场）+ 漂移云层
	var bg := ColorRect.new()
	bg.name = "MenuBg"
	bg.color = PopPalette.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bg)
	var clouds := CloudBackdrop.new()
	clouds.name = "MenuClouds"
	clouds.base_z = 0                            # 菜单内：云层盖住底色（世界层则沉底）
	_root.add_child(clouds)

	# 大 logo：字母双色交替（天空蓝/珊瑚红）+ 白描边贴纸字
	var logo := HBoxContainer.new()
	logo.name = "Logo"
	logo.add_theme_constant_override("separation", 2)
	logo.position = Vector2(0.0, 258.0)
	logo.size = Vector2(720.0, 64.0)
	logo.alignment = BoxContainer.ALIGNMENT_CENTER
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(logo)
	for i in range(Lore.LOGO.length()):
		var ch := Lore.LOGO[i]
		if ch == " ":
			var gap := Control.new()
			gap.custom_minimum_size = Vector2(14.0, 10.0)
			gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
			logo.add_child(gap)
			continue
		var letter := Label.new()
		var fill := PopPalette.PLAYER if i % 2 == 0 else PopPalette.ENEMY
		StickerTheme.label_sticker(letter, 50, fill, 8, Color.WHITE, true)
		letter.text = ch
		logo.add_child(letter)

	# 副题 + lore 引导文案
	var subtitle := Label.new()
	StickerTheme.label_sticker(subtitle, 24, PopPalette.INK, 0, Color.WHITE, true)
	subtitle.text = Lore.SUBTITLE
	subtitle.position = Vector2(0.0, 342.0)
	subtitle.size = Vector2(720.0, 34.0)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(subtitle)
	for i in range(Lore.MENU_LINES.size()):
		var line := Label.new()
		StickerTheme.label_sticker(line, 16, PopPalette.INK_SOFT)
		line.text = Lore.MENU_LINES[i]
		line.position = Vector2(0.0, 660.0 + 26.0 * float(i))
		line.size = Vector2(720.0, 22.0)
		line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_root.add_child(line)

	# 哨兵-9 圆舰吉祥物（漂浮 idle：上下浮动 + 轻微摇摆）
	_mascot = TextureRect.new()
	_mascot.name = "Sentinel9"
	_mascot.texture = TextureFactory.ship()
	_mascot.position = Vector2(310.0, 452.0)
	_mascot.custom_minimum_size = Vector2(100.0, 100.0)
	_mascot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_mascot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_mascot.pivot_offset = Vector2(50.0, 50.0)
	_mascot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_mascot)
	var name_tag := Label.new()
	StickerTheme.label_sticker(name_tag, 15, PopPalette.PLAYER, 0, Color.WHITE, true)
	name_tag.text = "防御机器人 · 哨兵-9"
	name_tag.position = Vector2(0.0, 566.0)
	name_tag.size = Vector2(720.0, 20.0)
	name_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(name_tag)

	# 出发！按钮（果冻脉动；贴纸四态由 Theme 承担）
	_start_btn = Button.new()
	_start_btn.name = "StartButton"
	_start_btn.text = Lore.START_BUTTON
	_start_btn.add_theme_font_size_override("font_size", 30)
	_start_btn.add_theme_font_override("font", StickerTheme.font_bold())
	_start_btn.position = Vector2(260.0, 790.0)
	_start_btn.size = Vector2(200.0, 84.0)
	_start_btn.pivot_offset = Vector2(100.0, 42.0)
	_start_btn.pressed.connect(_on_start_pressed)
	_start_btn.button_down.connect(func() -> void: StickerTheme.press_punch(_start_btn))
	_root.add_child(_start_btn)
	_pulse_tween = StickerTheme.pulse(_start_btn, 1.15, 0.045)

	# 吉祥物漂浮 idle（正弦 bob + 摇摆）
	_bob_tween = _mascot.create_tween().set_loops()
	_bob_tween.tween_property(_mascot, "position:y", 440.0, 1.4) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_bob_tween.parallel().tween_property(_mascot, "rotation", 0.06, 1.4) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_bob_tween.tween_property(_mascot, "position:y", 464.0, 1.4) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_bob_tween.parallel().tween_property(_mascot, "rotation", -0.06, 1.4) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	# 版本脚注
	var footer := Label.new()
	StickerTheme.label_sticker(footer, 13, PopPalette.INK_SOFT)
	footer.text = "竖屏弹幕防御 · Roguelike"
	footer.position = Vector2(0.0, 1216.0)
	footer.size = Vector2(720.0, 20.0)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(footer)


func _on_start_pressed() -> void:
	_open_map_select()                        # 出发 → 选关面板（M2 多地图，用户反馈）


# ── 选关面板（出发按钮打开；通关链解锁——用户反馈「第一大关通关后打后面的」） ──
func _open_map_select() -> void:
	_panel_root.visible = true
	_panel_title.text = "选择关卡"
	for kind: String in _codex_tabs:
		(_codex_tabs[kind] as Button).visible = false
	for c in _panel_list.get_children():
		(c as Node).queue_free()
	for i in range(MapTable.count()):
		var def := MapTable.MAPS[i]
		var mid: StringName = def.id
		var unlocked := Meta.is_map_unlocked(mid)
		var cleared := Meta.is_map_cleared(mid)
		var status := ("已通关 ★" if cleared else "可挑战") if unlocked else "🔒 通关上一关解锁"
		var row := Panel.new()
		row.add_theme_stylebox_override("panel", StickerTheme.panel_style(14.0, 3, false))
		row.custom_minimum_size = Vector2(576.0, 96.0)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var idx_l := Label.new()
		StickerTheme.label_sticker(idx_l, 24, PopPalette.PLAYER if unlocked else PopPalette.INK_SOFT,
			0, Color.WHITE, true)
		idx_l.text = "%d" % (i + 1)
		idx_l.position = Vector2(18.0, 32.0)
		idx_l.size = Vector2(40.0, 34.0)
		idx_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(idx_l)
		var name_l := Label.new()
		StickerTheme.label_sticker(name_l, 19, PopPalette.INK if unlocked else PopPalette.INK_SOFT,
			0, Color.WHITE, true)
		name_l.text = "%s（%d 波 · %s）" % [String(def.name), int(def.final_wave), status]
		name_l.position = Vector2(64.0, 14.0)
		name_l.size = Vector2(500.0, 26.0)
		name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(name_l)
		var desc_l := Label.new()
		StickerTheme.label_sticker(desc_l, 12, PopPalette.INK_SOFT)
		desc_l.text = String(def.desc)
		desc_l.position = Vector2(64.0, 40.0)
		desc_l.size = Vector2(500.0, 18.0)
		desc_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(desc_l)
		# 词缀二期：双词缀两行小字（祝 = 薄荷绿 / 诅 = 珊瑚红；数值真源 map_table.gd）
		var bless_l := Label.new()
		StickerTheme.label_sticker(bless_l, 12, PopPalette.SUCCESS)
		bless_l.text = "祝　%s" % String(def.get("bless_name", ""))
		bless_l.position = Vector2(64.0, 58.0)
		bless_l.size = Vector2(500.0, 18.0)
		bless_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(bless_l)
		var curse_l := Label.new()
		StickerTheme.label_sticker(curse_l, 12, PopPalette.ENEMY)
		curse_l.text = "诅　%s" % String(def.get("curse_name", ""))
		curse_l.position = Vector2(64.0, 76.0)
		curse_l.size = Vector2(500.0, 18.0)
		curse_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(curse_l)
		if unlocked:
			var play_btn := Button.new()
			play_btn.text = "出发"
			play_btn.add_theme_font_size_override("font_size", 15)
			play_btn.add_theme_font_override("font", StickerTheme.font_bold())
			play_btn.position = Vector2(486.0, 28.0)
			play_btn.size = Vector2(76.0, 40.0)
			play_btn.focus_mode = Control.FOCUS_NONE
			play_btn.pressed.connect(_on_map_pick.bind(mid))
			play_btn.button_down.connect(func() -> void: StickerTheme.press_punch(play_btn))
			row.add_child(play_btn)
		_panel_list.add_child(row)
	StickerTheme.squash_pop(_panel_root.get_node("LobbyPanel") as Control)


func _on_map_pick(p_map_id: StringName) -> void:
	_panel_root.visible = false
	start_map_requested.emit(p_map_id)


func is_menu_visible() -> bool:
	# 测试观测口
	return _root != null and _root.visible


# ── 大厅入口（图鉴 / 成就 / 记录） ────────────────────────────────
func _build_lobby() -> void:
	# 出发按钮下方三入口（按钮文案带完成度角标——图鉴 x/y、成就 x/y）
	var defs := [
		{"kind": "codex", "text": "图鉴", "pos": Vector2(44.0, 900.0)},
		{"kind": "ach", "text": "成就", "pos": Vector2(265.0, 900.0)},
		{"kind": "records", "text": "记录", "pos": Vector2(486.0, 900.0)},
		{"kind": "char", "text": "角色", "pos": Vector2(155.0, 988.0)},
		{"kind": "upgrade", "text": "养成", "pos": Vector2(375.0, 988.0)},
		{"kind": "daily", "text": "每日挑战", "pos": Vector2(265.0, 1076.0)},
	]
	for d in defs:
		var btn := Button.new()
		btn.name = "Lobby_%s" % String(d.kind)
		btn.add_theme_font_size_override("font_size", 22)
		btn.add_theme_font_override("font", StickerTheme.font_bold())
		btn.position = d.pos
		btn.size = Vector2(190.0, 74.0)
		btn.pivot_offset = btn.size * 0.5
		btn.pressed.connect(_on_lobby_pressed.bind(String(d.kind)))
		btn.button_down.connect(func() -> void: StickerTheme.press_punch(btn))
		_root.add_child(btn)
		_lobby_btns[String(d.kind)] = btn
	_refresh_lobby_counts()


func _refresh_lobby_counts() -> void:
	# 入口角标：图鉴解锁数 / 成就完成数（Meta 无档时显示 0）
	if registry == null:
		return
	var codex_total := registry.enemies.size() + registry.weapons.size() + registry.traits.size()
	var codex_got := Meta.codex_kills.size() + Meta.codex_weapons.size() + Meta.codex_traits.size()
	var ach := Meta.achievement_count()
	(_lobby_btns["codex"] as Button).text = "图鉴 %d/%d" % [codex_got, codex_total]
	(_lobby_btns["ach"] as Button).text = "成就 %d/%d" % [ach.x, ach.y]
	(_lobby_btns["records"] as Button).text = "记录"
	(_lobby_btns["char"] as Button).text = "角色"
	(_lobby_btns["upgrade"] as Button).text = "养成 %d💎" % Meta.crystals
	var dbest: Dictionary = Meta.daily_record()
	var dbest_txt := "每日挑战" if dbest.is_empty() \
		else "每日挑战 %d波" % int(dbest.get("best_wave", 0))
	(_lobby_btns["daily"] as Button).text = dbest_txt


func _on_lobby_pressed(p_kind: String) -> void:
	_panel_root.visible = true
	var titles := {"codex": "图鉴", "ach": "成就", "records": "历史记录",
		"char": "选择角色", "upgrade": "局外养成", "daily": "每日挑战"}
	_panel_title.text = String(titles.get(p_kind, ""))
	for kind: String in _codex_tabs:
		(_codex_tabs[kind] as Button).visible = p_kind == "codex"
	match p_kind:
		"codex":
			_rebuild_codex()
		"ach":
			_rebuild_achievements()
		"records":
			_rebuild_records()
		"char":
			_panel_title.text = "选择角色"
			_rebuild_char_select()
		"upgrade":
			_panel_title.text = "局外养成"
			_rebuild_upgrades()
		"daily":
			_panel_title.text = "每日挑战"
			_rebuild_daily()
	StickerTheme.squash_pop(_panel_root.get_node("LobbyPanel") as Control)


# ── 全屏详情面板（三入口共用壳） ──────────────────────────────────
func _build_panel() -> void:
	_panel_root = Control.new()
	_panel_root.name = "LobbyPanelRoot"
	_panel_root.theme = StickerTheme.theme()
	_panel_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel_root.visible = false
	_root.add_child(_panel_root)
	var dim := ColorRect.new()
	dim.color = PopPalette.BG                                  # 大厅内不透明白底（盖住 menu）
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel_root.add_child(dim)
	var card := Panel.new()
	card.name = "LobbyPanel"
	card.add_theme_stylebox_override("panel", StickerTheme.panel_style(24.0, 4, true))
	card.position = Vector2(36.0, 96.0)
	card.size = Vector2(648.0, 1080.0)
	card.pivot_offset = card.size * 0.5
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel_root.add_child(card)
	_panel_title = Label.new()
	StickerTheme.label_sticker(_panel_title, 32, PopPalette.INK, 0, Color.WHITE, true)
	_panel_title.text = "图鉴"
	_panel_title.position = Vector2(0.0, 28.0)
	_panel_title.size = Vector2(648.0, 42.0)
	_panel_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(_panel_title)
	# 图鉴页签（仅图鉴模式可见；行 = [页名, x]）
	var tabs := [["怪物", 36.0], ["武器", 244.0], ["词条", 452.0]]
	for t in tabs:
		var tab := Button.new()
		tab.name = "Tab_%s" % String(t[0])
		tab.text = String(t[0])
		tab.add_theme_font_size_override("font_size", 18)
		tab.add_theme_font_override("font", StickerTheme.font_bold())
		tab.position = Vector2(float(t[1]), 84.0)
		tab.size = Vector2(160.0, 54.0)
		tab.pivot_offset = tab.size * 0.5
		tab.pressed.connect(_on_codex_tab.bind(String(t[0])))
		card.add_child(tab)
		_codex_tabs[String(t[0])] = tab
	var scroll := ScrollContainer.new()
	scroll.name = "LobbyScroll"
	scroll.position = Vector2(28.0, 156.0)
	scroll.size = Vector2(592.0, 812.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	card.add_child(scroll)
	_panel_list = VBoxContainer.new()
	_panel_list.name = "LobbyList"
	_panel_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_panel_list)
	var close_btn := Button.new()
	close_btn.name = "LobbyCloseButton"
	close_btn.text = "返回大厅"
	close_btn.add_theme_font_size_override("font_size", 20)
	close_btn.add_theme_font_override("font", StickerTheme.font_bold())
	close_btn.position = Vector2(211.0, 986.0)
	close_btn.size = Vector2(226.0, 64.0)
	close_btn.pivot_offset = close_btn.size * 0.5
	close_btn.pressed.connect(_on_panel_close)
	close_btn.button_down.connect(func() -> void: StickerTheme.press_punch(close_btn))
	card.add_child(close_btn)


func _on_panel_close() -> void:
	_panel_root.visible = false
	_refresh_lobby_counts()


func _on_codex_tab(p_tab: String) -> void:
	_codex_tab = p_tab
	_rebuild_codex()


# ── 图鉴内容（怪物击杀解锁 / 武器获得解锁 / 词条抽取解锁） ────────
func _rebuild_codex() -> void:
	for c in _panel_list.get_children():
		(c as Node).queue_free()
	if registry == null:
		return
	match _codex_tab:
		"怪物":
			for eid: Variant in registry.enemies:
				var ed: EnemyData = registry.get_enemy(eid)
				if ed == null:
					continue
				var kills := Meta.codex_kill_count(eid)
				_panel_list.add_child(_make_codex_row(
					_enemy_icon_tex(eid), kills > 0,
					ed.display_name if kills > 0 else "？？？",
					"累计击杀 %d · HP %d · 经验 %d" % [kills, int(ed.hp_base), int(ed.exp_base)]
						if kills > 0 else "未解锁：击杀一只后展示详情"))
		"武器":
			for wid: Variant in registry.weapons:
				var wd: WeaponData = registry.get_weapon(wid)
				if wd == null:
					continue
				var got := Meta.is_weapon_unlocked(wid)
				_panel_list.add_child(_make_codex_row(
					TextureFactory.weapon_icon(wid), got,
					wd.display_name if got else "？？？",
					_form_stat_line(wd) if got else "未解锁：抽到「新武器」卡后展示详情"))
		"词条":
			for tid: Variant in registry.traits:
				var td: TraitData = registry.get_trait(tid)
				if td == null:
					continue
				var got := Meta.is_trait_unlocked(tid)
				_panel_list.add_child(_make_codex_row(
					TextureFactory.type_icon(1, int(td.pool)), got,
					td.display_name if got else "？？？",
					td.description if got else "未解锁：抽到该词条卡后展示详情"))
	_sticker_active_tab()


func _form_stat_line(p_wd: WeaponData) -> String:
	# 武器条目副文案：形态 + Lv1 攻击（升级表首档）
	var form_names := ["弹道", "激光", "自导", "近战"]
	var atk := 0.0
	if p_wd.upgrade_table.size() > 0:
		atk = float(p_wd.upgrade_table[0].get("base_atk"))
	return "%s形态 · Lv1 攻击 %.0f" % [form_names[clampi(int(p_wd.form), 0, 3)], atk]


func _enemy_icon_tex(p_eid: Variant) -> ImageTexture:
	# 怪物 id 前缀 → 分型贴图（enemy.gd _visual_kind 同映射的菜单侧轻副本）
	var sid := String(p_eid)
	if sid.begins_with("E17"):
		return TextureFactory.enemy_tex(&"boss4")
	if sid.begins_with("E18"):
		return TextureFactory.enemy_tex(&"boss5")
	if sid.begins_with("E19"):
		return TextureFactory.enemy_tex(&"boss6")
	if sid.begins_with("E20"):
		return TextureFactory.enemy_tex(&"boss7")
	if sid.begins_with("E6_boss2"):
		return TextureFactory.enemy_tex(&"boss2")
	if sid.begins_with("E6_boss3"):
		return TextureFactory.enemy_tex(&"boss3")
	if sid.begins_with("E6"):
		return TextureFactory.enemy_tex(&"boss1")
	if sid.begins_with("E2"):
		return TextureFactory.enemy_tex(&"dart")
	if sid.begins_with("E3"):
		return TextureFactory.enemy_tex(&"bastion_core")
	if sid.begins_with("E4"):
		return TextureFactory.enemy_tex(&"volatile")
	if sid.begins_with("E5"):
		return TextureFactory.enemy_tex(&"elite")
	if sid.begins_with("E7"):
		return TextureFactory.enemy_tex(&"spitter")
	if sid.begins_with("E8"):
		return TextureFactory.enemy_tex(&"imp")
	if sid.begins_with("E9"):
		return TextureFactory.enemy_tex(&"frostling")
	if sid.begins_with("E10"):
		return TextureFactory.enemy_tex(&"woodbird")
	if sid.begins_with("E11"):
		return TextureFactory.enemy_tex(&"aquasquirt")
	if sid.begins_with("E12"):
		return TextureFactory.enemy_tex(&"bogslime")
	if sid.begins_with("E13"):
		return TextureFactory.enemy_tex(&"bogspitter")
	if sid.begins_with("E14"):
		return TextureFactory.enemy_tex(&"boguard")
	if sid.begins_with("E15"):
		return TextureFactory.enemy_tex(&"bogleaper")
	if sid.begins_with("E16"):
		return TextureFactory.enemy_tex(&"marshmaw")
	return TextureFactory.enemy_tex(&"grunt")


func _make_codex_row(p_tex: ImageTexture, p_unlocked: bool, p_name: String,
		p_desc: String) -> Control:
	# 图鉴行：章形图标 + 名称 + 副文案（未解锁 = 剪影灰 + 问号）
	var row := Panel.new()
	row.add_theme_stylebox_override("panel", StickerTheme.panel_style(12.0, 2, false))
	row.custom_minimum_size = Vector2(576.0, 64.0)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon := TextureRect.new()
	icon.texture = p_tex
	icon.position = Vector2(12.0, 12.0)
	icon.custom_minimum_size = Vector2(40.0, 40.0)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.modulate = Color.WHITE if p_unlocked else Color(0.25, 0.27, 0.4, 0.6)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)
	var name_l := Label.new()
	StickerTheme.label_sticker(name_l, 17, PopPalette.INK if p_unlocked else PopPalette.INK_SOFT,
		0, Color.WHITE, true)
	name_l.text = p_name
	name_l.position = Vector2(64.0, 10.0)
	name_l.size = Vector2(490.0, 24.0)
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(name_l)
	var desc_l := Label.new()
	StickerTheme.label_sticker(desc_l, 13, PopPalette.INK_SOFT)
	desc_l.text = p_desc
	desc_l.position = Vector2(64.0, 34.0)
	desc_l.size = Vector2(500.0, 22.0)
	desc_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(desc_l)
	return row


func _sticker_active_tab() -> void:
	# 活动页签高亮（非活动降透明）
	for kind: String in _codex_tabs:
		(_codex_tabs[kind] as Button).modulate = Color.WHITE \
			if kind == _codex_tab else Color(1.0, 1.0, 1.0, 0.55)


# ── 成就内容 ──────────────────────────────────────────────────────
func _rebuild_achievements() -> void:
	for c in _panel_list.get_children():
		(c as Node).queue_free()
	for a in Meta.ACHIEVEMENTS:
		var done := Meta.is_ach_done(a.id)
		var row := Panel.new()
		row.add_theme_stylebox_override("panel", StickerTheme.panel_style(12.0, 2, false))
		row.custom_minimum_size = Vector2(576.0, 60.0)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var mark := Label.new()
		StickerTheme.label_sticker(mark, 24, PopPalette.SUCCESS if done else PopPalette.INK_SOFT,
			0, Color.WHITE, true)
		mark.text = "✓" if done else "·"
		mark.position = Vector2(18.0, 14.0)
		mark.size = Vector2(36.0, 32.0)
		mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(mark)
		var name_l := Label.new()
		StickerTheme.label_sticker(name_l, 17, PopPalette.INK if done else PopPalette.INK_SOFT,
			0, Color.WHITE, true)
		name_l.text = String(a.name)
		name_l.position = Vector2(60.0, 8.0)
		name_l.size = Vector2(480.0, 24.0)
		name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(name_l)
		var desc_l := Label.new()
		StickerTheme.label_sticker(desc_l, 13, PopPalette.INK_SOFT)
		desc_l.text = String(a.desc) + ("　已完成" if done else "")
		desc_l.position = Vector2(60.0, 32.0)
		desc_l.size = Vector2(500.0, 22.0)
		desc_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(desc_l)
		_panel_list.add_child(row)


# ── 角色选择 ──────────────────────────────────────────────────────
func _rebuild_char_select() -> void:
	for c in _panel_list.get_children():
		(c as Node).queue_free()
	for i in range(CharacterTable.count()):
		var def := CharacterTable.CHARACTERS[i]
		var picked: bool = Meta.character_id == def.id
		var unlocked: bool = Meta.is_character_unlocked(def.id)
		var row := Panel.new()
		row.add_theme_stylebox_override("panel", StickerTheme.panel_style(14.0, 3, false))
		row.custom_minimum_size = Vector2(576.0, 118.0)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var name_l := Label.new()
		StickerTheme.label_sticker(name_l, 20, PopPalette.PLAYER if picked else (PopPalette.INK if unlocked else PopPalette.INK_SOFT),
			0, Color.WHITE, true)
		var unlock_hint := ""
		if not unlocked:
			var umap: StringName = def.get("unlock_map", &"")
			if umap != &"":
				unlock_hint = "　🔒 通关「%s」解锁" % String(MapTable.get_map(umap).get("name", "?"))
			elif int(def.get("unlock_kills", 0)) > 0:
				unlock_hint = "　🔒 图鉴累计击杀 %d 解锁" % int(def.get("unlock_kills", 0))
			elif int(def.get("unlock_depth", 0)) > 0:
				unlock_hint = "　🔒 任意图无尽深度 ≥%d 解锁" % int(def.get("unlock_depth", 0))
		name_l.text = String(def.name) + ("　✓ 当前" if picked else "") + unlock_hint
		name_l.position = Vector2(20.0, 12.0)
		name_l.size = Vector2(460.0, 28.0)
		name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(name_l)
		var stat_l := Label.new()
		StickerTheme.label_sticker(stat_l, 14, PopPalette.INK_SOFT)
		stat_l.text = "生命 %d　攻击 %s%.0f%%" % [int(def.hp),
			"+" if float(def.atk_pct) >= 0.0 else "", float(def.atk_pct) * 100.0]
		stat_l.position = Vector2(20.0, 46.0)
		stat_l.size = Vector2(400.0, 20.0)
		stat_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(stat_l)
		var skill_l := Label.new()
		StickerTheme.label_sticker(skill_l, 14, PopPalette.ENEMY)
		skill_l.text = "技能【%s】%s（CD %.0fs）" % [String(def.skill_name),
			String(def.skill_desc), float(def.cd)]
		skill_l.position = Vector2(20.0, 72.0)
		skill_l.size = Vector2(540.0, 20.0)
		skill_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(skill_l)
		if not picked and unlocked:
			var pick_btn := Button.new()
			pick_btn.text = "选用"
			pick_btn.add_theme_font_size_override("font_size", 16)
			pick_btn.add_theme_font_override("font", StickerTheme.font_bold())
			pick_btn.position = Vector2(478.0, 38.0)
			pick_btn.size = Vector2(84.0, 44.0)
			pick_btn.focus_mode = Control.FOCUS_NONE
			pick_btn.pressed.connect(_on_char_pick.bind(def.id))
			pick_btn.button_down.connect(func() -> void: StickerTheme.press_punch(pick_btn))
			row.add_child(pick_btn)
		_panel_list.add_child(row)


func _on_char_pick(p_id: StringName) -> void:
	Meta.set_character_id(p_id)
	_rebuild_char_select()
	_refresh_lobby_counts()


# ── 局外养成（结晶 + 永久升级） ──────────────────────────────────
func _rebuild_upgrades() -> void:
	for c in _panel_list.get_children():
		(c as Node).queue_free()
	var head := Label.new()
	StickerTheme.label_sticker(head, 20, PopPalette.XP, 0, Color.WHITE, true)
	head.text = "裂变结晶：%d（每局结算产出：波次 + 击杀）" % Meta.crystals
	head.custom_minimum_size = Vector2(576.0, 36.0)
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel_list.add_child(head)
	for u in Meta.UPGRADES:
		var lv := Meta.upgrade_level(u.id)
		var maxed := lv >= int(u.max_lv)
		var cost := Meta.upgrade_cost(u.id)
		var row := Panel.new()
		row.add_theme_stylebox_override("panel", StickerTheme.panel_style(12.0, 2, false))
		row.custom_minimum_size = Vector2(576.0, 68.0)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var name_l := Label.new()
		StickerTheme.label_sticker(name_l, 17, PopPalette.INK, 0, Color.WHITE, true)
		name_l.text = "%s  Lv%d/%d" % [String(u.name), lv, int(u.max_lv)]
		name_l.position = Vector2(18.0, 8.0)
		name_l.size = Vector2(320.0, 26.0)
		name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(name_l)
		var desc_l := Label.new()
		StickerTheme.label_sticker(desc_l, 13, PopPalette.INK_SOFT)
		desc_l.text = String(u.desc)
		desc_l.position = Vector2(18.0, 36.0)
		desc_l.size = Vector2(340.0, 20.0)
		desc_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(desc_l)
		var buy := Button.new()
		buy.text = "已满级" if maxed else "升级 (%d💎)" % cost
		buy.add_theme_font_size_override("font_size", 15)
		buy.add_theme_font_override("font", StickerTheme.font_bold())
		buy.position = Vector2(420.0, 14.0)
		buy.size = Vector2(140.0, 42.0)
		buy.focus_mode = Control.FOCUS_NONE
		buy.disabled = maxed or Meta.crystals < cost
		buy.pressed.connect(_on_buy_upgrade.bind(u.id))
		buy.button_down.connect(func() -> void: StickerTheme.press_punch(buy))
		row.add_child(buy)
		_panel_list.add_child(row)
	var note := Label.new()
	StickerTheme.label_sticker(note, 13, PopPalette.INK_SOFT)
	note.text = "养成永久生效：开局自动应用（生命/攻击/磁吸/技能冷却）"
	note.custom_minimum_size = Vector2(576.0, 24.0)
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel_list.add_child(note)


func _on_buy_upgrade(p_id: StringName) -> void:
	if Meta.buy_upgrade(p_id):
		_rebuild_upgrades()
		_refresh_lobby_counts()


# ── 每日挑战（P2：当日固定种子 + 三词缀 + daily_best——全玩家同日同配置口径） ──
func _rebuild_daily() -> void:
	for c in _panel_list.get_children():
		(c as Node).queue_free()
	var key := Meta.daily_date_key()
	var date_disp := "%s-%s-%s" % [key.substr(0, 4), key.substr(4, 2), key.substr(6, 2)]
	var affixes := Meta.daily_affixes(key)
	# 当日词缀行（诅咒 ×2 珊瑚红 / 祝福 ×1 薄荷绿——名称复用 map_table 单源）
	for cid: Variant in affixes.get("curses", []):
		_panel_list.add_child(_make_daily_row("诅",
			Meta.affix_name(StringName(String(cid))), PopPalette.ENEMY))
	var bless: StringName = StringName(String(affixes.get("bless", "")))
	_panel_list.add_child(_make_daily_row("祝", Meta.affix_name(bless), PopPalette.SUCCESS))
	# 当日最佳（daily_best：波次 + 击杀——独立口径不混常规记录）
	var best := Meta.daily_record(key)
	_panel_list.add_child(_make_daily_row("最佳", "波次 %d · 击杀 %d" % [
		int(best.get("best_wave", 0)), int(best.get("best_kills", 0))], PopPalette.PLAYER))
	var note := Label.new()
	StickerTheme.label_sticker(note, 13, PopPalette.INK_SOFT)
	note.text = "%s · 锁定晴空草原 · 全玩家同日同词缀" % date_disp
	note.custom_minimum_size = Vector2(576.0, 24.0)
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel_list.add_child(note)
	var go := Button.new()
	go.name = "DailyStartButton"
	go.text = "出发挑战"
	go.add_theme_font_size_override("font_size", 20)
	go.add_theme_font_override("font", StickerTheme.font_bold())
	go.custom_minimum_size = Vector2(240.0, 64.0)
	go.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	go.focus_mode = Control.FOCUS_NONE
	go.pressed.connect(_on_daily_start)
	go.button_down.connect(func() -> void: StickerTheme.press_punch(go))
	_panel_list.add_child(go)


func _make_daily_row(p_mark: String, p_text: String, p_color: Color) -> Control:
	# 每日挑战信息行：字标（诅/祝/最佳）+ 内容
	var row := Panel.new()
	row.add_theme_stylebox_override("panel", StickerTheme.panel_style(12.0, 2, false))
	row.custom_minimum_size = Vector2(576.0, 60.0)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mark := Label.new()
	StickerTheme.label_sticker(mark, 20, p_color, 0, Color.WHITE, true)
	mark.text = p_mark
	mark.position = Vector2(18.0, 15.0)
	mark.size = Vector2(60.0, 30.0)
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(mark)
	var text_l := Label.new()
	StickerTheme.label_sticker(text_l, 15, PopPalette.INK)
	text_l.text = p_text
	text_l.position = Vector2(86.0, 19.0)
	text_l.size = Vector2(470.0, 24.0)
	text_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(text_l)
	return row


func _on_daily_start() -> void:
	# 出发挑战：关面板 → 申请启动（仲裁权在 GameLoop._on_menu_start_daily，E-16 同源）
	_panel_root.visible = false
	start_daily_requested.emit()


# ── 记录内容 ──────────────────────────────────────────────────────
func _rebuild_records() -> void:
	for c in _panel_list.get_children():
		(c as Node).queue_free()
	var lines := [
		["历史最高波次（全图）", "%d" % int(Meta.records["best_wave"])],
		["单局最高击杀", "%d" % int(Meta.records["best_kills"])],
		["单局最高等级", "%d" % int(Meta.records["best_level"])],
		["累计完成局数", "%d" % int(Meta.records["total_runs"])],
		["累计击杀", "%d" % int(Meta.records["total_kills"])],
		["· 分图最佳 ·", ""],
	]
	for i in range(MapTable.count()):
		var def := MapTable.MAPS[i]
		var mr: Dictionary = Meta.map_records.get(String(def.id), {})
		var depth := int(mr.get("endless_depth", 0))
		lines.append(["%s 最高波次" % String(def.name),
			"%d%s%s" % [int(mr.get("best_wave", 0)), " ★" if Meta.is_map_cleared(def.id) else "",
				" · 无尽 %d" % depth if depth > 0 else ""]])
	lines.append(["通关进度", "%d/%d 图" % [Meta.cleared_count(), MapTable.count()]])
	for l in lines:
		var row := Panel.new()
		row.add_theme_stylebox_override("panel", StickerTheme.panel_style(12.0, 2, false))
		row.custom_minimum_size = Vector2(576.0, 56.0)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var name_l := Label.new()
		StickerTheme.label_sticker(name_l, 18, PopPalette.INK, 0, Color.WHITE, true)
		name_l.text = String(l[0])
		name_l.position = Vector2(24.0, 15.0)
		name_l.size = Vector2(300.0, 26.0)
		name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(name_l)
		var val_l := Label.new()
		StickerTheme.label_sticker(val_l, 22, PopPalette.PLAYER, 0, Color.WHITE, true)
		val_l.text = String(l[1])
		val_l.position = Vector2(400.0, 13.0)
		val_l.size = Vector2(150.0, 30.0)
		val_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		val_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(val_l)
		_panel_list.add_child(row)

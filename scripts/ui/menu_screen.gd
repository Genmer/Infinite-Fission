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
signal start_map_requested(map_id: StringName, difficulty: int)   # 选图启动（M2 多地图 + R72 难度档 → GameLoop._on_menu_start）
signal start_daily_requested()                # 每日挑战启动（P2 → GameLoop._on_menu_start_daily）
signal settings_requested()                   # 设置页打开（P3 → GameLoop 接线 SettingsPanel.open）
signal continue_requested()                   # 继续上次进度（局内存档 → GameLoop.continue_run，2026-08-31）

var registry: DataRegistry = null             # GameLoop Boot 期注入（图鉴全量清单）

var _root: Control = null
var _start_btn: Button = null
var _continue_btn: Button = null              # 继续上次进度（有局内存档时可见，2026-08-31）
var _pulse_tween: Tween = null                # 出发按钮果冻脉动（隐藏时暂停）
var _mascot: TextureRect = null
var name_tag: Label = null                    # 吉祥物名签（R13：随当前角色刷新）
var _bob_tween: Tween = null                  # 吉祥物漂浮 idle
var _lobby_btns: Dictionary = {}              # 入口按钮（kind → Button，刷新计数角标）
# 详情面板运行期
var _sel_difficulty: int = 0                   # R72 难度三档（0 普通/1 困难/2 地狱；选关面板内切换）
var _diff_btns: Array[Button] = []             # 难度三档切换按钮（选中态刷新）
var _panel_root: Control = null
var _panel_title: Label = null
var _panel_list: Control = null
var _codex_tabs: Dictionary = {}              # 页签按钮（页名 → Button）
var _codex_tab: String = "怪物"
# ── R191#6 成就面板类别页签 + 分页（成就扩容配套：页容量 24 控单页行构建成本） ──
var _ach_tabs: Dictionary = {}                # 类别页签（页名 → Button）
var _ach_tab: String = "全部"
var _ach_page: int = 0                        # 当前页（0 基）
var _ach_prev_btn: Button = null
var _ach_next_btn: Button = null
var _ach_page_label: Label = null
const ACH_PAGE_SIZE := 24                     # 成就分页页容量
# 成就类别归类真源（type 字段 → 页签名；未知 type 归「进阶」兜底——三类别页签遍历
# 累加恒等于全量，新族落地漏配也不丢行）
const ACH_TYPE_CATEGORY := {
	"total_kills": "猎杀", "boss_slain": "猎杀", "enemy_kills": "猎杀",
	"run_wave": "进阶", "run_level": "进阶", "total_runs": "进阶",
	"run_reactions": "进阶",                    # R192 反应族（单局触发反应数，run 域同进阶）
	"run_weapons_drawn": "收集", "run_traits_drawn": "收集",
	"codex_weapons": "收集", "codex_traits": "收集", "maps_cleared": "收集",
}
var _char_new_badge: bool = false             # R186：新角色解锁「·新」角标（打开选人面板清除）


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_build_lobby()
	_build_panel()
	_root.visible = false
	# R195 适配：安全区接入（底座组 SafeAreaHelper 单点引用，不复写）。守卫外
	# （桌面窗口化/headless）insets 恒零 → offset 写 0 = 默认窗逐位恒等；真机延迟
	# ≥1 帧重读兜首帧 transform 未定型，size_changed/重获焦点由 helper 重放回调。
	_apply_safe_area()
	if SafeAreaHelper.enabled(get_window()):          # 守卫外恒零→零协程悬挂（headless 全绿面）
		_apply_safe_area_deferred()                # 真值环境延迟重读（SafeAreaHelper 契约）
	SafeAreaHelper.bind_reread(get_window(), _apply_safe_area)
	EventBus.state_changed.connect(_on_state_changed)
	Meta.codex_changed.connect(_refresh_lobby_counts)
	Meta.fissioner_unlocked.connect(_on_fissioner_unlocked)   # R186：普通通关解锁角标
	Meta.echo_unlocked.connect(_on_fissioner_unlocked)        # R198（二aw-6）：困难/地狱通关解锁角标（复用同处理器——两新角色「·新」角标统一）


func _apply_safe_area() -> void:
	# R195 安全区应用（消费式契约=SafeAreaHelper.insets 注释）：根 FULL_RECT
	# offset 左/上取正、右/下取负；底色/云 FULL_RECT 子件随根，面板锚组在让位域内锚定。
	# 仅 realize/size_changed/焦点事件驱动，非每帧路径（R188 纪律）。
	var ins := SafeAreaHelper.insets(get_window())
	_root.offset_left = ins.position.x
	_root.offset_top = ins.position.y
	_root.offset_right = -ins.size.x
	_root.offset_bottom = -ins.size.y


func _apply_safe_area_deferred() -> void:
	# realize 后延迟 ≥1 帧重读（首帧查询为未 realize 真值——SafeAreaHelper 契约）；
	# 协程即发即续，不阻塞 _ready（调用方已守卫 enabled 才进来；二次应用幂等）
	await SafeAreaHelper.read_deferred(get_window())
	_apply_safe_area()


func _on_fissioner_unlocked() -> void:
	# R186：改造者·枢解锁（结算兑现点派发）——「角色」入口加「·新」角标
	# R198（二aw-6）：echo_unlocked 同接本处理器（menu_screen _ready 连接区）——
	# 回响·伊可解锁角标语义统一（信号源 meta_manager 结算兑现点，恰发一次边沿）
	_char_new_badge = true
	_refresh_lobby_counts()


func _on_state_changed(p_state: int) -> void:
	# 仅 MENU 态显示（PLAYING/LEVEL_UP/PAUSED/GAME_OVER 均隐藏）；动效随可见性启停
	var show := p_state == GameConst.GameStatus.MENU
	_root.visible = show
	if show:
		_refresh_continue_btn()
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
	# R195 适配分区：全宽拉伸锚（anchor_l=0/anchor_r=1、y 不变；720×1280 恒等，
	# 宽视口下满宽 + ALIGNMENT_CENTER 随动）
	var logo := HBoxContainer.new()
	logo.name = "Logo"
	logo.add_theme_constant_override("separation", 2)
	logo.anchor_right = 1.0
	logo.offset_left = 0.0
	logo.offset_right = 0.0
	logo.offset_top = 258.0
	logo.offset_bottom = 322.0
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
	# R195 适配分区：全宽拉伸锚（y 不变恒等；宽视口下满宽居中）
	subtitle.anchor_right = 1.0
	subtitle.offset_left = 0.0
	subtitle.offset_right = 0.0
	subtitle.offset_top = 342.0
	subtitle.offset_bottom = 376.0
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(subtitle)
	for i in range(Lore.MENU_LINES.size()):
		var line := Label.new()
		StickerTheme.label_sticker(line, 16, PopPalette.INK_SOFT)
		line.text = Lore.MENU_LINES[i]
		# R10：上移给「继续上次进度」让位（原 660 与按钮重叠）
		# R195 适配分区：全宽拉伸锚（offset=现值−锚点设计位，y 行距恒等）
		line.anchor_right = 1.0
		line.offset_left = 0.0
		line.offset_right = 0.0
		line.offset_top = 636.0 + 26.0 * float(i)
		line.offset_bottom = 658.0 + 26.0 * float(i)
		line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_root.add_child(line)

	# 哨兵-9 圆舰吉祥物（漂浮 idle：上下浮动 + 轻微摇摆）
	_mascot = TextureRect.new()
	_mascot.name = "Sentinel9"
	_mascot.texture = TextureFactory.ship()
	# R195 适配分区：横向居中锚（offset=现值−锚点(360,0)：左 310−360、右沿 410−360
	# 贴中恒 ±50px；bob 补间仍写 position:y，宽视口下与全宽文字栈同随 vis 中心）
	_mascot.anchor_left = 0.5
	_mascot.anchor_right = 0.5
	_mascot.offset_left = -50.0
	_mascot.offset_right = 50.0
	_mascot.offset_top = 452.0
	_mascot.offset_bottom = 552.0
	_mascot.custom_minimum_size = Vector2(100.0, 100.0)
	_mascot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_mascot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_mascot.pivot_offset = Vector2(50.0, 50.0)
	_mascot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_mascot)
	name_tag = Label.new()
	StickerTheme.label_sticker(name_tag, 15, PopPalette.PLAYER, 0, Color.WHITE, true)
	_refresh_mascot()
	# R195 适配分区：全宽拉伸锚（y 不变恒等）
	name_tag.anchor_right = 1.0
	name_tag.offset_left = 0.0
	name_tag.offset_right = 0.0
	name_tag.offset_top = 566.0
	name_tag.offset_bottom = 586.0
	name_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(name_tag)

	# 出发！按钮（果冻脉动；贴纸四态由 Theme 承担）
	_start_btn = Button.new()
	_start_btn.name = "StartButton"
	_start_btn.text = Lore.START_BUTTON
	_start_btn.add_theme_font_size_override("font_size", 30)
	_start_btn.add_theme_font_override("font", StickerTheme.font_bold())
	# R195 适配分区：横向居中锚（offset=现值−锚点(360,0)：左 260−360、右沿 460−360
	# 恒 ±100px；R194 触控 200×84 几何与默认窗落位恒等，宽视口下随 vis 中心）
	_start_btn.anchor_left = 0.5
	_start_btn.anchor_right = 0.5
	_start_btn.offset_left = -100.0
	_start_btn.offset_right = 100.0
	_start_btn.offset_top = 790.0
	_start_btn.offset_bottom = 874.0
	_start_btn.pivot_offset = Vector2(100.0, 42.0)
	_start_btn.pressed.connect(_on_start_pressed)
	_start_btn.button_down.connect(func() -> void: StickerTheme.press_punch(_start_btn))
	_root.add_child(_start_btn)
	_pulse_tween = StickerTheme.pulse(_start_btn, 1.15, 0.045)

	# 继续上次进度（局内存档入口，2026-08-31 用户反馈「回到菜单再进入可选择继续上次进度」）：
	# 出发按钮上方；有档才可见（文案带地图/波次摘要），点击 → GameLoop.continue_run
	_continue_btn = Button.new()
	_continue_btn.name = "ContinueButton"
	_continue_btn.text = "继续上次进度"
	_continue_btn.add_theme_font_size_override("font_size", 17)
	_continue_btn.add_theme_font_override("font", StickerTheme.font_bold())
	# R195 适配分区：横向居中锚（offset=现值−锚点(360,0)：左 190−360、右沿 530−360
	# 恒 ±170px；R10 文案（至 ~712）与出发（790）之间落位恒等，宽视口下随 vis 中心）
	_continue_btn.anchor_left = 0.5
	_continue_btn.anchor_right = 0.5
	_continue_btn.offset_left = -170.0
	_continue_btn.offset_right = 170.0
	_continue_btn.offset_top = 722.0
	_continue_btn.offset_bottom = 770.0
	_continue_btn.pivot_offset = Vector2(170.0, 24.0)
	_continue_btn.pressed.connect(_on_continue_pressed)
	_continue_btn.button_down.connect(func() -> void: StickerTheme.press_punch(_continue_btn))
	_continue_btn.visible = false
	_root.add_child(_continue_btn)

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
	# R195 适配分区：全宽拉伸锚 + 下锚（offset=现值−锚点(0,1280)：上 1216−1280、
	# 底沿 1236−1280 恒 44px；高视口下贴 vis 底）
	var footer := Label.new()
	StickerTheme.label_sticker(footer, 13, PopPalette.INK_SOFT)
	footer.text = "竖屏弹幕防御 · Roguelike"
	footer.anchor_right = 1.0
	footer.anchor_top = 1.0
	footer.anchor_bottom = 1.0
	footer.offset_left = 0.0
	footer.offset_right = 0.0
	footer.offset_top = -64.0
	footer.offset_bottom = -44.0
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(footer)


func _refresh_mascot() -> void:
	# 大厅吉祥物 = 当前选中角色（R13 用户反馈「大厅应显示当前选中的角色」）
	var def := CharacterTable.get_character(Meta.character_id)
	var tints := {
		&"sentinel": Color(1.0, 1.0, 1.0), &"veles": Color(1.0, 0.72, 0.72),
		&"bulwark": Color(0.72, 0.84, 1.0), &"ranger": Color(0.66, 1.0, 0.92),
		&"zero": Color(0.85, 0.72, 1.0), &"mank": Color(0.66, 1.0, 0.55),
		&"vera": Color(0.72, 1.0, 0.72), &"noah": Color(1.0, 0.93, 0.62),
		&"fission": Color(0.62, 0.9, 1.0), &"echo": Color(0.82, 0.66, 1.0),   # R186 新角色
	}
	_mascot.modulate = tints.get(Meta.character_id, Color.WHITE)
	name_tag.text = String(def.get("name", "哨兵-9"))


func _on_start_pressed() -> void:
	_open_map_select()                        # 出发 → 选关面板（M2 多地图，用户反馈）


func _on_continue_pressed() -> void:
	# 继续上次进度（仲裁在 GameLoop.continue_run：无档/坏档 false 兜底）
	continue_requested.emit()


func _refresh_continue_btn() -> void:
	# 有档可见 + 摘要文案（地图 · 第 N 波 · Lv）；无档隐藏
	if _continue_btn == null:
		return
	var data := RunSave.load_run()
	if data.is_empty():
		_continue_btn.visible = false
		return
	var map_name := String(MapTable.get_map(StringName(String(data.get("map_id", "")))).get("name", "?"))
	_continue_btn.text = "继续上次进度：%s · 第%d波 · Lv%d" % [map_name,
		int(data.get("wave", 1)), int(data.get("level", 1))]
	_continue_btn.visible = true


# ── 选关面板（出发按钮打开；通关链解锁——用户反馈「第一大关通关后打后面的」） ──
func _open_map_select() -> void:
	_panel_root.visible = true
	_panel_title.text = "选择关卡"
	for kind: String in _codex_tabs:
		(_codex_tabs[kind] as Button).visible = false
	for kind: String in _ach_tabs:
		(_ach_tabs[kind] as Button).visible = false
	_set_ach_pager_visible(false)
	for c in _panel_list.get_children():
		(c as Node).queue_free()
	_build_difficulty_row()
	for i in range(MapTable.count()):
		var def := MapTable.MAPS[i]
		var mid: StringName = def.id
		var unlocked := Meta.is_map_unlocked(mid)
		var cleared := Meta.is_map_cleared(mid)
		var status := ("已通关 ★" if cleared else "可挑战") if unlocked else "通关上一关解锁"
		var row := Panel.new()
		row.add_theme_stylebox_override("panel", StickerTheme.panel_style(14.0, 3, false))
		row.custom_minimum_size = Vector2(576.0, 118.0)
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
		# 大关新机制行（2026-09-13 解锁节奏表：MechanicGate 真源——选关即见本关主题）
		var note_l := Label.new()
		StickerTheme.label_sticker(note_l, 12, PopPalette.GOLD)
		note_l.text = "✦ %s" % MechanicGate.intro_for_map(i)
		note_l.position = Vector2(64.0, 94.0)
		note_l.size = Vector2(500.0, 18.0)
		note_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(note_l)
		if unlocked:
			var play_btn := Button.new()
			play_btn.text = "出发"
			play_btn.add_theme_font_size_override("font_size", 15)
			play_btn.add_theme_font_override("font", StickerTheme.font_bold())
			play_btn.position = Vector2(486.0, 32.0)   # R194 触控目标放大 76×52（选关行 118 内，32+52=84 留底距）
			play_btn.size = Vector2(76.0, 52.0)
			play_btn.focus_mode = Control.FOCUS_NONE
			play_btn.pressed.connect(_on_map_pick.bind(mid))
			play_btn.button_down.connect(func() -> void: StickerTheme.press_punch(play_btn))
			row.add_child(play_btn)
		_panel_list.add_child(row)
	StickerTheme.squash_pop(_panel_root.get_node("LobbyPanel") as Control)


func selected_difficulty() -> int:
	# 测试观测口（R72）
	return _sel_difficulty


func _build_difficulty_row() -> void:
	# R72 难度选择行（选关面板顶部）：普通 / 困难 / 地狱 三档单选——出发时随图携带
	var row := Panel.new()
	row.name = "DifficultyRow"
	row.add_theme_stylebox_override("panel", StickerTheme.panel_style(14.0, 3, false))
	row.custom_minimum_size = Vector2(576.0, 112.0)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var title := Label.new()
	StickerTheme.label_sticker(title, 15, PopPalette.GOLD, 0, Color.WHITE, true)
	title.text = "◈ 难度"
	title.position = Vector2(16.0, 8.0)
	title.size = Vector2(544.0, 20.0)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(title)
	_diff_btns.clear()
	for d in range(3):
		var btn := Button.new()
		btn.text = GameConst.difficulty_name(d)
		btn.add_theme_font_size_override("font_size", 17)
		btn.add_theme_font_override("font", StickerTheme.font_bold())
		btn.position = Vector2(16.0 + d * 188.0, 34.0)
		btn.size = Vector2(176.0, 50.0)
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(_on_difficulty_pick.bind(d))
		btn.button_down.connect(func() -> void: StickerTheme.press_punch(btn))
		row.add_child(btn)
		_diff_btns.append(btn)
	var desc := Label.new()
	StickerTheme.label_sticker(desc, 12, PopPalette.INK_SOFT)
	desc.text = GameConst.difficulty_desc(_sel_difficulty)
	desc.name = "DiffDesc"
	desc.position = Vector2(16.0, 90.0)
	desc.size = Vector2(544.0, 18.0)
	desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(desc)
	_panel_list.add_child(row)
	_refresh_difficulty_row()


func _on_difficulty_pick(p_d: int) -> void:
	_sel_difficulty = p_d
	_refresh_difficulty_row()


func _refresh_difficulty_row() -> void:
	# 选中态：选中档高亮描边 + 描述行同步（图鉴口径文案）。
	# R88 解锁门：困难/地狱需普通通关（任意图）——未解锁置灰禁用
	var unlocked_hard := Meta.normal_cleared()
	for d in range(_diff_btns.size()):
		var btn := _diff_btns[d]
		var locked := d >= 1 and not unlocked_hard
		btn.disabled = locked
		if locked and _sel_difficulty >= 1:
			_sel_difficulty = 0              # 当前选中档被锁 → 回落普通
		btn.modulate = Color(0.45, 0.45, 0.5) if locked 			else (Color.WHITE if d == _sel_difficulty else Color(0.62, 0.62, 0.66))
	var desc_l := _panel_list.get_node_or_null("DifficultyRow/DiffDesc") as Label
	if desc_l == null and not _diff_btns.is_empty():
		# 行名为默认 Panel（无 name 时按子树找）——直接从按钮父级取
		desc_l = _diff_btns[0].get_parent().get_node_or_null("DiffDesc") as Label
	if desc_l != null:
		desc_l.text = GameConst.difficulty_desc(_sel_difficulty)
		if not unlocked_hard:
			desc_l.text = "普通通关后解锁困难 / 地狱（当前：普通）
" + desc_l.text


func _on_map_pick(p_map_id: StringName) -> void:
	_panel_root.visible = false
	start_map_requested.emit(p_map_id, _sel_difficulty)


func is_menu_visible() -> bool:
	# 测试观测口
	return _root != null and _root.visible


# ── 大厅入口（图鉴 / 成就 / 记录） ────────────────────────────────
func _build_lobby() -> void:
	# 出发按钮下方入口行（按钮文案带完成度角标——图鉴 x/y、成就 x/y）
	var defs := [
		{"kind": "codex", "text": "图鉴", "pos": Vector2(44.0, 900.0)},
		{"kind": "ach", "text": "成就", "pos": Vector2(265.0, 900.0)},
		{"kind": "records", "text": "记录", "pos": Vector2(486.0, 900.0)},
		{"kind": "char", "text": "角色", "pos": Vector2(155.0, 988.0)},
		{"kind": "upgrade", "text": "养成", "pos": Vector2(375.0, 988.0)},
		{"kind": "daily", "text": "每日挑战", "pos": Vector2(265.0, 1076.0)},
		{"kind": "settings", "text": "设置", "pos": Vector2(486.0, 1076.0)},
	]
	for d in defs:
		var btn := Button.new()
		btn.name = "Lobby_%s" % String(d.kind)
		btn.text = String(d.text)                # 基础文案（动态角标由 _refresh_lobby_counts 覆盖）
		btn.add_theme_font_size_override("font_size", 22)
		btn.add_theme_font_override("font", StickerTheme.font_bold())
		if String(d.kind) == "upgrade":
			# R196：结晶 emoji 字面量 → ui_gem 贴纸 icon（Android 系统字体链缺 emoji
			# 字形只出字不出图——apk_menu_no_icons 定案；Button.icon 原生排版，
			# icon_max_width 钳贴纸宽与 22 号字对齐不乱）
			btn.icon = TextureFactory.ui_gem()
			btn.add_theme_constant_override("icon_max_width", 26)
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
	var char_txt := "角色"
	if _char_new_badge:
		char_txt = "角色 ·新"                     # R186：新角色解锁角标（打开选人面板清除）
	(_lobby_btns["char"] as Button).text = char_txt
	(_lobby_btns["upgrade"] as Button).text = "养成 %d" % Meta.crystals   # R196：结晶符号 → ui_gem icon（构建期已挂）
	var dbest: Dictionary = Meta.daily_record()
	var dbest_txt := "每日挑战" if dbest.is_empty() \
		else "每日挑战 %d波" % int(dbest.get("best_wave", 0))
	(_lobby_btns["daily"] as Button).text = dbest_txt


func _on_lobby_pressed(p_kind: String) -> void:
	if p_kind == "settings":
		# 设置页为独立全屏面板（不占大厅详情壳；GameLoop 接线 SettingsPanel.open）
		settings_requested.emit()
		return
	_panel_root.visible = true
	var titles := {"codex": "图鉴", "ach": "成就", "records": "历史记录",
		"char": "选择角色", "upgrade": "局外养成", "daily": "每日挑战"}
	_panel_title.text = String(titles.get(p_kind, ""))
	for kind: String in _codex_tabs:
		(_codex_tabs[kind] as Button).visible = p_kind == "codex"
	for kind: String in _ach_tabs:
		(_ach_tabs[kind] as Button).visible = p_kind == "ach"
	_set_ach_pager_visible(p_kind == "ach")
	match p_kind:
		"codex":
			_rebuild_codex()
		"ach":
			_ach_page = 0                    # 重开成就面板回第一页（防跨类别页码越界残留）
			_rebuild_achievements()
		"records":
			_rebuild_records()
		"char":
			_panel_title.text = "选择角色"
			_char_new_badge = false            # R186：打开选人面板即清除「·新」角标
			_refresh_lobby_counts()
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
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel_root.add_child(card)
	# R195 适配分区：大厅卡左右居中锚（inset 36 恒等）+ 顶部 96 上锚 + 纵向拉伸
	# （offset=现值−锚点设计位：上 96、底沿 1176=1280−104；720×1280 恒等，
	# 宽视口下左右各收 36px、高视口下卡体随高拉伸——滚动区/底行随卡内锚联动）
	card.anchor_left = 0.0
	card.anchor_right = 1.0
	card.anchor_top = 0.0
	card.anchor_bottom = 1.0
	card.offset_left = 36.0
	card.offset_right = -36.0
	card.offset_top = 96.0
	card.offset_bottom = -104.0
	card.pivot_offset = card.size * 0.5
	_panel_title = Label.new()
	StickerTheme.label_sticker(_panel_title, 32, PopPalette.INK, 0, Color.WHITE, true)
	_panel_title.text = "图鉴"
	_panel_title.position = Vector2(0.0, 28.0)
	_panel_title.size = Vector2(648.0, 42.0)
	_panel_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(_panel_title)
	# 图鉴页签（仅图鉴模式可见；行 = [页名, x]。R191#5：+「反应」页共 4 枚，宽 160→126
	# 重排——末沿 486+126=612 与右距 36 均不变）
	var tabs := [["怪物", 36.0], ["武器", 186.0], ["词条", 336.0], ["反应", 486.0]]
	for t in tabs:
		var tab := Button.new()
		tab.name = "Tab_%s" % String(t[0])
		tab.text = String(t[0])
		tab.add_theme_font_size_override("font_size", 18)
		tab.add_theme_font_override("font", StickerTheme.font_bold())
		tab.position = Vector2(float(t[1]), 84.0)
		tab.size = Vector2(126.0, 54.0)
		tab.pivot_offset = tab.size * 0.5
		tab.pressed.connect(_on_codex_tab.bind(String(t[0])))
		card.add_child(tab)
		_codex_tabs[String(t[0])] = tab
	# 成就类别页签（仅成就模式可见；R191#6，复用图鉴页签按钮先例，同行错峰显隐）
	var ach_tabs_def := [["全部", 36.0], ["猎杀", 186.0], ["进阶", 336.0], ["收集", 486.0]]
	for t in ach_tabs_def:
		var atab := Button.new()
		atab.name = "AchTab_%s" % String(t[0])
		atab.text = String(t[0])
		atab.add_theme_font_size_override("font_size", 18)
		atab.add_theme_font_override("font", StickerTheme.font_bold())
		atab.position = Vector2(float(t[1]), 84.0)
		atab.size = Vector2(126.0, 54.0)
		atab.pivot_offset = atab.size * 0.5
		atab.visible = false
		atab.pressed.connect(_on_ach_tab.bind(String(t[0])))
		atab.button_down.connect(func() -> void: StickerTheme.press_punch(atab))
		card.add_child(atab)
		_ach_tabs[String(t[0])] = atab
	# 成就分页（上一页/下一页 + 页码读数；返回大厅按钮两侧让位——页容量 24）
	_ach_prev_btn = Button.new()
	_ach_prev_btn.name = "AchPrevButton"
	_ach_prev_btn.text = "◀ 上一页"
	_ach_prev_btn.add_theme_font_size_override("font_size", 15)
	_ach_prev_btn.add_theme_font_override("font", StickerTheme.font_bold())
	_ach_prev_btn.position = Vector2(36.0, 986.0)
	_ach_prev_btn.size = Vector2(132.0, 64.0)
	# R195 适配分区：底行下锚（offset=现值−锚点(0,1080)：上 986−1080、底沿 1050−1080
	# 随卡底恒 30px；横向保持左 inset 36）
	_ach_prev_btn.anchor_top = 1.0
	_ach_prev_btn.anchor_bottom = 1.0
	_ach_prev_btn.offset_top = -94.0
	_ach_prev_btn.offset_bottom = -30.0
	_ach_prev_btn.pivot_offset = _ach_prev_btn.size * 0.5
	_ach_prev_btn.visible = false
	_ach_prev_btn.pressed.connect(_on_ach_page_prev)
	_ach_prev_btn.button_down.connect(func() -> void: StickerTheme.press_punch(_ach_prev_btn))
	card.add_child(_ach_prev_btn)
	_ach_next_btn = Button.new()
	_ach_next_btn.name = "AchNextButton"
	_ach_next_btn.text = "下一页 ▶"
	_ach_next_btn.add_theme_font_size_override("font_size", 15)
	_ach_next_btn.add_theme_font_override("font", StickerTheme.font_bold())
	_ach_next_btn.position = Vector2(480.0, 986.0)
	_ach_next_btn.size = Vector2(132.0, 64.0)
	# R195 适配分区：底行下锚 + 右锚（offset=现值−锚点(648,1080)：左 480−648、右沿
	# 612−648 随卡宽恒 inset 36——与左页签对称；默认窗 (480,986) 恒等）
	_ach_next_btn.anchor_left = 1.0
	_ach_next_btn.anchor_right = 1.0
	_ach_next_btn.anchor_top = 1.0
	_ach_next_btn.anchor_bottom = 1.0
	_ach_next_btn.offset_left = -168.0
	_ach_next_btn.offset_right = -36.0
	_ach_next_btn.offset_top = -94.0
	_ach_next_btn.offset_bottom = -30.0
	_ach_next_btn.pivot_offset = _ach_next_btn.size * 0.5
	_ach_next_btn.visible = false
	_ach_next_btn.pressed.connect(_on_ach_page_next)
	_ach_next_btn.button_down.connect(func() -> void: StickerTheme.press_punch(_ach_next_btn))
	card.add_child(_ach_next_btn)
	_ach_page_label = Label.new()
	_ach_page_label.name = "AchPageLabel"
	StickerTheme.label_sticker(_ach_page_label, 13, PopPalette.INK_SOFT)
	# 坐标落在 ◀上一页(36~168) 与 返回大厅(211~) 之间 43px 空当内——旧位 136 压进按钮描边 30px
	_ach_page_label.position = Vector2(170.0, 1004.0)
	_ach_page_label.size = Vector2(39.0, 28.0)
	# R195 适配分区：底行下锚（offset=现值−锚点(0,1080)：上 1004−1080、底沿 1032−1080；
	# 横向固定随左页签——页码读数属翻页器）
	_ach_page_label.anchor_top = 1.0
	_ach_page_label.anchor_bottom = 1.0
	_ach_page_label.offset_top = -76.0
	_ach_page_label.offset_bottom = -48.0
	_ach_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ach_page_label.visible = false
	card.add_child(_ach_page_label)
	var scroll := ScrollContainer.new()
	scroll.name = "LobbyScroll"
	scroll.position = Vector2(28.0, 156.0)
	scroll.size = Vector2(592.0, 812.0)
	# R195 适配分区：滚动列表区纵向拉伸（上锚 156 固定/下锚随卡底：底沿 968=1080−112；
	# 720×1280 恒等，高视口下随卡体拉伸多显行）
	# R198（r195-4）：横向改居中锚——父卡 720 设计域宽 648、锚 0.5=324 → 324±296=28..620
	# 逐位恒等（720 域零变化）；宽画布域下滚动列随卡居中，消除右侧 ~268px 留白（960 宽
	# 画布域卡宽 888 → 列左缘 28→148 卡内居中）。图鉴 4 页签/选关/记录三屏共用本列自动受益。
	scroll.anchor_left = 0.5
	scroll.anchor_right = 0.5
	scroll.offset_left = -296.0
	scroll.offset_right = 296.0
	scroll.anchor_top = 0.0
	scroll.anchor_bottom = 1.0
	scroll.offset_top = 156.0
	scroll.offset_bottom = -112.0
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
	# R195 适配分区：底行下锚 + 横向居中锚（offset=现值−锚点(324,1080)：左 211−324、
	# 右 437−324——卡宽变化下保持行内居中；默认窗恒等）
	close_btn.anchor_left = 0.5
	close_btn.anchor_right = 0.5
	close_btn.anchor_top = 1.0
	close_btn.anchor_bottom = 1.0
	close_btn.offset_left = -113.0
	close_btn.offset_right = 113.0
	close_btn.offset_top = -94.0
	close_btn.offset_bottom = -30.0
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
				var atk_note := GameConst.enemy_attack_note(String(eid))
				_panel_list.add_child(_make_codex_row(
					_enemy_icon_tex(eid), kills > 0,
					ed.display_name if kills > 0 else "？？？",
					"累计击杀 %d · HP %d · 经验 %d%s" % [kills, int(ed.hp_base),
						int(ed.exp_base), atk_note]
						if kills > 0 else "未解锁：击杀一只后展示详情"))
		"武器":
			# R196 三态（定案 wunlock）：①已获得 = got 现状（机制一句话 + 形态数值）；
			# ②可获取 = 门开未获得（显示名 + 局内抽卡提示）；③未解锁 = 门未开（隐名 +
			# 「通关『X』后开放」——句式单源 MechanicGate.weapon_locked_line，UI 禁手抄；
			# 锁徽记走 ui_lock 贴纸，行压暗读感同 RxnRow 锁定态手法）。
			# 「图鉴 %d/%d」计数保持获得口径不动（_refresh_lobby_counts）。
			for wid: Variant in registry.weapons:
				var wd: WeaponData = registry.get_weapon(wid)
				if wd == null:
					continue
				var got := Meta.is_weapon_unlocked(wid)
				# R196 评审修复：三态门态改进度派生（weapon_allowed_progress）——
				# weapon_allowed 读 run_map（上一局地图残留），大厅冷启动全亮「可获取」
				# 假话、局后按末局地图漂移；进度门 = 已通关大关数派生，与选关页一致
				var allowed := MechanicGate.weapon_allowed_progress(wid)
				# R190：解锁行副文案加机制一句话（图鉴直接可见，不靠 hover）——
				# 万镜回廊/蓄能轨道等 R187 特殊机制读图标猜不出
				var w_desc := ""
				var w_name := wd.display_name
				if got:
					var w_note := GameConst.weapon_note(String(wid))
					w_desc = ("%s\n%s" % [w_note, _form_stat_line(wd)]) if w_note != "" \
						else _form_stat_line(wd)
				elif allowed:
					w_desc = "可获取：局内抽到「新武器」卡解锁"
				else:
					w_name = "？？？"
					w_desc = MechanicGate.weapon_locked_line(wid)
				var w_row := _make_codex_row(
					TextureFactory.weapon_icon(wid), got or allowed,
					w_name, w_desc)
				if not allowed and not got:
					# 未解锁三态：压暗 + 右上角锁徽贴纸（观察名 WeaponLockBadge）。
					# R196 wunlock 定案 P6「获得优先于门」：门外已获得的武器按已获得态
					# 展示（显示名 + 无锁徽 + 不压暗）——只拦「未获得 ∧ 门外」，老档无损
					w_row.modulate.a = 0.55
					var w_lock := TextureRect.new()
					w_lock.name = "WeaponLockBadge"
					w_lock.texture = TextureFactory.ui_lock()
					w_lock.position = Vector2(536.0, 8.0)
					w_lock.size = Vector2(26.0, 24.0)
					w_lock.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
					w_lock.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
					w_lock.mouse_filter = Control.MOUSE_FILTER_IGNORE
					w_row.add_child(w_lock)
				_panel_list.add_child(w_row)
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
		"反应":
			# R191#5 图鉴「反应」页：枚举全键全量可见（无解锁过滤——不设 codex 门、零新增
			# 存档键；页面不出现难度门文案，条件句写代码真条件）。倍率运行时读
			# GameConfig.balance.reaction_table 格式化（禁止硬编码数值）。
			# R192 wire T2 rid 无关化：行建遍历 ReactionType 枚举声明序（keys() 即序——
			# 枚举字典 = 名→int，keys() 给名字串，int 值经 ReactionType[名] 反查），逐键查
			# reaction_table 成员过滤——缺键 push_error+跳过（半接线启动期报红，禁静默落行）；
			# 行序 = 枚举声明序（构建序定位保留）。冰+草留白标注行（21 配对唯一空格）在循环
			# 后单独追加——不计入枚举行数。
			for rid_key: String in GameConst.ReactionType.keys():
				if GameConfig.balance == null \
						or not GameConfig.balance.reaction_table.has(rid_key):
					push_error("[MenuScreen] reaction_table 缺键（半接线）：%s——行跳过" % rid_key)
					continue
				_panel_list.add_child(
					_make_codex_reaction_row(int(GameConst.ReactionType[rid_key])))
			_panel_list.add_child(_make_codex_blank_row())
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
	# R72 新形态（E25~E30 先于 E2/E3 短前缀——begins_with 撞前缀）
	if sid.begins_with("E25"):
		return TextureFactory.enemy_tex(&"phase")
	if sid.begins_with("E26"):
		return TextureFactory.enemy_tex(&"shieldlancer")
	if sid.begins_with("E27"):
		return TextureFactory.enemy_tex(&"warden")
	if sid.begins_with("E28"):
		return TextureFactory.enemy_tex(&"hexcaster")
	if sid.begins_with("E29"):
		return TextureFactory.enemy_tex(&"longbow")
	if sid.begins_with("E30"):
		return TextureFactory.enemy_tex(&"revenant")
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
	# P07(R199)：图鉴描述 autowrap + 按实测需求扩高——单行 500×22 定格把最长描述
	#（风域 1263px）拦屏截断，被裁的恰是图鉴要解释的元素反应族。行高用 StickerTheme
	# 字型排版实测（同 card_select_ui._measured_desc_h 口径：wrap 高 + 行距，禁拍值），
	# 行体随描述扩高
	desc_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var _raw_need: float = StickerTheme.font().get_multiline_string_size(p_desc,
		HORIZONTAL_ALIGNMENT_LEFT, 500.0, 13, -1, 7).y
	var _lines := maxi(1, roundi(_raw_need / maxf(StickerTheme.font().get_height(13), 1.0)))
	var desc_need: float = _raw_need + float(_lines - 1) \
		* float(desc_l.get_theme_constant("line_spacing"))
	desc_l.position = Vector2(64.0, 34.0)
	desc_l.size = Vector2(500.0, maxf(22.0, desc_need))
	desc_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(desc_l)
	row.custom_minimum_size = Vector2(576.0, maxf(64.0, 34.0 + desc_need + 10.0))
	return row


func _make_codex_reaction_row(p_rxn: int) -> Control:
	# R191#5 反应行（576×150 高行——既有 64 行装不下 54px+12px 描边的预览大字）：
	# 左配方双色环 +「+」/ 名称 / 效果与条件 / 解锁 / 倍率（运行时读表）/ 右 54px 预览。
	# 预览复刻 DamagePopup._apply_reaction_look 五项 override（不走 label_sticker——
	# 会覆写 font 破坏反应专属字型）；文案单源 GameConst.reaction_note。
	var rid := String(GameConst.ReactionType.find_key(p_rxn))
	var note: Dictionary = GameConst.reaction_note(rid)
	var row := Panel.new()
	row.name = "RxnRow_%s" % rid
	row.add_theme_stylebox_override("panel", StickerTheme.panel_style(12.0, 2, false))
	row.custom_minimum_size = Vector2(576.0, 150.0)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 配方双色环（元素色单源 PopPalette.ELEMENT_COLORS——R192 M2 改引：与跳字同表同源，
	# 改表即跳字+图鉴环自动跟随；36px 环）
	var elems: Array = note.get("elements", [])
	var ring_xs := [14.0, 78.0]
	for e_i in range(mini(elems.size(), 2)):
		var ring := TextureRect.new()
		ring.texture = TextureFactory.ring_tex(
			PopPalette.ELEMENT_COLORS.get(int(elems[e_i]), Color.WHITE), 36, 5.0)
		ring.position = Vector2(float(ring_xs[e_i]), 18.0)
		ring.custom_minimum_size = Vector2(36.0, 36.0)
		ring.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ring.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(ring)
	var plus_l := Label.new()
	StickerTheme.label_sticker(plus_l, 17, PopPalette.INK_SOFT)
	plus_l.text = "+"
	plus_l.position = Vector2(50.0, 24.0)
	plus_l.size = Vector2(28.0, 24.0)
	plus_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(plus_l)
	var name_l := Label.new()
	StickerTheme.label_sticker(name_l, 17, PopPalette.INK, 0, Color.WHITE, true)
	name_l.name = "RxnName"
	name_l.text = String(note.get("name", rid))
	name_l.position = Vector2(128.0, 16.0)
	name_l.size = Vector2(280.0, 28.0)
	row.add_child(name_l)
	var desc_l := Label.new()
	StickerTheme.label_sticker(desc_l, 13, PopPalette.INK_SOFT)
	desc_l.name = "RxnDesc"
	desc_l.text = String(note.get("effect", ""))
	desc_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART   # 条件句估宽 417~441px 超 400px 格——超宽折行（3 行 57px ≤ 60px 格）
	desc_l.position = Vector2(14.0, 62.0)
	desc_l.size = Vector2(400.0, 60.0)
	row.add_child(desc_l)
	var unlock_l := Label.new()
	StickerTheme.label_sticker(unlock_l, 12, PopPalette.GOLD)
	unlock_l.name = "RxnUnlock"
	unlock_l.text = String(note.get("unlock", ""))
	unlock_l.position = Vector2(14.0, 124.0)
	unlock_l.size = Vector2(396.0, 18.0)
	row.add_child(unlock_l)
	var mult_l := Label.new()
	StickerTheme.label_sticker(mult_l, 12, PopPalette.PLAYER)
	mult_l.name = "RxnMult"
	mult_l.text = _rxn_multiplier_text(rid)
	mult_l.position = Vector2(414.0, 124.0)
	# R198（R192-low8）：绽放（RXN_HYD_DEN）mult_fmt 三段串估宽超 148px 格——autowrap
	# 折两行 + 高 18→34（宽 148/右对齐保持；其余反应单段串单行不受影响。文案真源
	# GameConst mult_fmt 不动——口径 4，UI 侧承宽；R191 收口2 desc_l autowrap 同族）
	mult_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	mult_l.size = Vector2(148.0, 34.0)
	mult_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(mult_l)
	# 坏 ID 兜底改报红（R192 wire T2：禁静默——LOOKS 缺键 = 表现半接线，落首键观感防崩）
	var look: Dictionary = DamagePopup.REACTION_LOOKS.get(p_rxn, {})
	if look.is_empty():
		push_error("[MenuScreen] REACTION_LOOKS 缺键（半接线）：rxn=%d——落首键观感" % p_rxn)
		look = DamagePopup.REACTION_LOOKS.values()[0]
	var prev := Label.new()
	prev.name = "RxnPreview"
	# R192 收口2：样张与实机跳字同源组合（用户口径「反应名+数字（包括图鉴）」）——
	# dmg 型 = 反应名+样张数值段（note.sample 仅此型渲染）；pct/stat 型 = 反应名+
	# DamagePopup.reaction_stat_text 读表统计段（与跳字同一函数，超导-30%/激化+25%…）；
	# 无统计段反应（感电/扩散族）只显名（链伤/扩散一击走自身伤害通道另跳数字）。
	prev.text = String(look["name"]) + (String(note.get("sample", "")) if String(look["fmt"]) == "dmg" \
		else DamagePopup.reaction_stat_text(p_rxn))
	prev.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prev.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# 五项 override 逐项对齐 DamagePopup._apply_reaction_look（damage_popup.gd 五连装）
	prev.add_theme_color_override("font_color", look["fill"])
	prev.add_theme_color_override("font_outline_color", look["outline"])
	prev.add_theme_constant_override("outline_size", DamagePopup.OUTLINE_PX_REACTION)
	prev.add_theme_font_override("font", StickerTheme.font_reaction(int(look["variant"])))
	prev.add_theme_font_size_override("font_size", DamagePopup.FONT_SIZE_REACTION)
	prev.position = Vector2(420.0, 18.0)
	prev.size = Vector2(140.0, 78.0)
	row.add_child(prev)
	# R192 visual 批1：预览缩放 CODEX_PREVIEW_SCALE 单源 + pivot 居中（54px 样张缩半适配
	# 140×78 格——不改字号不加宽格，五项对位断言契约不变）。54px 反应字型的最小行高把
	# size.y 顶过 78 设定值（实测 →108）且钳制时机延迟不定——挂 resized 单发跟随：任何
	# 一次尺寸变化（含延迟钳制）都即刻重算 pivot，恒等式 pivot_offset == size×0.5 在任意
	# 时点成立（fx_quality 预览缩放断言口径）。行随页签重建 queue_free，连接随节点销毁。
	prev.resized.connect(func() -> void:
		prev.pivot_offset = prev.size * DamagePopup.CODEX_PREVIEW_SCALE)
	prev.pivot_offset = prev.size * DamagePopup.CODEX_PREVIEW_SCALE
	prev.scale = Vector2.ONE * DamagePopup.CODEX_PREVIEW_SCALE
	prev.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# R196 图鉴锁：未触发反应行锁定态（只读 Meta.is_reaction_seen——标记接线在 Meta 侧
	# _on_reaction_triggered，本文件零写入口）。锁定只改样式不改行集合：全枚举行仍全量
	# 可见（A5/D0 行数断言口径不动），解锁关提示单源复用上方 RxnUnlock 行（note.unlock
	# 已含「第 N 关起」，零新文案、零 GameConst 改动）；行随页签 queue_free 重建 → 战斗内
	# 首次触发后下次进图鉴自然解锁（持久化在 Meta codex/reaction_seen，旧档缺键 → 空表
	# 全锁定，降级不崩）。
	if not Meta.is_reaction_seen(StringName(rid)):
		row.modulate.a = 0.55                    # 降透明读感（_make_codex_blank_row 同族手法）
		# R196：锁徽记 emoji 字面量 → ui_lock 程序贴纸（Android 系统字体链缺 emoji 字形——
		# apk_menu_no_icons 定案；观察名 RxnLockBadge 保留，图鉴武器行锁徽同款贴纸）
		var lock_l := TextureRect.new()
		lock_l.name = "RxnLockBadge"
		lock_l.texture = TextureFactory.ui_lock()
		lock_l.position = Vector2(536.0, 6.0)    # 预览格右上角（格 420..560×18..96）
		lock_l.size = Vector2(26.0, 24.0)
		lock_l.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		lock_l.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		lock_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var seen_l := Label.new()
		StickerTheme.label_sticker(seen_l, 12, PopPalette.INK_SOFT)
		seen_l.name = "RxnLockNote"
		seen_l.text = "未触发"
		seen_l.position = Vector2(520.0, 104.0)  # 预览格下方（y96）与 RxnMult（y124）之间——不压倍率
		seen_l.size = Vector2(56.0, 18.0)
		seen_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		row.add_child(lock_l)
		row.add_child(seen_l)
	return row


func _rxn_multiplier_text(p_rid: String) -> String:
	# R192 wire T2：倍率行 token 格式化器（rid 无关——零 per-rid 分支，新反应零新代码）。
	# 模板单源 GameConst.reaction_note[p_rid].mult_fmt（数值一律不进文案）；数值运行时读
	# GameConfig.balance.reaction_table（禁硬编码数值，禁 rule.get 硬兜底默认——半接线
	# 必须报红不可静默出数）。
	# token 语法（reaction_note.mult_fmt 契约，validator 锁 mult_fmt token 键 ⊆ rule 键）：
	# · {key:spec}     → rule[key] 按 spec printf（spec 如 .1f / .0f）
	# · {key_pc:spec}  → rule[key 剥 _pc 后缀] × 100 后按 spec（resist_delta 等百分比口径）
	# 不可解析 token（键不在表 / 语法残缺）→ push_error + 返空串（D 组行级断言 mult 非空
	# 同红——缺件在页面读得见，不可静默空行）。
	var rule: Dictionary = {}
	if GameConfig.balance != null:
		rule = GameConfig.balance.reaction_table.get(p_rid, {})
	var note: Dictionary = GameConst.reaction_note(p_rid)
	if note.is_empty() or not note.has("mult_fmt"):
		return ""                                 # 坏 id / 模板缺键（validator 闸上游报红）
	var out := ""
	var rest: String = String(note["mult_fmt"])
	while true:
		var open := rest.find("{")
		if open < 0:
			out += rest
			break
		var close := rest.find("}", open)
		if close < 0:                             # 模板残缺（无闭括号）——余段原样落行
			out += rest
			break
		out += rest.substr(0, open)
		var token := rest.substr(open + 1, close - open - 1)
		var sep := token.find(":")
		var key := token.substr(0, sep) if sep >= 0 else ""
		var spec := token.substr(sep + 1) if sep >= 0 else ""
		var rule_key := key.trim_suffix("_pc")
		if key.is_empty() or spec.is_empty() or not rule.has(rule_key):
			push_error("[MenuScreen] mult_fmt token 不可解析：rid=%s token={%s}" % [p_rid, token])
			return ""
		var value := float(rule[rule_key])
		if key.ends_with("_pc"):
			value *= 100.0                        # 百分比口径（×100 后按 spec）
		out += ("%" + spec) % value
		rest = rest.substr(close + 1)
	return out


func _make_codex_blank_row() -> Control:
	# R192 M3 冰+草留白标注行（21 配对唯一空格；R191#4『选了没反应』误报教训——把空白变
	# 规则）。循环后单独追加、不计入枚举行数（A5/D0/X3 行数口径 = 全枚举 或 全枚举+1）；
	# 文案单源 GameConst.REACTION_BLANK_NOTE（数值不进文案，本行不承载任何表值）；
	# 降透明样式 = 全行 modulate 半透（非活动页签同族读感——如实标注非图鉴遗漏）。
	var row := Panel.new()
	row.name = "RxnRow_BLANK"
	row.add_theme_stylebox_override("panel", StickerTheme.panel_style(12.0, 2, false))
	row.custom_minimum_size = Vector2(576.0, 56.0)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.modulate = Color(1.0, 1.0, 1.0, 0.5)
	var note_l := Label.new()
	StickerTheme.label_sticker(note_l, 13, PopPalette.INK_SOFT)
	note_l.name = "RxnBlankNote"
	note_l.text = GameConst.REACTION_BLANK_NOTE
	note_l.position = Vector2(18.0, 18.0)
	note_l.size = Vector2(540.0, 22.0)
	note_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(note_l)
	return row


func _sticker_active_tab() -> void:
	# 活动页签高亮（非活动降透明）
	for kind: String in _codex_tabs:
		(_codex_tabs[kind] as Button).modulate = Color.WHITE \
			if kind == _codex_tab else Color(1.0, 1.0, 1.0, 0.55)


# ── 成就内容（R191#6：类别页签 + 分页——全量行数上百，页容量 24 控单次行构建成本；
#    行构建逻辑复用原 :732-759 不动） ─────────────────────────────────
func _ach_filtered() -> Array:
	# 类别过滤（type 字段单源归类 ACH_TYPE_CATEGORY；未知 type 归「进阶」兜底——
	# 三类别页签遍历累加恒等于全量）
	var out: Array = []
	for a in Meta.ACHIEVEMENTS:
		if _ach_tab == "全部" or String(ACH_TYPE_CATEGORY.get(String(a.type), "进阶")) == _ach_tab:
			out.append(a)
	return out


func _ach_page_count() -> int:
	# 当前页签总页数（≥1——空类别也保持「1/1」读数与翻页按钮可用语义）
	return maxi(1, ceili(float(_ach_filtered().size()) / float(ACH_PAGE_SIZE)))


func _on_ach_tab(p_tab: String) -> void:
	_ach_tab = p_tab
	_ach_page = 0                              # 切类别回第一页
	_rebuild_achievements()


func _on_ach_page_next() -> void:
	_ach_page = mini(_ach_page + 1, _ach_page_count() - 1)
	_rebuild_achievements()


func _on_ach_page_prev() -> void:
	_ach_page = maxi(_ach_page - 1, 0)
	_rebuild_achievements()


func _set_ach_pager_visible(p_visible: bool) -> void:
	# 翻页控件显隐（页签行与返回大厅按钮同排错峰——选关面板/其他页签下不可见）
	if _ach_prev_btn != null:
		_ach_prev_btn.visible = p_visible
		_ach_next_btn.visible = p_visible
		_ach_page_label.visible = p_visible


func _sticker_ach_tab() -> void:
	# 成就活动页签高亮（非活动降透明；_sticker_active_tab 同款）
	for kind: String in _ach_tabs:
		(_ach_tabs[kind] as Button).modulate = Color.WHITE \
			if kind == _ach_tab else Color(1.0, 1.0, 1.0, 0.55)


func _rebuild_achievements() -> void:
	for c in _panel_list.get_children():
		(c as Node).queue_free()
	var list := _ach_filtered()
	var pages := maxi(1, ceili(float(list.size()) / float(ACH_PAGE_SIZE)))
	_ach_page = clampi(_ach_page, 0, pages - 1)
	for i in range(_ach_page * ACH_PAGE_SIZE, mini((_ach_page + 1) * ACH_PAGE_SIZE, list.size())):
		var a: Dictionary = list[i]
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
	_sticker_ach_tab()
	if _ach_page_label != null:
		_ach_page_label.text = "%d/%d" % [_ach_page + 1, pages]
		if _ach_prev_btn != null:
			_ach_prev_btn.disabled = _ach_page <= 0
			_ach_next_btn.disabled = _ach_page >= pages - 1


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
		row.custom_minimum_size = Vector2(576.0, 140.0)   # R194 触控目标放大联动（118→140，行底容纳 92+48 武器循环钮）
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# 技能图标（2026-08-31 用户反馈「技能好歹画个对应的图标」）：行首 48px 程序化图标
		var skill_ico := TextureRect.new()
		skill_ico.name = "SkillIcon"
		skill_ico.texture = TextureFactory.skill_icon(def.id)
		skill_ico.position = Vector2(14.0, 24.0)
		skill_ico.custom_minimum_size = Vector2(48.0, 48.0)
		skill_ico.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		skill_ico.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		skill_ico.modulate.a = 1.0 if unlocked else 0.3
		skill_ico.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(skill_ico)
		var name_l := Label.new()
		StickerTheme.label_sticker(name_l, 20, PopPalette.PLAYER if picked else (PopPalette.INK if unlocked else PopPalette.INK_SOFT),
			0, Color.WHITE, true)
		var unlock_hint := ""
		# R196：锁/奖杯/结晶 emoji 前缀删除（Android 系统字体链缺 SMP 字形只出字不出图——
		# apk_menu_no_icons 定案 T7；仅删符号不动词，行首全角空格保留）
		if not unlocked:
			var umap: StringName = def.get("unlock_map", &"")
			if umap != &"":
				unlock_hint = "　通关「%s」解锁" % String(MapTable.get_map(umap).get("name", "?"))
			elif bool(def.get("unlock_normal_clear", false)):
				# R186：改造者·枢——任一地图常规局普通通关（每日局结算分流不解锁）
				# R198（二aw-7）：锁定句压缩——删「任一地图常规局 · 当前最佳 %d 波」段（当前最佳
				# 波次已由记录/成就面可见，此处冗余）。规划拟句「（首关需 %d 波）」连同角色名前缀
				# 实测仍溢 406px 格（≈21.5 全角 ≈430px → name_l autowrap 折两行压 stat/skill 行），
				# 再省「需」字 + 数字前空格（语义不变）→ 估宽 400px（真字型 396px）单行可容；
				# 兜底见下方 name_l autowrap。
				unlock_hint = "　通关普通难度解锁（首关%d 波）" % [
					int(MapTable.get_map(MapTable.FIRST_MAP_ID).get("final_wave", 10))]
			elif bool(def.get("unlock_hard_clear", false)):
				unlock_hint = "　任意地图·困难难度通关解锁"   # R186：回响·伊可
			elif int(def.get("unlock_kills", 0)) > 0:
				unlock_hint = "　图鉴累计击杀 %d 解锁" % int(def.get("unlock_kills", 0))
			elif def.get("unlock_achievement", &"") != &"":
				var uach: StringName = def.get("unlock_achievement", &"")
				var aname := String(uach)
				for a in Meta.ACHIEVEMENTS:
					if a.id == uach:
						aname = String(a.name)
				unlock_hint = "　成就「%s」解锁" % aname
			elif int(def.get("unlock_price", 0)) > 0:
				unlock_hint = "　结晶解锁 %d（当前 %d）" % [int(def.get("unlock_price", 0)), Meta.crystals]
		name_l.text = String(def.name) + ("　✓ 当前" if picked else "") + unlock_hint
		name_l.position = Vector2(74.0, 12.0)
		name_l.size = Vector2(406.0, 28.0)
		# R198（二aw-7）：锁定句溢出兜底折行（高度 28 不变；theme.gd label_sticker 默认不加
		# autowrap——调用点显式设避免全站涟漪；防未来文案漂移再裁字）
		name_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(name_l)
		var stat_l := Label.new()
		StickerTheme.label_sticker(stat_l, 14, PopPalette.INK_SOFT)
		stat_l.text = "生命 %d　攻击 %s%.0f%%" % [int(def.hp),
			"+" if float(def.atk_pct) >= 0.0 else "", float(def.atk_pct) * 100.0]
		stat_l.position = Vector2(74.0, 46.0)
		stat_l.size = Vector2(346.0, 20.0)
		stat_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(stat_l)
		# 技能行（R186：改 def.get() 读法 + no_skill 分支——全项目唯一点读
		# def.skill_name/skill_desc/cd 处，fission 无技能键不崩）
		# R198（P2-skillcopy）：noah desc 尾补 12% 括注后长文案溢出 486px 单行格——
		# 换行区自检落位：skill_l 补 autowrap（行底 72..108 有空，140 行高内二行可容；
		# 短文案角色单行不变。调用点显式设——同二aw-7 name_l 口径，不动 label_sticker）
		var has_skill := CharacterTable.has_skill(def.id)
		var skill_l := Label.new()
		StickerTheme.label_sticker(skill_l, 14, PopPalette.ENEMY)
		if has_skill:
			skill_l.text = "技能【%s】%s（CD %.0fs）" % [String(def.get("skill_name", "")),
				String(def.get("skill_desc", "")), float(def.get("cd", 120.0))]
		else:
			skill_l.text = "无技能 · 初始武器自定义（开局前选定）"
		skill_l.position = Vector2(74.0, 72.0)
		skill_l.size = Vector2(486.0, 36.0)
		skill_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		skill_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(skill_l)
		if not has_skill:
			# R186 改造者·枢：行内首发武器循环（候选 = 手枪白名单 ∪ 图鉴已解锁，registry 序）
			var wcycle := Button.new()
			wcycle.name = "CustomWeaponCycle"
			wcycle.text = "初始武器：%s ▸" % _custom_weapon_label()
			wcycle.add_theme_font_size_override("font_size", 13)
			wcycle.add_theme_font_override("font", StickerTheme.font_bold())
			wcycle.position = Vector2(74.0, 92.0)
			wcycle.size = Vector2(300.0, 48.0)   # R194 触控目标放大（300×24→300×48，行底 92+48=140 恰齐）
			wcycle.focus_mode = Control.FOCUS_NONE
			# R190：武器效果 hover 说明——循环切换按钮只改名不解释，玩家不知道每把枪
			# 干嘛的（尤其棱镜「万镜回廊」这类特殊机制）；note 取 GameConst 真源，
			# cycle 后 _rebuild_char_select 重建按钮 → tooltip 随新武器刷新
			var cw_note := GameConst.weapon_note(String(Meta.custom_weapon())) if String(Meta.custom_weapon()) != "" \
				else GameConst.weapon_note("W1_pistol")
			wcycle.tooltip_text = "点击切换初始武器\n%s" % cw_note if cw_note != "" \
				else "点击切换初始武器"
			wcycle.mouse_filter = Control.MOUSE_FILTER_STOP
			wcycle.pressed.connect(_on_custom_weapon_cycle)
			wcycle.button_down.connect(func() -> void: StickerTheme.press_punch(wcycle))
			row.add_child(wcycle)
			var codex_l := Label.new()
			StickerTheme.label_sticker(codex_l, 12, PopPalette.INK_SOFT)
			codex_l.text = "图鉴 %d/%d · 局内抽到新枪可解选" % [
				Meta.codex_weapons.size(),
				registry.weapons.size() if registry != null else 0]
			codex_l.position = Vector2(382.0, 118.0)   # R194 联动下移（96→118，避让放大后的武器循环钮 92-140）
			codex_l.size = Vector2(180.0, 18.0)
			codex_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(codex_l)
		if not picked and unlocked:
			var pick_btn := Button.new()
			pick_btn.text = "选用"
			pick_btn.add_theme_font_size_override("font_size", 16)
			pick_btn.add_theme_font_override("font", StickerTheme.font_bold())
			pick_btn.position = Vector2(478.0, 38.0)
			pick_btn.size = Vector2(84.0, 56.0)   # R194 触控目标放大（84×44→84×56，角色行 140 内）
			pick_btn.focus_mode = Control.FOCUS_NONE
			pick_btn.pressed.connect(_on_char_pick.bind(def.id))
			pick_btn.button_down.connect(func() -> void: StickerTheme.press_punch(pick_btn))
			row.add_child(pick_btn)
		elif not picked and int(def.get("unlock_price", 0)) > 0:
			# 购买门：解锁按钮（结晶不足置灰——purchase_character 不足返回 false 口径）
			# R196：结晶符号 → ui_gem 贴纸 icon（Button.icon 原生排版，84px 钮内 icon_max_width 钳宽防挤）
			var price := int(def.get("unlock_price", 0))
			var buy_btn := Button.new()
			buy_btn.text = "解锁 %d" % price
			buy_btn.icon = TextureFactory.ui_gem()
			buy_btn.add_theme_constant_override("icon_max_width", 20)
			buy_btn.add_theme_font_size_override("font_size", 14)
			buy_btn.add_theme_font_override("font", StickerTheme.font_bold())
			buy_btn.position = Vector2(478.0, 38.0)
			buy_btn.size = Vector2(84.0, 56.0)   # R194 触控目标放大（84×44→84×56，角色行 140 内）
			buy_btn.focus_mode = Control.FOCUS_NONE
			buy_btn.disabled = Meta.crystals < price
			buy_btn.pressed.connect(_on_char_buy.bind(def.id))
			buy_btn.button_down.connect(func() -> void: StickerTheme.press_punch(buy_btn))
			row.add_child(buy_btn)
		_panel_list.add_child(row)


func _custom_weapon_candidates() -> Array[StringName]:
	# R186：fission 首发候选集 = W1_pistol 白名单（W1 被卡池永久排除，必须放行）∪
	# 图鉴已解锁武器（registry 序，去重）。
	# R196：准入门只设在「来源侧」（卡池上架 + echo 双武装池——mechanic_gate.gd wunlock
	# 注释块）；到达本处的候选必已获得（上行 is_weapon_unlocked 过滤），按「获得优先于门」
	# 照常入选——R196 评审修复：原 weapon_allowed 过滤在菜单态读 run_map 残留（冷启动
	# =world_grass → map_index()==0），把老档已获得∧门外武器全滤掉（10→3 把）且循环钮
	# 把存档非初始批首发静默降级手枪落盘——定案 P6「老档无损」被破，整段门滤除。
	# 白名单首元素恒在 → 结果恒非空。
	var cands: Array[StringName] = [&"W1_pistol"]
	if registry != null:
		for wid_v: Variant in registry.weapons.keys():
			var sid := StringName(String(wid_v))
			if sid == &"W1_pistol" or cands.has(sid) or not Meta.is_weapon_unlocked(sid):
				continue
			cands.append(sid)
	return cands


func _custom_weapon_label() -> String:
	# R186：当前首发展示名（空键 → 手枪；脏 id → 原样 id 文本）
	var wid := Meta.custom_weapon()
	if wid == &"":
		return "手枪"
	var wd: WeaponData = registry.get_weapon(wid) if registry != null else null
	return String(wd.display_name) if wd != null else String(wid)


func _on_custom_weapon_cycle() -> void:
	# R186：首发循环按钮——候选序取当前下一项（缺项/脏键 → 回首候选），写口自校验
	#（未解锁 push_warning 忽略）+ 写即落盘，重建面板即时刷新
	var cands := _custom_weapon_candidates()
	if cands.is_empty():
		return
	var idx := cands.find(Meta.custom_weapon())
	var next: StringName = cands[0] if idx < 0 else cands[(idx + 1) % cands.size()]
	Meta.set_custom_weapon(next)
	_rebuild_char_select()


func _on_char_pick(p_id: StringName) -> void:
	Meta.set_character_id(p_id)
	_rebuild_char_select()
	_refresh_lobby_counts()
	_refresh_mascot()


func _on_char_buy(p_id: StringName) -> void:
	# 结晶购买角色（Meta 扣费 + 永久记录；成功音同「换一批次数」金币音——购买爽感反馈）
	if Meta.purchase_character(p_id):
		if SfxBank.I != null:
			SfxBank.I.play(&"coin")
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
		# R196：结晶符号 → ui_gem 贴纸 icon（已满级无花费 → 不挂贴纸；140px 钮内排版余量足）
		buy.text = "已满级" if maxed else "升级 (%d)" % cost
		buy.icon = null if maxed else TextureFactory.ui_gem()
		if not maxed:
			buy.add_theme_constant_override("icon_max_width", 22)
		buy.add_theme_font_size_override("font_size", 15)
		buy.add_theme_font_override("font", StickerTheme.font_bold())
		buy.position = Vector2(420.0, 6.0)   # R194 触控目标放大 140×56（养成行 68 内居中：6+56=62）
		buy.size = Vector2(140.0, 56.0)
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
		# E11 分档战绩：困/狱任一有记录 → 三档并列展示（一眼看到难度进度差）
		var mr_h: Dictionary = Meta.map_records.get(String(def.id) + "#1", {})
		var mr_l: Dictionary = Meta.map_records.get(String(def.id) + "#2", {})
		if mr_h.is_empty() and mr_l.is_empty():
			lines.append(["%s 最高波次" % String(def.name),
				"%d%s%s" % [int(mr.get("best_wave", 0)), " ★" if Meta.is_map_cleared(def.id) else "",
					" · 无尽 %d" % depth if depth > 0 else ""]])
		else:
			lines.append(["%s 最高波次（普/困/狱）" % String(def.name),
				"%d%s / %d / %d" % [int(mr.get("best_wave", 0)),
					"★" if Meta.is_map_cleared(def.id) else "",
					int(mr_h.get("best_wave", 0)), int(mr_l.get("best_wave", 0))]])
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

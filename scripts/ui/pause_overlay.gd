# scripts/ui/pause_overlay.gd
# 方向 C 暂停遮罩面板（用户反馈 2026-08-29「没有暂停的地方」）：全屏压暗 + 「暂停中」
# 大标题白卡 + 四按钮（继续 / 重新开始 / 回主菜单 / 设置——P3 设置页入口，纯 UI 不改
# 暂停态）。仅 PAUSED 态显示（state_changed 绑定）。
# process_mode = ALWAYS（tree.paused 期间 UI 照常，Q-14 口径）；申请经信号 → GameLoop
# 仲裁（迁移矩阵唯一裁决位，E-16 同源）：resume→PLAYING / restart→restart_run /
# menu→quit_to_menu（PAUSED→MENU 合法迁移，pkg4 非法迁移枚举不含此对，证据见交付报告）。
class_name PauseOverlay
extends CanvasLayer

signal resume_requested()                     # → GameLoop.request_resume()（PAUSED → PLAYING）
signal restart_requested()                    # → GameLoop.restart_run()（PAUSED → PLAYING 重开）
signal menu_requested()                       # → GameLoop.quit_to_menu()（PAUSED → MENU）
signal settings_requested()                   # → GameLoop 接线 SettingsPanel.open（P3，纯 UI 不改状态）

var _root: Control = null
var _card: Panel = null
# 构筑详情模式（用户反馈 2026-08-29「点击左下角，可以看 buff 详情」）：左下角构筑面板
# 点击 → GameLoop 申请暂停 + 进入详情卡；详情/暂停两卡互斥显示，PAUSED 态内可切换。
var _details_mode: bool = false
var _details_card: Panel = null
var _details_list: Control = null
var _player_ref: Node = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_build_details_ui()
	_root.visible = false
	EventBus.state_changed.connect(_on_state_changed)


func is_pause_visible() -> bool:
	# 测试观测口
	return _root != null and _root.visible


func is_details_visible() -> bool:
	# 测试观测口（构筑详情卡可见性）
	return _details_card != null and _details_card.visible


func open_details(p_player: Node) -> void:
	# 构筑详情模式开启（GameLoop 暂停仲裁通过后调用；注入 player 供内容刷新）
	_player_ref = p_player
	_details_mode = true
	_refresh_cards()


func toggle_details() -> void:
	# PAUSED 态内：暂停卡 ↔ 详情卡切换（再次点击左下角同效）
	_details_mode = not _details_mode
	_refresh_cards()


func _on_state_changed(p_state: int) -> void:
	var show := p_state == GameConst.GameStatus.PAUSED
	_root.visible = show
	if show:
		_refresh_cards()
	else:
		_details_mode = false


func _refresh_cards() -> void:
	# 双卡互斥：PAUSED 且详情模式 → 详情卡；否则暂停卡
	var paused := _root != null and _root.visible
	_card.visible = paused and not _details_mode
	_details_card.visible = paused and _details_mode
	if _card.visible:
		StickerTheme.squash_pop(_card)
	if _details_card.visible:
		_rebuild_details()
		StickerTheme.squash_pop(_details_card)


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "PauseRoot"
	_root.theme = StickerTheme.theme()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# 全屏压暗（藏青半透——战斗画面隐约可见，暂停观感）
	var dim := ColorRect.new()
	dim.name = "PauseDim"
	dim.color = PopPalette.DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)

	# 暂停白卡（贴纸面板：圆角 24 + 藏青描边 + 底部厚投影；P3 加高容纳第四钮「设置」）
	_card = Panel.new()
	_card.name = "PauseCard"
	_card.add_theme_stylebox_override("panel", StickerTheme.panel_style(24.0, 4, true))
	_card.position = Vector2(120.0, 378.0)
	_card.size = Vector2(480.0, 524.0)
	_card.pivot_offset = _card.size * 0.5
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_card)

	# 卡顶 ▶ 小徽标（压在卡沿上——贴纸叠贴感，与暂停按钮同源图形）
	var glyph := TextureRect.new()
	glyph.name = "PauseGlyph"
	glyph.texture = TextureFactory.ui_glyph(1)
	glyph.position = Vector2(208.0, -46.0)
	glyph.custom_minimum_size = Vector2(84.0, 84.0)
	glyph.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glyph.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(glyph)

	var title := Label.new()
	StickerTheme.label_sticker(title, 40, PopPalette.INK, 0, Color.WHITE, true)
	title.text = "暂停中"
	title.position = Vector2(0.0, 56.0)
	title.size = Vector2(480.0, 48.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card.add_child(title)

	var hint := Label.new()
	StickerTheme.label_sticker(hint, 15, PopPalette.INK_SOFT)
	hint.text = "Esc / P 也可继续战斗"
	hint.position = Vector2(0.0, 116.0)
	hint.size = Vector2(480.0, 20.0)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card.add_child(hint)

	_add_card_button("ResumeButton", "继续", Vector2(140.0, 156.0), _on_resume_pressed)
	_add_card_button("RestartButton", "重新开始", Vector2(140.0, 246.0), _on_restart_pressed)
	_add_card_button("MenuButton", "回主菜单", Vector2(140.0, 336.0), _on_menu_pressed)
	_add_card_button("SettingsButton", "设置", Vector2(140.0, 426.0), _on_settings_pressed)


func _add_card_button(p_name: String, p_text: String, p_pos: Vector2, p_handler: Callable) -> void:
	# 卡内贴纸按钮（四态由 Theme 承担 + 按下 punch）
	var btn := Button.new()
	btn.name = p_name
	btn.text = p_text
	btn.add_theme_font_size_override("font_size", 22)
	btn.add_theme_font_override("font", StickerTheme.font_bold())
	btn.position = p_pos
	btn.size = Vector2(200.0, 72.0)
	btn.pivot_offset = btn.size * 0.5
	btn.pressed.connect(p_handler)
	btn.button_down.connect(func() -> void: StickerTheme.press_punch(btn))
	_card.add_child(btn)


func _on_resume_pressed() -> void:
	_details_mode = false
	resume_requested.emit()


# ── 构筑详情卡（buff 详情：武器 × 词条全量列表） ─────────────────────
func _build_details_ui() -> void:
	_details_card = Panel.new()
	_details_card.name = "DetailsCard"
	_details_card.add_theme_stylebox_override("panel", StickerTheme.panel_style(24.0, 4, true))
	_details_card.position = Vector2(44.0, 120.0)
	_details_card.size = Vector2(632.0, 1000.0)
	_details_card.pivot_offset = _details_card.size * 0.5
	_details_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_details_card.visible = false
	_root.add_child(_details_card)

	var glyph := TextureRect.new()
	glyph.name = "DetailsGlyph"
	glyph.texture = TextureFactory.type_icon(1, 3)
	glyph.position = Vector2(274.0, -40.0)
	glyph.custom_minimum_size = Vector2(84.0, 84.0)
	glyph.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glyph.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_details_card.add_child(glyph)

	var title := Label.new()
	StickerTheme.label_sticker(title, 34, PopPalette.INK, 0, Color.WHITE, true)
	title.text = "构筑详情"
	title.position = Vector2(0.0, 40.0)
	title.size = Vector2(632.0, 44.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_details_card.add_child(title)

	var hint := Label.new()
	StickerTheme.label_sticker(hint, 14, PopPalette.INK_SOFT)
	hint.text = "当前持有武器与词条（内容为实际生效值）"
	hint.position = Vector2(0.0, 88.0)
	hint.size = Vector2(632.0, 20.0)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_details_card.add_child(hint)

	# 滚动列表（5 武器 × 12 词条上限口径——超出可视高度可滚）
	var scroll := ScrollContainer.new()
	scroll.name = "DetailsScroll"
	scroll.position = Vector2(28.0, 122.0)
	scroll.size = Vector2(576.0, 712.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_details_card.add_child(scroll)
	_details_list = VBoxContainer.new()
	_details_list.name = "DetailsList"
	_details_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_details_list.add_theme_constant_override("separation", 10)
	scroll.add_child(_details_list)

	_add_details_button("DetailsBackButton", "返回", Vector2(58.0, 872.0), _on_details_back)
	_add_details_button("DetailsResumeButton", "继续战斗", Vector2(348.0, 872.0), _on_resume_pressed)


func _add_details_button(p_name: String, p_text: String, p_pos: Vector2, p_handler: Callable) -> void:
	var btn := Button.new()
	btn.name = p_name
	btn.text = p_text
	btn.add_theme_font_size_override("font_size", 20)
	btn.add_theme_font_override("font", StickerTheme.font_bold())
	btn.position = p_pos
	btn.size = Vector2(226.0, 64.0)
	btn.pivot_offset = btn.size * 0.5
	btn.pressed.connect(p_handler)
	btn.button_down.connect(func() -> void: StickerTheme.press_punch(btn))
	_details_card.add_child(btn)


func _on_details_back() -> void:
	# 详情卡 → 暂停卡（PAUSED 态内切换）
	_details_mode = false
	_refresh_cards()


func _rebuild_details() -> void:
	# 内容重建（每次显示时刷新；player 由 open_details 注入）
	for c in _details_list.get_children():
		(c as Node).queue_free()
	if _player_ref == null or not is_instance_valid(_player_ref):
		return
	var slots: Array = _player_ref.get("weapon_slots")
	var any := false
	for w in slots:
		if w == null or not is_instance_valid(w):
			continue
		any = true
		_details_list.add_child(_make_weapon_section(w))
	if not any:
		var empty := Label.new()
		StickerTheme.label_sticker(empty, 18, PopPalette.INK_SOFT)
		empty.text = "暂无武器（选一张「新武器」卡开始构筑）"
		empty.size = Vector2(560.0, 40.0)
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_details_list.add_child(empty)


func _make_weapon_section(p_w: Node) -> Control:
	# 单武器区块：图标 + 名称 Lv 头行 + 词条行 ×N（章形 + 名 ×层 + 描述实际值）
	var wdata: Variant = p_w.get("data")
	var section := VBoxContainer.new()
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section.add_theme_constant_override("separation", 4)
	var head := Panel.new()
	head.add_theme_stylebox_override("panel", StickerTheme.panel_style(12.0, 3, false))
	head.custom_minimum_size = Vector2(576.0, 52.0)
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	section.add_child(head)
	var icon := TextureRect.new()
	icon.texture = TextureFactory.weapon_icon(
		StringName(str(wdata.get("id"))) if wdata != null else &"W_MISSING")
	icon.position = Vector2(8.0, 6.0)
	icon.custom_minimum_size = Vector2(40.0, 40.0)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(icon)
	var wname := Label.new()
	StickerTheme.label_sticker(wname, 19, PopPalette.INK, 0, Color.WHITE, true)
	wname.text = "%s  Lv%d" % [String(wdata.get("display_name")) if wdata != null else "?",
		int(p_w.get("level"))]
	wname.position = Vector2(58.0, 14.0)
	wname.size = Vector2(500.0, 26.0)
	wname.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(wname)

	var stack: Variant = p_w.get("trait_stack")
	var traits: Array = (stack.get("traits") as Array) if stack != null \
		and stack.get("traits") != null else []
	if traits.is_empty():
		var none := Label.new()
		StickerTheme.label_sticker(none, 14, PopPalette.INK_SOFT)
		none.text = "　└ 暂无词条"
		none.size = Vector2(540.0, 20.0)
		none.mouse_filter = Control.MOUSE_FILTER_IGNORE
		section.add_child(none)
		return section
	for t: Variant in traits:
		var td: Variant = t.get("data")
		if td == null:
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var gem := TextureRect.new()
		gem.texture = TextureFactory.type_icon(1, int(td.get("pool")))
		gem.custom_minimum_size = Vector2(26.0, 26.0)
		gem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		gem.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		gem.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(gem)
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_theme_constant_override("separation", 0)
		col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tname := Label.new()
		StickerTheme.label_sticker(tname, 16, PopPalette.INK, 0, Color.WHITE, true)
		var layers := int(t.get("layers"))
		tname.text = String(td.get("display_name")) + ("　×%d" % layers if layers > 1 else "")
		tname.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_child(tname)
		var tdesc := Label.new()
		StickerTheme.label_sticker(tdesc, 13, PopPalette.INK_SOFT)
		tdesc.text = "　└ " + String(td.get("description"))
		tdesc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		tdesc.custom_minimum_size = Vector2(500.0, 0.0)
		tdesc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tdesc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_child(tdesc)
		row.add_child(col)
		section.add_child(row)
	return section


func _on_restart_pressed() -> void:
	restart_requested.emit()


func _on_menu_pressed() -> void:
	menu_requested.emit()


func _on_settings_pressed() -> void:
	# 设置页打开（P3）：纯 UI 层——暂停态不变，面板盖在暂停卡上方，关闭即恢复
	settings_requested.emit()

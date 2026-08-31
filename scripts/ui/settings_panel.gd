# scripts/ui/settings_panel.gd
# P3 设置页（META_ROADMAP §5.10「设置页：音量/震屏开关」）：贴纸风全屏独立面板。
# 两滑条（音效/音乐音量，HSlider 贴纸化：圆珠 grabber + 圆角描边槽）+ 两开关
#（震屏 / 伤害数字，Button 触发翻转，✓/✗ 态样式）。入口两处（大厅按钮行 + 暂停卡
# 「设置」按钮），GameLoop 接线 open()；纯 UI 层——写口统一走 Meta.set_setting
#（写即存），音量经 Meta.settings_changed → SfxBank 实时应用，震屏/跳字在消费入口
# 短路；关闭只隐藏本层（恢复原界面，菜单/暂停卡不受扰）。
class_name SettingsPanel
extends CanvasLayer

var _root: Control = null
var _card: Panel = null
var _sfx_slider: HSlider = null
var _bgm_slider: HSlider = null
var _sfx_value: Label = null
var _bgm_value: Label = null
var _shake_btn: Button = null
var _dmg_btn: Button = null
var _syncing: bool = false                    # 回填守卫（open 回填不触发写口）


func _ready() -> void:
	layer = 10                                   # 盖过菜单/暂停卡（CanvasLayer 默认 1）
	process_mode = Node.PROCESS_MODE_ALWAYS      # 暂停期间可操作（Q-14 口径）
	_build_ui()
	_root.visible = false


func is_open() -> bool:
	# 测试观测口（开合状态机）
	return _root != null and _root.visible


func open() -> void:
	# 打开：从 Meta 回填当前值（不触发写口）→ 果冻出现
	_sync_from_meta()
	_root.visible = true
	StickerTheme.squash_pop(_card)


func close() -> void:
	# 关闭：恢复原界面（下方菜单/暂停卡本就可见，只隐藏本层）
	_root.visible = false


# ── 组装（程序化贴纸风，零外部资源） ──────────────────────────────
func _build_ui() -> void:
	_root = Control.new()
	_root.name = "SettingsRoot"
	_root.theme = StickerTheme.theme()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# 全屏压暗（藏青半透——下方界面隐约可见，关闭即恢复）
	var dim := ColorRect.new()
	dim.name = "SettingsDim"
	dim.color = PopPalette.DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)

	# 设置白卡（贴纸面板：圆角 24 + 藏青描边 + 底部厚投影）
	_card = Panel.new()
	_card.name = "SettingsCard"
	_card.add_theme_stylebox_override("panel", StickerTheme.panel_style(24.0, 4, true))
	_card.position = Vector2(50.0, 290.0)
	_card.size = Vector2(620.0, 700.0)
	_card.pivot_offset = _card.size * 0.5
	_root.add_child(_card)

	# 卡顶 ⚙ 小徽标（压在卡沿上——贴纸叠贴感，同暂停卡 ▶ 徽标口径）
	var glyph := TextureRect.new()
	glyph.name = "SettingsGlyph"
	glyph.texture = TextureFactory.bead(PopPalette.XP, 64)
	glyph.position = Vector2(268.0, -40.0)
	glyph.custom_minimum_size = Vector2(84.0, 84.0)
	glyph.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glyph.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(glyph)

	var title := Label.new()
	StickerTheme.label_sticker(title, 36, PopPalette.INK, 0, Color.WHITE, true)
	title.text = "设置"
	title.position = Vector2(0.0, 46.0)
	title.size = Vector2(620.0, 44.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card.add_child(title)

	# ── 音效音量（滑条 + 百分比） ──
	_sfx_value = _add_volume_row("SfxVolumeLabel", "音效音量", 116.0)
	_sfx_slider = _make_sticker_slider(Vector2(40.0, 152.0), PopPalette.PLAYER)
	_sfx_slider.value_changed.connect(_on_sfx_volume_changed)
	_card.add_child(_sfx_slider)

	# ── 音乐音量（滑条 + 百分比） ──
	_bgm_value = _add_volume_row("BgmVolumeLabel", "音乐音量", 214.0)
	_bgm_slider = _make_sticker_slider(Vector2(40.0, 250.0), PopPalette.SUCCESS)
	_bgm_slider.value_changed.connect(_on_bgm_volume_changed)
	_card.add_child(_bgm_slider)

	# ── 开关行：震屏 / 伤害数字（✓ 开 薄荷绿 / ✗ 关 灰） ──
	_shake_btn = _add_toggle_row("ShakeToggleButton", "震屏", 312.0, _on_shake_toggle)
	_dmg_btn = _add_toggle_row("DamageNumbersToggleButton", "伤害数字", 402.0, _on_dmg_toggle)

	var hint := Label.new()
	StickerTheme.label_sticker(hint, 13, PopPalette.INK_SOFT)
	hint.text = "设置即存 · 立即生效（关震屏不影响顿帧打击感）"
	hint.position = Vector2(0.0, 492.0)
	hint.size = Vector2(620.0, 20.0)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card.add_child(hint)

	var close_btn := Button.new()
	close_btn.name = "SettingsCloseButton"
	close_btn.text = "返 回"
	close_btn.add_theme_font_size_override("font_size", 22)
	close_btn.add_theme_font_override("font", StickerTheme.font_bold())
	close_btn.position = Vector2(190.0, 552.0)
	close_btn.size = Vector2(240.0, 68.0)
	close_btn.pivot_offset = close_btn.size * 0.5
	close_btn.pressed.connect(close)
	close_btn.button_down.connect(func() -> void: StickerTheme.press_punch(close_btn))
	_card.add_child(close_btn)


func _add_volume_row(p_name: String, p_text: String, p_y: float) -> Label:
	# 音量行头：左标签 + 右百分比（返回百分比 Label 供拖动刷新）
	var name_l := Label.new()
	StickerTheme.label_sticker(name_l, 20, PopPalette.INK, 0, Color.WHITE, true)
	name_l.name = p_name
	name_l.text = p_text
	name_l.position = Vector2(40.0, p_y)
	name_l.size = Vector2(240.0, 30.0)
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(name_l)
	var val_l := Label.new()
	StickerTheme.label_sticker(val_l, 20, PopPalette.PLAYER, 0, Color.WHITE, true)
	val_l.name = p_name + "Value"
	val_l.text = "0%"
	val_l.position = Vector2(480.0, p_y)
	val_l.size = Vector2(100.0, 30.0)
	val_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(val_l)
	return val_l


func _make_sticker_slider(p_pos: Vector2, p_fill: Color) -> HSlider:
	# HSlider 贴纸化：圆角描边槽 + 同色填充段 + 圆珠 grabber（TextureFactory.bead）
	var slider := HSlider.new()
	var groove := StyleBoxFlat.new()
	groove.bg_color = PopPalette.PANEL_PRESS
	groove.border_color = PopPalette.OUTLINE
	groove.set_border_width_all(3)
	groove.set_corner_radius_all(12)
	groove.content_margin_top = 7.0
	groove.content_margin_bottom = 7.0
	slider.add_theme_stylebox_override("slider", groove)
	var fill := StyleBoxFlat.new()
	fill.bg_color = p_fill
	fill.set_corner_radius_all(12)
	fill.content_margin_top = 7.0
	fill.content_margin_bottom = 7.0
	slider.add_theme_stylebox_override("grabber_area", fill)
	var fill_hi := StyleBoxFlat.new()
	fill_hi.bg_color = p_fill.lightened(0.18)
	fill_hi.set_corner_radius_all(12)
	fill_hi.content_margin_top = 7.0
	fill_hi.content_margin_bottom = 7.0
	slider.add_theme_stylebox_override("grabber_area_highlight", fill_hi)
	slider.add_theme_icon_override("grabber", TextureFactory.bead(p_fill, 44))
	slider.add_theme_icon_override("grabber_highlight", TextureFactory.bead(PopPalette.XP, 48))
	slider.add_theme_icon_override("grabber_disabled", TextureFactory.bead(PopPalette.INK_SOFT, 44))
	slider.position = p_pos
	slider.size = Vector2(540.0, 36.0)
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05                           # 5% 步进（拖动少落盘，写即存仍成立）
	slider.focus_mode = Control.FOCUS_NONE
	return slider


func _add_toggle_row(p_btn_name: String, p_text: String, p_y: float, p_handler: Callable) -> Button:
	# 开关行：左标签 + 右翻转按钮（✓ 开 = 薄荷绿 / ✗ 关 = 弱化灰）
	var name_l := Label.new()
	StickerTheme.label_sticker(name_l, 20, PopPalette.INK, 0, Color.WHITE, true)
	name_l.text = p_text
	name_l.position = Vector2(40.0, p_y + 14.0)
	name_l.size = Vector2(300.0, 30.0)
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(name_l)
	var btn := Button.new()
	btn.name = p_btn_name
	btn.add_theme_font_size_override("font_size", 19)
	btn.add_theme_font_override("font", StickerTheme.font_bold())
	btn.position = Vector2(440.0, p_y)
	btn.size = Vector2(140.0, 58.0)
	btn.pivot_offset = btn.size * 0.5
	btn.focus_mode = Control.FOCUS_NONE
	btn.pressed.connect(p_handler)
	btn.button_down.connect(func() -> void: StickerTheme.press_punch(btn))
	_card.add_child(btn)
	return btn


# ── 写口（统一 Meta.set_setting——写即存，信号驱动播放/短路链实时生效） ──
func _on_sfx_volume_changed(p_value: float) -> void:
	if _syncing:
		return                                   # open 回填触发 → 只刷 UI 不写盘
	Meta.set_setting("sfx_volume", p_value)
	_sfx_value.text = "%d%%" % roundi(clampf(p_value, 0.0, 1.0) * 100.0)


func _on_bgm_volume_changed(p_value: float) -> void:
	if _syncing:
		return                                   # open 回填触发 → 只刷 UI 不写盘
	Meta.set_setting("bgm_volume", p_value)
	_bgm_value.text = "%d%%" % roundi(clampf(p_value, 0.0, 1.0) * 100.0)


func _on_shake_toggle() -> void:
	Meta.set_setting("shake_on", not bool(Meta.settings("shake_on")))
	_refresh_toggles()


func _on_dmg_toggle() -> void:
	Meta.set_setting("damage_numbers_on", not bool(Meta.settings("damage_numbers_on")))
	_refresh_toggles()


# ── 回填/刷新 ─────────────────────────────────────────────────────
func _sync_from_meta() -> void:
	# 打开时回填当前值（守卫位防回填触发 value_changed 二次写盘）
	_syncing = true
	_sfx_slider.value = float(Meta.settings("sfx_volume"))
	_bgm_slider.value = float(Meta.settings("bgm_volume"))
	_syncing = false
	_sfx_value.text = "%d%%" % roundi(float(Meta.settings("sfx_volume")) * 100.0)
	_bgm_value.text = "%d%%" % roundi(float(Meta.settings("bgm_volume")) * 100.0)
	_refresh_toggles()


func _refresh_toggles() -> void:
	# ✓/✗ 态样式（开 = 薄荷绿 + ✓ / 关 = 弱化灰 + ✗）
	var on := bool(Meta.settings("shake_on"))
	_shake_btn.text = "✓ 开" if on else "✗ 关"
	_shake_btn.add_theme_color_override("font_color",
		PopPalette.SUCCESS if on else PopPalette.INK_SOFT)
	var dmg_on := bool(Meta.settings("damage_numbers_on"))
	_dmg_btn.text = "✓ 开" if dmg_on else "✗ 关"
	_dmg_btn.add_theme_color_override("font_color",
		PopPalette.SUCCESS if dmg_on else PopPalette.INK_SOFT)

# scripts/ui/settings_panel.gd
# P3 设置页（META_ROADMAP §5.10「设置页：音量/震屏开关」）：贴纸风全屏独立面板。
# 三滑条（音效/音乐音量 + R194 特效透明度 0.3~1.0 观感旋钮，HSlider 贴纸化：圆珠
# grabber + 圆角描边槽）+ 循环/开关行（特效质量 R19 三档 / R194 帧率上限 60-90-120-不限
# / 震屏 / 伤害数字 / R196 构筑面板位置 右上-右下-左下 / R196 重置武器图鉴动作行——
# 非 settings 键，Meta.reset_weapon_codex 单源，Button 触发，✓/✗ 态样式）。入口两处（大厅按钮行 + 暂停卡
# 「设置」按钮），GameLoop 接线 open()；纯 UI 层——写口统一走 Meta.set_setting
#（写即存），音量经 Meta.settings_changed → SfxBank 实时应用，特效透明度/帧率经
# 同信号由 GameLoop/Meta 侧订阅应用，震屏/跳字在消费入口短路；关闭只隐藏本层
#（恢复原界面，菜单/暂停卡不受扰）。
class_name SettingsPanel
extends CanvasLayer

var _root: Control = null
var _card: Panel = null
var _sfx_slider: HSlider = null
var _bgm_slider: HSlider = null
var _fxo_slider: HSlider = null               # R194 特效透明度（0.3~1.0，观感减淡非提帧手段）
var _sfx_value: Label = null
var _bgm_value: Label = null
var _fxo_value: Label = null                  # R194 透明度百分比（口径同音量 "N%"）
var _shake_btn: Button = null
var _dmg_btn: Button = null
var _fx_btn: Button = null                    # 特效质量三档循环（R19：高/中/低）
var _fps_btn: Button = null                   # R194 帧率上限循环（60/90/120/不限，移动端 Engine.max_fps）
var _pos_btn: Button = null                   # R196 构筑面板位置循环（右上/右下/左下，HUD 消费 panel_pos）
var _codex_reset_btn: Button = null           # R196 重置武器图鉴动作行（非设置项——无 settings 键）
var _codex_reset_armed: bool = false          # R196 评审修复：二次确认臂（首点进入确认态，3s 无操作自动解除）
var _syncing: bool = false                    # 回填守卫（open 回填不触发写口）


func _ready() -> void:
	layer = 10                                   # 盖过菜单/暂停卡（CanvasLayer 默认 1）
	process_mode = Node.PROCESS_MODE_ALWAYS      # 暂停期间可操作（Q-14 口径）
	_build_ui()
	_root.visible = false
	# R195 适配：安全区接入（底座组 SafeAreaHelper 单点引用，不复写）。守卫外
	# （桌面窗口化/headless）insets 恒零 → offset 写 0 = 默认窗逐位恒等；真机延迟
	# ≥1 帧重读兜首帧 transform 未定型，size_changed/重获焦点由 helper 重放回调。
	_apply_safe_area()
	if SafeAreaHelper.enabled(get_window()):          # 守卫外恒零→零协程悬挂（headless 全绿面）
		_apply_safe_area_deferred()                # 真值环境延迟重读（SafeAreaHelper 契约）
	SafeAreaHelper.bind_reread(get_window(), _apply_safe_area)


func _apply_safe_area() -> void:
	# R195 安全区应用（消费式契约=SafeAreaHelper.insets 注释）：根 FULL_RECT
	# offset 左/上取正、右/下取负；dim FULL_RECT 子件随根，设置卡居中锚随根域居中。
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

	# 设置白卡（贴纸面板：圆角 24 + 藏青描边 + 底部厚投影。R194 两行并入一次布局重排：
	# 卡高 700→820，卡底 290+820=1110 ≤1280，行距重排后无重叠）
	# R195 适配分区：整体居中锚 + 中心 y=700 下偏恒等（offset=卡位−设计中心(360,640)：
	# (50,290)620×820 → ±310 / 上 −350 下 +470——下偏 +60 在任意视口高度保持）
	# R196 又并入「构筑面板位置」一行：卡高 820→894（offset_bottom 470→544），
	# abs 底 290+894=1184 ≤1280，行距 74 与既有循环行一致零重叠
	# R196 再并入「重置武器图鉴」动作行（y754，行距 74 同口径）：hint 750→824、
	# 关闭钮 798→872，卡高 894→968（offset_bottom 544→618），abs 底 290+968=1258 ≤1280
	_card = Panel.new()
	_card.name = "SettingsCard"
	_card.add_theme_stylebox_override("panel", StickerTheme.panel_style(24.0, 4, true))
	_card.anchor_left = 0.5
	_card.anchor_right = 0.5
	_card.anchor_top = 0.5
	_card.anchor_bottom = 0.5
	_card.offset_left = -310.0
	_card.offset_right = 310.0
	_card.offset_top = -350.0
	_card.offset_bottom = 618.0
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

	# ── 音效音量（滑条 + 百分比；R194 重排 106 起，滑条行距 92） ──
	_sfx_value = _add_volume_row("SfxVolumeLabel", "音效音量", 106.0)
	_sfx_slider = _make_sticker_slider(Vector2(40.0, 142.0), PopPalette.PLAYER)
	_sfx_slider.value_changed.connect(_on_sfx_volume_changed)
	_card.add_child(_sfx_slider)

	# ── 音乐音量（滑条 + 百分比） ──
	_bgm_value = _add_volume_row("BgmVolumeLabel", "音乐音量", 198.0)
	_bgm_slider = _make_sticker_slider(Vector2(40.0, 234.0), PopPalette.SUCCESS)
	_bgm_slider.value_changed.connect(_on_bgm_volume_changed)
	_card.add_child(_bgm_slider)

	# ── 特效透明度（R194：0.3~1.0 观感旋钮——乘 modulate.a 减淡，非提帧手段；
	# 提帧唯一杠杆是上方特效质量档） ──
	_fxo_value = _add_volume_row("FxOpacityLabel", "特效透明度", 290.0)
	_fxo_slider = _make_sticker_slider(Vector2(40.0, 326.0), PopPalette.XP, 0.3)
	_fxo_slider.value_changed.connect(_on_fx_opacity_changed)
	_card.add_child(_fxo_slider)

	# ── 特效质量（R19：高/中/低三档循环——buff 叠多层卡顿救） ──
	_fx_btn = _add_toggle_row("FxQualityButton", "特效质量", 384.0, _on_fx_quality_cycle)
	# ── 帧率上限（R194：60/90/120/不限 循环；仅移动端应用 Engine.max_fps，桌面基准不变） ──
	_fps_btn = _add_toggle_row("FpsCapButton", "帧率上限", 458.0, _on_fps_cap_cycle)
	# ── 开关行：震屏 / 伤害数字（✓ 开 薄荷绿 / ✗ 关 灰） ──
	_shake_btn = _add_toggle_row("ShakeToggleButton", "震屏", 532.0, _on_shake_toggle)
	_dmg_btn = _add_toggle_row("DamageNumbersToggleButton", "伤害数字", 606.0, _on_dmg_toggle)
	# ── 构筑面板位置（R196：右上/右下/左下三档循环——HUD 经 settings_changed 即时重挂） ──
	_pos_btn = _add_toggle_row("PanelPosButton", "构筑面板位置", 680.0, _on_panel_pos_cycle)
	# ── 重置武器图鉴（R196 自救动作——非设置项：清 codex_weapons + codex_first_met 的
	#    W_ 前缀键，零 settings 键零存档段改动；老档测试期图鉴满档残留的唯一自救路径，
	#    行模式复用 _add_toggle_row 先例） ──
	_codex_reset_btn = _add_toggle_row("CodexResetButton", "重置武器图鉴", 754.0, _on_codex_reset)

	var hint := Label.new()
	StickerTheme.label_sticker(hint, 13, PopPalette.INK_SOFT)
	hint.text = "设置即存 · 立即生效（特效质量=跳字/粒子/元素特效总量）\n卡顿时优先调低特效质量；特效透明度 30%~100% 仅观感减淡"
	hint.position = Vector2(0.0, 824.0)
	hint.size = Vector2(620.0, 44.0)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card.add_child(hint)

	var close_btn := Button.new()
	close_btn.name = "SettingsCloseButton"
	close_btn.text = "返 回"
	close_btn.add_theme_font_size_override("font_size", 22)
	close_btn.add_theme_font_override("font", StickerTheme.font_bold())
	close_btn.position = Vector2(190.0, 872.0)
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


func _make_sticker_slider(p_pos: Vector2, p_fill: Color, p_min: float = 0.0) -> HSlider:
	# HSlider 贴纸化：圆角描边槽 + 同色填充段 + 圆珠 grabber（TextureFactory.bead）；
	# R194 加 p_min 可选参（音量默认 0.0 不变；特效透明度传 0.3——max/step 仍 1.0/0.05）
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
	slider.min_value = p_min
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


func _on_fx_opacity_changed(p_value: float) -> void:
	# R194 特效透明度写口（写即存，GameLoop 单源应用器经 settings_changed 实时减淡）；
	# "N%" 口径同音量行；仅观感旋钮——无提帧暗示（提帧走特效质量档）
	if _syncing:
		return                                   # open 回填触发 → 只刷 UI 不写盘
	Meta.set_setting("fx_opacity", p_value)
	_fxo_value.text = "%d%%" % roundi(clampf(p_value, 0.3, 1.0) * 100.0)


func _on_fps_cap_cycle() -> void:
	# R194 帧率上限循环：60 → 90 → 120 → 不限(0) → 60……写即存，Meta/移动端侧订阅
	# settings_changed("fps_cap") 即时重应用；非循环值（如手改 144）一轮归位 60
	var cur := clampi(int(Meta.settings("fps_cap")), 0, 144)
	var order: Array[int] = [60, 90, 120, 0]
	var idx := order.find(cur)
	Meta.set_setting("fps_cap", order[(idx + 1) % order.size()] if idx >= 0 else 60)
	_refresh_toggles()


func _on_shake_toggle() -> void:
	Meta.set_setting("shake_on", not bool(Meta.settings("shake_on")))
	_refresh_toggles()


func _on_dmg_toggle() -> void:
	Meta.set_setting("damage_numbers_on", not bool(Meta.settings("damage_numbers_on")))
	_refresh_toggles()


func _on_fx_quality_cycle() -> void:
	# 三档循环：高(2) → 中(1) → 低(0) → 高……写即存，消费端下一帧生效
	var q := clampi(int(Meta.settings("fx_quality")), 0, 2)
	Meta.set_setting("fx_quality", (q + 2) % 3)
	_refresh_toggles()


func _on_panel_pos_cycle() -> void:
	# R196 构筑面板位置循环：右上(0) → 右下(1) → 左下(2) → 右上……写即存，HUD 经
	# settings_changed("panel_pos") 即时重挂；越档值（脏档）一轮归位右上
	var cur := clampi(int(Meta.settings("panel_pos")), 0, 2)
	Meta.set_setting("panel_pos", (cur + 1) % 3)
	_refresh_toggles()


func _on_codex_reset() -> void:
	# R196 自救动作（老档测试期武器图鉴满档残留清洗）：Meta.reset_weapon_codex 单源——
	# 只清 codex_weapons + codex_first_met 的 W_ 前缀键（零 settings 键、存档段结构
	# 不动、achievements_done 不碰）。按钮文案即时反馈，面板重开复位（_sync_from_meta）。
	# R196 评审修复：与高频试点的「构筑面板位置」行仅隔 74px 且按钮同视觉语言——
	# 一次点击即不可逆清空代价过高。二段式确认：首点进入确认态（按钮文案变确认
	# 问句 + 3s 无操作自动解除，SceneTreeTimer 弱引用不持久化）；再点才执行。
	if not _codex_reset_armed:
		_codex_reset_armed = true
		_codex_reset_btn.text = "确认清空？"
		_codex_reset_btn.add_theme_color_override("font_color", PopPalette.GOLD)
		_codex_reset_btn.get_tree().create_timer(3.0).timeout.connect(
			_disarm_codex_reset)
		return
	_disarm_codex_reset()
	var cleared := Meta.reset_weapon_codex()
	if cleared > 0:
		_codex_reset_btn.text = "已清空 %d" % cleared
	else:
		_codex_reset_btn.text = "图鉴本已空"
	_codex_reset_btn.add_theme_color_override("font_color", PopPalette.SUCCESS)


func _disarm_codex_reset() -> void:
	# 确认态解除（3s 超时 / 执行后）：按钮回「重置」待命态
	_codex_reset_armed = false
	if _codex_reset_btn != null and is_instance_valid(_codex_reset_btn):
		_codex_reset_btn.text = "重置"
		_codex_reset_btn.remove_theme_color_override("font_color")


# ── 回填/刷新 ─────────────────────────────────────────────────────
func _sync_from_meta() -> void:
	# 打开时回填当前值（守卫位防回填触发 value_changed 二次写盘）
	_syncing = true
	_sfx_slider.value = float(Meta.settings("sfx_volume"))
	_bgm_slider.value = float(Meta.settings("bgm_volume"))
	_fxo_slider.value = clampf(float(Meta.settings("fx_opacity")), 0.3, 1.0)   # R194 回填（守卫内不写盘）
	_syncing = false
	_sfx_value.text = "%d%%" % roundi(float(Meta.settings("sfx_volume")) * 100.0)
	_bgm_value.text = "%d%%" % roundi(float(Meta.settings("bgm_volume")) * 100.0)
	_fxo_value.text = "%d%%" % roundi(clampf(float(Meta.settings("fx_opacity")), 0.3, 1.0) * 100.0)
	# R196：重置动作行反馈复位（动作非设置项——每次打开回「重置」态；
	# R196 评审：一并解除二次确认臂，防跨开关残留确认态）
	_codex_reset_armed = false
	_codex_reset_btn.text = "重置"
	_codex_reset_btn.remove_theme_color_override("font_color")
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
	# 特效质量三档文案（高=全量 / 中=减半 / 低=精简——卡顿救）
	var q := clampi(int(Meta.settings("fx_quality")), 0, 2)
	var fx_texts: Array[String] = ["✗ 低", "◐ 中", "✓ 高"]
	var fx_colors: Array[Color] = [PopPalette.INK_SOFT, PopPalette.XP, PopPalette.SUCCESS]
	_fx_btn.text = fx_texts[q]
	_fx_btn.add_theme_color_override("font_color", fx_colors[q])
	# R194 帧率上限循环文案（60/90/120/不限；0=不限——仅移动端应用，桌面基准不变）
	var cap := clampi(int(Meta.settings("fps_cap")), 0, 144)
	_fps_btn.text = "✓ 不限" if cap == 0 else "✓ %d" % cap
	_fps_btn.add_theme_color_override("font_color", PopPalette.SUCCESS)
	# R196 构筑面板位置循环文案（◉ 右上/右下/左下——HUD 三档锚/offset 落位）
	var pos := clampi(int(Meta.settings("panel_pos")), 0, 2)
	var pos_texts: Array[String] = ["◉ 右上", "◉ 右下", "◉ 左下"]
	_pos_btn.text = pos_texts[pos]
	_pos_btn.add_theme_color_override("font_color", PopPalette.SUCCESS)

# scripts/ui/settings_panel.gd
# P3 设置页（META_ROADMAP §5.10「设置页：音量/震屏开关」）：贴纸风全屏独立面板。
# 三滑条（音效/音乐音量 + R194 特效透明度 0.3~1.0 观感旋钮，HSlider 贴纸化：圆珠
# grabber + 圆角描边槽）+ 循环/开关行（特效质量 R19 三档 / R194 帧率上限 60-90-120-不限
# / R220 优先模式 帧率-特效 / 震屏 / 伤害数字 / R202 显示帧率 / R212 记录日志开关
# + 日志长度 60-120-240-360 档
# / R196 构筑面板位置 右上-右下-左下 / R196 重置武器图鉴
# 动作行——非 settings 键，Meta.reset_weapon_codex 单源，Button 触发，✓/✗ 态样式）。入口两处（大厅按钮行 + 暂停卡
# 「设置」按钮），GameLoop 接线 open()；纯 UI 层——写口统一走 Meta.set_setting
#（写即存），音量经 Meta.settings_changed → SfxBank 实时应用，特效透明度/帧率经
# 同信号由 GameLoop/Meta 侧订阅应用，震屏/跳字在消费入口短路；关闭只隐藏本层
#（恢复原界面，菜单/暂停卡不受扰）。
class_name SettingsPanel
extends CanvasLayer

signal closed()                                # R252D P6：设置面板作用域批落盘收口——close()
                                               # 时发射，GameLoop 接线 → Meta.end_persist_defer()
                                               # 统一落盘（open 侧由 settings_requested 回调包
                                               # begin；滑条 14 步拖动 = 1 次写盘）

var _root: Control = null
var _card: Panel = null
var _sfx_slider: HSlider = null
var _bgm_slider: HSlider = null
var _fxo_slider: HSlider = null               # R194 特效透明度（0.3~1.0，观感减淡非提帧手段）
var _sfx_value: Label = null
var _bgm_value: Label = null
var _fxo_value: Label = null                  # R194 透明度百分比（口径同音量 "N%"）
var _mute_btn: Button = null                  # R230 二cb：静音药丸（master_mute 总静音，音效音量行内）
var _shake_btn: Button = null
var _dmg_btn: Button = null
var _show_fps_btn: Button = null                # R202 显示帧率开关（show_fps，HUD 右缘小字读数）
var _fx_btn: Button = null                    # 特效质量三档循环（R19：高/中/低）
var _fps_btn: Button = null                   # R194 帧率上限循环（60/90/120/不限，移动端 Engine.max_fps）
var _perf_mode_btn: Button = null             # R220 优先模式循环（0=帧率优先/1=特效优先——PerfGovernor 模式源）
var _boost_btn: Button = null                 # R269：保帧模式三态循环行（关→开85→开75→关——perf_boost/boost_res 双键）
var _pos_btn: Button = null                   # R196 构筑面板位置循环（右上/右下/左下，HUD 消费 panel_pos）
var _diag_log_btn: Button = null              # R212：诊断日志采样开关（diag_log——原主菜单底带按钮迁入）
var _diag_len_btn: Button = null              # R212：日志长度档位循环（diag_log_len 60/120/240/360 行）
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
	# R270 修P1（评审高）：降档画布（保帧活战态 612×1088/540×960）下全高卡适配——
	# 卡 620×968 中锚非对称（−350/+618 底重）→ 围绕画布中心缩放（卡内定点=(310,350)
	# 常量——中锚偏移量即局部坐标），fit=min(1, 画布宽/620, 画布高/1236)（1236=2×618
	# 底半限制：底 ≤ 画布高 ⇔ 618·k ≤ H/2）。720×1280 域 fit=1.0 逐位不变（桌面默认/
	# 菜单域零扰动）。返回钮是本面板唯一关闭口（无 Esc/点外路径），随卡缩放完整入画
	# ——75% 档不修则整颗出屏=玩家被困面板。
	# 画布真源=window.content_scale_size（应用器同一写点；get_visible_rect() 宽度不跟
	# content_scale_size（实测返回基宽 720）——勿用）。
	var css: Vector2i = get_window().content_scale_size
	var fit := minf(1.0, minf(float(css.x) / 620.0, float(css.y) / 1236.0))
	_card.scale = Vector2(fit, fit)
	StickerTheme.squash_pop(_card, 0.0, Vector2(fit, fit))
	_card.pivot_offset = Vector2(310.0, 350.0)   # 画布中心（squash_pop 设卡中心 pivot 后覆写——缩放/果冻均绕画布中心）


func close() -> void:
	# 关闭：恢复原界面（下方菜单/暂停卡本就可见，只隐藏本层）
	_root.visible = false
	closed.emit()         # R252D P6：面板作用域结束 → GameLoop 侧 end_persist_defer 落盘


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
	# R202 再并入「显示帧率」开关行（show_fps，HUD 右缘小字读数）：卡已顶满（abs 底
	# 1258/1280 仅余 22px）禁扩卡高——缩行距塞入：滑条行 92→84（106/198/290→100/184/268）、
	# 开关行 74→66（384..754 六行→362..758 七行），hint 824 / 关闭钮 872 原位不动，
	# offset_bottom 618 不动（卡高 968 保持；末行按钮底 816 与 hint 824 留 8px 缝）
	# R212 再并入「记录日志」+「日志长度」两行（主菜单底带采样开关迁入设置页）：卡仍
	# 顶满禁扩——开关行距 66→52、钮高 58→48（九行 354..770，末行钮底 818 与 hint 824
	# 留 6px 缝）；滑条三行原位不动
	# R220 再并入「优先模式」一行（帧率优先/特效优先——PerfGovernor 调速器模式源，插在
	# 「帧率上限」行后）：卡仍顶满禁扩（abs 底 1258/1280 仅余 22px）——照 R202 先例缩行
	# 距塞入：开关行距 52→46、钮高 48→44（44=R194 触控目标下限），十行 354..768，末行
	# 钮底 768+44=812 与 hint 顶 824 留 12px 缝；hint/关闭钮/卡高 968 原位不动
	# R269 再并入「保帧模式」一行（perf_boost 三态——插在「优先模式」行后）：卡仍顶满
	# 禁扩——两段压缩塞入（r202 S④-S⑦ 布局法条保持：hint 824/关闭钮 872/末行底 ≤824/
	# 行零重叠）：滑条行距 84→76（92/168/244 + 滑条 128/204/280），开关行距 46→44
	#（首行 330 起、十一行 330..770，末行钮底 770+44=814 ≤824 留 10px 缝；44 钮高触控
	# 下限保持、44 行距=按钮贴排零重叠）
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

	# ── 音效音量（滑条 + 百分比；R194 重排 106 起，R202 行距 92→84 缩至 100，R269 84→76 缩至 92） ──
	_sfx_value = _add_volume_row("SfxVolumeLabel", "音效音量", 92.0)
	_sfx_slider = _make_sticker_slider(Vector2(40.0, 128.0), PopPalette.PLAYER)
	_sfx_slider.value_changed.connect(_on_sfx_volume_changed)
	_card.add_child(_sfx_slider)

	# ── R230 二cb：静音药丸（音效音量行中段空档 330-460——master_mute 总静音，正交于
	#    两滑条；卡满禁增行故复用行内空位，130×38 避开右缘百分比（480 起）与下滑条（128）──
	_mute_btn = Button.new()
	_mute_btn.name = "MuteButton"
	_mute_btn.add_theme_font_size_override("font_size", 18)
	_mute_btn.add_theme_font_override("font", StickerTheme.font_bold())
	for state in ["normal", "hover", "pressed", "disabled"]:
		var msb: StyleBoxFlat = (StickerTheme.button_style(state) as StyleBoxFlat).duplicate()
		msb.content_margin_top -= 4.0
		msb.content_margin_bottom -= 4.0
		_mute_btn.add_theme_stylebox_override(state, msb)
	_mute_btn.position = Vector2(330.0, 87.0)
	_mute_btn.size = Vector2(130.0, 38.0)
	_mute_btn.pivot_offset = _mute_btn.size * 0.5
	_mute_btn.focus_mode = Control.FOCUS_NONE
	_mute_btn.pressed.connect(_on_mute_toggle)
	_mute_btn.button_down.connect(func() -> void: StickerTheme.press_punch(_mute_btn))
	_card.add_child(_mute_btn)
	# 构建即设初值（完整态刷在 _sync_from_meta→_refresh_toggles——open 路径；此处防
	# 首开前空文案）
	var _mm0 := bool(Meta.settings("master_mute"))
	_mute_btn.text = "已静音" if _mm0 else "静 音"
	_mute_btn.add_theme_color_override("font_color",
		PopPalette.INK_SOFT if _mm0 else PopPalette.INK)

	# ── 音乐音量（滑条 + 百分比；R269 行距 84→76：184→168 / 220→204） ──
	_bgm_value = _add_volume_row("BgmVolumeLabel", "音乐音量", 168.0)
	_bgm_slider = _make_sticker_slider(Vector2(40.0, 204.0), PopPalette.SUCCESS)
	_bgm_slider.value_changed.connect(_on_bgm_volume_changed)
	_card.add_child(_bgm_slider)

	# ── 特效透明度（R194：0.3~1.0 观感旋钮——乘 modulate.a 减淡，非提帧手段；
	# 提帧唯一杠杆是上方特效质量档；R269 行距 84→76：268→244 / 304→280） ──
	_fxo_value = _add_volume_row("FxOpacityLabel", "特效透明度", 244.0)
	_fxo_slider = _make_sticker_slider(Vector2(40.0, 280.0), PopPalette.XP, 0.3)
	_fxo_slider.value_changed.connect(_on_fx_opacity_changed)
	_card.add_child(_fxo_slider)

	# ── 特效质量（R19：高/中/低三档循环——buff 叠多层卡顿救；R220 行距 52→46 自 354 起，
	#    R269 46→44 自 330 起） ──
	_fx_btn = _add_toggle_row("FxQualityButton", "特效质量", 330.0, _on_fx_quality_cycle)
	# ── 帧率上限（R194：60/90/120/不限 循环；仅移动端应用 Engine.max_fps，桌面基准不变。
	#    R293 刀C 核实：本行即「帧率帽解锁」终态——四档（60/90/120/无帽=0）+Meta 存档
	#    +默认 60 均为 R194 既有交付，接线原样保持；桌面/headless 零写是关侧承重墙） ──
	_fps_btn = _add_toggle_row("FpsCapButton", "帧率上限", 374.0, _on_fps_cap_cycle)
	# ── 优先模式（R220：帧率优先/特效优先 两态循环——PerfGovernor 升降档阈值与刀12-14
	#    数值面的模式源；写即存 + frame_priority() 每读直查 → 立即生效） ──
	_perf_mode_btn = _add_toggle_row("PerfModeButton", "优先模式", 418.0, _on_perf_mode_cycle)
	# ── R269：保帧模式（perf_boost 三态循环 关→开·画质85%→开·画质75%→关——分辨率两档
	#    +五帽+fx 钉 0 的用户显式开关；mobile 垫值默认开。cycle 写双键 §3.1 写口关系） ──
	_boost_btn = _add_toggle_row("BoostModeButton", "保帧模式", 462.0, _on_boost_cycle)
	# ── 开关行：震屏 / 伤害数字 / 显示帧率（✓ 开 薄荷绿 / ✗ 关 灰） ──
	_shake_btn = _add_toggle_row("ShakeToggleButton", "震屏", 506.0, _on_shake_toggle)
	_dmg_btn = _add_toggle_row("DamageNumbersToggleButton", "伤害数字", 550.0, _on_dmg_toggle)
	_show_fps_btn = _add_toggle_row("ShowFpsToggleButton", "显示帧率", 594.0, _on_show_fps_toggle)
	# ── R212：记录日志开关（原主菜单底带第三枚按钮迁入——设置页大厅+暂停卡双入口，
	#    局中局外均可达；菜单按钮只在 _ready 构建一次，迁移后不再有过期 ✓/✗ 态问题） ──
	_diag_log_btn = _add_toggle_row("DiagLogToggleButton", "记录日志", 638.0, _on_diag_log_toggle)
	# ── R212：日志长度循环（60/120/240/360 行，默认 240——环形缓冲只留最新 N 条，
	#    缩容由 DebugStats._diag_push 首笔重整裁旧） ──
	_diag_len_btn = _add_toggle_row("DiagLenButton", "日志长度", 682.0, _on_diag_len_cycle)
	# ── 构筑面板位置（R196：右上/右下/左下三档循环——HUD 经 settings_changed 即时重挂） ──
	_pos_btn = _add_toggle_row("PanelPosButton", "构筑面板位置", 726.0, _on_panel_pos_cycle)
	# ── 重置武器图鉴（R196 自救动作——非设置项：清 codex_weapons + codex_first_met 的
	#    W_ 前缀键，零 settings 键零存档段改动；老档测试期图鉴满档残留的唯一自救路径，
	#    行模式复用 _add_toggle_row 先例） ──
	_codex_reset_btn = _add_toggle_row("CodexResetButton", "重置武器图鉴", 770.0, _on_codex_reset)

	var hint := Label.new()
	# R269 修2（评审中#2）：补保帧模式白话（开 85% 后死亡爆闪/状态特效/敌密度代价零
	# 披露——行文案只说「画质85%」的知情缺口）。R269 修6（QA-R269-D2）：四行@11 实测
	# 行单元 17.25px（字高15+行距3）→ 块高 69 底 893，第四行整条落入关闭钮带 872..940
	# （QA 探针实测定级 P2）——改三行合并（四条披露零删除：R194 两句拆至行1/行3 尾，
	# contains 锁子串逐字保持）+ line_separation 压 0（3×15=45 → 文本底 869 ≤872）。
	StickerTheme.label_sticker(hint, 11, PopPalette.INK_SOFT)
	hint.add_theme_constant_override("line_spacing", 0)   # 修6：行距 3→0（项名 line_spacing——card_select_ui:406 同主题读法；11px 字高 15px 自带沉余可读）
	hint.text = "设置即存 · 立即生效（特效质量=跳字/粒子/元素特效总量；卡顿时优先调低特效质量）\n优先模式：帧率优先=卡时自动压特效/弹幕/跳字密度保帧，特效优先=保持表现\n保帧模式：优先帧率，画面略糊、部分特效隐藏；特效透明度 30%~100% 仅观感减淡"
	hint.position = Vector2(0.0, 824.0)
	hint.size = Vector2(620.0, 45.0)
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
	# R212：钮高 58→48（九行行距 52 塞卡不扩高）；R220：钮高 48→44、行距 52→46（十行
	# 46 塞卡不扩高——46>44 行间留 2px 缝不重叠；44 仍 = R194 触控目标下限）、标签纵偏
	# +9→+7（30 高标签在 44 钮内垂直居中）
	var name_l := Label.new()
	StickerTheme.label_sticker(name_l, 20, PopPalette.INK, 0, Color.WHITE, true)
	name_l.text = p_text
	name_l.position = Vector2(40.0, p_y + 7.0)
	name_l.size = Vector2(300.0, 30.0)
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(name_l)
	var btn := Button.new()
	btn.name = p_btn_name
	btn.add_theme_font_size_override("font_size", 19)
	btn.add_theme_font_override("font", StickerTheme.font_bold())
	# R220 紧凑钮：贴纸按钮主题 content_margin 10+12 使 min 高 ≈48（19pt 行高 ~26+22），
	# 44 高会被 min 钳回 48——四态样式盒行内复刻仅收纵向边距（各 −2，视觉差不可辨），
	# min 高 ≈44 恰达 R194 触控目标下限；全局 StickerTheme 零改动（本面板局部 override）
	for state in ["normal", "hover", "pressed", "disabled"]:
		var sb: StyleBoxFlat = (StickerTheme.button_style(state) as StyleBoxFlat).duplicate()
		sb.content_margin_top -= 2.0
		sb.content_margin_bottom -= 2.0
		btn.add_theme_stylebox_override(state, sb)
	btn.position = Vector2(440.0, p_y)
	btn.size = Vector2(140.0, 44.0)
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


func _on_mute_toggle() -> void:
	# R230 二cb：总静音开关（照 _on_shake_toggle 先例——写即存 + _refresh_toggles 刷态；
	# SfxBank 经 settings_changed("master_mute") 即时全播放器 -60dB/恢复滑条音量）
	Meta.set_setting("master_mute", not bool(Meta.settings("master_mute")))
	_refresh_toggles()


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
	# settings_changed("fps_cap") 即时重应用；非循环值（如手改 144）一轮归位 60。
	# R220 修轮补注：本键同时是 PerfGovernor 调速器目标读口——target=min(上限,120,
	# 屏幕刷新率)：上限只是帽，vsync/面板达不到不会触发降档（帽语义修正，perf_governor
	# _target_fps 同口径）。
	# R293 刀C 核实：本写口+Meta._on_settings_changed→_apply_fps_cap 即「切档即时生效」
	# 既有接线（启动读取=Meta._ready 同函数）——mobile 门内应用，桌面/headless 零写。
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


func _on_show_fps_toggle() -> void:
	# R202：帧率显示开关（照 _on_shake_toggle 先例——Meta 写即存 + 即时刷 ✓/✗ 态；
	# HUD 侧经 settings_changed("show_fps") 即时切 FpsLabel visible。与「帧率上限」行
	# 正交：fps_cap 是 mobile 门内 Engine.max_fps 帽，本键纯显示互不依赖）
	Meta.set_setting("show_fps", not bool(Meta.settings("show_fps")))
	_refresh_toggles()


func _on_diag_log_toggle() -> void:
	# R212：诊断日志采样开关（原 menu_screen 底带第三枚按钮迁入本行——照
	# _on_show_fps_toggle 先例：Meta 写即存 + 即时刷 ✓/✗ 态；DebugStats._diag_maybe_sample
	# 每帧读口，纯轮询门无需 settings_changed 订阅）
	Meta.set_setting("diag_log", not bool(Meta.settings("diag_log")))
	_refresh_toggles()


func _on_diag_len_cycle() -> void:
	# R212：日志长度循环：60 → 120 → 240 → 360 → 60……写即存；非档值（脏档连续值，
	# 如手改 333）一轮归位 240（fps_cap「find 不到归位」同口径）；缩容由
	# DebugStats._diag_push 首笔重整裁旧——只留最新 N 条
	var cur := clampi(int(Meta.settings("diag_log_len")), 60, 360)
	var order: Array[int] = [60, 120, 240, 360]
	var idx := order.find(cur)
	Meta.set_setting("diag_log_len", order[(idx + 1) % order.size()] if idx >= 0 else 240)
	_refresh_toggles()


func _on_fx_quality_cycle() -> void:
	# 三档循环：高(2) → 中(1) → 低(0) → 高……写即存，消费端下一帧生效
	var q := clampi(int(Meta.settings("fx_quality")), 0, 2)
	Meta.set_setting("fx_quality", (q + 2) % 3)
	_refresh_toggles()


func _on_perf_mode_cycle() -> void:
	# R220 优先模式两态循环：帧率优先(0) ↔ 特效优先(1)。写即存（照 _on_fx_quality_cycle
	# 先例）；立即生效=PerfGovernor.frame_priority() 每读直查 settings（零订阅零滞后），
	# 调速器侧转换计时在其 _process 模式观测口清零重累计（tier/EMA 保持）
	var cur := clampi(int(Meta.settings("perf_mode")), 0, 1)
	Meta.set_setting("perf_mode", 1 - cur)
	_refresh_toggles()


func _on_boost_cycle() -> void:
	# R269：保帧模式三态循环 关 → 开·画质85% → 开·画质75% → 关（§3.1 写口关系写死，
	# 防显示态与 促%d 不一致）：85 档=写 perf_boost 1+boost_res 85；75 档=写 perf_boost 1+
	# boost_res 75；关=仅写 perf_boost 0（boost_res 保留当前值不回写，重开沿用）。
	# 热切应用=GameLoop 经 settings_changed 即时 _apply_boost_resolution（订阅接线）。
	# 写口读 settings 真值非 boost_override 注入态（注入口仅测试用，不进用户写路径）。
	var on := int(Meta.settings("perf_boost")) == 1
	var res75 := int(Meta.settings("boost_res")) == 75
	# R269 修4（评审低#4）：写序先 boost_res 后 perf_boost——关(存75)→85% 时首写落在
	# 关态（应用器 no-op），perf_boost 1 才触发唯一一次 content_scale_size 重分配
	#（原序先 perf_boost 1 会先误应用 75 档再覆盖 85 档=同帧两连写；Android GLES3
	# 运行期改 content_scale_size 是 §3.2 点名 P0 风险操作，白做一次）。
	if not on:
		Meta.set_setting("boost_res", 85)
		Meta.set_setting("perf_boost", 1)
	elif not res75:
		Meta.set_setting("boost_res", 75)
		Meta.set_setting("perf_boost", 1)
	else:
		Meta.set_setting("perf_boost", 0)
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
	# R230 二cb：静音药丸态（未静音=墨「静 音」/已静音=灰「已静音」——开关语义直读）
	var mm := bool(Meta.settings("master_mute"))
	if _mute_btn != null:
		_mute_btn.text = "已静音" if mm else "静 音"
		_mute_btn.add_theme_color_override("font_color",
			PopPalette.INK_SOFT if mm else PopPalette.INK)
	var on := bool(Meta.settings("shake_on"))
	_shake_btn.text = "✓ 开" if on else "✗ 关"
	_shake_btn.add_theme_color_override("font_color",
		PopPalette.SUCCESS if on else PopPalette.INK_SOFT)
	var dmg_on := bool(Meta.settings("damage_numbers_on"))
	_dmg_btn.text = "✓ 开" if dmg_on else "✗ 关"
	_dmg_btn.add_theme_color_override("font_color",
		PopPalette.SUCCESS if dmg_on else PopPalette.INK_SOFT)
	# R202：帧率显示开关态（✓/✗ 同震屏/伤害数字口径）
	var fps_show_on := bool(Meta.settings("show_fps"))
	_show_fps_btn.text = "✓ 开" if fps_show_on else "✗ 关"
	_show_fps_btn.add_theme_color_override("font_color",
		PopPalette.SUCCESS if fps_show_on else PopPalette.INK_SOFT)
	# R212：记录日志开关态（✓/✗ 同口径——原主菜单底带按钮迁入）
	var diag_on := bool(Meta.settings("diag_log"))
	_diag_log_btn.text = "✓ 开" if diag_on else "✗ 关"
	_diag_log_btn.add_theme_color_override("font_color",
		PopPalette.SUCCESS if diag_on else PopPalette.INK_SOFT)
	# R212：日志长度档文案（60/120/240/360 行——环形只留最新 N 条；脏档连续值显示
	# clamp 后实值，cycle 一轮归位 240）
	var dlen := clampi(int(Meta.settings("diag_log_len")), 60, 360)
	_diag_len_btn.text = "✓ %d 行" % dlen
	_diag_len_btn.add_theme_color_override("font_color", PopPalette.SUCCESS)
	# 特效质量三档文案（高=全量 / 中=减半 / 低=精简——卡顿救）
	var q := clampi(int(Meta.settings("fx_quality")), 0, 2)
	var fx_texts: Array[String] = ["✗ 低", "◐ 中", "✓ 高"]
	var fx_colors: Array[Color] = [PopPalette.INK_SOFT, PopPalette.XP, PopPalette.SUCCESS]
	_fx_btn.text = fx_texts[q]
	_fx_btn.add_theme_color_override("font_color", fx_colors[q])
	# R194 帧率上限循环文案（60/90/120/不限；0=不限——仅移动端应用，桌面基准不变）
	# R293 修轮 1 体验披露：切档仅解锁 Engine.max_fps 帽——物理模拟恒 60Hz、插值层门
	# =sim30_effective() 且 SIM_30HZ_ENABLED=false → 90/120 档=60Hz 模拟交替重复帧非
	# 顺滑、60Hz 屏+vsync 下 fps 读数不变（零反馈=已知口径非失效，全文见诊断导出
	# 口径头 R293 段；插值门与 30Hz 解耦/物理提频 90Hz=第二批必做决策，本刀不实施）
	var cap := clampi(int(Meta.settings("fps_cap")), 0, 144)
	_fps_btn.text = "✓ 不限" if cap == 0 else "✓ %d" % cap
	_fps_btn.add_theme_color_override("font_color", PopPalette.SUCCESS)
	# R220 优先模式文案（帧率优先=调速器积极降档保帧 / 特效优先=保画面宽松档——
	# PerfGovernor.frame_priority() 直读本键，写口下一读即翻转）
	var pm := clampi(int(Meta.settings("perf_mode")), 0, 1)
	_perf_mode_btn.text = "✓ 帧率优先" if pm == 0 else "◉ 特效优先"
	_perf_mode_btn.add_theme_color_override("font_color",
		PopPalette.SUCCESS if pm == 0 else PopPalette.XP)
	# R269：保帧模式三态文案（促%d 同源——PerfGovernor.boost_diag_state 单源纯函数，
	# 诊断行与设置行同源防不一致；分辨率档明示「画质」观感代价，§3.2 用户预先接受）
	var bst := PerfGovernor.boost_diag_state()
	var boost_texts: Array[String] = ["✗ 关", "✓ 画质85%", "✓ 画质75%"]
	var boost_colors: Array[Color] = [PopPalette.INK_SOFT, PopPalette.SUCCESS, PopPalette.SUCCESS]
	_boost_btn.text = boost_texts[bst]
	_boost_btn.add_theme_color_override("font_color", boost_colors[bst])
	# R196 构筑面板位置循环文案（◉ 右上/右下/左下——HUD 三档锚/offset 落位）
	var pos := clampi(int(Meta.settings("panel_pos")), 0, 2)
	var pos_texts: Array[String] = ["◉ 右上", "◉ 右下", "◉ 左下"]
	_pos_btn.text = pos_texts[pos]
	_pos_btn.add_theme_color_override("font_color", PopPalette.SUCCESS)

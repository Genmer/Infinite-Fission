# scripts/ui/sublime_confirm_ui.gd
# R245 需求① 红卡（个人技能升华）大屏确认卡：选了红色 buff（rarity 4 SUBLIME）后，
# 大屏告知「技能升级前后效果对比」+ 单「确认」钮，确认后才继续战斗（确认前战斗停住
# ——弹出期状态保持 LEVEL_UP、tree.paused=true 持续、零模拟成本、BGM 战斗曲不掐，
# 本 UI 以 PROCESS_MODE_ALWAYS 照常响应）。红卡 apply 即生效（本局语义，幂等），
# 大屏是效果告知+确认继续，不是效果选择。
# 骨架照抄 pause_overlay.gd：ALWAYS + SafeAreaHelper 三行接入 + 全屏 PopPalette.DIM
# 压暗 + 白卡 StickerTheme.panel_style(24,4,true) + squash_pop 果冻出场 +
# 按钮 focus_mode=FOCUS_NONE（真机异形屏/手柄焦点不抢）。
# 卡面文案零新设计：全部读 CharacterTable.get_character(cid)（与选卡卡面同源同表，
# 不复制字符串——card_generator.gd 卡面 compose 同表）。
# 弹出规则（设计 §1.5 裁定）：每批必弹、每批至多一次（注入点每批只掷一次）、
# 同局不去重（enable_sublime 幂等；0.001% 爆率下大屏是「传说时刻」仪式感）。
class_name SublimeConfirmUI
extends CanvasLayer

signal confirmed()                              # → GameLoop._finish_card_choice()（红卡门收口）

const FOOTER_TEXT := "本局有效 · 爆率 0.001% · 确认后继续战斗"

var _root: Control = null
var _card: Panel = null
var _title: Label = null
var _cur_name: Label = null
var _cur_desc: Label = null
var _sub_name: Label = null
var _sub_desc: Label = null
var _confirm_btn: Button = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_root.visible = false
	# R195 适配：安全区接入（pause_overlay 同款三行——守卫外 insets 恒零=零扰动）
	_apply_safe_area()
	if SafeAreaHelper.enabled(get_window()):
		_apply_safe_area_deferred()
	SafeAreaHelper.bind_reread(get_window(), _apply_safe_area)
	# 防御收口：LEVEL_UP 之外的任何态迁移（死亡优先级/测试拆树）→ 大屏即收
	EventBus.state_changed.connect(_on_state_changed)


func _apply_safe_area() -> void:
	# R195 安全区应用（消费式契约=SafeAreaHelper.insets 注释；仅事件驱动非每帧路径）
	var ins := SafeAreaHelper.insets(get_window())
	_root.offset_left = ins.position.x
	_root.offset_top = ins.position.y
	_root.offset_right = -ins.size.x
	_root.offset_bottom = -ins.size.y


func _apply_safe_area_deferred() -> void:
	await SafeAreaHelper.read_deferred(get_window())
	_apply_safe_area()


func is_open() -> bool:
	# 测试/挂机观测口（鸭子口——game_loop 挂机自动确认臂与 test_r245_sublime_gate 同源）
	return _root != null and _root.visible


func open(p_character_id: StringName) -> void:
	# 开卡（GameLoop 红卡门唯一入口）：按角色读表刷新两栏文案 + 果冻出场。
	# 幂等：重复 open 只刷内容（弹出规则「每批至多一次」由 game_loop 门保证，UI 侧不设防）
	var entry: Dictionary = CharacterTable.get_character(p_character_id)
	_title.text = "技能升华 · 传说"
	_cur_name.text = String(entry.get("skill_name", "技能"))
	_cur_desc.text = String(entry.get("skill_desc", ""))
	_sub_name.text = String(entry.get("sublime_name", "技能强化"))
	_sub_desc.text = String(entry.get("sublime_desc", ""))
	_root.visible = true
	StickerTheme.squash_pop(_card)


func close() -> void:
	# 收卡（confirm 路径与防御收口共用；幂等）
	if _root != null:
		_root.visible = false


func confirm() -> void:
	# 确认收口：手动按钮 / 挂机自动臂（game_loop._tick_auto_idle AUTO_SUBLIME_WINDOW_S
	# 倒计时到点）同一入口——先收卡再发信号（收口链 _finish_card_choice 内若续开选卡
	# 回 LEVEL_UP，本卡已收不挡新窗）。重复调用幂等（is_open 假直接返）。
	if not is_open():
		return
	close()
	confirmed.emit()


func _on_confirm_pressed() -> void:
	confirm()


func _unhandled_input(p_event: InputEvent) -> void:
	# 键盘/手柄确认通道：Enter/空格（ui_accept）与手柄 A（ui_select）即确认——按钮
	# FOCUS_NONE 不抢焦点也不吃键，此通道与按钮/挂机自动臂同一 confirm() 入口（幂等；
	# LEVEL_UP 期 tree.paused 下 ALWAYS 件照常收输入）。
	if is_open() and (p_event.is_action_pressed("ui_accept") or p_event.is_action_pressed("ui_select")):
		confirm()
		get_viewport().set_input_as_handled()


func _on_state_changed(p_state: int) -> void:
	# 防御：确认收口链外的任何态迁移（E-16 死亡优先级等）→ 大屏即收（confirmed 不发
	# ——非玩家确认语义；game_loop 侧状态机自会走对应收口）
	if p_state != GameConst.GameStatus.LEVEL_UP:
		close()


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "SublimeRoot"
	_root.theme = StickerTheme.theme()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# 全屏压暗（藏青半透——战斗画面隐约可见，与暂停/选卡同观感）
	var dim := ColorRect.new()
	dim.name = "SublimeDim"
	dim.color = PopPalette.DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)

	# 白卡（贴纸面板：圆角 24 + 藏青描边 + 底部厚投影；整体居中锚 560×760 → ±280/±380）
	_card = Panel.new()
	_card.name = "SublimeCard"
	_card.add_theme_stylebox_override("panel", StickerTheme.panel_style(24.0, 4, true))
	_card.anchor_left = 0.5
	_card.anchor_right = 0.5
	_card.anchor_top = 0.5
	_card.anchor_bottom = 0.5
	_card.offset_left = -280.0
	_card.offset_right = 280.0
	_card.offset_top = -380.0
	_card.offset_bottom = 380.0
	_card.pivot_offset = _card.size * 0.5
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_card)

	# 红顶带（红档描边色=PopPalette.rarity_color(4) #ff2e63——「传说」档的视觉锚）
	var band := ColorRect.new()
	band.name = "RarityBand"
	band.color = PopPalette.rarity_color(4)
	band.position = Vector2(20.0, 20.0)
	band.size = Vector2(520.0, 10.0)
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(band)

	_title = Label.new()
	StickerTheme.label_sticker(_title, 36, PopPalette.rarity_color(4), 0, Color.WHITE, true)
	_title.text = "技能升华 · 传说"
	_title.position = Vector2(0.0, 48.0)
	_title.size = Vector2(560.0, 44.0)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card.add_child(_title)

	# 左右两栏（当前 → 升华 前后对比）：同高双子卡，各 名(粗) + 描述(自动换行)
	_cur_name = _make_col_panel(Vector2(24.0, 112.0), "当前", PopPalette.INK, 0)
	_cur_desc = _col_desc_label(_cur_name.get_parent())
	_sub_name = _make_col_panel(Vector2(292.0, 112.0), "升华", PopPalette.rarity_color(4), 1)
	_sub_desc = _col_desc_label(_sub_name.get_parent())

	var footer := Label.new()
	StickerTheme.label_sticker(footer, 15, PopPalette.INK_SOFT)
	footer.text = FOOTER_TEXT
	footer.position = Vector2(0.0, 646.0)
	footer.size = Vector2(560.0, 20.0)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card.add_child(footer)

	# 单「确认」钮（FOCUS_NONE：真机异形屏/手柄焦点不抢——设计 §6.4-1）
	_confirm_btn = Button.new()
	_confirm_btn.name = "SublimeConfirmButton"
	_confirm_btn.text = "确认"
	_confirm_btn.add_theme_font_size_override("font_size", 24)
	_confirm_btn.add_theme_font_override("font", StickerTheme.font_bold())
	_confirm_btn.position = Vector2(180.0, 672.0)
	_confirm_btn.size = Vector2(200.0, 72.0)
	_confirm_btn.pivot_offset = _confirm_btn.size * 0.5
	_confirm_btn.focus_mode = Control.FOCUS_NONE
	_confirm_btn.pressed.connect(_on_confirm_pressed)
	_confirm_btn.button_down.connect(func() -> void: StickerTheme.press_punch(_confirm_btn))
	_card.add_child(_confirm_btn)


func _make_col_panel(p_pos: Vector2, p_caption: String, p_accent: Color, p_which: int) -> Label:
	# 双栏共用：浅底子卡 + 顶角标（当前/升华）+ 名行；返回名 Label（描述行挂同父子卡）
	var col := Panel.new()
	col.name = "Col%d" % p_which
	col.add_theme_stylebox_override("panel", StickerTheme.panel_style(12.0, 3, false))
	col.position = p_pos
	col.size = Vector2(244.0, 512.0)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(col)
	var caption := Label.new()
	StickerTheme.label_sticker(caption, 14, p_accent, 0, Color.WHITE, true)
	caption.text = "「%s」" % p_caption
	caption.position = Vector2(12.0, 10.0)
	caption.size = Vector2(220.0, 18.0)
	col.add_child(caption)
	var name_label := Label.new()
	StickerTheme.label_sticker(name_label, 20, PopPalette.INK, 0, Color.WHITE, true)
	name_label.position = Vector2(12.0, 36.0)
	name_label.size = Vector2(220.0, 26.0)
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(name_label)
	return name_label


func _col_desc_label(p_col: Node) -> Label:
	# 描述行（挂同栏子卡；自动换行——升华描述最长 ~110 字）
	var desc := Label.new()
	StickerTheme.label_sticker(desc, 15, PopPalette.INK_SOFT)
	desc.position = Vector2(12.0, 68.0)
	desc.size = Vector2(220.0, 428.0)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	(p_col as Node).add_child(desc)
	return desc

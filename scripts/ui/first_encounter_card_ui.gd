# scripts/ui/first_encounter_card_ui.gd
# R251 需求③ 首遇卡片系统：新机制/新武器/新敌人第一次出现 → 统一介绍卡（替换既有
# 分散 toast 横幅——敌人首遇/武器上架/反应首触三域同一张卡面孔）。
# 骨架照 SublimeConfirmUI 先例裁剪：CanvasLayer + SafeAreaHelper 三行接入 + bind_reread
# + 白卡 StickerTheme.panel_style + squash_pop 果冻出场 + FOCUS_NONE（无按钮不设防）。
# 非阻塞纪律（设计 §3.3）：不 pause、不改 GameStatus（LEVEL_UP 态机矩阵零改动）；
# PROCESS_MODE 默认 INHERIT——LEVEL_UP 暂停期计时不推进，队列不丢、恢复续播。
# 队列：FIFO 逐张展示、同一时刻至多 1 张；单张 4.5s 自动消散（process delta 计时），
# 点击/触摸任意处立即关闭；两卡间 0.25s 间隔；队列上限 4 溢出丢最旧（新档首局最坏
# ≈ 首发武器 1 + 开场敌 2~3 种，不会轰炸）。
# 文案纪律：title/body 全由发点按 GameConst 表组装（本 UI 零手抄机制字符串）；
# 图标按 p_kind 三域解析（敌=分型贴图 id 前缀轻副本 menu_screen.gd:1044 同款 /
# 武器=weapon_icon / 反应=recipe 双色环 PopPalette 单源取色），零新贴图。
class_name FirstEncounterCardUI
extends CanvasLayer

const CARD_LIFE_S := 4.5                        # 单张自动消散时长（设计 §3.3）
const CARD_GAP_S := 0.25                        # 两卡间隔
const QUEUE_CAP := 4                            # 等待队列上限（溢出丢最旧）
const CARD_SIZE := Vector2(520.0, 96.0)         # 横条卡尺寸（R253 下移后避让顶带+Boss 战带）
const CARD_TOP_Y := 260.0                       # R253 卡区顶 y（原 10 压 HUD 顶带读数组——QA丙-1；
                                               # 评审 M1 二次让位：188 仍撞 Boss 战带——TargetBar
                                               # 让位 y190-216 + 降临横幅 y210-256（Boss 首遇卡恰在
                                               # 出场瞬间弹出，盖血条+横幅 4.5s）；260 起 4px 缝）

var _root: Control = null
var _card: Panel = null
var _icon_rect: TextureRect = null
var _icon_rect2: TextureRect = null            # 反应域双色环第二元（敌/武器域隐藏）
var _title_l: Label = null
var _body_l: Label = null
var _queue: Array[Dictionary] = []             # 等待卡 {title, body, kind, id}
var _showing := false                          # 当前有卡在屏
var _life := 0.0                               # 当前卡已展示时长
var _gap := 0.0                                # 距下一张的剩余间隔


func _ready() -> void:
	layer = 50                                    # 高于 HUD/选卡窗（默认 1——顶部横条永不被弹窗压住）
	# QA B-1（设计 §3.3 兑现）：显式 PAUSABLE——父链 GameLoop 是 PROCESS_MODE_ALWAYS
	#（game_loop.gd:214），默认 INHERIT 会被传导为 ALWAYS，LEVEL_UP/PAUSED（两者同置
	# tree.paused）期间 4.5s 计时照走、队列照排干、_unhandled_input 照吞点击——升级
	# 选卡长考期间首遇卡烧完消失。PAUSABLE 一处改动：暂停期 _process 与 _unhandled_input
	# 同时冻结、恢复续播、队列不丢（test_r251_first_encounter C 暂停回归锚覆盖）。
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_build_ui()
	_root.visible = false
	# R195 适配：安全区接入（SublimeConfirmUI 同款三行——守卫外 insets 恒零=零扰动）
	_apply_safe_area()
	if SafeAreaHelper.enabled(get_window()):
		_apply_safe_area_deferred()
	SafeAreaHelper.bind_reread(get_window(), _apply_safe_area)
	# 自连事件（hud.gd:241 模式——UI 自管订阅，GameLoop 只挂载零接线）
	EventBus.first_encounter_card.connect(_on_first_encounter_card)


func is_open() -> bool:
	# 测试/挂机观测口（SublimeConfirmUI :58 先例）
	return _showing and _card != null and _card.visible


func pending_count() -> int:
	# 队列观测口（C7 断言「至多 1 张可见 + 队列上限」用）
	return _queue.size()


func _process(p_delta: float) -> void:
	# 单张计时消散 + 间隔放行（INHERIT：LEVEL_UP 暂停期本函数不跑——队列冻结不丢）
	if _showing:
		_life += p_delta
		if _life >= CARD_LIFE_S:
			_advance()
	elif _gap > 0.0:
		_gap -= p_delta
		if _gap <= 0.0 and not _queue.is_empty():
			_play_next()


func _unhandled_input(p_event: InputEvent) -> void:
	# 点击/触摸任意处立即关闭当前卡（队列按间隔续播——「第一次就行」读没读都让路）
	if not _showing:
		return
	var clicked := false
	if p_event is InputEventMouseButton and p_event.pressed \
			and p_event.button_index == MOUSE_BUTTON_LEFT:
		clicked = true
	elif p_event is InputEventScreenTouch and p_event.pressed:
		clicked = true
	if clicked:
		_advance()
		get_viewport().set_input_as_handled()


func _on_first_encounter_card(p_title: String, p_body: String, p_kind: StringName, p_id: StringName) -> void:
	# 入队（帽 4 溢出丢最旧）→ 空闲即播
	_queue.append({"title": p_title, "body": p_body, "kind": p_kind, "id": p_id})
	while _queue.size() > QUEUE_CAP:
		_queue.pop_front()
	if not _showing and _gap <= 0.0:
		_play_next()


func _play_next() -> void:
	# 取队首填卡出场（squash_pop 果冻；单卡复用同一 Panel——逐张重入不重建节点）
	if _queue.is_empty() or _card == null:
		return
	var entry: Dictionary = _queue.pop_front()
	_title_l.text = String(entry.get("title", ""))
	_body_l.text = String(entry.get("body", ""))
	_apply_icon(entry.get("kind") as StringName, entry.get("id") as StringName)
	_showing = true
	_life = 0.0
	_root.visible = true
	_card.visible = true
	StickerTheme.squash_pop(_card)


func _advance() -> void:
	# 收当前卡 → 间隔期（0.25s）→ _process 放行下一张
	_showing = false
	_life = 0.0
	_gap = CARD_GAP_S
	_card.visible = false
	if _queue.is_empty():
		_root.visible = false


func _apply_icon(p_kind: StringName, p_id: StringName) -> void:
	# 三域图标单源解析（零新贴图）：敌=分型贴图 64px / 武器=图标库 64px /
	# 反应=配方双色环并排（规格 §3.3「reaction_note.elements 双色环」——menu_screen
	# .gd:1164-1170 同款双 TextureRect 并排，取色同 PopPalette.ELEMENT_COLORS 单源）
	var note: Dictionary = {}
	var elems: Array = []
	if p_kind == &"reaction":
		note = GameConst.reaction_note(String(p_id))
		elems = note.get("elements", [])
	if p_kind == &"reaction" and elems.size() >= 2:
		_icon_rect.texture = _element_ring(int(elems[0]))
		_icon_rect2.texture = _element_ring(int(elems[1]))
		_icon_rect.position = Vector2(14.0, 32.0)
		_icon_rect.size = Vector2(32.0, 32.0)
		_icon_rect2.position = Vector2(50.0, 32.0)
		_icon_rect2.size = Vector2(32.0, 32.0)
		_icon_rect2.visible = true
	else:
		_icon_rect.texture = _icon_for(p_kind, p_id)
		_icon_rect.position = Vector2(16.0, 16.0)
		_icon_rect.size = Vector2(64.0, 64.0)
		_icon_rect2.visible = false


func _element_ring(p_elem: int) -> ImageTexture:
	var col: Color = PopPalette.ELEMENT_COLORS.get(p_elem, Color.WHITE)
	return TextureFactory.ring_tex(col, 32, 4.5)


func _icon_for(p_kind: StringName, p_id: StringName) -> ImageTexture:
	# 敌/武器域单图解析（反应域双环走 _apply_icon 直排）
	match p_kind:
		&"weapon":
			return TextureFactory.weapon_icon(p_id)
		_:
			return _enemy_icon_tex(p_id)


func _enemy_icon_tex(p_eid: StringName) -> ImageTexture:
	# 怪物 id 前缀 → 分型贴图（enemy.gd _visual_kind 同映射的菜单侧轻副本——
	# menu_screen.gd:1044 同款先例；多字符 id（E24/E25~E30）必须先于 E2/E3 短前缀——
	# begins_with 撞前缀，"E24_rift_demon".begins_with("E2")==true）
	var sid := String(p_eid)
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
	if sid.begins_with("E24"):
		return TextureFactory.enemy_tex(&"phase")
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


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "FirstEncounterRoot"
	_root.theme = StickerTheme.theme()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# 顶部横条白卡（水平居中；无 DIM 无按钮——非阻塞横幅卡）。R253 下移 y10→260：
	# 原顶部横条压 HUD 顶带读数组（QA丙-1：竖屏 720×1280 实测 PauseButton 全遮、HP 条
	# 遮 79%、XP/R187/复活全遮）；评审 M1 二次让位：188 仍撞 Boss 战带（TargetBar 让位
	# y190-216 + 降临横幅 y210-256）——260 起全让开（顶带+BossBar 带+Boss 战带），
	# 卡底 356 落敌区上沿空白带（玩家活动区 y≥768 不受扰）
	_card = Panel.new()
	_card.name = "FirstEncounterCard"
	_card.add_theme_stylebox_override("panel", StickerTheme.panel_style(18.0, 3, true))
	_card.anchor_left = 0.5
	_card.anchor_right = 0.5
	_card.offset_left = -CARD_SIZE.x * 0.5
	_card.offset_right = CARD_SIZE.x * 0.5
	_card.offset_top = CARD_TOP_Y
	_card.offset_bottom = CARD_TOP_Y + CARD_SIZE.y
	_card.pivot_offset = Vector2(CARD_SIZE.x * 0.5, CARD_SIZE.y * 0.5)
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.visible = false
	_root.add_child(_card)

	_icon_rect = TextureRect.new()
	_icon_rect.name = "CardIcon"
	_icon_rect.position = Vector2(16.0, 16.0)
	_icon_rect.custom_minimum_size = Vector2(64.0, 64.0)
	_icon_rect.size = Vector2(64.0, 64.0)
	_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(_icon_rect)

	# 反应域第二元环（§3.3 双色环规格；敌/武器域隐藏——menu_screen.gd:1164-1170 双环先例）
	_icon_rect2 = TextureRect.new()
	_icon_rect2.name = "CardIcon2"
	_icon_rect2.position = Vector2(50.0, 32.0)
	_icon_rect2.custom_minimum_size = Vector2(32.0, 32.0)
	_icon_rect2.size = Vector2(32.0, 32.0)
	_icon_rect2.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon_rect2.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon_rect2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon_rect2.visible = false
	_card.add_child(_icon_rect2)

	_title_l = StickerTheme.label_sticker(Label.new(), 17, PopPalette.INK, 0, Color.WHITE, true)
	_title_l.name = "CardTitle"
	_title_l.position = Vector2(96.0, 14.0)
	_title_l.size = Vector2(408.0, 26.0)
	_title_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(_title_l)

	_body_l = StickerTheme.label_sticker(Label.new(), 12, PopPalette.INK_SOFT)
	_body_l.name = "CardBody"
	_body_l.position = Vector2(96.0, 44.0)
	_body_l.size = Vector2(408.0, 44.0)
	_body_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(_body_l)


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

# scripts/ui/boss_bar.gd
# M-16 BossBar（架构 §1.4/§2.1 事件表）：Boss 血条——订阅 boss_spawned 登场 /
# enemy_killed（Boss 死亡）隐藏；每帧从 Boss 实例拉取 HP 比例。
# 方向 C：白圆角条 + 珊瑚填充 + Boss 小脸标 + 相位点 + 登场预警横幅（lore 文案）。
# process_mode = ALWAYS（暂停期间可见）。
class_name BossBar
extends CanvasLayer

var boss: Node2D = null                       # 当前 Boss 引用（boss_spawned 注入）

var _root: Control = null
var _fill: Panel = null                       # 填充（displayed_pct 口径：size.x / BAR_SIZE.x）
var _fill_style: StyleBoxFlat = null
var _frame: Panel = null                      # 描边框（叠在填充上方——中心镂空只画边）
var _name_label: Label = null
var _face_icon: TextureRect = null            # Boss 小脸标（分型贴图复用）
var _phase_dots: Array[TextureRect] = []      # 相位点（Boss 阶段 1/2）
var _banner: Label = null                     # 登场预警横幅
var _banner_left: float = 0.0                 # 横幅剩余展示（raw 通道）
var _last_phase: int = 0                      # 相位点脏检查（避免每帧换贴图）

const BAR_SIZE := Vector2(560.0, 18.0)
const BAR_POS := Vector2(80.0, 154.0)
const BANNER_TIME := 2.2                      # 预警横幅展示时长 s
const BANNER_FADE := 0.35                     # 末段淡出 s


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	EventBus.boss_spawned.connect(_on_boss_spawned)
	EventBus.enemy_killed.connect(_on_enemy_killed)
	EventBus.state_changed.connect(_on_state_changed)


func tick(p_raw_delta: float) -> void:
	# 每帧拉取 Boss HP 比例 + 相位点刷新 + 横幅衰减（⑧ UI 阶段，raw 通道）
	if boss == null or not is_instance_valid(boss):
		return
	var max_hp: float = boss.get("max_hp")
	var hp: float = boss.get("hp")
	var pct := 0.0 if max_hp <= 0.0 else clampf(hp / max_hp, 0.0, 1.0)
	_fill.size = Vector2(BAR_SIZE.x * pct, BAR_SIZE.y)
	_sync_phase(int(boss.get("boss_phase")))
	if _banner_left > 0.0:
		_banner_left = maxf(_banner_left - p_raw_delta, 0.0)
		if _banner_left <= 0.0:
			_banner.visible = false
		elif _banner_left < BANNER_FADE:
			_banner.modulate.a = _banner_left / BANNER_FADE


func displayed_pct() -> float:
	# 测试观测口
	if _fill == null or BAR_SIZE.x <= 0.0:
		return 0.0
	return _fill.size.x / BAR_SIZE.x


func is_visible_bar() -> bool:
	return _root.visible


func _on_boss_spawned(p_enemy: Node2D) -> void:
	# Boss 登场（HUD 血条/GameFeel——架构 §2.1 事件表）+ 预警横幅
	boss = p_enemy
	_name_label.text = str(p_enemy.get("data").get("display_name")) if p_enemy.get("data") != null else "BOSS"
	_root.visible = true
	_last_phase = -1
	tick(0.0)
	_show_banner(Lore.boss_warning(_name_label.text))


func _on_enemy_killed(p_enemy: Node2D) -> void:
	# Boss 死亡 → 隐藏
	if p_enemy == boss:
		boss = null
		_root.visible = false


func _on_state_changed(p_state: int) -> void:
	# 回 MENU/GAME_OVER 时收起（新一局由 boss_spawned 重新唤起）
	if p_state == GameConst.GameStatus.MENU or p_state == GameConst.GameStatus.GAME_OVER:
		boss = null
		_root.visible = false
		_banner.visible = false
		_banner_left = 0.0


# ── 程序化 UI 组装（方向 C 贴纸风） ────────────────────────────────
func _build_ui() -> void:
	_root = Control.new()
	_root.name = "BossBarRoot"
	_root.theme = StickerTheme.theme()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)

	# Boss 小脸标（聚合体贴图缩小复用）
	_face_icon = TextureRect.new()
	_face_icon.name = "BossFace"
	_face_icon.texture = TextureFactory.enemy_tex(&"boss")
	_face_icon.position = Vector2(20.0, 112.0)
	_face_icon.custom_minimum_size = Vector2(56.0, 56.0)
	_face_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_face_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_face_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_face_icon)

	# 名字（贴纸字：藏青字 + 白描边）
	_name_label = StickerTheme.label_sticker(Label.new(), 18, PopPalette.INK, 8, Color.WHITE, true)
	_name_label.name = "BossName"
	_name_label.text = "BOSS"
	_name_label.position = Vector2(84.0, 126.0)
	_root.add_child(_name_label)

	# 血条：填充在下、描边框叠上（displayed_pct 语义：fill.size.x = BAR_SIZE.x × pct）
	_fill = Panel.new()
	_fill.name = "Fill"
	_fill_style = StyleBoxFlat.new()
	_fill_style.bg_color = PopPalette.ENEMY
	_fill_style.set_corner_radius_all(9)
	_fill.add_theme_stylebox_override("panel", _fill_style)
	_fill.position = BAR_POS
	_fill.size = BAR_SIZE
	_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_fill)
	_frame = Panel.new()
	_frame.name = "Frame"
	var frame_style := StyleBoxFlat.new()
	frame_style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	frame_style.draw_center = false
	frame_style.border_color = PopPalette.OUTLINE
	frame_style.set_border_width_all(3)
	frame_style.set_corner_radius_all(11)
	_frame.add_theme_stylebox_override("panel", frame_style)
	_frame.position = BAR_POS
	_frame.size = BAR_SIZE
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_frame)

	# 相位点（阶段 1/2：空心 → 实心葡萄紫）
	for i in range(2):
		var dot := TextureRect.new()
		dot.name = "PhaseDot%d" % i
		dot.texture = TextureFactory.ring_tex(PopPalette.INK_SOFT, 28, 3.5)
		dot.position = Vector2(BAR_POS.x + BAR_SIZE.x - 72.0 + 26.0 * float(i), BAR_POS.y - 6.0)
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(dot)
		_phase_dots.append(dot)

	# 登场预警横幅（果冻 pop）
	_banner = StickerTheme.label_sticker(Label.new(), 34, PopPalette.ENEMY, 12, Color.WHITE, true)
	_banner.name = "BossBanner"
	_banner.text = ""
	_banner.size = Vector2(720.0, 46.0)
	_banner.position = Vector2(0.0, 336.0)
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.visible = false
	_root.add_child(_banner)


func _sync_phase(p_phase: int) -> void:
	# 相位点同步（脏检查：贴图切换仅发生在阶段跨越）
	if p_phase == _last_phase:
		return
	_last_phase = p_phase
	for i in range(_phase_dots.size()):
		var filled := p_phase >= i + 2        # 阶段 2 → 第 1 点亮，预留阶段 3
		_phase_dots[i].texture = TextureFactory.bead(PopPalette.SHOCK, 28, false) if filled \
			else TextureFactory.ring_tex(PopPalette.INK_SOFT, 28, 3.5)


func _show_banner(p_text: String) -> void:
	# 预警横幅：果冻 squash & stretch（重要 UI 元素全局动效口径）
	_banner.text = p_text
	_banner.visible = true
	_banner.modulate.a = 1.0
	_banner_left = BANNER_TIME
	StickerTheme.squash_pop(_banner)

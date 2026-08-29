# scripts/ui/boss_bar.gd
# M-16 BossBar（架构 §1.4/§2.1 事件表）：Boss 血条——订阅 boss_spawned 登场 /
# enemy_killed（Boss 死亡）隐藏；每帧从 Boss 实例拉取 HP 比例。
# 方向 A 重做：警报条纹头（UV 滚动）+ 红渐变血条 + 相位刻度（50%）+ Boss 死亡签名瞬间
# （冲击波 + 全屏白闪 → BossDeathFX，纯表现层：不碰 time_scale/hit_stop 数值）。
# process_mode = ALWAYS（暂停期间可见）。
class_name BossBar
extends CanvasLayer

var boss: Node2D = null                       # 当前 Boss 引用（boss_spawned 注入）

var _root: Control = null
var _fill: TextureProgressBar = null          # 红渐变填充
var _name_label: Label = null
var _stripes: TextureRect = null              # 警报条纹（滚动）
var _death_fx: BossDeathFX = null             # 签名瞬间层（子 CanvasLayer）

const BAR_SIZE := Vector2(560.0, 16.0)
const LAYER_ORDER := 12


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = LAYER_ORDER
	_build_ui()
	EventBus.boss_spawned.connect(_on_boss_spawned)
	EventBus.enemy_killed.connect(_on_enemy_killed)
	EventBus.state_changed.connect(_on_state_changed)


func tick(_p_raw_delta: float) -> void:
	# 每帧拉取 Boss HP 比例（⑧ UI 阶段，raw 通道）
	if boss == null or not is_instance_valid(boss):
		return
	var max_hp: float = boss.get("max_hp")
	var hp: float = boss.get("hp")
	var pct := 0.0 if max_hp <= 0.0 else clampf(hp / max_hp, 0.0, 1.0)
	_fill.value = pct * 100.0


func displayed_pct() -> float:
	# 测试观测口
	if _fill == null:
		return 0.0
	return _fill.value / 100.0


func is_visible_bar() -> bool:
	return _root.visible


func _on_boss_spawned(p_enemy: Node2D) -> void:
	# Boss 登场（HUD 血条/GameFeel——架构 §2.1 事件表）
	boss = p_enemy
	_name_label.text = str(p_enemy.get("data").get("display_name")) if p_enemy.get("data") != null else "BOSS"
	_root.visible = true
	tick(0.0)


func _on_enemy_killed(p_enemy: Node2D) -> void:
	# Boss 死亡 → 签名瞬间（引用相等判定不受死亡归还清零影响）+ 隐藏
	if p_enemy == boss:
		if _death_fx != null and p_enemy != null and is_instance_valid(p_enemy):
			_death_fx.burst(p_enemy.global_position)
		boss = null
		_root.visible = false


func _on_state_changed(p_state: int) -> void:
	# 回 MENU/GAME_OVER 时收起（新一局由 boss_spawned 重新唤起）
	if p_state == GameConst.GameStatus.MENU or p_state == GameConst.GameStatus.GAME_OVER:
		boss = null
		_root.visible = false


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "BossBarRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	UITheme.apply_theme(_root)
	add_child(_root)
	# 签名瞬间层（子层——Boss 死亡冲击波 + 全屏白闪）
	_death_fx = BossDeathFX.new()
	_death_fx.name = "BossDeathFX"
	add_child(_death_fx)
	# Boss 名（加重 + 红色警戒 + 深描边——Boss 名再大一档）
	_name_label = UITheme.make_label("BOSS", 22, Palette.RED)
	_name_label.name = "BossName"
	_name_label.add_theme_font_override("font", UITheme.font_title())
	_name_label.position = Vector2(80.0, 112.0)
	_name_label.size = Vector2(560.0, 26.0)
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_name_label)
	# 血条玻璃框 + 红渐变填充 + 相位刻度（50%）
	var frame := UITheme.make_glass_panel(Palette.RED)
	frame.name = "BarFrame"
	frame.position = Vector2(78.0, 142.0)
	frame.size = BAR_SIZE + Vector2(4.0, 4.0)
	_root.add_child(frame)
	var bar := TextureProgressBar.new()
	bar.name = "Bar"
	bar.nine_patch_stretch = true
	bar.texture_under = TextureFactory.white_px()
	bar.tint_under = Color(0.10, 0.05, 0.08, 0.95)
	bar.texture_progress = TextureFactory.hp_low_gradient()
	bar.fill_mode = TextureProgressBar.FILL_LEFT_TO_RIGHT
	bar.min_value = 0.0
	bar.max_value = 100.0
	bar.value = 100.0
	bar.position = Vector2(80.0, 144.0)
	bar.size = BAR_SIZE
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bar)
	_fill = bar
	# 相位刻度（阶段 2 @50%——暗色竖线贴在填充上层）
	for x in [0.5]:
		var tick_mark := ColorRect.new()
		tick_mark.name = "PhaseTick"
		tick_mark.color = Color(0.05, 0.02, 0.04, 0.85)
		tick_mark.position = Vector2(80.0 + BAR_SIZE.x * x, 142.0)
		tick_mark.size = Vector2(2.0, BAR_SIZE.y + 4.0)
		tick_mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(tick_mark)
	# 警报条纹头（滚动红黑斜纹——血条上缘 4px）
	_stripes = TextureRect.new()
	_stripes.name = "AlertStripes"
	_stripes.texture = TextureFactory.stripes()
	_stripes.material = _stripes_material()
	_stripes.position = Vector2(80.0, 136.0)
	_stripes.size = Vector2(BAR_SIZE.x, 6.0)
	_stripes.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_stripes)


static func _stripes_material() -> ShaderMaterial:
	# 警报条纹滚动（fract 包络 UV——不依赖纹理 repeat 标志）
	var shader := Shader.new()
	shader.code = "\
shader_type canvas_item;\n\
uniform float speed : hint_range(0.0, 4.0) = 0.6;\n\
uniform sampler2D stripe_tex : source_color, filter_nearest;\n\
void fragment() {\n\
\tvec2 uv = fract(UV + vec2(TIME * speed, 0.0));\n\
\tCOLOR = texture(stripe_tex, uv) * COLOR;\n\
}\n"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter(&"stripe_tex", TextureFactory.stripes())
	return mat

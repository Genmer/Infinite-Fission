# scripts/gamefeel/game_feel_director.gd
# M-15 GameFeelDirector（架构 §2.14）：顿帧/震屏/色差/粒子总调度。
# 事件驱动（无独立 gamefeel 事件）：订阅 damage_resolved / enemy_killed / reaction_triggered /
# player_hit 四个既有事件（B_spec §3.1 M-15 契约），按 GameConst.FeelLevel 分级：
#   HIT(0)=0ms / CRIT(1)=30ms / CATALYST(2)=50ms / BOSS_DEATH(3)=120ms（hit_stop_ms 档位）
#   trauma：0.15 / 0.4 / 0.5 / 1.0（shake_trauma 档位）；色差 base_intensity × ca_level_mult。
# 顿帧申请唯一出口 request_hit_stop() → GameLoop 每帧拉 desired_time_scale()——
# 本类绝不写 Engine.time_scale / GameLoop.time_scale（§8.7 冻结契约，AC-15.1）。
# tick 走 raw 通道（顿帧期间 trauma/色差照常衰减，Q-14）。
class_name GameFeelDirector
extends Node

var feel_config: GameFeelConfig = null        # M-14 注入
var shake: CameraShake = null
var particles: ParticleDirector = null
var hit_stop_left: float = 0.0                # 顿帧剩余（raw 通道计时，s）
var hit_stop_active_ms: float = 0.0           # 当前激活时长（合并比较基准）
var merge_window: float = 0.03                # 30ms 内多触发取最大不叠加（AC-15.2）
var chromatic_rect: ColorRect = null          # 全屏色差 ColorRect（程序化 shader 占位）

var current_ca_intensity: float = 0.0         # 当前色差强度（遥测/测试观测）
var _ca_peak: float = 0.0                     # 本段色差峰值（线性衰减基准）
var _ca_left: float = 0.0                     # 色差剩余（raw 通道，s）
var _raw_elapsed: float = 0.0                 # raw 通道累计时钟（合并窗口判据）
var _last_request_ms: float = -1000.0         # 上次顿帧申请时刻（ms，raw 通道）

var _chromatic_material: ShaderMaterial = null

# 粒子场景 id（池模板统一 burst emitter；场景 id 仅作 meta 遥测键）
const EMITTER_SCENE_ID := &"burst_default"


func setup(p_deps: Dictionary) -> void:
	# 注入 config / particle_pool / 后处理宿主（CameraShake 内部构造）
	feel_config = p_deps.get("config")
	particles = p_deps.get("particles")
	shake = CameraShake.new()
	var max_px := 8.0
	var max_rot := 1.5
	var decay := 0.4
	if feel_config != null:
		max_px = feel_config.shake_max_offset_px
		max_rot = feel_config.shake_max_rot_deg
		decay = feel_config.shake_decay_s
		merge_window = float(feel_config.hit_stop_merge_ms) / 1000.0
	shake.setup(max_px, max_rot, decay)
	_setup_chromatic_rect(p_deps.get("chromatic_host"))
	# 事件订阅（仅 Node 派生类可订阅，E-12；本类 extends Node ✓）
	EventBus.damage_resolved.connect(on_damage_resolved)
	EventBus.enemy_killed.connect(on_enemy_killed)
	EventBus.reaction_triggered.connect(on_reaction_triggered)
	EventBus.player_hit.connect(on_player_hit)


func on_damage_resolved(p_result: DamageResult) -> void:
	# feel_level 分级入口（0/30/50ms 顿帧 + trauma + 色差；粒子按 CRIT/HIT 优先级）
	var level := p_result.feel_level
	var stop_ms := _hit_stop_ms_for(level)
	if stop_ms > 0.0:
		request_hit_stop(stop_ms)
	add_trauma_for_level(level)
	_apply_chromatic(_ca_intensity_for(level))
	if particles != null:
		var pri := ParticleDirector.PRIORITY_HIT
		if p_result.is_crit:
			pri = ParticleDirector.PRIORITY_CRIT
		particles.burst(EMITTER_SCENE_ID, p_result.pos, pri)


func on_enemy_killed(p_enemy: Node2D) -> void:
	# Boss 死亡 → 120ms 顿帧 + trauma 1.0（BOSS_DEATH 档）；普通击杀 → KILL 优先级粒子
	var tags := int(p_enemy.get("tags")) if p_enemy != null else 0
	if (tags & GameConst.TAG_BOSS) != 0:
		request_hit_stop(_hit_stop_ms_for(GameConst.FeelLevel.BOSS_DEATH))
		add_trauma_for_level(GameConst.FeelLevel.BOSS_DEATH)
		_apply_chromatic(_ca_intensity_for(GameConst.FeelLevel.BOSS_DEATH))
	if particles != null:
		var pos := p_enemy.global_position if p_enemy != null else Vector2.ZERO
		particles.burst(EMITTER_SCENE_ID, pos, ParticleDirector.PRIORITY_KILL)


func on_reaction_triggered(_p_rxn: int, p_pos: Vector2, _p_target_uid: int) -> void:
	# 质变级：50ms + trauma 0.4 + 色差（CATALYST 档）
	request_hit_stop(_hit_stop_ms_for(GameConst.FeelLevel.CATALYST))
	add_trauma_for_level(GameConst.FeelLevel.CATALYST)
	_apply_chromatic(_ca_intensity_for(GameConst.FeelLevel.CATALYST))
	if particles != null:
		particles.burst(EMITTER_SCENE_ID, p_pos, ParticleDirector.PRIORITY_CRIT)


func on_player_hit(_p_damage: float, _p_source_uid: int) -> void:
	# 玩家受击 → trauma 0.15（HIT 档；无顿帧）。签名对齐 EventBus.player_hit(damage, source_uid)
	# 双参信号（集成包修复：单参签名在信号派发时报 Method expected 1 arguments 错误刷屏）。
	add_trauma_for_level(GameConst.FeelLevel.HIT)


func request_hit_stop(p_duration_ms: float) -> void:
	# 向 GameLoop 申请（唯一出口，不直写 time_scale）。
	# 合并语义（AC-15.2）：激活中 / 合并窗口内再触发 → 取最大不叠加（maxf 剩余时长）。
	var ms := maxf(p_duration_ms, 0.0)
	if ms <= 0.0:
		return
	hit_stop_left = maxf(hit_stop_left, ms / 1000.0)
	hit_stop_active_ms = maxf(hit_stop_active_ms, ms)
	_last_request_ms = _raw_elapsed * 1000.0


func tick(p_raw_delta: float) -> void:
	# raw 通道：顿帧剩余衰减 / trauma 衰减 / 色差线性归零（顿帧期间表现层照常，Q-14）
	_raw_elapsed += p_raw_delta
	if hit_stop_left > 0.0:
		hit_stop_left = maxf(hit_stop_left - p_raw_delta, 0.0)
		if hit_stop_left <= 0.0:
			hit_stop_active_ms = 0.0
	if shake != null:
		shake.tick(p_raw_delta)
	if _ca_left > 0.0:
		_ca_left = maxf(_ca_left - p_raw_delta, 0.0)
		current_ca_intensity = _ca_peak * (_ca_left / _ca_decay_s_safe())
		if _ca_left <= 0.0:
			current_ca_intensity = 0.0
			_ca_peak = 0.0
	_push_chromatic_uniform()


func desired_time_scale() -> float:
	# 返回 hit_stop_scale（顿帧激活中，默认 0.05）或 1.0 —— GameLoop 每帧拉取
	if hit_stop_left > 0.0 and feel_config != null:
		return feel_config.hit_stop_scale
	return 1.0


func add_trauma_for_level(p_level: int) -> void:
	# 按档位叠加 trauma（shake_trauma[p_level]，clamp 由 CameraShake 承担）
	if shake == null or feel_config == null:
		return
	var idx := clampi(p_level, 0, feel_config.shake_trauma.size() - 1)
	shake.add(feel_config.shake_trauma[idx])


# ── 内部 ──────────────────────────────────────────────────────────
func _hit_stop_ms_for(p_level: int) -> float:
	# 顿帧档位（hit_stop_ms[FeelLevel]，真源 data/gamefeel/game_feel_config.tres）
	if feel_config == null:
		return 0.0
	var idx := clampi(p_level, 0, feel_config.hit_stop_ms.size() - 1)
	return float(feel_config.hit_stop_ms[idx])


func _ca_intensity_for(p_level: int) -> float:
	# 色差强度：base × level_mult（0.004 起跳分级放大，AC-15.4）
	if feel_config == null:
		return 0.0
	var idx := clampi(p_level, 0, feel_config.ca_level_mult.size() - 1)
	return feel_config.ca_base_intensity * feel_config.ca_level_mult[idx]


func _apply_chromatic(p_intensity: float) -> void:
	# 触发色差段（同档更强覆盖；剩余时长重置为本段衰减窗口）
	if p_intensity <= 0.0 or feel_config == null:
		return
	if p_intensity >= _ca_peak:
		_ca_peak = p_intensity
	_ca_left = feel_config.ca_decay_s
	current_ca_intensity = _ca_peak * (_ca_left / _ca_decay_s_safe())


func _ca_decay_s_safe() -> float:
	return feel_config.ca_decay_s if feel_config != null else 0.15


func _push_chromatic_uniform() -> void:
	# shader uniform 同步 + 零强度隐藏（无开销路径）
	if chromatic_rect == null:
		return
	var enabled := feel_config == null or feel_config.ca_enabled
	chromatic_rect.visible = enabled and current_ca_intensity > 0.0001
	if _chromatic_material != null:
		_chromatic_material.set_shader_parameter(&"intensity", current_ca_intensity)


func _setup_chromatic_rect(p_host: Node) -> void:
	# 程序化色差后处理占位：全屏 ColorRect + hint_screen_texture shader（无外部资源文件）
	chromatic_rect = ColorRect.new()
	chromatic_rect.name = "ChromaticAberration"
	chromatic_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chromatic_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	chromatic_rect.color = Color.WHITE
	chromatic_rect.visible = false
	var shader := Shader.new()
	shader.code = "\
shader_type canvas_item;\n\
uniform float intensity : hint_range(0.0, 0.1) = 0.0;\n\
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;\n\
void fragment() {\n\
\tvec2 dir = SCREEN_UV - vec2(0.5);\n\
\tvec2 off = dir * intensity;\n\
\tfloat r = texture(screen_tex, SCREEN_UV + off).r;\n\
\tfloat g = texture(screen_tex, SCREEN_UV).g;\n\
\tfloat b = texture(screen_tex, SCREEN_UV - off).b;\n\
\tCOLOR = vec4(r, g, b, 1.0);\n\
}\n"
	_chromatic_material = ShaderMaterial.new()
	_chromatic_material.shader = shader
	chromatic_rect.material = _chromatic_material
	if p_host != null:
		p_host.add_child(chromatic_rect)

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

# ── R188 档2 表现收口（fx_quality 档内开关；档位数值/缺省 fx_quality=2 不动） ──
const CA_QUALITY_INTENSITY := [0.0, 0.5, 1.0]  # 色差强度档乘数：低档关 / 中档半强 / 高档保持
const CA_QUALITY_WINDOW := [1.0, 0.5, 1.0]     # 色差衰减窗口档缩放：中档缩窗（衰减更快）
const CRIT_STOP_DENSE_WINDOW := 1.0            # CRIT 顿帧密集场判定窗口 s（raw 通道时钟）
const CRIT_STOP_DENSE_LIMIT := 6               # 窗口内 CRIT 顿帧申请达限 → 自动关（密集场近连续顿帧）
const CRIT_STOP_DENSE_ENEMY_MIN := 40          # R189c：密集场敌数门（§4.4「敌 >N 自动关」——非密集战顿帧保留）

var _crit_stop_times: Array[float] = []        # CRIT 顿帧申请时刻滚动窗（raw elapsed；密集场判据）

# ── R229 粒子满载门收口（CRIT/KILL/反应爆闪三路三重门减薄） ──────────
# R228 绘制谱实锤：深载带（敌120 驻场、tier≤2）CRIT/击杀/反应爆闪流把 64 发射器
# 池打满 = 64 独立 dc 地板（GPUParticles2D 逐发射器独立 multimesh 绘制 + GPU 填充）。
# R213 满载门只盖非 CRIT 普命中；CRIT 仅吃 mobile 中档 1/2 隔次；KILL/反应路径完全
# 无门。本刀三路接入同判据三重门（R223 _settle_cap_now 哨兵同款）：
#   mobile ∧ 帧率优先 ∧ tier≤2 —— 门开时 CRIT 1/4 独立采样 / 普通 KILL 1/4、
#   精英 KILL 1/2、Boss tag 全保留（死亡低频大反馈）/ 反应 1/2。
# tier3/特效优先/桌面/headless 恒关 = 零扰动；顿帧/震屏/色差/跳字在粒子前施加，
# 零触碰；particles.burst 调用点之后的 dropped_requests 遥测（particle_director）
# 不动。R226 口径：本门是性能保险丝不是成长帽，-2 为用户否决档（可否决披露）。
static var burst_thin_override: int = -1       # -1=真值自动门 / -2=强制关（用户否决档）/
                                               # -3=模拟 mobile（跳过 OS 检查直入 tier 分支，
                                               # headless 可测）/ 1=强制开
var _crit_thin_tick: int = 0                   # 三重门 CRIT 1/4 采样计数器（R229）
var _kill_thin_tick: int = 0                   # 三重门 KILL 爆闪采样计数器（普通/精英共用，
                                               # 模按敌类取 4/2——任意连续 8 窗内通过数确定）
var _rxn_thin_tick: int = 0                    # 三重门反应 1/2 采样计数器（R229）


static func _burst_thin_on() -> bool:
	# 三重门判定（R223 哨兵形状）：-3 模拟真机门=跳过 OS.has_feature("mobile")
	# 直入 tier 分支（tier_override 注入即生效）——自动门真机语义与测试口径共用同一
	# 条映射分支；真值路径 = mobile ∧ 帧率优先 ∧ tier≤2。
	if burst_thin_override == -2:
		return false
	if burst_thin_override == 1:
		return true
	if burst_thin_override != -3 and not OS.has_feature("mobile"):
		return false
	if not PerfGovernor.frame_priority():
		return false
	return PerfGovernor.effective_tier() <= 2


func _ready() -> void:
	add_to_group(&"game_feel")                  # R74：复活演出等跨系统查找口


func early_bind() -> void:
	# ★ enemy_killed 前置订阅（连接序 = 派发序，审查 Fix 2）：Boss 击杀打击感读取
	#   enemy.tags 必须先于 EnemySpawner 死亡归还清零（tags=0）——GameLoop 在 spawner
	#   入树/连接之前调用本方法；其余事件订阅仍在 setup（其派发序无 tags 读取依赖）
	EventBus.enemy_killed.connect(on_enemy_killed)


func setup(p_deps: Dictionary) -> void:
	# 注入 config / particle_pool / 后处理宿主（CameraShake 内部构造）。
	# enemy_killed 订阅已拆出至 early_bind（Boot 期提前连接，见上）
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
	EventBus.reaction_triggered.connect(on_reaction_triggered)
	EventBus.player_hit.connect(on_player_hit)


var _thin_burst_tick: int = 0                 # 中档隔次粒子计数器（R19）


func on_damage_resolved(p_result: DamageResult) -> void:
	# feel_level 分级入口（0/30/50ms 顿帧 + trauma + 色差；粒子按 CRIT/HIT 优先级）。
	# R19 特效质量档位：低=仅暴击粒子 / 中=隔次粒子（高频命中减负——buff 叠多层卡顿主源之一）。
	# R188 档2：CRIT 顿帧密集场自动关（滚动窗内申请达限即停发——密集场 30ms 顿帧近连续
	# 拖慢游戏时钟；Boss/精英路径走 on_enemy_killed 直发不经此处，保留不受影响）
	var level := p_result.feel_level
	var stop_ms := _hit_stop_ms_for(level)
	if stop_ms > 0.0:
		if level == GameConst.FeelLevel.CRIT and _crit_stop_dense():
			DebugStats.count(&"crit_stop_dense_skipped")
		else:
			request_hit_stop(stop_ms)
	add_trauma_for_level(level)
	_apply_chromatic(_ca_intensity_for(level))
	if particles != null:
		# R213 B案：满载门——普命中碎屑粒子关（敌≥80 满载高频命中下发射器池软限 64
		# 恒满且每个独立 dc + GPU 填充；CRIT/击杀路径不走此处，反馈保留；顿帧/震屏/
		# 色差在门之前已施加不受影响；敌数回落自动恢复）
		if Enemy.fullload_dim() and not p_result.is_crit:
			return
		var q := clampi(int(Meta.settings("fx_quality")), 0, 2)
		# R204：mobile 门内高档降中档（命中粒子是每击都出的持续流——怪海×高频
		# 武器下发射器池软限 64 恒满，与敌状态件同口径减半）
		if OS.has_feature("mobile"):
			q = mini(q, 1)
		if q == 0 and not p_result.is_crit:
			return                              # 低档：普命中不出粒子
		# R229 满载门收口：门开时 CRIT 走独立 1/4 采样（在 mobile 中档 1/2 隔次基础上
		# 再收紧——深载 CRIT 流是发射器池饱和主源之一；非 CRIT 满载门/q 档语义逐位不动）
		if p_result.is_crit and _burst_thin_on():
			_crit_thin_tick += 1
			if _crit_thin_tick % 4 != 1:
				DebugStats.count(&"burst_thinned")
				return
		elif q == 1:
			_thin_burst_tick += 1
			if _thin_burst_tick % 2 == 1:
				return                          # 中档：隔次削减
		var pri := ParticleDirector.PRIORITY_HIT
		if p_result.is_crit:
			pri = ParticleDirector.PRIORITY_CRIT
		particles.burst(EMITTER_SCENE_ID, p_result.pos, pri)


func on_boss_death_feel() -> void:
	# R74 最高档感受（Boss 死亡/玩家复活共用）：120ms 顿帧 + trauma 1.0 + 色差
	request_hit_stop(_hit_stop_ms_for(GameConst.FeelLevel.BOSS_DEATH))
	add_trauma_for_level(GameConst.FeelLevel.BOSS_DEATH)
	_apply_chromatic(_ca_intensity_for(GameConst.FeelLevel.BOSS_DEATH))


func on_enemy_killed(p_enemy: Node2D) -> void:
	# Boss 死亡 → 120ms 顿帧 + trauma 1.0（BOSS_DEATH 档）；普通击杀 → KILL 优先级粒子
	var tags := int(p_enemy.get("tags")) if p_enemy.get("tags") != null else 0 if p_enemy != null else 0
	if (tags & GameConst.TAG_BOSS) != 0:
		on_boss_death_feel()
	elif (tags & GameConst.TAG_ELITE) != 0:
		# R19 打击质感：精英击杀 → CRIT 档顿帧 + 震屏（大怪击杀更有分量）
		request_hit_stop(_hit_stop_ms_for(GameConst.FeelLevel.CRIT))
		add_trauma_for_level(GameConst.FeelLevel.CRIT)
	if particles != null:
		var pos := p_enemy.global_position if p_enemy != null else Vector2.ZERO
		# R229 满载门收口：门开时 KILL 爆闪采样——普通敌 1/4 / 精英 1/2 / Boss tag
		# 全保留（Boss 死亡低频大反馈；on_boss_death_feel 顿帧/震屏路径零触碰）
		if _burst_thin_on() and (tags & GameConst.TAG_BOSS) == 0:
			_kill_thin_tick += 1
			var kill_mod := 4 if (tags & GameConst.TAG_ELITE) == 0 else 2
			if _kill_thin_tick % kill_mod != 1:
				DebugStats.count(&"burst_thinned")
				return
		particles.burst(EMITTER_SCENE_ID, pos, ParticleDirector.PRIORITY_KILL)


func on_reaction_triggered(_p_rxn: int, p_pos: Vector2, _p_target_uid: int) -> void:
	# 质变级：50ms + trauma 0.4 + 色差（CATALYST 档）
	request_hit_stop(_hit_stop_ms_for(GameConst.FeelLevel.CATALYST))
	add_trauma_for_level(GameConst.FeelLevel.CATALYST)
	_apply_chromatic(_ca_intensity_for(GameConst.FeelLevel.CATALYST))
	if particles != null:
		# R229 满载门收口：门开时反应爆闪 1/2 采样（顿帧/震屏/色差在前已施加，零触碰）
		if _burst_thin_on():
			_rxn_thin_tick += 1
			if _rxn_thin_tick % 2 != 1:
				DebugStats.count(&"burst_thinned")
				return
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
	# + 粒子发射器寿命兜底回收（爆炸残留修复，用户反馈 2026-08-29）
	if particles != null and particles.particle_pool != null:
		particles.particle_pool.reap_expired(p_raw_delta)
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
	# 按档位叠加 trauma（shake_trauma[p_level]，clamp 由 CameraShake 承担）。
	# 设置页震屏开关（P3）：入口短路——只关震动，顿帧/色差/粒子打击感全保留
	if shake == null or feel_config == null:
		return
	if not bool(Meta.settings("shake_on")):
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
	# 色差强度：base × level_mult（0.004 起跳分级放大，AC-15.4）。
	# R188 档2：fx_quality 档内乘数——低档全关（0.0）/ 中档半强（0.5）/ 高档保持（1.0）；
	# 缺省档 2 口径逐位不变（pkg4 色差起跳 0.004×2 断言锚定）。
	if feel_config == null:
		return 0.0
	var idx := clampi(p_level, 0, feel_config.ca_level_mult.size() - 1)
	var q := clampi(int(Meta.settings("fx_quality")), 0, 2)
	return feel_config.ca_base_intensity * feel_config.ca_level_mult[idx] \
		* float(CA_QUALITY_INTENSITY[q])


func _apply_chromatic(p_intensity: float) -> void:
	# 触发色差段（同档更强覆盖；剩余时长重置为本段衰减窗口）。
	# R188 档2：衰减窗口按 fx_quality 缩放（中档缩窗——衰减更快，高档全窗口）
	if p_intensity <= 0.0 or feel_config == null:
		return
	if p_intensity >= _ca_peak:
		_ca_peak = p_intensity
	var q := clampi(int(Meta.settings("fx_quality")), 0, 2)
	_ca_left = feel_config.ca_decay_s * float(CA_QUALITY_WINDOW[q])
	current_ca_intensity = _ca_peak * (_ca_left / _ca_decay_s_safe())


func _ca_decay_s_safe() -> float:
	return feel_config.ca_decay_s if feel_config != null else 0.15


func _push_chromatic_uniform() -> void:
	# shader uniform 同步 + 零强度隐藏（无开销路径）。
	# R188 档2：低档（fx_quality=0）全屏色差整体关（ca_enabled 缺省 true 不动——档内开关）
	# R203 真机分辨率专项：mobile 门内整体禁用——全屏 hint_screen_texture 后处理是移动
	# GPU 唯一逐像素全屏通道（R202 侦查定性），命中风暴期常开，1.5K-2K 屏上代价不可容；
	# 震屏/跳字/顿帧等打击反馈不受影响（仅去色差一层）
	if chromatic_rect == null:
		return
	var q := clampi(int(Meta.settings("fx_quality")), 0, 2)
	var enabled := (feel_config == null or feel_config.ca_enabled) and q > 0 \
			and not OS.has_feature("mobile")
	chromatic_rect.visible = enabled and current_ca_intensity > 0.0001
	if _chromatic_material != null:
		_chromatic_material.set_shader_parameter(&"intensity", current_ca_intensity)


func _crit_stop_dense() -> bool:
	# R188 档2：CRIT 顿帧密集场判定（滚动窗内申请达限 → 自动关；申请记录仍入列——
	# 密集场持续期间恒 true，窗口滑出后自动恢复）。Boss/精英/反应路径不经此处。
	while not _crit_stop_times.is_empty() \
			and _raw_elapsed - float(_crit_stop_times[0]) > CRIT_STOP_DENSE_WINDOW:
		_crit_stop_times.pop_front()
	# R189c：判据补设计原文「敌 >N」（评审#11：仅按申请频率时缺省档暴击混战期顿帧
	# 整体消失可感）——频率达限 **且** 在树活敌 ≥ 门限才判密集；Enemy.live_count 静态计数。
	var dense := _crit_stop_times.size() >= CRIT_STOP_DENSE_LIMIT \
		and Enemy.live_count >= CRIT_STOP_DENSE_ENEMY_MIN
	if not dense:
		_crit_stop_times.append(_raw_elapsed)
	return dense


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

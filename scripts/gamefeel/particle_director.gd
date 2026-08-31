# scripts/gamefeel/particle_director.gd
# M-15 ParticleDirector（架构 §2.14）：GPUParticles2D 统一池化管理入口。
# 职责：burst 请求分发（优先级裁剪在 ParticlePool.burst，AC-15.5：同屏 ≤64 发射器、
# KILL > CRIT > HIT > AMBIENT）；为池内发射器程序化配置 ParticleProcessMaterial（占位美术，
# 正式粒子后续迭代）。无独立运行时状态（转发层）。
class_name ParticleDirector
extends Node

var particle_pool: ParticlePool = null        # 注入（Boot 期 GameLoop 组装）
var burst_requests: int = 0                   # 遥测：受理的 burst 请求累计
var dropped_requests: int = 0                  # 遥测：满池且无可抢占时的丢弃数（AC-15.5 口径）

# 优先级档位（GameFeelConfig.particle_priorities 真源；键封闭）
const PRIORITY_KILL := 4
const PRIORITY_CRIT := 3
const PRIORITY_HIT := 2
const PRIORITY_AMBIENT := 1

# v0.7.0 U9：三反应 → 专属 burst 场景 id（池模板统一 burst emitter，id 仅作 meta/材质选择键）
const REACTION_SCENE_IDS: Dictionary = {
	GameConst.ReactionType.RXN_FIR_ICE: &"burst_rxn_shatter",       # 碎裂
	GameConst.ReactionType.RXN_FIR_LTG: &"burst_rxn_overload",      # 过载
	GameConst.ReactionType.RXN_ICE_LTG: &"burst_rxn_superconduct",  # 超导
}
# v0.7.0 U9：反应粒子预设（色/速度/重力/最大缩放；真源 A6 §9）
const REACTION_PRESETS: Dictionary = {
	&"burst_rxn_shatter": {"color": Color(1.0, 0.5, 0.3), "vmin": 180.0, "vmax": 320.0,
		"gravity_y": 320.0, "scale_max": 2.0},
	&"burst_rxn_overload": {"color": Color(1.0, 0.9, 0.3), "vmin": 120.0, "vmax": 260.0,
		"gravity_y": 120.0, "scale_max": 1.6},
	&"burst_rxn_superconduct": {"color": Color(0.8, 0.7, 1.0), "vmin": 60.0, "vmax": 160.0,
		"gravity_y": 40.0, "scale_max": 1.2},
}

var _shared_material: ParticleProcessMaterial = null   # 程序化占位材质（全发射器共享）
var _reaction_materials: Dictionary = {}               # StringName(scene_id) -> 材质（U9）


func setup(p_pool: ParticlePool) -> void:
	# 注入池 + 程序化占位材质准备（一次性）+ 反应预设材质（一次性）
	particle_pool = p_pool
	_shared_material = ParticleProcessMaterial.new()
	_shared_material.direction = Vector3(0, -1, 0)
	_shared_material.spread = 180.0
	_shared_material.initial_velocity_min = 40.0
	_shared_material.initial_velocity_max = 160.0
	_shared_material.gravity = Vector3(0, 240, 0)
	_shared_material.scale_min = 0.5
	_shared_material.scale_max = 1.4
	_shared_material.color = Color(1.0, 0.85, 0.4)
	for key in REACTION_PRESETS:
		var preset: Dictionary = REACTION_PRESETS[key]
		var mat := ParticleProcessMaterial.new()
		mat.direction = Vector3(0, -1, 0)
		mat.spread = 180.0
		mat.initial_velocity_min = float(preset["vmin"])
		mat.initial_velocity_max = float(preset["vmax"])
		mat.gravity = Vector3(0, float(preset["gravity_y"]), 0)
		mat.scale_min = 0.5
		mat.scale_max = float(preset["scale_max"])
		mat.color = preset["color"]
		_reaction_materials[key] = mat


func burst(p_scene_id: StringName, p_pos: Vector2, p_priority: int) -> void:
	# 优先级裁剪（击杀 > 暴击 > 普命中 > 环境），≤64 由池承担（AC-15.5）。
	# v0.7.0 U9：burst 返回发射器（可 null）→ 反应场景 id 重指对应预设材质；
	# 默认 scene_id → shared；★ 每次重指防串色（池化发射器材质复用）。
	var emitter := particle_pool.burst(p_scene_id, p_pos, p_priority) \
		if particle_pool != null else null   # 审查 Q2：保留未 setup 守卫（防御回退）
	burst_requests += 1
	if emitter == null:
		dropped_requests += 1                   # 满池且无可抢占 → 丢弃（原 misses 判据等价）
		return
	if _reaction_materials.has(p_scene_id):
		emitter.process_material = _reaction_materials[p_scene_id]
	elif _shared_material != null:
		emitter.process_material = _shared_material


func apply_placeholder_material(p_emitter: GPUParticles2D) -> void:
	# 池预热后为发射器配置程序化占位材质（Boot 期一次性）
	if p_emitter != null and _shared_material != null:
		p_emitter.process_material = _shared_material
		if p_emitter.texture == null:
			# 占位粒子贴图：4×4 白点（程序化；美术后续替换）
			p_emitter.texture = _placeholder_texture()


static func _placeholder_texture() -> ImageTexture:
	# 共享静态占位贴图（程序化生成）
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 0.9, 0.6, 1.0))
	return ImageTexture.create_from_image(img)

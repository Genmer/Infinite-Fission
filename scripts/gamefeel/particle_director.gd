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

var _shared_material: ParticleProcessMaterial = null   # 程序化占位材质（全发射器共享）


func setup(p_pool: ParticlePool) -> void:
	# 注入池 + 程序化占位材质准备（一次性）。
	# 碎片配色（用户裁定敌人角色化 2026-08-29）：白闪 → 珊瑚红（PopPalette.ENEMY）→
	# 透明渐隐 + 角速度翻滚——死亡「同色碎片 pop」/受击火花共用本材质（战斗通道全部敌向）。
	particle_pool = p_pool
	_shared_material = ParticleProcessMaterial.new()
	_shared_material.direction = Vector3(0, -1, 0)
	_shared_material.spread = 180.0
	_shared_material.initial_velocity_min = 90.0
	_shared_material.initial_velocity_max = 220.0
	_shared_material.gravity = Vector3(0, 240, 0)
	_shared_material.scale_min = 0.5
	_shared_material.scale_max = 1.4
	_shared_material.angular_velocity_min = -540.0
	_shared_material.angular_velocity_max = 540.0
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	gradient.set_color(1, Color(PopPalette.ENEMY.r, PopPalette.ENEMY.g, PopPalette.ENEMY.b, 0.0))
	gradient.add_point(0.22, Color(PopPalette.ENEMY.r, PopPalette.ENEMY.g, PopPalette.ENEMY.b, 1.0))
	var ramp := GradientTexture1D.new()
	ramp.gradient = gradient
	_shared_material.color_ramp = ramp


func burst(p_scene_id: StringName, p_pos: Vector2, p_priority: int) -> void:
	# 优先级裁剪（击杀 > 暴击 > 普命中 > 环境），≤64 由池承担（AC-15.5）。
	# 丢弃判定（遥测）：池 misses 增加且 preempted_count 未变（抢占成功路径 misses 同样 +1）。
	if particle_pool == null:
		return
	var miss_before: int = int(particle_pool.stats()["misses"])
	var preempt_before: int = particle_pool.preempted_count
	particle_pool.burst(p_scene_id, p_pos, p_priority)
	burst_requests += 1
	if int(particle_pool.stats()["misses"]) > miss_before and particle_pool.preempted_count == preempt_before:
		dropped_requests += 1


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

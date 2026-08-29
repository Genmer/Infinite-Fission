# scripts/core/pools/particle_pool.gd
# M-13 特化池：ParticlePool（GPUParticles2D 一次性发射器；架构 §2.3/§5.1：预热 64 / 软 64 / 硬 96）
# burst：优先级裁剪 + ≤64 发射器（AC-15.5，KILL > CRIT > HIT > AMBIENT）；
# 一次性发射器（one_shot）播放完成信号 → 自动归还。
class_name ParticlePool
extends ObjectPool

var preempted_count: int = 0                 # 优先级抢占回收计数（遥测）

# 活跃发射器优先级表（GPUParticles2D → priority；抢占裁剪判据）
var _active_priorities: Dictionary = {}


func acquire() -> GPUParticles2D:
	# 一次性发射器取出
	return super.acquire() as GPUParticles2D


func burst(scene_id: StringName, pos: Vector2, priority: int) -> void:
	# 优先级裁剪 + ≤64 发射器（AC-15.5）：满池时抢占最低优先级的活跃发射器（低让高）；
	# 无可抢占 → 丢弃请求（调用方计数，降级不崩溃）。
	var emitter := acquire()
	if emitter == null:
		var victim := _lowest_priority_emitter()
		if victim != null and int(_active_priorities.get(victim, 0)) < priority:
			preempted_count += 1
			release(victim)
			emitter = acquire()
	if emitter == null:
		return
	_active_priorities[emitter] = priority
	emitter.set_meta(&"_burst_scene_id", scene_id)
	emitter.position = pos
	emitter.visible = true
	emitter.one_shot = true
	emitter.emitting = true
	if not emitter.finished.is_connected(_on_emitter_finished):
		emitter.finished.connect(_on_emitter_finished.bind(emitter))


func release(node: Node) -> void:
	# 架构原文签名 release(e: GPUParticles2D)；GDScript 覆写不允许参数收窄，保持 Node 签名。
	if node is GPUParticles2D:
		var e := node as GPUParticles2D
		_active_priorities.erase(e)
		e.emitting = false
	super.release(node)


func release_active_all() -> void:
	# 清场归还（GameLoop._reset_run_state 重开口径，审查 Fix 1）：全部活跃发射器归还。
	# disconnect 必须携带 burst 期 bind 的同构 Callable（BoundCallable 按对象+方法+绑定参
	# 比较相等），否则提前停播后的 finished 信号会在复播完成时触发二次归还（E-05 违例）
	for e in _active_priorities.keys():
		var emitter := e as GPUParticles2D
		if emitter != null:
			var bound: Callable = _on_emitter_finished.bind(emitter)
			if emitter.finished.is_connected(bound):
				emitter.finished.disconnect(bound)
			release(emitter)


func _on_emitter_finished(emitter: GPUParticles2D) -> void:
	# 播放完成信号 → 自动归还
	if emitter != null:
		release(emitter)


func _lowest_priority_emitter() -> GPUParticles2D:
	# 取最低优先级活跃发射器（同分取先入者——确定性）
	var victim: GPUParticles2D = null
	var lowest := 1 << 30
	for e in _active_priorities:
		var p := int(_active_priorities[e])
		if p < lowest:
			lowest = p
			victim = e
	return victim

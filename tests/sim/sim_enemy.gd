# tests/sim/sim_enemy.gd
# v1.5.0 TTK 复校工装（A14）：仿真敌装配器（纯静态）。
# · make_data(p_base,p_kind)：EnemyData.duplicate(true) 派生——spd=0（静止靶）/
#   ranged={}（无远程臂）/ Boss 段只留 phases+phase2_resist（弹幕+召唤清空——A14 §2 假设
#   留痕：Boss 弹幕/召唤臂不进 TTK 口径）/ shield 保留（_ns 变体 spawn 后 strip_shield）。
# · E6 按 w 映射：w<10→E6_boss1 / [10,20)→E6_boss2 / ≥20→E6_boss3（镜像 WaveDirector Boss 档）。
# · spawn(p_env,p_kind,p_wave)：池 acquire → spawn（E5 加 TAG_ELITE）→ position(360,300)
#   → *_ns 变体 strip_shield → register_host + grid.rebuild（单敌快照）。
# · make_formula_target(p_hp)：pkg1 DUMMY_ENEMY_SRC 逐字复用（tests/formula/
#   test_formula_pipeline.gd:109-116）——对齐门（sim_align）公式侧夹具。
class_name SimEnemy
extends RefCounted

const KIND_E1 := "E1"
const KIND_E5 := "E5"
const KIND_E5_NS := "E5_ns"
const KIND_E6 := "E6"
const KIND_E6_NS := "E6_ns"
const KINDS: Array[String] = [KIND_E1, KIND_E5, KIND_E5_NS, KIND_E6, KIND_E6_NS]

# pkg1 公式夹具母本（逐字；对齐门 DPS 通道用——直落血不走池）
const DUMMY_ENEMY_SRC := "extends Enemy\n" \
	+ "var status_vuln: float = 0.0\n" \
	+ "var take_count: int = 0\n" \
	+ "var applied_total: float = 0.0\n" \
	+ "func take_result(p_result: DamageResult) -> void:\n" \
	+ "\ttake_count += 1\n\tapplied_total += p_result.final_value\n" \
	+ "\thp -= p_result.final_value\n" \
	+ "\tif hp <= 0.0 and not dead:\n\t\tdead = true\n"

static var _dummy_script: GDScript = null


static func boss_id_for_wave(p_wave: int) -> StringName:
	# E6 Boss 档映射（WaveDirector 波表 Boss 波 w10/20/30 口径的连续化——A14 冻结）
	if p_wave < 10:
		return &"E6_boss1"
	if p_wave < 20:
		return &"E6_boss2"
	return &"E6_boss3"


static func make_data(p_base: EnemyData, p_kind: String) -> EnemyData:
	# 派生数据（duplicate(true) 深拷贝——防 .tres 共享段被改写）
	assert(p_base != null)
	var data: EnemyData = p_base.duplicate(true)
	data.spd_base = 0.0                           # 静止靶（CHASE 不位移）
	data.ranged = {}                              # 远程臂清空
	if (data.tags & GameConst.TAG_BOSS) != 0:
		# Boss 段只留 phases + phase2_resist（弹幕/召唤清空——A14 §2 假设留痕）
		var phases: int = int(data.boss.get("phases", 2))
		var p2_resist: float = float(data.boss.get("phase2_resist", 0.0))
		data.boss = {"phases": phases, "phase2_resist": p2_resist}
	return data


static func spawn(p_env: SimEnv, p_kind: String, p_wave: int) -> Enemy:
	# 装配单敌：池取出 → spawn（E5 族加 TAG_ELITE）→ 锚点 → _ns 剥盾 → 宿主挂载 + 网格
	assert(KINDS.has(p_kind))
	var data := make_data(_base_data(p_env, p_kind, p_wave), p_kind)
	var enemy: Enemy = p_env.enemy_pool.acquire() as Enemy
	if enemy == null:
		push_error("[SimEnemy] 敌池满（容量 %d）" % SimEnv.ENEMY_POOL_CAP)
		assert(false)
		return null
	var tags := GameConst.TAG_ELITE if p_kind.begins_with("E5") else 0
	enemy.spawn(data, p_wave, tags)
	enemy.position = SimEnv.ENEMY_POS
	if p_kind.ends_with("_ns"):
		enemy.strip_shield()                      # 召唤剥盾通道复用（三字段清零）
	p_env.elemental.register_host(enemy)
	p_env.set_host(enemy)
	var roster: Array[Node2D] = [enemy]
	p_env.grid.rebuild(roster)
	return enemy


static func release(p_env: SimEnv, p_enemy: Enemy) -> void:
	# 归还（宿主注销 + 池回收；reset_for_cell 之外的手动释放口）
	if p_enemy != null and is_instance_valid(p_enemy):
		p_env.elemental.unregister_host(p_enemy)
		p_env.enemy_pool.release(p_enemy)
	if p_env._host == p_enemy:
		p_env.set_host(null)


static func make_formula_target(p_hp: float) -> Enemy:
	# pkg1 DUMMY_ENEMY_SRC 逐字复用（对齐门公式通道夹具；不入池不入树）
	if _dummy_script == null:
		_dummy_script = GDScript.new()
		_dummy_script.source_code = DUMMY_ENEMY_SRC
		_dummy_script.reload()
	var t: Enemy = _dummy_script.new()
	t.set("hp", p_hp)
	t.set("uid", GameConst.next_uid())
	return t


static func _base_data(p_env: SimEnv, p_kind: String, p_wave: int) -> EnemyData:
	match p_kind:
		KIND_E1:
			return p_env.registry.get_enemy(&"E1_grunt")
		KIND_E5, KIND_E5_NS:
			return p_env.registry.get_enemy(&"E5_elite")
		KIND_E6, KIND_E6_NS:
			return p_env.registry.get_enemy(boss_id_for_wave(p_wave))
	push_error("[SimEnemy] 未知敌种类：%s" % p_kind)
	assert(false)
	return null

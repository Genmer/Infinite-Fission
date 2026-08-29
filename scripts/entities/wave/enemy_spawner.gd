# scripts/entities/wave/enemy_spawner.gd
# M-04 EnemySpawner（架构 §2.11）：生成节流 + 池预热协作 + 出生点 + 死亡回收。
# 节流契约（B_spec M-04）：单帧 ≤8、同屏 ≤120 排队（敌池满亦排队不丢弃——波次不卡死）。
# 死亡回收：订阅 EventBus.enemy_killed → 活跃表移除 → 池归还（M1 无尸体表现，立即归还）。
class_name EnemySpawner
extends Node

const SPAWN_PER_FRAME: int = 8                # 单帧生成节流（B_spec M-04）
const MAX_ONSCREEN: int = 120                # 同屏敌人上限（超出排队，波次不卡死）
const SPAWN_OFFSCREEN := 40.0                # 出生点屏外余量（配合入场渐显）

var pool: EnemyPool = null                    # 注入
var registry: DataRegistry = null             # 注入（data_id → EnemyData 解析）
var projectile_pool: ProjectilePool = null    # 注入（RANGED 敌人敌弹池——ballistic 场景）
var map_mods: Dictionary = {}                 # 地图词缀（GameLoop.start_run 注入；M2 二期）
var enemy_grid: SpaceGrid = null              # 最近一次 tick 的网格（E-10 分离力/查询预留）
var elemental_system: ElementalSystem = null  # 注入（包 4 帧序⑤：出生 register_host 挂状态容器）
var spawn_queue: Array[Dictionary] = []      # 待生成队列 {data_id, wave, tags, pos}
var active: Array[Node2D] = []                # 活跃敌列表（GameLoop ④ enemy_grid.rebuild 数据源）
var rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	rng.randomize()
	EventBus.enemy_killed.connect(_on_enemy_killed)


func prewarm() -> void:
	# 启动预热（AC-14.2，Boot 期完成）
	if pool != null:
		pool.prewarm(GameConfig.get_pool_capacity(&"enemy"))


func enqueue(p_entry: Dictionary) -> void:
	# WaveDirector 投放生成请求：{data_id, wave, tags, pos}（pos 可缺省→出生点抽样）
	spawn_queue.append(p_entry)


func tick(p_game_delta: float, p_grid: SpaceGrid) -> void:
	# 节流出队 → pool.acquire → enemy.spawn → 挂活跃表（p_game_delta 为帧节奏锚，出队节流按帧计）
	enemy_grid = p_grid
	var spawned := 0
	while spawned < SPAWN_PER_FRAME and not spawn_queue.is_empty():
		if active.size() >= MAX_ONSCREEN:
			break                             # 同屏上限：余量留队（排队不丢弃）
		var entry: Dictionary = spawn_queue[0]
		var data := _resolve_data(entry)
		if data == null:
			spawn_queue.pop_front()          # 悬空数据：丢弃该请求 + 告警（AC-13.3 口径）
			push_warning("[EnemySpawner] 敌数据缺失（%s），丢弃该生成请求"
				% str(entry.get("data_id", "")))
			continue
		if pool == null:
			return
		var enemy := pool.acquire() as Enemy
		if enemy == null:
			break                             # 池满：留在队首等待下帧（不丢弃）
		spawn_queue.pop_front()
		enemy.spawn(data, int(entry.get("wave", 1)), int(entry.get("tags", 0)))
		_apply_map_mods(enemy)
		enemy.projectile_pool = projectile_pool
		enemy.enemy_grid = enemy_grid
		if elemental_system != null:
			elemental_system.register_host(enemy)   # 包 4：出生挂元素状态容器（帧序⑤宿主）
		var pos_v: Variant = entry.get("pos", null)
		if pos_v is Vector2:
			enemy.position = pos_v
		else:
			enemy.position = _pick_spawn_pos()
		active.append(enemy)
		if enemy.is_boss():
			EventBus.emit_boss_spawned(enemy)   # Boss 登场事件（HUD 血条/GameFeel）
		spawned += 1


func _apply_map_mods(p_enemy: Enemy) -> void:
	# 地图词缀（M2 二期）：出生后差分修正——冰抗/移速/生命
	if map_mods.is_empty():
		return
	if map_mods.has("ice_resist"):
		var r: Array = p_enemy.resist
		if r.size() > 2:
			r[2] = clampf(float(r[2]) + float(map_mods["ice_resist"]), -0.8, 0.8)
	if map_mods.has("spd_mult"):
		p_enemy.speed = p_enemy.speed * float(map_mods["spd_mult"])
	if map_mods.has("hp_mult"):
		p_enemy.max_hp = p_enemy.max_hp * float(map_mods["hp_mult"])
		p_enemy.hp = p_enemy.max_hp


func on_enemy_killed(p_enemy: Node2D) -> void:
	# 死亡通知：活跃表移除 → 元素宿主注销（清 DOT，AC-11.1）→ _reset_state + 池归还（经 pool.release 前置钩子）
	active.erase(p_enemy)
	if elemental_system != null:
		elemental_system.unregister_host(p_enemy)
	if pool != null:
		pool.release(p_enemy)


func active_count() -> int:
	return active.size()


func queue_count() -> int:
	return spawn_queue.size()


func queue_empty() -> bool:
	return spawn_queue.is_empty()


func _on_enemy_killed(p_enemy: Node2D) -> void:
	on_enemy_killed(p_enemy)


func _resolve_data(p_entry: Dictionary) -> EnemyData:
	# data_id → EnemyData（注册表；亦接受直接 data 引用——测试/内存构造通道）
	var direct: Variant = p_entry.get("data", null)
	if direct is EnemyData:
		return direct
	var id: Variant = p_entry.get("data_id", &"")
	if id is StringName or id is String:
		if registry != null:
			return registry.get_enemy(StringName(String(id)))
	return null


func _pick_spawn_pos() -> Vector2:
	# 出生点（任务书）：顶边（60%）+ 左右上 20% 区域（各 20%）——屏外余量入场
	var size := Vector2(720.0, 1280.0)
	if GameConfig.balance != null:
		size = Vector2(GameConfig.balance.res_logic)
	var roll := rng.randf()
	if roll < 0.6:
		return Vector2(rng.randf_range(0.0, size.x), -SPAWN_OFFSCREEN)
	if roll < 0.8:
		return Vector2(-SPAWN_OFFSCREEN, rng.randf_range(0.0, size.y * 0.2))
	return Vector2(size.x + SPAWN_OFFSCREEN, rng.randf_range(0.0, size.y * 0.2))

# scripts/entities/wave/enemy_spawner.gd
# M-04 EnemySpawner（架构 §2.11）：生成节流 + 池预热协作 + 出生点 + 死亡回收。
# 节流契约（B_spec M-04）：单帧 ≤8、同屏 ≤120 排队（敌池满亦排队不丢弃——波次不卡死）。
# 死亡回收：订阅 EventBus.enemy_killed → 活跃表移除 → 池归还（M1 无尸体表现，立即归还）。
class_name EnemySpawner
extends Node

const SPAWN_PER_FRAME: int = 8                # 单帧生成节流（B_spec M-04）
const WAVE1_SPAWN_PER_FRAME: int = 4          # R267 刀P5：首波摊帧档——w1 出队 8→4（出发后
                                             # 首两帧渲染/贴图上传余量让路；敌自屏外走入+
                                             # 入场渐显天然无感）。生成顺序=队列序不变，仅
                                             # 改每帧出队帽；wave≥2 契约 8/帧不动（M-04）
const MAX_ONSCREEN: int = 120                # 同屏敌人上限（超出排队，波次不卡死）。
                                             # R269 必改2：const 保留（r212_poolwarm_cases 符号
                                             # 直引编译不破）——产品消费经 max_onscreen() 读口
const SPAWN_OFFSCREEN := 40.0                # 出生点屏外余量（配合入场渐显）
const SPAWN_QUEUE_HIGH_WATER := 600          # R188 档3：spawn_queue 高水位（深层无尽投放无界——
                                            # w233+ 建波 O(count) 结构性失控配套钳；正常局峰值远低）
const QUEUE_WARN_REARM := 300                # 告警重臂水位（队列回落至半水位重臂——每饱和段一次告警）

var pool: EnemyPool = null                    # 注入
var registry: DataRegistry = null             # 注入（data_id → EnemyData 解析）
var projectile_pool: ProjectilePool = null    # 注入（RANGED 敌人敌弹池——ballistic 场景）
var map_mods: Dictionary = {}                 # 地图词缀（GameLoop.start_run 注入；M2 二期）
var enemy_grid: SpaceGrid = null              # 最近一次 tick 的网格（E-10 分离力/查询预留）
var elemental_system: ElementalSystem = null  # 注入（包 4 帧序⑤：出生 register_host 挂状态容器）
var spawn_queue: Array[Dictionary] = []      # 待生成队列 {data_id, wave, tags, pos}
var active: Array[Node2D] = []                # 活跃敌列表（GameLoop ④ enemy_grid.rebuild 数据源）
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var difficulty: int = 0                         # R72 难度档（GameLoop 开局注入；0=普通）
var queue_rejected: int = 0                    # R188 档3：高水位拒收累计（DebugStats 同步计数）
var _queue_warned: bool = false                # R188 档3：高水位一次告警闸（回落重臂，不刷屏）


func _ready() -> void:
	add_to_group(&"enemy_spawner")           # F2：受击方向指示查找口
	rng.randomize()
	EventBus.enemy_killed.connect(_on_enemy_killed)


func prewarm() -> void:
	# 启动预热（AC-14.2，Boot 期完成）
	if pool != null:
		pool.prewarm(GameConfig.get_pool_capacity(&"enemy"))


static func max_onscreen() -> int:
	# R269 A-5：同屏敌上限读口（§3.4——boost 开=90 模式帽 / 关=MAX_ONSCREEN 120 逐位）。
	# 排队不丢弃契约保持（超帽留队，波次不卡死——只是到场节奏放缓 §6 披露）。产品代码
	# 唯一消费点=tick 同屏比较处；const MAX_ONSCREEN 保留供符号直引（r212_poolwarm:118）。
	# R289 B：深载（boost ∧ 滞回闩）再降到 60——已在场敌不回收，只放缓到场节奏；
	# 深载解除即回 90（boost 关恒 120，逐位不变）。
	# R290 修轮（vc89 判读：深载期 90 敌 + 250 弹下 per-entity 地板仍 46-78µs/敌/步，
	# fps 只到 9-14）：深载档再压一档 60 → 40（保帧优先侧；到场节奏放缓，波次不卡死）。
	if PerfGovernor.deep_load():
		return 40
	return 90 if PerfGovernor.boost_mode() else MAX_ONSCREEN


func enqueue(p_entry: Dictionary, p_priority: bool = false) -> void:
	# WaveDirector 投放生成请求：{data_id, wave, tags, pos}（pos 可缺省→出生点抽样）。
	# R188 档3：高水位 600 拒收（深层无尽建波投放无界——队列积压 = 帧尖峰与 RSS 缓升
	# 根源之一；拒收请求直接丢弃，WaveDirector 侧已按 ≤200/波钳制，正常局不触线）
	# R289 修轮 2（评审 P2-4）：Boss 优先入队（p_priority=true）——深载 40 帽只放缓
	# 出队，若 Boss 排整波小怪之后可能被拖过硬上限/埋进下一波（终局不可接受）。
	if spawn_queue.size() >= SPAWN_QUEUE_HIGH_WATER:
		queue_rejected += 1
		DebugStats.count(&"spawn_queue_rejected")
		if not _queue_warned:
			_queue_warned = true
			push_warning("[EnemySpawner] spawn_queue 达高水位 %d：拒收后续投放请求（一次告警）"
				% SPAWN_QUEUE_HIGH_WATER)
		return
	if p_priority:
		spawn_queue.push_front(p_entry)
	else:
		spawn_queue.append(p_entry)


func tick(p_game_delta: float, p_grid: SpaceGrid) -> void:
	# 节流出队 → pool.acquire → enemy.spawn → 挂活跃表（p_game_delta 为帧节奏锚，出队节流按帧计）
	enemy_grid = p_grid
	if _queue_warned and spawn_queue.size() < QUEUE_WARN_REARM:
		_queue_warned = false                    # R188 档3：队列回落半水位 → 重臂告警（每饱和段一次）
	var spawned := 0
	# R267 刀P5：首波摊帧——队首待生成项 wave==1 时本帧出队帽取 4（17 只 = 5 帧内落场，
	# 出发链同帧的渲染/首遇卡冷建余量让路）；FIFO 下同帧出队项同波，队首判定即整帧帽。
	# wave≥2 项回 8/帧原契约；首波残余与次波首项同帧共存时按队首项档位走（次波完整项
	# 下帧起即 8/帧，最坏多等 1 帧不破「波次不卡死」）。
	var per_frame := SPAWN_PER_FRAME
	if not spawn_queue.is_empty() and int(spawn_queue[0].get("wave", 1)) == 1:
		per_frame = WAVE1_SPAWN_PER_FRAME
	while spawned < per_frame and not spawn_queue.is_empty():
		if active.size() >= max_onscreen():    # R269 A-5：比较处换读口（boost 开 90/关 120）
			break                             # 同屏上限：余量留队（排队不丢弃）
		var entry: Dictionary = spawn_queue[0]
		var data := _resolve_data(entry)
		if data == null:
			spawn_queue.pop_front()          # 悬空数据：丢弃该请求 + 告警（AC-13.3 口径）
			DebugStats.count(&"spawn_dropped")   # R194 双诊断（P0-4）：悬空丢弃可观测化（原口径仅 push_warning 静默）
			push_warning("[EnemySpawner] 敌数据缺失（%s），丢弃该生成请求"
				% str(entry.get("data_id", "")))
			continue
		if pool == null:
			return
		var enemy := pool.acquire() as Enemy
		if enemy == null:
			break                             # 池满：留在队首等待下帧（不丢弃）
		spawn_queue.pop_front()
		# R214 E'：分桶 host 注入须在 spawn 前（spawn 内 _sync_visual 尾 _place_in_bucket
		# 消费；host 未装配的老路径 null=不分桶零行为变化）
		enemy.bucket_host = pool.bucket_host
		enemy.spawn(data, int(entry.get("wave", 1)), int(entry.get("tags", 0)))
		_elite_affix_roll(enemy, int(entry.get("wave", 1)))
		# E5/R251 首遇介绍卡：敌第一次实际登场 → 首遇卡片（跨局只弹一次）。R251 通道
		# 升级：由 mechanics_intro toast 改发 first_encounter_card 统一弹卡（队列化不互顶，
		# 图标+一句话正文）；文案表 R251 §3.4 已扩全 29 敌——三路生成（自然波/Boss/精英
		# 召唤）汇聚出队天然全覆盖
		var note := GameConst.enemy_attack_note(String(data.id))
		if not note.is_empty() and Meta.mark_first_met(data.id):
			EventBus.emit_first_encounter_card(
				"【首次遭遇】%s" % data.display_name, note, &"enemy", StringName(String(data.id)))
		# R28 基线强化（用户裁定「敌人攻击、生命值提升 20%」）：出生管线单次应用
		# R72 难度乘区（困难 ×3 / 地狱 ×9——用户口径「最基础的数值：攻击、血量」）：
		# 与基线同点单次应用，覆盖全部自然刷怪/Boss/召唤
		enemy.max_hp = enemy.max_hp * 1.2 * GameConst.difficulty_hp_mult(difficulty)
		enemy.hp = enemy.max_hp
		enemy.contact_dmg = enemy.contact_dmg * 1.2 * GameConst.difficulty_dmg_mult(difficulty)
		# R188 档3：深层无尽「变强不变多」乘区（WaveDirector count 钳 ≤200 溢出转乘区，
		# "pressure" 键随生成请求下发；总血量预算守恒、攻击 √p 折算防单触秒杀）。
		# 召唤请求（enemy 侧 enqueue）不携带该键 → 天然不受影响
		var pressure: Variant = entry.get("pressure", null)
		if pressure != null and float(pressure) > 1.0:
			var p := float(pressure)
			enemy.max_hp = enemy.max_hp * p
			enemy.hp = enemy.max_hp
			enemy.contact_dmg = enemy.contact_dmg * sqrt(p)
		# 召唤物面值折算（B4 裂变召唤 hp_ratio 0.08/0.5——ENEMY_BOSS_TELEGRAPH §2）
		var hp_ratio: Variant = entry.get("hp_ratio", null)
		if hp_ratio != null:
			enemy.max_hp = enemy.max_hp * float(hp_ratio)
			enemy.hp = enemy.max_hp
		# 召唤来源标记（B4 cap 判据：仅统计 Boss 召唤的同种，不误伤自然波次刷出）
		var sum_uid: Variant = entry.get("summon_uid", null)
		enemy.set_meta(&"_summoned_by", int(sum_uid) if sum_uid != null else -1)
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
		enemy.ip_birth_snap()                 # R233 T6：插值缓冲置出生位（prev=curr=挂位后出生位）
		active.append(enemy)
		if enemy.is_boss():
			EventBus.emit_boss_spawned(enemy)   # Boss 登场事件（HUD 血条/GameFeel）
		spawned += 1


const ELITE_AFFIX_POOL: Array[StringName] = [
	&"affix_ring", &"affix_sniper", &"affix_trapper", &"affix_charger", &"affix_caller",
]   # 五词缀齐（§6）；扫线/狂暴永不下发精英
const ELITE_AFFIX_EXCLUSIVE := [["affix_charger", "affix_trapper"]]   # 互斥对：冲锋×布雷禁叠
const ELITE_AFFIX_WAVE := 8                   # 词缀精英起始波（§6 投放节奏）


func _elite_affix_roll(p_enemy: Enemy, p_wave: int) -> void:
	# 夜间R39 投放门：wave 8+ 精英 1 词缀；wave 15+ 30% 双词缀（本批词缀池无互斥对；
	# charger×trapper 互斥待二批接 charger 时落地）。词缀写实例侧 data 副本不动共享 tres。
	if p_enemy == null or p_enemy.is_boss() or not p_enemy.is_elite() or p_wave < ELITE_AFFIX_WAVE:
		return
	var data := p_enemy.data
	if data == null:
		return
	var affixes: Array[StringName] = [ELITE_AFFIX_POOL[randi() % ELITE_AFFIX_POOL.size()]]
	if p_wave >= 15 and randf() < 0.3:
		for extra in ELITE_AFFIX_POOL:
			if affixes.has(extra):
				continue
			var clash := false
			for pair in ELITE_AFFIX_EXCLUSIVE:
				if (extra in pair) and (affixes[0] in pair):
					clash = true
			if not clash:
				affixes.append(extra)
				break
	data = data.duplicate() as EnemyData
	data.elite_affixes = affixes
	p_enemy.data = data
	p_enemy.set_elite_affixes(affixes)


func _apply_map_mods(p_enemy: Enemy) -> void:
	# 地图词缀（M2 二期 + 词缀二期双词缀诅咒侧，数值真源 map_table.gd 注释块）：
	# 出生后差分修正——冰抗/移速/生命/小怪生命/接触伤
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
	if map_mods.has("mob_hp_mult") and not p_enemy.is_boss():
		# 虫群（草原诅咒）：小怪 HP +8%——Boss 免除（词缀二期口径： TAG_BOSS 不吃）
		p_enemy.max_hp = p_enemy.max_hp * float(map_mods["mob_hp_mult"])
		p_enemy.hp = p_enemy.max_hp
	if map_mods.has("contact_mult"):
		# 毒肤（树海诅咒）：敌接触伤 +8%（敌弹伤害同源 contact_dmg，随动放大）
		p_enemy.contact_dmg = p_enemy.contact_dmg * float(map_mods["contact_mult"])


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

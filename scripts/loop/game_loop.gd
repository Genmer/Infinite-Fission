# scripts/loop/game_loop.gd
# M-01 GameLoop（架构 §2.17）：状态机 / 固定帧序 / time_scale 唯一持有者 / Boot 序列。
# · 状态机：BOOT→MENU→PLAYING⇄PAUSED / PLAYING⇄LEVEL_UP / →GAME_OVER（迁移矩阵冻结，
#   E-16：player_died 优先级最高，GameOver 状态 level_up 请求丢弃 + 计数）。
# · 固定帧序（架构 §2.17，顺序禁止重排）：①输入 →②玩家(+武器开火——包2 Player.tick 落地口径)
#   →④双网格重建+投射物 →⑤敌+元素+帧末反应 →⑥波次 →⑦GameFeel(raw) →⑧UI(raw)。
# · 双时间通道（§8.7 冻结契约）：game_delta = raw × time_scale 是一切游戏逻辑唯一时间源；
#   顿帧 = GameFeelDirector 申请 → time_scale 短时 0.05，GameLoop 自行消费 raw 计算——
#   ★ 绝不写 Engine.time_scale（AC-15.1/E-11：无时间债跳变）。LEVEL_UP/PAUSED 用 tree.paused。
# · Boot：GameConfig → DataRegistry → 池×5 预热 → 子系统组装 → MENU（<3s 预算；xp 池待
#   集成包经验链路实体时补挂）。
# 编排说明：本类是 main.tscn 根（集成包组装）；headless 自测可直接实例化 + 手动驱动
# _physics_process(raw_delta)。
class_name GameLoop
extends Node2D

const SCENE_PLAYER := "res://scenes/combat/player/player.tscn"
const SCENE_PROJECTILE := "res://scenes/combat/projectiles/ballistic_projectile.tscn"
const SCENE_ENEMY := "res://scenes/combat/enemies/enemy.tscn"
const SCENE_POPUP := "res://scenes/ui/damage_popup.tscn"
const SCENE_PARTICLE := "res://scenes/fx/burst_emitter.tscn"
const SCENE_LASER := "res://scenes/combat/lasers/laser_beam.tscn"
const MANIFEST_PATH := "res://data/manifest.cfg"
const STARTING_WEAPON_ID := &"W1_pistol"      # Q-4：首发手枪

# 状态机（复用 GameConst.GameStatus：BOOT/MENU/PLAYING/PAUSED/LEVEL_UP/GAME_OVER）
# 合法迁移矩阵（冻结；非法迁移 change_state 拒绝 + 计数）
const TRANSITIONS: Dictionary = {
	GameConst.GameStatus.BOOT: [GameConst.GameStatus.MENU],
	GameConst.GameStatus.MENU: [GameConst.GameStatus.PLAYING],
	GameConst.GameStatus.PLAYING: [GameConst.GameStatus.PAUSED, GameConst.GameStatus.LEVEL_UP,
		GameConst.GameStatus.GAME_OVER],
	GameConst.GameStatus.PAUSED: [GameConst.GameStatus.PLAYING, GameConst.GameStatus.GAME_OVER],
	GameConst.GameStatus.LEVEL_UP: [GameConst.GameStatus.PLAYING, GameConst.GameStatus.GAME_OVER],
	GameConst.GameStatus.GAME_OVER: [GameConst.GameStatus.MENU, GameConst.GameStatus.PLAYING],
}

var state: int = GameConst.GameStatus.BOOT
var time_scale: float = 1.0                   # ★ 唯一持有者（写入口仅 set_time_scale）
var time_scale_source: StringName = &""       # 当前缩放来源（遥测/测试观测）
var frame_stamp: int = 0                      # GameConfig.advance_frame 同步源
var rejected_transitions: int = 0             # 非法迁移拒绝计数（测试/遥测）
var dropped_level_ups: int = 0                # GameOver 状态升级请求丢弃计数（E-16）
var pending_level_ups: int = 0                # 多级连升排队（A3 §6.2：排队弹卡）
var boot_ready: bool = false                  # Boot 完成（MENU 可进）
var boot_fatal: Array = []                    # 致命错误清单（非空 → 停留 BOOT）

var pipeline: RefCounted = null               # DamagePipeline 真件/桩（get_pipeline 工厂）
var enemy_grid: SpaceGrid                     # 敌人格（弹-敌碰撞主路径）
var enemy_bullet_grid: SpaceGrid              # 敌弹格（消弹查询）
var player: Player = null
var wave_director: WaveDirector = null
var spawner: EnemySpawner = null
var elemental: ElementalSystem = null
var game_feel: GameFeelDirector = null
var registry: DataRegistry = null
var popup_manager: PopupManager = null
var hud: HUD = null
var boss_bar: BossBar = null
var game_over_screen: GameOverScreen = null
var card_generator: CardGenerator = null
var card_select_ui: CardSelectUI = null
var pools: Dictionary = {}                    # {projectile, enemy, popup, particle, laser}

var frame_order: Array[StringName] = []       # 帧序探针（每帧重建；测试断言固定帧序）
var current_candidates: Array[Dictionary] = []   # 当前货架（测试观测）

var _projectile_pool: ProjectilePool = null
var _boot_elapsed_ms: float = 0.0             # Boot 耗时（AC：<3s 预算遥测）


func _ready() -> void:
	# Boot 序列（架构 §六.2）：fatal 检查 → registry → 池预热 → 子系统组装 → MENU
	process_mode = Node.PROCESS_MODE_ALWAYS      # tree.paused 期间仍驱动 ⑦⑧（帧序契约）
	var t0 := Time.get_ticks_usec()
	if GameConfig.is_fatal():
		boot_fatal = GameConfig.fatal_errors.duplicate()
		push_error("[GameLoop] 致命配置，拒绝进入 MENU：%s" % str(boot_fatal))
		return
	_boot_load_data()
	_boot_build_pools()
	_boot_build_grids()
	_boot_build_actors()
	_boot_build_presentation()
	boot_ready = true
	_boot_elapsed_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	change_state(GameConst.GameStatus.MENU)


func _physics_process(p_raw_delta: float) -> void:
	# ★ 固定帧序（架构 §2.17，顺序禁止重排）
	GameConfig.advance_frame()
	frame_stamp = GameConfig.frame_stamp
	if pipeline != null:
		pipeline.begin_frame()
	match state:
		GameConst.GameStatus.PLAYING:
			var gd := _game_delta(p_raw_delta)
			frame_order.clear()
			# ① 输入采样：相对拖动由 Player._unhandled_input 自采（E-15 单指针锁定），
			#    GameLoop 本层透传零向量 = 玩家消费自采样（包 2 落地口径）
			frame_order.append(&"input")
			# ② 玩家（移动/受击/拾取；内含武器冷却+开火调度——包 2 Player.tick 落地口径）
			frame_order.append(&"player")
			player.tick(gd, Vector2.ZERO)
			# ④ 双网格重建（当前实体位置确定性快照）→ 投射物运动/碰撞/结算
			frame_order.append(&"grid_projectile")
			enemy_grid.rebuild(spawner.active)
			enemy_bullet_grid.rebuild(_collect_enemy_bullets())
			_tick_projectiles(gd)
			# ⑤ 敌 AI + 元素 tick + 帧末反应检测（E-07；倒序遍历——自爆/结算可在 tick 内回收）
			frame_order.append(&"enemy")
			var eidx := spawner.active.size() - 1
			while eidx >= 0:
				var enemy := spawner.active[eidx] as Enemy
				if is_instance_valid(enemy):
					enemy.tick(gd)
				eidx -= 1
			elemental.tick(gd)
			elemental.detect_reactions()
			# ⑥ 波次推进（生成节流 ≤8/帧 / 窗口计时 / Boss 伴随怪流水）
			frame_order.append(&"wave")
			wave_director.tick(gd)
			# ⑦ GameFeel（raw 通道）→ 顿帧申请出口（time_scale 唯一变更点）
			frame_order.append(&"feel")
			game_feel.tick(p_raw_delta)
			set_time_scale(game_feel.desired_time_scale(), &"gamefeel")
			# ⑧ UI（raw 通道：跳字/HUD/Boss 条——顿帧期间照常，Q-14）
			frame_order.append(&"ui")
			_tick_ui(p_raw_delta)
		GameConst.GameStatus.LEVEL_UP, GameConst.GameStatus.PAUSED:
			# tree.paused=true 冻结全部 PAUSABLE 子系统（AC-16.2 战斗完全冻结）；
			# 仅 ⑦⑧ 以 raw 通道运行（架构帧序契约）
			frame_order.clear()
			frame_order.append(&"feel")
			game_feel.tick(p_raw_delta)
			set_time_scale(game_feel.desired_time_scale(), &"gamefeel")
			frame_order.append(&"ui")
			_tick_ui(p_raw_delta)
		_:
			pass                                  # BOOT/MENU/GAME_OVER：无战斗帧序
	if pipeline != null:
		pipeline.end_frame()
	EventBus.end_frame()                          # 事件风暴计数清零（§六.4）


# ── 状态机（迁移矩阵仲裁，E-16） ─────────────────────────────────
func change_state(p_new: int) -> bool:
	# 仲裁：迁移矩阵校验 → tree.paused 联动 → state_changed 广播
	var allowed: Array = TRANSITIONS.get(state, [])
	if not allowed.has(p_new):
		rejected_transitions += 1
		push_warning("[GameLoop] 非法状态迁移拒绝：%d → %d" % [state, p_new])
		return false
	state = p_new
	get_tree().paused = (p_new == GameConst.GameStatus.PAUSED
		or p_new == GameConst.GameStatus.LEVEL_UP)
	if p_new == GameConst.GameStatus.GAME_OVER:
		time_scale = 1.0                          # 结算屏恢复常态缩放（下一局干净起步）
	EventBus.emit_state_changed(p_new)
	return true


func request_pause() -> bool:
	# M-16/M-17 暂停申请（仲裁后生效）
	return change_state(GameConst.GameStatus.PAUSED)


func request_resume() -> bool:
	return change_state(GameConst.GameStatus.PLAYING)


func start_run() -> bool:
	# MENU → PLAYING：波次 1 开局
	if not change_state(GameConst.GameStatus.PLAYING):
		return false
	wave_director.start_wave(1)
	return true


func restart_run() -> bool:
	# GAME_OVER → PLAYING（重开）：数值重置 + 波次 1 重开
	if state != GameConst.GameStatus.GAME_OVER:
		return false
	if not change_state(GameConst.GameStatus.PLAYING):
		return false
	_reset_run_state()
	wave_director.start_wave(1)
	return true


func set_time_scale(p_value: float, p_source: StringName) -> void:
	# ★ time_scale 唯一写入口（§1.3-7：audit 调用者；绝不写 Engine.time_scale，§8.7）
	time_scale = clampf(p_value, 0.0, 1.0)
	time_scale_source = p_source


func _game_delta(p_raw_delta: float) -> float:
	# raw × time_scale（子系统唯一时间源；顿帧 ≈0 → 全部游戏计时自然冻结，E-11）
	return p_raw_delta * time_scale


func _on_player_died() -> void:
	# 死亡仲裁（E-16：优先级最高；任何状态 → GAME_OVER）
	if state == GameConst.GameStatus.GAME_OVER or state == GameConst.GameStatus.BOOT \
			or state == GameConst.GameStatus.MENU:
		return                                    # 未开局/已结算：忽略
	change_state(GameConst.GameStatus.GAME_OVER)


func _on_level_up(p_new_level: int) -> void:
	# 升级仲裁（E-16）：GameOver 丢弃 + 计数；PLAYING 进选卡流；LEVEL_UP 中 → 排队（A3 §6.2）
	match state:
		GameConst.GameStatus.GAME_OVER:
			dropped_level_ups += 1
		GameConst.GameStatus.PLAYING:
			_open_card_flow(p_new_level)
		GameConst.GameStatus.LEVEL_UP:
			pending_level_ups += 1
		_:
			pass                                  # 其余状态（MENU 等）：升级请求不应存在，忽略


func _open_card_flow(p_new_level: int) -> void:
	# 三选一流程：roll 3 张 → LEVEL_UP（暂停战斗）→ 选卡界面打开
	current_candidates = card_generator.generate_candidates({
		"player": player,
		"wave": wave_director.current_wave,
		"level": p_new_level,
	})
	change_state(GameConst.GameStatus.LEVEL_UP)
	card_select_ui.open(current_candidates)


func _on_card_choice(p_card: Dictionary) -> void:
	# 选卡应用（CardGenerator）→ 恢复 PLAYING；连升排队继续弹（A3 §6.2）
	if state != GameConst.GameStatus.LEVEL_UP:
		return
	card_generator.apply_choice(p_card, player)
	card_select_ui.close()
	change_state(GameConst.GameStatus.PLAYING)
	if pending_level_ups > 0:
		pending_level_ups -= 1
		_open_card_flow(player.level)


# ── Boot 各段 ─────────────────────────────────────────────────────
func _boot_load_data() -> void:
	# DataRegistry 启动期一次性加载（运行期零 .tres 加载，E-08）
	registry = DataRegistry.new()
	registry.load_all(MANIFEST_PATH)


func _boot_build_pools() -> void:
	# 池×5（容量真源 BalanceTables.pool_prewarm；xp 池待集成包经验实体后补挂）
	_projectile_pool = ProjectilePool.new()
	_projectile_pool.name = "ProjectilePool"
	add_child(_projectile_pool)
	_projectile_pool.setup(&"projectile", load(SCENE_PROJECTILE),
		GameConfig.get_pool_capacity(&"projectile"))
	_projectile_pool.soft_limit = int(GameConfig.balance.projectile_soft_limit)
	_projectile_pool.hard_limit = int(GameConfig.balance.projectile_hard_limit)
	var enemy_pool := EnemyPool.new()
	enemy_pool.name = "EnemyPool"
	add_child(enemy_pool)
	enemy_pool.setup(&"enemy", load(SCENE_ENEMY), GameConfig.get_pool_capacity(&"enemy"))
	var popup_pool := PopupPool.new()
	popup_pool.name = "PopupPool"
	add_child(popup_pool)
	popup_pool.setup(&"popup", load(SCENE_POPUP), GameConfig.get_pool_capacity(&"popup"))
	var particle_pool := ParticlePool.new()
	particle_pool.name = "ParticlePool"
	add_child(particle_pool)
	particle_pool.setup(&"particle", load(SCENE_PARTICLE), GameConfig.get_pool_capacity(&"particle"))
	var laser_pool := LaserBeamPool.new()
	laser_pool.name = "LaserPool"
	add_child(laser_pool)
	laser_pool.setup(&"laser", load(SCENE_LASER), GameConfig.get_pool_capacity(&"laser"))
	pools = {
		&"projectile": _projectile_pool,
		&"enemy": enemy_pool,
		&"popup": popup_pool,
		&"particle": particle_pool,
		&"laser": laser_pool,
	}
	# 预热（AC-14.2，Boot 期完成）
	_projectile_pool.prewarm(GameConfig.get_pool_capacity(&"projectile"))
	enemy_pool.prewarm(GameConfig.get_pool_capacity(&"enemy"))
	popup_pool.prewarm(GameConfig.get_pool_capacity(&"popup"))
	particle_pool.prewarm(GameConfig.get_pool_capacity(&"particle"))
	laser_pool.prewarm(GameConfig.get_pool_capacity(&"laser"))


func _boot_build_grids() -> void:
	# SpaceGrid ×2（§1.3-6：GameLoop 持有；720×1280 + 192px 出屏余量）
	enemy_grid = SpaceGrid.new()
	enemy_grid.configure(Vector2(GameConfig.balance.res_logic), 192.0)
	enemy_bullet_grid = SpaceGrid.new()
	enemy_bullet_grid.configure(Vector2(GameConfig.balance.res_logic), 192.0)


func _boot_build_actors() -> void:
	# 管线（工厂自动切真件）→ 玩家（形态工厂依赖注入）→ 敌波 → 元素系统
	pipeline = DamagePipelineStub.get_pipeline()
	elemental = ElementalSystem.new()
	elemental.name = "ElementalSystem"
	add_child(elemental)
	elemental.pipeline = pipeline
	elemental.enemy_grid = enemy_grid
	player = (load(SCENE_PLAYER) as PackedScene).instantiate() as Player
	player.name = "Player"
	add_child(player)
	player.setup({
		"pipeline": pipeline,
		"projectile_pool": _projectile_pool,
		"enemy_grid": enemy_grid,
		"enemy_bullet_grid": enemy_bullet_grid,
		"laser_pool": pools[&"laser"],
		"elemental": elemental,
	})
	spawner = EnemySpawner.new()
	spawner.name = "EnemySpawner"
	add_child(spawner)
	spawner.pool = pools[&"enemy"]
	spawner.registry = registry
	spawner.projectile_pool = _projectile_pool
	spawner.enemy_grid = enemy_grid
	spawner.elemental_system = elemental
	spawner.prewarm()
	wave_director = WaveDirector.new()
	wave_director.name = "WaveDirector"
	add_child(wave_director)
	wave_director.spawner = spawner
	wave_director.registry = registry
	wave_director.wave_table = registry.get_wave_table()
	wave_director.enemy_grid = enemy_grid
	# Q-4：首发手枪（形态工厂 add_weapon）
	player.add_weapon(registry.get_weapon(STARTING_WEAPON_ID))


func _boot_build_presentation() -> void:
	# 表现层组装：粒子导演 → GameFeel → 跳字 → HUD/Boss 条/结算屏 → 卡牌流
	var particles := ParticleDirector.new()
	particles.name = "ParticleDirector"
	add_child(particles)
	particles.setup(pools[&"particle"])
	for emitter in (pools[&"particle"] as ParticlePool).get_children():
		particles.apply_placeholder_material(emitter as GPUParticles2D)
	game_feel = GameFeelDirector.new()
	game_feel.name = "GameFeelDirector"
	add_child(game_feel)
	game_feel.setup({
		"config": registry.get_game_feel(),
		"particles": particles,
		"chromatic_host": self,
	})
	popup_manager = PopupManager.new()
	popup_manager.name = "PopupManager"
	add_child(popup_manager)
	popup_manager.setup(pools[&"popup"])
	hud = HUD.new()
	hud.name = "HUD"
	add_child(hud)
	hud.setup(player)
	hud.bind_events()
	boss_bar = BossBar.new()
	boss_bar.name = "BossBar"
	add_child(boss_bar)
	game_over_screen = GameOverScreen.new()
	game_over_screen.name = "GameOverScreen"
	add_child(game_over_screen)
	game_over_screen.setup(hud)
	game_over_screen.restart_requested.connect(restart_run)
	card_generator = CardGenerator.new()
	card_generator.setup(registry)
	card_select_ui = CardSelectUI.new()
	card_select_ui.name = "CardSelectUI"
	add_child(card_select_ui)
	card_select_ui.choice_made.connect(_on_card_choice)
	# 仲裁订阅（E-16：死亡最高优先 / 升级弹卡排队）
	EventBus.player_died.connect(_on_player_died)
	EventBus.level_up.connect(_on_level_up)


# ── 帧序支撑 ──────────────────────────────────────────────────────
func _tick_projectiles(p_gd: float) -> void:
	# 投射物逐弹 tick（倒序遍历：tick 内可能回收自身 → release 擦除当前/更早索引安全）
	var actives := _projectile_pool.active_projectiles()
	var idx := actives.size() - 1
	while idx >= 0:
		var proj := actives[idx]
		if is_instance_valid(proj):
			proj.tick(p_gd)
		idx -= 1


func _collect_enemy_bullets() -> Array[Node2D]:
	# 敌弹列表（team==1；供消弹查询网格重建——上一帧位置的确定性快照口径）
	var out: Array[Node2D] = []
	for proj in _projectile_pool.active_projectiles():
		if proj is ProjectileBase and (proj as ProjectileBase).team == 1:
			out.append(proj)
	return out


func _tick_ui(p_raw_delta: float) -> void:
	# ⑧ UI 阶段（raw 通道）：跳字 → HUD → Boss 条
	popup_manager.tick(p_raw_delta)
	hud.tick(p_raw_delta)
	boss_bar.tick(p_raw_delta)


func _reset_run_state() -> void:
	# 重开重置：玩家（HP/经验/槽位/武器）/ HUD 统计 / 卡牌流 / 顿帧态
	player.hp = player.max_hp
	player.level = 1
	player.xp = 0.0
	player.xp_need = 14.0
	player.unlocked_slots = 1
	player.invuln_left = 0.0
	for i in range(player.weapon_slots.size()):
		var w: WeaponBase = player.weapon_slots[i] if i < player.weapon_slots.size() else null
		if w != null and is_instance_valid(w):
			w.queue_free()
		player.weapon_slots[i] = null
	player.add_weapon(registry.get_weapon(STARTING_WEAPON_ID))
	hud.kills = 0
	hud.wave = 0
	hud.total_damage = 0.0
	hud.run_elapsed = 0.0
	card_generator.owned_relics.clear()
	pending_level_ups = 0
	game_feel.hit_stop_left = 0.0
	game_feel.hit_stop_active_ms = 0.0
	set_time_scale(1.0, &"reset")

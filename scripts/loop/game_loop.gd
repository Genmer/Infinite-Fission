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
const SCENE_XP_SHARD := "res://scenes/combat/pickups/xp_shard.tscn"   # B.1 经验碎片（XPPool 模板）
const SCENE_GOLD_COIN := "res://scenes/combat/pickups/gold_coin.tscn"   # v0.6.0 金币（GoldPool 模板，A4 §3）
const GOLD_RNG_SEED: int = 42                 # 金币掉落 roll 固定种子（A4 §7：与卡牌流同口径，可注入）
# E-10 敌间分离力（软分离防重叠）：10Hz 降频 + 网格邻域查询（性能预案 §5.2-5；
# 单轴单次推移 ≤4px 软钳——分离是观感修正而非物理约束，避免两帧内挤开 Boss 阵型）
const SEPARATION_INTERVAL := 0.1              # 10Hz（架构 §2.11 敌间分离力口径）
const SEPARATION_MAX_STEP := 4.0              # 单敌单次推移上限 px

# 状态机（复用 GameConst.GameStatus：BOOT/MENU/PLAYING/PAUSED/LEVEL_UP/GAME_OVER/SHOP）
# 合法迁移矩阵（冻结；非法迁移 change_state 拒绝 + 计数）；v0.6.0：PLAYING→SHOP 增边 +
# SHOP 行（闭店回 PLAYING / 商店期死亡结算 GAME_OVER，A4 §1）
const TRANSITIONS: Dictionary = {
	GameConst.GameStatus.BOOT: [GameConst.GameStatus.MENU],
	GameConst.GameStatus.MENU: [GameConst.GameStatus.PLAYING],
	GameConst.GameStatus.PLAYING: [GameConst.GameStatus.PAUSED, GameConst.GameStatus.LEVEL_UP,
		GameConst.GameStatus.GAME_OVER, GameConst.GameStatus.SHOP],
	GameConst.GameStatus.PAUSED: [GameConst.GameStatus.PLAYING, GameConst.GameStatus.GAME_OVER],
	GameConst.GameStatus.LEVEL_UP: [GameConst.GameStatus.PLAYING, GameConst.GameStatus.GAME_OVER],
	GameConst.GameStatus.GAME_OVER: [GameConst.GameStatus.MENU, GameConst.GameStatus.PLAYING],
	GameConst.GameStatus.SHOP: [GameConst.GameStatus.PLAYING, GameConst.GameStatus.GAME_OVER],
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
var relic_handler: RelicHandler = null         # 集成包 B.2：遗物效果处理器
var chip_handler: ChipHandler = null           # v0.7.0：芯片效果处理器（A6 §2）
var curse_handler: CurseHandler = null         # v0.8.0：诅咒效果处理器（A7 §V6）
var event_director: EventDirector = null       # v0.8.0：事件效果处理器（A7 §V2）
var event_ui: EventUI = null                   # v0.8.0：事件界面（复用 SHOP 态宿主）
var blessing_handler: BlessingHandler = null   # v0.9.0：波次赐福处理器（A8 §1）
var blessing_ui: BlessingUI = null             # v0.9.0：赐福界面（复用 SHOP 态宿主）
var meta_store: MetaStore = null               # v1.0.0：局外成长存档层（A9，boot 首位组装）
var meta_panel: MetaPanel = null               # v1.0.0：结晶强化面板（MENU 态宿主，A9）
var current_character: CharacterData = null    # v0.8.0：本局选中角色（null = 默认兜底）
var menu_screen: MenuScreen = null            # 集成包 A：主菜单屏（MENU 态宿主）
var camera: Camera2D = null                   # 集成包 A：震屏偏移宿主（trauma² 映射应用位）
var shop_ui: ShopUI = null                    # v0.6.0：Boss 前商店界面（SHOP 态宿主）
var pools: Dictionary = {}                    # {projectile, enemy, popup, particle, laser, xp, gold}

var frame_order: Array[StringName] = []       # 帧序探针（每帧重建；测试断言固定帧序）
var current_candidates: Array[Dictionary] = []   # 当前货架（测试观测）
var active_shards: Array[XpShard] = []        # 场上经验碎片（掉落/吸附/归还管理，B.1）
var gold: int = 0                             # v0.6.0 金币余额（唯一真源；变更走 _add_gold → gold_changed）
var active_coins: Array[GoldCoin] = []        # 场上金币（掉落/吸附/入账/归还管理，A4 §3）
var upgrade_cards_dealt: int = 0              # v0.7.0 U11：本局升级发牌数（首件武器保底计数）
var stage_probe_enabled: bool = false         # 分阶段采样开关（架构 §5.5：P95 超线按阶段定位）
var stage_probe_us: Dictionary = {}           # {StringName 阶段: 累计 usec}（仅 PLAYING 帧，逐帧重建）

var _projectile_pool: ProjectilePool = null
var _boot_elapsed_ms: float = 0.0             # Boot 耗时（AC：<3s 预算遥测）
var _separation_left: float = SEPARATION_INTERVAL   # E-10 分离力 10Hz 相位
var _gold_rng: RandomNumberGenerator = RandomNumberGenerator.new()   # v0.6.0 金币 roll 流（默认 seed 42）
var _deferred_shop_wave: int = 0              # v0.6.0 非战斗态暂存商店波（0 = 无；闭店/选卡后排空）
var _deferred_event_wave: int = 0             # v0.8.0：非战斗态暂存事件波（0 = 无）
var _deferred_event_index: int = -1           # v0.8.0：暂存事件索引（配对 _deferred_event_wave）
var _deferred_blessing: bool = false          # v0.9.0：非战斗态暂存赐福（排空补开，A8）
var _settled_this_run: bool = false           # v1.0.0：局外结转一次闸（A9，_reset_run_state 复位）


func _ready() -> void:
	# Boot 序列（架构 §六.2）：fatal 检查 → registry → 池预热 → 子系统组装 → MENU
	process_mode = Node.PROCESS_MODE_ALWAYS      # tree.paused 期间仍驱动 ⑦⑧（帧序契约）
	_gold_rng.seed = GOLD_RNG_SEED               # v0.6.0：金币 roll 定种子（set_gold_rng_seed 可注入）
	var t0 := Time.get_ticks_usec()
	if GameConfig.is_fatal():
		boot_fatal = GameConfig.fatal_errors.duplicate()
		_build_boot_error_screen()
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
			var _probe_t0 := Time.get_ticks_usec() if stage_probe_enabled else 0
			if stage_probe_enabled:
				stage_probe_us.clear()
			# ① 输入采样：相对拖动由 Player._unhandled_input 自采（E-15 单指针锁定），
			#    GameLoop 本层透传零向量 = 玩家消费自采样（包 2 落地口径）
			frame_order.append(&"input")
			# ② 玩家（移动/受击/拾取；内含武器冷却+开火调度——包 2 Player.tick 落地口径）
			frame_order.append(&"player")
			player.tick(gd, Vector2.ZERO)
			_tick_xp_shards(gd)               # B.1：经验碎片磁吸/吸收（拾取属玩家阶段）
			_tick_gold_coins(gd)              # v0.6.0：金币磁吸/吸收（紧随经验碎片，帧序②内）
			if stage_probe_enabled:
				stage_probe_us[&"player"] = Time.get_ticks_usec() - _probe_t0
				_probe_t0 = Time.get_ticks_usec()
			# ④ 双网格重建（当前实体位置确定性快照）→ 投射物运动/碰撞/结算
			frame_order.append(&"grid_projectile")
			enemy_grid.rebuild(spawner.active)
			enemy_bullet_grid.rebuild(_collect_enemy_bullets())
			_tick_projectiles(gd)
			if stage_probe_enabled:
				stage_probe_us[&"grid_projectile"] = Time.get_ticks_usec() - _probe_t0
				_probe_t0 = Time.get_ticks_usec()
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
			# E-10 敌间软分离（10Hz 降频；网格为 ④ 阶段重建快照——上一帧位置确定性口径）
			_separation_left -= gd
			if _separation_left <= 0.0:
				_separation_left = SEPARATION_INTERVAL
				_apply_enemy_separation()
			if stage_probe_enabled:
				stage_probe_us[&"enemy"] = Time.get_ticks_usec() - _probe_t0
				_probe_t0 = Time.get_ticks_usec()
			# ⑥ 波次推进（生成节流 ≤8/帧 / 窗口计时 / Boss 伴随怪流水）
			frame_order.append(&"wave")
			wave_director.tick(gd)
			if stage_probe_enabled:
				stage_probe_us[&"wave"] = Time.get_ticks_usec() - _probe_t0
				_probe_t0 = Time.get_ticks_usec()
			# ⑦ GameFeel（raw 通道）→ 顿帧申请出口（time_scale 唯一变更点）
			frame_order.append(&"feel")
			game_feel.tick(p_raw_delta)
			set_time_scale(game_feel.desired_time_scale(), &"gamefeel")
			# ⑧ UI（raw 通道：跳字/HUD/Boss 条——顿帧期间照常，Q-14）
			frame_order.append(&"ui")
			_tick_ui(p_raw_delta)
			if stage_probe_enabled:
				stage_probe_us[&"feel_ui"] = Time.get_ticks_usec() - _probe_t0
		GameConst.GameStatus.LEVEL_UP, GameConst.GameStatus.PAUSED, GameConst.GameStatus.SHOP:
			# tree.paused=true 冻结全部 PAUSABLE 子系统（AC-16.2 战斗完全冻结）；
			# 仅 ⑦⑧ 以 raw 通道运行（架构帧序契约）；v0.6.0 SHOP 合并本分支（帧序不变）
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
		or p_new == GameConst.GameStatus.LEVEL_UP
		or p_new == GameConst.GameStatus.SHOP)     # v0.6.0：商店期战斗冻结（A4 §1）
	if p_new == GameConst.GameStatus.GAME_OVER:
		time_scale = 1.0                          # 结算屏恢复常态缩放（下一局干净起步）
	EventBus.emit_state_changed(p_new)
	return true


func request_pause() -> bool:
	# M-16/M-17 暂停申请（仲裁后生效）
	return change_state(GameConst.GameStatus.PAUSED)


func request_resume() -> bool:
	return change_state(GameConst.GameStatus.PLAYING)


func start_run(p_character_id: StringName = &"") -> bool:
	# MENU → PLAYING：波次 1 开局。v0.8.0（A7 §V18）：p_character_id 空参读菜单选中
	#（start_requested 无参 emit 冻结兼容）；未命中 registry → null 兜底（STARTING_WEAPON_ID
	# 口径由 _starting_weapon_id 承担）。★ 重排：角色应用与首发武器装载并入 _reset_run_state
	#（restart_run 同路径——角色感知重开零分支）。
	if not change_state(GameConst.GameStatus.PLAYING):
		return false
	var requested: StringName = p_character_id
	if requested == &"" and menu_screen != null:
		requested = menu_screen.selected_character_id()
	current_character = registry.get_character(requested) if requested != &"" else null
	_reset_run_state()
	wave_director.start_wave(1)
	return true


func restart_run() -> bool:
	# GAME_OVER → PLAYING（重开）：数值重置 + 波次 1 重开（★ 语义零改动——pkg4/pkg5/pkg6
	# 冻结断言兼容；v0.8.0 角色感知由 _reset_run_state 内部 apply_character 承担）
	if state != GameConst.GameStatus.GAME_OVER:
		return false
	if not change_state(GameConst.GameStatus.PLAYING):
		return false
	_reset_run_state()
	wave_director.start_wave(1)
	return true


func goto_menu() -> bool:
	# v0.8.0：GAME_OVER → MENU（返回选角；迁移矩阵合法边，仲裁后生效）
	return change_state(GameConst.GameStatus.MENU)


func _starting_weapon_id() -> StringName:
	# v0.8.0（A7 §V18）：首发武器 id = 选中角色?.starting_weapon_id ?? STARTING_WEAPON_ID
	#（boot 组装 / _reset_run_state 两处共用单点）
	if current_character != null and current_character.starting_weapon_id != &"":
		return current_character.starting_weapon_id
	return STARTING_WEAPON_ID


func set_time_scale(p_value: float, p_source: StringName) -> void:
	# ★ time_scale 唯一写入口（§1.3-7：audit 调用者；绝不写 Engine.time_scale，§8.7）
	time_scale = clampf(p_value, 0.0, 1.0)
	time_scale_source = p_source


func set_gold_rng_seed(p_seed: int) -> void:
	# v0.6.0 金币 roll 流种子注入（测试确定性 / 同种子掉落序列可复现，A4 §7）
	_gold_rng.seed = p_seed


func _game_delta(p_raw_delta: float) -> float:
	# raw × time_scale（子系统唯一时间源；顿帧 ≈0 → 全部游戏计时自然冻结，E-11）
	return p_raw_delta * time_scale


func _on_player_died() -> void:
	# 死亡仲裁（E-16：优先级最高；任何状态 → GAME_OVER）
	if state == GameConst.GameStatus.GAME_OVER or state == GameConst.GameStatus.BOOT \
			or state == GameConst.GameStatus.MENU:
		return                                    # 未开局/已结算：忽略
	_settle_run()                                # v1.0.0（A9）：局外结转（一次闸），先于状态切换
	change_state(GameConst.GameStatus.GAME_OVER)


func _settle_run() -> void:
	# v1.0.0（A9）死亡结转单点：本局金币 → 结晶 + 战绩入档 + 写盘（失败仅告警）。
	# ★ 一次闸 _settled_this_run——重入不重复入账；meta_store 缺失 → 降级 set_crystal_gain(0)。
	if _settled_this_run:
		return
	_settled_this_run = true
	var gain := maxi(gold, 0)
	if meta_store == null:
		game_over_screen.set_crystal_gain(0)      # 降级：无存档层 → 结晶 +0，不入档
		return
	meta_store.add_crystal(gain)
	meta_store.record_run(hud.kills, hud.wave)
	meta_store.save()                            # 失败仅告警（MetaStore 内 push_warning）
	game_over_screen.set_crystal_gain(gain)
	_refresh_menu_meta()


func _on_level_up(p_new_level: int) -> void:
	# 升级仲裁（E-16）：GameOver 丢弃 + 计数；PLAYING 进选卡流；LEVEL_UP 中 → 排队（A3 §6.2）
	match state:
		GameConst.GameStatus.GAME_OVER:
			dropped_level_ups += 1
		GameConst.GameStatus.PLAYING:
			_open_card_flow(p_new_level)
		GameConst.GameStatus.LEVEL_UP:
			pending_level_ups += 1
		GameConst.GameStatus.SHOP:
			pending_level_ups += 1                # v0.6.0 防御：商店期升级请求排队（闭店排空）
		_:
			pass                                  # 其余状态（MENU 等）：升级请求不应存在，忽略


func _open_card_flow(p_new_level: int) -> void:
	# 三选一流程：roll 3 张 → LEVEL_UP（暂停战斗）→ 选卡界面打开。
	# 集成包 B.2：遗物改写发牌参数（GAMBLER 四选一+诅咒 / OVERCLOCK 稀有度保底），
	# WORDS_TIDE 每波一次重随货架（保留稀有度 roll 序列）
	upgrade_cards_dealt += 1                     # v0.7.0 U11：发牌计数（保底窗口 ≤3）
	var context := {
		"player": player,
		"wave": wave_director.current_wave,
		"level": p_new_level,
		"deal_count": relic_handler.deal_count(),
		"curse_last": relic_handler.curse_requested(),
		"min_rarity_floor": relic_handler.take_rarity_floor(),
		"weapon_weight_mult": 2.0 if _weapon_pity_active() else 1.0,   # U11 保底
	}
	current_candidates = card_generator.generate_candidates(context)
	if relic_handler.consume_reroll():
		var rarities: Array[int] = []
		for c in current_candidates:
			rarities.append(int(c.get("rarity", 0)))
		var reroll_context := context.duplicate()
		reroll_context["min_rarity_floor"] = -1       # 保底已折入首 roll 的稀有度序列
		reroll_context["fixed_rarities"] = rarities
		current_candidates = card_generator.generate_candidates(reroll_context)
	change_state(GameConst.GameStatus.LEVEL_UP)
	card_select_ui.open(current_candidates)


func _on_card_choice(p_card: Dictionary) -> void:
	# 选卡应用（CardGenerator）→ 恢复 PLAYING；连升排队继续弹（A3 §6.2）；
	# v0.8.0：排空重构为 _drain_overlays_after_resume 单点（弹卡→暂存店→暂存事件，行为不变）
	if state != GameConst.GameStatus.LEVEL_UP:
		return
	card_generator.apply_choice(p_card, player)
	# v0.8.0：cursed 卡（REL_GAMBLER 末位诅咒）同步诅咒层（A7 §V6 卡流接入点 1/2）
	if bool(p_card.get("cursed", false)) and curse_handler != null:
		curse_handler.add_curse(1)
	card_select_ui.close()
	change_state(GameConst.GameStatus.PLAYING)
	_drain_overlays_after_resume()


# ── 商店流（v0.6.0，A4 §1/§2：Boss 前商店——开门/购买/utility/闭店仲裁） ──
func _open_shop_flow(p_wave: int, p_black_market: bool) -> bool:
	# 开门仲裁：仅 PLAYING 可开（非战斗态 → 波号暂存，闭店/选卡后排空补开）；
	# 卡架 roll 3 张（shop_exclude_weapon 防武器混入卡价）+ 武器架 1 张随机取一
	#（无可用武器 → 空架 disabled）。roll 用卡牌 RNG（同种子可复现货架）。
	if state != GameConst.GameStatus.PLAYING:
		_deferred_shop_wave = p_wave
		return false
	var context := {
		"player": player,
		"wave": p_wave,
		"shop_exclude_weapon": true,
	}
	current_candidates = card_generator.generate_candidates(context)
	var weapon_pool := card_generator._weapon_candidates(player, [])
	var weapon_card: Dictionary = {}
	if not weapon_pool.is_empty():
		weapon_card = card_generator._make_weapon_card(
			weapon_pool[card_generator.rng.randi_range(0, weapon_pool.size() - 1)])
	# v0.7.0 U4+U7：芯片货架 roll（未持有池；wave<10 → 1 格）+ 槽位面板快照
	var chip_offers := chip_handler.roll_shop_offers(p_wave)
	change_state(GameConst.GameStatus.SHOP)
	shop_ui.open(p_wave, p_black_market, current_candidates, weapon_card, gold)
	shop_ui.set_chip_shelf(chip_offers, chip_handler.free_slots())
	shop_ui.set_chip_slots(chip_handler.slot_snapshot())
	_refresh_shop_availability()                 # v0.8.0：三 setter + heal 预禁用统一回写
	return true


func _weapon_pity_active() -> bool:
	# v0.7.0 U11：首件武器保底（已装备武器 <2 且 本局发牌数 ≤3 → WEAPON 权重 ×2）
	var held := 0
	for w in player.weapon_slots:
		if w != null and is_instance_valid(w):
			held += 1
	return held < 2 and upgrade_cards_dealt <= 3


func _refresh_shop_availability() -> void:
	# v0.8.0 V10/V11：utility 扩容可购性回写（三 setter + heal 预禁用）——
	# 开店/每次购买/utility 成功后调用（单一回写口）。
	if shop_ui == null or not shop_ui.is_open:
		return
	var primary := card_generator._primary_weapon(player)
	var strip_ok := primary != null and primary.trait_stack != null \
		and bool(primary.trait_stack.peek_last(true).get("ok", false))
	var preview := ""
	if strip_ok:
		preview = String((primary.trait_stack.peek_last(true) as Dictionary).get("display_name", ""))
	shop_ui.set_strip_available(strip_ok, preview)
	var has_gambler := primary != null and primary.trait_stack != null \
		and _stack_has_trait_id(primary.trait_stack, &"GAMBLER_CURSE")
	shop_ui.set_purify_available(has_gambler
		or (curse_handler != null and curse_handler.curse_count > 0))
	shop_ui.set_contract_available(curse_handler == null or not curse_handler.is_maxed())
	shop_ui.set_player_full_hp(player.hp >= player.max_hp)


func _stack_has_trait_id(p_stack: TraitStack, p_id: StringName) -> bool:
	for tb in p_stack.traits:
		if (tb as TraitBase).data.id == p_id:
			return true
	return false


func _close_shop() -> void:
	# 闭店：SHOP → PLAYING（战斗恢复）→ 排空连升队列与暂存商店（A4 §1；v0.8.0 重构为
	# _drain_overlays_after_resume 单点排空，行为不变）
	if state != GameConst.GameStatus.SHOP:
		return
	shop_ui.close()
	change_state(GameConst.GameStatus.PLAYING)
	_drain_overlays_after_resume()


func _drain_overlays_after_resume() -> void:
	# v0.8.0 排空序冻结（A7）：pending_level_ups 弹卡 → _deferred_shop_wave 开店 →
	# _deferred_event 开事件（逐项消费，命中即停——每项恢复 PLAYING/开新浮层）。
	# v0.9.0（A8）：序扩展为 升级→赐福→商店→事件
	if pending_level_ups > 0:
		pending_level_ups -= 1
		_open_card_flow(player.level)
		return
	if _deferred_blessing:                    # v0.9.0：暂存赐福先于商店/事件（冻结序）
		_deferred_blessing = false
		_open_blessing_flow(wave_director.current_wave if wave_director != null else 0)
		return
	if _deferred_shop_wave > 0:
		var wave := _deferred_shop_wave
		_deferred_shop_wave = 0
		_open_shop_flow(wave, false)
		return
	if _deferred_event_wave > 0:
		var wave := _deferred_event_wave
		var index := _deferred_event_index
		_deferred_event_wave = 0
		_deferred_event_index = -1
		_open_event_flow(wave, index)


# ── 事件流（v0.8.0，A7 §V1~V4：事件复用 SHOP 态——TRANSITIONS 零改动） ──
func _on_event_requested(p_wave: int, p_index: int) -> void:
	# WaveDirector.event_requested 消费（BUFFER 间隙触发，A7 §V1）
	_open_event_flow(p_wave, p_index)


func _open_event_flow(p_wave: int, p_index: int) -> void:
	# 开门仲裁：仅 PLAYING 且商店关闭可开（EventUI 与 ShopUI 互斥由本函数单点保证）；
	# 非战斗态 → 暂存（闭店/选卡后排空补开）。事件复用 SHOP 态（战斗冻结同口径）。
	if state != GameConst.GameStatus.PLAYING or (shop_ui != null and shop_ui.is_open):
		_deferred_event_wave = p_wave
		_deferred_event_index = p_index
		return
	change_state(GameConst.GameStatus.SHOP)
	event_ui.open(event_director.build_event(p_index))


func _on_event_choice(p_option: int) -> void:
	# 选项仲裁：SHOP 态且事件打开 → apply_option → 收事件回 PLAYING → 排空
	if state != GameConst.GameStatus.SHOP or event_ui == null or not event_ui.is_open:
		return
	var index := _event_index_of(event_ui.current_event())
	event_director.apply_option(index, p_option)
	_close_event()


func _on_event_leave() -> void:
	# 离开仲裁：直接收事件
	_close_event()


func _event_index_of(p_event: Dictionary) -> int:
	# 事件 id → EVENTS 索引（EventDirector 表序）；未命中 → 0 兜底
	var id := StringName(String(p_event.get("id", "")))
	for i in range(event_director.event_count()):
		if StringName(String(EventDirector.EVENTS[i].get("id", ""))) == id:
			return i
	return 0


func _close_event() -> void:
	# 收事件：SHOP → PLAYING（战斗恢复）→ 排空（连升/暂存店/暂存事件，序冻结）
	if state != GameConst.GameStatus.SHOP:
		return
	event_ui.close()
	change_state(GameConst.GameStatus.PLAYING)
	_drain_overlays_after_resume()


# ── 赐福流（v0.9.0，A8 §1：波次赐福三选一——复用 SHOP 态，TRANSITIONS 零改动） ──
func _on_wave_cleared_blessing(p_wave: int) -> void:
	# wave_cleared 消费（w>=2 才弹）；硬上限叠波直调 start_wave 不派发 wave_cleared =
	# 天然无赐福（pkg9 固化）
	if p_wave < BlessingHandler.MIN_WAVE:
		return
	_open_blessing_flow(p_wave)


func _open_blessing_flow(p_wave: int) -> void:
	# 开门仲裁：仅 PLAYING 且商店/事件/赐福均关闭可开（四重守卫，与 ShopUI/EventUI 互斥
	# 由本函数单点保证）；非战斗态 → 暂存（_deferred_blessing，闭店/选卡/收赐福后排空补开）
	if state != GameConst.GameStatus.PLAYING \
			or (shop_ui != null and shop_ui.is_open) \
			or (event_ui != null and event_ui.is_open) \
			or (blessing_ui != null and blessing_ui.is_open):
		_deferred_blessing = true
		return
	change_state(GameConst.GameStatus.SHOP)
	blessing_ui.open(blessing_handler.roll_offers(p_wave))


func _on_blessing_choice(p_index: int) -> void:
	# 选项仲裁：SHOP 态且赐福打开且 index 界内 → apply → 收赐福回 PLAYING → 排空
	if state != GameConst.GameStatus.SHOP or blessing_ui == null or not blessing_ui.is_open:
		return
	var options := blessing_ui.current_options()
	if p_index < 0 or p_index >= options.size():
		return
	var kind := StringName(String((options[p_index] as Dictionary).get("kind", &"")))
	if not blessing_handler.apply(kind, wave_director.current_wave if wave_director != null else 0):
		# 审查 Q2 防御：apply 门失败（当前被出牌时过滤覆盖、产品内不可达）——不静默消费选项
		push_warning("[GameLoop] 赐福 apply 失败（kind=%s），按跳过处理" % String(kind))
	_close_blessing()


func _on_blessing_skip() -> void:
	# 跳过仲裁：无补偿（仅 DebugStats 遥测，无信号）→ 收赐福回 PLAYING → 排空
	if state != GameConst.GameStatus.SHOP or blessing_ui == null or not blessing_ui.is_open:
		return
	blessing_handler.count_skip()
	_close_blessing()


func _close_blessing() -> void:
	# 收赐福：SHOP → PLAYING（战斗恢复）→ 排空（连升/暂存赐福/暂存店/暂存事件，序冻结 A8）
	if state != GameConst.GameStatus.SHOP:
		return
	blessing_ui.close()
	change_state(GameConst.GameStatus.PLAYING)
	_drain_overlays_after_resume()


func _on_shop_requested(p_wave: int, p_black_market: bool) -> void:
	# WaveDirector.shop_requested 消费（ BUFFER 间隙触发，A4 §1）
	_open_shop_flow(p_wave, p_black_market)


func _on_wave_cleared_shop_bridge(p_wave: int) -> void:
	# 黑市桥接（A4 §1）：relic_handler 的 REL_BLACK_MARKET 排程（w35 起每 10 波 pending+1）
	# → 转 wave_director 额外商店申请（单间隙单店闸去重）。★ 本订阅必须晚于
	# relic_handler.bind_events 连接（连接序 = 派发序：先排程再桥接）。
	if relic_handler == null or wave_director == null:
		return
	if relic_handler.pending_shop_waves > 0:
		relic_handler.pending_shop_waves -= 1
		wave_director.queue_extra_shop()


func _on_wave_cleared_gold_rush(p_wave: int) -> void:
	# v0.7.0 U5：金币关波末奖励（wave_cleared 派发于 BUFFER 前——此刻 _hard_cap_left 有值）。
	# base = 10 + 5×wave，amount = round(base × 剩余时间比)；>0 才入账 + 文本跳字。
	if wave_director == null or not wave_director.is_gold_rush_wave(p_wave):
		return
	var ratio := wave_director.gold_rush_remaining_ratio()
	var base := int(round(10.0 + 5.0 * float(p_wave)))
	var amount := int(round(float(base) * ratio))
	if amount <= 0:
		return
	_add_gold(amount)
	DebugStats.count(&"gold_rush_reward")
	if popup_manager != null and player != null and is_instance_valid(player):
		popup_manager.show_text_popup(player.global_position + Vector2(0.0, -60.0),
			"金币狂欢 +%d" % amount)


func _on_shop_purchase(p_index: int) -> void:
	# 购买仲裁（A4 §2 + v0.7.0 A6 §4）：先验证 → apply → 扣款；任一失败静默拒绝 + push_warning。
	# index 0~2 卡架 / 3 武器架 / 4~5 芯片架（芯片分支五查：未购/offer 非空/未持有/有空槽/余额足）。
	if state != GameConst.GameStatus.SHOP or shop_ui == null or not shop_ui.is_open:
		return
	if p_index < 0 or p_index > 5:
		return
	var shelf := shop_ui.shelf_state()
	var purchased: Array = shelf["purchased"]
	if bool(purchased[p_index]):
		push_warning("[GameLoop] 商店购买拒绝：已购（index %d）" % p_index)
		return
	if p_index >= 4:
		# ── 芯片分支（v0.7.0 A6 §4 五查）──
		var chip_offers: Array = shelf["chips"]
		var offer: Dictionary = chip_offers[p_index - 4] \
			if (p_index - 4) < chip_offers.size() else {}
		if offer.is_empty():
			push_warning("[GameLoop] 商店购买拒绝：芯片空架（index %d）" % p_index)
			return
		var chip_id := StringName(String(offer.get("chip_id", "")))
		if chip_handler.is_equipped(chip_id):
			push_warning("[GameLoop] 商店购买拒绝：芯片已持有（%s）" % String(chip_id))
			return
		if chip_handler.free_slots() <= 0:
			push_warning("[GameLoop] 商店购买拒绝：芯片槽满")
			return
		var chip_price := shop_ui.price_for(p_index)
		if chip_price < 0 or gold < chip_price:
			push_warning("[GameLoop] 商店购买拒绝：余额不足（需 %d，有 %d）" % [chip_price, gold])
			return
		if not chip_handler.equip(chip_id, int(offer.get("rarity", 0)),
				offer.get("substats", [])):   # v0.8.0：预随副词条所见即所得
			push_warning("[GameLoop] 芯片 equip 失败，不扣款")
			return
		_add_gold(-chip_price)
		shop_ui.mark_purchased(p_index)
		shop_ui.set_chip_slots(chip_handler.slot_snapshot())
		_refresh_shop_availability()       # v0.8.0：三 setter + heal 预禁用统一回写
		return
	var card: Dictionary = shelf["weapon"] if p_index == 3 \
		else (shelf["cards"] as Array)[p_index]
	if card.is_empty():
		push_warning("[GameLoop] 商店购买拒绝：空架（index %d）" % p_index)
		return
	var price := shop_ui.price_for(p_index)
	if price < 0 or gold < price:
		push_warning("[GameLoop] 商店购买拒绝：余额不足（需 %d，有 %d）" % [price, gold])
		return
	if p_index == 3:
		# 武器架门控复查：仍存在已解锁空槽且未持有（A4 §5 门控）
		var wd: WeaponData = card.get("data")
		if wd == null or card_generator._weapon_candidates(player, []).is_empty():
			push_warning("[GameLoop] 武器架门控失效，拒绝购买")
			return
	card_generator.apply_choice(card, player)
	# v0.8.0：cursed 卡（商店货架 REL_GAMBLER 诅咒卡）同步诅咒层（A7 §V6 卡流接入点 2/2）
	if bool(card.get("cursed", false)) and curse_handler != null:
		curse_handler.add_curse(1)
	if p_index == 3 and not card_generator._player_holds_weapon(player,
			StringName(String(card.get("id", "")))):
		push_warning("[GameLoop] 武器卡 apply 失败，不扣款")
		return
	_add_gold(-price)
	shop_ui.mark_purchased(p_index)
	_refresh_shop_availability()                 # v0.8.0：余额变动后可购性统一回写


func _on_shop_utility(p_util: StringName) -> void:
	# utility 仲裁（A4 §2）：重随券 30 每店限 1 / 回复 30%max_hp 50 / max_hp+10 80 每店限 1
	if state != GameConst.GameStatus.SHOP or shop_ui == null or not shop_ui.is_open:
		return
	var shelf := shop_ui.shelf_state()
	match p_util:
		&"reroll":
			if bool(shelf["reroll_used"]):
				push_warning("[GameLoop] 重随券每店限 1 次，拒绝")
				return
			if gold < ShopUI.REROLL_PRICE:
				push_warning("[GameLoop] 余额不足：重随券需 %d" % ShopUI.REROLL_PRICE)
				return
			_add_gold(-ShopUI.REROLL_PRICE)
			shop_ui.update_cards(card_generator.generate_candidates({
				"player": player,
				"wave": int(shelf["wave"]),
				"shop_exclude_weapon": true,
			}))
			# v0.7.0 U7：重随全域（卡架 + 芯片架；武器架维持现状）——同帧刷新
			shop_ui.set_chip_shelf(chip_handler.roll_shop_offers(int(shelf["wave"])),
				chip_handler.free_slots())
			shop_ui.set_chip_slots(chip_handler.slot_snapshot())
			shop_ui.mark_utility_used(&"reroll")
			_refresh_shop_availability()
		&"heal":
			var max_hp: float = player.get("max_hp")
			var hp: float = player.get("hp")
			if hp >= max_hp:
				push_warning("[GameLoop] 满血，拒绝购买回复")
				return
			if gold < ShopUI.HEAL_PRICE:
				push_warning("[GameLoop] 余额不足：回复需 %d" % ShopUI.HEAL_PRICE)
				return
			_add_gold(-ShopUI.HEAL_PRICE)
			player.set("hp", minf(hp + max_hp * 0.3, max_hp))
			_refresh_shop_availability()   # v0.7.0 U7 → v0.8.0 统一回写口（含 heal 预禁用）
		&"maxhp":
			if bool(shelf["maxhp_used"]):
				push_warning("[GameLoop] max_hp+10 每店限 1 次，拒绝")
				return
			if gold < ShopUI.MAXHP_PRICE:
				push_warning("[GameLoop] 余额不足：max_hp+10 需 %d" % ShopUI.MAXHP_PRICE)
				return
			_add_gold(-ShopUI.MAXHP_PRICE)
			# v0.8.0：max_hp 走 flat 池 + recompute_max_hp 唯一写入口（比例回补口径）
			player.max_hp_bonus_flat += 10.0
			if curse_handler != null:
				curse_handler.recompute_max_hp()
			else:
				player.max_hp += 10.0
			shop_ui.mark_utility_used(&"maxhp")
			# 上限抬升后 hp<max_hp → 回复合法化（审查 Fix：heal 预禁用状态同步）
			_refresh_shop_availability()
		&"strip":
			# v0.8.0 V9 移除词条（60 金/店限 1）：主武器最后挂载非诅咒词条 1 层
			if bool(shelf.get("strip_used", false)):
				push_warning("[GameLoop] 移除词条每店限 1 次，拒绝")
				return
			if gold < ShopUI.STRIP_PRICE:
				push_warning("[GameLoop] 余额不足：移除词条需 %d" % ShopUI.STRIP_PRICE)
				return
			var primary := card_generator._primary_weapon(player)
			if primary == null or primary.trait_stack == null:
				push_warning("[GameLoop] 移除词条拒绝：无主武器")
				return
			if not bool(primary.trait_stack.peek_last(true).get("ok", false)):
				push_warning("[GameLoop] 移除词条拒绝：无非诅咒词条")
				return
			var detached: Dictionary = primary.trait_stack.detach_last(true)
			primary.invalidate_panel()             # 调用方失效宿主（TraitStack 不回查宿主）
			_add_gold(-ShopUI.STRIP_PRICE)
			shop_ui.mark_utility_used(&"strip")
			_refresh_shop_availability()
			if popup_manager != null and is_instance_valid(player):
				popup_manager.show_text_popup(player.global_position + Vector2(0.0, -60.0),
					"移除词条：%s" % String(detached.get("display_name", "")))
		&"purify":
			# v0.8.0 V9 净化（80 金/店限 1）：主武器栈含 GAMBLER_CURSE → detach_by_id 优先，
			# 否则深渊诅咒层 −1；皆无 → 拒绝
			if bool(shelf.get("purify_used", false)):
				push_warning("[GameLoop] 净化每店限 1 次，拒绝")
				return
			if gold < ShopUI.PURIFY_PRICE:
				push_warning("[GameLoop] 余额不足：净化需 %d" % ShopUI.PURIFY_PRICE)
				return
			var purged := ""
			var pweapon := card_generator._primary_weapon(player)
			var had_curse_trait := false
			if pweapon != null and pweapon.trait_stack != null:
				for tb in pweapon.trait_stack.traits:
					if (tb as TraitBase).data.id == &"GAMBLER_CURSE":
						had_curse_trait = true
						break
			if had_curse_trait:
				var d: Dictionary = pweapon.trait_stack.detach_by_id(&"GAMBLER_CURSE", 1)
				if not bool(d.get("ok", false)):
					push_warning("[GameLoop] 净化拒绝：GAMBLER_CURSE 摘层失败")
					return
				pweapon.invalidate_panel()
				purged = "词条"
			elif curse_handler != null and curse_handler.remove_curse(1) > 0:
				purged = "深渊层"
			else:
				push_warning("[GameLoop] 净化拒绝：无 GAMBLER_CURSE 词条且无深渊层")
				return
			_add_gold(-ShopUI.PURIFY_PRICE)
			shop_ui.mark_utility_used(&"purify")
			_refresh_shop_availability()
			if popup_manager != null and is_instance_valid(player):
				popup_manager.show_text_popup(player.global_position + Vector2(0.0, -60.0),
					"净化完成（%s −1）" % purged)
		&"contract":
			# v0.8.0 V11 深渊契约（免费/店限 1）：+1 层换 120 金（基础值，经 _add_gold 吃
			# K_gold）；满 5 层禁用（setter 回写 disabled）
			if bool(shelf.get("contract_used", false)):
				push_warning("[GameLoop] 深渊契约每店限 1 次，拒绝")
				return
			if curse_handler == null or curse_handler.is_maxed():
				push_warning("[GameLoop] 深渊契约拒绝：诅咒已满 5 层")
				return
			if curse_handler.add_curse(1) <= 0:
				push_warning("[GameLoop] 深渊契约拒绝：加层失败")
				return
			_add_gold(ShopUI.CONTRACT_GOLD)
			shop_ui.mark_utility_used(&"contract")
			_refresh_shop_availability()
			if popup_manager != null and is_instance_valid(player):
				popup_manager.show_text_popup(player.global_position + Vector2(0.0, -60.0),
					"深渊契约：诅咒 %d/5（+120 金·基础值）" % curse_handler.curse_count)
		_:
			push_warning("[GameLoop] 未知 utility：%s" % String(p_util))


# ── Boot 各段 ─────────────────────────────────────────────────────
func _boot_load_data() -> void:
	# DataRegistry 启动期一次性加载（运行期零 .tres 加载，E-08）
	registry = DataRegistry.new()
	registry.load_all(MANIFEST_PATH)


func _boot_build_pools() -> void:
	# 池×6（容量真源 BalanceTables.pool_prewarm；xp 池集成包 B.1 挂载——XpShard 真件落地）
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
	var xp_pool := XPPool.new()
	xp_pool.name = "XPPool"
	add_child(xp_pool)
	xp_pool.setup(&"xp", load(SCENE_XP_SHARD), GameConfig.get_pool_capacity(&"xp"))
	# v0.6.0 金币池（A4 §7：容量真源 BalanceTables.pool_prewarm 增 "gold" 行）
	var gold_pool := GoldPool.new()
	gold_pool.name = "GoldPool"
	add_child(gold_pool)
	gold_pool.setup(&"gold", load(SCENE_GOLD_COIN), GameConfig.get_pool_capacity(&"gold"))
	pools = {
		&"projectile": _projectile_pool,
		&"enemy": enemy_pool,
		&"popup": popup_pool,
		&"particle": particle_pool,
		&"laser": laser_pool,
		&"xp": xp_pool,
		&"gold": gold_pool,
	}
	# 预热（AC-14.2，Boot 期完成）
	_projectile_pool.prewarm(GameConfig.get_pool_capacity(&"projectile"))
	enemy_pool.prewarm(GameConfig.get_pool_capacity(&"enemy"))
	popup_pool.prewarm(GameConfig.get_pool_capacity(&"popup"))
	particle_pool.prewarm(GameConfig.get_pool_capacity(&"particle"))
	laser_pool.prewarm(GameConfig.get_pool_capacity(&"laser"))
	xp_pool.prewarm(GameConfig.get_pool_capacity(&"xp"))
	gold_pool.prewarm(GameConfig.get_pool_capacity(&"gold"))


func _boot_build_grids() -> void:
	# SpaceGrid ×2（§1.3-6：GameLoop 持有；720×1280 + 192px 出屏余量）
	enemy_grid = SpaceGrid.new()
	enemy_grid.configure(Vector2(GameConfig.balance.res_logic), 192.0)
	enemy_bullet_grid = SpaceGrid.new()
	enemy_bullet_grid.configure(Vector2(GameConfig.balance.res_logic), 192.0)


func _boot_build_actors() -> void:
	# v1.0.0（A9）：MetaStore 首位组装（先于一切战斗子系统——结转/注入四通道的存档层就绪序）
	meta_store = MetaStore.new()
	meta_store.name = "MetaStore"
	add_child(meta_store)
	# v1.0.0 审查 Important 1：headless 回归与真机存档自动隔离——headless 下死亡用例的
	# settle 落独立档，真实档（窗口模式写的 meta_save.cfg）永不被测试写侧污染
	if DisplayServer.get_name() == "headless":
		meta_store.set_save_path("user://meta_save_headless.cfg")
	meta_store.load_save()
	# 管线（工厂自动切真件）→ 遗物处理器 → 敌波（spawner/wave_director）→ 玩家 → 元素系统
	# ★ 经验掉落订阅必须先于 EnemySpawner 入树（信号连接序 = 派发序：掉落侧读取
	#   exp_value/position 必须先于 spawner 的死亡归还清零，集成包 B.1）
	EventBus.enemy_killed.connect(_on_enemy_killed_drop_xp)
	# ★ v0.6.0 金币掉落订阅紧邻 xp 掉落连接点之后（连接序 = 派发序纪律同上：
	#   掉落侧读取 data.gold_drop/position 必须先于 spawner 死亡归还清零，A4 §3）
	EventBus.enemy_killed.connect(_on_enemy_killed_drop_gold)
	# ★ v0.7.0 U6 芯片掉落订阅（连接序 = 派发序纪律同 xp/gold/relic 先例：
	#   掉落侧读取 enemy.tags/spawn_wave 必须先于 spawner 死亡归还清零）
	EventBus.enemy_killed.connect(_on_enemy_killed_drop_chip)
	pipeline = DamagePipelineStub.get_pipeline()
	relic_handler = RelicHandler.new()
	relic_handler.name = "RelicHandler"
	add_child(relic_handler)
	# ★ 遗物事件绑定提前至 Boot（连接序 = 派发序）：enemy_killed 的精英 tag/治疗读取
	#   必须先于 EnemySpawner 的死亡归还清零（_reset_state 置 tags=0），集成包 B.2
	relic_handler.bind_events()
	# ★ v0.7.0 芯片处理器组装（relic_handler 之后、spawner add_child 之前——连接序纪律；
	#   U6 起本节点将订阅 enemy_killed 掉落芯片，同样先于 spawner 入树）
	chip_handler = ChipHandler.new()
	chip_handler.name = "ChipHandler"
	add_child(chip_handler)
	# ★ v0.8.0 诅咒处理器组装（chip_handler 之后、player.setup 前——player deps 注入
	#   curse_handler 问询通道，A7 §V6）
	curse_handler = CurseHandler.new()
	curse_handler.name = "CurseHandler"
	add_child(curse_handler)
	elemental = ElementalSystem.new()
	elemental.name = "ElementalSystem"
	add_child(elemental)
	elemental.pipeline = pipeline
	elemental.enemy_grid = enemy_grid
	elemental.chip_handler = chip_handler         # v0.7.0：附着强度芯片注入（A6 §3）
	# ★ wave_director 先于 spawner 入树（连接序 = 派发序）：F-19 Boss 击杀解锁读取
	#   enemy.tags 必须先于 spawner 死亡归还的 tags 清零（_reset_state）——与上方 xp 掉落
	#   订阅提前同因（集成包修复：此前 Boss 击杀解锁恒读 tags=0 失效，集成冒烟补断言）
	wave_director = WaveDirector.new()
	wave_director.name = "WaveDirector"
	add_child(wave_director)
	# ★ GameFeel 前置组装 + enemy_killed 前置订阅（连接序 = 派发序，F-19 同纪律）：
	#   Boss 击杀打击感读取 enemy.tags 必须先于 EnemySpawner 死亡归还的 tags 清零
	#   （_reset_state 置 0）——审查 Fix 2：此前 GameFeel 在 presentation 段订阅，派发序
	#   恒排在 spawner 之后（读 tags=0），Boss 击杀 120ms 顿帧永不触发。setup（其余职责）
	#   仍在 _boot_build_presentation 完成
	game_feel = GameFeelDirector.new()
	game_feel.name = "GameFeelDirector"
	add_child(game_feel)
	game_feel.early_bind()
	spawner = EnemySpawner.new()
	spawner.name = "EnemySpawner"
	add_child(spawner)
	spawner.pool = pools[&"enemy"]
	spawner.registry = registry
	spawner.projectile_pool = _projectile_pool
	spawner.enemy_grid = enemy_grid
	spawner.elemental_system = elemental
	spawner.prewarm()
	wave_director.spawner = spawner
	wave_director.registry = registry
	wave_director.wave_table = registry.get_wave_table()
	wave_director.enemy_grid = enemy_grid
	player = (load(SCENE_PLAYER) as PackedScene).instantiate() as Player
	player.name = "Player"
	player.z_index = 6
	add_child(player)
	player.setup({
		"pipeline": pipeline,
		"projectile_pool": _projectile_pool,
		"enemy_grid": enemy_grid,
		"enemy_bullet_grid": enemy_bullet_grid,
		"laser_pool": pools[&"laser"],
		"elemental": elemental,
		"relic_handler": relic_handler,           # B.2：遗物命中乘区问询通道
		"wave_director": wave_director,           # B.4：SYN_FIRST_STRIKE 波首命中位
		"chip_handler": chip_handler,             # v0.7.0：芯片 crit 折算（A6 §3）
		"curse_handler": curse_handler,           # v0.8.0：诅咒受伤乘区问询通道（A7 §V6）
	})
	relic_handler.setup({"registry": registry, "player": player})
	chip_handler.setup({"registry": registry, "player": player, "curse_handler": curse_handler})
	chip_handler.bind_events()
	curse_handler.setup({"player": player, "chip_handler": chip_handler})   # v0.8.0（A7 §V6）
	# Q-4：首发手枪（形态工厂 add_weapon；v0.8.0：id 经 _starting_weapon_id 单点——boot 期无角色 = 默认）
	player.add_weapon(registry.get_weapon(_starting_weapon_id()))


func _boot_build_presentation() -> void:
	# 表现层组装：粒子导演 → GameFeel → 跳字 → HUD/Boss 条/结算屏 → 卡牌流
	var particles := ParticleDirector.new()
	particles.name = "ParticleDirector"
	add_child(particles)
	particles.setup(pools[&"particle"])
	for emitter in (pools[&"particle"] as ParticlePool).get_children():
		particles.apply_placeholder_material(emitter as GPUParticles2D)
	# GameFeel 实例已在 _boot_build_actors 前置组装并 early_bind（Fix 2）——
	# 此处补全 setup 其余职责（config/shake/色差/其余事件订阅）
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
	game_over_screen.menu_requested.connect(goto_menu)   # v0.8.0：返回选角（A7 §V19）
	card_generator = CardGenerator.new()
	card_generator.setup(registry)
	card_select_ui = CardSelectUI.new()
	card_select_ui.name = "CardSelectUI"
	add_child(card_select_ui)
	card_select_ui.choice_made.connect(_on_card_choice)
	# v0.6.0 商店界面（A4 §1/§2）+ 黑市桥接（★ 订阅序在 relic_handler.bind_events 之后——
	# 连接序 = 派发序：wave_cleared 先由 relic 排程 pending，再由桥接转 queue_extra_shop）
	shop_ui = ShopUI.new()
	shop_ui.name = "ShopUI"
	add_child(shop_ui)
	shop_ui.purchase_requested.connect(_on_shop_purchase)
	shop_ui.utility_requested.connect(_on_shop_utility)
	shop_ui.close_requested.connect(_close_shop)
	# v0.8.0 事件流（A7 §V2）：EventDirector（效果）+ EventUI（SHOP 态复用宿主）+ 连线。
	# ★ 订阅在 shop_ui 连线之后（连接序 = 派发序：同 BUFFER 帧商店先仲裁、事件后仲裁）
	event_director = EventDirector.new()
	event_director.name = "EventDirector"
	add_child(event_director)
	event_director.setup({
		"registry": registry,
		"player": player,
		"card_generator": card_generator,
		"curse_handler": curse_handler,
		"chip_handler": chip_handler,
		"popup_manager": popup_manager,
		"game_loop": self,
	})
	event_ui = EventUI.new()
	event_ui.name = "EventUI"
	add_child(event_ui)
	event_ui.option_chosen.connect(_on_event_choice)
	event_ui.leave_requested.connect(_on_event_leave)
	# v0.9.0 波次赐福（A8 §1）：handler 需 popup_manager/hud（presentation 段组装件）——
	# 构造 + setup 在本段完成（player/chip_handler 在 actors 段已就绪）
	blessing_handler = BlessingHandler.new()
	blessing_handler.name = "BlessingHandler"
	add_child(blessing_handler)
	blessing_handler.setup({
		"player": player,
		"chip_handler": chip_handler,
		"game_loop": self,
		"popup_manager": popup_manager,
		"hud": hud,
	})
	blessing_ui = BlessingUI.new()
	blessing_ui.name = "BlessingUI"
	add_child(blessing_ui)
	blessing_ui.option_chosen.connect(_on_blessing_choice)
	blessing_ui.skip_requested.connect(_on_blessing_skip)
	# 事件开门请求（WaveDirector BUFFER 间隙 → 仲裁）
	wave_director.event_requested.connect(_on_event_requested)
	EventBus.wave_cleared.connect(_on_wave_cleared_shop_bridge)
	EventBus.wave_cleared.connect(_on_wave_cleared_gold_rush)   # v0.7.0 U5：金币关波末奖励
	# ★ v0.9.0 赐福订阅固定金币关之后（连接序 = 派发序：波末奖励先入账、赐福后开门——A8）
	EventBus.wave_cleared.connect(_on_wave_cleared_blessing)
	# 商店开门请求（WaveDirector BUFFER 间隙 → 仲裁）
	wave_director.shop_requested.connect(_on_shop_requested)
	# 集成包 A：震屏宿主相机（trauma² 偏移在 ⑧ raw 通道应用）+ 主菜单屏
	camera = Camera2D.new()
	camera.name = "Camera"
	camera.position = Vector2(GameConfig.balance.res_logic) * 0.5
	add_child(camera)
	camera.make_current()
	menu_screen = MenuScreen.new()
	menu_screen.name = "MenuScreen"
	add_child(menu_screen)
	menu_screen.setup(registry)                   # v0.8.0：选角表注入（A7 §V18）
	menu_screen.start_requested.connect(start_run)
	# v1.0.0 结晶强化面板（A9）：★menu_screen 之后 add_child → 同层绘制在上遮挡成立；
	# 回写菜单统计行（boot 载档后首刷）
	meta_panel = MetaPanel.new()
	meta_panel.name = "MetaPanel"
	add_child(meta_panel)
	meta_panel.purchase_requested.connect(_on_meta_purchase)
	meta_panel.close_requested.connect(_close_meta_panel)
	menu_screen.meta_requested.connect(_on_meta_requested)
	_refresh_menu_meta()
	# 仲裁订阅（E-16：死亡最高优先 / 升级弹卡排队）
	EventBus.player_died.connect(_on_player_died)
	EventBus.level_up.connect(_on_level_up)


# ── 结晶强化面板流（v1.0.0，A9：仅 MENU 态仲裁——不占状态机迁移） ──
func _on_meta_requested() -> void:
	# 菜单入口申请：仅 MENU 态且存档层就绪可开（互斥由全屏 dim STOP 遮挡保证）
	if state != GameConst.GameStatus.MENU or meta_store == null:
		return
	meta_panel.open(meta_store)


func _on_meta_purchase(p_id: StringName) -> void:
	# 购买仲裁：仅 MENU 态且面板开启；MetaStore.purchase 失败（未知/满级/余额不足）静默拒绝；
	# 成功 → 面板全量刷新 + 菜单统计行回写
	if state != GameConst.GameStatus.MENU or meta_store == null \
			or meta_panel == null or not meta_panel.is_open():
		return
	if not meta_store.purchase(p_id):
		return
	meta_panel.refresh()
	_refresh_menu_meta()


func _close_meta_panel() -> void:
	# 返回钮收起 + 菜单统计行回写（购买后余额/战绩同源）
	if meta_panel != null:
		meta_panel.close()
	_refresh_menu_meta()


func _refresh_menu_meta() -> void:
	# 菜单统计行回写（meta_store 未就绪 → 全 0 占位）
	var summary: Dictionary = {"best_wave": 0, "total_runs": 0, "total_kills": 0, "crystal": 0}
	if meta_store != null:
		summary = meta_store.meta_summary()
	if menu_screen != null:
		menu_screen.set_meta_summary(int(summary.get("best_wave", 0)),
			int(summary.get("total_runs", 0)), int(summary.get("total_kills", 0)),
			int(summary.get("crystal", 0)))


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
	# ⑧ UI 阶段（raw 通道）：跳字 → HUD → Boss 条 → 相机震屏偏移（trauma² 映射应用位）
	popup_manager.tick(p_raw_delta)
	hud.tick(p_raw_delta)
	boss_bar.tick(p_raw_delta)
	_apply_camera_shake()


func _apply_camera_shake() -> void:
	# 集成包 A：CameraShake 纯计算输出 → 相机 transform（headless 无相机也安全）
	if camera == null or game_feel == null or game_feel.shake == null:
		return
	var v := game_feel.shake.offset_and_rotation()
	camera.offset = Vector2(v.x, v.y)
	camera.rotation = v.z


# ── 经验链路（集成包 B.1：击杀掉落 → 磁吸 → 经验 → 升级仲裁 E-16） ──
func _on_enemy_killed_drop_xp(p_enemy: Node2D) -> void:
	# 掉落值真源：Enemy.exp_value（波次通胀已缩放）× 遗物点金手倍率（REL_MIDAS +20%，A3 §5）
	# × (1+K_xp)（v0.7.0 芯片 xp_gain，A6 §3）
	if not (p_enemy is Enemy):
		return                                  # 裸实体探针/非敌事件防御
	# v0.8.0（A7 §V18）：xp 三乘子 = 遗物 × 角色 × (1+K_chip)（顺序冻结；芯片行保持其后）
	var value := (p_enemy as Enemy).exp_value * relic_handler.xp_mult() \
		* player.character_xp_mult()
	if chip_handler != null:
		value *= 1.0 + maxf(chip_handler.stat_bonus(&"xp_gain"), 0.0)
	# v1.0.0（A9）：meta xp 第 4 因子（与芯片 xp_gain 分立防双算；0 级 → ×1.0 恒等）
	if meta_store != null:
		value *= meta_store.xp_mult()
	_spawn_xp_shard(p_enemy.global_position, value)


# ── 芯片掉落（v0.7.0 U6：Boss 击杀 → grant_boss_chip；文本跳字反馈） ──
func _on_enemy_killed_drop_chip(p_enemy: Node2D) -> void:
	# TAG_BOSS 判定（连接序保证 tags 读取先于 spawner 归还清零）→ grant_boss_chip(出生波)。
	# granted → 跳字"芯片 [名] 已装备"；否则转金币（converted_gold 经 _add_gold 入账，
	# 正增量随 K_gold 缩放）+ 跳字"芯片满 → +N 金币"。
	if not (p_enemy is Enemy):
		return                                  # 裸实体探针/非敌事件防御（同 xp/gold 口径）
	var enemy := p_enemy as Enemy
	if (enemy.tags & GameConst.TAG_BOSS) == 0:
		return
	var drop := chip_handler.grant_boss_chip(enemy.spawn_wave())
	var pos := enemy.global_position
	if bool(drop.get("granted")):
		var chip_data := chip_handler.registry.get_chip(
			StringName(String(drop.get("chip_id", "")))) if chip_handler.registry != null else null
		var chip_name := chip_data.display_name if chip_data != null else String(drop.get("chip_id", ""))
		if popup_manager != null:
			popup_manager.show_text_popup(pos + Vector2(0.0, -42.0), "芯片 [%s] 已装备" % chip_name)
	else:
		var gold := int(drop.get("converted_gold", 0))
		if gold > 0:
			_add_gold(gold)
			if popup_manager != null:
				popup_manager.show_text_popup(pos + Vector2(0.0, -42.0), "芯片满 → +%d 金币" % gold)


func _spawn_xp_shard(p_pos: Vector2, p_value: float) -> void:
	if p_value <= 0.0:
		return
	var shard := (pools[&"xp"] as XPPool).acquire()
	if shard == null:
		# 满池合并为大面值碎片（数值守恒，架构 §5.1 XPPool 行）
		if not active_shards.is_empty():
			active_shards[0].merge_value(p_value)
		return
	shard.position = p_pos
	shard.activate(p_value)
	active_shards.append(shard)


func _tick_xp_shards(p_gd: float) -> void:
	# 磁吸/吸收推进（帧序②玩家阶段内；倒序遍历——吸收即归还擦除当前索引安全）
	var idx := active_shards.size() - 1
	while idx >= 0:
		var shard := active_shards[idx]
		if is_instance_valid(shard) and shard.tick(p_gd):
			active_shards.remove_at(idx)
			(pools[&"xp"] as XPPool).release(shard)
		idx -= 1


# ── 金币链路（v0.6.0，A4 §3：击杀掉落 → 磁吸 → 吸收入账） ──────────
func _on_enemy_killed_drop_gold(p_enemy: Node2D) -> void:
	# 掉落公式（A4 §3）：chance = clamp(drop.chance + Σadd_gold_drop, 0, 1) → roll 判定 →
	# base = randi_range(min, max) → amount = round(base × (1 + Σadd_gold_value))。
	# 三层 guard：空 dict / 负值 / 零面值全跳过。
	if not (p_enemy is Enemy):
		return                                  # 裸实体探针/非敌事件防御（与 xp 掉落同口径）
	var enemy := p_enemy as Enemy
	if enemy.data == null or enemy.data.gold_drop.is_empty():
		return                                  # 空段 = 不掉金币（合法）
	var drop := enemy.data.gold_drop
	var min_v := float(drop.get("min", 0.0))
	var max_v := float(drop.get("max", 0.0))
	if min_v < 0.0 or max_v < 0.0:
		return                                  # 负值 guard（校验器 warning 级，掉落侧兜底）
	if max_v < min_v:
		max_v = min_v                           # 坏序防御（randi_range 前提 min ≤ max）
	var chance := clampf(float(drop.get("chance", 0.0)) + _gold_add_sum(&"add_gold_drop")
		+ (curse_handler.gold_drop_bonus() if curse_handler != null else 0.0), 0.0, 1.0)   # v0.8.0 诅咒掉率层
	# v0.7.0 U5：金币关掉率下限 50%（词条正常叠加；非金币关零影响）
	if enemy.gold_rush:
		chance = maxf(chance, 0.5)
	if chance <= 0.0 or _gold_rng.randf() > chance:
		return                                  # 零概率 / roll 未中
	var base := _gold_rng.randi_range(int(min_v), int(max_v))
	var rush_mult := 2.0 if enemy.gold_rush else 1.0   # v0.7.0 U5：金币关面值 ×2
	var amount := int(round(float(base) * rush_mult * (1.0 + _gold_add_sum(&"add_gold_value"))))
	_spawn_gold_coin(enemy.global_position, amount)


func _spawn_gold_coin(p_pos: Vector2, p_value: int) -> void:
	if p_value <= 0:
		return                                  # 零面值 guard
	var coin := (pools[&"gold"] as GoldPool).acquire()
	if coin == null:
		# 满池合并为大面值金币（数值守恒，A4 §3——同 XPPool 降级口径）
		if not active_coins.is_empty():
			active_coins[0].merge_value(p_value)
		return
	coin.position = p_pos
	coin.activate(p_value)
	active_coins.append(coin)


func _tick_gold_coins(p_gd: float) -> void:
	# 磁吸/吸收推进（帧序②内紧随 _tick_xp_shards；倒序遍历——吸收即归还擦除当前索引安全）。
	# ★ 吸收入账在 GameLoop：_add_gold(coin.value) 先于 release（release 清零面值，E-04 契约）
	var idx := active_coins.size() - 1
	while idx >= 0:
		var coin := active_coins[idx]
		if is_instance_valid(coin) and coin.tick(p_gd):
			active_coins.remove_at(idx)
			_add_gold(coin.value)
			(pools[&"gold"] as GoldPool).release(coin)
		idx -= 1


func _add_gold(p_delta: int) -> void:
	# 金币余额唯一写入口（钳 ≥0）→ gold_changed 广播（HUD/商店刷新共源）。
	# v0.7.0（A6 §3）：正增量 ×(1+K_gold)（芯片 gold_gain）；负数消费不缩放。
	var delta := p_delta
	if delta > 0 and chip_handler != null:
		delta = int(round(float(delta) * (1.0 + maxf(chip_handler.stat_bonus(&"gold_gain"), 0.0))))
	gold = maxi(gold + delta, 0)
	EventBus.emit_gold_changed(gold)


func _gold_add_sum(p_pool: StringName) -> float:
	# Σ 全武器 trait_stack.aggregate_panel()[p_pool]（F3 衰减内含；金币侧唯一消费口径，A4 §4）。
	# 〔审查后裁定 2026-09-01〕帧缓存回退：帧号失效口径对"同帧 attach 词条后击杀"的合法
	# 路径返回脏数据（pkg6 冻结用例证实）；正确失效钩子应为 card_chosen/attach_trait 信号，
	# 待实测压力出现再做（PROGRESS §11）。
	var total := 0.0
	if player == null or not is_instance_valid(player):
		return total
	for w in player.weapon_slots:
		if w is WeaponBase and is_instance_valid(w) and w.trait_stack != null:
			total += float(w.trait_stack.aggregate_panel().get(p_pool, 0.0))
	return total


# ── E-10 敌间分离力（软分离防重叠；10Hz + 网格邻域查询） ──────────
func _apply_enemy_separation() -> void:
	if enemy_grid == null:
		return
	var actives := spawner.active
	for i in range(actives.size() - 1, -1, -1):
		var enemy := actives[i] as Enemy
		if enemy == null or enemy.dead:
			continue
		# 邻域查询（网格保守半径超集）；查询缓冲顺序消费后即失效 → 不留存引用
		var neighbors := enemy_grid.query_circle(enemy.global_position, enemy.hitbox_r)
		for j in range(neighbors.size() - 1, -1, -1):
			var other := neighbors[j] as Enemy
			if other == null or other == enemy or other.dead:
				continue
			var delta := enemy.global_position - other.global_position
			var min_d := enemy.hitbox_r + other.hitbox_r
			var d := delta.length()
			if d >= min_d:
				continue
			# 完全重叠（同点）时按敌 uid 定向散开（确定性，无 RNG）
			var dir := delta / d if d >= 0.01 \
				else Vector2.RIGHT.rotated(float(enemy.uid % 16) * TAU / 16.0)
			var push := dir * ((min_d - d) * 0.5)          # 各让一半重叠量
			enemy.global_position += push.limit_length(SEPARATION_MAX_STEP)


# ── 致命配置错误清单屏（§六.2 boot_error 占位；程序化美术） ───────
func _build_boot_error_screen() -> void:
	var layer := CanvasLayer.new()
	layer.name = "BootErrorScreen"
	layer.layer = 100
	add_child(layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	var dim := ColorRect.new()
	dim.color = Color(0.12, 0.02, 0.02, 0.97)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(dim)
	var title := Label.new()
	title.text = "启动失败：致命配置错误"
	title.add_theme_font_size_override("font_size", 30)
	title.position = Vector2(40.0, 320.0)
	root.add_child(title)
	var lines := Label.new()
	var text := ""
	for err in boot_fatal:
		text += String(err) + "\n"
	lines.text = text
	lines.add_theme_font_size_override("font_size", 15)
	lines.position = Vector2(40.0, 400.0)
	root.add_child(lines)


func _reset_run_state() -> void:
	# 重开重置：★ 战场清场（敌/弹/光束/跳字/粒子——残留半血 Boss 原位冻结后会叠进
	# 新波次 1、残留敌弹重生首帧秒杀，审查 Fix 1 Critical）→ 玩家（复活含死亡短路清除/
	# HP/经验/槽位解锁）/ HUD 统计 / 卡牌流 / 顿帧态
	_clear_battlefield()
	# v0.8.0（A7 §V18）：角色应用先于 respawn——max_hp 基线 = respawn → compute_max_hp
	# (char_pct,0,0,0) 公式承载。★ 无条件调用：current_character=null（默认/悬空 id 兜底）时
	# apply_character 内部跳过属性应用但清引用——防上一局角色 char_pct/xp 残留进本局
	player.apply_character(current_character)
	player.respawn()
	for i in range(player.weapon_slots.size()):
		var w: WeaponBase = player.weapon_slots[i] if i < player.weapon_slots.size() else null
		if w != null and is_instance_valid(w):
			w.queue_free()
		player.weapon_slots[i] = null
	player.add_weapon(registry.get_weapon(_starting_weapon_id()))   # v0.8.0：角色感知首发武器
	hud.kills = 0
	hud.wave = 0
	hud.total_damage = 0.0
	hud.run_elapsed = 0.0
	hud.reset_reactions()                         # v0.7.0 U10：反应统计随局清零
	card_generator.owned_relics.clear()
	relic_handler.reset_run()                     # B.2：遗物每场重新获取（owned/常驻位清零）
	chip_handler.reset_run()                      # v0.7.0：芯片每场重新获取（装备/槽位/遥测清零）
	if elemental != null:
		elemental.reset_run()                     # v1.1.0 审查 Critical：反应注册表清零
		                                         #（×1.8 既有缺口 + 精通层跨局残留，XE1 坐实）
	if curse_handler != null:
		# v1.0.0（A9）：meta hpg 注入★先于 reset——reset 内 recompute_max_hp 收口生效
		if meta_store != null:
			curse_handler.meta_hp_flat = meta_store.meta_hp_flat()
		curse_handler.reset_run()                 # v0.8.0：诅咒层数/遥测清零 + max_hp 重导出（A7 §V6）
	if event_director != null:
		event_director.reset_run()                # v0.8.0：事件遥测清零 + rng 重播种（A7 §V2）
	for shard in active_shards:                   # B.1：清场归还经验碎片
		if is_instance_valid(shard):
			(pools[&"xp"] as XPPool).release(shard)
	active_shards.clear()
	for coin in active_coins:                     # v0.6.0：清场归还金币（余额归零 emit，A4 §3）
		if is_instance_valid(coin):
			(pools[&"gold"] as GoldPool).release(coin)
	active_coins.clear()
	_add_gold(-gold)
	if meta_store != null:
		# v1.0.0（A9）①：局外 meta 段注入芯片处理器（先载入，覆盖上一局残留——
		# chip reset_run 有意不清 meta_stats，A9 冻结语义）
		chip_handler.set_meta_stats(meta_store.meta_stats_snapshot())
		# ② 开局金直注入：★不经 _add_gold——greed 不放大开局金（A9 冻结语义）
		var seed_gold := meta_store.starting_gold()
		if seed_gold > 0:
			gold += seed_gold
			EventBus.emit_gold_changed(gold)
	_deferred_shop_wave = 0                       # v0.6.0：暂存商店波清零
	upgrade_cards_dealt = 0                       # v0.7.0 U11：发牌计数随局清零
	if shop_ui != null:
		shop_ui.close()                           # v0.6.0：强制收起商店（重开净化）
	if event_ui != null:
		event_ui.close()                          # v0.8.0：强制收起事件浮层（重开净化）
	_deferred_event_wave = 0                      # v0.8.0：暂存事件清零
	_deferred_event_index = -1
	if blessing_ui != null:
		blessing_ui.close()                       # v0.9.0：强制收起赐福浮层（重开净化）
	_deferred_blessing = false                    # v0.9.0：暂存赐福清零
	if blessing_handler != null:
		blessing_handler.reset_run()              # v0.9.0：赐福 rng 重播种 + 遥测清零（A8）
	if wave_director != null:
		wave_director.reset_extra_shop()          # v0.6.0：黑市追加申请不跨局（与 relic reset 同口径）
		wave_director.reset_event_state()         # v0.8.0：事件 rng 重播种 + 闸复位（A7 §V1）
	_separation_left = SEPARATION_INTERVAL
	pending_level_ups = 0
	game_feel.hit_stop_left = 0.0
	game_feel.hit_stop_active_ms = 0.0
	set_time_scale(1.0, &"reset")
	_settled_this_run = false                    # v1.0.0：结转一次闸随局复位（A9）


func _clear_battlefield() -> void:
	# 残留清场序（审查 Fix 1）：生成队列 → 在场敌（快照遍历归还 EnemyPool）→ 投射物
	#（含敌弹）→ 活跃光束 → 跳字 → 粒子。敌/弹为静默回收：不经 enemy_killed / ON_EXPIRE——
	# 防死亡新星/分裂请求在清场期再结算、防重复击杀计数（非战斗语义归还）；
	# 光束经 _recycle 统一收束（ON_EXPIRE 仅词条派发，无次级结算通道，安全）。
	if spawner != null:
		spawner.spawn_queue.clear()
		for enemy in spawner.active.duplicate():  # 快照遍历（on_enemy_killed 内部 erase active）
			if is_instance_valid(enemy):
				spawner.on_enemy_killed(enemy)    # 活跃表移除 + 元素宿主注销 + 池归还
	for proj in _projectile_pool.active_projectiles().duplicate():
		if is_instance_valid(proj):
			_projectile_pool.release(proj)        # 直接归还（池侧 _reset_state 清零）
	for child in (pools[&"laser"] as LaserBeamPool).get_children():
		var beam := child as LaserBeam
		if beam != null and beam.is_live():
			if beam.weapon != null and is_instance_valid(beam.weapon):
				beam.weapon.active_beams.erase(beam)   # 先摘宿主（防宿主 tick 已归还光束）
			beam._recycle()                       # 统一收束：ON_EXPIRE → 清零 → 池归还
	if popup_manager != null:
		popup_manager.clear_all()
	(pools[&"particle"] as ParticlePool).release_active_all()

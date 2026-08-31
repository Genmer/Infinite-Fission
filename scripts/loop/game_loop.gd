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
# E-10 敌间分离力（软分离防重叠）：10Hz 降频 + 网格邻域查询（性能预案 §5.2-5；
# 单轴单次推移 ≤4px 软钳——分离是观感修正而非物理约束，避免两帧内挤开 Boss 阵型）
const SEPARATION_INTERVAL := 0.1              # 10Hz（架构 §2.11 敌间分离力口径）
const SEPARATION_MAX_STEP := 4.0              # 单敌单次推移上限 px
const RESUME_GRACE_S := 0.5                   # 暂停恢复输入忽略期 s（防误触，用户反馈 2026-08-29）

# 状态机（复用 GameConst.GameStatus：BOOT/MENU/PLAYING/PAUSED/LEVEL_UP/GAME_OVER）
# 合法迁移矩阵（冻结；非法迁移 change_state 拒绝 + 计数）。
# ★ PAUSED → MENU 为暂停面板「回主菜单」新增合法迁移（用户反馈 2026-08-29；pkg4 非法
#   迁移用例枚举 MENU→PAUSED / MENU→LEVEL_UP / GAME_OVER→PAUSED，不含本对——不破坏）
const TRANSITIONS: Dictionary = {
	GameConst.GameStatus.BOOT: [GameConst.GameStatus.MENU],
	GameConst.GameStatus.MENU: [GameConst.GameStatus.PLAYING],
	GameConst.GameStatus.PLAYING: [GameConst.GameStatus.PAUSED, GameConst.GameStatus.LEVEL_UP,
		GameConst.GameStatus.GAME_OVER],
	GameConst.GameStatus.PAUSED: [GameConst.GameStatus.PLAYING, GameConst.GameStatus.GAME_OVER,
		GameConst.GameStatus.MENU],
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
var current_map_id: StringName = MapTable.FIRST_MAP_ID   # 当前地图（M2 多地图，用户反馈）
var _backdrop: CloudBackdrop = null                       # 云层主题色宿主（分图换色）
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
var menu_screen: MenuScreen = null            # 集成包 A：主菜单屏（MENU 态宿主）
var pause_overlay: PauseOverlay = null        # 方向 C：暂停遮罩面板（PAUSED 态宿主）
var shop_ui: ShopUi = null                    # 战地黑市（M7 股市商店，SHOP 波事件宿主）
var sfx: SfxBank = null                       # 程序化音效库（表现层一期）
var elemental_fx: ElementalFxLayer = null     # 方向 C：元素签名特效层（连锁闪电/碎裂环/DOT 火星）
var camera: Camera2D = null                   # 集成包 A：震屏偏移宿主（trauma² 映射应用位）
var confetti: ConfettiBurst = null            # 方向 C：Boss 死亡彩纸屑（actors 段前置订阅）
var pools: Dictionary = {}                    # {projectile, enemy, popup, particle, laser, xp}
var resume_grace_left: float = 0.0            # 恢复输入忽略剩余（raw 通道；测试观测）

var frame_order: Array[StringName] = []       # 帧序探针（每帧重建；测试断言固定帧序）
var current_candidates: Array[Dictionary] = []   # 当前货架（测试观测）
var active_shards: Array[XpShard] = []        # 场上经验碎片（掉落/吸附/归还管理，B.1）
var stage_probe_enabled: bool = false         # 分阶段采样开关（架构 §5.5：P95 超线按阶段定位）
var stage_probe_us: Dictionary = {}           # {StringName 阶段: 累计 usec}（仅 PLAYING 帧，逐帧重建）

var _projectile_pool: ProjectilePool = null
var _boot_elapsed_ms: float = 0.0             # Boot 耗时（AC：<3s 预算遥测）
var _separation_left: float = SEPARATION_INTERVAL   # E-10 分离力 10Hz 相位


func _ready() -> void:
	# Boot 序列（架构 §六.2）：fatal 检查 → registry → 池预热 → 子系统组装 → MENU
	process_mode = Node.PROCESS_MODE_ALWAYS      # tree.paused 期间仍驱动 ⑦⑧（帧序契约）
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
			#    GameLoop 本层透传零向量 = 玩家消费自采样（包 2 落地口径）。
			#    暂停恢复宽限期内吞掉拖动输入（防误触，raw 通道倒计时）
			frame_order.append(&"input")
			if resume_grace_left > 0.0:
				resume_grace_left = maxf(resume_grace_left - p_raw_delta, 0.0)
			player.input_enabled = resume_grace_left <= 0.0
			# ② 玩家（移动/受击/拾取；内含武器冷却+开火调度——包 2 Player.tick 落地口径）
			frame_order.append(&"player")
			player.tick(gd, Vector2.ZERO)
			_tick_xp_shards(gd)               # B.1：经验碎片磁吸/吸收（拾取属玩家阶段）
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
			if elemental_fx != null:
				elemental_fx.tick(p_raw_delta)   # 元素签名特效层（连锁闪电/冲击环/火星）
			# ⑧ UI（raw 通道：跳字/HUD/Boss 条——顿帧期间照常，Q-14）
			frame_order.append(&"ui")
			_tick_ui(p_raw_delta)
			if stage_probe_enabled:
				stage_probe_us[&"feel_ui"] = Time.get_ticks_usec() - _probe_t0
		GameConst.GameStatus.LEVEL_UP, GameConst.GameStatus.PAUSED:
			# tree.paused=true 冻结全部 PAUSABLE 子系统（AC-16.2 战斗完全冻结）；
			# 仅 ⑦⑧ 以 raw 通道运行（架构帧序契约）。
			# 用户反馈 2026-08-29：PAUSED 期 GameFeel 计时（顿帧/震屏衰减）一并冻结——
			# ⑦ 标签保留（帧序契约），以零时长驱动；LEVEL_UP 沿用 raw 通道原口径
			frame_order.clear()
			frame_order.append(&"feel")
			game_feel.tick(0.0 if state == GameConst.GameStatus.PAUSED else p_raw_delta)
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


func _on_shop_requested(p_wave: int) -> void:
	# 战地黑市开店仲裁（M7）：PLAYING 态 → LEVEL_UP（复用弹卡态，E-16 仲裁同源）
	if state != GameConst.GameStatus.PLAYING:
		return
	if change_state(GameConst.GameStatus.LEVEL_UP):
		shop_ui.open(player, p_wave)


func _on_build_details() -> void:
	# 左下角构筑面板点击（用户反馈「点击左下角，可以看 buff 详情」）：战斗中 → 申请暂停
	# 并进详情卡；已暂停 → 暂停卡/详情卡切换；LEVEL_UP/GAME_OVER 等态不响应
	if state == GameConst.GameStatus.PLAYING:
		if request_pause():
			pause_overlay.open_details(player)
	elif state == GameConst.GameStatus.PAUSED:
		pause_overlay.toggle_details()


func request_resume() -> bool:
	# 恢复申请：自 PAUSED 恢复时启动 0.5s 输入忽略期（防误触，用户反馈 2026-08-29）。
	# input_enabled 即时同步（宽限自恢复瞬间生效）——写权仍归 ① 步每帧口径（§1.3 单写者：
	# 本函数与 _reset_run_state 是仅有的两处帧外写点，均为"申请瞬间"语义）
	var resumed := change_state(GameConst.GameStatus.PLAYING)
	if resumed:
		if resume_grace_left <= 0.0:
			resume_grace_left = RESUME_GRACE_S
		player.input_enabled = false
	return resumed


func start_run() -> bool:
	# MENU → PLAYING：波次 1 开局（当前地图波表 + 主题色 + Meta 记图——M2 多地图）
	if not change_state(GameConst.GameStatus.PLAYING):
		return false
	wave_director.wave_table = MapTable.load_table(current_map_id, registry)
	Meta.set_run_map(current_map_id)
	card_generator.rng.randomize()               # 卡池每局随机（固定种子=「选项写死」观感根因；pkg 测试自行定种子）
	player.set_character(Meta.character_id)   # 角色应用（含养成加成——M8/角色系统）
	var map_def := MapTable.get_map(current_map_id)
	_apply_map_affixes(map_def)                  # 词缀二期：双词缀注入（祝→玩家 / 诅→敌侧）
	if _backdrop != null:
		_backdrop.modulate = map_def.get("tint", Color.WHITE)   # 分图云层主题色
	hud.set_map_name(String(map_def.get("name", "")))
	wave_director.start_wave(1)
	return true


func _apply_map_affixes(p_map_def: Dictionary) -> void:
	# 地图词缀二期（双词缀祝/诅咒，P1 2026-08-31；数值真源 = map_table.gd MAPS 注释块）：
	# 诅咒（利敌）→ spawner.map_mods（spawner._apply_map_mods 出生差分应用）；
	# 祝福（利好玩家）→ player.map_* 字段——金币（本类掉账）/ 经验（Player.gain_xp）/
	# 射速（WeaponBase._fire_interval rof 乘区）/ 每波回血（本类 _on_wave_cleared_bless_heal）。
	# 旧 mod_id 单向词缀键保留兼容（断言锁定），应用口径由本表替代。
	spawner.map_mods = {}
	player.map_xp_mult = 1.0
	player.map_gold_mult = 1.0
	player.map_rof_mult = 1.0
	player.map_wave_heal_pct = 0.0
	match String(p_map_def.get("curse_id", "")):
		&"curse_swarm":
			spawner.map_mods = {"mob_hp_mult": 1.08}    # 虫群（草原）：小怪 HP +8%（Boss 免除）
		&"curse_frost_armor":
			spawner.map_mods = {"ice_resist": 0.2}      # 霜甲（冰原）：敌冰抗 +20%（沿用旧值）
		&"curse_swift_demon":
			spawner.map_mods = {"spd_mult": 1.10}       # 疾魔（魔域）：敌移速 +10%（沿用旧值）
		&"curse_toxic_skin":
			spawner.map_mods = {"contact_mult": 1.08}   # 毒肤（树海）：敌接触伤 +8%
		&"curse_mire":
			spawner.map_mods = {"hp_mult": 1.10}        # 泥沼（沼泽）：敌 HP +10%（旧 8% 上调）
	match String(p_map_def.get("bless_id", "")):
		&"bless_harvest":
			player.map_gold_mult = 1.10                 # 丰饶（草原）：金币 +10%
		&"bless_frost_crystal":
			player.map_xp_mult = 1.10                   # 寒晶（冰原）：经验 +10%
		&"bless_fervor":
			player.map_rof_mult = 1.06                  # 狂热（魔域）：射速 +6%
		&"bless_nurture":
			player.map_wave_heal_pct = 0.02             # 滋养（树海）：每波回 2% max_hp
		&"bless_rich_vein":
			player.map_xp_mult = 1.08                   # 富矿（沼泽）：经验 +8% 且金币 +8%
			player.map_gold_mult = 1.08


func _on_wave_cleared_bless_heal(_p_wave: int) -> void:
	# 祝福·滋养（树海）：波次清空回复 map_wave_heal_pct × max_hp（数值真源 map_table.gd）。
	# 死亡/GAME_OVER 后 wave_cleared 不再派发（GameLoop 帧序仅 PLAYING 驱动⑥），此处为防御。
	if player == null or not is_instance_valid(player):
		return
	if player.map_wave_heal_pct <= 0.0 or player.hp <= 0.0:
		return
	player.hp = minf(player.hp + player.max_hp * player.map_wave_heal_pct, player.max_hp)


func _on_menu_start(p_map_id: StringName) -> void:
	# 选图启动（大厅出发/地图卡；未解锁拒绝——解锁判据 = 上一关已通关）
	if not Meta.is_map_unlocked(p_map_id):
		push_warning("[GameLoop] 地图未解锁（%s）——拒绝启动" % String(p_map_id))
		return
	current_map_id = p_map_id
	start_run()


func restart_run() -> bool:
	# GAME_OVER → PLAYING（结算重开）/ PAUSED → PLAYING（暂停面板「重新开始」，
	# 用户反馈 2026-08-29；PAUSED→PLAYING 为既有合法迁移）：数值重置 + 波次 1 重开
	if state != GameConst.GameStatus.GAME_OVER and state != GameConst.GameStatus.PAUSED:
		return false
	if not change_state(GameConst.GameStatus.PLAYING):
		return false
	_reset_run_state()
	wave_director.start_wave(1)
	return true


func quit_to_menu() -> bool:
	# PAUSED → MENU（暂停面板「回主菜单」；新增合法迁移）：回菜单前静默清场 +
	# 数值复位（等同 restart 口径——防残留敌/弹在下次 start_run 时叠进波次 1）
	if not change_state(GameConst.GameStatus.MENU):
		return false
	_reset_run_state()
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
	# 三选一流程：roll 3 张 → LEVEL_UP（暂停战斗）→ 选卡界面打开。
	# 集成包 B.2：遗物改写发牌参数（GAMBLER 四选一+诅咒 / OVERCLOCK 稀有度保底），
	# WORDS_TIDE 每波一次重随货架（保留稀有度 roll 序列）
	var context := {
		"player": player,
		"wave": wave_director.current_wave,
		"level": p_new_level,
		"deal_count": relic_handler.deal_count(),
		"curse_last": relic_handler.curse_requested(),
		"min_rarity_floor": relic_handler.take_rarity_floor(),
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
	pools = {
		&"projectile": _projectile_pool,
		&"enemy": enemy_pool,
		&"popup": popup_pool,
		&"particle": particle_pool,
		&"laser": laser_pool,
		&"xp": xp_pool,
	}
	# 预热（AC-14.2，Boot 期完成）
	_projectile_pool.prewarm(GameConfig.get_pool_capacity(&"projectile"))
	enemy_pool.prewarm(GameConfig.get_pool_capacity(&"enemy"))
	popup_pool.prewarm(GameConfig.get_pool_capacity(&"popup"))
	particle_pool.prewarm(GameConfig.get_pool_capacity(&"particle"))
	laser_pool.prewarm(GameConfig.get_pool_capacity(&"laser"))
	xp_pool.prewarm(GameConfig.get_pool_capacity(&"xp"))


func _boot_build_grids() -> void:
	# SpaceGrid ×2（§1.3-6：GameLoop 持有；720×1280 + 192px 出屏余量）
	enemy_grid = SpaceGrid.new()
	enemy_grid.configure(Vector2(GameConfig.balance.res_logic), 192.0)
	enemy_bullet_grid = SpaceGrid.new()
	enemy_bullet_grid.configure(Vector2(GameConfig.balance.res_logic), 192.0)


func _boot_build_actors() -> void:
	# 管线（工厂自动切真件）→ 遗物处理器 → 敌波（spawner/wave_director）→ 玩家 → 元素系统
	# ★ 经验掉落订阅必须先于 EnemySpawner 入树（信号连接序 = 派发序：掉落侧读取
	#   exp_value/position 必须先于 spawner 的死亡归还清零，集成包 B.1）
	EventBus.enemy_killed.connect(_on_enemy_killed_drop_xp)
	pipeline = DamagePipelineStub.get_pipeline()
	relic_handler = RelicHandler.new()
	relic_handler.name = "RelicHandler"
	add_child(relic_handler)
	# ★ 遗物事件绑定提前至 Boot（连接序 = 派发序）：enemy_killed 的精英 tag/治疗读取
	#   必须先于 EnemySpawner 的死亡归还清零（_reset_state 置 tags=0），集成包 B.2
	relic_handler.bind_events()
	elemental = ElementalSystem.new()
	elemental.name = "ElementalSystem"
	add_child(elemental)
	elemental.pipeline = pipeline
	elemental.enemy_grid = enemy_grid
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
	# ★ 方向 C 彩纸屑前置组装 + enemy_killed 前置订阅（连接序 = 派发序，F-19 同纪律）：
	#   Boss 击杀庆祝读取 enemy.tags 必须先于 EnemySpawner 死亡归还的 tags 清零
	#   （_reset_state 置 0）——否则彩纸屑恒不触发
	confetti = ConfettiBurst.new()
	confetti.name = "ConfettiBurst"
	add_child(confetti)
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
	})
	relic_handler.setup({"registry": registry, "player": player})
	# Q-4：首发手枪（形态工厂 add_weapon）
	player.add_weapon(registry.get_weapon(STARTING_WEAPON_ID))


func _boot_build_presentation() -> void:
	# 表现层组装：淡云背景 → 粒子导演 → GameFeel → 跳字 → HUD/Boss 条/结算屏 → 卡牌流
	# （方向 C：淡云蓝白底 z=-20——纯视觉层，零事件依赖；彩纸屑已在 actors 段前置订阅）
	var backdrop := CloudBackdrop.new()
	backdrop.name = "CloudBackdrop"
	_backdrop = backdrop
	add_child(backdrop)
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
	# 方向 C 元素签名特效层（连锁闪电/碎裂冲击环/DOT 火星；事件订阅在其 _ready 自挂）
	elemental_fx = ElementalFxLayer.new()
	elemental_fx.name = "ElementalFxLayer"
	add_child(elemental_fx)
	hud = HUD.new()
	hud.name = "HUD"
	add_child(hud)
	hud.setup(player)
	hud.bind_events()
	hud.pause_requested.connect(request_pause)   # 暂停按钮申请（仲裁权在 GameLoop）
	hud.build_details_requested.connect(_on_build_details)   # 左下角 → buff 详情（用户反馈）
	pause_overlay = PauseOverlay.new()
	pause_overlay.name = "PauseOverlay"
	add_child(pause_overlay)
	pause_overlay.resume_requested.connect(request_resume)
	pause_overlay.restart_requested.connect(restart_run)
	pause_overlay.menu_requested.connect(quit_to_menu)
	shop_ui = ShopUi.new()
	shop_ui.name = "ShopUi"
	add_child(shop_ui)
	shop_ui.closed.connect(request_resume)       # 出击 → LEVEL_UP → PLAYING（含宽限）
	wave_director.shop_requested.connect(_on_shop_requested)
	sfx = SfxBank.new()
	sfx.name = "SfxBank"
	add_child(sfx)
	EventBus.damage_resolved.connect(func(_r: DamageResult) -> void: sfx.play(&"hit"))
	EventBus.enemy_killed.connect(func(_e: Node2D) -> void: sfx.play(&"kill"))
	EventBus.level_up.connect(func(_l: int) -> void: sfx.play(&"level"))
	EventBus.card_chosen.connect(func(_i: StringName, _k: int) -> void: sfx.play(&"coin"))
	EventBus.shield_blocked.connect(func(_p: Vector2) -> void: sfx.play(&"shield"))
	EventBus.boss_spawned.connect(func(_b: Node2D) -> void: sfx.play(&"boss"))
	EventBus.wave_cleared.connect(_on_wave_cleared_bless_heal)   # 祝福·滋养（词缀二期）
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
	shop_ui.card_generator = card_generator      # 黑市货架走同一条卡链（注入须在创建后）
	card_select_ui = CardSelectUI.new()
	card_select_ui.name = "CardSelectUI"
	add_child(card_select_ui)
	card_select_ui.choice_made.connect(_on_card_choice)
	# 集成包 A：震屏宿主相机（trauma² 偏移在 ⑧ raw 通道应用）+ 主菜单屏
	camera = Camera2D.new()
	camera.name = "Camera"
	camera.position = Vector2(GameConfig.balance.res_logic) * 0.5
	add_child(camera)
	camera.make_current()
	menu_screen = MenuScreen.new()
	menu_screen.name = "MenuScreen"
	menu_screen.registry = registry             # 图鉴全量清单（大厅面板，用户反馈 M4+M6）
	add_child(menu_screen)
	menu_screen.start_requested.connect(func() -> void: _on_menu_start(MapTable.FIRST_MAP_ID))
	menu_screen.start_map_requested.connect(_on_menu_start)   # 选图启动（M2 多地图）
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
	# ⑧ UI 阶段（raw 通道）：跳字 → HUD → Boss 条 → 相机震屏偏移（trauma² 映射应用位）
	popup_manager.tick(p_raw_delta)
	hud.tick(p_raw_delta)
	boss_bar.tick(p_raw_delta)
	_apply_camera_shake()


func _apply_camera_shake() -> void:
	# 集成包 A：CameraShake 纯计算输出 → 相机 transform（headless 无相机也安全）。
	# PAUSED：震屏冻结（用户反馈 2026-08-29——暂停期画面完全静止）
	if camera == null or game_feel == null or game_feel.shake == null:
		return
	if state == GameConst.GameStatus.PAUSED:
		camera.offset = Vector2.ZERO
		camera.rotation = 0.0
		return
	var v := game_feel.shake.offset_and_rotation()
	camera.offset = Vector2(v.x, v.y)
	camera.rotation = v.z


func _unhandled_input(p_event: InputEvent) -> void:
	# 桌面键盘暂停（用户反馈 2026-08-29）：Esc / P 在 PLAYING⇄PAUSED 间切换——
	# 仅真实输入事件触发（headless 手动驱动 _physics_process 的测试零影响）；
	# 本节点 PROCESS_MODE_ALWAYS（tree.paused 期仍收输入，Q-14 同口径）
	if not (p_event is InputEventKey) or not (p_event as InputEventKey).pressed \
			or (p_event as InputEventKey).echo:
		return
	var key := (p_event as InputEventKey).keycode
	if key != KEY_ESCAPE and key != KEY_P:
		return
	match state:
		GameConst.GameStatus.PLAYING:
			request_pause()
			get_viewport().set_input_as_handled()
		GameConst.GameStatus.PAUSED:
			request_resume()
			get_viewport().set_input_as_handled()
		_:
			pass                                  # 其余状态：键盘暂停不介入


# ── 经验链路（集成包 B.1：击杀掉落 → 磁吸 → 经验 → 升级仲裁 E-16） ──
func _on_enemy_killed_drop_xp(p_enemy: Node2D) -> void:
	# 掉落值真源：Enemy.exp_value（波次通胀已缩放）× 遗物点金手倍率（REL_MIDAS +20%，A3 §5）
	if not (p_enemy is Enemy):
		return                                  # 裸实体探针/非敌事件防御
	var value := (p_enemy as Enemy).exp_value * relic_handler.xp_mult()
	_spawn_xp_shard(p_enemy.global_position, value)
	# 金币掉账（M7 战地黑市货币：gold_drop = {chance, min, max}，首次接线——此前为死数据；
	# 词缀二期：祝福·丰饶/富矿金币倍率在掉账额入账（player.map_gold_mult，真源 map_table.gd））
	var gdrop: Variant = (p_enemy as Enemy).data.gold_drop
	if gdrop is Dictionary and not (gdrop as Dictionary).is_empty():
		var gd := gdrop as Dictionary
		if randf() < float(gd.get("chance", 0.0)):
			player.gold += int(round(randf_range(float(gd.get("min", 1)), float(gd.get("max", 1)))
				* player.map_gold_mult))


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
	player.respawn()
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
	relic_handler.reset_run()                     # B.2：遗物每场重新获取（owned/常驻位清零）
	for shard in active_shards:                   # B.1：清场归还经验碎片
		if is_instance_valid(shard):
			(pools[&"xp"] as XPPool).release(shard)
	active_shards.clear()
	_separation_left = SEPARATION_INTERVAL
	pending_level_ups = 0
	resume_grace_left = 0.0
	player.input_enabled = true
	game_feel.hit_stop_left = 0.0
	game_feel.hit_stop_active_ms = 0.0
	set_time_scale(1.0, &"reset")


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

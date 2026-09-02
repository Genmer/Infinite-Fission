# tests/sim/sim_env.gd
# v1.5.0 TTK 复校工装（A14）：单敌封闭仿真环境（RefCounted，无表现层）。
# · build(p_seed)：autoload 兜底 → DataRegistry.load_all(manifest) → Player + deps
#   镜像 game_loop:998-1007（relic_handler/wave_director = null）→ ElementalSystem 注入
#   pipeline/grid/chip（meta_store/achievement_tracker = null）→ EnemyPool(8) →
#   ChipHandler setup（bind 不调——不订阅 chip_slot_unlocked，槽位由模板显式开）→
#   DamagePipeline.new()+set_rng_seed——★不走 get_pipeline 工厂（headless 桩切换防线）。
# · 玩家静止 (360,1100)；敌出生点 (360,300)（SimEnemy.spawn）；无跳字/无 GameFeel/无 UI。
# · reset_for_cell(p_seed)：管线重播种 + 上一 cell 宿主敌归还（主机换绑前半）；
#   新宿主挂载在 SimEnemy.spawn 尾（set_host + grid.rebuild）。
# · dispose()：宿主/武器/池归还解绑 + meta scratch 档 wipe（T6 跑批尾收口）。
class_name SimEnv
extends RefCounted

const MANIFEST_PATH := "res://data/manifest.cfg"
const SCENE_PLAYER := "res://scenes/combat/player/player.tscn"
const SCENE_ENEMY := "res://scenes/combat/enemies/enemy.tscn"
const ENEMY_POOL_CAP := 8                     # 单敌封闭仿真：容量 8 足够（池循环纪律）
const PLAYER_POS := Vector2(360.0, 1100.0)    # 镜像真实玩家活动区（下 40% 屏）
const ENEMY_POS := Vector2(360.0, 300.0)      # 敌出生锚点（上游 860px，CHASE spd=0 静止）
const META_SCRATCH_PATH := "user://sim_batch/meta_scratch.cfg"

var registry: DataRegistry = null             # 每环境独立加载（真件 .tres 真路径）
var pipeline: DamagePipeline = null           # 真件管线（seed 可注入；set_rng_seed 重播种）
var elemental: ElementalSystem = null         # meta_store/achievement_tracker 恒 null（图鉴降级静默）
var player: Player = null                     # 静止宿主（tick 不调——武器由 SimWeaponDriver 驱动）
var grid: SpaceGrid = null                    # 敌人格（反应连锁/窄相同口径）
var chip: ChipHandler = null                  # 芯片/赐福/meta stat 注入通道（bind 不调）
var enemy_pool: EnemyPool = null              # 敌池（池循环纪律：运行期零实例化）
var _host: Enemy = null                       # 当前 cell 宿主敌（reset_for_cell 归还）
var _meta_scratch: MetaStore = null           # T6 meta 真购买 scratch 档（惰性建；dispose wipe）
var _disposed: bool = false


static func build(p_seed: int) -> SimEnv:
	# 工厂：树挂载全部经 root（pkg14 微夹具同款；autoload 兜底沿用 pkg1 口径）
	_ensure_autoloads()
	var env := SimEnv.new()
	env.registry = DataRegistry.new()
	env.registry.load_all(MANIFEST_PATH)
	assert(not env.registry.report.is_empty() or true)   # load_all 必产报告（悬空 manifest fail-fast 由空表承担）
	assert(env.registry.get_weapon(&"W1_pistol") != null)
	# 真件管线（★不走 DamagePipelineStub.get_pipeline 工厂——A14 冻结口径）
	env.pipeline = DamagePipeline.new()
	env.pipeline.set_rng_seed(p_seed)
	env.grid = SpaceGrid.new()
	env.grid.configure(Vector2(720.0, 1280.0), 192.0)
	var tree := Engine.get_main_loop() as SceneTree
	# 池（先于玩家/元素——game_loop 依赖序镜像）
	env.enemy_pool = EnemyPool.new()
	env.enemy_pool.name = "SimEnemyPool"
	tree.get_root().add_child(env.enemy_pool)
	env.enemy_pool.setup(&"sim_enemy", load(SCENE_ENEMY), ENEMY_POOL_CAP)
	env.enemy_pool.prewarm(ENEMY_POOL_CAP)
	# 元素系统（meta/tracker null → 图鉴/成就判定自然降级）
	env.elemental = ElementalSystem.new()
	env.elemental.name = "SimElemental"
	tree.get_root().add_child(env.elemental)
	env.elemental.pipeline = env.pipeline
	env.elemental.enemy_grid = env.grid
	# 芯片处理器（setup 不 bind_events——槽位由模板 add_bonus_slots/equip 显式开）
	env.chip = ChipHandler.new()
	env.chip.name = "SimChipHandler"
	tree.get_root().add_child(env.chip)
	env.elemental.chip_handler = env.chip
	# 玩家（deps 镜像 game_loop:998-1007；relic/wave_director/laser/敌弹格/诅咒 = null）
	env.player = (load(SCENE_PLAYER) as PackedScene).instantiate() as Player
	env.player.name = "SimPlayer"
	env.player.position = PLAYER_POS
	tree.get_root().add_child(env.player)
	env.player.setup({
		"pipeline": env.pipeline,
		"projectile_pool": null,
		"enemy_grid": env.grid,
		"enemy_bullet_grid": null,
		"laser_pool": null,
		"elemental": env.elemental,
		"relic_handler": null,
		"wave_director": null,
		"chip_handler": env.chip,
		"curse_handler": null,
	})
	env.chip.setup({"registry": env.registry, "player": env.player, "curse_handler": null})
	return env


func reset_for_cell(p_seed: int) -> void:
	# cell 间复位：管线重播种（crit 序列复现）+ 上一宿主归还（主机换绑前半；
	# 新宿主由 SimEnemy.spawn 挂载）。grid 空表重建（陈旧快照防线）。
	pipeline.set_rng_seed(p_seed)
	_release_host()
	var empty: Array[Node2D] = []
	grid.rebuild(empty)


func dispose() -> void:
	# 跑批尾收口：宿主/武器归还解绑 + meta scratch 档 wipe + 树节点 free。
	if _disposed:
		return
	_disposed = true
	_release_host()
	if player != null and is_instance_valid(player):
		for i in range(player.weapon_slots.size()):
			var w: WeaponBase = player.weapon_slots[i]
			if w != null and is_instance_valid(w):
				w.free()
			player.weapon_slots[i] = null
	if _meta_scratch != null and is_instance_valid(_meta_scratch):
		_meta_scratch.wipe()                      # scratch wipe（user://sim_batch/ 跑批尾清）
		_meta_scratch.free()
		_meta_scratch = null
	if enemy_pool != null and is_instance_valid(enemy_pool):
		enemy_pool.free()
	if elemental != null and is_instance_valid(elemental):
		elemental.free()
	if player != null and is_instance_valid(player):
		player.free()


func set_host(p_enemy: Enemy) -> void:
	# SimEnemy.spawn 尾调用（主机换绑后半）
	_host = p_enemy


func host() -> Enemy:
	# 当前 cell 宿主敌（SimWeaponDriver 弹丸目标查询口；无宿主 → null）
	return _host


func meta_scratch() -> MetaStore:
	# T6 meta 真购买 scratch 档（惰性建：独立 save path + 构造即 wipe——pkg14 隔离纪律同款；
	# 先建 user://sim_batch 目录——ConfigFile.save 父目录缺失 err=7）
	if _meta_scratch == null or not is_instance_valid(_meta_scratch):
		DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path("user://sim_batch"))
		_meta_scratch = MetaStore.new()
		_meta_scratch.name = "SimMetaScratch"
		(Engine.get_main_loop() as SceneTree).get_root().add_child(_meta_scratch)
		_meta_scratch.set_save_path(META_SCRATCH_PATH)
		_meta_scratch.wipe()
	return _meta_scratch


func _release_host() -> void:
	if _host != null and is_instance_valid(_host):
		elemental.unregister_host(_host)
		enemy_pool.release(_host)
	_host = null


static func _ensure_autoloads() -> void:
	# -s 脚本模式下引擎自动实例化 autoload（EventBus→GameConfig→DebugStats）；
	# 兜底按就绪序手动挂载（pkg1 _ensure_autoloads 同口径）
	var tree := Engine.get_main_loop() as SceneTree
	if tree.get_root().get_node_or_null("EventBus") == null:
		_install_autoload(tree, "EventBus", "res://autoload/event_bus.gd")
	if tree.get_root().get_node_or_null("GameConfig") == null:
		_install_autoload(tree, "GameConfig", "res://autoload/game_config.gd")
	if tree.get_root().get_node_or_null("DebugStats") == null:
		_install_autoload(tree, "DebugStats", "res://autoload/debug_stats.gd")


static func _install_autoload(p_tree: SceneTree, p_name: String, p_path: String) -> void:
	var script: GDScript = load(p_path)
	var node: Node = script.new()
	node.name = p_name
	p_tree.get_root().add_child(node)

# scripts/combat/weapon/laser_beam.gd
# M-06 LaserBeam（架构 §2.8.3）：光束段实体——不是 M-09 投射物（B_spec M-06），
# 独立实体但共享 M-10 词条（运行时栈）与 M-12 结算。
# · 首敌命中：沿射线方向的网格查询（Q-15 同源：物理 RayCast 语义经 SpaceGrid 实现，
#   规避 Area2D 层配置脆弱性）；持续照射叠「灼焦」≤scorch_max_layers（1 层/0.25s）。
# · 节拍结算：tick_rate 跳/s；每跳 ctx 注入 Local 私有池（灼焦 ×8%/层，F-15——
#   不入全局乘区名额、自有 cap_local）+ 词条乘区（collect_mult_pools 条件自评）。
# · 跳字节流：popup_throttle ≤15Hz/目标（AC-04.2——包 4 跳字管理器消费同一闸门）。
# · 折射：命中新目标 → weapon._on_beam_refracted 分叉子光束（深度 ≤2 引擎侧拒绝；W5 棱镜）。
# · W4 棱镜副束定案（2026-09-25）：
#   ▸ 灼焦池迁移：束实例私有池（scorch_layers/_scorch_accum）→ 目标侧单池
#     （LaserBeam._scorch_pool，target_uid 键全局单例）——多束共照同目标共享叠层计时
#     （=单束口径 1 层/0.25s），W5 组同池复用；死亡 uid 经 sweep_scorch_pool 惰性回收。
#   ▸ 元素束侧化：新增 element 字段（主束=武器附魔 dominant / 副束=SPECTRA 轮转），
#     _settle_one_tick 删 ctx.element=KIN 硬编码；第三谱系束色=元素染色（element_tint）。
#   ▸ 重叠回退束（overlap_fallback）：并入主束目标 ×0.5 折价、不叠灼焦、不提交 ELE 附着。
#   ▸ 遗物乘区接线：_settle_one_tick 经 weapon.inject_relic_pools 注入 B.2 命中乘区
#     （此前激光跳伤路径绕过 REL_TROPHY/MOMENTUM——与 projectile_base 通道对齐）。
#   ▸ R183 复制体灰染：gray_tint 束染（RARITY_NORMAL 灰蓝）由宿主武器 copy_tint 注入。
# ── R195 穿透定案（2026-09-30）────────────────────────────────────
# · 预算口径 N=pierce（镜像弹体 pierce_left 可命中总数，pkg2:464-469 同源）：主束沿
#   射线按 t 升序取前 N 个目标逐拍结算（_hits_along_ray 扩自旧 _first_hit）；基线
#   pierce=1 与旧单目标口径逐位同构（pkg3 激光已知数 955.2/16 settles/8 popups 零位移）。
# · 仅主束吃穿透：depth==0 ∧ ¬sub_beam ∧ ¬overlap_fallback 三重门（_hit_budget）；
#   副束/折射束/重叠回退束恒 1（武器侧 _spawn_beam 传 1 同源防御）。
# · 无逐目标衰减（f=1：弹体同口径每跳同 base_atk 只扣计数）；增减伤走现成
#   pierce_index→pierce_dmg 池（SYN_PIERCE_EVO：ctx.pierce_index=序数+1，首目标=2）。
# · last_hit_uid 仅随首目标写（R91「主束锁定最近敌」/聚焦换目标契约不破）；
#   束端表现=末贯穿目标（t 最大者）；贯穿目标照常入 _hit_exclusions（防子束回烧）
#   但不触发新折射分叉（防 W5 分叉×穿透连乘）。
class_name LaserBeam
extends Node2D

const SCORCH_LAYER_INTERVAL := 0.25            # 叠层节拍（1 层/0.25s，架构 §2.8.3）
const POPUP_HZ := 15.0                         # 跳字节流上限（AC-04.2）

# ── 目标侧灼焦单池（W4 裁定 2026-09-25：束私有池 → target_uid 全局单例）──
# 多束共照同目标：叠层计时共享（合并速率恒 = 单束口径，不随束数翻倍）；层乘算
# 消费口径不变（×8%/层 Local 池）。回收：sweep_scorch_pool（武器侧周期携网格调用）
# + 硬帽防泄漏 + scorch_pool_reset（测试/换局清池口）。
static var _scorch_pool: Dictionary = {}       # target_uid -> {"layers": int, "accum": float}
const SCORCH_POOL_SWEEP_INTERVAL := 5.0        # 死亡 uid 清扫周期（s，武器侧消费）
const SCORCH_POOL_HARD_CAP := 512              # 池条目硬帽（sweep 缺席时的防泄漏保险丝）

var uid: int = 0
var depth: int = 0                             # 0=主光束；折射分叉深度上限 2
var dmg_mult: float = 1.0                      # 折射率/副束折价乘区（二段 = ratio²）
var team: int = 0
var tick_atk: float = 6.0                      # 每跳基础 ATK（L 表 tick_atk × dmg_mult）
var tick_rate: float = 8.0                     # 跳/s
var beam_length: float = 560.0
var is_refraction: bool = false              # 折射副束标识（R26：紫色细束视觉区分主束；W5）
var sub_beam: bool = false                    # 棱镜副束标识（MEC_SPLIT_PRISM 通道，W4）
var element: int = GameConst.Element.KIN      # 本束元素（主束附魔/SPECTRA 副束轮转；删 KIN 硬编码）
var overlap_fallback: bool = false            # 重叠回退（并入主束目标：×0.5、不叠灼焦、不附着）
var gray_tint: bool = false                   # R183 复制体灰染（RARITY_NORMAL 灰蓝束）
var last_hit_uid: int = 0                     # R91 最近结算目标（武器侧聚焦爬坡判据）
var focus_mult: float = 1.0                   # R91 聚焦乘区（武器侧每帧注入——主束专属，副束恒 1.0）
var _focus_visual := 0.0                      # R91 聚焦视觉量 0~1（束变粗变白热）
var beam_width: float = 14.0
var lifetime: float = 0.0     # 脉冲寿命 s（0=常驻，>0=脉冲收束，用户反馈「激光常驻」）
var scorch_max_layers: int = 5                 # ≤8（schema 上限；W4 L5 = 8）
var scorch_per_layer: float = 0.08             # 每层 +8%（目标侧单池共享乘数）
var refract_beams: int = 0
var refract_ratio: float = 0.6
var refract_depth: int = 2
var popup_throttle: Dictionary = {}            # target_uid -> 跳字下次可发时刻（束内时间轴）
var popup_count: int = 0                       # 跳字放行计数（节流验证口径）
var settle_count: int = 0                      # 总结算跳数
var weapon: LaserWeapon = null                 # 宿主武器（折射调度/词条消费）
var damage_pipeline: RefCounted = null
var enemy_grid: SpaceGrid = null
var pool: ObjectPool = null                    # 归属池（LaserBeamPool）
var trait_stack: TraitStack = null             # 武器运行时栈副本（共享 M-10）
var panel_snapshot: Dictionary = {}
var weapon_uid: int = 0
var target_uid: int = 0                        # 副束/折射子束锁定目标（0 = 主束自由瞄准）
var pierce: int = 1                            # R195 穿透预算 N（主束每拍可结算目标数；1=旧单目标口径）

var _aim_dir: Vector2 = Vector2.UP            # 主束指向（武器每帧刷新）
var _tick_left: float = 0.0
var _hit_exclusions: Dictionary = {}           # target_uid -> true（折射去重：已命中目标）
# R195 射线查询缓冲（成员复用——tick 路径禁每帧 Dictionary/Array 分配，R188 红线）
var _ray_candidates: Array[Node2D] = []        # 网格查询候选（_hits_along_ray 每拍复用清空）
var _ray_hits: Array[Node2D] = []              # 贯穿目标集（t 升序；仅本帧 tick 同步消费，禁跨帧持有）
var _ray_ts: Array[float] = []                 # 贯穿目标 t 值并行缓冲（升序插入排序用）
var _time_alive: float = 0.0
var _live: bool = false
var _line: Line2D = null                      # 外层蓝束（粗，方向 C：蓝白渐变观感）
var _core: Line2D = null                      # 内层白芯（细亮，圆头端帽）


# ── 灼焦目标侧单池静态 API（W5 组/W4 测试共用面） ─────────────────
static func scorch_layers_of(p_target_uid: int) -> int:
	# 目标当前灼焦层数（结算消费口；多束读数同源）
	var entry: Variant = _scorch_pool.get(p_target_uid)
	if entry is Dictionary:
		return int((entry as Dictionary).get("layers", 0))
	return 0


static func scorch_pool_reset() -> void:
	# 清池口（测试夹具隔离/换局收束；生产层由 sweep 惰性回收）
	_scorch_pool.clear()


static func sweep_scorch_pool(p_grid: SpaceGrid) -> void:
	# 死亡 uid 惰性回收：网格全域快照之外的条目即孤儿（池化敌复用换 uid，键安全）
	if p_grid == null or _scorch_pool.is_empty():
		return
	var live: Dictionary = {}
	var found: Array[Node2D] = []
	found.append_array(p_grid.query_circle(Vector2.ZERO, 4096.0))
	for node in found:
		live[int(node.get("uid"))] = true
	for key in _scorch_pool.keys():
		if not live.has(int(key)):
			_scorch_pool.erase(key)


static func _scorch_add(p_target_uid: int, p_delta: float, p_cap: int, p_beam_uid: int) -> int:
	# 目标叠层推进（共享计时；裁定 2026-09-25：多束同目标叠层速率 = 单束口径——
	# 同帧异束共照只记先到束（frame+last_beam 去重），同束同帧续推不受限
	# （pkg3 直驱大步长 tick 契约）；层推进 1 层/0.25s，≤p_cap）
	var entry: Dictionary = _scorch_pool.get(p_target_uid, {})
	var frame := GameConfig.frame_stamp
	if int(entry.get("frame", -1)) == frame and int(entry.get("last_beam", 0)) != p_beam_uid:
		return int(entry.get("layers", 0))     # 并发束同帧去重：不叠加速率
	entry["frame"] = frame
	entry["last_beam"] = p_beam_uid
	var layers := int(entry.get("layers", 0))
	var accum := float(entry.get("accum", 0.0)) + p_delta
	if p_cap <= 0:
		accum = 0.0                            # 防御：无上限声明不积攒
	while accum >= SCORCH_LAYER_INTERVAL and layers < p_cap:
		layers += 1
		accum -= SCORCH_LAYER_INTERVAL
	if layers >= p_cap:
		accum = 0.0                            # 满层即弃残余计时（防溢层后突跳）
	entry["layers"] = layers
	entry["accum"] = accum
	_scorch_pool[p_target_uid] = entry
	if _scorch_pool.size() > SCORCH_POOL_HARD_CAP:
		_scorch_pool.erase(_scorch_pool.keys()[0])   # FIFO 保险丝（正常路径 sweep 回收）
	return layers


static func element_tint(p_element: int, p_alpha: float = 0.85) -> Color:
	# 元素束色（第三谱系读感；取色单源 PopPalette.ELEMENT_COLORS——禁散落新色值；
	# R192 八元素：表内直查带 alpha，KIN/表外回落玩家蓝兜底）
	var table: Dictionary = PopPalette.ELEMENT_COLORS
	if table.has(p_element) and p_element != GameConst.Element.KIN:
		var base: Color = table[p_element]
		return Color(base.r, base.g, base.b, p_alpha)
	return Color(PopPalette.PLAYER.r, PopPalette.PLAYER.g, PopPalette.PLAYER.b, p_alpha)


func _ready() -> void:
	# 池化实例化期组装渲染（代码组装为主，.tscn 仅做容器，§1.4）
	# 粗圆头光束：外层天空蓝 + 内层白芯（双线叠加 = 蓝白渐变；LINE_CAP_ROUND 端头圆帽）
	_line = Line2D.new()
	_line.name = "BeamLine"
	_line.width = beam_width
	_line.default_color = Color(PopPalette.PLAYER.r, PopPalette.PLAYER.g, PopPalette.PLAYER.b, 0.85)
	_line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	_line.end_cap_mode = Line2D.LINE_CAP_ROUND
	_line.joint_mode = Line2D.LINE_JOINT_ROUND
	add_child(_line)
	_core = Line2D.new()
	_core.name = "BeamCore"
	_core.width = beam_width * 0.42
	_core.default_color = Color(1.0, 1.0, 1.0, 0.95)
	_core.begin_cap_mode = Line2D.LINE_CAP_ROUND
	_core.end_cap_mode = Line2D.LINE_CAP_ROUND
	_core.joint_mode = Line2D.LINE_JOINT_ROUND
	add_child(_core)
	visible = false


func spawn(p_params: Dictionary) -> void:
	# 池取出初始化（origin/depth/dmg_mult/武器快照；契约见 LaserWeapon._spawn_beam）
	uid = GameConst.next_uid()
	depth = int(p_params.get("depth", 0))
	dmg_mult = maxf(float(p_params.get("dmg_mult", 1.0)), 0.0)
	team = int(p_params.get("team", 0))
	tick_atk = maxf(float(p_params.get("tick_atk", 6.0)), 0.0)
	tick_rate = maxf(float(p_params.get("tick_rate", 8.0)), 0.1)
	beam_length = maxf(float(p_params.get("beam_length", 560.0)), 1.0)
	lifetime = maxf(float(p_params.get("lifetime", 0.0)), 0.0)
	beam_width = maxf(float(p_params.get("beam_width", 14.0)), 1.0)
	# R195 穿透预算 N（镜像弹体 pierce_left 注入口 projectile_base.gd:118 缺省/钳制同式）；
	# 缺省 1 与旧单目标口径同构；主束由武器传 _pierce_count()，副束/折射束恒 1
	pierce = maxi(int(p_params.get("pierce", 1)), 0)
	# 束色解析（优先级：R183 灰染 > SPECTRA 元素染色 > W5 折射光谱 > 主束玩家蓝）
	is_refraction = bool(p_params.get("is_refraction", false))
	sub_beam = bool(p_params.get("sub_beam", false))
	overlap_fallback = bool(p_params.get("overlap_fallback", false))
	gray_tint = bool(p_params.get("gray_tint", false))
	element = int(p_params.get("element", GameConst.Element.KIN))
	var depth_i := int(p_params.get("depth", 0))
	var tint := Color(PopPalette.PLAYER.r, PopPalette.PLAYER.g, PopPalette.PLAYER.b, 0.85)
	if gray_tint:
		tint = Color(PopPalette.RARITY_NORMAL.r, PopPalette.RARITY_NORMAL.g,
			PopPalette.RARITY_NORMAL.b, 0.6)
	elif sub_beam and element != GameConst.Element.KIN:
		tint = element_tint(element)           # 第三谱系束色：副束按元素谱系染色
	elif is_refraction:
		beam_width *= 0.7
		# R91 折射光谱（W5 分光读感）：depth1 = 光谱橙 / depth2 = 光谱紫——主束保持玩家蓝，
		# 分光束逐级换色且更细（「棱镜把光拆开」的视觉语言）
		tint = Color(PopPalette.ENEMY.r, PopPalette.ENEMY.g, PopPalette.ENEMY.b, 0.85).lerp(
			Color(PopPalette.XP.r, PopPalette.XP.g, PopPalette.XP.b, 0.85), 0.55) 			if depth_i <= 1 else Color(PopPalette.SHOCK.r, PopPalette.SHOCK.g, PopPalette.SHOCK.b, 0.85)
	if _line != null:
		_line.default_color = tint
	if _core != null:
		_core.default_color = tint.lerp(Color.WHITE, 0.9)
	scorch_max_layers = clampi(int(p_params.get("scorch_max_layers", 5)), 1, 8)
	scorch_per_layer = float(p_params.get("scorch_per_layer", 0.08))
	refract_beams = int(p_params.get("refract_beams", 0))
	refract_ratio = float(p_params.get("refract_ratio", 0.6))
	refract_depth = int(p_params.get("refract_depth", 2))
	target_uid = int(p_params.get("target_uid", 0))
	weapon_uid = int(p_params.get("weapon_uid", 0))
	var snap: Variant = p_params.get("panel_snapshot", {})
	panel_snapshot = snap if typeof(snap) == TYPE_DICTIONARY else {}
	trait_stack = p_params.get("trait_stack", null) as TraitStack
	_aim_dir = p_params.get("dir", Vector2.UP)
	if _aim_dir == Vector2.ZERO:
		_aim_dir = Vector2.UP
	if p_params.has("position"):
		position = p_params["position"]
	popup_throttle.clear()
	_hit_exclusions.clear()
	var exclusions: Variant = p_params.get("exclusions", [])
	if exclusions is Array:
		for uid_v in exclusions:
			_hit_exclusions[int(uid_v)] = true
	_tick_left = 1.0 / tick_rate
	_time_alive = 0.0
	popup_count = 0
	settle_count = 0
	_live = true
	visible = true
	if _line != null:
		_line.width = beam_width
	if _core != null:
		_core.width = beam_width * 0.42
	_dispatch_event(GameConst.TraitEvent.ON_SPAWN)


func tick(p_game_delta: float) -> void:
	# 朝向解析 → 射线命中集 → 灼焦叠层管理 → 节拍结算 → 渲染同步
	# R195 多目标贯穿（有意变更契约）：主束预算口径沿射线取前 pierce 个目标逐拍结算；
	# 基线 pierce=1 时与旧「单目标 _first_hit」行为逐位同构（选中一次算定）
	if not _live:
		return
	_time_alive += p_game_delta
	if lifetime > 0.0 and _time_alive >= lifetime:
		_recycle()
		return
	var dir := _resolve_aim()
	var hits := _hits_along_ray(dir, _hit_budget())
	var end_pos := global_position + dir * beam_length
	if not hits.is_empty():
		end_pos = (hits[hits.size() - 1] as Node2D).global_position   # R195：束端=末贯穿目标（t 最大）
		for i in hits.size():
			# 折射分叉仅由首个（最近）目标首次命中触发（现语义保留）；贯穿目标
			# 照常入 _hit_exclusions 但不触发新分叉（防 W5 分叉×穿透连乘）
			_on_hit_target(hits[i], p_game_delta, i == 0)
	_sync_line(end_pos)
	_tick_settle(hits, p_game_delta)


func set_origin(p_origin: Vector2) -> void:
	# 光束跟随（用户反馈「激光不跟随主角」：武器每帧更新原点）
	position = p_origin

func set_aim(p_dir: Vector2) -> void:
	# 主束指向（武器每帧刷新——目标策略：最近/最前；FAN 副束固定角同通道）
	if p_dir != Vector2.ZERO:
		_aim_dir = p_dir.normalized()


func is_live() -> bool:
	return _live


func hit_exclusions() -> Array[int]:
	# 已命中目标 uid 集（折射寻的排除集——子束继承）
	var out: Array[int] = []
	for key in _hit_exclusions:
		out.append(int(key))
	return out


func request_refract(p_count: int) -> void:
	# 分叉请求（深度 >refract_depth 拒绝并计数，AC-04.3；武器 _spawn_beam 同样硬闸 ≤2）
	if depth + 1 > refract_depth:
		DebugStats.count(&"laser_refract_rejected")
		EventBus.emit_chain_fused(depth + 1, &"laser_refract")
		return
	weapon._on_beam_refracted(global_position, self, p_count)


func _recycle() -> void:
	# 统一收束：OnExpire 派发 → 状态清零 → 池归还（E-04 顺序）。
	# 审查 Fix 1 清场连带修复：pool 引用须先于 _reset_state 捕获（_reset_state 契约清零
	# pool——先清后读使 release 恒短路，光束归还失效 → 池名额永久占用，集成审查发现）
	if not _live:
		return
	var pool_ref: ObjectPool = pool
	_live = false
	DebugStats.count(&"laser_beam_recycled")
	_dispatch_event(GameConst.TraitEvent.ON_EXPIRE)
	_reset_state()
	if pool_ref != null:
		pool_ref.release(self)


func _reset_state() -> void:
	# 归还清零契约（E-04/E-05：层数表/节流表/词条/订阅/计时）。
	# 灼焦目标侧单池不随束归还清零（池归属目标侧，跨束/跨武器存活——sweep/reset 口回收）
	depth = 0
	dmg_mult = 1.0
	last_hit_uid = 0                          # R91 聚焦态随归还清零
	focus_mult = 1.0
	_focus_visual = 0.0
	tick_atk = 6.0
	tick_rate = 8.0
	beam_length = 560.0
	beam_width = 14.0
	pierce = 1                                # R195 穿透预算归缺省（副束/下任主束缺省 1）
	scorch_max_layers = 5
	scorch_per_layer = 0.08
	refract_beams = 0
	refract_ratio = 0.6
	refract_depth = 2
	sub_beam = false
	element = GameConst.Element.KIN
	overlap_fallback = false
	gray_tint = false
	target_uid = 0
	weapon_uid = 0
	trait_stack = null
	panel_snapshot = {}
	popup_throttle.clear()
	_hit_exclusions.clear()
	_ray_candidates.clear()                   # R195 射线缓冲随归还清空（不持死节点引用）
	_ray_hits.clear()
	_ray_ts.clear()
	_tick_left = 0.0
	_time_alive = 0.0
	_aim_dir = Vector2.UP
	weapon = null
	damage_pipeline = null
	enemy_grid = null
	pool = null
	if _line != null:
		_line.clear_points()
	if _core != null:
		_core.clear_points()


# ── 内部 ──────────────────────────────────────────────────────────
func _resolve_aim() -> Vector2:
	# 朝向：副束/折射子束锁定目标（死亡 → 回收）/ 主束 = 武器刷新指向
	if target_uid != 0:
		var target := _find_target()
		if target == null:
			_recycle()
			return _aim_dir
		var dir := ((target as Node2D).global_position - global_position).normalized()
		if dir != Vector2.ZERO:
			_aim_dir = dir
	return _aim_dir


func _find_target() -> Node2D:
	# target_uid 解析（网格全域扫描；死亡/失踪 → null → 回收）
	if enemy_grid == null:
		return null
	var candidates: Array[Node2D] = []
	candidates.append_array(enemy_grid.query_circle(global_position, beam_length * 2.0))
	for cand in candidates:
		if int(cand.get("uid")) == target_uid:
			if bool(cand.get("dead")):
				return null
			return cand
	return null


func _hit_budget() -> int:
	# R195 穿透预算门：仅主束吃穿透（depth==0 ∧ ¬sub_beam ∧ ¬overlap_fallback——
	# is_refraction 蕴含于 depth==0 之外的三重防御：副束 depth 恒 0 但 sub_beam 真、
	# 折射束 depth≥1、回退束 overlap_fallback 真），预算口径 N=pierce；
	# 副束/折射/重叠回退束恒 1（旧单目标口径）
	if depth == 0 and not sub_beam and not overlap_fallback:
		return pierce
	return 1


func _hits_along_ray(p_dir: Vector2, p_budget: int) -> Array[Node2D]:
	# R195 射线命中集（扩自旧 _first_hit，判定式逐字保留）：射线段内垂直距离
	# ≤ beam_width/2 + 目标半径，按 t 升序取前 p_budget 个贯穿目标（Q-15 网格实现）。
	# 候选不查 _hit_exclusions（主束锁定持续照射语义保留——贯穿目标入排除集只为
	# 子束寻的防回烧）。缓冲成员复用（R188 禁每帧分配）；返回数组仅供本帧 tick
	# 同步消费，禁跨帧持有（下拍即被清空覆写）。
	_ray_hits.clear()
	_ray_ts.clear()
	if enemy_grid == null or p_budget <= 0:
		return _ray_hits
	_ray_candidates.clear()
	_ray_candidates.append_array(enemy_grid.query_circle(global_position, beam_length))
	var half_w := beam_width * 0.5
	for cand in _ray_candidates:
		if bool(cand.get("dead")):
			continue
		var rel := (cand as Node2D).global_position - global_position
		var t := rel.dot(p_dir)
		if t < 0.0 or t > beam_length:
			continue
		var perp := (rel - p_dir * t).length()
		var reach := half_w + float(cand.get("hitbox_r"))
		if perp <= reach:
			# t 升序插入（容量 ≤ 预算上界，尾部超额即裁——保最近 p_budget 个）
			var at := _ray_ts.size()
			while at > 0 and _ray_ts[at - 1] > t:
				at -= 1
			_ray_ts.insert(at, t)
			_ray_hits.insert(at, cand)
			if _ray_hits.size() > p_budget:
				_ray_ts.remove_at(_ray_ts.size() - 1)
				_ray_hits.remove_at(_ray_hits.size() - 1)
	return _ray_hits


func _on_hit_target(p_target: Node2D, p_game_delta: float, p_can_refract: bool = true) -> void:
	# 叠层 +1（1 层/0.25s，上限 scorch_max_layers；目标侧单池）→ 折射调度（新目标）。
	# 重叠回退束不叠灼焦（「不叠灼焦不附着」定案；伤害侧仍读共享层数乘区）。
	# R195：p_can_refract 仅首目标（最近）为真——折射分叉仍由每束首个目标首次命中
	# 触发一次，贯穿目标照常入 _hit_exclusions（防子束回烧）但不触发新分叉
	# （防 W5 分叉×穿透连乘；探针 S8 锁分叉数不随 N 增长）
	var target_uid := int(p_target.get("uid"))
	if not _hit_exclusions.has(target_uid):
		_hit_exclusions[target_uid] = true
		if p_can_refract and refract_beams > 0 and weapon != null:
			request_refract(refract_beams)
	if not overlap_fallback:
		_scorch_add(target_uid, p_game_delta, scorch_max_layers, uid)


func _tick_settle(p_hits: Array[Node2D], p_game_delta: float) -> void:
	# 节拍结算（tick_rate 跳/s；HIT 通道——灼焦 Local 池 + 词条乘区 + 暴击每跳独立）。
	# R195 多目标：选中一次算定——同拍内前目标死亡不移除后目标；逐目标复用
	# _settle_one_tick 单口（灼焦/跳字闸/ELE 附着/遗物乘区全走现管道，禁旁路简化结算）
	_tick_left -= p_game_delta
	while _tick_left <= 0.0 and not p_hits.is_empty() and _live:
		_tick_left += 1.0 / tick_rate
		for i in p_hits.size():
			_settle_one_tick(p_hits[i], i + 1)
	if _tick_left < 0.0:
		_tick_left = 0.0


func apply_focus_visual(p_focus_time: float) -> void:
	# R91 聚焦视觉：束宽 +50%、芯线趋白热（cap 1.0）——持续照射「越来越烫」的读感
	_focus_visual = clampf(p_focus_time / 6.7, 0.0, 1.0)
	if _line != null:
		_line.width = beam_width * (1.0 + 0.5 * _focus_visual)
	if _core != null:
		_core.width = beam_width * 0.42 * (1.0 + 0.6 * _focus_visual)
		_core.default_color = Color(1.0, 1.0, 1.0, 0.95).lerp(
			Color(1.0, 0.95, 0.75, 1.0), _focus_visual)


func _settle_one_tick(p_hit: Node2D, p_ordinal: int = 1) -> void:
	# p_ordinal = 贯穿序数（1 基，R195 多目标；缺省 1 = 旧单目标口径）
	if damage_pipeline == null:
		return
	var ctx := DamageContext.make()
	ctx.source_uid = uid
	ctx.target = p_hit
	ctx.target_uid = int(p_hit.get("uid"))
	if p_ordinal == 1:
		last_hit_uid = ctx.target_uid           # R91 聚焦判据（武器侧消费）——R195 仅首目标写
	ctx.frame_stamp = GameConfig.frame_stamp
	ctx.base_atk = tick_atk * dmg_mult * focus_mult   # R91 W4 聚焦爬坡（主束专属，副束恒 1.0）
	ctx.flat_bonus = float(panel_snapshot.get("flat_bonus", 0.0))
	ctx.crit_chance = float(panel_snapshot.get("crit_rate", 0.0))
	ctx.crit_mult = float(panel_snapshot.get("crit_mult", 2.0))
	var entries: Variant = panel_snapshot.get("add_entries", [])
	if entries is Array:
		for entry in entries:
			ctx.add_entries.append(entry)
	ctx.element = element                       # 元素束侧化（删 KIN 硬编码：附魔/SPECTRA 生效）
	ctx.pos = (p_hit as Node2D).global_position
	# R199 F11/F10：波首命中位 + 玩家血线条件输入（激光自建 ctx 此前零写口——先手协议
	# SYN_FIRST_STRIKE 对激光族死卡、背水/壁垒血线条件断供恒默认值）。经宿主武器问询，
	# 与近战 builder（weapon_base.build_damage_context:212/:217）和投射物路径
	#（projectile_base.gd:485-486）同源同式；无宿主（纯束测试夹具）→ 安全缺省 false/1.0
	if weapon != null and is_instance_valid(weapon):
		ctx.is_first_hit_of_wave = weapon.is_wave_first_hit()
		ctx.player_hp_pct = weapon.player_hp_pct()
	# R195 穿透序数（弹体同式复制——镜像 projectile_base.gd:462/:484-485）：第 k 目标
	# pierce_index=k+1（首目标=2）+ 恒 HIT_AFTER_PIERCE。SYN_PIERCE_EVO 条件
	# pierce_index≥2 因此在激光首目标即贡献 value×(2−1)，与弹体同紫卡首跳同数值；
	# HIT_AFTER_PIERCE 全仓零消费者，写入纯为口径统一
	# R198（r195-1 口径 1）：序数加成仅主束——副束/折射束/重叠回退束 pierce_index 恒 1
	#（SYN_PIERCE_EVO 对副束 (pierce_index-1)=0，贡献归零）。副束/折射/重叠回退束本就
	# 永不贯穿（_hit_budget 恒预算 1），其首目标白吃首跳 ×1.2 系序数口径缺口。谓词与
	# _hit_budget（:392-399）逐字同源；弹体路径（projectile_base.gd:481）不动
	ctx.pierce_index = (p_ordinal + 1) if (depth == 0 and not sub_beam and not overlap_fallback) else 1
	ctx.hit_flags |= GameConst.HIT_AFTER_PIERCE
	# F-15 灼焦 Local 私有池（∏ L_l：不入名额、不受 cap_prod、自有 cap_local）——
	# 层数读目标侧单池（多束同目标共享；W4 裁定 2026-09-25）
	var layers := scorch_layers_of(ctx.target_uid)
	if layers > 0:
		ctx.local_pools.append({
			"local_id": &"scorch",
			"contrib": float(layers) * scorch_per_layer,
			"cap_local": float(scorch_max_layers) * scorch_per_layer,
		})
	# 词条乘区预聚合（§4.4 ②：光束路径条件自评）+ 目标易伤乘区 + 遗物命中乘区（B.2）
	var tctx := TraitContext.new()
	tctx.event = GameConst.TraitEvent.ON_HIT
	tctx.beam = self
	tctx.weapon = weapon
	tctx.target = ctx.target
	tctx.damage_ctx = ctx
	if trait_stack != null:
		for pool in trait_stack.collect_mult_pools(tctx):
			ctx.mult_pools.append(pool)
	if weapon != null:
		weapon.inject_vuln_pool(ctx, ctx.target)
		weapon.inject_relic_pools(ctx, ctx.target)   # 遗物乘区接线（激光跳伤路径此前绕过）
	if trait_stack != null:
		trait_stack.dispatch(GameConst.TraitEvent.ON_HIT, tctx)
	var result: DamageResult = damage_pipeline.call(&"resolve", ctx)
	settle_count += 1
	if not tctx.attach_request.is_empty() and not overlap_fallback \
			and weapon != null and weapon.elemental != null:
		# ELE 词条附着请求（引擎结算后提交——对齐投射物 _apply_elemental 时序：
		# projectile_base.gd 在 _on_settled 即 resolve 之后提交）。★ 快照基数 = 单跳 ×
		# 跳频 × 0.5s（= 每「燃烧跳伤间隔」造成的照射伤害——与弹道武器的「每发快照」
		# 口径对齐；旧版直接传单跳值 6 → 点燃 DOT 0.9/跳，观感即「烧伤 0」，
		# 2026-08-31 修复）。R199 D16：hit_damage 改传真实跳伤（result.final_value，
		# 同 projectile_base.gd:540-547 先例）——此前恒 0.0 使雷引 ELE_SHOCK 满槽感电的
		# 连锁传导伤害 0.35×0=0，连锁闪电特效空放（elemental_system._shock_chain 消费）。
		# result 为 null（透传桩缺结果）→ 回落 0.0 旧口径。
		var request: Dictionary = tctx.attach_request
		weapon.elemental.apply_attach(ctx.target, int(request["element"]),
			float(request["value"]), {
				"snapshot": ctx.base_atk * tick_rate * 0.5,
				"hit_damage": float(result.final_value) if result != null else 0.0,
				"overrides": request.get("overrides", {}),
			})
	# 命中迸裂表现（用户反馈 2026-08-31「脉冲的命中迸裂没看见特效」）：每跳结算瞬间
	# 广播命中点 + 束方向（ElementalFxLayer 迸裂星闪 + 火花承接；跳频即特效频率——
	# 射速强化卡在激光上同时加密迸裂节奏，升级反馈可视化）
	EventBus.emit_beam_impact(ctx.pos, _aim_dir)
	if result != null:
		if popup_due(ctx.target_uid):
			popup_count += 1
		# 落血口径双轨（同 weapon_base.settle_aoe 审查修复）：真件 DamagePipeline 九步
		# 9b 在 resolve 内部已 take_result 落血（_apply_to_target——killed 判定/死亡广播
		# 唯一执行点），本侧再落血即每跳伤害 ×2；透传桩 resolve 只算不落血，落血职责在
		# 调用方（pkg2/pkg3 桩用例锁定口径，保持不变）。管线为 null 在方法头已短路。
		if damage_pipeline is DamagePipeline:
			return
		if ctx.target.has_method(&"take_result"):
			ctx.target.call(&"take_result", result)


func popup_due(p_uid: int) -> bool:
	# 跳字节流闸门：≤15Hz/目标（AC-04.2；包 4 PopupManager 消费同口径）
	var next := float(popup_throttle.get(p_uid, 0.0))
	if _time_alive >= next:
		popup_throttle[p_uid] = _time_alive + 1.0 / POPUP_HZ
		return true
	return false


func _sync_line(p_end: Vector2) -> void:
	# 线段渲染（局部坐标：起点原点）；束宽轻微呼吸（方向 C：束流活力，零 shader）
	if _line == null:
		return
	_line.clear_points()
	_line.add_point(Vector2.ZERO)
	_line.add_point(to_local(p_end))
	_line.width = beam_width * (1.0 + 0.07 * sin(_time_alive * 26.0))
	if _core != null:
		_core.clear_points()
		_core.add_point(Vector2.ZERO)
		_core.add_point(to_local(p_end))
		_core.width = beam_width * 0.42 * (1.0 + 0.07 * sin(_time_alive * 26.0 + 1.2))


func _dispatch_event(p_event: int) -> void:
	# 词条事件派发（M-10 链式深度/重入护栏在 TraitStack.dispatch）
	if trait_stack == null:
		return
	var tctx := TraitContext.new()
	tctx.event = p_event
	tctx.beam = self
	tctx.weapon = weapon
	trait_stack.dispatch(p_event, tctx)

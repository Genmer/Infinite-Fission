# scripts/combat/weapon/sim_query_share.gd
# R293 模拟刀 B：② 段武器侧查询帧级共享（W9 查询共享 + has_target_now 帧缓存）。
# 语义地基（R231 语义锚 space_grid.gd:8-14 承接）：固定帧序 ①输入→②玩家(player.tick
# 含四组武器调度)→④双网格重建→⑤敌——② 段内网格桶=上一步 ④ 的冻结快照、敌位只在
# ⑤ 变（击退为速度型 ⑤ tick 才位移），② 内唯一变异=武器侧击杀翻 dead 位（死亡回池
# 位置不变）。⇒ 同帧 ② 内同参数查询结果恒同，跨武器共享数学上精确；dead 位由消费方
# 逐调用过滤（与 acquire_target 现口径 weapon_base.gd 逐位同法——本缓存只存裸节点/
# 裸候选数组，绝不缓存「有目标」布尔，防前序武器击杀唯一敌时假阳）。
# 逐位等价证明（三件）：
#   ① nearest 派生：query_nearest(pos,r,null) 与 query_circle(pos,r) 共用
#     _cells_in_range 行主序×桶插入序、同一谓词 d<=(r+mr)²、`d<best_d` 严格比较
#     保首个最小值——对圆扫候选表按同式 argmin（严格 <）与 query_nearest 逐位同值
#     （含精确平局同取向）；
#   ② leash 子集派生：以同谓词 `_pos_of(c).distance_squared_to(center)
#     <= (leash+mr)²` 对 1600 候选表保序过滤——集合=直接 query_circle(center,leash)
#     的全体、相对序=行主序截断后的同序（_pick_chase_target 平局取向逐位不变）；
#   ③ 相位括号纪元：共享只在 ② 相位括号内生效（player.tick 武器调度段 begin/end_
#     phase 包夹——括号内敌位/网格成员结构性冻结：击退速度型 ⑤ 才位移、rebuild/
#     insert 在 ④、死亡回池位置不变，唯一变异=dead 翻转且由消费方逐调用过滤）；
#     纪元三轴=相位号+GameConfig.frame_stamp+SpaceGrid._stamp（任一变即整帧条目
#     作废——headless 直驱玩家拍/测试直驱武器拍不经括号时恒走原查询路径，逐位）。
# 承重墙对齐：
#   · 仅 tick 栈内（_in_tick）且 ② 相位括号内走缓存——栈外直调 try_fire / 测试
#     直驱武器拍恒真查（R220 r220_firephase_cases ③「栈外直调不共享缓存」锁，
#     结构性保持：括号只由 player.tick 生产写点开合）；
#   · 键含网格实例身份（CountingGrid 桩按武器注入替换时桩查询不被他网格条目吞掉，
#     且桩首查照常实查——「一拍 tick 全链 query_nearest 恰 1 次」在基类路径保持）；
#   · 候选缓存一律先复制进自有数组（SpaceGrid._query_buffer/_cells_buffer 单实例
#     不得跨查询持有——space_grid 共享缓冲纪律，_cand_buf 同款）；
#   · 惰性首查者付费：全部调用点在 weapon.tick 计时窗内（player.gd 逐武器 µs 探针
#     之下），不把查询 hoist 出武器循环——武9µs/副武µs 归因链不断。
# 自证口：stat_hits/stat_fills/stat_empty_skips/stat_leash_derives 计数（qa_r293
# 套件「查询次数计数口下降断言」读数；enabled=false 一键回退原查询路径——A/B 逐位
# 对照口）。
# 引用方式（R293 修轮裁定）：本文件不挂 class_name——headless 门禁跑 -s 套件不重扫
# .godot/global_script_class_cache.cfg（实测缓存停在跑套件前的旧版），新 class_name
# 在裸标识符解析口不可达 → 引用方全部 parse error 级联（qa_r293 首跑「用例体加载
# 失败」0/1 根因）。消费方一律 `const SimQueryShare = preload("res://scripts/combat/
# weapon/sim_query_share.gd")` 按路径引用（WeaponBase 声明一份——子类继承；非子类
# 宿主〔OrbitField/Player/测试〕各自声明——父子类同名 const = parse error，R243 注先例）。
extends RefCounted

# 基类索敌 reach 单源（原 weapon_base.acquire_target 字面量 1600 上移——值不变；
# slash 模式 1600 圆扫条目与基类 nearest 条目共用本值域但分命名空间存储：基类必须
# 保持 query_nearest 调用形状（r220 计数桩），slash 侧用 query_circle+argmin 派生）
const TARGET_REACH := 1600.0

static var enabled: bool = true              # 刀开关（false=全路径恒原查询——逐位回退）
static var stat_hits: int = 0                # 自证口：帧缓存命中次数（近邻/圆扫/leash 合计）
static var stat_fills: int = 0               # 自证口：实查填充次数
static var stat_empty_skips: int = 0         # 自证口：is_empty() O(1) 早退次数
static var stat_leash_derives: int = 0       # 自证口：leash 候选从 1600 圆扫条目派生次数

# ② 相位括号（生产唯一写点=player.tick 武器调度段；_phase_ctr>0 时共享生效，
# _phase_epoch 每次开括号递增=条目纪元轴之一——跨相位条目必作废）
static var _phase_ctr: int = 0
static var _phase_epoch: int = 0

# 帧级条目仓：网格实例 id → {phase, frame, stamp, near, scan, leash}
#   near  = {center: {reach: 裸最近节点}}            —— 基类 acquire_target / cleave 交战门
#   scan  = {center: {cands: 候选数组, nearest: 节点}} —— slash 1600 圆扫共享条目
#   leash = {center: {leash: 候选数组}}               —— 追击 leash 候选（派生或小扫）
# 键为 Vector2/float 值哈希——同相位内同武器同参调用键恒同（muzzle 在 ② 内不位移）。
static var _grid_meta: Dictionary = {}

# GameConfig（autoload）帧号惰性解析缓存——headless 直驱无主场景时 root 找不到该
# 节点则恒 0（此时 SpaceGrid._stamp 纪元独自承担失效，rebuild 每步递增仍零陈旧）。
static var _cfg_node: Node = null
static var _cfg_checked: bool = false


static func _frame_now() -> int:
	# 当前帧号（GameConfig.frame_stamp 只读；节点解析一次终身复用——autoload 不销毁）
	if not _cfg_checked:
		_cfg_checked = true
		var ml := Engine.get_main_loop() as SceneTree
		if ml != null and ml.root != null:
			_cfg_node = ml.root.get_node_or_null("GameConfig")
	if _cfg_node != null:
		return int(_cfg_node.get("frame_stamp"))
	return 0


static func begin_phase() -> void:
	# ② 相位开括号（player.tick 武器调度段入口——生产唯一写点；测试可显式包夹）。
	# 每次开括号递进相位号：上一相位的全部条目即时陈旧（纪元比对作废）。
	_phase_ctr += 1
	_phase_epoch += 1


static func end_phase() -> void:
	# ② 相位闭括号（player.tick 武器调度段出口）。括号外共享一律不生效（恒原查询）。
	_phase_ctr = maxi(_phase_ctr - 1, 0)


static func _meta_for(p_grid: SpaceGrid) -> Dictionary:
	# 网格的当相位条目仓（纪元三轴任一变即三表整清——跨相位/跨帧/跨 rebuild 零
	# 陈旧通道）。网格为 RefCounted：条目仓只存实例 id 不持引用（不阻回收；实例
	# id 复用时纪元不匹配自然整清）。上限保险丝：长跑测试桩网格更替下防仓表无界
	# （清仓只掉缓存，次查实查重建——语义零变化）。
	var gid := p_grid.get_instance_id()
	var meta: Dictionary = _grid_meta.get(gid, {})
	if meta.is_empty():
		if _grid_meta.size() > 16:
			_grid_meta.clear()
		meta = {"phase": _phase_epoch, "frame": _frame_now(), "stamp": p_grid._stamp,
			"near": {}, "scan": {}, "leash": {}}
		_grid_meta[gid] = meta
		return meta
	if int(meta["phase"]) != _phase_epoch or int(meta["frame"]) != _frame_now() \
			or int(meta["stamp"]) != p_grid._stamp:
		meta["phase"] = _phase_epoch
		meta["frame"] = _frame_now()
		meta["stamp"] = p_grid._stamp
		(meta["near"] as Dictionary).clear()
		(meta["scan"] as Dictionary).clear()
		(meta["leash"] as Dictionary).clear()
	return meta


static func invalidate() -> void:
	# 全量作废（测试收口/场景切换——语义上恒安全：次查实查重建）
	_grid_meta.clear()
	_phase_epoch += 1                        # 纪元递进：既有条目全部陈旧


static func reset_diag() -> void:
	# 自证口复位 + 全量作废 + 相位归零（测试相位隔离）
	stat_hits = 0
	stat_fills = 0
	stat_empty_skips = 0
	stat_leash_derives = 0
	_phase_ctr = 0
	invalidate()


# ── B1：query_nearest 帧级共享（基类索敌口 / W13 cleave 交战门共用） ─────────
# 返回裸最近节点（不过滤 dead——消费方逐调用过滤，与现口径逐位同法）；键含 reach
# ——1600 条目与小 reach 交战门分立成条（cleave 门=进圈判定，超集候选直放会放宽门，
# 承重墙口径）。空场 is_empty() O(1) 早退（R287：快照空 ⇒ 任何 query_* 必零候选——
# 清场/弹重窗归零；桩网格继承同口径）。
static func shared_nearest(p_in_tick: bool, p_grid: SpaceGrid,
		p_origin: Vector2, p_reach: float) -> Node2D:
	if not enabled or not p_in_tick or _phase_ctr <= 0:
		return p_grid.query_nearest(p_origin, p_reach, null)
	if p_grid.is_empty():
		stat_empty_skips += 1
		return null
	var meta := _meta_for(p_grid)
	var near: Dictionary = meta["near"]
	if near.has(p_origin):
		var inner: Dictionary = near[p_origin]
		if inner.has(p_reach):
			stat_hits += 1
			var hit_node: Node2D = inner[p_reach]
			return hit_node
	stat_fills += 1
	var found: Node2D = p_grid.query_nearest(p_origin, p_reach, null)
	var slot: Dictionary = {}
	if near.has(p_origin):
		slot = near[p_origin]
	else:
		near[p_origin] = slot
	slot[p_reach] = found
	return found


# ── 缝隙A：slash（W9 族）1600 圆扫共享条目——一次 query_circle 同时供 nearest
#    派生 + 追击 leash 候选子集；本体+同拍同位副本/镜面同帧共享一条目 ────────────
static func slash_nearest(p_in_tick: bool, p_grid: SpaceGrid,
		p_center: Vector2) -> Node2D:
	# slash 模式索敌：优先同帧圆扫条目（含追击先填的条目——谁先到谁实查）；
	# 未建则一次 query_circle(center,1600) 复制候选 + argmin 派生 nearest
	#（逐位等价证明①——遍历序/谓词/严格比较与 query_nearest 同构）。
	if not enabled or not p_in_tick or _phase_ctr <= 0:
		return p_grid.query_nearest(p_center, TARGET_REACH, null)
	if p_grid.is_empty():
		stat_empty_skips += 1
		return null
	var meta := _meta_for(p_grid)
	var scan: Dictionary = meta["scan"]
	if scan.has(p_center):
		stat_hits += 1
		var hit_node: Node2D = (scan[p_center] as Dictionary)["nearest"]
		return hit_node
	var entry := _fill_scan(meta, p_grid, p_center)
	var near_node: Node2D = entry["nearest"]
	return near_node


static func shared_scan_cands(p_in_tick: bool, p_grid: SpaceGrid,
		p_center: Vector2) -> Array[Node2D]:
	# 1600 圆扫候选表帧级共享（W6 齐射目标分配 _acquire_volley_targets 等「需要
	# 全候选表」的消费口——与 slash_nearest 同条目同填充）。返回数组只读迭代、
	# 不得跨查询持有/变异（环内嵌套网格查询 = 踩共享候选，space_grid 缓冲纪律）。
	# 禁用/栈外回落=直接实查的内部缓冲引用（与原实现零复制迭代完全同款——调用方
	# 立即迭代消亡，语义逐位）。
	if not enabled or not p_in_tick or _phase_ctr <= 0:
		return p_grid.query_circle(p_center, TARGET_REACH)
	if p_grid.is_empty():
		stat_empty_skips += 1
		return []
	var meta := _meta_for(p_grid)
	var scan: Dictionary = meta["scan"]
	if scan.has(p_center):
		stat_hits += 1
		var hit_cands: Array[Node2D] = (scan[p_center] as Dictionary)["cands"]
		return hit_cands
	var entry2 := _fill_scan(meta, p_grid, p_center)
	var out_cands: Array[Node2D] = entry2["cands"]
	return out_cands


static func _fill_scan(p_meta: Dictionary, p_grid: SpaceGrid,
		p_center: Vector2) -> Dictionary:
	# 1600 圆扫条目填充（slash_nearest / shared_scan_cands 共用）：一次 query_circle
	# 复制候选（共享缓冲纪律）+ argmin 派生 nearest（严格 < 首个最小值——与
	# query_nearest 同遍历序/同谓词/同平局取向，逐位等价）。
	stat_fills += 1
	var cands: Array[Node2D] = []
	cands.append_array(p_grid.query_circle(p_center, TARGET_REACH))
	var nearest: Node2D = null
	var best_d := INF
	for c in cands:
		var d := p_grid._pos_of(c).distance_squared_to(p_center)
		if d < best_d:                       # 严格 <：首个最小值——与 query_nearest 平局取向逐位同
			best_d = d
			nearest = c
	var entry := {"cands": cands, "nearest": nearest}
	var scan_tbl: Dictionary = p_meta["scan"]
	scan_tbl[p_center] = entry
	return entry

static func slash_leash_candidates(p_in_tick: bool, p_grid: SpaceGrid,
		p_center: Vector2, p_leash: float) -> Array[Node2D]:
	# 追击 leash 候选（OrbitField._tick_chase 消费）：
	#   ① 同帧已有 1600 圆扫条目（本拍索敌或前序 W9 已建）→ 保序派生子集
	#     （逐位等价证明②——零查询，stat_leash_derives 计数）；
	#   ② 无条目（冷却期无索敌拍——chase 是首消费者）→ 原小扫 query_circle(center,
	#     leash) 复制（与原实现同调用形状），并按 (center,leash) 键共享给同 leash
	#     同位 W9 系副本。
	# 返回数组：调用方只读迭代（_pick_chase_target 无嵌套查询——原实现同款纪律）。
	if not enabled or not p_in_tick or _phase_ctr <= 0:
		var fb: Array[Node2D] = []
		fb.append_array(p_grid.query_circle(p_center, p_leash))
		return fb
	if p_grid.is_empty():
		stat_empty_skips += 1
		return []
	var meta := _meta_for(p_grid)
	var leash: Dictionary = meta["leash"]
	if leash.has(p_center):
		var l_inner: Dictionary = leash[p_center]
		if l_inner.has(p_leash):
			stat_hits += 1
			var hit_cands: Array[Node2D] = l_inner[p_leash]
			return hit_cands
	var out: Array[Node2D] = []
	var scan: Dictionary = meta["scan"]
	if scan.has(p_center) and p_leash <= TARGET_REACH:
		# ① 从 1600 条目派生（同谓词保序过滤——与直接小扫逐位同集合同序）。完备门
		#   p_leash <= TARGET_REACH：条目候选域=1600+mr 圆（_fill_scan query_circle 半径），
		#   leash 超域时派生子集必缺员 → 恒走②直扫（当前调用面 leash ≤1425 恒入①——
		#   门为防未来调参踩雷的结构性保险，QA-R293 修轮2）。
		stat_leash_derives += 1
		var mr := p_grid.max_entity_radius()
		var reach := p_leash + mr
		var reach_sq := reach * reach
		for c in (scan[p_center] as Dictionary)["cands"]:
			if p_grid._pos_of(c).distance_squared_to(p_center) <= reach_sq:
				out.append(c)
	else:
		# ② 原小扫（首消费者冷却期路径——成本不高于原实现）
		stat_fills += 1
		out.append_array(p_grid.query_circle(p_center, p_leash))
	if not leash.has(p_center):
		leash[p_center] = {}
	var l_slot: Dictionary = leash[p_center]
	l_slot[p_leash] = out
	return out

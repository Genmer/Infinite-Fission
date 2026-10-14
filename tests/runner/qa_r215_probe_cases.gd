# tests/runner/qa_r215_probe_cases.gd
# R215 QA 自提探针（独立验证口——r215_defer 套件之外的交叉验证）：
#   ① 刀A 真帧尾消费路径（产品路径 _physics_process PLAYING 帧，非手动 _consume）
#      + 跨 3 帧连续升级窗链零丢弃 + LEVEL_UP 期 gain_xp 排队 + choose→排队窗再开链
#      + batch 路径（首级档位/同帧二次批溢出/GAME_OVER 批丢弃）
#   ② 刀B 160 死亡堆守恒 ×3 可重复（emit 次数守恒=乘区无关口径 + 三轮总量一致）
#      + 帽冻结只作用圈内片 + 磁片在场遥测 + 真实 diag 行 + ⑦ 段产品路径吸收
#   ③ 刀C boot 零生成（敌贴图键 boot 前后增量 0）+ 队首共享域优先 + 建队幂等/成本
#      + 快速开局不崩溃不消化 + MENU 预算消化清队 + 实例 _kind 转发一致 + 静态真源行为锁
#   ④ 刀D 桶计数真源（同 kind 同桶/release 保留）——并入 ③ 组尾部（同实例省一次 boot）
# 坑位纪律：池化实体不 add_child、只 release 一次；lambda 按值捕获用数组容器；
# XpShard.activate 内含出生散射——落位必须在 activate 之后；
# xp_gained 事件负载=乘区后金额（player.gain_xp：Meta×地图×词条×难度），守恒按次数口径。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const PLAYER_HOME := Vector2(360.0, 900.0)
const DT := 1.0 / 60.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null                       # 组①② 用实例
var _gl2: GameLoop = null                      # 组③④ 用实例（干净桶宿主）
var _enemy_keys_before_boot2: Array[String] = []   # gl2 boot 前敌贴图键快照（静态缓存跨实例）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261002)
	_boot(&"_gl")
	await tree.process_frame
	await tree.process_frame
	_test_a_knife_a_deferred_chain()
	_test_b_knife_b_conservation_x3()
	_teardown(&"_gl")
	_snapshot_enemy_keys()
	_boot(&"_gl2")
	_test_c_knife_c_menu_prewarm()
	_teardown(&"_gl2")
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s（%s）" % [p_name, p_detail])
		print("  FAIL | %s（%s）" % [p_name, p_detail])


func _boot(p_slot: String) -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	var gl: GameLoop = scene.instantiate() as GameLoop
	gl.name = "R215Probe%s" % p_slot
	tree.get_root().add_child(gl)
	set(p_slot, gl)


func _teardown(p_slot: String) -> void:
	tree.paused = false
	RunSave.clear()
	var gl: GameLoop = get(p_slot)
	if gl != null:
		gl.free()
		set(p_slot, null)


func _snapshot_enemy_keys() -> void:
	_enemy_keys_before_boot2.clear()
	for k in TextureFactory._cache:
		if String(k).begins_with("enemy_"):
			_enemy_keys_before_boot2.append(String(k))
	_enemy_keys_before_boot2.sort()


func _enter_play(p_gl: GameLoop) -> void:
	p_gl.state = GameConst.GameStatus.MENU
	p_gl.current_map_id = MapTable.FIRST_MAP_ID
	p_gl.start_run()


func _choose_until_playing(p_gl: GameLoop, p_max: int = 12) -> int:
	var n := 0
	while p_gl.state == GameConst.GameStatus.LEVEL_UP and n < p_max:
		(p_gl.card_select_ui as CardSelectUI).choose(0)
		n += 1
	return n


# ── ① 刀A：真帧尾消费 + 跨 3 帧窗链 + 排队/批路径 ─────────────────
func _test_a_knife_a_deferred_chain() -> void:
	print("── ① 刀A 延迟开窗链 ──")
	_enter_play(_gl)
	var lv0: int = _gl.player.level
	var drop0: int = _gl.dropped_level_ups
	# A1：产品路径——PLAYING 帧尾自动消费（非手动 _consume）
	_gl.player.gain_xp(_gl.player.xp_need)
	_check("A1a gain 后同帧未开窗（state PLAYING + 已记档）",
		_gl.state == GameConst.GameStatus.PLAYING
			and int(_gl.get("_deferred_level_open")) >= 0,
		"state=%d deferred=%s" % [_gl.state, str(_gl.get("_deferred_level_open"))])
	_gl._physics_process(DT)                      # 真实 PLAYING 帧（帧序⑧后消费点）
	_check("A1b 真帧尾消费开窗（LEVEL_UP + 窗开 + 档位清）",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open
			and int(_gl.get("_deferred_level_open")) == -1,
		"state=%d open=%s" % [_gl.state, str(_gl.card_select_ui.is_open)])
	# A2~A4：跨 3 帧每帧 gain+消费，choose 链不丢级
	for i in range(2):
		_choose_until_playing(_gl)
		_gl.player.gain_xp(_gl.player.xp_need)
		_gl._physics_process(DT)
		_check("A%d 帧尾再开窗（第 %d 次）" % [2 + i, i + 1],
			_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open, "")
	_choose_until_playing(_gl)
	_check("A4 跨 3 帧窗链零丢弃（level+3 dropped+0 回 PLAYING）",
		_gl.player.level == lv0 + 3 and _gl.dropped_level_ups == drop0
			and _gl.state == GameConst.GameStatus.PLAYING
			and not _gl.card_select_ui.is_open,
		"lv %d→%d drop+%d" % [lv0, _gl.player.level, _gl.dropped_level_ups - drop0])
	# B1：LEVEL_UP 期 gain_xp 走排队不经延迟档
	_gl.player.gain_xp(_gl.player.xp_need)
	_gl.call(&"_consume_deferred_level_open")
	_gl.player.gain_xp(_gl.player.xp_need)        # 窗内再来一级
	_check("B1 LEVEL_UP 期 gain 走排队（deferred 恒 -1 + pending≥1）",
		int(_gl.get("_deferred_level_open")) == -1 and int(_gl.pending_level_ups) >= 1,
		"deferred=%s pending=%d" % [str(_gl.get("_deferred_level_open")), _gl.pending_level_ups])
	# B2：choose→排队窗再开链（queued 级逐窗消化）
	var lv_b: int = _gl.player.level
	var n_open: int = _choose_until_playing(_gl)
	_check("B2 排队窗再开链耗尽回 PLAYING（≥2 窗 + 零丢弃）",
		n_open >= 2 and _gl.state == GameConst.GameStatus.PLAYING
			and _gl.dropped_level_ups == drop0 and _gl.pending_level_ups == 0,
		"opens=%d state=%d pending=%d" % [n_open, _gl.state, _gl.pending_level_ups])
	_check("B3 窗链等级守恒（窗数==升级数）", _gl.player.level == lv_b,
		"lv %d→%d" % [lv_b, _gl.player.level])
	# C1：batch 路径——首级档位 + 其余排队
	var lv_c: int = _gl.player.level
	_gl.call(&"_on_level_up_batch", 3)
	_check("C1 batch(3) 首级档位+排队 2（deferred=level-2）",
		int(_gl.get("_deferred_level_open")) == lv_c - 2 and int(_gl.pending_level_ups) == 2,
		"deferred=%s pending=%d" % [str(_gl.get("_deferred_level_open")), _gl.pending_level_ups])
	_gl.call(&"_consume_deferred_level_open")
	_choose_until_playing(_gl)
	_check("C2 batch 窗链收口零丢弃", _gl.state == GameConst.GameStatus.PLAYING
		and _gl.dropped_level_ups == drop0 and int(_gl.get("_deferred_level_open")) == -1, "")
	# C3：同帧二次批——帽 3 + 溢出批
	var pend_c: int = _gl.pending_level_ups
	var mo_c: int = _gl.merged_overflow_level_ups
	_gl.call(&"_on_level_up_batch", 3)
	_gl.call(&"_on_level_up_batch", 3)
	_check("C3 同帧双批 queued 帽 3 + 溢出 2",
		_gl.pending_level_ups - pend_c == 3
			and _gl.merged_overflow_level_ups - mo_c == 2,
		"pend+%d mo+%d" % [_gl.pending_level_ups - pend_c,
			_gl.merged_overflow_level_ups - mo_c])
	_gl.call(&"_consume_deferred_level_open")
	_choose_until_playing(_gl)
	_check("C4 双批窗链收口零丢弃", _gl.state == GameConst.GameStatus.PLAYING
		and _gl.dropped_level_ups == drop0, "")
	# C5：GAME_OVER 期批丢弃
	_gl.state = GameConst.GameStatus.GAME_OVER
	var drop_c: int = _gl.dropped_level_ups
	_gl.call(&"_on_level_up_batch", 5)
	_check("C5 GAME_OVER batch(5) 丢弃 +5", _gl.dropped_level_ups == drop_c + 5, "")
	_gl.state = GameConst.GameStatus.PLAYING


# ── ② 刀B：160 死亡堆守恒 ×3 + 冻结选择性 + 磁片遥测 + diag 行 ────
func _test_b_knife_b_conservation_x3() -> void:
	print("── ② 死亡堆帽守恒 ×3 ──")
	_gl.player.global_position = PLAYER_HOME
	var acc_totals: Array[float] = []             # 三轮总量一致性（乘区恒定→守恒可重复口径）
	for round_i in range(3):
		var pool := _gl.pools[&"xp"] as XPPool
		var shards: Array = _gl.get("active_shards")
		shards.clear()
		var frozen_pos: Array[Vector2] = []
		for i in range(160):
			var s: XpShard = pool.acquire()
			if s == null:
				break
			s.activate(1.0, 0.0)                  # 先激活（内含出生散射）
			s.global_position = PLAYER_HOME + Vector2(1.0, 0.0)   # 后落位（圈内）
			shards.append(s)
			if i < 5:
				frozen_pos.append(s.global_position)
		var with_ctrl := round_i == 0
		var out_shard: XpShard = null
		if with_ctrl:
			out_shard = pool.acquire()
			if out_shard != null:
				out_shard.activate(1.0, 0.0)
				out_shard.global_position = PLAYER_HOME + Vector2(40.0, 0.0)   # 圈外（>24 ≤120）
				shards.append(out_shard)
		var n_in: int = shards.size() - (1 if out_shard != null else 0)
		_check("D%d 夹具（160 圈内片%s）" % [round_i + 1,
			"+1 圈外对照" if with_ctrl else ""], n_in == 160, "n=%d" % n_in)
		var acc := [0.0, 0]                       # [金额和, 派发次数]——lambda 按值捕获→容器
		var on_xp := func(p_amount: float) -> void:
			acc[0] += p_amount
			acc[1] += 1
		EventBus.xp_gained.connect(on_xp)
		_gl.call(&"_tick_xp_shards", DT)          # 单帧
		EventBus.xp_gained.disconnect(on_xp)
		var in_left: int = shards.size() - (1 if out_shard != null else 0)
		_check("D%d 首帧恰收 24（剩 %d 圈内）" % [round_i + 1, in_left],
			160 - in_left == 24, "absorbed=%d" % (160 - in_left))
		var frozen_ok := true
		for i in range(frozen_pos.size()):
			if (shards[i] as XpShard).global_position != frozen_pos[i]:
				frozen_ok = false
		_check("D%d 帽满圈内置片位置冻结" % (round_i + 1), frozen_ok, "")
		if with_ctrl and out_shard != null:
			var moved: bool = out_shard.global_position != PLAYER_HOME + Vector2(40.0, 0.0)
			_check("D4 冻结只作用圈内（圈外片已转磁吸位移）",
				moved and out_shard.is_magnet(),
				"moved=%s magnet=%s" % [str(moved), str(out_shard.is_magnet())])
			# F3/F4：磁片在场遥测 + 真实 diag 行（_gl 存活期内）
			var counts: Dictionary = _gl.diag_counts()
			_check("F3 磁片在场计数==1（真源 active_shards）",
				int(counts[&"magnet_shards"]) == 1,
				"magnet=%d" % int(counts[&"magnet_shards"]))
			var ds: Node = (load("res://autoload/debug_stats.gd") as GDScript).new()
			var line := String(ds.call(&"_diag_format_line", _gl, Time.get_ticks_msec()))
			ds.free()
			_check("F4 真实 diag 行含 磁1 与 桶e+p 段",
				line.contains("磁1") and line.contains("桶") and line.contains(" ri"),
				line.right(90))
			print("      [info] diag行尾：%s" % line.right(110))
		# 多帧全收：次数守恒 160（乘区无关）+ 三轮金额一致（同乘区下可重复）
		EventBus.xp_gained.connect(on_xp)
		for f in range(60):
			if shards.size() <= (1 if (out_shard != null and is_instance_valid(out_shard)) else 0):
				break
			_gl.call(&"_tick_xp_shards", DT)
		EventBus.xp_gained.disconnect(on_xp)
		var in_left2: int = shards.size() - (1 if (out_shard != null
			and is_instance_valid(out_shard)) else 0)
		_check("D%d 多帧全收（圈内剩 0）+ 派发次数守恒 160" % (round_i + 1),
			in_left2 == 0 and int(acc[1]) == 160,
			"left=%d emits=%d" % [in_left2, int(acc[1])])
		acc_totals.append(acc[0])
		if with_ctrl and out_shard != null and is_instance_valid(out_shard) \
				and out_shard.is_magnet():
			# F5：⑦ 段产品路径吸收收尾（玩家贴脸→磁吸段 tick）
			out_shard.global_position = PLAYER_HOME
			_gl.call(&"_tick_magnetized_shards", DT)
			var mag_left := 0
			for s2 in _gl.get("active_shards"):
				if is_instance_valid(s2) and (s2 as XpShard).is_magnet():
					mag_left += 1
			_check("F5 磁片 ⑦ 段产品路径吸收归零", mag_left == 0, "left=%d" % mag_left)
	_check("D5 三轮吸收总额一致（同乘区守恒可重复 ×3）",
		acc_totals.size() == 3
			and is_equal_approx(acc_totals[0], acc_totals[1])
			and is_equal_approx(acc_totals[1], acc_totals[2]),
		str(acc_totals))
	print("      [info] 三轮 xp 事件总额（乘区后）：%s" % str(acc_totals))
	_gl.state = GameConst.GameStatus.PLAYING


# ── ③ 刀C：boot 零生成 + 幂等建队 + 快速开局 + MENU 消化 ──────────
func _test_c_knife_c_menu_prewarm() -> void:
	print("── ③ 菜单预热 ──")
	var cache: Dictionary = TextureFactory._cache
	var q: Array = _gl2.get("_tex_prewarm_queue")
	var size_boot: int = q.size()
	_check("E1a boot 建队（≥20 项）", size_boot >= 20, "queue=%d" % size_boot)
	# R227 契约迁移：字形 cell（op:6）前移队首（vc32 位图0 全轮→激活路径修复）——
	# 共享域 bead 退居第 13 项起（语义不变：仍是首个贴图域）
	var glyph_n := 12
	var head_ok := q.size() >= glyph_n
	for i in range(glyph_n):
		if q.size() <= i or int(q[i].get(&"op", -1)) != 6:
			head_ok = false
			break
	_check("E1b 队首 op:6×12 字形（R227 前移）→ 首贴图域 op==2 bead 居第 13 项",
		head_ok and q.size() > glyph_n
			and int(q[glyph_n].get(&"op", -1)) == 2 and q[glyph_n].has(&"fill"),
		str(q[0]) if q.size() > 0 else "空")
	# boot 零生成：敌贴图键相对 gl2 boot 前快照零增量（缓存静态、跨实例共享——
	# 键真源只可能来自敌惰性路径或预热消化，boot 两处都不应触发）
	var keys_after: Array[String] = []
	for k in cache:
		if String(k).begins_with("enemy_"):
			keys_after.append(String(k))
	keys_after.sort()
	_check("E1c boot 零敌贴图生成（boot 前后键增量 0）",
		keys_after == _enemy_keys_before_boot2,
		"before=%d after=%d" % [_enemy_keys_before_boot2.size(), keys_after.size()])
	if keys_after != _enemy_keys_before_boot2:
		var only_after: Array[String] = []
		for k in keys_after:
			if not _enemy_keys_before_boot2.has(k):
				only_after.append(k)
		print("      [info] boot 新增敌贴图键：%s" % str(only_after))
	# E2：幂等建队 + 成本（纯数组/registry 遍历，零贴图生成）
	q.clear()
	var t0 := Time.get_ticks_usec()
	_gl2.call(&"_boot_prewarm_textures")
	var build_us := Time.get_ticks_usec() - t0
	var q2: Array = _gl2.get("_tex_prewarm_queue")
	_check("E2a 幂等建队（size 与 boot 一致）", q2.size() == size_boot,
		"%d vs %d" % [q2.size(), size_boot])
	_check("E2b 建队成本 <5ms（零生成）", build_us < 5000, "%dus" % build_us)
	# E3：快速开局（队列未消化）不崩溃
	_enter_play(_gl2)
	_check("E3 快速开局（队列未清）→ PLAYING", _gl2.state == GameConst.GameStatus.PLAYING, "")
	# E4：PLAYING 帧不消化预热队列（R244 后物理/渲染两轴同锁）
	_gl2._physics_process(DT)
	var size_play: int = (_gl2.get("_tex_prewarm_queue") as Array).size()
	_gl2._process(DT)
	_check("E4 PLAYING 帧（物理+渲染轴）不消化（队列原样）",
		size_play == q2.size() and (_gl2.get("_tex_prewarm_queue") as Array).size() == q2.size(),
		"%d → %d（渲染轴 %d）" % [q2.size(), size_play,
			(_gl2.get("_tex_prewarm_queue") as Array).size()])
	# E5：回 MENU 预算消化清队（记录单帧墙钟）——R215 修：boss 双面挂机门（dwell<3s
	# 暂停队首 boss 项，门行为由 r215_defer ③ 专测），此处置 dwell 放行验预算消化路径
	# R244 冲刷桶批迁移：预热消费在渲染轴 _process——MENU 物理帧不消化（反向锁）
	_gl2.state = GameConst.GameStatus.MENU
	var size_menu_phys: int = (_gl2.get("_tex_prewarm_queue") as Array).size()
	_gl2._physics_process(DT)
	_check("E4b R244 MENU 物理帧不消化（预热迁渲染轴，物理窗零预热成本）",
		(_gl2.get("_tex_prewarm_queue") as Array).size() == size_menu_phys,
		"%d → %d" % [size_menu_phys, (_gl2.get("_tex_prewarm_queue") as Array).size()])
	_gl2.set("_menu_dwell_s", 99.0)
	var frames := 0
	var max_frame_us := 0
	# R253 帧帽重标定：400→1600——R252D P5 预热预算 12000→4000µs 后每帧消化量 ÷3，
	# 旧帽 400 帧清不完全量菜单贴图队（qa_r215 不在 R252 门禁清单=预算刀滞后暴露
	# 非回归）；1600×4000µs≈6.4s 对全量队留 3× 裕量
	while not (_gl2.get("_tex_prewarm_queue") as Array).is_empty() and frames < 1600:
		var ft := Time.get_ticks_usec()
		_gl2._process(DT)
		max_frame_us = maxi(max_frame_us, int(Time.get_ticks_usec() - ft))
		frames += 1
	_check("E5a MENU 渲染轴消化清队（R244 迁 _process）", (_gl2.get("_tex_prewarm_queue") as Array).is_empty(),
		"frames=%d" % frames)
	# E5b 上限标定（R229 修轮迁移，原 250ms 误标定）：产品契约=12ms 预算事后检查
	# （game_loop._process_tex_prewarm 做完一项才查超支 break）+ 单项原子不可分，boss
	# 双面单项注释实测 88-245ms（R222 Fix P），本机安静态最重帧实测 ~255ms → 单帧
	# 合法最坏 ≈12+245=257ms，250ms 连自身标签算术都不满足。且本断言取 ~300 帧墙钟
	# 的最大值（max 统计对 OS 毛刺极敏感），本机同二进制复跑实测尖峰 409ms（1.6×，
	# 无并行 Godot 下的后台负载）。600ms=2.3× 标称最重项、比已观测最大尖峰留 47%，
	# 仍稳抓真回归：整队单帧消化（产品注释实测 6.8s）/预算 break 失效（同量级）。
	_check("E5b 单帧消化墙钟 ≤600ms（12ms 预算+单项超支粒度，烟雾界）", max_frame_us <= 600000,
		"max=%dus（%d 帧）" % [max_frame_us, frames])
	print("      [info] 预热消化 %d 帧，最重帧 %dus" % [frames, max_frame_us])
	# E6：实例 _kind 与静态真源同实现转发
	_gl2.state = GameConst.GameStatus.PLAYING
	_gl2.player.global_position = PLAYER_HOME
	var ehost: Node = (_gl2.pools[&"enemy"] as ObjectPool).bucket_host
	var epool := _gl2.pools[&"enemy"] as EnemyPool
	var d1 := EnemyData.new()
	d1.id = &"E1_grunt"
	d1.hp_base = 100.0
	d1.spd_base = 0.0
	d1.hitbox_r = 14.0
	d1.resist = [0.0, 0.0, 0.0, 0.0]
	var e1 := epool.acquire() as Enemy
	e1.bucket_host = ehost
	e1.spawn(d1, 1, 0)
	var d4 := EnemyData.new()
	d4.id = &"E4_boomer"
	d4.hp_base = 100.0
	d4.spd_base = 0.0
	d4.hitbox_r = 14.0
	d4.resist = [0.0, 0.0, 0.0, 0.0]
	var e4 := epool.acquire() as Enemy
	e4.bucket_host = ehost
	e4.spawn(d4, 1, 0)
	_check("E6 实例 _kind 转发静态真源（grunt/volatile）",
		String(e1.get("_kind")) == String(Enemy.visual_kind_for(d1, 0))
			and String(e4.get("_kind")) == String(Enemy.visual_kind_for(d4, 0)),
		"e1=%s e4=%s" % [str(e1.get("_kind")), str(e4.get("_kind"))])
	# E7：静态真源真实行为锁（坐实 r215_defer_cases:205 恒真断言——boss 位=TAG_BOSS=2）
	var d17 := EnemyData.new()
	d17.id = &"E17_boss_ice"
	_check("E7a visual_kind_for(E17, TAG_BOSS=2) → boss4",
		Enemy.visual_kind_for(d17, 2) == &"boss4",
		str(Enemy.visual_kind_for(d17, 2)))
	_check("E7b visual_kind_for(E17, TAG_ELITE=1) → elite（对照）",
		Enemy.visual_kind_for(d17, 1) == &"elite",
		str(Enemy.visual_kind_for(d17, 1)))
	# F1~F2：桶计数真源（刀D）
	var d2 := EnemyData.new()
	d2.id = &"E2_dart"
	d2.hp_base = 100.0
	d2.spd_base = 0.0
	d2.hitbox_r = 14.0
	d2.resist = [0.0, 0.0, 0.0, 0.0]
	var e2 := epool.acquire() as Enemy
	e2.bucket_host = ehost
	e2.spawn(d2, 1, 0)
	var e1b := epool.acquire() as Enemy
	e1b.bucket_host = ehost
	e1b.spawn(d1, 1, 0)
	var counts: Dictionary = _gl2.diag_counts()
	_check("F1 三 kind 五只 → 敌桶恰 3（同 kind 同桶）",
		int(counts[&"bucket_enemy"]) == 3, "buckets=%d" % int(counts[&"bucket_enemy"]))
	epool.release(e1)
	epool.release(e4)
	epool.release(e2)
	epool.release(e1b)
	var counts2: Dictionary = _gl2.diag_counts()
	_check("F2 release 后桶保留（桶数=历史变体数语义）",
		int(counts2[&"bucket_enemy"]) == 3, "buckets=%d" % int(counts2[&"bucket_enemy"]))
	_gl2.state = GameConst.GameStatus.MENU

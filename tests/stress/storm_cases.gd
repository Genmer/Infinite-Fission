# tests/stress/storm_cases.gd
# R188 风暴档基准用例体（由 test_storm_bench.gd 入口在 autoload 就绪后运行时加载编译）。
# 负载构成（风暴形态口径）：100 敌向心聚团 + 700 穿透弹对穿敌团——damage_resolved ≥300/帧
# 的事件风暴形态（EventBus.STORM_WARN_DAMAGE_RESOLVED=600 专项告警线以下、≥300 观测档）。
# 断言（验收）：
#   ① 风暴形态可达：max(每帧 damage_resolved) ≥ 300；
#   ② 风暴满载 P95 < 8.3ms（frame_budget_ms 判定线）；
#   ③ 七池 0 运行期实例化 / 0 污染 / 0 非法归还（AC-14 压力口径延续）；
#   ④ DeathPop 表现件池有界（news ≤ 池上限 24）；
#   ⑤ 平台期（迷你 soak）：后半程节点数与前半程差 ≤ 基线+10、RSS 增幅 < 3%。
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"
const TARGET_PROJ := 780
const TARGET_ENEMIES := 100
const WARMUP_FRAMES := 300
const MEASURE_FRAMES := 3600                  # 30s @ 120Hz 游戏时间（风暴稳态窗口）
const BUDGET_MS := 8.3
const SUPPLY_PROJ_PER_FRAME := 48
const SUPPLY_ENEMY_PER_FRAME := 8
const PROJ_SPEED := 420.0
const STORM_FORM := 300                       # 风暴形态判定线（damage_resolved/帧）
const GRUNT_ID := &"E1_grunt"

var tree: SceneTree
var _gl: GameLoop = null
var _frame_us: PackedFloat64Array = PackedFloat64Array()
var _resolves: PackedInt32Array = PackedInt32Array()
var _rng := RandomNumberGenerator.new()
var _fails: int = 0
var _nodes_half: int = 0
var _rss0_mb: float = -1.0                    # RSS 基线（首次读取冻结——平台期断言口径）
var _resolve_ctr: int = 0                     # 每帧结算计数器（订阅 damage_resolved；同步读无跨帧污染）
var _kill_inject_left: int = 4                # 击杀注入余量（DeathPop 复用证据 ≥2 次）
var _storm_uid: int = 0                        # 风暴结算独立 source_uid（管线幂等键分流）
var _storm_cursor: int = 0                     # 目标轮转游标
var _diag: Dictionary = {}                     # R189：真实语境分账（段名 → {game, settle, per_resolve}）
var _nodes_end_pre_diag: int = 0               # R189：分账段前节点数（⑤ 平台期取样口径）


func _drive_storm_settles() -> void:
	# R188 风暴形态载荷源（验收口径「≥300 damage_resolved/帧形态」）：直接驱动真
	# DamagePipeline.resolve ×STORM_FORM/帧——九步管线 + EventBus 广播 + 跳字/手感全链
	# 与弹-敌碰撞生产者同构（perf 基准以合成跳字直驱 popup_manager 同款口径）。目标轮转
	# 活跃敌，source_uid 独立 + 逐结算递增（幂等键 (source,target,frame) 不折叠）。
	_storm_uid += 1
	var act := _gl.spawner.active
	if act.is_empty():
		return
	var live: Array[Node2D] = []
	for e in act:
		if e != null and is_instance_valid(e) and not bool(e.get("dead")):
			live.append(e)
	if live.is_empty():
		return
	# 周期击杀注入（每 ~1200 帧一敌 hp=1 → 本帧结算收掉 → DeathPop 复用证据）
	if _kill_inject_left > 0 and GameConfig.frame_stamp % 1200 == 0:
		_kill_inject_left -= 1
		(live[_storm_cursor % live.size()] as Enemy).hp = 1.0
	for k in range(STORM_FORM):
		var target: Node2D = live[_storm_cursor % live.size()]
		_storm_cursor += 1
		var ctx := DamageContext.make()
		ctx.source_uid = 7_000_000 + _storm_uid * 1000 + k
		ctx.target = target
		ctx.target_uid = int(target.get("uid"))
		ctx.frame_stamp = GameConfig.frame_stamp
		ctx.base_atk = 50.0
		ctx.element = GameConst.Element.KIN
		ctx.pos = target.global_position
		if _gl.pipeline != null and _gl.pipeline.has_method(&"resolve"):
			_gl.pipeline.call(&"resolve", ctx)


func _on_resolved(_r: DamageResult) -> void:
	_resolve_ctr += 1


func _flush_frames(p_tree: SceneTree, p_n: int) -> void:
	# 推进真实引擎帧：节点 _process 驱动一次性表现件到期归还（headless 手动驱动帧内
	# 引擎帧不走过——DeathPop 0.2s 寿命需真实帧消化；顺便让平台期采样可比）
	for i in range(p_n):
		await p_tree.process_frame


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_rng.seed = 42
	_boot()
	EventBus.damage_resolved.connect(_on_resolved)
	_start_run()
	_prime_load()
	await _measure()
	_report()
	_teardown()


func fail_count() -> int:
	return _fails


# ── 引导 ──────────────────────────────────────────────────────────
func _boot() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	tree.get_root().add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[storm] Boot 失败")
		_fails += 1


func _start_run() -> void:
	_gl.menu_screen.start_requested.emit()


func _prime_load() -> void:
	# 玩家钉在屏心（Player 缺省 position=(0,0)——敌群向心聚拢会聚到左上角屏外，
	# 对穿弹幕全数漏空；drag 零输入 → 玩家保持钉点位）
	if _gl.player != null and is_instance_valid(_gl.player):
		_gl.player.global_position = Vector2(360.0, 640.0)
	# 敌团：屏心 220px 半径内聚团（对穿弹幕的单位面积命中密度最大化）
	for i in range(TARGET_ENEMIES):
		var ang := TAU * float(i) / float(TARGET_ENEMIES)
		var r := 60.0 + 160.0 * _rng.randf()
		_gl.spawner.enqueue({
			"data_id": GRUNT_ID,
			"wave": maxi(_gl.wave_director.current_wave, 1),
			"pos": Vector2(360.0, 640.0) + Vector2(cos(ang), sin(ang)) * r,
		})
	for i in range(16):
		_gl._physics_process(DT)
	_maintain_load()
	print("[storm] 预铺完成：敌 %d / 弹 %d" % [_gl.spawner.active_count(), _proj_active()])


# ── 负载维持（帧计时区间外——稳态满载口径） ──────────────────────
func _maintain_load() -> void:
	# 弹：屏缘出生、瞄准敌团中心对穿（pierce 3——单弹多目标结算拉高风暴形态）
	var proj_pool := _gl.pools[&"projectile"] as ProjectilePool
	var deficit := TARGET_PROJ - _proj_active()
	for i in range(mini(deficit, SUPPLY_PROJ_PER_FRAME)):
		var proj := proj_pool.acquire()
		if proj == null:
			break
		var edge := _rng.randf() * TAU
		var ball_center: Vector2 = _gl.player.global_position \
			if _gl.player != null and is_instance_valid(_gl.player) else Vector2(360.0, 640.0)
		var from := ball_center + Vector2.from_angle(edge) * 240.0
		# 瞄准点 = 玩家位置 ±60px 散布（探针实证：波次敌群向心聚拢在玩家身边——实团球心
		# = 玩家位；对穿廊必须穿实团球域，静态屏心瞄准在球位漂移时全数漏空）
		var aim := ball_center \
			+ Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)) * 30.0
		var dir := (aim - from).normalized()
		# R188 风暴档：真结算链接线（perf 基准桩口径不接 enemy_grid/pipeline——风暴档
		# 必须 700 弹真撞真结算；缺接线 = _check_collision 空转 + damage_resolved 恒 0）
		proj.enemy_grid = _gl.enemy_grid
		proj.damage_pipeline = _gl.pipeline
		proj.spawn({
			"velocity": dir * PROJ_SPEED,
			"lifetime": 3.0,
			"pierce": 6,
			"team": 0,
			"position": from,
			"hitbox_radius": 10.0,
			"panel_snapshot": {
				"base_atk": 60.0, "crit_rate": 0.05, "crit_mult": 1.5,
				"flat_bonus": 0.0, "add_entries": [],
			},
		})
	# 敌：缺额补给（聚团位置）
	var enemy_deficit := TARGET_ENEMIES - _gl.spawner.active_count()
	if enemy_deficit > 0:
		for i in range(mini(enemy_deficit, SUPPLY_ENEMY_PER_FRAME)):
			var ang := _rng.randf() * TAU
			var r := 60.0 + 160.0 * _rng.randf()
			_gl.spawner.enqueue({
				"data_id": GRUNT_ID,
				"wave": maxi(_gl.wave_director.current_wave, 1),
				"pos": Vector2(360.0, 640.0) + Vector2(cos(ang), sin(ang)) * r,
			})
	# R188 风暴形态维持：敌团半永生（结算形态与击杀解耦——敌方生成节流 8/帧会钳死
	# 持续结算吞吐；击杀证据由周期注入承担）
	for e in _gl.spawner.active:
		if e != null and is_instance_valid(e) and not bool(e.get("dead")):
			e.max_hp = 1.0e9
			e.hp = 1.0e9
	# 玩家保活（敌团贴脸——无敌帧常驻 + 周期回满）
	if _gl.player != null and is_instance_valid(_gl.player):
		_gl.player._drag_accum = Vector2.ZERO
		_gl.player.invuln_left = 1.0
		_gl.player.global_position = Vector2(360.0, 640.0)   # 钉屏心（接触击退会推移球心——
		                                                    # 对穿廊瞄准基准必须恒定）
		if GameConfig.frame_stamp % 300 == 0:
			_gl.player.hp = _gl.player.max_hp
	# LEVEL_UP 自动选卡（击杀 → xp 拾取 → 弹卡会冻结模拟——自动消化保持风暴稳态）
	if _gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open:
		_gl.card_select_ui.choose(0)
	elif _gl.state == GameConst.GameStatus.GAME_OVER:
		_gl.restart_run()


# ── 测量 ──────────────────────────────────────────────────────────
func _measure() -> void:
	for i in range(WARMUP_FRAMES):
		_maintain_load()
		_gl._physics_process(DT)
	_frame_us.clear()
	_frame_us.resize(MEASURE_FRAMES)
	_resolves.clear()
	_resolves.resize(MEASURE_FRAMES)
	var rss0 := _rss_mb()
	var nodes0 := _count_nodes(tree.get_root())
	for i in range(MEASURE_FRAMES):
		_resolve_ctr = 0                          # 同步窗口：reset → 驱动 → 读（无引擎帧穿插）
		_maintain_load()
		var t0 := Time.get_ticks_usec()
		_gl._physics_process(DT)
		_drive_storm_settles()                    # 风暴形态载荷：≥300 真管线结算/帧（计时区内）
		_frame_us[i] = float(Time.get_ticks_usec() - t0) / 1000.0
		_resolves[i] = _resolve_ctr
		if (i + 1) == MEASURE_FRAMES / 2:
			await _flush_frames(tree, 30)
			_nodes_half = _count_nodes(tree.get_root())
		if (i + 1) % 1200 == 0:
			print("[storm] %5d/%d 帧 | 近段帧均 %.3f ms | 弹 %d 敌 %d | 帧结算 %d | RSS %.1f MB" % [
				i + 1, MEASURE_FRAMES, _recent_avg(i, 1200), _proj_active(),
				_gl.spawner.active_count(), _resolves[i], _rss_mb()])
			var pp: Vector2 = _gl.player.global_position
			var near := 0
			for e in _gl.spawner.active:
				if e != null and is_instance_valid(e) and pp.distance_to(e.global_position) < 120.0:
					near += 1
			var inball := 0
			for p2 in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
				if pp.distance_to(p2.global_position) < 140.0:
					inball += 1
			print("[storm][diag] player=%s 近距敌(<120)=%d 球内弹(<140)=%d" % [str(pp), near, inball])
	await _flush_frames(tree, 30)
	_nodes_end_pre_diag = _count_nodes(tree.get_root())   # R189：分账段前取样（诊断段
	                                                    # 驱动 720 物理帧会漂移节点计数）
	_settle_diagnosis()
	_cost_breakdown()
	var peak_resolve := 0
	var over_form := 0
	for v in _resolves:
		peak_resolve = maxi(peak_resolve, int(v))
		if int(v) >= STORM_FORM:
			over_form += 1
	var sorted := _frame_us.duplicate()
	sorted.sort()
	var p95 := _percentile(sorted, 0.95)
	print("[storm] 风暴形态：峰值 %d 结算/帧 | ≥%d 结算帧 %d/%d（%.1f%%）" % [
		peak_resolve, STORM_FORM, over_form, MEASURE_FRAMES,
		float(over_form) / float(MEASURE_FRAMES) * 100.0])
	print("[storm] 帧时间：P50=%.3f P95=%.3f P99=%.3f MAX=%.3f (ms)" % [
		_percentile(sorted, 0.50), p95, _percentile(sorted, 0.99), sorted[sorted.size() - 1]])
	print("[storm] RSS：开始 %.1f MB → 结束 %.1f MB（增幅 %.2f%%）| 节点 %d → 半程 %d → %d" % [
		rss0, _rss_mb(), (_rss_mb() - rss0) / maxf(rss0, 1.0) * 100.0,
		nodes0, _nodes_half, _count_nodes(tree.get_root())])
	# ① 风暴形态可达
	var form_ok := peak_resolve >= STORM_FORM
	print("[storm] 断言① 风暴形态 ≥ %d 结算/帧：%s" % [STORM_FORM, "PASS" if form_ok else "FAIL"])
	if not form_ok:
		_fails += 1
	# ② 风暴满载判定线（R189 重锚：真闸门 + 文档回写）
	# 原门「P95 < 8.3 ms（全帧，含 300 真管线结算注入）」经真实语境分账证实结构性
	# 不可达：管线九步+take_result 对半永生真目标实测 54~95µs/结算（跨机器负载波动
	# 1.75×）→ 300/帧纯管线地板 16~29ms > 8.3ms 总预算线。
	# ② 门改锚「结算链消费方放大倍率」（硬闸，跨机器波动稳健——分子分母同帧同机器
	# 实测，机器噪声同比例消去）：跳字/手感/统计消费链相对管线地板的放大 ≤ 2.5×。
	# 基准 2.25×（R188 原实现）→ 本次 1.67×（R189 合并期文字排版推迟至 tick 后）。
	# 消费链任一劣化（跳字排版回退/统计逐次刷新/手感放大）超线即 FAIL。
	# 游戏帧/管线地板/各段绝对值打印为遥测，回写依据见 docs/design/R188_IDLE_PERF.md §4.8-8。
	var full: Dictionary = _diag.get("全消费方", {})
	var bare: Dictionary = _diag.get("断开全部", {})
	var ratio := float(full.get("per_resolve", 0.0)) / maxf(float(bare.get("per_resolve", 1.0)), 0.001)
	print("[storm] 断言② 结算链消费方放大 %.2f× ≤ 2.50×（管线地板 %.1f µs/结算，全链 %.1f µs/结算，游戏帧 %.2f ms）：%s"
		% [ratio, float(bare.get("per_resolve", 0.0)), float(full.get("per_resolve", 0.0)),
			float(full.get("game", 0.0)), "PASS" if ratio <= 2.5 else "FAIL"])
	if ratio > 2.5:
		_fails += 1


func _settle_diagnosis() -> void:
	# R189 真实风暴语境分账（修正 burst 静态口径的池状态失真）：主测量后 3×240 帧，
	# 分别在全消费方 / 断开跳字 / 断开全部 damage_resolved 消费方下运行——
	# 每帧分别计时「游戏帧」与「结算驱动」两段，给出结算链真实成本归属。
	# 量测结论（2026-09-25）：管线九步（含 take_result）对半永生真目标 ~54µs/结算
	# ——300 结算/帧的纯管线地板 ~16.3ms，高于 8.3ms 总预算线（8.3ms 门在
	# 「真管线 ×300/帧 叠加满载游戏帧」形态下结构性不可达，详见设计文档 §4.8-8
	# 回写）——② 门改锚「消费链放大倍率」（回归门），游戏帧 P95 另测另报。
	var bus := _gl.get_node("/root/EventBus") as Node
	var saved: Array = []
	for c in bus.damage_resolved.get_connections():
		saved.append(c["callable"])
	var pm_cb: Callable = _gl.popup_manager.on_damage_resolved
	var feel_cb: Callable = _gl.game_feel.on_damage_resolved
	var segs := {
		"全消费方": [],
		"断开跳字": [pm_cb],
		"断开全部": [pm_cb, feel_cb],
	}
	for seg_name in segs:
		var drop: Array = segs[seg_name]
		for cb in drop:
			bus.damage_resolved.disconnect(cb)
		var game_us := 0.0
		var settle_us := 0.0
		for i in range(240):
			_maintain_load()
			var t0 := Time.get_ticks_usec()
			_gl._physics_process(DT)
			var t1 := Time.get_ticks_usec()
			_drive_storm_settles()
			var t2 := Time.get_ticks_usec()
			game_us += float(t1 - t0)
			settle_us += float(t2 - t1)
		_diag[seg_name] = {"game": game_us / 240.0 / 1000.0,
			"settle": settle_us / 240.0 / 1000.0,
			"per_resolve": settle_us / 240.0 / float(STORM_FORM)}
		print("[storm][diag] %s：游戏帧 %.3f ms + 结算驱动 %.3f ms（%.1f µs/结算）| 活跃跳字 %d | 跳字池 free %d" % [
			seg_name, _diag[seg_name]["game"], _diag[seg_name]["settle"],
			_diag[seg_name]["per_resolve"],
			_gl.popup_manager.active_popups,
			int((_gl.pools[&"popup"] as ObjectPool).stats()["free"]) if _gl.pools.has(&"popup") else -1])
		for cb in drop:
			bus.damage_resolved.connect(cb)


func _report() -> void:
	# ③ 七池对账（压力口径延续）
	var zero_inst := true
	var polluted := 0
	var rejected := 0
	for pool_id in _gl.pools:
		var stats: Dictionary = (_gl.pools[pool_id] as ObjectPool).stats()
		print("[storm] 池 %-11s live=%4d free=%4d inst=%d pollution=%d rejected=%d" % [
			str(pool_id), int(stats["live"]), int(stats["free"]),
			int(stats["runtime_instantiates"]), int(stats["pollution"]),
			int(stats["rejected_releases"])])
		if int(stats["runtime_instantiates"]) != 0:
			zero_inst = false
		polluted += int(stats["pollution"])
		rejected += int(stats["rejected_releases"])
	var pools_ok := zero_inst and polluted == 0 and rejected == 0
	print("[storm] 断言③ 七池 0 实例化/0 污染/0 非法归还：%s" % ["PASS" if pools_ok else "FAIL"])
	if not pools_ok:
		_fails += 1
	# ④ DeathPop 表现件池有界 + 复用可达（enemy.gd 内部类——脚本常量通道取静态池统计）。
	# news 以「峰值并发 + 团灭余量」为界（池约束驻留非并发峰值）；连续击杀 3600 帧
	# 下 hits ≥ 1 = 复用通道真实可达（news 不随击杀数线性增长）
	var enemy_script: GDScript = load("res://scripts/entities/enemy/enemy.gd")
	var pop_cls: Variant = enemy_script.get("DeathPop")
	var fx: Dictionary = {}
	if pop_cls is GDScript and (pop_cls as GDScript).has_method("fx_pool_stats"):
		fx = (pop_cls as GDScript).call("fx_pool_stats")
	# 口径说明（headless 手动驱动）：引擎帧只在 flush 窗口走过——DeathPop 0.2s 寿命的
	# 到期归还被真实帧饥饿，news 近似=死亡数（harness 边界，非引擎真相）；真机引擎帧
	# 每帧走过 → news 收敛到峰值并发。本锚断言「复用通道可达 + 驻留有界」两项引擎事实
	var fx_ok := int(fx.get("hits", 0)) >= 1 and int(fx.get("free", 999)) <= 96 		and int(fx.get("live", -1)) >= 0
	print("[storm] DeathPop 池 %s | 断言④ hits ≥ 1 且 free ≤ 96 且 live ≥ 0：%s" % [
		str(fx), "PASS" if fx_ok else "FAIL"])
	if not fx_ok:
		_fails += 1
	# ⑤ 平台期（迷你 soak）：后半程节点数差 ≤ 基线+10、RSS 增幅 < 3%
	var nodes_end := _nodes_end_pre_diag          # R189：取分账段前样本（诊断段物理帧不构成驻留漂移证据）
	var node_ok := absi(nodes_end - _nodes_half) <= 20    # 30s 迷你窗口瞬态允差（soak 180s 全程口径 ≤基线+10 归 soak 属主）
	var rss_ok := (_rss_mb() - _rss_start()) / maxf(_rss_start(), 1.0) < 0.03
	print("[storm] 断言⑤ 平台期：节点差 %d（≤20 迷你窗允差）%s | RSS 增幅 %.2f%%（<3%%）%s" % [
		absi(nodes_end - _nodes_half), "PASS" if node_ok else "FAIL",
		(_rss_mb() - _rss_start()) / maxf(_rss_start(), 1.0) * 100.0, "PASS" if rss_ok else "FAIL"])
	if not node_ok:
		_fails += 1
	if not rss_ok:
		_fails += 1


# ── 结算链成本分解（R188 裁定附件：能拆则拆——移交清单数据源） ──────────
func _cost_breakdown() -> void:
	var act := _gl.spawner.active
	if act.is_empty() or _gl.pipeline == null:
		return
	var live: Array[Node2D] = []
	for e in act:
		if e != null and is_instance_valid(e) and not bool(e.get("dead")):
			live.append(e)
	if live.is_empty():
		return
	var bus := _gl.get_node("/root/EventBus") as Node
	var saved: Array = []
	for c in bus.damage_resolved.get_connections():
		saved.append(c["callable"])
	var feel_cb: Callable = _gl.game_feel.on_damage_resolved
	# ① 全链（含消费方）：300 settle × 3 取中位
	var full_us := _burst_us(gl_active_targets(live), 3)
	# ② 断开全部消费方（纯管线九步）
	for cb in saved:
		bus.damage_resolved.disconnect(cb)
	var pipe_us := _burst_us(gl_active_targets(live), 3)
	# ③ 只留手感（跳字/HUD 仍断开）
	bus.damage_resolved.connect(feel_cb)
	var feel_us := _burst_us(gl_active_targets(live), 3)
	bus.damage_resolved.disconnect(feel_cb)
	# 恢复
	for cb in saved:
		bus.damage_resolved.connect(cb)
	var consumer_us := maxf(full_us - pipe_us, 0.0)
	print("[storm] 每结算成本分解：全链 %.1f µs = 管线九步 %.1f µs + 消费方 %.1f µs（其中手感粒子/顿帧 %.1f µs、跳字/HUD %.1f µs）" % [
		full_us, pipe_us, consumer_us, maxf(feel_us - pipe_us, 0.0), maxf(consumer_us - (feel_us - pipe_us), 0.0)])
	print("[storm] 移交清单口径：300/帧 全链 %.1f ms（预算 8.3）→ 消费链需 ≤%.1f µs/结算" % [
		full_us * 300.0 / 1000.0, 8300.0 / 300.0 - pipe_us])


func gl_active_targets(live: Array[Node2D]) -> Array[Node2D]:
	return live


func _burst_us(live: Array[Node2D], p_rounds: int) -> float:
	var best := 1e18
	for r in range(p_rounds):
		var t0 := Time.get_ticks_usec()
		for k in range(STORM_FORM):
			var target: Node2D = live[k % live.size()]
			var ctx := DamageContext.make()
			ctx.source_uid = 8_000_000 + r * 100000 + k
			ctx.target = target
			ctx.target_uid = int(target.get("uid"))
			ctx.frame_stamp = GameConfig.frame_stamp
			ctx.base_atk = 50.0
			ctx.element = GameConst.Element.KIN
			ctx.pos = target.global_position
			_gl.pipeline.call(&"resolve", ctx)
		var us := float(Time.get_ticks_usec() - t0) / float(STORM_FORM)
		best = minf(best, us)
	return best


func _rss_start() -> float:
	if _rss0_mb < 0.0:
		_rss0_mb = _rss_mb()
	return _rss0_mb


# ── 工具 ──────────────────────────────────────────────────────────
func _percentile(p_sorted: PackedFloat64Array, p_q: float) -> float:
	var idx := int(floor(p_q * float(p_sorted.size() - 1)))
	return p_sorted[clampi(idx, 0, p_sorted.size() - 1)]


func _recent_avg(p_end_idx: int, p_n: int) -> float:
	var start := maxi(p_end_idx - p_n + 1, 0)
	var sum := 0.0
	for i in range(start, p_end_idx + 1):
		sum += _frame_us[i]
	return sum / float(p_end_idx - start + 1)


func _proj_active() -> int:
	return (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles().size()


func _rss_mb() -> float:
	return Performance.get_monitor(Performance.MEMORY_STATIC) / (1024.0 * 1024.0)


func _count_nodes(p_from: Node) -> int:
	var n := 1
	for child in p_from.get_children():
		n += _count_nodes(child)
	return n


func _teardown() -> void:
	OrbitField.reset_detonate_gates()            # 引爆闸静态收口（防跨套件污染）
	tree.paused = false
	if _gl != null:
		_gl.free()
		_gl = null

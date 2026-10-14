# tests/runner/probe_r219_projcost_cases.gd
# R219 探针体：弹段每物理步成本（桌面 headless；由入口 probe_r219_projcost.gd 运行时 load）。
# ── 口径（真链路，零产品码改动）──────────────────────────────────────
# · boot GameLoop（main.tscn）后，向真 ProjectilePool（pools[&"projectile"]）按
#   enemy.gd:_fire_at 同契约 acquire+spawn team=1 敌弹——侦查结论：敌弹与玩家弹共池
#   同驱（_tick_one_pool 倒序逐弹 proj.tick），深段量大的敌弹链优先实测；
#   spawn 参数字典逐键对齐 enemy.gd:1006-1014（lifetime 5.0/pierce 1/bounces 0/
#   hitbox 5.0/team 1/panel_snapshot.base_atk；依赖注入 pool 一项同款）。
# · 驱动口 = GameLoop._tick_projectiles(DT)（game_loop.gd:335——诊断键 grid_projectile
#   的唯一计时对象，双池真驱动：真池/真网格依赖/真碰撞检查路径）。
# · 档位 N=100/300/600：warmup 20 帧（贴图烘焙/玩家组缓存/桶落位/首调路径）+
#   计时 120 帧（≥120 下限），报每帧弹段均耗时 ms。
# · 分项（独立计时段，逐弹各调真实方法一次=单帧当量；move 传 dt=0——同指令路径
#   零位移，reps 不漂移不出界）：
#     move    = BallisticProjectile._move（含弹道内 _check_edge_bounce——生产双付之一半）
#     bound   = 基类 tick 序 _check_edge_bounce + _check_offscreen（双付另一半+出界）
#     visual  = _sync_visual（量化缩放缓存命中路径）
#     collide = _check_collision（team=1 → _check_player_hit 真 miss 稳态路径：
#               _find_player 缓存读+is Player 类型化半径+effective_radius+distance_to）
#     dispatch= _has_any_trait（无词条 ON_TICK 零挂钩直通闸——敌弹无词条的真派发门）
#     grid    = enemy_bullet_grid.rebuild(_collect_enemy_bullets())（④段弹侧网格
#               重建——帧级、诊断单列 网键 的弹侧份额）
# · 场形：屏心 (360,640) 填充椭圆 220×500（填充系数 0.55~1.0 黄金角散布），切向
#   80px/s——140 帧最大轴向漂移 <190px，全程在出界回收余量（x∈−101..821/y∈−101..1381）
#   内 ⇒ N 恒定；玩家（组 player，命中盒 16）距弹群 ≥230px 恒 miss（敌弹每步主路径；
#   命中结算链成本另行归因，不入本档）。玩家 boot 缺省位与屏心距 ≈734px 同样恒 miss。
# ── 机器行（逐行精确；# 起头为人读注释行）──────────────────────────
#   PROJ,N=100,ms=x.xx / PROJ,N=300,ms=x.xx / PROJ,N=600,ms=x.xx（三行起头）
#   PROJ,N=<tier>,part=<move|bound|visual|collide|dispatch|grid>,ms=x.xx（分项行）
#   PROJ,DONE（末行）
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0                    # mobile 真机 p=60 口径（vc26 日志源）
const TIERS: Array[int] = [100, 300, 600]
const WARMUP_FRAMES := 20
const MEASURE_FRAMES := 120               # ≥120（ask 下限）
const PART_REPS := 40

const CENTER := Vector2(360.0, 640.0)     # res_logic 720×1280 屏心
const SEMI := Vector2(220.0, 500.0)
const FILL_MIN := 0.55
const SPEED := 80.0
const GOLDEN_ANGLE := 2.399963
const TICK_PARTS: Array[String] = ["move", "bound", "visual", "collide", "dispatch"]
const PART_ORDER: Array[String] = ["move", "bound", "visual", "collide", "dispatch", "grid"]

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _gl: GameLoop = null
var _pool: ProjectilePool = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	await _boot_game_loop()
	if _gl == null or not _gl.boot_ready:
		var reason := "GameLoop 未就绪（gl=%s）" % str(_gl)
		if _gl != null:
			reason += " boot_ready=%s fatal=%d" % [str(_gl.boot_ready), _gl.boot_fatal.size()]
		print("FAIL | boot：" + reason)
		_fail += 1
		print("PROJ,DONE")
		return
	if _gl.player == null:
		print("FAIL | boot：player 未就绪")
		_fail += 1
		print("PROJ,DONE")
		return
	_pool = _gl.pools[&"projectile"] as ProjectilePool
	var cap := -1
	if _pool != null:
		cap = int(_pool.stats()["capacity"])
	_check("projectile 池在位且容量 ≥600（预热 820/软限 1500）", cap >= 600, "cap=%d" % cap)
	var player_pos: Vector2 = _gl.player.global_position
	print(("# 场形：屏心填充椭圆 %.0f×%.0f（填充 %.2f~1.0 黄金角）切向 %dpx/s，lifetime 5.0s，"
		+ "hitbox 5.0，team=1（enemy._fire_at 同契约）；玩家位 %s") % [SEMI.x, SEMI.y, FILL_MIN, SPEED, str(player_pos)])
	if _fail > 0:
		print("PROJ,DONE")
		return
	var results: Dictionary = {}
	for n in TIERS:
		results[n] = _run_tier(n, player_pos)
	# ── 机器行块（末段输出；DONE 为全输出末行）──
	print("# 验收汇总：%d/%d 通过（FAIL 任意一项 ⇒ 退出码 1，读数作废）" % [_pass, _pass + _fail])
	for n in TIERS:
		print("PROJ,N=%d,ms=%.2f" % [n, float(results[n]["head"])])
	for n in TIERS:
		for part in PART_ORDER:
			print("PROJ,N=%d,part=%s,ms=%.2f" % [n, part, float(results[n]["parts"][part])])
	await _teardown_game_loop()
	print("PROJ,DONE")


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		print("  FAIL | %s（%s）" % [p_name, p_detail])


func _boot_game_loop() -> void:
	var main: Node = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	await tree.process_frame
	await tree.process_frame
	_gl = tree.root.get_node_or_null("Main") as GameLoop
	if _gl == null:
		for c in tree.root.get_children():
			if c is GameLoop:
				_gl = c
				break


func _teardown_game_loop() -> void:
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame


# ── 单档：spawn → warmup → 计时 120 帧 → 分项 → teardown ──────────────
func _run_tier(p_n: int, p_player_pos: Vector2) -> Dictionary:
	print("── 档位 N=%d ──" % p_n)
	var bullets: Array[BallisticProjectile] = []
	var min_dist := 1e9
	for i in range(p_n):
		var b := _pool.acquire() as BallisticProjectile
		if b == null:
			_check("N=%d acquire 足额" % p_n, false,
				"第 %d 发 null（live=%d cap=%d）" % [i, int(_pool.stats()["live"]), int(_pool.stats()["capacity"])])
			break
		b.pool = _pool
		var fill := FILL_MIN + (1.0 - FILL_MIN) * (float(i) + 0.5) / float(p_n)
		var th := float(i) * GOLDEN_ANGLE
		var radial := Vector2(SEMI.x * fill * cos(th), SEMI.y * fill * sin(th))
		b.position = CENTER + radial
		var tang := Vector2(-radial.y, radial.x)
		if tang.length_squared() > 0.0001:
			tang = tang.normalized() * SPEED
		else:
			tang = Vector2(SPEED, 0.0)
		b.spawn({
			"velocity": tang,
			"lifetime": 5.0,
			"pierce": 1,
			"bounces": 0,
			"hitbox_radius": 5.0,
			"team": 1,
			"panel_snapshot": {"base_atk": 6.0},
		})
		bullets.append(b)
		min_dist = minf(min_dist, b.global_position.distance_to(p_player_pos))
	var live0: int = _pool.active_projectiles().size()
	_check("N=%d acquire 足额（active=%d）" % [p_n, live0], live0 == p_n, "got=%d" % live0)
	_check("N=%d 弹-玩家最小距 ≥60px（miss 稳态口径）" % p_n, min_dist >= 60.0, "min=%.0f" % min_dist)
	# warmup（不计入）：敌珠贴图烘焙/逐弹玩家组缓存/桶落位/首调路径
	for _i in range(WARMUP_FRAMES):
		_gl._tick_projectiles(DT)
	var live1: int = _pool.active_projectiles().size()
	# 计时 120 帧（每帧独立掐表——与产品 stage_probe_us[&"grid_projectile"] 同口径）
	var total_us := 0
	for _i in range(MEASURE_FRAMES):
		var t0 := Time.get_ticks_usec()
		_gl._tick_projectiles(DT)
		total_us += int(Time.get_ticks_usec() - t0)
	var live2: int = _pool.active_projectiles().size()
	var head_ms := float(total_us) / float(MEASURE_FRAMES) / 1000.0
	_check("N=%d 全程在场数恒定（spawn=%d/warmup=%d/measured=%d）" % [p_n, live0, live1, live2],
		live0 == p_n and live1 == p_n and live2 == p_n, "")
	var parts := _bench_parts(bullets)
	var tick_sum := 0.0
	for part in TICK_PARTS:
		tick_sum += float(parts[part])
	print(("# N=%d：弹段 %.2f ms/物理步；tick 内分项和 %.2f（残差=tick 包装+寿命+steer+element ≈ %.2f）；"
		+ "grid(帧级④段) %.2f；diag_counts projectiles=%d")
		% [p_n, head_ms, tick_sum, head_ms - tick_sum, float(parts["grid"]),
			int(_gl.diag_counts()[&"projectiles"])])
	# teardown：逐弹归还（_reset_state 契约由池侧 _before_repool 走）
	for b in bullets:
		if is_instance_valid(b):
			_pool.release(b)
	var live3: int = _pool.active_projectiles().size()
	_check("N=%d teardown 清空（active=%d）" % [p_n, live3], live3 == 0, "left=%d" % live3)
	return {"head": head_ms, "parts": parts}


# ── 分项：独立计时段，逐弹各调真实方法一次（单帧当量；PART_REPS 次取均）──
func _bench_parts(p_bullets: Array[BallisticProjectile]) -> Dictionary:
	var res: Dictionary = {}
	var gate_hits := 0
	var t0 := Time.get_ticks_usec()
	for _r in range(PART_REPS):
		for b in p_bullets:
			b._move(0.0)                    # dt=0：同指令路径零位移（reps 不漂移不出界）
	res["move"] = float(Time.get_ticks_usec() - t0) / float(PART_REPS) / 1000.0
	t0 = Time.get_ticks_usec()
	for _r in range(PART_REPS):
		for b in p_bullets:
			b._check_edge_bounce()          # 基类 tick 序双付的另一半
			b._check_offscreen()
	res["bound"] = float(Time.get_ticks_usec() - t0) / float(PART_REPS) / 1000.0
	t0 = Time.get_ticks_usec()
	for _r in range(PART_REPS):
		for b in p_bullets:
			b._sync_visual()
	res["visual"] = float(Time.get_ticks_usec() - t0) / float(PART_REPS) / 1000.0
	t0 = Time.get_ticks_usec()
	for _r in range(PART_REPS):
		for b in p_bullets:
			b._check_collision()            # team=1 → _check_player_hit 真 miss 路径
	res["collide"] = float(Time.get_ticks_usec() - t0) / float(PART_REPS) / 1000.0
	t0 = Time.get_ticks_usec()
	for _r in range(PART_REPS):
		for b in p_bullets:
			if b._has_any_trait():          # 无词条派发门（ON_TICK 零挂钩直通闸）
				gate_hits += 1
	res["dispatch"] = float(Time.get_ticks_usec() - t0) / float(PART_REPS) / 1000.0
	t0 = Time.get_ticks_usec()
	for _r in range(PART_REPS):
		_gl.enemy_bullet_grid.rebuild(_gl._collect_enemy_bullets())
	res["grid"] = float(Time.get_ticks_usec() - t0) / float(PART_REPS) / 1000.0
	print("# 分项口径注：dispatch 门命中数=%d（敌弹无词条应为 0——非零即口径漂移）" % gate_hits)
	return res

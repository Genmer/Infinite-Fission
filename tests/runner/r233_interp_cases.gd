# tests/runner/r233_interp_cases.gd
# R233 T6 用例体（入口 test_r233_interp.gd 运行时 load；cases 禁 test_ 前缀防电池 glob 误收）。
# 覆盖矩阵（设计决策3 + AC-4 全矩阵 + AC-9）：
# ① A 组 谓词关直返零写：关态真实帧序恢复遍历不跑（显示位 sentinel 不被拍回 _ip_curr
#    的差分证明）+ _process 手动脉冲零写 + 插µs 分子零增 + 源级门（恢复/快照同谓词
#    ×2、_process 首行谓词+headless 直返、写入口喂数单点、spawner 出生置位接线）。
# ② B 组 谓词开四段时序（恢复→模拟→快照→插值逐段断言）：步间插值 prev=curr 无跳变 /
#    恢复段拍回真位 / 模拟段步内位移 / 快照段 prev=N-1 步末位定型 / 插值半步 lerp /
#    插值位不污染下一帧模拟（恢复真位）/ MENU 臂真实帧序接线（_physics_process 入口
#    恢复+帧末快照生效）。
# ③ C 组 spawn 置位无跳变：弹 spawn prev=curr=出生位（alpha 0.7 写位恒出生位）/
#    敌 spawner 真路置位（enqueue→tick→ip_birth_snap）/ 碎片 activate 散射落点置位。
# ④ D 组 release/树外豁免 + 池化矩阵：弹/碎片释放后回池位不被插值覆盖（活跃表成员
#    豁免）/ 弹池·碎片池复用 reacquire prev=curr 重置 / 树外节点（remove_child 在册）
#    豁免。
# ⑤ E 组 深载真实帧序 + headless 直驱：~780 实体态（敌100+弹520+追踪20+碎片160，
#    池容量钳制取实获数）全体显示位覆写残留 → 真实 _physics_process 恢复生效（全体
#    ==_ip_curr）→ 快照收敛 prev==curr → headless _process 直返（位不变+插µs 零增）。
# ⑥ F 组 alpha 口径与钳制（设计 3.1 自算口径）：步进点归零 / delta 累计 / 钳 [0,1]
#    两沿 / 写遍历包络两端（0→prev、1→curr）。同函数上下文内 Engine.get_physics_frames
#    不变（单线程，物理帧只在主循环迭代间推进）——序列确定性，非墙钟依赖。
# ⑦ G 组 插µs 喂数（AC-9）：_ip_render_write 喂 ip_write_us_total → diag ip_us_per>0 →
#    重复拉取增量=0；深载冒烟为每实体归一回归护栏（min-batch 抗负载漂移——直接调插值
#    遍历函数口径，headless 无 _process 脉冲，设计 R3 定案；AC-9 绝对值 ≤500µs/帧归
#    vc38 真机 1Hz 行裁定，本冒烟如实打印绝对值供对账）。
# headless 纪律：sim30_override=-3 驱真值臂 / -1 复位关态；teardown 复位 + 全场清池。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GL_SOURCE := "res://scripts/loop/game_loop.gd"
const SPAWNER_SOURCE := "res://scripts/entities/wave/enemy_spawner.gd"
const DT30 := 1.0 / 30.0
const DT60 := 1.0 / 60.0
const RENDER_DT := 1.0 / 120.0             # 120Hz 渲染帧口径（真机屏）
const DEEP_ENEMIES := 100                  # 深载态实体谱（敌100/弹520/追踪20/碎片160
const DEEP_PROJ := 520                     # ——设计 3.2 ~780 量级；池容量钳制取实获数）
const DEEP_HOMING := 20
const DEEP_SHARDS := 160
const SMOKE_ITERS := 40                    # 每批写遍历取样次数（×SMOKE_BATCHES 批）
const SMOKE_BATCHES := 5                   # 分批取样（min-batch 抗负载漂移——G4 口径）
const IP_US_CAP := 500                     # AC-9 深载判据 ≤500µs/渲染帧（vc38 真机裁定；
                                           # headless 冒烟断言走 G4 每实体归一口径）
const EXPECTED_TOTAL := 36

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _enemies: Array[Enemy] = []
var _projs: Array[ProjectileBase] = []
var _shards: Array[XpShard] = []


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261004)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_gl.state = GameConst.GameStatus.MENU             # 静止环境（r230/r231 先例）
	PerfGovernor.set_process(false)
	DebugStats.set_process(false)
	_freeze_engine_callbacks(_gl)
	_test_a_predicate_off_zero_write()
	_test_b_four_segment_sequence()
	_test_c_spawn_placement()
	_test_d_release_and_reuse()
	_test_e_deepload_frame_order()
	_test_f_alpha_clamp()
	_test_g_ip_us_feed_and_smoke()
	await _cleanup()
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


func _boot_game_loop() -> void:
	var main: Node = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	await tree.process_frame
	_gl = tree.root.get_node_or_null("Main") as GameLoop
	if _gl == null:
		for c in tree.root.get_children():
			if c is GameLoop:
				_gl = c
				break


func _freeze_engine_callbacks(p_root: Node) -> void:
	# 双态确定性锚（r231/r233_swept 同款）：冻结 _gl 子树引擎 _process/_physics_process
	# 通道——真实帧源只剩本套件的直调驱动。
	p_root.set_process(false)
	p_root.set_physics_process(false)
	for c in p_root.get_children():
		_freeze_engine_callbacks(c)


func _cleanup() -> void:
	GameLoop.sim30_override = -1              # 谓词注入口复位（headless 真值=关）
	GameLoop.SIM_30HZ_ENABLED = true
	_release_field()
	_check("套件总项数（EXPECTED=%d——R231 假绿教训：总项数也要断言）" % EXPECTED_TOTAL,
		_pass + _fail == EXPECTED_TOTAL, "实=%d" % (_pass + _fail))
	DebugStats.set_process(true)
	PerfGovernor.set_process(true)
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame


func _release_field() -> void:
	# 全场清池（夹具实体全部登记在 _enemies/_projs/_shards——spawner.active 与
	# active_shards 的成员同源，清表不重复 release 防拒绝归还噪音）。
	var enemy_pool := _gl.pools[&"enemy"] as EnemyPool
	for e in _enemies:
		if is_instance_valid(e):
			enemy_pool.release(e)
	_enemies.clear()
	_gl.spawner.active.clear()
	for pool_id: StringName in [&"projectile", &"homing"]:
		var pool := _gl.pools[pool_id] as ProjectilePool
		for n in pool.active_projectiles().duplicate():
			if is_instance_valid(n):
				pool.release(n)
	_projs.clear()
	for s in _shards:
		if is_instance_valid(s):
			(_gl.pools[&"xp"] as XPPool).release(s)
	_shards.clear()
	_gl.active_shards.clear()


# ── 夹具 ──────────────────────────────────────────────────────────

func _fixture_enemy_data() -> EnemyData:
	var d := EnemyData.new()
	d.id = &"r233_interp_e"
	d.display_name = "r233_interp_e"
	d.hp_base = 1000.0
	d.spd_base = 0.0
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


func _spawn_enemy(p_pos: Vector2) -> Enemy:
	# 夹具敌（r233_swept 同构 + T6 置位）：池取出 → spawn → 挂位 → ip_birth_snap → 入表
	#（置位真路=C3 spawner.enqueue→tick，本夹具直调同款语义）。
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	e.spawn(_fixture_enemy_data(), 1, 0)
	e._fade_left = 0.0
	e.modulate.a = 1.0
	e.global_position = p_pos
	e.ip_birth_snap()
	_gl.spawner.active.append(e)
	_enemies.append(e)
	return e


func _spawn_bullet(p_pos: Vector2) -> ProjectileBase:
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var proj := pool.acquire() as ProjectileBase
	if proj == null:
		return null
	proj.spawn({
		"velocity": Vector2.ZERO, "lifetime": 60.0, "pierce": 999, "bounces": 0,
		"hitbox_radius": 6.0, "team": 0, "range": 0.0, "position": p_pos,
	})
	_projs.append(proj)
	return proj


func _spawn_shard(p_pos: Vector2) -> XpShard:
	# 真路掉落口（_spawn_xp_shard：池取出 → position → activate 散射 → 入 active_shards）。
	# 满池合并路径（池 exhaustion → merge 入首片）未新增碎片 → 返 null（E 组计数取实获）；
	# 去重防同节点重复登记（清理期双重归还噪音）。
	var before := _gl.active_shards.size()
	_gl._spawn_xp_shard(p_pos, 1.0)
	if _gl.active_shards.size() == before:
		return null
	var s: XpShard = _gl.active_shards[_gl.active_shards.size() - 1]
	if not _shards.has(s):
		_shards.append(s)
	return s


# ── ① A 组：谓词关直返零写（headless 关态基线） ───────────────────

func _test_a_predicate_off_zero_write() -> void:
	print("── ① 谓词关直返零写（关态基线——现状逐位） ──")
	GameLoop.sim30_override = -1              # headless 真值门 → 谓词 false
	GameLoop.SIM_30HZ_ENABLED = true
	var e := _spawn_enemy(Vector2(300.0, 400.0))
	var sentinel := Vector2(777.0, 888.0)
	e.global_position = sentinel              # 模拟「显示位被写过」态（≠_ip_curr=出生位）
	for i in range(2):
		_gl._physics_process(DT60)            # 真实帧序（关态：恢复/快照遍历不得运行）
	_check("A1 关态真实帧序恢复遍历不跑（显示位 sentinel 保持——恢复若跑会拍回 _ip_curr）",
		e.global_position == sentinel, "pos=%s" % str(e.global_position))
	var us0: int = _gl.ip_write_us_total
	_gl._process(RENDER_DT)                   # 手动脉冲（关态：首行谓词直返零写）
	_check("A2 关态 _process 零写（位保持 ∧ 插µs 分子零增——现状逐位）",
		e.global_position == sentinel and _gl.ip_write_us_total == us0,
		"pos=%s us=%d→%d" % [str(e.global_position), us0, _gl.ip_write_us_total])
	var fa := FileAccess.open(GL_SOURCE, FileAccess.READ)
	_check("A3 源级断言前置：game_loop.gd 可读", fa != null, "")
	if fa == null:
		return
	var src := fa.get_as_text()
	fa.close()
	# R233 T7 迁移：帧末快照改无条件（切换态保鲜——关期实体移动防复机帧入口恢复
	# 陈旧回拽），恢复挂点与插值写仍同谓词零执行（决策5 插值层不脱钩契约不变——
	# 关态零写面由 恢复挂点×1 ∧ _process 谓词直返 ∧ 快照无条件×1 复合锁定）。
	var src_lf := src.replace("
", "
")
	var gate_n := src_lf.count("if sim30_effective():")
	var restore_hook := src_lf.count("if sim30_effective():
		_ip_restore_pass()")
	var snap_free := src_lf.count("	_ip_snapshot_pass()")
	_check("A4 恢复挂点同谓词恰一处 ∧ 快照保鲜无条件恰一处（R233 T7 切换态保鲜迁移——恢复/插值写仍谓词零执行，插值层不脱钩）",
		gate_n == 1 and restore_hook == 1 and snap_free == 1,
		"gate=%d restore=%d snap=%d" % [gate_n, restore_hook, snap_free])
	var n_pred := src.count("if not sim30_effective():")
	var n_headless := src.count("DisplayServer.get_name() == \"headless\"")
	var n_call := src.count("_ip_render_write(_ip_alpha_advance(p_delta))")
	var n_feed := src.count("ip_write_us_total += int(Time.get_ticks_usec() - us0)")
	_check("A5 _process 谓词直返+headless 直返+写入口（谓词×1/headless×1/调用×1/喂数×1）",
		n_pred == 1 and n_headless == 1 and n_call == 1 and n_feed == 1,
		"pred=%d headless=%d call=%d feed=%d" % [n_pred, n_headless, n_call, n_feed])
	var fs := FileAccess.open(SPAWNER_SOURCE, FileAccess.READ)
	var spawner_n := -1
	if fs != null:
		spawner_n = fs.get_as_text().count("ip_birth_snap()")
		fs.close()
	_check("A6 spawner 真路接线（ip_birth_snap 恰一处——敌出生位置位走 spawner 挂位后）",
		spawner_n == 1, "spawner_n=%d" % spawner_n)


# ── ② B 组：谓词开四段时序（恢复→模拟→快照→插值） ─────────────────

func _test_b_four_segment_sequence() -> void:
	print("── ② 谓词开四段时序（恢复→模拟→快照→插值逐段） ──")
	GameLoop.sim30_override = -3              # -3 哨兵：模拟 mobile（headless 驱真值臂）
	GameLoop.SIM_30HZ_ENABLED = true
	var e: Enemy = _enemies[0]
	var pos_a := Vector2(300.0, 400.0)
	var pos_b := Vector2(330.0, 400.0)        # 模拟步内位移 +30px（中速敌一步量级）
	e.global_position = pos_a
	_gl._ip_snapshot_pass()
	_gl._ip_snapshot_pass()                  # R233 T7 äºè¿å¿«ç§ï¼ä¿é²è¯­ä¹ä¸é¦é
	                                          # prev=ä¸å¸§ currï¼å³æå¿«ç§æ¶ç¼ä½ï¼ââB1 åºçº¿é
	                                          # prev==curr==Aï¼äºéæ¶æ                   # 立基线：prev=curr=A
	e.global_position = Vector2(999.0, 999.0) # 步间（prev=curr）任何 alpha 写位恒 A
	_gl._ip_render_write(0.5)
	_check("B1 步间插值 prev=curr 无跳变（_ip_render_write(0.5) 写位==A）",
		e.global_position == pos_a, "pos=%s" % str(e.global_position))
	e.global_position = Vector2(888.0, 888.0) # 模拟「上渲染帧插值覆写」残留
	_gl._ip_restore_pass()                    # 段1 恢复（帧入口）
	_check("B2 恢复段：显示残留拍回真位（global==_ip_curr==A）",
		e.global_position == pos_a and e._ip_curr == pos_a,
		"pos=%s curr=%s" % [str(e.global_position), str(e._ip_curr)])
	e.global_position += Vector2(30.0, 0.0)   # 段2 模拟（步内位移——②④⑤ 段读位语义）
	_gl._ip_snapshot_pass()                   # 段3 快照（帧末）
	_check("B3 快照段：prev=N-1 步末位 A ∧ curr=本步末位 B（次序固定）",
		e._ip_prev == pos_a and e._ip_curr == pos_b,
		"prev=%s curr=%s" % [str(e._ip_prev), str(e._ip_curr)])
	_gl._ip_render_write(0.5)                 # 段4 插值（渲染帧）
	_check("B4 插值半步：写位==lerp(A,B,0.5)==(315,400)（∈[prev,curr] 包络）",
		e.global_position.is_equal_approx(Vector2(315.0, 400.0)),
		"pos=%s" % str(e.global_position))
	_gl._ip_restore_pass()
	_check("B5 插值位不污染下一帧模拟（恢复后 global==真位 B）",
		e.global_position == pos_b, "pos=%s" % str(e.global_position))
	e.global_position = Vector2(500.0, 500.0)  # 显示覆写残留 → 真实帧序差分证明
	_gl._physics_process(DT30)                 # MENU 臂：入口恢复 + 帧末快照（无位移）
	_check("B6 真实帧序接线（MENU 臂 _physics_process）：入口恢复拍回 B ∧ 帧末快照收敛 prev==curr==B",
		e.global_position == pos_b and e._ip_prev == pos_b and e._ip_curr == pos_b,
		"pos=%s prev=%s curr=%s" % [str(e.global_position), str(e._ip_prev), str(e._ip_curr)])


# ── ③ C 组：spawn 置位无跳变 ─────────────────────────────────────

func _test_c_spawn_placement() -> void:
	print("── ③ spawn 置位无跳变（弹/敌/碎片） ──")
	GameLoop.sim30_override = -3
	GameLoop.SIM_30HZ_ENABLED = true
	var birth := Vector2(200.0, 600.0)
	var p := _spawn_bullet(birth)
	_check("C1 弹 spawn 置位：prev==curr==global==出生位（position 键落位后定型）",
		p != null and p._ip_prev == birth and p._ip_curr == birth
		and p.global_position == birth,
		"prev=%s curr=%s" % [str(p._ip_prev) if p != null else "?",
			str(p._ip_curr) if p != null else "?"])
	if p != null:
		_gl._ip_render_write(0.7)
	_check("C2 弹插值无跳变：alpha 0.7 写位仍==出生位（prev=curr 钳平）",
		p != null and p.global_position == birth, "pos=%s" % str(p.global_position))
	var spawn_pos := Vector2(150.0, -40.0)
	_gl.spawner.enqueue({"data": _fixture_enemy_data(), "wave": 1, "tags": 0,
		"pos": spawn_pos})
	_gl.spawner.tick(DT30, _gl.enemy_grid)    # 真路：出队→spawn→挂位→ip_birth_snap→入表
	var se: Enemy = null
	for x in _gl.spawner.active:
		var en := x as Enemy
		if en != null and not _enemies.has(en):
			se = en
	if se != null:
		_enemies.append(se)
	_check("C3 敌 spawner 真路置位：enqueue→tick 出生敌 prev==curr==挂位出生位 ∧ 入表",
		se != null and se._ip_prev == spawn_pos and se._ip_curr == spawn_pos
		and se.global_position == spawn_pos,
		"pos=%s" % [str(se._ip_curr) if se != null else "?"])
	var shard := _spawn_shard(Vector2(360.0, 900.0))
	_check("C4 碎片 activate 置位：prev==curr==global（散射落点定型后——三值一致）",
		shard != null and shard._ip_prev == shard.global_position
		and shard._ip_curr == shard.global_position,
		"prev=%s global=%s" % [str(shard._ip_prev) if shard != null else "?",
			str(shard.global_position) if shard != null else "?"])
	if shard != null:
		var shard_pos: Vector2 = shard.global_position
		_gl._ip_render_write(0.3)
		_check("C5 碎片插值无跳变：alpha 0.3 写位仍==散射落点",
			shard.global_position == shard_pos, "pos=%s" % str(shard.global_position))
	else:
		_check("C5 碎片插值无跳变（前置失败——碎片未spawn）", false, "shard=null")


# ── ④ D 组：release/树外豁免 + 池化矩阵 ──────────────────────────

func _test_d_release_and_reuse() -> void:
	print("── ④ release/树外豁免 + 池化矩阵（复用重置） ──")
	GameLoop.sim30_override = -3
	GameLoop.SIM_30HZ_ENABLED = true
	var p: ProjectileBase = _projs[0]
	var old_pos: Vector2 = p.global_position
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	pool.release(p)
	_projs.erase(p)
	var sentinel := Vector2(-64.0, -64.0)
	p.global_position = sentinel              # 回池位（池内节点坐标无语义）
	_gl._ip_render_write(0.5)
	_check("D1 弹 release 豁免：出活跃表后回池位不被插值覆盖（写遍历只走 active）",
		p.global_position == sentinel and not pool.active_projectiles().has(p),
		"pos=%s" % str(p.global_position))
	var s: XpShard = _shards[0]
	var xp_pool := _gl.pools[&"xp"] as XPPool
	_gl.active_shards.erase(s)
	_shards.erase(s)
	xp_pool.release(s)
	var shard_sentinel := Vector2(-32.0, -32.0)
	s.global_position = shard_sentinel
	_gl._ip_render_write(0.5)
	_check("D2 碎片 release 豁免：出 active_shards 后回池位不被插值覆盖",
		s.global_position == shard_sentinel, "pos=%s" % str(s.global_position))
	var p2 := _spawn_bullet(Vector2(250.0, 700.0))
	_check("D3 弹池复用 reacquire 重置：同节点 prev=curr=新出生位（旧位 %s 不残留）"
		% str(old_pos),
		p2 == p and p2._ip_prev == Vector2(250.0, 700.0)
		and p2._ip_curr == Vector2(250.0, 700.0),
		"node_same=%s prev=%s" % [str(p2 == p), str(p2._ip_prev)])
	var s2 := _spawn_shard(Vector2(400.0, 950.0))
	_check("D4 碎片池复用 reacquire 重置：同节点 prev=curr=新散射落点（旧回池位不残留）",
		s2 == s and s2._ip_prev == s2.global_position
		and s2._ip_curr == s2.global_position,
		"node_same=%s prev=%s global=%s" % [str(s2 == s), str(s2._ip_prev),
			str(s2.global_position)])
	var e: Enemy = _enemies[0]
	var tree_pos: Vector2 = e.global_position
	e._ip_prev = tree_pos + Vector2(50.0, 0.0)     # 预置「若误写」会落的插值位（≠sentinel）
	e._ip_curr = tree_pos + Vector2(100.0, 0.0)
	var parent := e.get_parent()
	parent.remove_child(e)                         # 摘树但保持在册（树外在册——豁免口径）
	var e_sentinel := Vector2(-128.0, -128.0)
	e.global_position = e_sentinel
	_gl._ip_render_write(0.5)
	var pos_after: Vector2 = e.global_position     # 摘树窗口内的写遍历结果（先取证再复位）
	parent.add_child(e)
	e.global_position = tree_pos
	_check("D5 树外豁免：摘树在册实体插值位零写（is_inside_tree 守卫——渲染层不追写孤儿）",
		pos_after == e_sentinel, "pos_after=%s" % str(pos_after))


# ── ⑤ E 组：深载真实帧序 + headless 直驱 ─────────────────────────

func _test_e_deepload_frame_order() -> void:
	print("── ⑤ 深载态真实帧序 + headless _process 直返 ──")
	GameLoop.sim30_override = -3
	GameLoop.SIM_30HZ_ENABLED = true
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261004
	for i in range(DEEP_ENEMIES):
		_spawn_enemy(Vector2(rng.randf_range(40.0, 680.0), rng.randf_range(40.0, 1240.0)))
	var made := 0
	for i in range(DEEP_PROJ):
		if _spawn_bullet(Vector2(rng.randf_range(20.0, 700.0),
				rng.randf_range(20.0, 1260.0))) != null:
			made += 1
	var hpool := _gl.pools[&"homing"] as ProjectilePool
	var hmade := 0
	for i in range(DEEP_HOMING):
		var hp := hpool.acquire() as ProjectileBase
		if hp != null:
			hp.spawn({"velocity": Vector2.ZERO, "lifetime": 60.0, "team": 1,
				"position": Vector2(rng.randf_range(20.0, 700.0),
					rng.randf_range(20.0, 1260.0))})
			hmade += 1
	var smade := 0
	for i in range(DEEP_SHARDS):
		if _spawn_shard(Vector2(rng.randf_range(30.0, 690.0),
				rng.randf_range(30.0, 1250.0))) != null:
			smade += 1
	var total := _enemies.size() + made + hmade + smade
	_check("E1 深载态建立：敌%d+弹%d+追踪%d+碎片%d=%d（≥700——设计 3.2 ~780 量级，池容量钳制）"
		% [_enemies.size(), made, hmade, smade, total], total >= 700, "total=%d" % total)
	_gl._ip_snapshot_pass()                   # 全体立基线 prev=curr=当前位
	for e in _enemies:
		e.global_position += Vector2(3.0, -7.0)   # 模拟「渲染帧插值覆写」残留（全体）
	for pr in _projs:
		pr.global_position += Vector2(3.0, -7.0)
	for s in _shards:
		s.global_position += Vector2(3.0, -7.0)
	_gl._physics_process(DT30)                # 真实帧序（MENU 臂）：入口恢复+帧末快照
	var drift := 0
	for e in _enemies:
		if e.global_position != e._ip_curr:
			drift += 1
	for pr in _projs:
		if pr.global_position != pr._ip_curr:
			drift += 1
	for s in _shards:
		if s.global_position != s._ip_curr:
			drift += 1
	_check("E2 深载恢复遍历真实生效：%d 实体显示位全体==_ip_curr（零残留零漏拍）" % total,
		drift == 0 and total > 0, "drift=%d" % drift)
	var not_snap := 0
	for e in _enemies:
		if e._ip_prev != e._ip_curr:
			not_snap += 1
	for pr in _projs:
		if pr._ip_prev != pr._ip_curr:
			not_snap += 1
	for s in _shards:
		if s._ip_prev != s._ip_curr:
			not_snap += 1
	_check("E3 快照收敛：MENU 无位移帧 prev==curr 全体（幂等快照）",
		not_snap == 0, "not_snap=%d" % not_snap)
	var us0: int = _gl.ip_write_us_total
	_gl._process(RENDER_DT)                   # headless：首行 headless 直返（零写零喂）
	var still := 0
	for e in _enemies:
		if e.global_position != e._ip_curr:
			still += 1
	_check("E4 headless _process 直返：位保持 ∧ 插µs 分子零增（直驱口径模拟位=显示位）",
		still == 0 and _gl.ip_write_us_total == us0,
		"still=%d us=%d→%d" % [still, us0, _gl.ip_write_us_total])


# ── ⑥ F 组：alpha 口径与钳制 ─────────────────────────────────────

func _test_f_alpha_clamp() -> void:
	print("── ⑥ alpha 口径与钳制（设计 3.1 自算——步长 1/30） ──")
	GameLoop.sim30_override = -3
	GameLoop.SIM_30HZ_ENABLED = true
	_gl._ip_last_phys_frames = -1             # 强制下一调为步进点（归零基准）
	var a0: float = _gl._ip_alpha_advance(RENDER_DT)
	_check("F1 步进点归零：物理帧推进帧 alpha==0.0（本渲染帧为步进基准）", a0 == 0.0,
		"a0=%f" % a0)
	# 同函数上下文内 Engine.get_physics_frames() 不变（单线程——物理帧只在主循环迭代间
	# 推进）：序列累计确定性，非墙钟依赖
	var a1: float = _gl._ip_alpha_advance(RENDER_DT)
	var a2: float = _gl._ip_alpha_advance(RENDER_DT)
	var a3: float = _gl._ip_alpha_advance(RENDER_DT)
	_check("F2 渲染 delta 累计：1/120×3→alpha 0.25/0.50/0.75（步长 1/30 口径；浮点近似断言）",
		is_equal_approx(a1, 0.25) and is_equal_approx(a2, 0.5) and is_equal_approx(a3, 0.75),
		"a=%.6f/%.6f/%.6f" % [a1, a2, a3])
	var a4: float = _gl._ip_alpha_advance(RENDER_DT)
	_check("F3 累计达步长：4×1/120→alpha==1.0（恰一整步）", is_equal_approx(a4, 1.0),
		"a4=%.6f" % a4)
	var a5: float = _gl._ip_alpha_advance(1.0)
	_check("F4 大 delta 钳顶：alpha 恒 1.0（写位不越包络上沿）", a5 == 1.0, "a5=%f" % a5)
	var a6: float = _gl._ip_alpha_advance(-5.0)
	_check("F5 负 delta 钳底：alpha==0.0（写位不越包络下沿）", a6 == 0.0, "a6=%f" % a6)
	var s: XpShard = _shards[0]
	var pa := Vector2(100.0, 100.0)
	var pb := Vector2(200.0, 100.0)
	s._ip_prev = pa
	s._ip_curr = pb
	_gl._ip_render_write(0.0)
	var at0: Vector2 = s.global_position
	_gl._ip_render_write(1.0)
	var at1: Vector2 = s.global_position
	_check("F6 写遍历包络两端：alpha 0→prev ∧ 1→curr（写位 ∈ [prev,curr]）",
		at0 == pa and at1 == pb, "at0=%s at1=%s" % [str(at0), str(at1)])
	s._ip_prev = s.global_position
	s._ip_curr = s.global_position


# ── ⑦ G 组：插µs 喂数 + 深载 ≤500µs 冒烟（AC-9） ─────────────────

func _test_g_ip_us_feed_and_smoke() -> void:
	print("── ⑦ 插µs 喂数 + 深载 ≤%dµs 冒烟（AC-9） ──" % IP_US_CAP)
	GameLoop.sim30_override = -3
	GameLoop.SIM_30HZ_ENABLED = true
	_gl.diag_counts()                          # 首拉立基线（分子/分母差分闩）
	var us0: int = _gl.ip_write_us_total
	_gl._ip_render_write(0.5)                  # 直调喂数（写遍历唯一喂入口——_process 同口）
	_check("G1 写遍历喂 ip_write_us_total（直调同口——累计器单调不减）",
		_gl.ip_write_us_total >= us0, "us=%d→%d" % [us0, _gl.ip_write_us_total])
	var pull2: Dictionary = _gl.diag_counts()
	_check("G2 diag ip_us_per 消费喂数（谓词开态喂入后 >0——关态恒 0 基线在 r233_sim30 D3 锁）",
		int(pull2.get(&"ip_us_per", -1)) > 0,
		"ip_us_per=%s" % str(pull2.get(&"ip_us_per", "?")))
	var pull3: Dictionary = _gl.diag_counts()
	_check("G3 重复拉取增量=0（结µs/帽N 同款闩语义）",
		int(pull3.get(&"ip_us_per", -1)) == 0,
		"ip_us_per=%s" % str(pull3.get(&"ip_us_per", "?")))
	# 深载冒烟（E 组深载态在册 ~780 实体）：headless 口径注明——_process 在 headless
	# 直返不可驱动（设计 R3 定案），直接调插值遍历函数。分批取样取最小批均值（抗电池
	# 上下文负载漂移——同套件单跑/电池内实测可差 2.5 倍，墙钟绝对阈值会产环境性假红）；
	# 断言口径=每实体归一成本（算法回归护栏：遍历失控/每帧分配会推高数量级）。AC-9
	# 「≤500µs/渲染帧」绝对判据归 vc38 真机 1Hz 行裁定（本冒烟如实打印绝对值供对账）。
	var entity_n := _enemies.size() + _projs.size() + _gl.active_shards.size()
	var acc_all := 0
	var best_batch := -1
	for b in range(SMOKE_BATCHES):
		var acc := 0
		for i in range(SMOKE_ITERS):
			var t0 := Time.get_ticks_usec()
			_gl._ip_render_write(0.5)
			acc += int(Time.get_ticks_usec() - t0)
		acc_all += acc
		var batch_avg := acc / SMOKE_ITERS
		best_batch = batch_avg if best_batch < 0 else mini(best_batch, batch_avg)
	var overall_avg := acc_all / (SMOKE_BATCHES * SMOKE_ITERS)
	var per_entity := float(best_batch) / float(maxi(entity_n, 1))
	print("  （深载写遍历 %d 实体 × %d×%d 次：overall_avg=%dµs min_batch=%dµs=%.2fµs/实体）"
		% [entity_n, SMOKE_BATCHES, SMOKE_ITERS, overall_avg, best_batch, per_entity])
	_check("G4 深载写遍历回归护栏：min-batch ≤2.0µs/实体 ×%d 实体（best=%dµs；AC-9 绝对值 ≤500µs 归 vc38 真机裁定）"
		% [entity_n, best_batch],
		per_entity <= 2.0, "per_entity=%.2fµs best=%dµs" % [per_entity, best_batch])

# tests/qa_r271_flushcut_cases.gd
# R271 A/B 轴刀验收用例体（设计 §5——a1-a4/b1/b3；按 verdict 实施档裁剪：V-C1 本批触发
# → a3 实测；V-A/V-B/V-D/B2 未触发 → a1/a2/b3 SKIP 注判据；C2 全局刀未启用 → a4 SKIP。
# verdict 门：本套件启动即读归档 verdict（docs/qa/2026-10-14-R271-deeprepro-verdict.md）
# ——「刀单宣告」行为档位真源（verdict 先归档后开刀的次序红线由 deeprepro r5 落盘保证）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const VERDICT_PATH := "res://docs/qa/2026-10-14-R271-deeprepro-verdict.md"
const GROVE_TABLE := "res://resources/maps/wave_table_grove.tres"
const PLAYER_HOME := Vector2(360.0, 660.0)
const SOAK_SECONDS := 180                        # §5-a3 soak 180s 硬口径
const SOAK_HOLD := 30                            # soak 敌驻场（池卫生面非深载面）
const SOAK_BULLETS := 150                        # soak 弹上限（真实 release 流量足够）

var tree: SceneTree
var _gl: GameLoop = null
var _pass: int = 0
var _fail: int = 0
var _skip: int = 0
var _failures: Array[String] = []
var _sig_added: Array = []                       # 树进出探针（方法回调非 lambda——捕获语义陷阱免疫）
var _sig_removed: Array = []
var _frame_i: int = 0
var _arm_active: String = &""
var _comp: Array = []
var _cursor: int = 0


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261013)
	print("══ R271 flushcut：V-C1 弹桶惰性归位（boost 门内）实测 + 未触发档 SKIP 判据 ══")
	var verdict := _read_verdict()
	if verdict.is_empty():
		await _finish()
		return
	if not _boot():
		await _finish()
		return
	# ── a3（V-C1——verdict 触发档，实测） ──
	_a3_unit_cases()
	await _a3_soak()
	# ── 未触发档 SKIP（判据读自归档 verdict——§5 契约「未触发档用例标记 SKIP 并注明判据」） ──
	_skip_gated_tiers(verdict)
	_b1_verdict_lines(verdict)
	await _finish()


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


func _skip_case(p_name: String, p_reason: String) -> void:
	_skip += 1
	print("  SKIP | %s（判据：%s）" % [p_name, p_reason])


# ── verdict 门（归档文档=档位真源） ─────────────────────────────────

func _read_verdict() -> String:
	var f := FileAccess.open(VERDICT_PATH, FileAccess.READ)
	if f == null:
		_check("verdict 归档存在（先归档后开刀次序红线）", false, VERDICT_PATH)
		return ""
	var txt := f.get_as_text()
	f.close()
	_check("verdict 归档存在（先归档后开刀次序红线）", true, VERDICT_PATH)
	_check("verdict 刀单宣告行存在（档位真源）", txt.contains("刀单宣告（§3.3 触发判据逐档）"),
		"grep 刀单宣告")
	return txt


# ── boot ────────────────────────────────────────────────────────────

func _boot() -> bool:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R271Flushcut"
	tree.root.add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[flushcut] Boot 失败：%s" % str(_gl.boot_fatal))
		_fail += 1
		return false
	PerfGovernor.set_process(false)
	PerfGovernor.boost_override = 1               # V-C1 门开——a3 全部在 boost 态测
	return true


func _boot_run() -> bool:
	_gl.current_map_id = &"world_grove"
	if not _gl.start_run():
		push_error("[flushcut] start_run 失败")
		_fail += 1
		return false
	_gl.player.set("xp_need", 1.0e12)
	_gl.player.set("max_hp", 1.0e12)
	_gl.player.set("hp", 1.0e12)
	_gl.player.global_position = PLAYER_HOME
	var gatling: Node = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	if gatling == null:
		_fail += 1
		return false
	gatling.level = 3
	_gl.wave_director.set("_hard_cap_left", 9999.0)   # 台架保活（deeprepro v4 同款——见其 _boot 注）
	if not _load_composition():
		return false
	return true


func _load_composition() -> bool:
	var tbl: Resource = load(GROVE_TABLE)
	if tbl == null or not ("entries" in tbl):
		_fail += 1
		return false
	var entry: Resource = null
	for e in tbl.get("entries"):
		if int(e.get("index")) == 16:
			entry = e
			break
	if entry == null:
		_fail += 1
		return false
	for c in entry.get("composition"):
		var src: EnemyData = _gl.registry.get_enemy(StringName(c.get("enemy_id")))
		if src == null:
			_fail += 1
			return false
		var data: EnemyData = src.duplicate()
		data.hp_base = data.hp_base * 0.3
		var tags := int(c.get("tags", 0))
		for i in range(int(c.get("count", 1))):
			_comp.append({"data": data, "tags": tags})
	_comp.shuffle()
	return true


# ── a3 单元面（MENU 态——同步块零帧边界，树进出探针确定性） ───────────

func _a3_unit_cases() -> void:
	print("── a3 V-C1 单元面（boost 开：release 留桶/同变体零 reparent/换变体换桶/关=逐位） ──")
	var pool: ObjectPool = _gl.pools[&"projectile"] as ObjectPool
	var host: TexBucketHost = pool.bucket_host as TexBucketHost
	var tex_a: Texture2D = PlaceholderTexture2D.new()
	var tex_b: Texture2D = PlaceholderTexture2D.new()
	var pol0 := int((pool.stats())["pollution"])
	# a3.1：boost 开 release 留桶（不 reparent 回池根）+ 池卫生零污染
	var pb: ProjectileBase = (pool as ProjectilePool).acquire(0)
	if pb == null:
		_check("a3.1 前置：acquire 得活弹", false, "pool=%s（后续单元面跳过）" % str(pool))
		return
	host.place(pb, tex_a)
	var bucket_a: Node2D = host._buckets[tex_a]
	_check("a3.1 前置：place 落桶 A", pb.get_parent() == bucket_a, "parent=%s" % str(pb.get_parent()))
	pool.release(pb)
	_check("a3.1 boost 开 release 留桶（parent==桶A 非 pool 根）", pb.get_parent() == bucket_a,
		"parent=%s" % str(pb.get_parent()))
	_check("a3.1 留桶弹 visible==false（不绘不断批）", not pb.visible, "visible=%s" % str(pb.visible))
	_check("a3.1 _assert_clean 双向零污染（release 侧）",
		int((pool.stats())["pollution"]) == pol0, "pollution=%d→%d" % [pol0, int((pool.stats())["pollution"])])
	# a3.2：同变体复用零 reparent（加N/摘N 差分==0——LIFO 弹栈必取刚归还件）
	_arm_active = &"a3.2"
	_sig_added.clear()
	_sig_removed.clear()
	tree.node_added.connect(_on_added)
	tree.node_removed.connect(_on_removed)
	var pb2: ProjectileBase = (pool as ProjectilePool).acquire(0)
	var same_node := pb2 == pb
	host.place(pb2, tex_a)
	tree.node_added.disconnect(_on_added)
	tree.node_removed.disconnect(_on_removed)
	_arm_active = &""
	_check("a3.2 同变体复用取回同一件（LIFO）", same_node, "acquire 回转=%s" % str(same_node))
	_check("a3.2 同变体复用零 reparent（加N/摘N 差分==0）",
		_sig_added.is_empty() and _sig_removed.is_empty(),
		"加=%d 摘=%d" % [_sig_added.size(), _sig_removed.size()])
	_check("a3.2 复用后仍在桶 A", pb2.get_parent() == bucket_a, "parent=%s" % str(pb2.get_parent()))
	# a3.3：变体变更仍换桶（桶语义零变化——reparent 计 1 组 加+摘）
	_arm_active = &"a3.3"
	_sig_added.clear()
	_sig_removed.clear()
	tree.node_added.connect(_on_added)
	tree.node_removed.connect(_on_removed)
	host.place(pb2, tex_b)
	tree.node_added.disconnect(_on_added)
	tree.node_removed.disconnect(_on_removed)
	_arm_active = &""
	var bucket_b: Node2D = host._buckets[tex_b]
	_check("a3.3 变体变更换桶（parent==桶B）", pb2.get_parent() == bucket_b,
		"parent=%s" % str(pb2.get_parent()))
	# 引擎语义（探针实证 zz 2026-10-14）：4.3 reparent 对全子树派发——P(带子 Visual) 换桶
	# = rm:Visual,rm:P,add:P,add:Visual。故换桶面 = 桶惰性建(加1) + reparent 对(加2摘2)。
	_check("a3.3 换桶树进出面恰为 加3摘2（桶建+根+Visual 子树传播——无其他件移动）",
		_sig_added.size() == 3 and _sig_removed.size() == 2
			and ",".join(_sig_added).contains("Visual"),
		"加=%s 摘=%s" % [",".join(_sig_added), ",".join(_sig_removed)])
	# a3.4：boost 关=逐位回 unplace 现状（归位池根）
	pool.release(pb2)                             # boost 开留桶（桶 B）
	PerfGovernor.boost_override = 0
	var pb3: ProjectileBase = (pool as ProjectilePool).acquire(0)
	host.place(pb3, tex_b)
	pool.release(pb3)
	PerfGovernor.boost_override = 1
	_check("a3.4 boost 关 release 逐位回池根（unplace 现状）",
		pb3.get_parent() == pool, "parent=%s pool=%s" % [str(pb3.get_parent()), str(pool)])
	_check("a3.4 关态归还件 visible==false", not pb3.visible, "visible=%s" % str(pb3.visible))
	_skip_case("a3.6 升全局刀预案门", "verdict S1 塌缩（50%）+ soak 双证后主会话授权——本批 boost 门内默认，全局刀不启用")


func _on_added(p_node: Node) -> void:
	_sig_added.append(str(p_node.name))


func _on_removed(p_node: Node) -> void:
	_sig_removed.append(str(p_node.name))


# ── a3 soak（180s 六池 0 实例化 0 污染——真实战斗流量过 lazy 归位口） ──

func _a3_soak() -> void:
	print("── a3 V-C1 soak：%ds 池卫生（0 实例化 0 污染）+ lazy 口真实流量 ──" % SOAK_SECONDS)
	if not _boot_run():
		return
	var pool: ObjectPool = _gl.pools[&"projectile"] as ObjectPool
	var ri0 := int((pool.stats())["runtime_instantiates"])
	var hits0 := int((pool.stats())["hits"])
	_frame_i = 0
	var cb := Callable(self, "_on_soak_frame")
	tree.physics_frame.connect(cb)
	var t0 := Time.get_ticks_msec()
	var target_ms := SOAK_SECONDS * 1000
	while Time.get_ticks_msec() - t0 < target_ms:
		await tree.physics_frame
	tree.physics_frame.disconnect(cb)
	# 池卫生：全池 0 实例化 0 污染（§5-a3 soak 口径）
	var all_ri_zero := true
	var all_pol_zero := true
	var parts: Array[String] = []
	for pid in _gl.pools:
		var st: Dictionary = (_gl.pools[pid] as ObjectPool).stats()
		all_ri_zero = all_ri_zero and int(st["runtime_instantiates"]) == 0
		all_pol_zero = all_pol_zero and int(st["pollution"]) == 0
		parts.append("%s(ri=%d pol=%d)" % [String(pid), int(st["runtime_instantiates"]), int(st["pollution"])])
	print("  soak 池读数：" + " ".join(parts))
	_check("a3.5 soak 180s 六池 0 运行期实例化", all_ri_zero, " ".join(parts))
	_check("a3.5 soak 180s 六池 0 池污染（_assert_clean 双向）", all_pol_zero, " ".join(parts))
	_check("a3.5 soak 期真实弹 release 流量过池（hits 增量>0）",
		int((pool.stats())["hits"]) > hits0,
		"hits %d→%d" % [hits0, int((pool.stats())["hits"])])
	_check("a3.5 soak 期运行期实例化恒 0（projectile 池直读）",
		int((pool.stats())["runtime_instantiates"]) == ri0, "ri=%d" % int((pool.stats())["runtime_instantiates"]))
	# lazy 口真实流量证明：空闲栈存在留桶件（parent != pool 根 ∧ 不可见）
	var parked := 0
	var parked_invisible := true
	for n in pool._free_list:
		var node := n as Node2D
		if node != null and node.get_parent() != pool:
			parked += 1
			if node.visible:
				parked_invisible = false
	_check("a3.5 lazy 口真实流量（空闲栈存在留桶件 >0）", parked > 0, "parked=%d" % parked)
	_check("a3.5 留桶空闲件全部不可见（不绘不断批）", parked_invisible, "parked=%d" % parked)
	_check("a3.5 soak 末仍在 PLAYING（会话保活）", int(_gl.state) == GameConst.GameStatus.PLAYING,
		"state=%d" % int(_gl.state))


func _on_soak_frame() -> void:
	_frame_i += 1
	var ang := float(_frame_i) * 0.35 / 60.0
	_gl.player.global_position = Vector2(360.0 + cos(ang) * 140.0,
		660.0 + sin(ang) * 200.0)
	var alive: int = _gl.spawner.active.size()
	var want := mini(8, SOAK_HOLD - alive)
	for i in range(want):
		_spawn_one()
	var pool: ProjectilePool = _gl.pools[&"projectile"] as ProjectilePool
	var bwant := mini(SOAK_BULLETS - pool.total_active(), 8)
	for i in range(bwant):
		_inject_filler_bullet()


func _spawn_one() -> void:
	if _comp.is_empty():
		return
	var c: Dictionary = _comp[_cursor % _comp.size()]
	_cursor += 1
	var e := (_gl.pools[&"enemy"] as EnemyPool).acquire() as Enemy
	if e == null:
		return
	e.bucket_host = (_gl.pools[&"enemy"] as EnemyPool).bucket_host
	e.spawn(c["data"], 16, int(c["tags"]))
	e.global_position = Vector2(randf() * 680.0 + 20.0, randf() * 1180.0 + 40.0)
	_gl.spawner.active.append(e)


func _inject_filler_bullet() -> void:
	var pool: ProjectilePool = _gl.pools[&"projectile"] as ProjectilePool
	var pb: ProjectileBase = pool.acquire(0)
	if pb == null:
		return
	pb.damage_pipeline = _gl.pipeline
	pb.enemy_grid = _gl.enemy_grid
	pb.pool = pool
	pb.elemental = _gl.elemental
	var ang := randf() * TAU
	var r := randf_range(320.0, 380.0)
	pb.spawn({
		"position": Vector2(clampf(360.0 + cos(ang) * r, 16.0, 704.0),
			clampf(660.0 + sin(ang) * r, 16.0, 1264.0)),
		"velocity": Vector2.from_angle(randf() * TAU) * randf_range(2.0, 12.0),
		"lifetime": 9.0, "pierce": 24, "bounces": 0,
		"hitbox_radius": 2.0, "team": 0,
	})


# ── 未触发档 SKIP（判据注记）+ b1 判读行 ────────────────────────────

func _skip_gated_tiers(p_verdict: String) -> void:
	print("── 未触发档 SKIP（判据读自归档 verdict） ──")
	var va_off := p_verdict.contains("V-A=未触发")
	var vb_off := p_verdict.contains("V-B=未触发")
	if va_off:
		_skip_case("a1 V-A 接触监控清退", "verdict V-A=未触发——S2 并集塌缩 21%（<60% 触发带；v6 归档行 H2）")
		_skip_case("a1.⑥ blink_cases「走位出圈免伤」语义迁移", "随 V-A 触发才存在（CONTACT_RADIAL 未翻——信号缓存口径原样，无迁移面）")
	else:
		_check("a1 V-A 档位门（doc 触发但刀未实施=FAIL 提示）", false,
			"verdict 宣告 V-A 触发而本批未实施——回补实施或回滚 verdict")
	if vb_off:
		_skip_case("a2 V-B 重绘链限频", "verdict V-B=未触发——S3 塌缩 1%、绘µs/延µs 9%（<50%/<40% 触发带；v6 归档行 H3）")
	else:
		_check("a2 V-B 档位门（doc 触发但刀未实施=FAIL 提示）", false, "verdict 宣告 V-B 触发而本批未实施")
	_skip_case("a4 V-C2 释放批预算", "C2 全局刀未启用（K=8 待调参——verdict 只坐实 C1 面；全局/机制刀另批主会话授权）")
	_skip_case("b3 B2 弹帽 384", "B-0 三键制真机未判（headless 不可测渲ms 语义）∧ 绘µs/延µs 占比 9% 未坐实拖尾重绘主载——vc81 复核后定")


# ── b1：verdict 三候选判读行断言（都不触发 → 敌侧免刀判定行） ────────

func _b1_verdict_lines(p_verdict: String) -> void:
	print("── b1 敌侧三候选判读行（§3.4-B1：本批=判据行） ──")
	var c1 := p_verdict.contains("B1 候选①") and p_verdict.contains("台架不可定谳")
	var c2 := p_verdict.contains("B1 候选②") and p_verdict.contains("不坐实")
	var c3 := p_verdict.contains("B1 候选③") and p_verdict.contains("待 B-0")
	_check("b1 候选① MM 排除面判读行存在（boss/elite——台架不可定谳，待 vc81）", c1, "grep B1 候选①")
	_check("b1 候选② MM 每帧同步判读行存在（S7 短路塌缩——本批不坐实）", c2, "grep B1 候选②")
	_check("b1 候选③ 填充率判读行存在（B-0 三键制，真机专属）", c3, "grep B1 候选③")
	_check("b1 敌侧免刀判定成立（三候选均未触发→预算转 B2/B4 由 vc81 定）", c1 and c2 and c3,
		"三行齐=本批敌侧免刀（vc81 复核候选①③）")


# ── teardown ────────────────────────────────────────────────────────

func _finish() -> void:
	PerfGovernor.boost_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.set_process(true)
	DebugStats._diag_last_ms = Time.get_ticks_msec()
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame
	RunSave.clear()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d / SKIP %d（共 %d 项）" % [_pass, _fail, _skip, _pass + _fail + _skip])
	if not _failures.is_empty():
		for fl in _failures:
			print("  FAIL 详情：%s" % fl)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])

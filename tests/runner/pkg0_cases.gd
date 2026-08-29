# tests/runner/pkg0_cases.gd
# 包 0 自测用例体（由 test_pkg0.gd 入口在 autoload 就绪后运行时加载编译；
# 此处 EventBus/GameConfig/DebugStats 全局名可用——工程常规写法，静态类型全覆盖）。
extends RefCounted

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _probe: Node        # Node 订阅者探针（EventBus 仅 Node 可订阅，E-12）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	_ensure_autoloads()
	_setup_probe()
	_test_game_const()
	_test_modifier_stack()
	_test_event_bus()
	_test_game_config()
	_test_object_pool()
	_test_projectile_pool()
	_test_other_pools()
	_test_particle_pool()
	_test_space_grid()
	_test_data_validator()
	_test_data_registry()
	_test_debug_stats()
	_summary()


func fail_count() -> int:
	return _fail


# ── 支撑 ──────────────────────────────────────────────────────────
func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append(p_name)
		print("FAIL | %s | %s" % [p_name, p_detail])


func _summary() -> void:
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		print("失败项：")
		for f in _failures:
			print("  - %s" % f)
	print("════════════════════════════════════════")


func _ensure_autoloads() -> void:
	# 正常路径：引擎在 -s 脚本模式下实例化 autoload（EventBus→GameConfig→DebugStats）。
	# 兜底：若非标准调用形态下未注册，手动按序挂载（GameConfig._ready 依赖 EventBus 先行）。
	if tree.get_root().get_node_or_null("EventBus") == null:
		_install_autoload("EventBus", "res://autoload/event_bus.gd")
	if tree.get_root().get_node_or_null("GameConfig") == null:
		_install_autoload("GameConfig", "res://autoload/game_config.gd")
	if tree.get_root().get_node_or_null("DebugStats") == null:
		_install_autoload("DebugStats", "res://autoload/debug_stats.gd")


func _install_autoload(p_name: String, p_path: String) -> void:
	var script: GDScript = load(p_path)
	var node: Node = script.new()
	node.name = p_name
	tree.get_root().add_child(node)


func _setup_probe() -> void:
	# Node 订阅者探针（运行时脚本——避免非 Node 订阅者触发 E-12 拦截）
	var s := GDScript.new()
	s.source_code = "extends Node\nvar level_up_hits: int = 0\nvar last_level: int = 0\n" \
		+ "var pool_exhausted_hits: int = 0\nvar exhausted_pools: Array[StringName] = []\n" \
		+ "func on_level_up(v: int) -> void:\n\tlevel_up_hits += 1\n\tlast_level = v\n" \
		+ "func on_pool_exhausted(pid: StringName) -> void:\n\tpool_exhausted_hits += 1\n\texhausted_pools.append(pid)\n"
	s.reload()
	_probe = Node.new()
	_probe.name = "TestProbe"
	_probe.set_script(s)
	tree.get_root().add_child(_probe)


# ── 1. GameConst ──────────────────────────────────────────────────
func _test_game_const() -> void:
	print("── GameConst ──")
	var u1: int = GameConst.next_uid()
	var u2: int = GameConst.next_uid()
	_check("next_uid 递增且非零", u1 > 0 and u2 == u1 + 1, "u1=%d u2=%d" % [u1, u2])
	_check("HIT_NO_CRIT 掩码 = REACTION|DOT", GameConst.HIT_NO_CRIT == (GameConst.HIT_IS_REACTION | GameConst.HIT_IS_DOT))
	_check("UID 位宽 2^20（幂等键位拼接约束）", GameConst.UID_MAX == 0xFFFFF)
	_check("ConditionId.NONE = 8（封闭枚举 9 值）", GameConst.ConditionId.NONE == 8)


# ── 2. ModifierStack（B_spec 公式例） ─────────────────────────────
func _test_modifier_stack() -> void:
	print("── ModifierStack ──")
	# B_spec M1 AC：Base=100 / 加算 +20%+30%（不同 ID 各 1 层）/ flat 10 / 乘区 ×1.5×1.4 → 336
	var stack := ModifierStack.new()
	stack.audit = DamageAudit.new()
	var adds: Array[Dictionary] = [
		{"trait_id": &"AFF_A", "pool_id": &"add_atk", "layer": 1, "contrib": 0.2, "decay_delta": 0.85, "is_curse": false},
		{"trait_id": &"AFF_B", "pool_id": &"add_atk", "layer": 1, "contrib": 0.3, "decay_delta": 0.85, "is_curse": false},
	]
	stack.aggregate_add(adds, {"add_atk": 2.0})
	_check("加算聚合：跨 ID 线性求和 = 0.5", is_equal_approx(float(stack.add_pool_sum[&"add_atk"]), 0.5),
		"got %s" % str(stack.add_pool_sum[&"add_atk"]))
	stack.apply_flat(10.0, 100.0, 0.5)
	_check("Flat 未超比例钳制 = 10", is_equal_approx(stack.flat_clamped, 10.0))
	var mults: Array[Dictionary] = [
		{"pool_id": &"frost_dmg", "source_uid": 1, "contrib": 0.5, "cap_pool": 2.0},
		{"pool_id": &"bounce_dmg", "source_uid": 2, "contrib": 0.4, "cap_pool": 2.0},
	]
	stack.aggregate_mults(mults, 8, 8.0)
	_check("乘区段 ×1.5×1.4 = 2.1", is_equal_approx(stack.product_clamped, 2.1), "got %s" % str(stack.product_clamped))
	var panel := 100.0 * (1.0 + float(stack.add_pool_sum[&"add_atk"])) + stack.flat_clamped
	_check("B_spec 公式例：(100×1.5+10)×2.1 = 336", is_equal_approx(panel * stack.product_clamped, 336.0),
		"got %s" % str(panel * stack.product_clamped))
	_check("双乘区均入名额、防御层恒空", stack.resolved_mults.size() == 2 and stack.audit.dedup_defense.is_empty())

	# B_spec M2 AC：×1.5 同实例两次 → 150 而非 225（防御层去重取最大）
	var stack2 := ModifierStack.new()
	stack2.audit = DamageAudit.new()
	var dup: Array[Dictionary] = [
		{"pool_id": &"frost_dmg", "source_uid": 7, "contrib": 0.5, "cap_pool": 2.0},
		{"pool_id": &"frost_dmg", "source_uid": 7, "contrib": 0.5, "cap_pool": 2.0},
	]
	stack2.aggregate_mults(dup, 8, 8.0)
	_check("同实例重入去重：×1.5 两次 → 乘区 1.5", is_equal_approx(stack2.product_clamped, 1.5), "got %s" % str(stack2.product_clamped))
	_check("100 × 1.5 = 150（而非 225）", is_equal_approx(100.0 * stack2.product_clamped, 150.0))
	_check("防御层审计记录 1 条", stack2.audit.dedup_defense.size() == 1)

	# F3 几何衰减：首层全额 / T(5)@δ=0.92 ≤ 4.3c / n≥2 严格递减
	var stack3 := ModifierStack.new()
	stack3.aggregate_add([{"trait_id": &"X", "pool_id": &"add_atk", "layer": 5, "contrib": 1.0, "decay_delta": 0.92, "is_curse": false}], {})
	var t5 := float(stack3.add_pool_sum[&"add_atk"])
	_check("F3 衰减：T(5)@δ=0.92 ≤ 4.3 且 > 4.0", t5 <= 4.3 and t5 > 4.0, "T(5)=%s" % str(t5))
	var stack3b := ModifierStack.new()
	stack3b.aggregate_add([{"trait_id": &"X", "pool_id": &"add_atk", "layer": 1, "contrib": 1.0, "decay_delta": 0.92, "is_curse": false}], {})
	_check("F3 首层全额 T(1) = c", is_equal_approx(float(stack3b.add_pool_sum[&"add_atk"]), 1.0))
	_check("F3 严格边际递减 T(5) < 5c", t5 < 5.0)

	# 诅咒负贡献：线性全额不衰减
	var stack5 := ModifierStack.new()
	stack5.aggregate_add([{"trait_id": &"CURSE", "pool_id": &"add_atk", "layer": 3, "contrib": -0.1, "decay_delta": 0.9, "is_curse": true}], {})
	_check("诅咒负贡献全额：−0.1×3 = −0.3", is_equal_approx(float(stack5.add_pool_sum[&"add_atk"]), -0.3))

	# F4 池钳（保险丝）
	var stack4 := ModifierStack.new()
	stack4.audit = DamageAudit.new()
	stack4.aggregate_add([{"trait_id": &"X", "pool_id": &"add_atk", "layer": 1, "contrib": 3.0, "decay_delta": 0.85, "is_curse": false}], {"add_atk": 2.0})
	_check("F4 池钳：Σ ≤ cap_add_atk=2.0 + 审计", is_equal_approx(float(stack4.add_pool_sum[&"add_atk"]), 2.0) and stack4.audit.clamped_add.has(&"add_atk"))

	# Flat 比例钳制（L3）
	var stack6 := ModifierStack.new()
	stack6.audit = DamageAudit.new()
	stack6.apply_flat(80.0, 100.0, 0.5)
	_check("Flat 比例钳制：80 → 50 + 审计", is_equal_approx(stack6.flat_clamped, 50.0) and stack6.audit.clamped_flat)

	# 单区 cap_pool_p（F-14）
	var stack7 := ModifierStack.new()
	stack7.audit = DamageAudit.new()
	stack7.aggregate_mults([{"pool_id": &"vuln", "source_uid": 1, "contrib": 3.0, "cap_pool": 2.0}], 8, 8.0)
	_check("单区钳制：agg=min(3,2)=2 → M=3.0", is_equal_approx(stack7.product_clamped, 3.0))

	# 名额截断 top-8（10 区取贡献最大 8 个，截断记审计）
	var stack8 := ModifierStack.new()
	stack8.audit = DamageAudit.new()
	var ten: Array[Dictionary] = []
	for i in range(10):
		ten.append({"pool_id": StringName("pool_%02d" % i), "source_uid": i + 1, "contrib": 0.1 * float(i + 1), "cap_pool": 10.0})
	stack8.aggregate_mults(ten, 8, 8.0)
	_check("名额截断：10 区 → 8 区 + 截断审计 2 条", stack8.resolved_mults.size() == 8 and stack8.audit.truncated_mults.size() == 2)
	var expect_top8 := 1.0
	for i in range(3, 11):
		expect_top8 *= 1.0 + 0.1 * float(i)
	_check("top-8 乘积 = min(贡献 0.3~1.0 连乘, 8.0)", is_equal_approx(stack8.product_clamped, minf(expect_top8, 8.0)),
		"got %s expect %s" % [str(stack8.product_clamped), str(minf(expect_top8, 8.0))])
	_check("截断区为贡献最小的两区", stack8.audit.truncated_mults.has(&"pool_00") and stack8.audit.truncated_mults.has(&"pool_01"))

	# 同值 priority 决胜（确定性破序键）
	var stack12 := ModifierStack.new()
	stack12.audit = DamageAudit.new()
	stack12.aggregate_mults([
		{"pool_id": &"aaa", "source_uid": 1, "contrib": 0.5, "cap_pool": 2.0, "priority": 1},
		{"pool_id": &"bbb", "source_uid": 2, "contrib": 0.5, "cap_pool": 2.0, "priority": 9},
	], 1, 8.0)
	_check("同值 priority 决胜：bbb(9) 胜出", stack12.resolved_mults.size() == 1 and stack12.resolved_mults[0]["pool_id"] == &"bbb")

	# 整体钳制 8.0（F9/F-16）
	var stack9 := ModifierStack.new()
	stack9.audit = DamageAudit.new()
	var six: Array[Dictionary] = []
	for i in range(6):
		six.append({"pool_id": StringName("big_%d" % i), "source_uid": i + 1, "contrib": 1.0, "cap_pool": 2.0})
	stack9.aggregate_mults(six, 8, 8.0)
	_check("整体钳制：∏=64 → 8.0 + compressed 审计", is_equal_approx(stack9.product_clamped, 8.0) and stack9.audit.compressed)

	# Local 私有池（F-15）：独立连乘 + cap_local，不入名额不受 cap_prod
	var stack10 := ModifierStack.new()
	stack10.aggregate_local([
		{"local_id": &"scorch", "contrib": 0.3, "cap_local": 0.5},
		{"local_id": &"scorch", "contrib": 0.3, "cap_local": 0.5},
	])
	_check("Local 池：Σ=0.6 钳到 cap 0.5 → L=1.5", is_equal_approx(stack10.local_product, 1.5))
	var stack11 := ModifierStack.new()
	stack11.aggregate_local([
		{"local_id": &"scorch", "contrib": 0.08, "cap_local": 0.5},
		{"local_id": &"other", "contrib": 0.2, "cap_local": 0.5},
	])
	_check("Local 池独立连乘：1.08×1.2", is_equal_approx(stack11.local_product, 1.08 * 1.2))


# ── 3. EventBus ───────────────────────────────────────────────────
func _test_event_bus() -> void:
	print("── EventBus ──")
	EventBus.end_frame()
	# 订阅 / 派发 / 退订
	var cb := Callable(_probe, "on_level_up")
	EventBus.level_up.connect(cb)
	EventBus.emit_level_up(3)
	EventBus.emit_level_up(5)
	_check("订阅后收到派发（2 次，末值 5）", int(_probe.get("level_up_hits")) == 2 and int(_probe.get("last_level")) == 5)
	_check("派发计数 = 2", EventBus.get_dispatch_count(&"level_up") == 2)
	EventBus.level_up.disconnect(cb)
	EventBus.emit_level_up(9)
	_check("退订后不再接收", int(_probe.get("level_up_hits")) == 2 and int(_probe.get("last_level")) == 5)
	_check("退订后计数仍累计 = 3", EventBus.get_dispatch_count(&"level_up") == 3)
	# 帧末清零
	EventBus.end_frame()
	_check("end_frame 清零本帧计数", EventBus.get_dispatch_count(&"level_up") == 0)
	# 事件风暴：同事件同帧 > 128 → 告警一次（§六.4）
	var storms_before: int = EventBus.storm_warnings
	for i in range(130):
		EventBus.emit_level_up(i)
	_check("风暴计数：130 次派发全计数", EventBus.get_dispatch_count(&"level_up") == 130)
	_check("风暴告警恰好一次（阈值 128）", EventBus.storm_warnings == storms_before + 1,
		"delta=%d" % (EventBus.storm_warnings - storms_before))
	EventBus.end_frame()
	for i in range(50):
		EventBus.emit_level_up(i)
	_check("阈值内不再告警", EventBus.storm_warnings == storms_before + 1)
	EventBus.end_frame()
	# 订阅回落断言（E-12 泄漏回归）
	var leaks_before: int = EventBus.subscription_leak_errors
	EventBus.assert_subscription_baseline()
	var cb2 := Callable(_probe, "on_pool_exhausted")
	EventBus.pool_exhausted.connect(cb2)
	EventBus.assert_subscription_baseline()
	_check("订阅未回落 → 断言报错一次", EventBus.subscription_leak_errors == leaks_before + 1)
	EventBus.pool_exhausted.disconnect(cb2)
	EventBus.assert_subscription_baseline()
	_check("退订后回落基线 → 无新报错", EventBus.subscription_leak_errors == leaks_before + 1)
	# 仅 Node 可订阅（E-12）：RefCounted 订阅者被 end_frame 拦截
	var rc_script := GDScript.new()
	rc_script.source_code = "extends RefCounted\nfunc on_level_up(_v: int) -> void:\n\tpass\n"
	rc_script.reload()
	var rc: RefCounted = rc_script.new()
	var rc_cb := Callable(rc, "on_level_up")
	EventBus.level_up.connect(rc_cb)
	var non_node_before: int = EventBus.non_node_subscriber_errors
	EventBus.end_frame()
	_check("RefCounted 订阅者被拦截（E-12）", EventBus.non_node_subscriber_errors == non_node_before + 1)
	EventBus.level_up.disconnect(rc_cb)
	EventBus.end_frame()
	_check("断开后不再拦截", EventBus.non_node_subscriber_errors == non_node_before + 1)
	# 类型化事件载荷（DamageResult）
	EventBus.emit_damage_resolved(DamageResult.new())
	_check("damage_resolved 派发计数", EventBus.get_dispatch_count(&"damage_resolved") == 1)
	EventBus.end_frame()


# ── 4. GameConfig ─────────────────────────────────────────────────
func _test_game_config() -> void:
	print("── GameConfig ──")
	_check("cfg 常量：player_base_hp = 100", is_equal_approx(GameConfig.get_constant(&"player_base_hp", 0.0), 100.0))
	_check("cfg 常量：hp_growth_per_wave = 1.12", is_equal_approx(GameConfig.get_constant(&"hp_growth_per_wave", 0.0), 1.12))
	_check("cfg 常量：player_pickup_radius = 120（B_spec Q-13）", is_equal_approx(GameConfig.get_constant(&"player_pickup_radius", 0.0), 120.0))
	_check("cfg 常量：缺键回退默认值", is_equal_approx(GameConfig.get_constant(&"nonexistent_key", 42.0), 42.0))
	_check("池容量：projectile = 640（架构 §5.1）", GameConfig.get_pool_capacity(&"projectile") == 640)
	_check("池容量：enemy = 128", GameConfig.get_pool_capacity(&"enemy") == 128)
	_check("池容量：popup = 80", GameConfig.get_pool_capacity(&"popup") == 80)
	_check("池容量：particle = 64", GameConfig.get_pool_capacity(&"particle") == 64)
	_check("池容量：laser = 12（架构 §5.1 表）", GameConfig.get_pool_capacity(&"laser") == 12)
	_check("池容量：xp = 160（架构 §5.1 表）", GameConfig.get_pool_capacity(&"xp") == 160)
	_check("balance 加载成功且非致命", GameConfig.balance != null and not GameConfig.is_fatal())
	_check("balance：cap_prod = 8.0（F-16）", is_equal_approx(GameConfig.balance.cap_prod, 8.0))
	_check("balance：cap_mul_count = 8（名额）", GameConfig.balance.cap_mul_count == 8)
	_check("balance：r_alarm_ratio = 500（×500 告警线）", is_equal_approx(GameConfig.balance.r_alarm_ratio, 500.0))
	_check("balance：decay_delta_max = 0.92（F-21）", is_equal_approx(GameConfig.balance.decay_delta_max, 0.92))
	_check("balance：软 1500 / 硬 2000", GameConfig.balance.projectile_soft_limit == 1500 and GameConfig.balance.projectile_hard_limit == 2000)
	GameConfig.advance_frame()
	GameConfig.advance_frame()
	_check("帧号推进（幂等键公共帧标识）", GameConfig.frame_stamp == 2)


# ── 5. ObjectPool 基类 ────────────────────────────────────────────
func _test_object_pool() -> void:
	print("── ObjectPool ──")
	var scene: PackedScene = load("res://tests/fixtures/dummy_pooled.tscn")
	var pool := ObjectPool.new()
	pool.name = "TestObjectPool"
	tree.get_root().add_child(pool)
	pool.setup(&"test_pool", scene, 5)
	pool.prewarm(3)
	var st: Dictionary = pool.stats()
	_check("预热：free=3 / live=0 / capacity=5", st["free"] == 3 and st["live"] == 0 and st["capacity"] == 5)
	var a: Node = pool.acquire()
	var b: Node = pool.acquire()
	var c: Node = pool.acquire()
	_check("取出 3 个互不相等", a != null and b != null and c != null and a != b and b != c and a != c)
	st = pool.stats()
	_check("取出后：live=3 / free=0 / hits=3", st["live"] == 3 and st["free"] == 0 and st["hits"] == 3)
	# 容量内懒增长（预热 3 < 容量 5）
	var d: Node = pool.acquire()
	var e: Node = pool.acquire()
	_check("容量内懒增长 2 个", d != null and e != null and pool.runtime_instantiate_count == 2)
	# 满池：null + 计数 + exhausted 双通道（本地信号 + EventBus.pool_exhausted）
	var cb_pool := Callable(_probe, "on_pool_exhausted")
	EventBus.pool_exhausted.connect(cb_pool)
	var pool_hits_before: int = int(_probe.get("pool_exhausted_hits"))
	var f: Node = pool.acquire()
	st = pool.stats()
	_check("满池丢弃：null + misses=1", f == null and st["misses"] == 1)
	_check("EventBus.pool_exhausted 转发", int(_probe.get("pool_exhausted_hits")) == pool_hits_before + 1)
	EventBus.pool_exhausted.disconnect(cb_pool)
	# 归还契约：_reset_state 清零 + 机械清理（隐藏/停处理）
	a.set("probe", 7)
	pool.release(a)
	_check("归还契约：_reset_state 被调用（probe=0）", int(a.get("probe")) == 0)
	_check("归还后机械清理：visible=false", not (a as CanvasItem).visible)
	st = pool.stats()
	_check("归还后：live=4 / free=1", st["live"] == 4 and st["free"] == 1)
	# 重复归还拦截
	pool.release(a)
	st = pool.stats()
	_check("重复归还被拦截：free 仍为 1 + 计数", st["free"] == 1 and pool.rejected_release_count == 1)
	# 复取（应取回同一节点）
	var g: Node = pool.acquire()
	_check("复取命中空闲栈（同一实例）", g == a)
	# 池污染断言：外部篡改空闲栈节点 → 取出时拦截
	pool.release(g)
	(g as CanvasItem).visible = true
	var pollution_before: int = pool.pollution_count
	var h: Node = pool.acquire()
	_check("池污染断言：篡改节点取出时被拦截", h == g and pool.pollution_count == pollution_before + 1)
	pool.free()


# ── 6. ProjectilePool（软/硬闸门） ─────────────────────────────────
# 集成包 B.8 用例迁移：夹具 dummy_pooled.tscn → 真实弹体场景（acquire() 已收紧 ProjectileBase）；
# 断言意图不变（闸门语义/FORCED 路径/meta 传递），仅夹具与类型标注升级。
func _test_projectile_pool() -> void:
	print("── ProjectilePool ──")
	var scene: PackedScene = load("res://scenes/combat/projectiles/ballistic_projectile.tscn")
	# 硬上限路径：容量=硬上限=2，软上限 10
	var pp := ProjectilePool.new()
	pp.name = "TestProjectilePool"
	tree.get_root().add_child(pp)
	pp.setup(&"projectile", scene, 2)
	pp.soft_limit = 10
	pp.hard_limit = 2
	var p1: ProjectileBase = pp.acquire()
	var p2: ProjectileBase = pp.acquire()
	_check("硬闸门池：取出 2 弹（懒增长）",
		p1 != null and p2 != null and p1 is ProjectileBase and p2 is ProjectileBase
		and pp.total_active() == 2)
	var p3: ProjectileBase = pp.acquire()
	_check("硬上限触达：FORCED 回收最老（取回 p1）", p3 == p1 and pp.forced_recycle_count == 1 and pp.total_active() == 2)
	_check("FORCED 回收原因经 meta 传递", int(p1.get_meta(&"_recycle_reason", -1)) == GameConst.RecycleReason.FORCED)
	pp.free()
	# 软上限路径
	var pp2 := ProjectilePool.new()
	pp2.name = "TestProjectilePoolSoft"
	tree.get_root().add_child(pp2)
	pp2.setup(&"projectile_soft", scene, 4)
	pp2.soft_limit = 1
	pp2.hard_limit = 4
	var s1: ProjectileBase = pp2.acquire()
	var s2: ProjectileBase = pp2.acquire()
	_check("软上限：第 2 发请求被丢弃（null+计数）", s1 != null and s2 == null and (pp2.stats()["misses"] == 1))
	pp2.release(s1)
	var s3: ProjectileBase = pp2.acquire()
	_check("释放后可再取", s3 == s1 and pp2.total_active() == 1)
	pp2.free()


# ── 7. 其余特化池（类型收窄 + 往返） ──────────────────────────────
# 集成包 B.8 用例迁移：EnemyPool 夹具 dummy_pooled.tscn → enemy.tscn、XPPool 夹具
# dummy_xp.tscn → xp_shard.tscn（acquire() 已分别收紧 Enemy / XpShard）；
# PopupPool / LaserBeamPool 未在本批收紧授权内，维持 dummy 夹具与 Node2D 占位断言。
func _test_other_pools() -> void:
	print("── 特化池 ──")
	var scene: PackedScene = load("res://tests/fixtures/dummy_pooled.tscn")
	var enemy_scene: PackedScene = load("res://scenes/combat/enemies/enemy.tscn")
	var xp_scene: PackedScene = load("res://scenes/combat/pickups/xp_shard.tscn")
	# EnemyPool
	var ep := EnemyPool.new()
	tree.get_root().add_child(ep)
	ep.setup(&"enemy", enemy_scene, 2)
	ep.prewarm(1)
	var enemy: Enemy = ep.acquire()
	_check("EnemyPool.acquire → Enemy（真件收紧）", enemy != null and enemy is Enemy)
	ep.release(enemy)
	_check("EnemyPool 归还往返", (ep.stats() as Dictionary)["free"] == 1)
	ep.free()
	# PopupPool
	var pop := PopupPool.new()
	tree.get_root().add_child(pop)
	pop.setup(&"popup", scene, 2)
	pop.prewarm(1)
	var popup: Node2D = pop.acquire()
	_check("PopupPool.acquire → Node2D（DamagePopup 占位类型）", popup != null and popup is Node2D)
	pop.release(popup)
	pop.free()
	# LaserBeamPool
	var lp := LaserBeamPool.new()
	tree.get_root().add_child(lp)
	lp.setup(&"laser", scene, 2)
	lp.prewarm(1)
	var beam: Node2D = lp.acquire()
	_check("LaserBeamPool.acquire → Node2D（LaserBeam 占位类型）", beam != null and beam is Node2D)
	lp.release(beam)
	lp.free()
	# XPPool（XpShard 真件——架构 §1.4 pickup.gd）
	var xp := XPPool.new()
	tree.get_root().add_child(xp)
	xp.setup(&"xp", xp_scene, 2)
	xp.prewarm(1)
	var shard: XpShard = xp.acquire()
	_check("XPPool.acquire → XpShard（真件收紧）", shard != null and shard is XpShard)
	xp.release(shard)
	xp.free()


# ── 8. ParticlePool（burst 生命周期 + 优先级抢占） ─────────────────
func _test_particle_pool() -> void:
	print("── ParticlePool ──")
	var scene: PackedScene = load("res://tests/fixtures/dummy_particle.tscn")
	var pool := ParticlePool.new()
	pool.name = "TestParticlePool"
	tree.get_root().add_child(pool)
	pool.setup(&"particle", scene, 1)
	pool.prewarm(1)
	pool.burst(&"fx_kill", Vector2(100, 100), 2)
	var st: Dictionary = pool.stats()
	_check("burst：发射器占用（live=1）", st["live"] == 1)
	var active: GPUParticles2D = null
	for child in pool.get_children():
		if child is GPUParticles2D and (child as GPUParticles2D).visible:
			active = child
	_check("burst：发射器可见 + one_shot", active != null and active.one_shot)
	_check("burst：scene_id 经 meta 传递", active.get_meta(&"_burst_scene_id", &"") == &"fx_kill")
	# 满池 + 高优先级 → 抢占低优先级活跃发射器
	pool.burst(&"fx_crit", Vector2(200, 200), 3)
	st = pool.stats()
	_check("满池抢占：低让高（live 仍 1 + preempted=1）", st["live"] == 1 and pool.preempted_count == 1)
	# 满池 + 低优先级 → 丢弃
	pool.burst(&"fx_hit", Vector2(0, 0), 1)
	st = pool.stats()
	_check("满池低优先级：请求丢弃（misses=2）", st["live"] == 1 and st["misses"] == 2)
	# 播放完成信号 → 自动归还
	var finished_active: GPUParticles2D = null
	for child in pool.get_children():
		if child is GPUParticles2D and (child as GPUParticles2D).visible:
			finished_active = child
	finished_active.finished.emit()
	st = pool.stats()
	_check("播放完成 → 自动归还（live=0）", st["live"] == 0)
	pool.free()


# ── 9. SpaceGrid ──────────────────────────────────────────────────
func _test_space_grid() -> void:
	print("── SpaceGrid ──")
	var grid := SpaceGrid.new()
	grid.configure(Vector2(720, 1280), 192.0)
	var n1 := Node2D.new()
	n1.position = Vector2(100, 100)
	var n2 := Node2D.new()
	n2.position = Vector2(500, 700)
	var n3 := Node2D.new()
	n3.position = Vector2(650, 1200)
	var items: Array[Node2D] = [n1, n2, n3]
	grid.rebuild(items)
	var res: Array[Node2D] = grid.query_circle(Vector2(90, 90), 50.0)
	_check("基础查询：命中且仅命中近邻", res.size() == 1 and res.has(n1))
	# 多桶跨查（中点 (575,950) 半径 300 同时覆盖 n2/n3，多格扫描）
	res = grid.query_circle(Vector2(575, 950), 300.0)
	_check("多桶查询：覆盖范围内两个目标", res.has(n2) and res.has(n3) and not res.has(n1))
	# 边界桶：网格边缘（±margin 内）与出屏远端（钳制入边缘桶）
	var n_edge := Node2D.new()
	n_edge.position = Vector2(-180, -180)
	grid.insert(n_edge, 10.0)
	res = grid.query_circle(Vector2(-180, -180), 20.0)
	_check("边界桶：左上出屏余量内可查", res.has(n_edge))
	var n_far := Node2D.new()
	n_far.position = Vector2(10000, 640)
	grid.insert(n_far, 10.0)
	res = grid.query_circle(Vector2(10000, 640), 10.0)
	_check("边界钳制：远出屏坐标落入边缘桶可查", res.has(n_far))
	# query_nearest（折射寻的/索敌）
	var nearest: Node2D = grid.query_nearest(Vector2(480, 680), 100.0, null)
	_check("最近邻查询：n2", nearest == n2)
	nearest = grid.query_nearest(Vector2(480, 680), 1000.0, n2)
	_check("最近邻排除原目标：n3（547px < n1 的 693px）", nearest == n3)
	nearest = grid.query_nearest(Vector2(-3000, -3000), 50.0, null)
	_check("空范围最近邻 → null", nearest == null)
	# query_arc（挥斩扇形）
	res = grid.query_arc(Vector2(480, 680), 400.0, 0.0, PI * 0.25 + 0.01)
	_check("扇形查询：+x 方向 90° 扇内含 n2", res.has(n2) and not res.has(n1))
	# 每帧重建：旧条目清除
	var only_n1: Array[Node2D] = [n1]
	grid.rebuild(only_n1)
	res = grid.query_circle(Vector2(500, 700), 400.0)
	_check("每帧重建：旧条目清除", res.is_empty())
	res = grid.query_circle(Vector2(100, 100), 50.0)
	_check("每帧重建：新条目可查", res.has(n1))
	for n in [n1, n2, n3, n_edge, n_far]:
		n.free()


# ── 10. DataValidator（坏数据剔除） ────────────────────────────────
func _test_data_validator() -> void:
	print("── DataValidator ──")
	var v := DataValidator.new()
	# ① 负射速 WeaponData（AC-13.2：负射速 → 剔除宿主）
	var w := WeaponData.new()
	w.id = &"W_TEST"
	w.display_name = "测试武器"
	w.form = GameConst.WeaponForm.BALLISTIC
	var tbl: Array[WeaponLevelStats] = []
	for i in range(5):
		var lv := WeaponLevelStats.new()
		lv.base_atk = 10.0 + float(i)
		lv.rof = 5.0
		tbl.append(lv)
	tbl[1].rof = -5.0
	w.upgrade_table = tbl
	var errs: Array = v.validate_weapon(w)
	_check("负射速被拦截（upgrade_table[1].rof）", _has_field(errs, "upgrade_table[1].rof"))
	# ② WeaponData upgrade_table 数量错误（≠5）
	var w2 := WeaponData.new()
	w2.id = &"W_SHORT"
	w2.display_name = "短表武器"
	var empty_tbl: Array[WeaponLevelStats] = []
	w2.upgrade_table = empty_tbl
	errs = v.validate_weapon(w2)
	_check("upgrade_table ≠ 5 项被拦截", _has_field(errs, "upgrade_table"))
	# ③ TraitData δ > 0.92（F-21 硬约束）
	var t := TraitData.new()
	t.id = &"AFF_DELTA_BAD"
	t.pool = GameConst.PoolClass.ADD
	t.pool_id = &"add_atk"
	t.effect_id = &"EF_STAT"
	t.stack_max = 3
	t.decay_delta = 0.95
	errs = v.validate_trait(t)
	_check("δ=0.95 > 0.92 被拦截（F-21）", _has_field(errs, "decay_delta"))
	# ④ TraitData 缺 id / 缺 pool_id / MULT 缺 cap_pool_p
	var t2 := TraitData.new()
	t2.pool = GameConst.PoolClass.ADD
	t2.pool_id = &"add_atk"
	t2.effect_id = &"EF_STAT"
	t2.decay_delta = 0.85
	errs = v.validate_trait(t2)
	_check("缺 id 被拦截", _has_field(errs, "id"))
	var t3 := TraitData.new()
	t3.id = &"SYN_NO_CAP"
	t3.pool = GameConst.PoolClass.MULT
	t3.pool_id = &"frost_dmg"
	t3.effect_id = &"EF_X"
	t3.cap_pool_p = 0.0
	errs = v.validate_trait(t3)
	_check("MULT 缺 cap_pool_p 被拦截（F-14）", _has_field(errs, "cap_pool_p"))
	var t4 := TraitData.new()
	t4.id = &"AFF_NO_POOLID"
	t4.pool = GameConst.PoolClass.ADD
	t4.effect_id = &"EF_STAT"
	t4.decay_delta = 0.85
	errs = v.validate_trait(t4)
	_check("ADD 缺 pool_id 被拦截", _has_field(errs, "pool_id"))
	# ⑤ 非法 pool_id（封闭枚举外）
	var t5 := TraitData.new()
	t5.id = &"AFF_BAD_POOL"
	t5.pool = GameConst.PoolClass.ADD
	t5.pool_id = &"add_hack_new_pool"
	t5.effect_id = &"EF_STAT"
	t5.decay_delta = 0.85
	errs = v.validate_trait(t5)
	_check("封闭枚举外 pool_id 被拦截（A2 §1.9）", _has_field(errs, "pool_id"))
	# ⑥ 合法实例 → 无 error
	var t_ok := TraitData.new()
	t_ok.id = &"AFF_OK"
	t_ok.pool = GameConst.PoolClass.ADD
	t_ok.pool_id = &"add_atk"
	t_ok.effect_id = &"EF_STAT"
	t_ok.stack_max = 3
	t_ok.decay_delta = 0.85
	t_ok.proc_chance = 1.0
	errs = v.validate_trait(t_ok)
	_check("合法 TraitData 通过校验", _error_count(errs) == 0)
	# ⑦ BalanceTables 致命集（res_logic 错 / pool_prewarm ≤0 / cap_prod ≤0）
	var bt_bad := BalanceTables.new()
	bt_bad.res_logic = Vector2i(1080, 1920)
	var bal_errs: Array = v.validate_balance(bt_bad)
	_check("balance 致命：res_logic 错被拦截", _has_fatal_field(bal_errs, "res_logic"))
	bt_bad = BalanceTables.new()
	bt_bad.pool_prewarm = {"projectile": 640, "enemy": 0, "popup": 80, "particle": 64, "laser": 12, "xp": 160}
	bal_errs = v.validate_balance(bt_bad)
	_check("balance 致命：pool_prewarm.enemy=0 被拦截", _has_fatal_field(bal_errs, "pool_prewarm"))
	bt_bad = BalanceTables.new()
	bt_bad.cap_prod = -1.0
	bal_errs = v.validate_balance(bt_bad)
	_check("balance 致命：cap_prod ≤ 0 被拦截", _has_fatal_field(bal_errs, "cap_prod"))
	# ⑧ 合法 BalanceTables（schema 默认值即合法）
	bal_errs = v.validate_balance(BalanceTables.new())
	_check("balance 默认值全合法", bal_errs.is_empty(), "violations=%s" % str(bal_errs))
	# ⑨ RelicData 悬空事件名（AC-13.3）
	var rel := RelicData.new()
	rel.id = &"REL_DANGLE"
	rel.effect_id = &"REL_EF_X"
	rel.listen_events = [&"nonexistent_event"]
	errs = v.validate_relic(rel)
	_check("遗物悬空事件名被拦截", _has_field(errs, "listen_events[0]"))


func _has_field(errs: Array, field: String) -> bool:
	for e in errs:
		if String(e.get("field", "")) == field and String(e.get("severity", "error")) == "error":
			return true
	return false


func _error_count(errs: Array) -> int:
	var count := 0
	for e in errs:
		if String(e.get("severity", "error")) == "error":
			count += 1
	return count


func _has_fatal_field(errs: Array, field: String) -> bool:
	for e in errs:
		if String(e.get("field", "")) == field and bool(e.get("fatal", false)):
			return true
	return false


# ── 11. DataRegistry（骨架目录加载 + 校验报告） ────────────────────
func _test_data_registry() -> void:
	print("── DataRegistry ──")
	var reg := DataRegistry.new()
	var elapsed: float = reg.load_all("res://data/manifest.cfg")
	_check("load_all 返回耗时秒（AC-13.4）", elapsed >= 0.0)
	_check("GameFeelConfig 从 data/gamefeel 骨架加载", reg.game_feel != null)
	_check("GameFeelConfig：hit_stop_ms = [0,30,50,120]", reg.game_feel.hit_stop_ms == [0, 30, 50, 120])
	_check("GameFeelConfig：shake_trauma = [0.15,0.4,0.5,1.0]", reg.game_feel.shake_trauma == [0.15, 0.4, 0.5, 1.0])
	_check("报告：total ≥ 1 且 rejected = 0", int(reg.report["total"]) >= 1 and int(reg.report["rejected"]) == 0)
	_check("get_game_feel 单件入口", reg.get_game_feel() == reg.game_feel)
	_check("get_weapon 未命中返回 null（fail-fast）", reg.get_weapon(&"W_MISSING") == null)
	_check("trait_ids_by_pool（ADD）= 12 条内容词条（pkg3 内容落地）", reg.trait_ids_by_pool(GameConst.PoolClass.ADD).size() == 12)
	var wave_tbl := reg.get_wave_table()
	_check("波表加载：30 波 entries（pkg3 内容落地）", wave_tbl != null and wave_tbl.entries.size() == 30)
	# 注入坏词条 → validate_all 剔除 + 错误清单含文件名/字段名
	var bad := TraitData.new()
	bad.id = &"AFF_BAD"
	bad.pool = GameConst.PoolClass.ADD
	bad.pool_id = &"add_atk"
	bad.effect_id = &"EF_STAT"
	bad.decay_delta = 0.99
	reg.traits[&"AFF_BAD"] = bad
	var v := DataValidator.new()
	var result: Dictionary = v.validate_all(reg)
	var rejected: Array = result["rejected"]
	_check("validate_all：坏词条进入 rejected 清单", rejected.size() == 1 and StringName(str(rejected[0]["id"])) == &"AFF_BAD")
	var errors: Array = result["errors"]
	var has_file: bool = false
	var has_field: bool = false
	for e in errors:
		if StringName(str(e.get("id", ""))) == &"AFF_BAD":
			if String(e.get("file", "")) != "":
				has_file = true
			if String(e.get("field", "")) != "":
				has_field = true
	_check("错误清单含文件名 + 字段名（AC-13.2/13.3）", has_file and has_field)


# ── 12. DebugStats ────────────────────────────────────────────────
func _test_debug_stats() -> void:
	print("── DebugStats ──")
	# 计数器通道
	DebugStats.count(&"test_counter")
	DebugStats.count(&"test_counter", 4)
	_check("计数器通道：count/get_counter", DebugStats.get_counter(&"test_counter") == 5)
	# 阶段计时
	DebugStats.begin_stage(&"test_stage")
	DebugStats.end_stage(&"test_stage")
	var rep: Dictionary = DebugStats.frame_report()
	_check("frame_report 键：p50/p95/p99/stage_breakdown", rep.has("p50") and rep.has("p95") and rep.has("p99") and rep.has("stage_breakdown"))
	_check("阶段分解含 test_stage", (rep["stage_breakdown"] as Dictionary).has("test_stage"))
	# 分位数（独立实例：注入已知样本 5/10/20ms）
	var ds_script: GDScript = load("res://autoload/debug_stats.gd")
	var ds = ds_script.new()
	ds._push_frame_time(0.005)
	ds._push_frame_time(0.010)
	ds._push_frame_time(0.020)
	_check("分位数：P50 = 10ms", is_equal_approx(float(ds.percentile_ms(0.50)), 10.0))
	_check("分位数：P95 = 20ms", is_equal_approx(float(ds.percentile_ms(0.95)), 20.0))
	ds.free()
	# 池断言（树扫描发现 + AC 验收口径）
	var scene: PackedScene = load("res://tests/fixtures/dummy_pooled.tscn")
	var clean_pool := ObjectPool.new()
	clean_pool.name = "CleanPool"
	tree.get_root().add_child(clean_pool)
	clean_pool.setup(&"clean_pool", scene, 4)
	clean_pool.prewarm(2)
	rep = DebugStats.frame_report()
	_check("池快照聚合（frame_report.pools）", (rep["pools"] as Dictionary).has(&"clean_pool"))
	_check("assert_pools_clean：干净池通过", DebugStats.assert_pools_clean())
	_check("assert_zero_instantiations：纯预热通过（AC-14.1）", DebugStats.assert_zero_instantiations())
	# 生长池 → 运行期实例化断言失败
	var grow_pool := ObjectPool.new()
	grow_pool.name = "GrowPool"
	tree.get_root().add_child(grow_pool)
	grow_pool.setup(&"grow_pool", scene, 3)
	grow_pool.prewarm(1)
	var grown: Node = grow_pool.acquire()
	var grown2: Node = grow_pool.acquire()
	_check("生长池：runtime_instantiate = 1", grown != null and grown2 != null and grow_pool.runtime_instantiate_count == 1)
	_check("assert_zero_instantiations：生长池拦截（AC-14.1 违例）", not DebugStats.assert_zero_instantiations())
	grow_pool.free()
	clean_pool.free()
	# CSV 导出
	DebugStats.export_csv("user://pkg0_debug_stats.csv")
	_check("export_csv 落盘", FileAccess.file_exists("user://pkg0_debug_stats.csv"))

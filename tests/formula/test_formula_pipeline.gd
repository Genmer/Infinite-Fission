# tests/formula/test_formula_pipeline.gd
# 包 1 自测用例体（模式 A 公式回归；由 tests/runner/test_pkg1.gd 入口在 autoload
# 就绪后运行时加载编译——EventBus/GameConfig/DebugStats 全局名可用，静态类型全覆盖）。
# 集成包 B.8 用例迁移：DamageContext.target 已收紧为 Enemy——目标夹具由「动态脚本裸
# Node2D」升级为「extends Enemy 真件脚本」（uid/hp/dead/resist 承自 Enemy 基类，
# 保留 take_result 计数覆写与 status_vuln 附加属性）；断言数值与意图全部不变。
extends RefCounted

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _probe: Node                          # EventBus 订阅探针（仅 Node 可订阅，E-12）
var _dummy_script: GDScript               # Enemy 真件派生测试脚本
var _targets: Array[Node2D] = []          # 动态 target 统一回收


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	_ensure_autoloads()
	_setup_probe()
	_test_formula_anchor()                 # AC-12.1 公式结构锚点
	_test_defense_layer()                  # AC-12.2 防御层去重
	_test_decay_family()                   # F3 衰减不等式族
	_test_add_flat_guards()                # F4 池钳 + Flat 比例钳
	_test_mult_guards()                    # 单区 cap / top-8 / priority / F9
	_test_local_pools()                    # Local 独立连乘不占名额
	_test_target_side()                    # 抗性 × 易伤 + duck-typing 回退
	_test_crit_rng()                       # 暴击固定种子复现
	_test_idempotent_and_death()           # 幂等缓存 + 死亡短路
	_test_sanitize()                       # NaN/Inf/负数入口防御
	_test_alarm()                          # R_alarm 双闸 + 一局一次
	_test_reaction()                       # 反应独立结算快照口径（F20/F21）
	_test_frame_hooks()                    # begin/end_frame + DebugStats 落点
	_test_determinism()                    # 1000 次确定性哈希
	_cleanup()
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
	# 兜底：非标准调用形态下手动按序挂载（沿用包 0 pkg0_cases 模式）。
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
	# Node 订阅者探针：damage_resolved / damage_alarm / reaction_triggered 三通道计数
	var s := GDScript.new()
	s.source_code = "extends Node\n" \
		+ "var resolved_hits: int = 0\n" \
		+ "var alarm_hits: int = 0\n" \
		+ "var reaction_hits: int = 0\n" \
		+ "var last_alarm: DamageResult = null\n" \
		+ "var last_rxn: int = -1\n" \
		+ "var last_rxn_target: int = -1\n" \
		+ "func on_resolved(_r: DamageResult) -> void:\n\tresolved_hits += 1\n" \
		+ "func on_alarm(r: DamageResult) -> void:\n\talarm_hits += 1\n\tlast_alarm = r\n" \
		+ "func on_reaction(rxn: int, _pos: Vector2, uid: int) -> void:\n" \
		+ "\treaction_hits += 1\n\tlast_rxn = rxn\n\tlast_rxn_target = uid\n"
	s.reload()
	_probe = Node.new()
	_probe.name = "Pkg1Probe"
	_probe.set_script(s)
	tree.get_root().add_child(_probe)
	EventBus.damage_resolved.connect(Callable(_probe, "on_resolved"))
	EventBus.damage_alarm.connect(Callable(_probe, "on_alarm"))
	EventBus.reaction_triggered.connect(Callable(_probe, "on_reaction"))


# 集成包 B.8 迁移：基类由 Node2D → Enemy 真件（uid/hp/dead/resist/get_resist 承自基类，
# 不重复声明防成员遮蔽）；保留测试计数覆写 take_result 与附加属性 status_vuln。
const DUMMY_ENEMY_SRC := "extends Enemy\n" \
	+ "var status_vuln: float = 0.0\n" \
	+ "var take_count: int = 0\n" \
	+ "var applied_total: float = 0.0\n" \
	+ "func take_result(p_result: DamageResult) -> void:\n" \
	+ "\ttake_count += 1\n\tapplied_total += p_result.final_value\n" \
	+ "\thp -= p_result.final_value\n" \
	+ "\tif hp <= 0.0 and not dead:\n\t\tdead = true\n"


func _make_target(p_hp: float = 1000000.0) -> Enemy:
	# 真件 Enemy 测试实例（接口收紧后 ctx.target: Enemy 的运行时实体；
	# 计数覆写 take_result + 附加 status_vuln——断言口径与迁移前一致）
	if _dummy_script == null:
		_dummy_script = GDScript.new()
		_dummy_script.source_code = DUMMY_ENEMY_SRC
		_dummy_script.reload()
	var t: Enemy = _dummy_script.new()
	t.set("hp", p_hp)
	t.set("uid", GameConst.next_uid())
	_targets.append(t)
	return t


func _make_ctx(p_target: Enemy, p_frame: int, p_source: int = 1) -> DamageContext:
	var ctx := DamageContext.make()
	ctx.source_uid = p_source
	ctx.target = p_target
	var uid_v: Variant = p_target.get("uid")
	ctx.target_uid = int(uid_v) if uid_v != null else 0    # 裸 Node2D 无 uid → 0
	ctx.frame_stamp = p_frame
	ctx.base_atk = 100.0
	ctx.crit_chance = 0.0
	return ctx


func _probe_get(p_key: String) -> int:
	return int(_probe.get(p_key))


# ── 1. AC-12.1 公式结构锚点 ───────────────────────────────────────
func _test_formula_anchor() -> void:
	print("── AC-12.1 公式结构锚点 ──")
	var pipe := DamagePipeline.new()
	pipe.begin_frame(1)
	var target := _make_target()
	var ctx := _make_ctx(target, 1)
	ctx.base_atk = 100.0
	ctx.add_entries = [
		{"trait_id": &"AFF_A", "pool_id": &"add_atk", "layer": 1, "contrib": 0.2, "decay_delta": 0.85, "is_curse": false},
		{"trait_id": &"AFF_B", "pool_id": &"add_atk", "layer": 1, "contrib": 0.3, "decay_delta": 0.85, "is_curse": false},
	]
	ctx.flat_bonus = 10.0
	ctx.mult_pools = [
		{"pool_id": &"frost_dmg", "source_uid": 1, "contrib": 0.5, "cap_pool": 2.0},
		{"pool_id": &"bounce_dmg", "source_uid": 2, "contrib": 0.4, "cap_pool": 2.0},
	]
	ctx.crit_chance = 0.0
	var r: DamageResult = pipe.resolve(ctx)
	_check("AC-12.1：(100×(1+0.2+0.3)+10)×1.5×1.4 = 336（非暴击）",
		r != null and is_equal_approx(r.final_value, 336.0), "got %s" % str(r.final_value if r != null else null))
	_check("面板段 S = 160（panel_snapshot）", r != null and is_equal_approx(r.panel_snapshot, 160.0))
	_check("乘区段 M = 2.1（钳后）", r != null and is_equal_approx(r.mult_product, 2.1))
	_check("Local 段 L = 1.0（空）", r != null and is_equal_approx(r.local_product, 1.0))
	_check("非暴击 C = 1", r != null and not r.is_crit)
	_check("目标侧 V = 1.0（零抗零易伤）", r != null and is_equal_approx(r.target_factor, 1.0))
	_check("表现级：NORMAL 跳字 / HIT 分级", r != null
		and r.popup_style == GameConst.PopupStyle.NORMAL and r.feel_level == GameConst.FeelLevel.HIT)
	_check("审计健康：无压缩/无告警/防御层恒空", r != null and r.audit != null
		and not r.audit.compressed and not r.audit.alarm and r.audit.dedup_defense.is_empty())
	_check("乘区明细 pool_breakdown 两条", r != null and r.pool_breakdown.size() == 2)
	_check("元数据：source/target/frame 回填", r != null and r.source_uid == 1
		and r.target_uid == int(target.get("uid")) and r.frame_stamp == 1)
	_check("killed=false（大血量目标）", r != null and not r.killed)
	_check("damage_resolved 每次成功结算广播一次", _probe_get("resolved_hits") == 1)


# ── 2. AC-12.2 防御层去重 ─────────────────────────────────────────
func _test_defense_layer() -> void:
	print("── AC-12.2 防御层 ──")
	var pipe := DamagePipeline.new()
	pipe.begin_frame(1)
	var target := _make_target()
	var ctx := _make_ctx(target, 1)
	ctx.mult_pools = [
		{"pool_id": &"frost_dmg", "source_uid": 7, "contrib": 0.5, "cap_pool": 2.0},
		{"pool_id": &"frost_dmg", "source_uid": 7, "contrib": 0.5, "cap_pool": 2.0},
	]
	var r: DamageResult = pipe.resolve(ctx)
	_check("AC-12.2：同实例重入两条 ×1.5 → 150 而非 225",
		r != null and is_equal_approx(r.final_value, 150.0), "got %s" % str(r.final_value if r != null else null))
	_check("乘区段 M = 1.5（去重取最大）", r != null and is_equal_approx(r.mult_product, 1.5))
	_check("防御层审计记录 1 条（>0 即 bug 的遥测口径）", r != null and r.audit != null
		and r.audit.dedup_defense.size() == 1)
	# 聚合层合法路径：不同实例同池 → 合并加算（×2.0）
	pipe.begin_frame(2)
	var ctx2 := _make_ctx(target, 2)
	ctx2.mult_pools = [
		{"pool_id": &"frost_dmg", "source_uid": 7, "contrib": 0.5, "cap_pool": 2.0},
		{"pool_id": &"frost_dmg", "source_uid": 8, "contrib": 0.5, "cap_pool": 2.0},
	]
	var r2: DamageResult = pipe.resolve(ctx2)
	_check("聚合层：多实例合法来源合并加算 ×2.0 → 200",
		r2 != null and is_equal_approx(r2.final_value, 200.0), "got %s" % str(r2.final_value if r2 != null else null))
	_check("聚合层路径防御层恒空", r2 != null and r2.audit != null and r2.audit.dedup_defense.is_empty())


# ── 3. F3 衰减不等式族 ────────────────────────────────────────────
func _test_decay_family() -> void:
	print("── F3 衰减不等式族 ──")
	var pipe := DamagePipeline.new()
	var target := _make_target()
	# 首层全额：T(1) = c
	pipe.begin_frame(1)
	var ctx1 := _make_ctx(target, 1)
	ctx1.add_entries = [{"trait_id": &"X", "pool_id": &"add_atk", "layer": 1, "contrib": 0.2, "decay_delta": 0.92, "is_curse": false}]
	var r1: DamageResult = pipe.resolve(ctx1)
	_check("首层全额：T(1) = c = 0.2 → S = 120",
		r1 != null and is_equal_approx(r1.final_value, 120.0), "got %s" % str(r1.final_value if r1 != null else null))
	# n ≥ 2 严格递减：T(2) = 0.2×(1+0.92) = 0.384 < 0.4
	pipe.begin_frame(2)
	var ctx2 := _make_ctx(target, 2)
	ctx2.add_entries = [{"trait_id": &"X", "pool_id": &"add_atk", "layer": 2, "contrib": 0.2, "decay_delta": 0.92, "is_curse": false}]
	var r2: DamageResult = pipe.resolve(ctx2)
	_check("n≥2 严格递减：T(2) = 0.384 → S = 138.4",
		r2 != null and is_equal_approx(r2.final_value, 138.4), "got %s" % str(r2.final_value if r2 != null else null))
	_check("T(2) < 2c（138.4 < 140）", r2 != null and r2.final_value < 140.0)
	# 边际差分：ΔT(2) = c·δ < ΔT(1) = c
	_check("边际严格递减：ΔT(2)=18.4 < ΔT(1)=20",
		r1 != null and r2 != null and (r2.final_value - r1.final_value) < 20.0)
	# T(5)@δ=0.92 ≤ 4.3c（c=0.4 绕开 F4 池钳保险丝 cap_add_atk=2.0：T(5)≈1.704 < 2.0）
	pipe.begin_frame(3)
	var ctx5 := _make_ctx(target, 3)
	ctx5.add_entries = [{"trait_id": &"X", "pool_id": &"add_atk", "layer": 5, "contrib": 0.4, "decay_delta": 0.92, "is_curse": false}]
	var r5: DamageResult = pipe.resolve(ctx5)
	var t5: float = ((r5.final_value / 100.0) - 1.0) / 0.4 if r5 != null else -1.0
	_check("T(5)@δ0.92 ≤ 4.3c（≈4.2615）", t5 <= 4.3 and t5 > 4.0, "T(5)=%s" % str(t5))
	# n≥2 通式：T(5) < 5c
	_check("T(5) < 5c（严格递减通式）", t5 < 5.0)
	# δ 边界：δ=1.0 → 线性退化 T(5) = 5c
	pipe.begin_frame(4)
	var ctxd1 := _make_ctx(target, 4)
	ctxd1.add_entries = [{"trait_id": &"X", "pool_id": &"add_atk", "layer": 5, "contrib": 0.2, "decay_delta": 1.0, "is_curse": false}]
	var rd1: DamageResult = pipe.resolve(ctxd1)
	_check("δ=1.0 边界：线性退化 T(5) = 5c → S = 200",
		rd1 != null and is_equal_approx(rd1.final_value, 200.0), "got %s" % str(rd1.final_value if rd1 != null else null))
	# δ 边界：δ=0 → 仅首层有效 T(n) = c
	pipe.begin_frame(5)
	var ctxd0 := _make_ctx(target, 5)
	ctxd0.add_entries = [{"trait_id": &"X", "pool_id": &"add_atk", "layer": 5, "contrib": 0.2, "decay_delta": 0.0, "is_curse": false}]
	var rd0: DamageResult = pipe.resolve(ctxd0)
	_check("δ=0 边界：T(5) = c → S = 120",
		rd0 != null and is_equal_approx(rd0.final_value, 120.0), "got %s" % str(rd0.final_value if rd0 != null else null))
	# 负贡献（诅咒）线性全额不衰减（A2 §1.3 裁定 #10）
	pipe.begin_frame(6)
	var ctxc := _make_ctx(target, 6)
	ctxc.add_entries = [{"trait_id": &"CURSE", "pool_id": &"add_atk", "layer": 3, "contrib": -0.1, "decay_delta": 0.9, "is_curse": true}]
	var rc: DamageResult = pipe.resolve(ctxc)
	_check("诅咒负贡献全额不衰减：−0.1×3 → S = 70",
		rc != null and is_equal_approx(rc.final_value, 70.0), "got %s" % str(rc.final_value if rc != null else null))
	_check("诅咒结算 final ≥ 0（下界钳制）", rc != null and rc.final_value >= 0.0)


# ── 4. F4 池钳 + Flat 比例钳 ─────────────────────────────────────
func _test_add_flat_guards() -> void:
	print("── F4/Flat 池钳 ──")
	var pipe := DamagePipeline.new()
	var target := _make_target()
	# F4：Σ_add ≤ cap_add_atk = 2.0（BalanceTables 保险丝）
	pipe.begin_frame(1)
	var ctx := _make_ctx(target, 1)
	ctx.add_entries = [{"trait_id": &"X", "pool_id": &"add_atk", "layer": 1, "contrib": 3.0, "decay_delta": 0.85, "is_curse": false}]
	var r: DamageResult = pipe.resolve(ctx)
	_check("F4 池钳：Σ=3.0 → cap 2.0 → S = 300",
		r != null and is_equal_approx(r.final_value, 300.0), "got %s" % str(r.final_value if r != null else null))
	_check("F4 触发记审计 clamped_add", r != null and r.audit != null and r.audit.clamped_add.has(&"add_atk"))
	# Flat 比例钳：Σ_flat ≤ 50% × base
	pipe.begin_frame(2)
	var ctxf := _make_ctx(target, 2)
	ctxf.flat_bonus = 80.0
	var rf: DamageResult = pipe.resolve(ctxf)
	_check("Flat 比例钳：80 → 50 → S = 150",
		rf != null and is_equal_approx(rf.final_value, 150.0), "got %s" % str(rf.final_value if rf != null else null))
	_check("Flat 钳制记审计 clamped_flat", rf != null and rf.audit != null and rf.audit.clamped_flat)
	# 未超限 Flat 全额
	pipe.begin_frame(3)
	var ctxf2 := _make_ctx(target, 3)
	ctxf2.flat_bonus = 30.0
	var rf2: DamageResult = pipe.resolve(ctxf2)
	_check("Flat 未超限全额：S = 130", rf2 != null and is_equal_approx(rf2.final_value, 130.0))
	_check("未触发 Flat 审计", rf2 != null and rf2.audit != null and not rf2.audit.clamped_flat)


# ── 5. 乘区护栏（单区 cap / top-8 / priority / F9） ───────────────
func _test_mult_guards() -> void:
	print("── 乘区护栏 ──")
	var pipe := DamagePipeline.new()
	var target := _make_target()
	# 单区 cap_pool_p（F-14）
	pipe.begin_frame(1)
	var ctx := _make_ctx(target, 1)
	ctx.mult_pools = [{"pool_id": &"vuln", "source_uid": 1, "contrib": 3.0, "cap_pool": 2.0}]
	var r: DamageResult = pipe.resolve(ctx)
	_check("单区钳制：agg=min(3,2)=2 → M=3.0 → 300",
		r != null and is_equal_approx(r.final_value, 300.0), "got %s" % str(r.final_value if r != null else null))
	# 名额 top-8：10 区取贡献最大 8 个，截断记审计
	pipe.begin_frame(2)
	var ctx10 := _make_ctx(target, 2)
	var ten: Array[Dictionary] = []
	for i in range(10):
		ten.append({"pool_id": StringName("pool_%02d" % i), "source_uid": i + 1,
			"contrib": 0.02 * float(i + 1), "cap_pool": 10.0})
	ctx10.mult_pools = ten
	var r10: DamageResult = pipe.resolve(ctx10)
	var expect_top8 := 1.0
	for j in range(3, 11):
		expect_top8 *= 1.0 + 0.02 * float(j)
	_check("名额截断：10 区 → top-8 + 截断审计 2 条", r10 != null and r10.audit != null
		and r10.audit.truncated_mults.size() == 2 and r10.audit.pool_count == 8,
		"truncated=%s pool_count=%s" % [str(r10.audit.truncated_mults.size() if r10 != null else -1), str(r10.audit.pool_count if r10 != null else -1)])
	_check("top-8 乘积正确（贡献 0.06~0.20 连乘）", r10 != null
		and is_equal_approx(r10.final_value, 100.0 * expect_top8),
		"got %s expect %s" % [str(r10.final_value if r10 != null else null), str(100.0 * expect_top8)])
	_check("截断区为贡献最小的两区", r10 != null and r10.audit != null
		and r10.audit.truncated_mults.has(&"pool_00") and r10.audit.truncated_mults.has(&"pool_01"))
	# 同值 priority 决胜（确定性破序键）：10 区同贡献、priority = i+1 → 高 priority 8 区入选
	pipe.begin_frame(3)
	var ctxp := _make_ctx(target, 3)
	var prio: Array[Dictionary] = []
	for i in range(10):
		prio.append({"pool_id": StringName("prio_%02d" % i), "source_uid": i + 1,
			"contrib": 0.5, "cap_pool": 2.0, "priority": i + 1})
	ctxp.mult_pools = prio
	var rp: DamageResult = pipe.resolve(ctxp)
	_check("priority 决胜：priority 高的 8 区入选", rp != null and rp.audit != null
		and rp.pool_breakdown.has(&"prio_09") and rp.pool_breakdown.has(&"prio_02")
		and not rp.pool_breakdown.has(&"prio_00") and not rp.pool_breakdown.has(&"prio_01"))
	_check("priority 决胜确定性：截断恰为 priority 最低两区", rp != null and rp.audit != null
		and rp.audit.truncated_mults.has(&"prio_00") and rp.audit.truncated_mults.has(&"prio_01"))
	# F9 整体钳制 8.0（F-16）
	pipe.begin_frame(4)
	var ctx9 := _make_ctx(target, 4)
	var six: Array[Dictionary] = []
	for i in range(6):
		six.append({"pool_id": StringName("big_%d" % i), "source_uid": i + 1, "contrib": 1.0, "cap_pool": 2.0})
	ctx9.mult_pools = six
	var r9: DamageResult = pipe.resolve(ctx9)
	_check("F9 整体钳制：∏=64 → 8.0 → 800",
		r9 != null and is_equal_approx(r9.final_value, 800.0), "got %s" % str(r9.final_value if r9 != null else null))
	_check("F9 触发记审计 compressed", r9 != null and r9.audit != null and r9.audit.compressed)


# ── 6. Local 私有池 ──────────────────────────────────────────────
func _test_local_pools() -> void:
	print("── Local 私有池 ──")
	var pipe := DamagePipeline.new()
	var target := _make_target()
	# cap_local 钳制：Σ=0.6 → 0.5 → L=1.5
	pipe.begin_frame(1)
	var ctx := _make_ctx(target, 1)
	ctx.local_pools = [
		{"local_id": &"scorch", "contrib": 0.3, "cap_local": 0.5},
		{"local_id": &"scorch", "contrib": 0.3, "cap_local": 0.5},
	]
	var r: DamageResult = pipe.resolve(ctx)
	_check("Local cap_local：Σ=0.6 → 钳 0.5 → L=1.5 → 150",
		r != null and is_equal_approx(r.final_value, 150.0), "got %s" % str(r.final_value if r != null else null))
	# 独立连乘：两 local_id 各自 1+agg
	pipe.begin_frame(2)
	var ctx2 := _make_ctx(target, 2)
	ctx2.local_pools = [
		{"local_id": &"scorch", "contrib": 0.08, "cap_local": 0.5},
		{"local_id": &"other", "contrib": 0.2, "cap_local": 0.5},
	]
	var r2: DamageResult = pipe.resolve(ctx2)
	_check("Local 独立连乘：1.08×1.2 → 129.6",
		r2 != null and is_equal_approx(r2.final_value, 100.0 * 1.08 * 1.2),
		"got %s" % str(r2.final_value if r2 != null else null))
	# 不占名额：10 乘区（top-8 截断）+ 2 local → pool_count 仍 8，L 独立连乘
	pipe.begin_frame(3)
	var ctx3 := _make_ctx(target, 3)
	var ten: Array[Dictionary] = []
	for i in range(10):
		ten.append({"pool_id": StringName("m_%02d" % i), "source_uid": i + 1, "contrib": 0.05, "cap_pool": 10.0})
	ctx3.mult_pools = ten
	ctx3.local_pools = [
		{"local_id": &"scorch", "contrib": 0.1, "cap_local": 0.5},
		{"local_id": &"other", "contrib": 0.2, "cap_local": 0.5},
	]
	var r3: DamageResult = pipe.resolve(ctx3)
	_check("Local 不占名额：10 乘区截断后 pool_count=8", r3 != null and r3.audit != null
		and r3.audit.pool_count == 8)
	_check("Local 不受 cap_prod：L=1.1×1.2 独立连乘生效",
		r3 != null and is_equal_approx(r3.final_value, 100.0 * pow(1.05, 8.0) * 1.1 * 1.2),
		"got %s expect %s" % [str(r3.final_value if r3 != null else null), str(100.0 * pow(1.05, 8.0) * 1.1 * 1.2)])


# ── 7. 目标侧（抗性 × 易伤 + duck-typing 回退） ───────────────────
func _test_target_side() -> void:
	print("── 目标侧 ──")
	var pipe := DamagePipeline.new()
	var target := _make_target()
	# 抗性：r=0.5 → V=0.5
	pipe.begin_frame(1)
	var ctx := _make_ctx(target, 1)
	ctx.element = GameConst.Element.ICE
	var res_ice: Array[float] = [0.0, 0.0, 0.5, 0.0]
	target.set("resist", res_ice)
	var r: DamageResult = pipe.resolve(ctx)
	_check("抗性：r=0.5 → V=0.5 → 50",
		r != null and is_equal_approx(r.final_value, 50.0), "got %s" % str(r.final_value if r != null else null))
	_check("target_factor = (1−r) = 0.5", r != null and is_equal_approx(r.target_factor, 0.5))
	# 状态易伤：vuln=+0.25 → V=1.25（B_spec F-32 冰冻易伤口径）
	pipe.begin_frame(2)
	var ctxv := _make_ctx(target, 2)
	ctxv.element = GameConst.Element.KIN
	target.set("status_vuln", 0.25)
	var rv: DamageResult = pipe.resolve(ctxv)
	_check("易伤：+0.25 → V=1.25 → 125",
		rv != null and is_equal_approx(rv.final_value, 125.0), "got %s" % str(rv.final_value if rv != null else null))
	# 组合：抗性 × 易伤
	pipe.begin_frame(3)
	var ctxb := _make_ctx(target, 3)
	ctxb.element = GameConst.Element.ICE
	var rb: DamageResult = pipe.resolve(ctxb)
	_check("组合：V = 0.5 × 1.25 = 0.625 → 62.5",
		rb != null and is_equal_approx(rb.final_value, 62.5), "got %s" % str(rb.final_value if rb != null else null))
	target.set("status_vuln", 0.0)
	var res_zero: Array[float] = [0.0, 0.0, 0.0, 0.0]
	target.set("resist", res_zero)
	# 接口收紧等价迁移（原「裸 Node2D 无 resist 接口 → ctx 快照回退」）：
	# ctx.target 已收窄 Enemy → get_resist 直读路径；期望值 70 与数值语义不变
	var res_03: Array[float] = [0.0, 0.0, 0.3, 0.0]
	target.set("resist", res_03)
	pipe.begin_frame(4)
	var ctxb2 := _make_ctx(target, 4)
	ctxb2.element = GameConst.Element.ICE
	var rb2: DamageResult = pipe.resolve(ctxb2)
	_check("目标接口收紧：Enemy.get_resist 直读 r=0.3 → V=0.7 → 70",
		rb2 != null and is_equal_approx(rb2.final_value, 70.0), "got %s" % str(rb2.final_value if rb2 != null else null))
	target.set("resist", res_zero)
	# 缺省中性回退：真件 Enemy 无 status_vuln 属性 → _read_status_vuln 回退 0.0 → V=1.0
	var plain: Enemy = Enemy.new()                 # 纯真件（无派生脚本、无附加属性）
	plain.set("hp", 1000000.0)
	_targets.append(plain)
	pipe.begin_frame(5)
	var ctxb3 := _make_ctx(plain, 5)
	var rb3: DamageResult = pipe.resolve(ctxb3)
	_check("目标缺省：真件 Enemy 零抗零易伤 → V=1.0 中性 → 100",
		rb3 != null and is_equal_approx(rb3.final_value, 100.0))
	# 目标存活：满血真件 Enemy（take_result 走 apply_damage）→ killed=false
	_check("满血真件 Enemy → killed=false", rb3 != null and not rb3.killed)


# ── 8. 暴击 RNG（固定种子复现） ──────────────────────────────────
func _test_crit_rng() -> void:
	print("── 暴击 RNG ──")
	var target := _make_target()
	# 同种子同序列同结果（AC-12.5）
	var seq_a: Array[bool] = _crit_sequence(42, target)
	var seq_b: Array[bool] = _crit_sequence(42, target)
	_check("暴击固定种子复现：同种子同序列", seq_a == seq_b)
	var seq_c: Array[bool] = _crit_sequence(7, target)
	_check("异种子序列不同（RNG 真实生效）", seq_a != seq_c)
	_check("序列非全真非全假（0.5 概率 20 掷）", seq_a.has(true) and seq_a.has(false))
	# 同实例重置种子 → 序列复位
	var pipe := DamagePipeline.new()
	pipe.set_rng_seed(42)
	var s1: Array[bool] = []
	for i in range(20):
		pipe.begin_frame(i)
		var ctx := _make_ctx(target, i)
		ctx.crit_chance = 0.5
		s1.append(pipe.resolve(ctx).is_crit)
	pipe.set_rng_seed(42)
	var s2: Array[bool] = []
	for i in range(20):
		pipe.begin_frame(i)
		var ctx := _make_ctx(target, i)
		ctx.crit_chance = 0.5
		s2.append(pipe.resolve(ctx).is_crit)
	_check("同实例重置种子 → 序列复位一致", s1 == s2)
	# chance=1 必暴 + crit_mult 乘数（不消耗序列）
	pipe.begin_frame(100)
	var ctxc := _make_ctx(target, 100)
	ctxc.crit_chance = 1.0
	ctxc.crit_mult = 2.0
	var rc: DamageResult = pipe.resolve(ctxc)
	_check("chance=1 必暴击 ×2.0 → 200",
		rc != null and rc.is_crit and is_equal_approx(rc.final_value, 200.0))
	pipe.begin_frame(101)
	var ctxc2 := _make_ctx(target, 101)
	ctxc2.crit_chance = 1.0
	ctxc2.crit_mult = 1.5
	var rc2: DamageResult = pipe.resolve(ctxc2)
	_check("crit_mult 词条加成 1.5 → 150",
		rc2 != null and is_equal_approx(rc2.final_value, 150.0))
	# HIT_NO_CRIT（DOT/反应）不掷骰
	pipe.begin_frame(102)
	var ctxd := _make_ctx(target, 102)
	ctxd.crit_chance = 1.0
	ctxd.crit_mult = 2.0
	ctxd.hit_flags = GameConst.HIT_IS_DOT
	var rd: DamageResult = pipe.resolve(ctxd)
	_check("HIT_IS_DOT 不掷暴击（A2 §1.7 排除项）", rd != null and not rd.is_crit
		and is_equal_approx(rd.final_value, 100.0))
	_check("DOT 表现级：DOT 跳字 / HIT 分级", rd != null
		and rd.popup_style == GameConst.PopupStyle.DOT and rd.feel_level == GameConst.FeelLevel.HIT)
	# 暴击表现级
	_check("暴击表现级：CRIT 跳字 / CRIT 分级", rc != null
		and rc.popup_style == GameConst.PopupStyle.CRIT and rc.feel_level == GameConst.FeelLevel.CRIT)


func _crit_sequence(p_seed: int, p_target: Node2D) -> Array[bool]:
	var pipe := DamagePipeline.new()
	pipe.set_rng_seed(p_seed)
	var seq: Array[bool] = []
	for i in range(20):
		pipe.begin_frame(i)
		var ctx := _make_ctx(p_target, i)
		ctx.crit_chance = 0.5
		ctx.crit_mult = 2.0
		seq.append(pipe.resolve(ctx).is_crit)
	return seq


# ── 9. 幂等缓存 + 死亡短路 ───────────────────────────────────────
func _test_idempotent_and_death() -> void:
	print("── 幂等 / 死亡短路 ──")
	var pipe := DamagePipeline.new()
	var target := _make_target()
	var ctx := _make_ctx(target, 1)
	ctx.base_atk = 100.0
	var r1: DamageResult = pipe.resolve(ctx)
	var take_after_first: int = int(target.get("take_count"))
	var hp_after_first: float = float(target.get("hp"))
	# 同 (source_uid, target, frame_stamp) 第二次调用 → 返回缓存，不重复扣血
	var r2: DamageResult = pipe.resolve(ctx)
	_check("幂等：第二次调用返回缓存结果（同一对象）", r2 != null and r1 != null and r2 == r1)
	_check("幂等：不重复扣血（take_count 不变）", int(target.get("take_count")) == take_after_first)
	_check("幂等：hp 不变", is_equal_approx(float(target.get("hp")), hp_after_first))
	_check("幂等：dropped_dupe 计数 +1", int(pipe.stats()["dropped_dupe"]) == 1)
	# begin_frame 清缓存 → 同 key 重新结算
	pipe.begin_frame(2)
	var r3: DamageResult = pipe.resolve(ctx)
	_check("begin_frame 清缓存 → 重新结算（take_count +1）",
		r3 != null and int(target.get("take_count")) == take_after_first + 1)
	# 死亡短路：首次致死 → dead 置位 → 后续丢弃
	var frail := _make_target(100.0)
	pipe.begin_frame(3)
	var ctxk := _make_ctx(frail, 3)
	ctxk.base_atk = 100.0
	ctxk.mult_pools = [{"pool_id": &"frost_dmg", "source_uid": 1, "contrib": 0.5, "cap_pool": 2.0}]
	var rk: DamageResult = pipe.resolve(ctxk)
	_check("致死结算：killed=true + 目标 dead 置位（死亡只执行一次）",
		rk != null and rk.killed and bool(frail.get("dead")))
	pipe.begin_frame(4)
	var ctxk2 := _make_ctx(frail, 4)
	var rk2: DamageResult = pipe.resolve(ctxk2)
	_check("死亡短路：dead 目标 → null 丢弃 + dropped_dead 计数",
		rk2 == null and int(pipe.stats()["dropped_dead"]) >= 1)
	_check("死亡短路：不再扣血（take_count 仍 1）", int(frail.get("take_count")) == 1)
	# null 目标 → 丢弃
	pipe.begin_frame(5)
	var ctxn := _make_ctx(_make_target(), 5)
	ctxn.target = null
	var rn: DamageResult = pipe.resolve(ctxn)
	_check("null 目标 → null 丢弃", rn == null and int(pipe.stats()["dropped_dead"]) >= 2)


# ── 10. NaN/Inf/负数 sanitize ────────────────────────────────────
func _test_sanitize() -> void:
	print("── sanitize 入口防御 ──")
	var pipe := DamagePipeline.new()
	var target := _make_target()
	var invalid: int = 0
	# NaN/Inf → 丢弃
	pipe.begin_frame(1)
	var ctx_nan := _make_ctx(target, 1)
	ctx_nan.base_atk = NAN
	invalid += 1
	_check("base_atk=NaN → 丢弃 null", pipe.resolve(ctx_nan) == null)
	pipe.begin_frame(2)
	var ctx_inf := _make_ctx(target, 2)
	ctx_inf.base_atk = INF
	invalid += 1
	_check("base_atk=Inf → 丢弃 null", pipe.resolve(ctx_inf) == null)
	pipe.begin_frame(3)
	var ctx_flat := _make_ctx(target, 3)
	ctx_flat.flat_bonus = NAN
	invalid += 1
	_check("flat=NaN → 丢弃 null", pipe.resolve(ctx_flat) == null)
	pipe.begin_frame(4)
	var ctx_mult := _make_ctx(target, 4)
	ctx_mult.mult_pools = [{"pool_id": &"frost_dmg", "source_uid": 1, "contrib": NAN, "cap_pool": 2.0}]
	invalid += 1
	_check("乘区 contrib=NaN → 丢弃 null", pipe.resolve(ctx_mult) == null)
	pipe.begin_frame(5)
	var ctx_crit := _make_ctx(target, 5)
	ctx_crit.crit_chance = NAN
	invalid += 1
	_check("crit_chance=NaN → 丢弃 null", pipe.resolve(ctx_crit) == null)
	pipe.begin_frame(6)
	var ctx_add := _make_ctx(target, 6)
	ctx_add.add_entries = [{"trait_id": &"X", "pool_id": &"add_atk", "layer": 1, "contrib": INF, "decay_delta": 0.9, "is_curse": false}]
	invalid += 1
	_check("加算 contrib=Inf → 丢弃 null", pipe.resolve(ctx_add) == null)
	_check("dropped_invalid 计数 = %d" % invalid, int(pipe.stats()["dropped_invalid"]) == invalid)
	# 负 base_atk → 钳 0 + 计数（继续结算不崩溃；Flat 比例钳以钳后 base=0 为基准 → flat 也被钳 0）
	pipe.begin_frame(7)
	var ctx_neg := _make_ctx(target, 7)
	ctx_neg.base_atk = -50.0
	ctx_neg.flat_bonus = 10.0
	var r_neg: DamageResult = pipe.resolve(ctx_neg)
	_check("负 base_atk → 钳 0 继续结算（flat 以钳后 base 为基准同被钳 0）",
		r_neg != null and is_equal_approx(r_neg.final_value, 0.0), "got %s" % str(r_neg.final_value if r_neg != null else null))
	_check("sanitized_negative 计数", int(pipe.stats()["sanitized_negative"]) == 1)


# ── 11. R_alarm ×500 双闸 ────────────────────────────────────────
func _test_alarm() -> void:
	print("── R_alarm ×500 ──")
	var pipe := DamagePipeline.new()
	var target := _make_target()
	# 构造超限：M=8（6 区 ×2 钳 8.0）× L=1001（local cap 2000）→ ratio = 8008 > 500
	var alarm_ctx := func(p_frame: int, p_target: Node2D) -> DamageContext:
		var ctx := _make_ctx(p_target, p_frame)
		ctx.base_atk = 100.0
		var six: Array[Dictionary] = []
		for i in range(6):
			six.append({"pool_id": StringName("big_%d" % i), "source_uid": i + 1, "contrib": 1.0, "cap_pool": 2.0})
		ctx.mult_pools = six
		ctx.local_pools = [{"local_id": &"scorch", "contrib": 1000.0, "cap_local": 2000.0}]
		return ctx
	pipe.begin_frame(1)
	var r1: DamageResult = pipe.resolve(alarm_ctx.call(1, target))
	_check("R_alarm 触发：audit.alarm=true", r1 != null and r1.audit != null and r1.audit.alarm)
	_check("R_alarm 口径（抗性前）：ratio = 100×8×1001/100 = 8008",
		r1 != null and is_equal_approx(r1.audit.ratio, 8008.0), "ratio=%s" % str(r1.audit.ratio if r1 != null else null))
	_check("保险钳制：raw=800800 → base×500 = 50000",
		r1 != null and is_equal_approx(r1.final_value, 50000.0), "got %s" % str(r1.final_value if r1 != null else null))
	_check("damage_alarm 广播一次", _probe_get("alarm_hits") == 1)
	# 第二次超限（新目标）：audit.alarm 仍记 + alarms 计数，但广播一局一次
	var target2 := _make_target()
	target2.set("status_vuln", 0.25)     # 易伤不影响抗性前 ratio 口径
	pipe.begin_frame(2)
	var r2: DamageResult = pipe.resolve(alarm_ctx.call(2, target2))
	_check("第二次超限：audit.alarm 仍记（遥测口径）", r2 != null and r2.audit != null and r2.audit.alarm)
	_check("alarms 计数累计 = 2", int(pipe.stats()["alarms"]) == 2)
	_check("damage_alarm 一局一次：广播不重复（仍 1）", _probe_get("alarm_hits") == 1)
	_check("易伤不影响抗性前 ratio（仍 8008）",
		r2 != null and is_equal_approx(r2.audit.ratio, 8008.0))
	_check("易伤只放大 raw 后仍被保险钳制（50000）",
		r2 != null and is_equal_approx(r2.final_value, 50000.0))


# ── 12. 反应独立结算（F20/F21 快照口径） ─────────────────────────
func _test_reaction() -> void:
	print("── 反应独立结算 ──")
	var pipe := DamagePipeline.new()
	var target := _make_target()
	# 主结算取面板快照：S = 100×1.5+10 = 160（乘区 ×2.1 → 336）
	pipe.begin_frame(1)
	var ctx := _make_ctx(target, 1)
	ctx.add_entries = [
		{"trait_id": &"AFF_A", "pool_id": &"add_atk", "layer": 1, "contrib": 0.5, "decay_delta": 0.85, "is_curse": false},
	]
	ctx.flat_bonus = 10.0
	ctx.mult_pools = [
		{"pool_id": &"frost_dmg", "source_uid": 1, "contrib": 0.5, "cap_pool": 2.0},
		{"pool_id": &"bounce_dmg", "source_uid": 2, "contrib": 0.4, "cap_pool": 2.0},
	]
	var main: DamageResult = pipe.resolve(ctx)
	_check("主结算 panel_snapshot = 160（反应快照源）",
		main != null and is_equal_approx(main.panel_snapshot, 160.0))
	# 反应独立结算：D = χ × S_snap = 2.0 × 160 = 320（F-34 碎裂系数）
	pipe.begin_frame(2)
	var rctx := _make_ctx(target, 2)
	rctx.element = GameConst.ReactionType.RXN_FIR_ICE     # 反应通道：element 承载 ReactionType
	rctx.crit_chance = 1.0                                 # 反应不掷暴击（排除项）
	rctx.crit_mult = 2.0
	rctx.mult_pools = [{"pool_id": &"frost_dmg", "source_uid": 1, "contrib": 0.5, "cap_pool": 2.0}]  # 应被忽略
	var resolved_before: int = _probe_get("resolved_hits")
	var rr: DamageResult = pipe.resolve_reaction(main.panel_snapshot, 2.0, rctx)
	_check("反应快照口径：D = 2.0 × 160 = 320",
		rr != null and is_equal_approx(rr.final_value, 320.0), "got %s" % str(rr.final_value if rr != null else null))
	_check("反应不掷暴击（crit_chance=1 仍非暴击）", rr != null and not rr.is_crit)
	_check("反应乘区被忽略（不入乘区管线，F20）", rr != null and is_equal_approx(rr.mult_product, 1.0)
		and rr.pool_breakdown.is_empty())
	_check("反应表现级：REACTION 跳字 / CATALYST 分级", rr != null
		and rr.popup_style == GameConst.PopupStyle.REACTION and rr.feel_level == GameConst.FeelLevel.CATALYST)
	_check("reaction_triggered 广播（rxn + target_uid）",
		_probe_get("reaction_hits") == 1 and _probe_get("last_rxn") == GameConst.ReactionType.RXN_FIR_ICE
		and _probe_get("last_rxn_target") == int(target.get("uid")))
	_check("反应不吃抗性（F21 无 (1−r) 项）", rr != null and is_equal_approx(rr.target_factor, 1.0))
	_check("反应结算也广播 damage_resolved", _probe_get("resolved_hits") == resolved_before + 1)
	# 反应幂等：同 ctx 第二次 → 缓存返回不重复扣血
	var take_before: int = int(target.get("take_count"))
	var rr2: DamageResult = pipe.resolve_reaction(main.panel_snapshot, 2.0, rctx)
	_check("反应幂等：第二次返回缓存不重复扣血",
		rr2 != null and rr2 == rr and int(target.get("take_count")) == take_before)
	# 反应可击杀
	var frail := _make_target(200.0)
	pipe.begin_frame(3)
	var rctx2 := _make_ctx(frail, 3)
	rctx2.element = GameConst.ReactionType.RXN_FIR_LTG
	var rk: DamageResult = pipe.resolve_reaction(160.0, 2.0, rctx2)
	_check("反应可击杀：320 ≥ hp 200 → killed", rk != null and rk.killed and bool(frail.get("dead")))
	# 无效输入 → 丢弃
	pipe.begin_frame(4)
	var rctx3 := _make_ctx(target, 4)
	_check("反应 NaN 快照 → null", pipe.resolve_reaction(NAN, 2.0, rctx3) == null)
	_check("反应负系数 → null", pipe.resolve_reaction(160.0, -1.0, rctx3) == null)
	# 零快照 → 0 伤害（合法边界）
	pipe.begin_frame(5)
	var rctx4 := _make_ctx(target, 5)
	var r0: DamageResult = pipe.resolve_reaction(0.0, 2.0, rctx4)
	_check("零快照 → D = 0（合法边界）", r0 != null and is_equal_approx(r0.final_value, 0.0))


# ── 13. begin/end_frame 挂接与 DebugStats 落点 ────────────────────
func _test_frame_hooks() -> void:
	print("── frame hooks / DebugStats ──")
	var pipe := DamagePipeline.new()
	var target := _make_target()
	var settles_before: int = DebugStats.get_counter(&"damage.settles")
	var dupes_before: int = DebugStats.get_counter(&"damage.dropped_dupe")
	# 3 帧各结算 1 次 + 1 次幂等重复
	for i in range(3):
		pipe.begin_frame(i)
		var ctx := _make_ctx(target, i)
		pipe.resolve(ctx)
	pipe.begin_frame(3)
	var ctx_dupe := _make_ctx(target, 3)
	pipe.resolve(ctx_dupe)      # 第 4 次成功结算（新 frame 键）
	pipe.resolve(ctx_dupe)      # 幂等重复
	pipe.end_frame()
	_check("end_frame 落 DebugStats：settles 增量 4",
		DebugStats.get_counter(&"damage.settles") - settles_before == 4)
	_check("end_frame 落 DebugStats：dropped_dupe 增量 1",
		DebugStats.get_counter(&"damage.dropped_dupe") - dupes_before == 1)
	# 增量口径：本帧无新结算 → 不重复累计
	pipe.end_frame()
	_check("end_frame 增量口径：无新结算不累计",
		DebugStats.get_counter(&"damage.settles") - settles_before == 4)
	# begin_frame 无参调用（架构 §2.5 兼容形态）
	pipe.begin_frame()
	var ctx2 := _make_ctx(target, 99)
	pipe.resolve(ctx2)
	pipe.end_frame()
	_check("begin_frame() 无参兼容 + 增量 1",
		DebugStats.get_counter(&"damage.settles") - settles_before == 5)
	# stats() 键完整
	var st: Dictionary = pipe.stats()
	_check("stats() 键完整（settles/dropped_*/alarms）",
		st.has("settles") and st.has("dropped_dupe") and st.has("dropped_dead")
		and st.has("dropped_invalid") and st.has("alarms") and st.has("reaction_settles"))


# ── 14. 确定性（固定种子 1000 次哈希一致） ───────────────────────
func _test_determinism() -> void:
	print("── 确定性 1000 次 ──")
	var hash_a: int = _run_batch(20260828)
	var hash_b: int = _run_batch(20260828)
	_check("固定种子连跑 1000 次 resolve 哈希一致（同输入同输出）", hash_a == hash_b,
		"hash_a=%d hash_b=%d" % [hash_a, hash_b])
	var hash_c: int = _run_batch(13579)
	_check("异种子哈希不同（暴击序列真实影响）", hash_a != hash_c)


func _run_batch(p_seed: int) -> int:
	var pipe := DamagePipeline.new()
	pipe.set_rng_seed(p_seed)
	var target := _make_target(1000000000.0)
	var h: int = 0
	for i in range(1000):
		pipe.begin_frame(i)
		var ctx := _mixed_ctx(target, i)
		var r: DamageResult = pipe.resolve(ctx)
		if r != null:
			h = (h * 1000003 + int(round(r.final_value * 100.0))) % 1000000007
			if r.is_crit:
				h = (h + 17) % 1000000007
	_targets.erase(target)      # 先出册再释放（防 TypedArray 持已释放对象）
	target.free()
	return h


func _mixed_ctx(p_target: Node2D, p_i: int) -> DamageContext:
	# 混合输入（确定性参数化）：加算/诅咒/乘区/Local/暴击全路径覆盖
	var ctx := _make_ctx(p_target, p_i, 5000 + p_i % 7)
	ctx.base_atk = 80.0 + 10.0 * float(p_i % 5)
	ctx.crit_chance = 0.37
	ctx.crit_mult = 2.0
	ctx.flat_bonus = 5.0 * float(p_i % 3)
	ctx.add_entries = [
		{"trait_id": &"AFF_A", "pool_id": &"add_atk", "layer": 1 + p_i % 4, "contrib": 0.1, "decay_delta": 0.9, "is_curse": false},
		{"trait_id": &"CURSE", "pool_id": &"add_atk", "layer": 1 + p_i % 2, "contrib": -0.05, "decay_delta": 0.9, "is_curse": true},
	]
	ctx.mult_pools = [
		{"pool_id": &"frost_dmg", "source_uid": 1, "contrib": 0.2 + 0.05 * float(p_i % 3), "cap_pool": 2.0},
		{"pool_id": &"bounce_dmg", "source_uid": 2, "contrib": 0.15, "cap_pool": 2.0},
	]
	ctx.local_pools = [{"local_id": &"scorch", "contrib": 0.1 * float(p_i % 4), "cap_local": 0.5}]
	ctx.element = p_i % 4
	return ctx


# ── 清理 ─────────────────────────────────────────────────────────
func _cleanup() -> void:
	EventBus.damage_resolved.disconnect(Callable(_probe, "on_resolved"))
	EventBus.damage_alarm.disconnect(Callable(_probe, "on_alarm"))
	EventBus.reaction_triggered.disconnect(Callable(_probe, "on_reaction"))
	_probe.free()
	for t in _targets:
		t.free()
	_targets.clear()
	EventBus.end_frame()

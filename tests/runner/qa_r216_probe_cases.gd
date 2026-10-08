# tests/runner/qa_r216_probe_cases.gd
# R216 QA 独立探针（qa 系交叉验证口——r216_shardbatch / r211_xpstar 之外的第三方验证）：
#   ① 碎片全生命周期分桶：spawn 落桶→同变体共桶→merge 爬档换桶→彩档步进换桶→
#      release 归位池根→复取再落桶；桶内不残留已归还片、桶节点惰性保留
#   ② modulate 恒白不变量：burst/rest/sink/bob/homing 亮闪/巡航/⑦磁吸段/force_magnet
#      波末回收（PAUSED 迁移全场强制）各相位帧后均 WHITE；亮闪=缩放脉冲非亮度
#   ③ 数值守恒：merge_value 并珠 value/基线 max 口径 + gain_xp 经 _tick_xp_shards
#      吸收入账「分片吸收 vs 并珠后单珠吸收」总额一致 + 满池 _spawn_xp_shard 产品并珠路径
#   ④ 量化边界：_baked_tier_color 三级 alpha（档底 0.5/带内 0.75/档顶 1.0）逐带边界 +
#      贴图缓存键身份 + 彩档 6 步进回绕（_anim_t 大值）+ 归还/复取无残留
#   ⑤ 预热队列内容：op:3 星变体恰 18 项（4 档×3 量化 alpha + 彩档 6 色相）、无白体项、
#      全部带 fill 键（防 default WHITE 兜底滑入）
#   ⑥ 遥测：diag_counts bucket_xp/shards 读数（同变体共桶=拾N桶x 合批对读）+ magnet 计数
#      + DebugStats 十一段序/标签 + 真实 diag 行尾段「桶e+p+x 磁 拾」格式
#   ⑦ 拆键：PLAYING 帧 player/shard 分立 + 开窗 card 键入账 ui 零写（手动归因口 +
#      真帧尾产品路径双验）+ 负控制（无 deferred 不出 card 键）+ 探针逐帧重建不残留
#   ⑧ dwell：MENU 帧累计 / 非 MENU 帧清零 / 回菜单重计 + boss 挂机门随 dwell=0 重新武装
#      （vc23 0:41 顿挫修复的行为口径）+ 清队后 18 星变体全量入缓存
# 坑位纪律：xp 池经 _gl.pools[&"xp"]；XpShard.activate 内含出生散射（先 activate 后落位）；
# 池化实例不 add_child、只 release 一次；入口零工程类名直引（用例体运行时 load）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const PLAYER_HOME := Vector2(360.0, 900.0)
const DT := 1.0 / 60.0
const ABSORB := 24.0                            # XpShard.ABSORB_DISTANCE 同口径

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null                        # 组①~④ 用实例
var _gl2: GameLoop = null                       # 组⑤~⑧ 用实例（新鲜桶宿主/队列/dwell）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261002)
	_boot(&"_gl")
	await tree.process_frame
	await tree.process_frame
	_test_1_shard_bucket_lifecycle()
	_test_2_modulate_invariant()
	_test_3_value_conservation()
	_test_4_quant_edges()
	_teardown(&"_gl")
	_boot(&"_gl2")
	_test_5_prewarm_queue_content()
	_test_6_diag_telemetry()
	_enter_play(_gl2)
	_test_7_stage_split_and_card_key()
	_test_8_dwell_gate_and_cache()
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
	gl.name = "R216QA%s" % p_slot
	tree.get_root().add_child(gl)
	set(p_slot, gl)
	gl.state = GameConst.GameStatus.MENU
	gl.current_map_id = MapTable.FIRST_MAP_ID
	gl.start_run()
	gl.state = GameConst.GameStatus.MENU
	gl.player.global_position = PLAYER_HOME


func _teardown(p_slot: String) -> void:
	tree.paused = false
	RunSave.clear()
	var gl: GameLoop = get(p_slot)
	if gl != null:
		gl.free()
		set(p_slot, null)


func _enter_play(p_gl: GameLoop) -> void:
	p_gl.state = GameConst.GameStatus.MENU
	p_gl.current_map_id = MapTable.FIRST_MAP_ID
	p_gl.start_run()


# ── 共用小件 ──────────────────────────────────────────────────────
func _spawn(p_gl: GameLoop, p_pos: Vector2, p_value: float, p_baseline: float) -> XpShard:
	# 产品路径 spawn（_spawn_xp_shard：host 注入 + active_shards 登记）；返回末位新片
	var n0: int = (p_gl.get("active_shards") as Array).size()
	p_gl._spawn_xp_shard(p_pos, p_value, p_baseline)
	var arr: Array = p_gl.get("active_shards")
	if arr.size() != n0 + 1:
		return null
	return arr[arr.size() - 1] as XpShard


func _xp_pool(p_gl: GameLoop) -> XPPool:
	return p_gl.pools[&"xp"] as XPPool


func _bucket_of(p_host: Node, p_shard: XpShard) -> Node:
	# 桶真源：host._buckets[贴图]（place 语义的期望值映射）
	var buckets: Dictionary = p_host.get("_buckets")
	return buckets.get(p_shard._sprite.texture) as Node


func _release_active(p_gl: GameLoop) -> void:
	var pool := _xp_pool(p_gl)
	for s in (p_gl.get("active_shards") as Array).duplicate():
		pool.release(s)
	(p_gl.get("active_shards") as Array).clear()


func _is_white(p_shard: XpShard) -> bool:
	return p_shard._sprite.modulate.is_equal_approx(Color.WHITE)


# ── ① 碎片全生命周期分桶 ─────────────────────────────────────────
func _test_1_shard_bucket_lifecycle() -> void:
	print("── ① 碎片生命周期分桶 ──")
	var pool := _xp_pool(_gl)
	var host: Node = pool.bucket_host
	var pool_root: Node = pool as Node
	_check("①a 装配：XP 池 bucket_host 在位", host != null, str(host))
	if host == null:
		return
	var s0 := _spawn(_gl, Vector2(300, 600), 4.0, 4.0)      # 白档 q1（ratio1 → α0.7→q1）
	var s1 := _spawn(_gl, Vector2(320, 620), 4.5, 4.0)      # 白档 q1（同变体）
	var s2 := _spawn(_gl, Vector2(340, 640), 30.0, 4.0)     # 紫档 q1
	var rb := _spawn(_gl, Vector2(360, 660), 200.0, 4.0)    # 彩档 step0
	_check("①b spawn 落桶：父级=桶节点（非池根直挂）",
		s0.get_parent() != pool_root and host.is_ancestor_of(s0),
		"parent=%s" % str(s0.get_parent()))
	_check("①c 同变体共桶：白 q1 两片同父且==贴图映射桶",
		s0.get_parent() == s1.get_parent() and s0.get_parent() == _bucket_of(host, s0), "")
	_check("①d 异变体异桶：紫档另桶", s2.get_parent() != s0.get_parent()
		and s2.get_parent() == _bucket_of(host, s2), "")
	_check("①e 彩档异桶：彩 step0 第三桶", rb.get_parent() != s0.get_parent()
		and rb.get_parent() == _bucket_of(host, rb), "")
	_check("①f 桶数：恰 3 变体 3 桶", host.get_child_count() == 3
		and (host.get("_buckets") as Dictionary).size() == 3,
		"host=%d dict=%d" % [host.get_child_count(), (host.get("_buckets") as Dictionary).size()])
	# merge 爬档换桶：白 q1 → 紫 q1（移入紫桶）
	var white_bucket: Node = s0.get_parent()
	s0.merge_value(26.0, 4.0)                               # value 30 → ratio 7.5 紫档
	_check("①g merge 爬档换桶：与紫档片共桶",
		s0.get_parent() == s2.get_parent() and s0.get_parent() != white_bucket, "")
	# 彩档步进换桶：_anim_t 0→1 → step 0→2
	var rb_tex0: Texture2D = rb._sprite.texture
	rb._anim_t = 1.0
	rb._tick_visual_anim(DT)
	_check("①h 彩档步进换桶：step0→2 换贴图换桶",
		rb._rainbow_step == 2 and rb._sprite.texture != rb_tex0
			and rb.get_parent() == _bucket_of(host, rb), "step=%d" % int(rb._rainbow_step))
	# release 归位池根 + 桶惰性保留 + 桶内不残留
	pool.release(s1)
	(_gl.get("active_shards") as Array).erase(s1)         # 手动口同步摘除（防清场二次归还）
	_check("①i release 归位池根（unplace 链）", s1.get_parent() == pool_root,
		"parent=%s" % str(s1.get_parent()))
	_check("①j 桶惰性保留：白桶仍在 host 下且已无残留片（桶内不残留）",
		is_instance_valid(white_bucket) and white_bucket.get_parent() == host
			and white_bucket.get_child_count() == 0, "")
	_check("①k 桶数单调：release 不拆桶（白/紫/彩 step0/彩 step2 共 4）",
		host.get_child_count() == 4 and (host.get("_buckets") as Dictionary).size() == 4,
		"host=%d" % host.get_child_count())
	# 复取再落桶（free 栈 LIFO → 弹回同实例）
	var again: XpShard = pool.acquire() as XpShard
	_check("①l 复取同实例（真·复用）", again == s1, "")
	again.activate(4.0, 4.0)
	_check("①m 复取再落桶：同变体回原白桶", again.get_parent() == white_bucket,
		"parent=%s" % str(again.get_parent()))
	pool.release(again)
	_check("①n 二次归还仍归位池根", again.get_parent() == pool_root, "")
	# 清场 + 归还清零契约
	_release_active(_gl)
	_check("①o 清场：active_shards 空、余片全归池根",
		(_gl.get("active_shards") as Array).is_empty()
			and s0.get_parent() == pool_root and s2.get_parent() == pool_root
			and rb.get_parent() == pool_root, "")
	_check("①p 归还清零：彩片 _rainbow_step=-1、modulate 白、scale 单位",
		rb._rainbow_step == -1 and _is_white(rb) and rb._sprite.scale == Vector2.ONE, "")


# ── ② modulate 恒白不变量（全相位 + 磁吸/波末回收路径） ───────────
func _test_2_modulate_invariant() -> void:
	print("── ② modulate 恒白 ──")
	_gl.player.global_position = Vector2(60.0, 640.0)       # 远离碎片活动区（>120 半径）
	# bob 路径（活动带内：落定 1s 直达 BOB）
	var b1 := _spawn(_gl, Vector2(660, 1000), 4.0, 4.0)
	b1.global_position = Vector2(660, 1000)                 # activate 散射后复落位
	b1.tick(0.5)                                            # burst→rest
	_check("②a burst/rest 帧 modulate 白", _is_white(b1)
		and b1._phase == XpShard.PHASE_REST, "phase=%d" % int(b1._phase))
	b1.tick(0.5)                                            # age1.0 带内→BOB
	_check("②b bob 相位 modulate 白", _is_white(b1)
		and b1._phase == XpShard.PHASE_BOB, "phase=%d" % int(b1._phase))
	# sink 路径（带外下沉至带）
	var s1 := _spawn(_gl, Vector2(660, 650), 4.0, 4.0)
	s1.global_position = Vector2(660, 650)                  # 带外贴带（54px 沉程——防 age 累计触发回归干扰）
	s1.tick(0.5)
	s1.tick(0.5)                                            # age1.0 带外→SINK
	_check("②c sink 相位进入 + modulate 白", _is_white(s1)
		and s1._phase == XpShard.PHASE_SINK, "phase=%d" % int(s1._phase))
	var sink_ok := true
	var guard := 0
	while s1._phase != XpShard.PHASE_BOB and guard < 40:
		s1.tick(0.25)
		if not _is_white(s1):
			sink_ok = false
		guard += 1
	_check("②d 下沉全程（%d 帧）至 bob modulate 恒白（未被回归打断）" % guard,
		sink_ok and s1._phase == XpShard.PHASE_BOB and not s1._homing,
		"phase=%d homing=%s" % [int(s1._phase), str(s1._homing)])
	# homing：亮闪=缩放脉冲（R216 口径）+ 巡航白（提亮乘法已除）
	var h1 := _spawn(_gl, Vector2(660, 1000), 20.0, 4.0)    # value≥15 → 2s 回归
	h1.global_position = Vector2(660, 1000)
	var vs: float = h1._value_scale
	for i in range(8):                                      # age 0→2.0 触发
		h1.tick(0.25)
	_check("②e homing 触发（2s 大珠口径）", h1._homing and _is_white(h1), "")
	h1.tick(0.15)                                           # 亮闪窗内帧
	_check("②f 亮闪=缩放脉冲（x>_value_scale×1.02）且 modulate 白",
		_is_white(h1) and h1._sprite.scale.x > vs * 1.02,
		"sx=%.3f vs=%.3f" % [h1._sprite.scale.x, vs])
	h1.tick(0.3)                                            # 闪窗已过 → 巡航
	_check("②g 巡航帧 modulate 白（亮度乘法已除）", _is_white(h1)
		and h1._sprite.scale.x <= vs * 1.081, "sx=%.3f" % h1._sprite.scale.x)
	# ⑦ 磁吸段 tick + force_magnet 波末回收（手动口）
	var m1 := _spawn(_gl, PLAYER_HOME, 4.0, 4.0)
	m1.global_position = _gl.player.global_position + Vector2(60.0, 0.0)
	m1.force_magnet()
	_gl.call(&"_tick_magnetized_shards", DT)
	_check("②h ⑦磁吸段：磁片位移向玩家且 modulate 白",
		m1.is_magnet() and _is_white(m1)
			and m1.global_position.distance_to(_gl.player.global_position) < 60.0, "")
	m1.global_position = _gl.player.global_position
	_gl.call(&"_tick_magnetized_shards", DT)
	_check("②i ⑦磁吸段吸收：出 active_shards + 归位池根",
		not (_gl.get("active_shards") as Array).has(m1)
			and m1.get_parent() == (_gl.pools[&"xp"] as ObjectPool as Node), "")
	# 产品迁移口 force_magnet：PLAYING→PAUSED 全场强制 → ⑦ 驱动 → 回 PLAYING
	var u1 := _spawn(_gl, Vector2(660, 100), 4.0, 4.0)
	var u2 := _spawn(_gl, Vector2(660, 1000), 4.0, 4.0)
	_gl.state = GameConst.GameStatus.PLAYING
	_gl.change_state(GameConst.GameStatus.PAUSED)
	_check("②j PAUSED 迁移全场 force_magnet + 树暂停",
		u1.is_magnet() and u2.is_magnet() and tree.paused, "")
	_gl.call(&"_tick_magnetized_shards", DT)
	_check("②k 波末回收帧两片 modulate 白（PAUSED 通道驱动）",
		_is_white(u1) and _is_white(u2), "")
	_gl.change_state(GameConst.GameStatus.PLAYING)
	_check("②l 回 PLAYING 解除树暂停", not tree.paused, "")
	# 彩档磁吸：步进路径下仍白
	var r1 := _spawn(_gl, PLAYER_HOME, 200.0, 4.0)
	r1.global_position = _gl.player.global_position + Vector2(60.0, 0.0)
	r1.force_magnet()
	_gl.call(&"_tick_magnetized_shards", DT)
	_check("②m 彩档磁吸帧 modulate 白且在桶宿主下",
		_is_white(r1) and (_gl.pools[&"xp"] as ObjectPool).bucket_host.is_ancestor_of(r1), "")
	_release_active(_gl)
	_gl.player.global_position = PLAYER_HOME


# ── ③ 数值守恒（merge 并珠 + 入账） ──────────────────────────────
func _test_3_value_conservation() -> void:
	print("── ③ 数值守恒 ──")
	var pool := _xp_pool(_gl)
	# 基础口径：value 累加 / 基线取 max / 不重置磁吸
	var m := _spawn(_gl, Vector2(300, 600), 4.0, 4.0)
	m.force_magnet()
	m.merge_value(10.0, 2.0)
	_check("③a merge 口径：value=14 恰等、基线 max(4,2)=4、磁吸不重置",
		is_equal_approx(m.value, 14.0) and is_equal_approx(m._baseline, 4.0)
			and m.is_magnet(), "v=%.4f b=%.4f" % [m.value, m._baseline])
	m.merge_value(-5.0, 0.0)
	_check("③b 负并入防御：value 不减", is_equal_approx(m.value, 14.0), "v=%.4f" % m.value)
	_check("③c merge 爬档：14/4=3.5 → 蓝档", m._tier == 1, "tier=%d" % int(m._tier))
	# 入账守恒：分片吸收 vs 并珠单珠吸收（经 _tick_xp_shards 产品路径）
	var totals := []                                        # [哨兵, A 总额, A 次数, B 总额, B 次数]
	totals.resize(5)
	var stage := [0]                                        # lambda 按值捕获→容器路由
	var cb := func(p_amount: float) -> void:
		if stage[0] == 0:
			totals[1] += p_amount
			totals[2] += 1
		else:
			totals[3] += p_amount
			totals[4] += 1
	totals[1] = 0.0
	totals[2] = 0
	totals[3] = 0.0
	totals[4] = 0
	# 场景 A：三片各自吸收
	var a1 := _spawn(_gl, PLAYER_HOME, 2.0, 4.0)
	var a2 := _spawn(_gl, PLAYER_HOME, 2.5, 4.0)
	var a3 := _spawn(_gl, PLAYER_HOME, 3.0, 4.0)
	for s in [a1, a2, a3]:
		(s as XpShard).global_position = _gl.player.global_position
	EventBus.xp_gained.connect(cb)
	_gl.call(&"_tick_xp_shards", DT)
	# 场景 B：同面值并成单珠后吸收
	stage[0] = 1
	var b1 := _spawn(_gl, PLAYER_HOME, 2.0, 4.0)
	b1.global_position = _gl.player.global_position
	var q0_bucket: Node = b1.get_parent()
	b1.merge_value(2.5, 4.0)
	b1.merge_value(3.0, 4.0)
	_check("③d 并珠后档内变体换桶（白 q0→q2 仍白档）",
		b1._tier == 0 and b1.get_parent() != q0_bucket
			and b1.get_parent() == _bucket_of((_gl.pools[&"xp"] as ObjectPool).bucket_host, b1),
		"tier=%d" % int(b1._tier))
	_gl.call(&"_tick_xp_shards", DT)
	EventBus.xp_gained.disconnect(cb)
	_check("③e 派发次数：A=3（分片）+B=1（并珠）",
		int(totals[2]) == 3 and int(totals[4]) == 1, str(totals))
	var total_a: float = float(totals[1])
	var total_b: float = float(totals[3])
	_check("③f 总额守恒：并珠单珠吸收 == 分片吸收总额（乘区线性）",
		absf(total_a - total_b) <= maxf(1e-6, 1e-6 * maxf(total_a, total_b)),
		"A=%.6f B=%.6f" % [total_a, total_b])
	_check("③g 总额下界：≥ 面值和 7.5（乘区 ≥1）", total_a >= 7.5 - 1e-6,
		"A=%.6f" % total_a)
	# 产品满池并珠路径：池吸干后 _spawn_xp_shard 并入 active_shards[0]
	_release_active(_gl)
	var cap: int = GameConfig.get_pool_capacity(&"xp")
	var base := _spawn(_gl, Vector2(300, 600), 4.0, 4.0)    # 先占 1 片（并珠落点 active_shards[0]）
	var drained: Array = []
	while true:
		var s: XpShard = pool.acquire() as XpShard
		if s == null:
			break
		drained.append(s)                               # 吸干余量 → 后续 spawn 满池
	_check("③h 池吸干夹具（acquire %d == 容量-1）",
		drained.size() == cap - 1 and base != null,
		"drained=%d cap=%d" % [drained.size(), cap])
	var pre_val: float = base.value
	_gl._spawn_xp_shard(Vector2(999.0, 999.0), 7.5, 4.0)
	_check("③i 满池并珠：active_shards 仍 1 片、value=11.5 恰等、基线 4",
		(_gl.get("active_shards") as Array).size() == 1
			and is_equal_approx(base.value, pre_val + 7.5)
			and is_equal_approx(base._baseline, 4.0),
		"v=%.4f" % base.value)
	_check("③j 并珠爬档：11.5/4=2.875 → 蓝档", base._tier == 1, "tier=%d" % int(base._tier))
	for s in drained:
		pool.release(s)
	_release_active(_gl)


# ── ④ 量化边界（三级 alpha + 彩档 6 步进回绕） ────────────────────
func _test_4_quant_edges() -> void:
	print("── ④ 量化边界 ──")
	var pool := _xp_pool(_gl)
	var host: Node = pool.bucket_host
	var p: XpShard = pool.acquire() as XpShard
	p.bucket_host = host
	# [value, baseline, 档色索引, 量化 alpha]（档底 0.5 / 带内 0.75 / 档顶 1.0）
	var cases := [
		[1.0, 4.0, 0, 0.5],    # 白档底 ratio0.25
		[4.0, 4.0, 0, 0.75],   # 白档中 ratio1.0 → α0.7 → q1
		[9.9, 4.0, 0, 1.0],    # 白档顶 ratio2.475 → α≈1 → q2
		[10.0, 4.0, 1, 0.5],   # 蓝档底（跨带重置）
		[19.9, 4.0, 1, 1.0],   # 蓝档顶
		[20.0, 4.0, 2, 0.5],   # 紫档底
		[47.9, 4.0, 2, 1.0],   # 紫档顶
		[48.0, 4.0, 3, 0.5],   # 金档底
		[159.9, 4.0, 3, 1.0],  # 金档顶
		[7.7, 0.0, 0, 0.5],    # 基线 0 降级恒 0.5
	]
	var all_ok := true
	var detail := ""
	for c in cases:
		p.activate(float(c[0]), float(c[1]))
		var exp_c: Color = PopPalette.xp_tier_color(int(c[2]))
		exp_c.a = float(c[3])
		var baked: Color = p._baked_tier_color()
		if not baked.is_equal_approx(exp_c) or p._sprite.texture != TextureFactory.star(44, exp_c) \
				or not _is_white(p):
			all_ok = false
			detail += "v%s→%s/%s " % [str(c[0]), baked.to_html(), exp_c.to_html()]
	_check("④a 三级量化逐带边界 ×10：烤色/贴图缓存键/modulate 白 全对",
		all_ok, detail)
	p.activate(200.0, 4.0)                                  # 彩档 a=1.0
	var rb_c := Color.from_hsv(0.0, 0.7, 1.0)
	_check("④b 彩档烤色：hsv(0,0.7,1) a=1.0 + 贴图键身份",
		p._baked_tier_color().is_equal_approx(rb_c)
			and p._sprite.texture == TextureFactory.star(44, rb_c)
			and is_equal_approx(p._baked_tier_color().a, 1.0), "")
	# 三级 alpha 贴图互异（变体分键成立 → 分桶成立前提）
	var t05 := TextureFactory.star(44, _tier_color(0, 0.5))
	var t075 := TextureFactory.star(44, _tier_color(0, 0.75))
	var t10 := TextureFactory.star(44, _tier_color(0, 1.0))
	_check("④c 白档三 alpha 贴图缓存实例互异", t05 != t075 and t075 != t10 and t05 != t10, "")
	# 彩档 6 步进回绕（含 _anim_t 大值）
	var wrap_ok := true
	var wdetail := ""
	for tc in [[2.6, 5], [2.9, 0], [100.7, 1]]:
		p._anim_t = float(tc[0])
		p._tick_visual_anim(DT)
		var exp_hue := fmod(float(int(tc[1])) / 6.0, 1.0)
		var exp_c := Color.from_hsv(exp_hue, 0.7, 1.0)
		if int(p._rainbow_step) != int(tc[1]) \
				or p._sprite.texture != TextureFactory.star(44, exp_c) \
				or p.get_parent() != _bucket_of(host, p):
			wrap_ok = false
			wdetail += "t%s→step%d " % [str(tc[0]), int(p._rainbow_step)]
	_check("④d 彩档步进回绕：step5→0 回绕 + _anim_t 大值（100.7→step1）+ 贴图/桶随动",
		wrap_ok, wdetail)
	# 归还→复取无彩档残留（真·复用路径：release→acquire→activate）
	pool.release(p)
	var p2: XpShard = pool.acquire() as XpShard
	p2.bucket_host = host
	p2.activate(4.0, 4.0)
	_check("④e 复取无残留：同实例弹出 + 白档 q1 贴图 + _rainbow_step=-1",
		p2 == p and p2._rainbow_step == -1 and p2._tier == 0
			and p2._sprite.texture == TextureFactory.star(44, _tier_color(0, 0.75)), "")
	pool.release(p2)


func _tier_color(p_tier: int, p_alpha: float) -> Color:
	var c := PopPalette.xp_tier_color(p_tier)
	c.a = p_alpha
	return c


# ── ⑤ 预热队列内容（boot 后立刻、零引擎帧污染） ──────────────────
func _test_5_prewarm_queue_content() -> void:
	print("── ⑤ 预热队列内容 ──")
	var q: Array = _gl2.get("_tex_prewarm_queue")
	var star_items: Array = []
	for job in q:
		if int((job as Dictionary).get(&"op", -1)) == 3:
			star_items.append(job)
	# R227 契约迁移：字形 cell（op:6×12）前移队首（位图激活路径修复）——共享域
	# bead 退居第 13 项（「不被 R216 破坏」语义收窄为首个贴图域仍是 op:2）
	_check("⑤a 首贴图域 op==2 居第 13 项（R227 字形前移后共享域次序不变）",
		q.size() > 12 and int((q[12] as Dictionary).get(&"op", -1)) == 2,
		str(q[12]) if q.size() > 12 else "短队")
	_check("⑤b 星变体项恰 18（4 档×3 量化 alpha + 彩档 6 色相）",
		star_items.size() == 18, "n=%d" % star_items.size())
	var got: Array[String] = []
	var missing_fill := 0
	var has_white := false
	for job in star_items:
		var d := job as Dictionary
		if not d.has(&"fill"):
			missing_fill += 1
			continue
		var c: Color = d[&"fill"]
		if c.to_html() == Color.WHITE.to_html():
			has_white = true
		got.append(c.to_html())
	var exp: Array[String] = []
	for t in 4:
		for a in 3:
			exp.append(_tier_color(t, 0.5 + 0.25 * a).to_html())
	for h in 6:
		exp.append(Color.from_hsv(float(h) / 6.0, 0.7, 1.0).to_html())
	var exp_set := {}
	for k in exp:
		exp_set[k] = true
	var got_set := {}
	for k in got:
		got_set[k] = true
	_check("⑤c 18 项填充色与产品量化口径逐键一致（含 alpha）",
		got_set == exp_set and got.size() == 18, "got=%d exp=%d" % [got.size(), exp.size()])
	_check("⑤d 无白体项：op:3 全带 fill 键且无 ffffff（default WHITE 兜底不可达）",
		missing_fill == 0 and not has_white,
		"nofill=%d white=%s" % [missing_fill, str(has_white)])
	var has_enemy := false
	for job in q:
		if int((job as Dictionary).get(&"op", -1)) == 0:
			has_enemy = true
			break
	_check("⑤e 敌 kind 项仍在队（op:0 ≥1）", has_enemy, "")


# ── ⑥ 遥测（diag_counts + 十六段 + diag 行） ─────────────────────
func _test_6_diag_telemetry() -> void:
	print("── ⑥ 遥测 ──")
	# R217/R218 有意契约变更（主控同步）：十一段→十三段→十五段——移/火 + 跳/他
	#（vc24 尖峰玩117ms：player.tick 内部归因），插在 player 之后
	# R220 刀1 有意契约变更（拆解契约 §3.1 同步）：十五段→十六段——card 拆
	# card_open「开」/card_drain「消」（开窗级联 vs 溢出批消化归因分离）
	var order: Array[StringName] = [&"player", &"player_mv", &"player_wp", &"shard",
		&"grid_rebuild", &"grid_projectile",
		&"enemy", &"wave", &"feel_shard", &"feel", &"fx", &"popup", &"ui",
		&"card_open", &"card_drain", &"other"]
	_check("⑥a 段序：十六段且顺序锁死（+移+火+跳+他+碎+开+消）",
		DebugStats.DIAG_STAGE_ORDER == order
			and DebugStats.DIAG_STAGE_ORDER.size() == 16,
		str(DebugStats.DIAG_STAGE_ORDER))
	_check("⑥b 标签：玩/移/火/碎/开/消/磁/感/特 全在位",
		str(DebugStats.DIAG_STAGE_TAGS.get(&"player", "")) == "玩"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"player_mv", "")) == "移"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"player_wp", "")) == "火"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"shard", "")) == "碎"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"card_open", "")) == "开"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"card_drain", "")) == "消"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"feel_shard", "")) == "磁"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"feel", "")) == "感"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"fx", "")) == "特"
			and DebugStats.DIAG_STAGE_TAGS.size() == 16, "")
	var pool := _xp_pool(_gl2)
	var host: Node = pool.bucket_host
	var c0 := _gl2.diag_counts()
	_check("⑥c 新鲜实例：bucket_xp=0 shards=0",
		int(c0[&"bucket_xp"]) == 0 and int(c0[&"shards"]) == 0, str(c0))
	var s_a := _spawn(_gl2, Vector2(300, 600), 4.0, 4.0)
	var s_b := _spawn(_gl2, Vector2(320, 620), 4.5, 4.0)
	_spawn(_gl2, Vector2(340, 640), 30.0, 4.0)
	var c1 := _gl2.diag_counts()
	_check("⑥d 读数：3 片 2 变体 → shards=3 bucket_xp=2",
		int(c1[&"shards"]) == 3 and int(c1[&"bucket_xp"]) == 2, str(c1))
	for i in range(4):
		_spawn(_gl2, Vector2(360 + 20 * i, 660), 4.2, 4.0)  # 同白 q1 变体（拾多桶少对读）
	var c2 := _gl2.diag_counts()
	_check("⑥e 合批对读：拾 7 而桶仍 2（同变体共桶）",
		int(c2[&"shards"]) == 7 and int(c2[&"bucket_xp"]) == 2, str(c2))
	_spawn(_gl2, Vector2(500, 700), 200.0, 4.0)
	var c3 := _gl2.diag_counts()
	_check("⑥f 彩档入桶：bucket_xp=3 且==host 子桶数",
		int(c3[&"bucket_xp"]) == 3 and int(host.get_child_count()) == 3, str(c3))
	s_a.force_magnet()
	var c4 := _gl2.diag_counts()
	_check("⑥g 磁片在场计数：is_magnet 真源（1/8）",
		int(c4[&"magnet_shards"]) == 1 and int(c4[&"shards"]) == 8, str(c4))
	_release_active(_gl2)
	var c5 := _gl2.diag_counts()
	_check("⑥h release 后：shards=0 桶单调保留 3",
		int(c5[&"shards"]) == 0 and int(c5[&"bucket_xp"]) == 3, str(c5))
	# 真实 diag 行（尾段格式：桶e+p+x 磁 拾 + 十一段标签）
	var ds: Node = (load("res://autoload/debug_stats.gd") as GDScript).new()
	var line := String(ds.call(&"_diag_format_line", _gl2, Time.get_ticks_msec()))
	ds.free()
	_check("⑥i diag 行尾段：桶0+0+3 磁0 拾0（e+p+x 三元 + 新键）",
		line.contains("桶0+0+3 磁0 拾0"), line.right(110))
	_check("⑥j diag 行：段标签 碎/开/消 在行内（探针关读 0）+ p%d ri 段" % Engine.physics_ticks_per_second,
		line.contains("碎0") and line.contains("开0") and line.contains("消0")
			and line.contains("p%d ri" % Engine.physics_ticks_per_second),
		line.right(110))
	print("      [info] diag行：%s" % line.right(150))


# ── ⑦ 拆键（player/shard 分立 + card 键归因） ────────────────────
func _test_7_stage_split_and_card_key() -> void:
	print("── ⑦ 拆键 ──")
	_gl2.stage_probe_enabled = true
	_gl2.state = GameConst.GameStatus.PLAYING
	_gl2._physics_process(DT)
	var probe: Dictionary = _gl2.stage_probe_us
	_check("⑦a PLAYING 帧：player/shard 两键分立（R216 刀②）",
		probe.has(&"player") and probe.has(&"shard"), str(probe.keys()))
	# R220 刀1：卡键拆分后普通玩帧在位的是 card_drain（溢出消化槽恒记账——评审#1 口径）
	_check("⑦b 普通玩帧卡消键在位（溢出消化槽恒记账）", probe.has(&"card_drain"), str(probe.keys()))
	# 负控制：无 deferred 时 _consume 零副作用零写键
	_gl2.stage_probe_us.clear()
	_gl2.call(&"_consume_deferred_level_open")
	_check("⑦c 负控制：无 deferred → 无 card_open 键、state 不变",
		not _gl2.stage_probe_us.has(&"card_open")
			and _gl2.state == GameConst.GameStatus.PLAYING, "")
	# 手动归因口：开窗成本入 card_open 键、ui 键零写 + peak 通道随动
	var lv0: int = _gl2.player.level
	_gl2.player.xp_need = 10.0
	_gl2.player.gain_xp(10.0)
	_gl2.stage_probe_us.clear()
	_gl2.call(&"_consume_deferred_level_open")
	var card_v: int = int(_gl2.stage_probe_us.get(&"card_open", -1))
	var ui_v: int = int(_gl2.stage_probe_us.get(&"ui", -1))
	_check("⑦d 开窗归「开」：card_open>0 且 ui 键零写入（归因分离）+ peak 随动",
		card_v > 0 and ui_v == -1
			and int(_gl2.stage_probe_us_peak.get(&"card_open", -1)) >= card_v,
		"card_open=%d ui=%d" % [card_v, ui_v])
	_check("⑦e 开窗生效：LEVEL_UP", _gl2.state == GameConst.GameStatus.LEVEL_UP, "")
	while _gl2.state == GameConst.GameStatus.LEVEL_UP:
		(_gl2.card_select_ui as CardSelectUI).choose(0)
	_check("⑦f 选卡收口：回 PLAYING + 解除暂停 + 等级 +1 零丢弃",
		_gl2.state == GameConst.GameStatus.PLAYING and not tree.paused
			and _gl2.player.level == lv0 + 1, "")
	# 产品路径：真帧尾消费开窗（⑧ 后帧尾）
	_gl2.player.xp_need = 5.0
	_gl2.player.gain_xp(5.0)
	_gl2._physics_process(DT)
	var probe2: Dictionary = _gl2.stage_probe_us
	_check("⑦g 产品帧尾消费：LEVEL_UP + card_open 键入账 + ui 段照常在帧内",
		_gl2.state == GameConst.GameStatus.LEVEL_UP and int(probe2.get(&"card_open", 0)) > 0
			and probe2.has(&"ui"), "keys=%s" % str(probe2.keys()))
	while _gl2.state == GameConst.GameStatus.LEVEL_UP:
		(_gl2.card_select_ui as CardSelectUI).choose(0)
	# 探针逐帧重建：开窗成本不残留（R220 拆键后 plain 帧无开窗动作 → card_open 键
	# 缺席=零残留强断言；溢出消化槽 card_drain 恒记账=原 ⑦b 口径）、player/shard 照常
	_gl2._physics_process(DT)
	var card_plain: int = int(_gl2.stage_probe_us.get(&"card_open", -1))
	_check("⑦h 逐帧重建：开窗成本零残留（plain 帧 card_open 缺席）+ 消化槽/player/shard 照常",
		card_plain == -1 and _gl2.stage_probe_us.has(&"card_drain")
			and _gl2.stage_probe_us.has(&"player") and _gl2.stage_probe_us.has(&"shard")
			and not _gl2.card_select_ui.is_open,
		"plain=%d keys=%s" % [card_plain, str(_gl2.stage_probe_us.keys())])
	# 带载探针：20 同变体碎片在场跑 3 帧（死亡堆形状 × 探针共存）
	var home := Vector2(660.0, 300.0)
	for i in range(20):
		var s := _spawn(_gl2, home, 4.0, 4.0)
		s.global_position = home
	var sh_ok := true
	for f in range(3):
		_gl2._physics_process(DT)
		if not (_gl2.stage_probe_us.has(&"player") and _gl2.stage_probe_us.has(&"shard")):
			sh_ok = false
	var shards_arr: Array = _gl2.get("active_shards")
	var all_white := true
	for s in shards_arr:
		if not (s as XpShard)._sprite.modulate.is_equal_approx(Color.WHITE):
			all_white = false
	_check("⑦i 20 片在场 3 帧：探针两键每帧在位 + 全片 modulate 白 + 零意外吸收",
		sh_ok and all_white and shards_arr.size() == 20,
		"n=%d" % shards_arr.size())
	_release_active(_gl2)
	_gl2.stage_probe_enabled = false


# ── ⑧ dwell（累计/清零/回菜单重计）+ boss 门重武装 + 18 变体入缓存 ─
func _test_8_dwell_gate_and_cache() -> void:
	print("── ⑧ dwell 与 boss 门 ──")
	# MENU 帧累计
	_gl2.state = GameConst.GameStatus.MENU
	_gl2.set("_menu_dwell_s", 0.0)
	_gl2._physics_process(DT)
	var d1: float = float(_gl2.get("_menu_dwell_s"))
	_check("⑧a MENU 帧累计：0→+δ", d1 > 0.0 and d1 < 1.0, "%.4f" % d1)
	# 非 MENU 帧清零（vc23 0:41 修复口径：头部清零）
	_gl2.set("_menu_dwell_s", 5.0)
	_gl2.state = GameConst.GameStatus.PLAYING
	_gl2._physics_process(DT)
	var d2: float = float(_gl2.get("_menu_dwell_s"))
	_check("⑧b PLAYING 帧清零：5.0→恰 0", d2 == 0.0, "%.6f" % d2)
	# 回菜单重计（从 0 起算，非旧值续走）
	_gl2.state = GameConst.GameStatus.MENU
	_gl2._physics_process(DT)
	var d3: float = float(_gl2.get("_menu_dwell_s"))
	_check("⑧c 回菜单重计：清零后重享累计（δ 内，非 5.0 续走）",
		d3 > 0.0 and d3 < 1.0, "%.4f" % d3)
	# boss 挂机门随 dwell=0 重新武装（回菜单即享 3s 缓冲的行为口径）
	# R222 Fix P 契约迁移：重项超预算折臂跳帧（跳帧帧零消化）——本组锁门/放行/清队
	# 语义，逐帧清占空余额隔离（占空行为由 r222_runrearm ② 承接）
	var q: Array = _gl2.get("_tex_prewarm_queue")
	var guard := 0
	while not q.is_empty() and guard < 200:
		var head := q[0] as Dictionary
		if int(head.get(&"op", 0)) == 0 and String(head.get(&"kind", &"")).begins_with("boss"):
			break
		_gl2.set("_menu_dwell_s", 0.0)                      # 模拟刚回菜单（dwell 恒小）
		_gl2.set("_tex_prewarm_skip", 0)
		_gl2._physics_process(DT)
		guard += 1
	var head_ok: bool = not q.is_empty() \
		and int((q[0] as Dictionary).get(&"op", 0)) == 0 \
		and String((q[0] as Dictionary).get(&"kind", &"")).begins_with("boss")
	_check("⑧d 消化至 boss 队首（非 boss 项 %d 帧清完）" % guard, head_ok and guard < 200,
		"guard=%d head=%s" % [guard, str(q[0]) if not q.is_empty() else "空"])
	if head_ok:
		var size0: int = q.size()
		_gl2.set("_menu_dwell_s", 0.0)
		_gl2.set("_tex_prewarm_skip", 0)
		_gl2._physics_process(DT)                           # dwell≈DT < 3 → 门扣住
		var held: bool = q.size() == size0 \
			and String((q[0] as Dictionary).get(&"kind", &"")).begins_with("boss")
		_check("⑧e 门武装：dwell<3 帧 boss 项不出队", held,
			"%d→%d" % [size0, q.size()])
		_gl2.set("_menu_dwell_s", 99.0)
		_gl2.set("_tex_prewarm_skip", 0)
		_gl2._physics_process(DT)                           # 放行
		_check("⑧f 放行：dwell≥3 帧 boss 项出队", q.size() == size0 - 1,
			"%d→%d" % [size0, q.size()])
	# 清队 + 18 星变体全量入缓存（预热闭环）
	_gl2.set("_menu_dwell_s", 99.0)
	var g2 := 0
	while not q.is_empty() and g2 < 400:
		_gl2.set("_tex_prewarm_skip", 0)                    # R222 Fix P：逐帧清臂
		_gl2._physics_process(DT)
		g2 += 1
	_check("⑧g 预热清队（含 boss 双面）", q.is_empty(), "guard=%d" % g2)
	var cache: Dictionary = TextureFactory._cache
	var missing: Array[String] = []
	for t in 4:
		for a in 3:
			var key := "star_44_" + _tier_color(t, 0.5 + 0.25 * a).to_html()
			if not cache.has(key):
				missing.append(key)
	for h in 6:
		var rkey := "star_44_" + Color.from_hsv(float(h) / 6.0, 0.7, 1.0).to_html()
		if not cache.has(rkey):
			missing.append(rkey)
	_check("⑧h 清队后 18 星变体全量在缓存（W1 首批死亡前烤好）",
		missing.is_empty(), "缺 %d 项：%s" % [missing.size(), "、".join(missing.slice(0, 3))])
	_gl2.state = GameConst.GameStatus.MENU

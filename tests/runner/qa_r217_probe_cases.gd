# tests/runner/qa_r217_probe_cases.gd
# R217 QA 独立探针（qa 系交叉验证口——r217_batchfix 之外的第三方验证）：
#   ① 批组上限红线（本刀核心）：同帧同状态组合敌 self_modulate/modulate 两两相等——
#      120 同 kind 敌批量驱动：点燃相位铺满断批分组恰 2 档、狂暴常驻恰 1 组（vc24
#      逐敌收敛链根因回归锁）、混合 4 状态组组内同色全局 ≤4 组、满载闪白同档恰 1 组
#   ② 档量化边界：点燃 sin 过零翻转只取两值（0.46/0.30）、感电方波叠加两值（0.14/0）、
#      吟唱进度 0.49/0.51 跨档、闪紫前摇两档、狂暴 _red_tint_left 跨档+倒计时归属、
#      闪白 0.49/0.51 两档、渐显 alpha 四档网格全程
#   ③ _tick_visual 全路径（_apply_body_tint 每 tick 调用）+ _tick_status_fx 30Hz 门内
#      幂等（同帧两次调用同值）+ _tick_status_tint 签名转发 + 真 tick 链染色落位 +
#      elemental=null 摘除回落 + R213 C案双通道互复位不回归 + 池归还复位
#   ④ 刀C 拆键：PLAYING 帧 player_mv/player_wp 分立且 ≥0、段内包含关系（mv+wp ≤ 玩）、
#      reset 清零、_dead 早退路径累加器保持 0（基准在早退前）、十五段契约（R218 同步）
#   ⑤ 刀B 遥测：tinted_enemies 随闪白敌进出计数、popups 随跳字池 live 计数、
#      diag 行尾段 磁N 拾N 跳N 断N + 段标签 移/火 在行
# 坑位纪律：敌池经 _gl.pools[&"enemy"]（局部变量坑）；elemental 初始 null（测试自挂
# ElementalState.new()）；fullload_override 1 强制满载分支；直连池敌不在 spawner.active
#（diag 遍历源——手动 append/erase）；勿二次 release；色断言容差 0.004。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const TOL := 0.004                              # 像素/色断言容差（纪律 ≥0.004）
const BATCH_N := 120                            # 满载深谷敌数口径（敌80-120 上沿）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null                        # 组①②③⑤ 用实例
var _gl2: GameLoop = null                       # 组④ 用实例（探针/玩家隔离）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261002)
	_boot(&"_gl")
	await tree.process_frame
	await tree.process_frame
	_test_1_batch_cap_redline()
	_test_2_quant_edges()
	_test_3_visual_path_and_regression()
	_test_5_telemetry_and_diag_line()
	_teardown(&"_gl")
	_boot(&"_gl2")
	_test_4_player_split_probe()
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
	gl.name = "R217QA%s" % p_slot
	tree.get_root().add_child(gl)
	set(p_slot, gl)
	gl.state = GameConst.GameStatus.MENU
	gl.current_map_id = MapTable.FIRST_MAP_ID
	gl.start_run()
	gl.state = GameConst.GameStatus.MENU
	gl.player.global_position = Vector2(360.0, 900.0)


func _teardown(p_slot: String) -> void:
	tree.paused = false
	Enemy.fullload_override = -1
	RunSave.clear()
	var gl: GameLoop = get(p_slot)
	if gl != null:
		gl.free()
		set(p_slot, null)


# ── 共用小件 ──────────────────────────────────────────────────────
func _fixture_enemy(p_id: StringName) -> EnemyData:
	var d := EnemyData.new()
	d.id = p_id
	d.display_name = String(p_id)
	d.hp_base = 100.0
	d.spd_base = 0.0                          # 定桩不位移（batch 断言只看染色）
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	return d


func _spawn_enemy(p_id: StringName, p_gl: GameLoop = null) -> Enemy:
	var loop := p_gl if p_gl != null else _gl
	var pool := loop.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	e.spawn(_fixture_enemy(p_id), 1, 0)
	e._fade_left = 0.0                        # 跳过入场渐显（染色组独立测）
	e.modulate.a = 1.0
	return e


func _release_enemy(p_e: Enemy, p_gl: GameLoop = null) -> void:
	var loop := p_gl if p_gl != null else _gl
	(loop.pools[&"enemy"] as EnemyPool).release(p_e)


func _cclose(p_a: Color, p_b: Color) -> bool:
	# 组件级容差比较（纪律：容差 0.004）
	return absf(p_a.r - p_b.r) <= TOL and absf(p_a.g - p_b.g) <= TOL \
		and absf(p_a.b - p_b.b) <= TOL and absf(p_a.a - p_b.a) <= TOL


func _distinct_colors(p_colors: Array, p_key_of: Callable) -> int:
	# 容差去重分组数（贪心：与已有代表值两两容差内归组——断批分组数口径）
	var reps: Array[Color] = []
	for c in p_colors:
		var col: Color = p_key_of.call(c)
		var found := false
		for r in reps:
			if _cclose(col, r):
				found = true
				break
		if not found:
			reps.append(col)
	return reps.size()


func _burn_tier_hi() -> Color:
	return Color.WHITE.lerp(PopPalette.ENEMY.lerp(PopPalette.XP, 0.45), 0.46)


func _burn_tier_lo() -> Color:
	return Color.WHITE.lerp(PopPalette.ENEMY.lerp(PopPalette.XP, 0.45), 0.30)


func _attach_burn(p_e: Enemy, p_anim_t: float) -> void:
	if p_e.elemental == null:
		p_e.elemental = ElementalState.new()
	p_e.elemental.burn_timer = 2.0
	p_e._anim_t = p_anim_t


# ── ① 批组上限红线（120 同 kind 敌批量驱动） ─────────────────────
func _test_1_batch_cap_redline() -> void:
	print("── ① 批组上限红线 ──")
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var cap := GameConfig.get_pool_capacity(&"enemy")
	var n: int = mini(BATCH_N, cap - int(pool.stats()["live"]))
	_check("①pre 池容量夹具：可取 %d 敌（容量 %d）" % [n, cap], n >= 100,
		"n=%d cap=%d live=%d" % [n, cap, int(pool.stats()["live"])])

	# 1a 同帧同相位点燃 ×N：真 tick 链 → 两两相等（同桶同批前提）
	var arr: Array[Enemy] = []
	for i in range(n):
		var e := _spawn_enemy(StringName("E_QA217_BA%d" % i))
		_attach_burn(e, 0.3)                  # 全员同相位
		arr.append(e)
	for e in arr:
		e.tick(DT)
	var tints: Array[Color] = []
	for e in arr:
		tints.append(e._sprite.self_modulate)
	var all_eq := true
	for c in tints:
		if not _cclose(c, tints[0]):
			all_eq = false
			break
	_check("①a 点燃同相位 ×%d：self_modulate 两两相等（恰 1 组）" % n,
		all_eq and _distinct_colors(tints, func(c: Color) -> Color: return c) == 1,
		"组数=%d" % _distinct_colors(tints, func(c: Color) -> Color: return c))
	_check("①a2 全员断批可观测（点燃=非白）", arr.all(func(e: Enemy) -> bool:
		return e.is_batch_broken()), "")

	# 1b 相位铺满整周期 ×N：断批分组数恰 ≤ 档组合上限 2（sin≥0/sin<0 两档）
	for i in range(n):
		arr[i]._anim_t = 0.3 + float(i) * PI / 6.2    # 铺满 sin(_anim_t*6.2) 正负半周
		arr[i].call(&"_apply_body_tint", DT)
	tints.clear()
	for e in arr:
		tints.append(e._sprite.self_modulate)
	var groups := _distinct_colors(tints, func(c: Color) -> Color: return c)
	var both_tiers := false
	for c in tints:
		if _cclose(c, _burn_tier_hi()):
			for c2 in tints:
				if _cclose(c2, _burn_tier_lo()):
					both_tiers = true
	_check("①b 点燃相位铺满 ×%d：断批分组数=2（≤档组合上限，双档齐现）" % n,
		groups == 2 and both_tiers, "组数=%d 双档=%s" % [groups, str(both_tiers)])
	for e in arr:
		_release_enemy(e)
	arr.clear()

	# 1c 狂暴常驻 ×N：任意相位恰 1 组（vc24 根因：原逐帧 lerp 收敛链逐敌唯一值）
	for i in range(n):
		var e := _spawn_enemy(StringName("E_QA217_RG%d" % i))
		e.set("_enrage_done", true)
		e.set("_red_tint_left", 0.0)
		e._anim_t = 0.7 + float(i) * 0.977    # 相位全异
		arr.append(e)
	tints.clear()
	for e in arr:
		e.call(&"_apply_body_tint", DT)
		tints.append(e._sprite.self_modulate)
	var rg_groups := _distinct_colors(tints, func(c: Color) -> Color: return c)
	_check("①c 狂暴常驻 ×%d：断批分组数=1（0.18 档绝对值——逐敌收敛链已根除）" % n,
		rg_groups == 1 and _cclose(tints[0],
			Color.WHITE.lerp(Color(1.0, 0.25, 0.25), 0.18)),
		"组数=%d" % rg_groups)
	for e in arr:
		_release_enemy(e)
	arr.clear()

	# 1d 混合 4 状态组（洁净/点燃/冻结/狂暴常驻）× 各 n/4：组内同色、全局 ≤4 组
	var g := n / 4
	for i in range(n):
		var e := _spawn_enemy(StringName("E_QA217_MX%d" % i))
		match i / g:
			0:
				pass                              # 洁净
			1:
				_attach_burn(e, 0.3)
			2:
				if e.elemental == null:
					e.elemental = ElementalState.new()
				e.elemental.freeze_timer = 2.0
				e._anim_t = 0.3
			_:
				e.set("_enrage_done", true)
				e.set("_red_tint_left", 0.0)
				e._anim_t = 0.3
		e.call(&"_apply_body_tint", DT)
		arr.append(e)
	tints.clear()
	for e in arr:
		tints.append(e._sprite.self_modulate)
	var mix_groups := _distinct_colors(tints, func(c: Color) -> Color: return c)
	var grp_ok := true
	for i in range(n):
		if not _cclose(tints[i], tints[(i / g) * g]):
			grp_ok = false
	_check("①d 混合 4 组 ×%d：全局断批分组 ≤4（=档组合上限）且组内两两相等" % n,
		mix_groups <= 4 and grp_ok, "组数=%d 组内齐=%s" % [mix_groups, str(grp_ok)])
	for e in arr:
		_release_enemy(e)
	arr.clear()

	# 1e 满载闪白同档 ×N：白变体贴图恰 1 组（同档同贴图同桶=同批）+ 混档 ≤3 组
	#（R237 闪白批化契约迁移：满载闪白 modulate 白乘 → 白变体贴图，断言改读贴图通道）
	Enemy.fullload_override = 1
	for i in range(n):
		var e := _spawn_enemy(StringName("E_QA217_FL%d" % i))
		arr.append(e)
	for e in arr:
		e.call(&"_apply_flash", randf_range(0.55, 1.0))   # 全落强闪档
	var tex_set: Dictionary = {}
	for e in arr:
		tex_set[e._sprite.texture] = true
	_check("①e 满载强闪 ×%d：贴图恰 1 组==强白变体 且 modulate 全白（R237 契约迁移）" % n,
		tex_set.size() == 1
			and tex_set.has(TextureFactory.enemy_tex_flash(&"grunt", false, true))
			and absf(arr[0]._sprite.modulate.r - 1.0) <= TOL,
		"组数=%d mod=%.3f" % [tex_set.size(), arr[0]._sprite.modulate.r])
	for i in range(n):
		arr[i].call(&"_apply_flash", float(i % 4) * 0.3)  # {0,0.3,0.6,0.9} → 弱/强/零三值
	tex_set.clear()
	for e in arr:
		tex_set[e._sprite.texture] = true
	_check("①e2 混档闪白 ×%d：贴图分组恰 3（本体 + 弱变体 + 强变体——R237 契约迁移，档差在贴图通道分明）" % n,
		tex_set.size() == 3
			and tex_set.has(TextureFactory.enemy_tex(&"grunt"))
			and tex_set.has(TextureFactory.enemy_tex_flash(&"grunt", false, false))
			and tex_set.has(TextureFactory.enemy_tex_flash(&"grunt", false, true)),
		"组数=%d" % tex_set.size())
	Enemy.fullload_override = -1
	for e in arr:
		_release_enemy(e)
	arr.clear()


# ── ② 档量化边界 ─────────────────────────────────────────────────
func _test_2_quant_edges() -> void:
	print("── ② 档量化边界 ──")
	# 2a 点燃 sin 过零翻转：过零点两侧只取两值（0.46/0.30）
	var e := _spawn_enemy(&"E_QA217_Q1")
	_attach_burn(e, (PI - 0.02) / 6.2)        # sin 微正 → 高档
	e.call(&"_apply_body_tint", DT)
	var hi: Color = e._sprite.self_modulate
	_attach_burn(e, (PI + 0.02) / 6.2)        # sin 微负 → 低档
	e.call(&"_apply_body_tint", DT)
	var lo: Color = e._sprite.self_modulate
	_check("②a 点燃过零两侧：恰两值 0.46/0.30（插值锚=ENEMY.lerp(XP,0.45)）",
		_cclose(hi, _burn_tier_hi()) and _cclose(lo, _burn_tier_lo())
			and not _cclose(hi, lo),
		"hi=%s lo=%s" % [str(hi), str(lo)])
	# 2b 感电方波叠加：固定点燃高档相位、扫 46rad 相位 → 叠加后全场 ≤2 值
	_attach_burn(e, 0.1)                      # sin(0.62)>0 高档；sin(4.6)<0 → 方波 0
	if e.elemental.gauges[GameConst.Element.LTG] <= 0.0:
		e.elemental.gauges[GameConst.Element.LTG] = 60.0
	e.call(&"_apply_body_tint", DT)
	var s0: Color = e._sprite.self_modulate
	_attach_burn(e, 0.2)                      # sin(1.24)>0 高档；sin(9.2)>0 → 方波 0.14
	e.call(&"_apply_body_tint", DT)
	var s1: Color = e._sprite.self_modulate
	_check("②b 感电方波两值：0 档=点燃本色 / 0.14 档=向白 lerp（互异且各对位）",
		_cclose(s0, _burn_tier_hi())
			and _cclose(s1, _burn_tier_hi().lerp(Color.WHITE, 0.14))
			and not _cclose(s0, s1),
		"s0=%s s1=%s" % [str(s0), str(s1)])
	# 半周期扫频（点燃高档锁定）：方波两符号各自出现 → 恰 2 值
	var sweep: Array[Color] = []
	for i in range(40):
		_attach_burn(e, 0.05 + float(i) * (PI / 6.2 - 0.1) / 40.0)   # 恒在 sin 正半周内
		e.call(&"_apply_body_tint", DT)
		sweep.append(e._sprite.self_modulate)
	var has_plain := false
	var has_shock := false
	var all_known := true
	for c in sweep:
		if _cclose(c, _burn_tier_hi()):
			has_plain = true
		elif _cclose(c, _burn_tier_hi().lerp(Color.WHITE, 0.14)):
			has_shock = true
		else:
			all_known = false
	_check("②b2 感电叠加半周期扫频：点燃高档锁定下方波恰 2 值（0/0.14 双档齐现）",
		_distinct_colors(sweep, func(c: Color) -> Color: return c) == 2
			and has_plain and has_shock and all_known,
		"组数=%d plain=%s shock=%s known=%s" % [
			_distinct_colors(sweep, func(c: Color) -> Color: return c),
			str(has_plain), str(has_shock), str(all_known)])
	# 全周期扫频：点燃 2 档 × 方波 2 值 = 档组合上限 4（断批分组数 ≤ 组合上限）
	sweep.clear()
	for i in range(40):
		_attach_burn(e, 0.05 + float(i) * (TAU / 6.2) / 40.0)
		e.call(&"_apply_body_tint", DT)
		sweep.append(e._sprite.self_modulate)
	_check("②b3 感电叠加全周期扫频：全场 ≤4（=点燃档×方波值组合上限）",
		_distinct_colors(sweep, func(c: Color) -> Color: return c) <= 4,
		"组数=%d" % _distinct_colors(sweep, func(c: Color) -> Color: return c))
	e.elemental.gauges[GameConst.Element.LTG] = 0.0

	# 2c 吟唱进度 0.49/0.51 跨档（0.45/0.85）
	e.elemental = null
	e.set("_cast_glow", 0.49)
	e.call(&"_apply_body_tint", DT)
	var c_lo: Color = e._sprite.self_modulate
	e.set("_cast_glow", 0.51)
	e.call(&"_apply_body_tint", DT)
	var c_hi: Color = e._sprite.self_modulate
	var exp_lo := Color.WHITE.lerp(Color(1.0, 0.36, 0.36), 0.45)
	var exp_hi := Color.WHITE.lerp(Color(1.0, 0.36, 0.36), 0.85)
	_check("②c 吟唱跨档：0.49→0.45 档 / 0.51→0.85 档（互异各对位）",
		_cclose(c_lo, exp_lo) and _cclose(c_hi, exp_hi) and not _cclose(c_lo, c_hi),
		"lo=%s hi=%s" % [str(c_lo), str(c_hi)])
	e.set("_cast_glow", 0.2)
	e.call(&"_apply_body_tint", DT)
	_check("②c2 吟唱同档：0.2 与 0.49 同色（低档内连续值已并入一档）",
		_cclose(e._sprite.self_modulate, c_lo), "")
	e.set("_cast_glow", 0.0)
	e.call(&"_apply_body_tint", DT)
	_check("②c3 吟唱归零：回纯白", _cclose(e._sprite.self_modulate, Color.WHITE), "")

	# 2d 闪紫前摇两档（BLINK 读条 state=1，glow=1−left/prep）
	e.set("_blink_state", 1)
	e.set("_blink_prep", 0.35)
	e.set("_blink_left", 0.1785)              # glow 0.49 → 低档
	e.call(&"_apply_body_tint", DT)
	var b_lo: Color = e._sprite.self_modulate
	e.set("_blink_left", 0.1715)              # glow 0.51 → 高档
	e.call(&"_apply_body_tint", DT)
	var b_hi: Color = e._sprite.self_modulate
	_check("②d 闪紫两档：glow0.49→0.4 / glow0.51→0.8（互异各对位）",
		_cclose(b_lo, Color.WHITE.lerp(Color(0.7, 0.5, 1.0), 0.4))
			and _cclose(b_hi, Color.WHITE.lerp(Color(0.7, 0.5, 1.0), 0.8))
			and not _cclose(b_lo, b_hi),
		"lo=%s hi=%s" % [str(b_lo), str(b_hi)])
	e.set("_blink_state", 0)
	e.call(&"_apply_body_tint", DT)
	_check("②d2 读条结束回白", _cclose(e._sprite.self_modulate, Color.WHITE), "")

	# 2e 狂暴 _red_tint_left 跨档 + 倒计时随 _apply_body_tint 走
	e.set("_enrage_done", true)
	e.set("_red_tint_left", 1.0)
	e.call(&"_apply_body_tint", DT)
	var r_hi: Color = e._sprite.self_modulate
	_check("②e 狂暴入场窗：红染 1.0 → 0.45 档且倒计时随本函数递减",
		_cclose(r_hi, Color.WHITE.lerp(Color(1.0, 0.25, 0.25), 0.45))
			and absf(e._red_tint_left - (1.0 - DT)) <= 0.0001,
		"left=%.4f" % e._red_tint_left)
	e.set("_red_tint_left", 0.005)
	e.call(&"_apply_body_tint", DT)
	var r_lo: Color = e._sprite.self_modulate
	_check("②e2 跨档：倒计时尽 → 常驻 0.18 档（互异）",
		_cclose(r_lo, Color.WHITE.lerp(Color(1.0, 0.25, 0.25), 0.18))
			and not _cclose(r_hi, r_lo), "")
	e.set("_enrage_done", false)
	e.set("_red_tint_left", 1.0)
	e.call(&"_apply_body_tint", DT)
	_check("②e3 未狂暴：无红染回白且倒计时不动（递减归属 _enrage_done 门内）",
		_cclose(e._sprite.self_modulate, Color.WHITE) and e._red_tint_left == 1.0, "")
	e.set("_red_tint_left", 0.0)

	# 2f 冻结/寒滞固定系数：任意相位两敌同色（0.88/0.55）
	var f2 := _spawn_enemy(&"E_QA217_Q2")
	e._anim_t = 0.7
	f2._anim_t = 13.7
	if e.elemental == null:
		e.elemental = ElementalState.new()
	if f2.elemental == null:
		f2.elemental = ElementalState.new()
	e.elemental.burn_timer = 0.0
	f2.elemental.burn_timer = 0.0
	e.elemental.freeze_timer = 2.0
	f2.elemental.freeze_timer = 2.0
	e.call(&"_apply_body_tint", DT)
	f2.call(&"_apply_body_tint", DT)
	var exp_fz := Color.WHITE.lerp(PopPalette.PLAYER.lerp(Color.WHITE, 0.6), 0.88)
	_check("②f 冻结：任意相位同色 =WHITE.lerp(PLAYER.lerp(W,0.6),0.88)",
		_cclose(e._sprite.self_modulate, exp_fz)
			and _cclose(f2._sprite.self_modulate, exp_fz), "")
	e.elemental.freeze_timer = 0.0
	f2.elemental.freeze_timer = 0.0
	e.elemental.chill_timer = 2.0
	f2.elemental.chill_timer = 2.0
	e.call(&"_apply_body_tint", DT)
	f2.call(&"_apply_body_tint", DT)
	var exp_ch := Color.WHITE.lerp(
		PopPalette.ELEMENT_COLORS[GameConst.Element.ICE].lerp(Color.WHITE, 0.45), 0.55)
	_check("②f2 寒滞：任意相位同色 =WHITE.lerp(ICE.lerp(W,0.45),0.55)",
		_cclose(e._sprite.self_modulate, exp_ch)
			and _cclose(f2._sprite.self_modulate, exp_ch), "")
	_release_enemy(e)
	_release_enemy(f2)

	# 2g 闪白 0.49/0.51 档界（满载分支——R237 闪白批化契约迁移：两档=强弱白变体贴图）
	Enemy.fullload_override = 1
	var g1 := _spawn_enemy(&"E_QA217_Q3")
	g1.call(&"_apply_flash", 0.49)
	var t_lo: Texture2D = g1._sprite.texture
	g1.call(&"_apply_flash", 0.51)
	var t_hi: Texture2D = g1._sprite.texture
	g1.call(&"_apply_flash", 0.5)
	var t_mid: Texture2D = g1._sprite.texture
	_check("②g 闪白档界：0.49→弱白变体 / 0.5 与 0.51→强白变体（两档界点归强档——R237 契约迁移）",
		t_lo == TextureFactory.enemy_tex_flash(&"grunt", false, false)
			and t_hi == TextureFactory.enemy_tex_flash(&"grunt", false, true)
			and t_mid == t_hi,
		"lo=%s hi=%s mid=%s" % [str(t_lo == TextureFactory.enemy_tex_flash(&"grunt", false, false)),
			str(t_hi == TextureFactory.enemy_tex_flash(&"grunt", false, true)), str(t_mid == t_hi)])
	Enemy.fullload_override = -1
	_release_enemy(g1)

	# 2h 渐显 alpha 四档网格全程
	var f3 := _spawn_enemy(&"E_QA217_Q4")
	var fls: Array[float] = [0.12, 0.09, 0.06, 0.03]
	var grid := [0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0]
	var grid_ok := true
	var got := ""
	var seen: Array[float] = []
	for i in range(fls.size()):
		f3._fade_left = fls[i]
		f3.tick(DT)
		var a: float = f3.modulate.a
		if absf(a - float(grid[i])) > TOL:
			grid_ok = false
			got += "fl=%.3f a=%.4f " % [fls[i], a]
		if not seen.has(a):
			seen.append(a)
	_check("②h 渐显四档网格：_fade_left 全程 α 恒落 {0,1/3,2/3,1}（四档齐现）",
		grid_ok and seen.size() == 4, "seen=%d %s" % [seen.size(), got])
	_release_enemy(f3)


# ── ③ _tick_visual 全路径 + 门内幂等 + 签名转发 + 双通道互复位 ──
func _test_3_visual_path_and_regression() -> void:
	print("── ③ 视觉路径与回归 ──")
	# 3a _tick_visual 每 tick 调 _apply_body_tint：真 tick 链染色落位
	var a := _spawn_enemy(&"E_QA217_P1")
	_attach_burn(a, 0.3)
	a.tick(DT)
	var tint_a: Color = a._sprite.self_modulate
	_check("③a 真 tick 链：burn 敌 1 帧后染色落位（非白且=高档锚值）",
		_cclose(tint_a, _burn_tier_hi()), "tint=%s" % str(tint_a))
	# 3b _tick_status_fx 30Hz 门内幂等：同帧两次调用同值
	a.call(&"_tick_status_fx", DT)
	var t1: Color = a._sprite.self_modulate
	a.call(&"_tick_status_fx", DT)
	var t2: Color = a._sprite.self_modulate
	a.call(&"_apply_body_tint", DT)
	var t3: Color = a._sprite.self_modulate
	_check("③b 30Hz 门内幂等：同帧两次 _tick_status_fx + 显式重算三值全等",
		_cclose(t1, t2) and _cclose(t2, t3), "%s/%s/%s" % [str(t1), str(t2), str(t3)])
	# 3c _tick_status_tint 签名转发：等价直接 _apply_body_tint
	var b := _spawn_enemy(&"E_QA217_P2")
	_attach_burn(b, 0.3)
	b.call(&"_tick_status_tint", true, false, false, false)
	_check("③c 签名转发：_tick_status_tint(burn) ≡ _apply_body_tint（唯一写点不改值）",
		_cclose(b._sprite.self_modulate, tint_a),
		"%s vs %s" % [str(b._sprite.self_modulate), str(tint_a)])
	# 3d 连续 tick 数帧无错落 + elemental 摘除（null 分支）回落纯白
	var stuck := true
	for i in range(8):
		a.tick(DT)
		var c := a._sprite.self_modulate
		if not (_cclose(c, _burn_tier_hi()) or _cclose(c, _burn_tier_lo())):
			stuck = false
	_check("③d 8 帧 tick 链：染色恒落两档内（无漂移无错落）", stuck, "")
	a.elemental = null                        # 摘除（ElementalSystem 死亡/反应清理同口径）
	a.tick(DT)
	_check("③d2 elemental=null：下一帧重算回纯白 + 断批观测回落",
		_cclose(a._sprite.self_modulate, Color.WHITE) and not a.is_batch_broken(),
		"tint=%s" % str(a._sprite.self_modulate))
	_release_enemy(a)
	_release_enemy(b)

	# 3e R213 C案双通道互复位不回归
	Enemy.fullload_override = 1
	var c1 := _spawn_enemy(&"E_QA217_C1")
	c1.call(&"_apply_flash", 1.0)             # 门开期受击 → 白乘 2.4（材质摘）
	Enemy.fullload_override = -1              # 门回落
	c1.call(&"_apply_flash", 0.0)             # 非 fullload 归零路径
	_check("③e C案门回落：满载白乘残留 → 归零路径复位纯白（QA-R213-001 口径）",
		_cclose(c1._sprite.modulate, Color.WHITE)
			and c1._sprite.material == null, "")
	var c2 := _spawn_enemy(&"E_QA217_C2")
	c2.call(&"_apply_flash", 1.0)             # 非 fullload：挂材质
	var mat_attached: bool = c2._sprite.material == c2._material
	Enemy.fullload_override = 1               # 门再开
	c2.call(&"_apply_flash", 0.0)             # fullload 归零路径
	_check("③e2 门再开：shader 材质摘除 + 白乘通道复位纯白（反向互复位）",
		mat_attached and c2._sprite.material == null
			and _cclose(c2._sprite.modulate, Color.WHITE), "")
	# 门开期受击后直接归还（_reset_state → _apply_flash(0.0) 路径）→ 复取无残留
	var c3 := _spawn_enemy(&"E_QA217_C3")
	c3.call(&"_apply_flash", 1.0)
	Enemy.fullload_override = -1
	_release_enemy(c3)
	_check("③e3 池归还复位：modulate/self_modulate/根 α 全回净（复用安全）",
		_cclose(c3._sprite.modulate, Color.WHITE)
			and _cclose(c3._sprite.self_modulate, Color.WHITE)
			and absf(c3.modulate.a - 1.0) <= TOL
			and not c3.is_batch_broken(), "")
	var c3b: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire() as Enemy
	_check("③e4 复取同实例且首帧前无残留", c3b == c3
		and _cclose(c3b._sprite.modulate, Color.WHITE), "")
	c3b.spawn(_fixture_enemy(&"E_QA217_C3R"), 1, 0)
	_release_enemy(c3b)


# ── ④ 刀C 拆键（player_mv/player_wp） ───────────────────────────
func _test_4_player_split_probe() -> void:
	print("── ④ player 拆键 ──")
	_gl2.stage_probe_enabled = true
	_gl2.state = GameConst.GameStatus.PLAYING
	_gl2._physics_process(DT)
	var probe: Dictionary = _gl2.stage_probe_us
	var mv: int = int(probe.get(&"player_mv", -1))
	var wp: int = int(probe.get(&"player_wp", -1))
	var pl: int = int(probe.get(&"player", -1))
	_check("④a PLAYING 帧：player_mv/player_wp 两键分立在位且 ≥0",
		probe.has(&"player_mv") and probe.has(&"player_wp") and mv >= 0 and wp >= 0,
		"mv=%d wp=%d" % [mv, wp])
	_check("④b 段内包含：移+火 ≤ 玩段全量（拆键不虚增）",
		pl >= 0 and mv + wp <= pl, "玩=%d 移=%d 火=%d" % [pl, mv, wp])
	_check("④c 移段实耗：真帧 >0（增益节拍+移动段有实工作量）", mv > 0, "mv=%d" % mv)
	# reset 清零
	Player.reset_stage_probe()
	_check("④d reset 清零：静态累加器双归零",
		Player.probe_pre_us == 0 and Player.probe_weapons_us == 0, "")
	# _dead 早退：基准在早退前 → 累加器保持 0 合法（不炸）
	_gl2.player.set("_dead", true)
	_gl2.player.tick(DT, Vector2.ZERO)
	_check("④e _dead 早退：tick 直返不炸且累加器保持 0",
		Player.probe_pre_us == 0 and Player.probe_weapons_us == 0, "")
	_gl2.player.set("_dead", false)
	# 静态累加语义：连续两次 tick 不 reset 单调不减且 >0
	_gl2.player.tick(DT, Vector2.ZERO)
	var t1: int = Player.probe_pre_us
	_gl2.player.tick(DT, Vector2.ZERO)
	var t2: int = Player.probe_pre_us
	_check("④f 累加语义：不 reset 连续 tick 单调不减（t2≥t1>0）", t2 >= t1 and t1 > 0,
		"t1=%d t2=%d" % [t1, t2])
	# 十六段契约（R220 刀1：card 拆 card_open/card_drain）
	var order: Array[StringName] = [&"player", &"player_mv", &"player_wp", &"shard",
		&"grid_rebuild", &"grid_projectile", &"enemy", &"wave", &"feel_shard",
		&"feel", &"fx", &"popup", &"ui", &"card_open", &"card_drain", &"other"]
	_check("④g 十六段契约：段序锁死 + 移/火标签在位",
		DebugStats.DIAG_STAGE_ORDER == order and DebugStats.DIAG_STAGE_ORDER.size() == 16
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"player_mv", "")) == "移"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"player_wp", "")) == "火",
		str(DebugStats.DIAG_STAGE_ORDER))
	_gl2.stage_probe_enabled = false


# ── ⑤ 刀B 遥测 + diag 行尾段 ─────────────────────────────────────
func _test_5_telemetry_and_diag_line() -> void:
	print("── ⑤ 遥测与 diag 行 ──")
	var counts: Dictionary = _gl.diag_counts()
	_check("⑤a diag_counts 新键：tinted_enemies/popups 在位",
		counts.has(&"tinted_enemies") and counts.has(&"popups"), str(counts.keys()))
	# 5b 断N 随闪白敌进出（直连池敌手动挂/摘活跃表）
	var base_tint: int = int(counts[&"tinted_enemies"])
	Enemy.fullload_override = 1
	var e := _spawn_enemy(&"E_QA217_T1")
	e.call(&"_apply_flash", 1.0)
	_gl.spawner.active.append(e)
	var in_cnt: int = int(_gl.diag_counts()[&"tinted_enemies"])
	e.call(&"_apply_flash", 0.0)
	var out_cnt: int = int(_gl.diag_counts()[&"tinted_enemies"])
	_gl.spawner.active.erase(e)
	Enemy.fullload_override = -1
	_release_enemy(e)
	_check("⑤b 断N 进出：闪白敌在场不增断N（贴图桶化 modulate 恒白——R237 闪白批化契约迁移）/ 归零后保持基线（is_batch_broken 直读）",
		in_cnt == base_tint and out_cnt == base_tint,
		"base=%d in=%d out=%d" % [base_tint, in_cnt, out_cnt])
	# 5c 跳N 随跳字池 live 计数
	var pm: PopupManager = _gl.popup_manager
	var numbers_prev: bool = bool(Meta.settings("damage_numbers_on"))
	var quality_prev: int = int(Meta.settings("fx_quality"))
	Meta.set_setting("damage_numbers_on", true)
	Meta.set_setting("fx_quality", 2)
	pm.clear_all()
	var base_pop: int = int(_gl.diag_counts()[&"popups"])
	var r := DamageResult.new()
	r.final_value = 6.0
	r.target_uid = 21701
	r.pos = Vector2(100.0, 200.0)
	r.popup_style = GameConst.PopupStyle.NORMAL
	pm.on_damage_resolved(r)
	var live: int = int((_gl.pools[&"popup"] as ObjectPool).stats()["live"])
	var pop_in: int = int(_gl.diag_counts()[&"popups"])
	pm.clear_all()
	var pop_out: int = int(_gl.diag_counts()[&"popups"])
	_check("⑤c 跳N 进出：起字后 popups=池 live+1 / clear_all 后回 0",
		pop_in == base_pop + 1 and pop_in == live and pop_out == 0
			and int((_gl.pools[&"popup"] as ObjectPool).stats()["live"]) == 0,
		"base=%d in=%d live=%d out=%d" % [base_pop, pop_in, live, pop_out])
	# 5d diag 行尾段：真实行含 磁N 拾N 跳N 断N + 段标签 移/火
	Enemy.fullload_override = 1
	var e2 := _spawn_enemy(&"E_QA217_T2")
	e2.call(&"_apply_flash", 1.0)
	_gl.spawner.active.append(e2)
	Meta.set_setting("damage_numbers_on", true)
	pm.clear_all()
	pm.on_damage_resolved(r)
	var c_now: Dictionary = _gl.diag_counts()
	_gl.stage_probe_us = {}                   # 探针关口径（段读 0）
	var ds: Node = (load("res://autoload/debug_stats.gd") as GDScript).new()
	var line := String(ds.call(&"_diag_format_line", _gl, Time.get_ticks_msec()))
	ds.free()
	var tail := "磁%d 拾%d 跳%d 断%d" % [int(c_now[&"magnet_shards"]),
		int(c_now[&"shards"]), int(c_now[&"popups"]), int(c_now[&"tinted_enemies"])]
	_check("⑤d diag 行尾段：真实行含「%s」（跳N/断N 与 diag_counts 同源）" % tail,
		line.contains(tail), line.right(120))
	_check("⑤d2 diag 行段标签：移/火 在行内（R220 后十六段拼行）",
		line.contains("移0 火0"), line.right(120))
	print("      [info] diag行：%s" % line.right(150))
	pm.clear_all()
	_gl.spawner.active.erase(e2)
	Enemy.fullload_override = -1
	_release_enemy(e2)
	Meta.set_setting("damage_numbers_on", numbers_prev)
	Meta.set_setting("fx_quality", quality_prev)

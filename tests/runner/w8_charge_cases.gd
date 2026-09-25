# tests/runner/w8_charge_cases.gd
# W8 蓄能引爆改版用例体（由 test_w8_charge.gd 入口加载）。
# 覆盖（五方向定案 orbit 组验收映射）：
#   ① R186 拆除负向：attach 三件套属性/方法零残留；挂 ELE 词条 240 帧接触目标
#      elemental 恒空、apply_attach 经 W8 零调用（锁死不复潮）。
#   ② 蓄能确定性：逐 tick 蓄能增量、gain_cd 内冷却、同帧双球仅 +1、满 5 恰 1 次
#      引爆、AoE=5×atk、w8_detonations 逐一吻合。
#   ③ 引爆三道闸：两目标同帧满档第二次延后 ≥0.5s（全局 ICD）；单目标 ICD 0.25s
#      隔离断言。
#   ④ 帽与复制：单目标刀数帽（distinct 刀 ≤ 帽）；本体+复制体共池——恰 1 次引爆/
#      周期（蓄能池目标 uid 全局单例）。
#   ⑤ 塑场：切向分量 > 0、径向归环 ≤ 8px/击；MEC_KNOCK 平加接线；自爆引信打断
#      契约保留。
#   ⑥ 阈值：删 3 条投射物死声明、CRIT_SHARD 0.35、ECHO 引爆×1.5 消费重计、
#      RING 半径 +20%。
#   ⑦ 数值探针：L1 裸装 DPS 33.3±10%、L5 113.3±10%、AFF_CDR 经 cd 通道首次生效。
# 确定性：全部用例固定坐标/静止敌/crit=0 副本数据/帧戳手动推进（E-03 闸门口径）。
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


# ELE 附着间谍（W8 侧 apply_attach 零调用断言——覆写只记数不提交）
class ElementSpy extends ElementalSystem:
	var attach_calls: int = 0
	func apply_attach(p_enemy: Node2D, p_element: int, p_value: float,
			p_info: Dictionary = {}) -> void:
		attach_calls += 1


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_test_r186_removal()
	_test_charge_determinism()
	_test_detonate_gates()
	_test_cap_and_copies()
	_test_formation_knockback()
	_test_thresholds()
	_test_dps_probes()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 夹具 ──────────────────────────────────────────────────────────
func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.global_position = Vector2(360.0, 640.0)   # 居中（几何确定性）


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _add(p_id: StringName) -> WeaponBase:
	return _gl.player.add_weapon(_gl.registry.get_weapon(p_id))


func _player_center() -> Vector2:
	return _gl.player.global_position


func _bump() -> void:
	GameConfig.frame_stamp += 1                    # E-03 帧闸门推进（引爆 ICD 帧戳时钟）


func _step(p_w8: WeaponBase, p_ticks: int) -> void:
	for i in range(p_ticks):
		_bump()
		p_w8.tick(DT)


func _fresh_w8() -> OrbitWeapon:
	# 拆旧 W8 → 蓄能静态闸清零 → 新装（crit=0 副本数据 + meta 修正归零——伤害探针确定性）
	for i in range(_gl.player.weapon_slots.size()):
		var w = _gl.player.weapon_slots[i]
		if w != null and is_instance_valid(w) and w.data != null \
				and String(w.data.id).begins_with("W8"):
			_gl.player.weapon_slots[i] = null
			w.free()
	OrbitField.reset_detonate_gates()
	_clear_enemies()
	_gl.player.set("unlocked_slots", 5)
	var w8: OrbitWeapon = _add(&"W8_orbit_field") as OrbitWeapon
	if w8 != null:
		w8.data = w8.data.duplicate(true)
		w8.data.crit_rate = 0.0                    # 探针确定性（暴击通道旁路）
		w8.meta_atk_pct = 0.0                      # 局外养成修正隔离（user:// 口径不入测）
		w8.call("_invalidate_panel")
	return w8


func _spawn_e(p_pos: Vector2, p_hp: float = 100000.0) -> Enemy:
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(_gl.registry.get_enemy(&"E1_grunt"), 1, 0)
	enemy.set("speed", 0.0)                        # 静止敌（几何确定性）
	enemy.set("max_hp", p_hp)
	enemy.set("hp", p_hp)
	enemy.global_position = p_pos
	_gl.spawner.active.append(enemy)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	return enemy


func _clear_enemies() -> void:
	for e in _gl.spawner.active.duplicate():
		_gl.spawner.active.erase(e)
		(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_gl.enemy_grid.rebuild(_gl.spawner.active)


func _ensure_field(p_w8: OrbitWeapon, p_angular: float = 0.0) -> OrbitField:
	# 力场懒创建 + 几何确定性配置（静止定相 / 零击退——塑场另段专测）
	p_w8.call("try_fire")
	var field: OrbitField = p_w8.orbit_field
	if field != null:
		field.knockback = 0.0
		field.angular_speed = p_angular
	return field


# ── ① R186 拆除负向 ──────────────────────────────────────────────
func _test_r186_removal() -> void:
	print("── R186 拆除负向锁死 ──")
	var w8 := _fresh_w8()
	_check("前置：W8 装配", w8 != null)
	if w8 == null:
		return
	var field := _ensure_field(w8)
	_check("前置：力场创建", field != null)
	if field == null:
		return
	# 三件套不复潮：属性/方法级零残留
	_check("拆除：attach_gate 属性不存在", not ("attach_gate" in field))
	_check("拆除：attach_mult 属性不存在", not ("attach_mult" in field))
	_check("拆除：_attach_cd 属性不存在", not ("_attach_cd" in field))
	_check("拆除：_orb_element 方法不存在", not field.has_method("_orb_element"))
	_check("拆除：_enchant_elements 方法不存在", not field.has_method("_enchant_elements"))
	# 行为级：ELE 词条在场 + 240 帧接触 → apply_attach 零调用 + 目标 elemental 恒空
	var spy := ElementSpy.new()
	w8.elemental = spy
	var ok_ele: bool = w8.attach_trait(_gl.registry.get_trait(&"ELE_IGNITE"))
	_check("前置：ELE_IGNITE 挂载", ok_ele)
	var enemy := _spawn_e(_player_center() + Vector2(90.0, 0.0))
	_gl.elemental.register_host(enemy)             # 真件系统宿主登记（模拟生产路径）
	var state: ElementalState = enemy.get("elemental")
	_check("前置：敌已挂 ElementalState", state != null)
	_step(w8, 240)
	var empty := true
	if state != null:
		for g in state.gauges:
			if absf(g) > 0.0001:
				empty = false
		if state.burn_layers > 0 or state.burn_timer > 0.0:
			empty = false
	_check("负向：240 帧接触目标 elemental 恒空（不复潮）", empty)
	_check("负向：apply_attach 经 W8 零调用", spy.attach_calls == 0,
		"calls=%d" % spy.attach_calls)
	_check("伤害底：接触伤害照常落血（拆附着不拆输出）", float(enemy.hp) < 100000.0 - 10.0,
		"hp=%s" % str(enemy.hp))
	spy.free()
	_clear_enemies()


# ── ② 蓄能确定性 ─────────────────────────────────────────────────
func _test_charge_determinism() -> void:
	print("── 蓄能确定性 ──")
	var w8 := _fresh_w8()
	if w8 == null:
		_check("前置：W8 装配", false)
		return
	var field := _ensure_field(w8)
	_check("前置：力场创建", field != null)
	if field == null:
		return
	var c := _player_center()
	var e1 := _spawn_e(c + Vector2(90.0, 0.0))
	var s1 := _spawn_e(c + Vector2(150.0, 0.0))    # 引爆心 60px（90px AoE 内）
	var s2 := _spawn_e(c + Vector2(210.0, 0.0))    # 引爆心 120px（AoE 外）
	# 逐 tick 蓄能增量：首接触 tick 恰 +1
	_step(w8, 1)
	_check("蓄能：首接触 tick 恰 +1", OrbitField.charge_of(e1) == 1,
		"charge=%d" % OrbitField.charge_of(e1))
	# charge_gain_cd 内冷却：同位连 tick 不再 +1
	_step(w8, 12)                                  # 0.1s < 0.5s
	_check("蓄能：gain_cd 内冷却（+0）", OrbitField.charge_of(e1) == 1,
		"charge=%d" % OrbitField.charge_of(e1))
	# 同帧双球仅 +1：扩判定半径令双球同帧压住同目标，清闸后单帧验证
	field.orb_radius = 300.0
	field._gain_cd.clear()
	_bump()
	w8.tick(DT)
	_check("蓄能：同帧双球仅 +1", OrbitField.charge_of(e1) == 2,
		"charge=%d" % OrbitField.charge_of(e1))
	field.orb_radius = 16.0
	# 满 5 恰 1 次引爆 + AoE=5×atk + w8_detonations 逐一吻合
	var det0: int = DebugStats.get_counter(&"w8_detonations")
	var hp1 := float(e1.hp)
	var hp_s1 := float(s1.hp)
	var hp_s2 := float(s2.hp)
	var peak := 0
	var detonated := false
	for i in range(600):                           # 5s 预算
		_step(w8, 1)
		var ch := OrbitField.charge_of(e1)
		peak = maxi(peak, ch)
		if ch == 0 and i > 12:
			detonated = true
			break
	_check("蓄能：逐档爬升（爆前可见峰值 4——第 5 档同 tick 引爆）", peak == 4,
		"peak=%d" % peak)
	_check("引爆：满 5 恰 1 次引爆（清零回落）", detonated)
	_check("引爆：w8_detonations 逐一吻合（+1）",
		DebugStats.get_counter(&"w8_detonations") == det0 + 1)
	_check("引爆：AoE=5×atk（60px 内副目标恰 50）",
		absf((hp_s1 - float(s1.hp)) - 50.0) < 0.05, "Δ=%s" % str(hp_s1 - float(s1.hp)))
	_check("引爆：90px 外零波及", absf(hp_s2 - float(s2.hp)) < 0.001,
		"Δ=%s" % str(hp_s2 - float(s2.hp)))
	var dmg_main := hp1 - float(e1.hp)
	_check("引爆：满档周期 = 3×接触(10) + 引爆 50 = 80（基线取在双球探测后蓄能 2 档）",
		absf(dmg_main - 80.0) < 0.05, "Δ=%s" % str(dmg_main))
	_clear_enemies()


# ── ③ 引爆三道闸 ─────────────────────────────────────────────────
func _test_detonate_gates() -> void:
	print("── 引爆三道闸 ──")
	var w8 := _fresh_w8()
	if w8 == null:
		_check("前置：W8 装配", false)
		return
	var field := _ensure_field(w8)
	_check("前置：力场创建", field != null)
	if field == null:
		return
	var c := _player_center()
	var e1 := _spawn_e(c + Vector2(90.0, 0.0))
	var e2 := _spawn_e(c + Vector2(-90.0, 0.0))    # orb1 位（相位 π，同节拍接触）
	# 闸①：两目标同帧满档 → 第二次引爆延后 ≥0.5s（全局 ICD）——按引爆计数逐 tick 定位
	var first_det_tick := -1
	var second_det_tick := -1
	for i in range(900):                           # 7.5s 预算
		var d0: int = DebugStats.get_counter(&"w8_detonations")
		_step(w8, 1)
		if DebugStats.get_counter(&"w8_detonations") > d0:
			if first_det_tick < 0:
				first_det_tick = i
			elif second_det_tick < 0:
				second_det_tick = i
				break
	_check("闸①：两目标同帧满档 → 两次引爆先后发生（非同帧）",
		first_det_tick >= 0 and second_det_tick >= 0 and first_det_tick != second_det_tick,
		"t1=%d t2=%d" % [first_det_tick, second_det_tick])
	var delay_s := float(second_det_tick - first_det_tick) * DT
	_check("闸①：第二次引爆延后 ≥0.5s（全局 ICD）且 <1.5s（非失速）",
		delay_s >= 0.4999 and delay_s <= 1.5, "delay=%.3fs" % delay_s)
	# 闸②：单目标 ICD 隔离（直置帧戳——全局闸清零后单看目标闸）
	OrbitField._detonate_global_stamp = 0
	OrbitField.set_charge(e1, 5)
	OrbitField._detonate_target_stamp[int(e1.get("uid"))] = GameConfig.frame_stamp + 30
	var det0: int = DebugStats.get_counter(&"w8_detonations")
	var blocked: bool = not field._maybe_detonate(e1)
	_check("闸②：单目标 ICD 内引爆被拒",
		blocked and DebugStats.get_counter(&"w8_detonations") == det0)
	for i in range(31):
		_bump()
	var fired: bool = field._maybe_detonate(e1)
	_check("闸②：ICD 到期后引爆放行（0.25s 闸）",
		fired and DebugStats.get_counter(&"w8_detonations") == det0 + 1)
	_check("闸③：刀数帽参数在力场（缺省 8）", field.effective_blade_cap == 8)
	_clear_enemies()


# ── ④ 刀数帽与复制单例 ───────────────────────────────────────────
func _test_cap_and_copies() -> void:
	print("── 刀数帽与复制单例 ──")
	var w8 := _fresh_w8()
	if w8 == null:
		_check("前置：W8 装配", false)
		return
	var field := _ensure_field(w8)
	_check("前置：力场创建", field != null)
	if field == null:
		return
	# 刀数帽：帽=2 + 16 刀扫掠——单目标命中事件只来自最先经过的 2 把 distinct 刀
	field.effective_blade_cap = 2
	field.charge_gain_cd = 0.05
	field.orbs = 16
	field.angular_speed = 335.0
	field._gain_cd.clear()
	field._blade_hits.clear()
	var c := _player_center()
	var e1 := _spawn_e(c + Vector2(120.0, 0.0), 1000000.0)
	var events0: int = DebugStats.get_counter(&"orbit_hit")
	_step(w8, 120)                                 # 1.0s = 335° < 1 公转周（无清闸 wrap）
	var events: int = DebugStats.get_counter(&"orbit_hit") - events0
	var blades: Dictionary = field._blade_hits.get(int(e1.get("uid")), {})
	_check("刀数帽：16 刀单目标命中事件 ≤ 帽等价位（≤4）", events <= 4,
		"events=%d" % events)
	_check("刀数帽：登记 distinct 刀数 ≤ 帽（2）", blades.size() <= 2,
		"blades=%d" % blades.size())
	# 复制体蓄能单例：本体+复制体共池——恰 1 次引爆/周期，全局 ICD 防同帧双爆
	field.effective_blade_cap = 8
	field.charge_gain_cd = 0.5
	field.orbs = 2
	field.angular_speed = 0.0
	field.angle = 0.0                             # 帽段把相位转走了——orb0 归位 (90,0)
	field._gain_cd.clear()
	field._blade_hits.clear()
	OrbitField.reset_detonate_gates()
	_clear_enemies()
	var deps: Dictionary = _gl.player.get("_deps")
	var copy := OrbitWeapon.new()
	copy.name = "W8CopyProbe"
	_gl.player.add_child(copy)
	copy.setup(w8.data, _gl.player, deps)
	copy.level = w8.level
	copy.call("try_fire")
	var cfield: OrbitField = copy.orbit_field
	_check("复制：副本力场创建（独立实体）", cfield != null and cfield != field)
	if cfield != null:
		cfield.knockback = 0.0
		cfield.angular_speed = 0.0
	var e2 := _spawn_e(c + Vector2(90.0, 0.0), 1000000.0)   # 双方 orb0 同压一目标
	var det_ticks: Array[int] = []
	for i in range(720):                           # 6s：双源加速 → 周期 ≈1.5s → ≥3 次
		var d0: int = DebugStats.get_counter(&"w8_detonations")
		_bump()
		w8.tick(DT)
		copy.tick(DT)
		if DebugStats.get_counter(&"w8_detonations") > d0:
			det_ticks.append(i)
	var gaps_ok := true
	var prev_t := -100
	for t in det_ticks:
		if t - prev_t < 55:                        # 同周期双爆 = 间隔 <0.5s；单例 + 全局闸 ≥0.5s
			gaps_ok = false
		prev_t = t
	_check("复制：恰 1 次引爆/周期（≥3 周期且间隔 ≥0.5s，uid 单例）",
		det_ticks.size() >= 3 and gaps_ok,
		"dets=%d gaps_ok=%s" % [det_ticks.size(), str(gaps_ok)])
	if copy != null and is_instance_valid(copy):
		copy.free()
	_clear_enemies()


# ── ⑤ 塑场击退 ──────────────────────────────────────────────────
func _test_formation_knockback() -> void:
	print("── 塑场击退 ──")
	var w8 := _fresh_w8()
	if w8 == null:
		_check("前置：W8 装配", false)
		return
	var field := _ensure_field(w8)
	_check("前置：力场创建", field != null)
	if field == null:
		return
	field.knockback = 40.0
	field.charge_gain_cd = 99.0                    # 只取一次命中（防连击叠加冲量）
	var c := _player_center()
	# 环上目标：纯切向（归环死区），切向分量 > 0、径向 0
	var e1 := _spawn_e(c + Vector2(90.0, 0.0))
	_bump()
	w8.tick(DT)
	var impulse: Vector2 = e1.knock_vel
	var f := impulse / 9.0                         # Enemy.knockback：冲量 = 位移 ×9 阻尼
	_check("塑场：命中产生击退冲量", impulse.length() > 0.0)
	_check("塑场：切向分量 = 击退×60%（沿公转扫带）",
		absf(f.dot(Vector2(0.0, 1.0)) - 40.0 * 0.6) < 0.01 and f.dot(Vector2(0.0, 1.0)) > 0.0,
		"t=%.1f" % f.dot(Vector2(0.0, 1.0)))
	_check("塑场：环上径向分量 ≈ 0（≤8px/击）", absf(f.dot(Vector2.RIGHT)) <= 8.0 + 0.01,
		"r=%.1f" % f.dot(Vector2.RIGHT))
	_clear_enemies()
	# 环内目标：径向归环向外推、钳 8px/击
	var e2 := _spawn_e(c + Vector2(70.0, 0.0))
	_bump()
	w8.tick(DT)
	var f2: Vector2 = e2.knock_vel / 9.0
	var radial2 := f2.dot(Vector2.RIGHT)
	_check("塑场：环内目标归环向外推（>0）", radial2 > 0.0, "r=%.1f" % radial2)
	_check("塑场：归环径向 ≤ 8px/击", radial2 <= 8.0 + 0.01, "r=%.1f" % radial2)
	_check("塑场：切向分量保持 60%", absf(f2.dot(Vector2(0.0, 1.0)) - 24.0) < 0.01)
	_clear_enemies()
	# MEC_KNOCK 接线（required_forms 解锁 [3] 后 W8 首次吃动能冲击池）
	var kb_ok: bool = w8.attach_trait(_gl.registry.get_trait(&"MEC_KNOCK"))
	w8.call("refresh_orbit_field")
	_check("塑场：MEC_KNOCK 平加进力场击退（40+60）",
		kb_ok and absf(float(w8.orbit_field.knockback) - 100.0) < 0.01,
		"kb=%.1f" % float(w8.orbit_field.knockback))
	# 自爆引信打断契约保留（接触击退 → Enemy.knockback 内 _cancel_fuse）
	var ev := _spawn_e(c + Vector2(90.0, 0.0))
	ev.set("_fuse_armed", true)                    # 模拟爆虫引导期
	w8.orbit_field.charge_gain_cd = 0.0            # 闸放开（每帧可命中）
	_bump()
	w8.tick(DT)
	_check("塑场：自爆引导被接触击退打断（契约保留）", not bool(ev.get("_fuse_armed")))
	_clear_enemies()


# ── ⑥ 阈值改版 ──────────────────────────────────────────────────
func _test_thresholds() -> void:
	print("── 阈值改版 ──")
	var w8 := _fresh_w8()
	if w8 == null:
		_check("前置：W8 装配", false)
		return
	var ids: Array[String] = []
	for th in w8.data.threshold_traits:
		ids.append(String(th.get("threshold_id")))
	_check("阈值：三条投射物死声明已删（SIZE_NOVA/FRACTAL_ECHO/BOUNCE_ETERNAL）",
		not ids.has("TH_SIZE_NOVA") and not ids.has("TH_FRACTAL_ECHO")
		and not ids.has("TH_BOUNCE_ETERNAL"), str(ids))
	var crit_idx := ids.find("TH_CRIT_SHARD")
	_check("阈值：TH_CRIT_SHARD 保留且 0.6→0.35",
		crit_idx >= 0 and absf(float(w8.data.threshold_traits[crit_idx].get("threshold", 0.0)) - 0.35) < 0.0001)
	_check("阈值：TH_DETONATION_ECHO / TH_RING_PRESSURE 在册",
		ids.has("TH_DETONATION_ECHO") and ids.has("TH_RING_PRESSURE"))
	# 行为级：ECHO（计数直置 8 → 下次引爆 ×1.5 = 75，消费后重计）
	var field := _ensure_field(w8)
	_check("前置：力场创建", field != null)
	if field == null:
		return
	var c := _player_center()
	var e1 := _spawn_e(c + Vector2(90.0, 0.0))
	var s1 := _spawn_e(c + Vector2(150.0, 0.0))    # 引爆心 60px（AoE 内）
	field.detonation_count = 8
	_step(w8, 400)                                 # 3.3s ≥ 5 档 ×0.5s
	var dmg_s1 := 100000.0 - float(s1.hp)
	_check("阈值：ECHO 生效（引爆 50→75）", absf(dmg_s1 - 75.0) < 0.05,
		"Δ=%s" % str(dmg_s1))
	_check("阈值：ECHO 消费后计数重计", field.detonation_count == 0,
		"count=%d" % field.detonation_count)
	# RING_PRESSURE（charged_hits ≥ 60 → 半径 90→108：110px 探针从「基础帽外」进「环压帽内」）
	OrbitField.reset_detonate_gates()
	_clear_enemies()
	var e3 := _spawn_e(c + Vector2(90.0, 0.0))
	var s3 := _spawn_e(c + Vector2(200.0, 0.0))    # 引爆心 110px（基础 90+14=104 外 / 环压 108+14=122 内）
	var sf := _spawn_e(c + Vector2(240.0, 0.0))    # 引爆心 150px（122 外零波及）
	field.charged_hits = 60
	_step(w8, 400)
	var dmg3 := 100000.0 - float(s3.hp)
	var dmgf := 100000.0 - float(sf.hp)
	_check("阈值：RING 生效（110px 处吃满引爆 50——基础半径 104 外）",
		absf(dmg3 - 50.0) < 0.05, "Δ=%s" % str(dmg3))
	_check("阈值：环压半径外（150px）零波及", dmgf < 0.001, "Δ=%s" % str(dmgf))
	_clear_enemies()


# ── ⑦ 数值探针 ──────────────────────────────────────────────────
func _test_dps_probes() -> void:
	print("── 数值探针 ──")
	var w8 := _fresh_w8()
	if w8 == null:
		_check("前置：W8 装配", false)
		return
	var field := _ensure_field(w8, 240.0)          # L1 真实转速表（240°/s）
	_check("前置：力场创建", field != null)
	if field == null:
		return
	var c := _player_center()
	# 45° 环位（非 orb 初相 0°）——解调引力脉冲（3.0s 节拍）与接触节拍（0.75s 间隔）的
	# 完全谐波锁死：45° 首触 0.1875s → 脉冲历元距前次接触 0.5625s ≥ gain_cd 0.5（脉冲
	# 稳定落账，公式 R 项 2 生效）；0° 环位会让脉冲恒撞接触后 0s 被闸吞（夹具谐波伪影）
	var e1 := _spawn_e(c + Vector2(90.0, 0.0).rotated(deg_to_rad(45.0)), 1000000.0)
	_step(w8, 3600)                                # 30s 稳态采样
	var dps := (1000000.0 - float(e1.hp)) / 30.0
	_check("数值：L1 裸装 DPS 33.3±10%（接触 16.7+引爆 16.7）",
		dps >= 30.0 and dps <= 36.7, "dps=%.2f" % dps)
	# L5：orbs 4 / 半径 120 / 转速 335 / gain_cd 0.3 / atk 17 → 113.3
	w8.level = 5
	w8.call("_invalidate_panel")
	w8.call("refresh_orbit_field")
	field = w8.orbit_field
	field.knockback = 0.0                          # 重铺后还原（探针静止几何）
	OrbitField.reset_detonate_gates()
	_clear_enemies()
	var e5 := _spawn_e(c + Vector2(120.0, 0.0).rotated(deg_to_rad(45.0)), 1000000.0)
	_step(w8, 3600)
	var dps5 := (1000000.0 - float(e5.hp)) / 30.0
	_check("数值：L5 裸装 DPS 113.3±10%（×3.4）",
		dps5 >= 102.0 and dps5 <= 124.7, "dps=%.2f" % dps5)
	# AFF_CDR 经 weapon_base cd 通道对 W8 首次生效（pulse 节拍 3.0→2.7）
	var iv0: float = w8.call("_fire_interval")
	var ok_cdr: bool = w8.attach_trait(_gl.registry.get_trait(&"AFF_CDR"))
	var iv1: float = w8.call("_fire_interval")
	_check("节奏：AFF_CDR 经 cd×(1−ΣCDR) 通道生效（3.0→2.7）",
		ok_cdr and absf(iv0 - 3.0) < 0.01 and absf(iv1 - 2.7) < 0.05,
		"iv=%.3f→%.3f" % [iv0, iv1])
	_clear_enemies()

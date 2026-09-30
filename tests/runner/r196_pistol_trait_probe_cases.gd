# tests/runner/r196_pistol_trait_probe_cases.gd
# R196 手枪词条家族失效探针·用例体（FEEDBACK_TRACKER R196 #2/#3）：
#   #2 手枪多重装填没生效——还是单发
#   #3 手枪选穿透弹头→往后面射 3 个散发子弹
# 全链真实口径：boot 真 GameLoop → 每例全新 W1_pistol（独立 trait_stack）→ 词条经
# attach_trait（registry .tres 白板值 1.45，档位受控）实挂 → try_fire 实弹审计：
#   A 多重装填（L1/L2）：实发 N 弹的位置/速度重合度——「视觉单发」根因复现
#   B L3/L5 编队几何（无词条基线）：实发弹数与散布——「3 个散发子弹」真源
#   C 穿透弹头：pierce_left 预算 + 同轴双敌贯穿实伤 + 金丝雀敌对照 + 弹数不变
#   D 卡流对照：_make_trait_card → _apply_rarity_values → apply_choice 全链（run1 已验）
# 逐弹审计打印：出生点/速度/速度角（UP=-90° 前向）/pierce_left——「背向弹」筛查。
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _snap_shake_on: bool = true
var _w: Array[WeaponBase] = []                     # 预建 6 把 W1（槽位帽内）——每例独占一把


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_test_a1_l1_baseline_single()
	_test_a2_multishot_superimposed()          # ★反馈#2 根因复现
	_test_a3_multishot_4x_superimposed()
	_test_b1_l5_three_line_fan_no_trait()      # ★反馈#3「3 个散发子弹」真源
	_test_b2_l5_pierce_no_extra_bullets()      # ★反馈#3 归因排除
	_test_c1_pierce_budget_and_passthrough()
	_test_d1_l3_parallel_lanes()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 环境 ──────────────────────────────────────────────────────────
func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU          # 冻结波次刷怪（用例自管夹具敌）
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.set("unlocked_slots", 6)
	_gl.player.global_position = Vector2(360.0, 900.0)
	_snap_shake_on = bool(Meta.settings("shake_on"))
	Meta.set_setting("shake_on", false)
	# 预建 6 把 W1（开局枪占槽 0，另补 5 把——槽帽内；每测试例独占一把防词条串扰）
	for i in range(6):
		_w.append(_gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol")))


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null
	Meta.set_setting("shake_on", _snap_shake_on)   # 还原写口（「写即存」防测试档残留污染后续套件）


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _fresh_pistol(p_idx: int, p_level: int) -> WeaponBase:
	# 每例独占一把预建 W1（trait_stack.clear 清例间词条串扰）；弹幕态计时器清零
	if p_idx < 0 or p_idx >= _w.size():
		return null
	var w := _w[p_idx]
	if w == null or not is_instance_valid(w):
		return null
	w.trait_stack.clear()
	w.level = clampi(p_level, 1, 5)
	w.set("_volley_left", 0.0)
	w.set("_volley_cd_left", 0.0)
	w.call("_invalidate_panel")
	return w


func _spawn_e(p_pos: Vector2, p_hp: float = 1000000.0) -> Node2D:
	# 静止夹具敌（r187_rework_cases 同款）
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(_gl.registry.get_enemy(&"E1_grunt"), 1, 0)
	enemy.set("speed", 0.0)
	enemy.set("max_hp", p_hp)
	enemy.set("hp", p_hp)
	enemy.global_position = p_pos
	_gl.spawner.active.append(enemy)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	return enemy


func _clear_all() -> void:
	# 弹与敌全清（active_projectiles 返回内部缓冲——先复制再遍历防 release 迭代跳元）
	var snapshot: Array = (_gl.pools[&"projectile"] as ProjectilePool) \
		.active_projectiles().duplicate()
	for p in snapshot:
		if p is ProjectileBase:
			(p as ProjectileBase).nullify()
	for e in _gl.spawner.active.duplicate():
		_gl.spawner.active.erase(e)
		(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_gl.enemy_grid.rebuild(_gl.spawner.active)


func _player_bullets() -> Array:
	var out: Array = []
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		if p is ProjectileBase and (p as ProjectileBase).team == 0:
			out.append(p)
	return out


func _bullets_report(p_tag: String) -> void:
	# 逐弹审计：出生点/速度/速度角/pierce_left。UP=-90°=前向；偏角>90°=背向弹
	for b in _player_bullets():
		var pb := b as ProjectileBase
		var dev := rad_to_deg(absf(angle_difference(-PI / 2.0, pb.velocity.angle())))
		print("  [%s] uid=%d pos=%.1f,%.1f vel=%.1f,%.1f 偏角=%.1f° pierce_left=%d" % [
			p_tag, pb.uid, pb.global_position.x, pb.global_position.y,
			pb.velocity.x, pb.velocity.y, dev, pb.pierce_left])


func _bullets_superimposed() -> bool:
	# 全弹两两「位置重合 ∧ 速度相等」判定（浮点容差 0.5px / 0.5px/s）
	var bs := _player_bullets()
	if bs.size() < 2:
		return true
	var v0: Vector2 = (bs[0] as ProjectileBase).velocity
	var p0: Vector2 = (bs[0] as ProjectileBase).global_position
	for i in range(1, bs.size()):
		var pb := bs[i] as ProjectileBase
		if pb.velocity.distance_to(v0) > 0.5 or pb.global_position.distance_to(p0) > 0.5:
			return false
	return true


func _max_spread_deg() -> float:
	# 弹间最大夹角（°）——散发锥实测
	var bs := _player_bullets()
	if bs.size() < 2:
		return 0.0
	var worst := 0.0
	for i in range(bs.size()):
		for j in range(bs.size()):
			worst = maxf(worst, rad_to_deg(absf(angle_difference(
				(bs[i] as ProjectileBase).velocity.angle(),
				(bs[j] as ProjectileBase).velocity.angle()))))
	return worst


func _fire_once(p_w: WeaponBase) -> int:
	seed(42)
	p_w.try_fire()
	return _player_bullets().size()


# ── A 组：多重装填 ────────────────────────────────────────────────
func _test_a1_l1_baseline_single() -> void:
	print("── A1 基线：W1 L1 裸装 ──")
	_clear_all()
	var w := _fresh_pistol(0, 1)
	_check("A1 前置：装配", w != null)
	if w == null:
		return
	_check("A1：_pellet_count==1 / _pierce_count==1",
		int(w.call("_pellet_count")) == 1 and int(w.call("_pierce_count")) == 1,
		"pellets=%d pierce=%d" % [int(w.call("_pellet_count")), int(w.call("_pierce_count"))])
	_check("A1：实发 1 弹", _fire_once(w) == 1, "实发 %d" % _player_bullets().size())
	_bullets_report("A1")
	_clear_all()


func _test_a2_multishot_superimposed() -> void:
	print("── A2 ★反馈#2 复现：L1 + 白板 AFF_MULTI（+1 丸） ──")
	_clear_all()
	var w := _fresh_pistol(1, 1)
	if w == null:
		_check("A2 前置：装配", false)
		return
	w.attach_trait(_gl.registry.get_trait(&"AFF_MULTI"))
	_check("A2：_pellet_count==2（词条聚合链工作）", int(w.call("_pellet_count")) == 2,
		"_pellet_count=%d" % int(w.call("_pellet_count")))
	var n := _fire_once(w)
	_bullets_report("A2")
	_check("A2：实发 2 弹（数值上多重已生效）", n == 2, "实发 %d" % n)
	# R196 FIX-1 契约变更（原「★两弹完全重合=视觉单发」根因断言随修复退役——
	# r196_growth_cases ⑦A 同口径正向锁定）：编队退化回落逐丸锥形分布，两弹可辨
	_check("A2：两弹可辨（散角>0.1°，不再同点同速像素重合——R196 FIX-1）",
		not _bullets_superimposed() and _max_spread_deg() > 0.1,
		"弹间散角 %.2f°" % _max_spread_deg())
	_clear_all()


func _test_a3_multishot_4x_superimposed() -> void:
	print("── A3 L1 + AFF_MULTI×2 层（+3 丸） ──")
	_clear_all()
	var w := _fresh_pistol(2, 1)
	if w == null:
		_check("A3 前置：装配", false)
		return
	w.attach_trait(_gl.registry.get_trait(&"AFF_MULTI"))
	w.attach_trait(_gl.registry.get_trait(&"AFF_MULTI"))
	_check("A3：_pellet_count==4（1+round(2.9)=4）", int(w.call("_pellet_count")) == 4,
		"_pellet_count=%d" % int(w.call("_pellet_count")))
	var n := _fire_once(w)
	_bullets_report("A3")
	_check("A3：实发 4 弹", n == 4, "实发 %d" % n)
	# R196 FIX-1 契约变更（原「★四弹完全重合」退役）：四弹锥形分布可辨
	_check("A3：四弹可辨（散角>0.1°——R196 FIX-1）",
		not _bullets_superimposed() and _max_spread_deg() > 0.1,
		"弹间散角 %.2f°" % _max_spread_deg())
	_clear_all()


# ── B 组：L5 三线（反馈#3 真源） ──────────────────────────────────
func _test_b1_l5_three_line_fan_no_trait() -> void:
	print("── B1 ★L5 无词条基线：三线收束=3 个散发子弹 ──")
	_clear_all()
	var w := _fresh_pistol(3, 5)
	if w == null:
		_check("B1 前置：装配", false)
		return
	_check("B1：零词条 _pellet_count==3（L5 表值）", int(w.call("_pellet_count")) == 3,
		"_pellet_count=%d" % int(w.call("_pellet_count")))
	var n := _fire_once(w)
	_bullets_report("B1")
	_check("B1：实发 3 弹（与「选了穿透弹头后射 3 个散发子弹」同画面）", n == 3,
		"实发 %d" % n)
	_check("B1：三弹呈散布（弹间散角>0.5°——L5 编队收束几何出 fan）",
		_max_spread_deg() > 0.5, "弹间散角 %.2f°" % _max_spread_deg())
	_check("B1：无背向弹（全弹偏角<90°）", _bullets_superimposed() == false \
		and _fan_all_forward(), "有弹偏角≥90°" if not _fan_all_forward() else "")
	_clear_all()


func _fan_all_forward() -> bool:
	for b in _player_bullets():
		var dev := rad_to_deg(absf(angle_difference(-PI / 2.0,
			(b as ProjectileBase).velocity.angle())))
		if dev >= 90.0:
			return false
	return true


func _test_b2_l5_pierce_no_extra_bullets() -> void:
	print("── B2 ★L5 + AFF_PIERCE：弹数不变（归因排除） ──")
	_clear_all()
	var w := _fresh_pistol(4, 5)
	if w == null:
		_check("B2 前置：装配", false)
		return
	w.attach_trait(_gl.registry.get_trait(&"AFF_PIERCE"))
	_check("B2：_pierce_count==3（L5 表值 2+白板 1）", int(w.call("_pierce_count")) == 3,
		"_pierce_count=%d" % int(w.call("_pierce_count")))
	var n := _fire_once(w)
	_bullets_report("B2")
	_check("B2：实发仍 3 弹（穿透弹头不产生多发——#3 的「多发」另有真源）", n == 3,
		"实发 %d" % n)
	_clear_all()


# ── C 组：穿透预算与贯穿行为 ──────────────────────────────────────
func _test_c1_pierce_budget_and_passthrough() -> void:
	print("── C1 L1 + 白板 AFF_PIERCE：预算/贯穿/金丝雀 ──")
	_clear_all()
	var w := _fresh_pistol(1, 1)
	if w == null:
		_check("C1 前置：装配", false)
		return
	w.attach_trait(_gl.registry.get_trait(&"AFF_PIERCE"))
	_check("C1：_pierce_count==2（1+1）", int(w.call("_pierce_count")) == 2,
		"_pierce_count=%d" % int(w.call("_pierce_count")))
	var e1 := _spawn_e(Vector2(360.0, 760.0))    # 首敌（距枪口 140px，抖动漂移 ≤5px）
	var e2 := _spawn_e(Vector2(360.0, 560.0))    # 贯穿第 2 敌（340px，漂移 ≤12px<reach20）
	var e3 := _spawn_e(Vector2(360.0, 300.0))    # 金丝雀（预算 2 不可达）
	_fire_once(w)
	var bs := _player_bullets()
	_check("C1：实发 1 弹", bs.size() == 1, "实发 %d" % bs.size())
	_bullets_report("C1")
	if bs.size() == 1:
		_check("C1：pierce_left==2（预算随词条）",
			(bs[0] as ProjectileBase).pierce_left == 2,
			"pierce_left=%d" % (bs[0] as ProjectileBase).pierce_left)
	_check("C1：方向朝前（偏角<30°）",
		rad_to_deg(absf(angle_difference(-PI / 2.0,
			(bs[0] as ProjectileBase).velocity.angle()))) < 30.0)
	# 推进穿越（620px/s；300px 行程 ≤60 帧）
	for i in range(90):
		GameConfig.advance_frame()
		for b in _player_bullets().duplicate():
			(b as ProjectileBase).tick(DT)
		if i % 10 == 0:
			var dbg: Array = _player_bullets()
			if dbg.is_empty():
				print("  [C1 dbg] frame %d：弹已空" % i)
			else:
				var dp := dbg[0] as ProjectileBase
				print("  [C1 dbg] frame %d：弹 pos=%.1f,%.1f pierce_left=%d | e1.hp=%.0f e2.hp=%.0f e3.hp=%.0f" % [
					i, dp.global_position.x, dp.global_position.y, dp.pierce_left,
					float(e1.get("hp")), float(e2.get("hp")), float(e3.get("hp"))])
		if _player_bullets().is_empty():
			break
	var hit1 := float(e1.get("hp")) < float(e1.get("max_hp")) - 0.5
	var hit2 := float(e2.get("hp")) < float(e2.get("max_hp")) - 0.5
	var hit3 := float(e3.get("hp")) < float(e3.get("max_hp")) - 0.5
	_check("C1：首敌命中", hit1)
	print("  [C1] e1 实伤=%.1f（单发 14；R196 FIX-2 同敌不重击——无 ≈28 双跳）"
		% (float(e1.get("max_hp")) - float(e1.get("hp"))))
	# R196 FIX-2 契约变更（原「★预算被首敌二次命中吃满」语义退役）：生命周期级
	# 逐目标去重——同敌不重击耗预算，预算花在换目标上 → e2 贯穿承伤
	_check("C1：贯穿第 2 敌成立（预算花在换目标——R196 FIX-2）",
		hit2, "e2 实伤 %.1f" % (float(e2.get("max_hp")) - float(e2.get("hp"))))
	_check("C1：首敌恰 1 击（同敌生命周期不重击——R196 FIX-2）",
		absf(float(e1.get("max_hp")) - float(e1.get("hp")) - 14.0) < 0.5)
	_check("C1：金丝雀满血（预算耗尽即停——无超发）", not hit3)
	_clear_all()
	_test_c2_kill_gated_passthrough(w)


# ── C2：命中即杀时的贯穿（E-06 死亡短路路径） ─────────────────────
func _test_c2_kill_gated_passthrough(p_w: WeaponBase) -> void:
	print("── C2 白板 AFF_PIERCE + 首敌可杀（hp=10）：贯穿成立对照 ──")
	_clear_all()
	p_w.trait_stack.clear()
	p_w.attach_trait(_gl.registry.get_trait(&"AFF_PIERCE"))
	p_w.level = 1
	p_w.call("_invalidate_panel")
	var k1 := _spawn_e(Vector2(360.0, 760.0), 10.0)   # 可杀首敌（14>10 一跳即杀）
	var k2 := _spawn_e(Vector2(360.0, 560.0))         # 贯穿目标
	_fire_once(p_w)
	for i in range(90):
		GameConfig.advance_frame()
		for b in _player_bullets().duplicate():
			(b as ProjectileBase).tick(DT)
		if _player_bullets().is_empty():
			break
	var k1_dead := bool(k1.get("dead"))
	var k2_hit := float(k2.get("hp")) < float(k2.get("max_hp")) - 0.5
	_check("C2：首敌被杀", k1_dead)
	_check("C2：★命中即杀时贯穿第 2 敌成立（穿透可见性=击杀门控）", k2_hit,
		"k2 实伤 %.1f" % (float(k2.get("max_hp")) - float(k2.get("hp"))))
	_clear_all()


# ── D 组：L3 并排双管 ─────────────────────────────────────────────
func _test_d1_l3_parallel_lanes() -> void:
	print("── D1 L3 无词条：并排双管（gap=12，无收束） ──")
	_clear_all()
	var w := _fresh_pistol(2, 3)
	if w == null:
		_check("D1 前置：装配", false)
		return
	var n := _fire_once(w)
	_bullets_report("D1")
	_check("D1：实发 2 弹（L3 表值）", n == 2, "实发 %d" % n)
	if n == 2:
		var bs := _player_bullets()
		var dx: float = absf((bs[0] as ProjectileBase).global_position.x
			- (bs[1] as ProjectileBase).global_position.x)
		_check("D1：双弹横向错开（±6px——L3 起编队可见，fan 感起点）", dx > 6.0,
			"Δx=%.1fpx" % dx)
	_clear_all()

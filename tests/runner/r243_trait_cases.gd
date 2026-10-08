# tests/runner/r243_trait_cases.gd
# R243 buff 族五武器适配（w3-trait）用例体（入口运行时 load——cases 禁 test_ 前缀防电池
# glob 误收；-s 对非 MainLoop 脚本会挂起——前缀化 cases 文件会让 _batt_r215.py glob 误收后
# 死挂）。覆盖（任务验收 ①~⑨ / 设计 §9.1 buff ①~⑧）：
# ① MEC_GIANT_BLADE required_weapon→[W8,W9,W11,W12,W13]（value 0.25/层 stack_max 2）+
#    分层断言：W11 判定半径 10.8/12.6、W12 震荡半径 110.4/124.8、W13 斩击半径 228/266
# ② MEC_ORBIT_LINK 扩五武器（卡描述改「近战/法器武器的攻击体 +1/层」）+ 数量帽：金 3 层
#    link raw 12（1.45×2.6 金档→round 4/层×3）→ W12 额外 min(12,3)=3 斧 / W11 额外 +6 /
#    W13 幻影斩额外 +2
# ③ MEC_SLASH_TEMPO required_weapon→[W9,W13] + 上架门：W9/W13 过、W8/W11/W12 拒
# ④ MEC_FRACTAL required_forms→[0,2,3]（inheritable=true 锁定）+ 门：form3 五武器与
#    form0 W1 全过
# ⑤ 通道 B 单元（trait_effect_fractal melee 臂）：双宿主缺位早退保持；melee 臂同参数表
#    （1 层 2 枚 ±28°/0.4，2 层 3 枚 ±22°/0.45）；TH_FRACTAL_ECHO 深度读 melee.generation
#   （gen2→echo 抬 0.6、gen1 不触发、OrbitField 无代数键 = 深度 0 不触发）
# ⑥ 通道 A 集成：W12×FRACTAL 母斧落地碎裂 2 子斧（flight_axe/gen=3 封堵/shock_scale 0.4/
#    面板×0.4/落点=母落点+出射×120 tol1px/二次进入计数/split_rejected_generation 恰 +2）+
#    W11 子代 = 迷你飞剑（flight_sword=true、generation=1）
# ⑦ W8 子引爆（§4.5-4 终审①）：母-only 50 / 子-only 20 / 中心幂等 50 + 结算次数恰 3
#   （粗相候选 4+3+3=10）+ _detonate_settle 纯结算体无 ON_EXPIRE 派发结构断言 + 负控
#   （事后再派发仍产出请求——栈未耗尽）+ 事后帧推进零增量
# ⑧ AFF_RANGE/MEC_KNOCK 新消费点反死卡：AFF_RANGE 3 层→W11 射程 646.8 + 寿命随射程延长、
#    W12 震荡半径 147.84（96×1.54）；MEC_KNOCK 1 层→W12 径向击退 140×9、W11 剑体击退
#    60×9（基础 0）；两卡对 W11/W12 上架且实测有效
# ⑨ 锁定不动：MEC_KNOCK excluded_weapons:[W9] + required_forms [0,2,3]；AFF_RANGE 门 [3]
# 确定性：GameLoop 夹具（liedifu/w8_charge 同款）+ 静止敌 + crit=0 副本数据 + 帧戳手动推进；
# 金档缩放 = RARITY_VALUE_SCALE[3]=2.6（card_generator.gd:60）。
# 已知口径备注（如实登记）：⑦ 中管线幂等闸 (source,target,frame) 使母/子引爆同帧重叠目标
# 首命中生效——伤害面只证「母/子/无额外」三段，孙代排除主证 = 结算次数恰 3 + 结构断言。
extends RefCounted

const EXPECTED_TOTAL := 43
const DT := 1.0 / 60.0
const MAIN_SCENE := "res://scenes/main.tscn"
const PLAYER_POS := Vector2(360.0, 640.0)
const GOLD_SCALE := 2.6                       # RARITY_VALUE_SCALE[3]（card_generator.gd:60）
const WANTED_FIVE: Array[StringName] = [
	&"W8_orbit_field", &"W9_arc_slash", &"W11_spirit_sword",
	&"W12_ground_axe", &"W13_great_sword",
]

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261008)
	_boot_game_loop()
	_case1_giant_blade()
	_case2_orbit_link()
	_case3_slash_tempo()
	_case4_fractal_gate()
	_case5_channel_b_unit()
	_case6_channel_a()
	_case7_w8_child_detonate()
	_case8_range_knock()
	_case9_locks()
	_teardown_game_loop()
	_check("⑩ 套件总项数（EXPECTED=%d——R231 假绿教训）" % EXPECTED_TOTAL,
		_pass + _fail + 1 == EXPECTED_TOTAL, "实得 %d" % (_pass + _fail + 1))
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


# ── 夹具（r243_liedifu_cases 同款 GameLoop 桩） ───────────────────
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
	_gl.player.set("unlocked_slots", 12)
	_gl.player.global_position = PLAYER_POS


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _fresh(p_id: StringName) -> WeaponBase:
	# 拆旧同 id → 清场 → 新装（crit=0 副本数据 + meta 修正归零——伤害确定性）
	for i in range(_gl.player.weapon_slots.size()):
		var w = _gl.player.weapon_slots[i]
		if w != null and is_instance_valid(w) and w.data != null \
				and StringName(String(w.data.id)) == p_id:
			_gl.player.weapon_slots[i] = null
			w.free()
	_gl.player.global_position = PLAYER_POS
	_clear_enemies()
	var weapon: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(p_id))
	if weapon != null:
		weapon.data = weapon.data.duplicate(true)
		weapon.data.crit_rate = 0.0
		weapon.meta_atk_pct = 0.0
		weapon.call("_invalidate_panel")
	return weapon


func _spawn_e(p_pos: Vector2, p_hp: float = 100000.0) -> Enemy:
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(_gl.registry.get_enemy(&"E1_grunt"), 1, 0)
	enemy.set("speed", 0.0)
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


func _bump() -> void:
	GameConfig.frame_stamp += 1                    # E-03 帧闸门推进


func _fire(p_weapon: WeaponBase) -> void:
	p_weapon.cooldown_left = 0.0
	_bump()
	p_weapon.tick(DT)


func _live_projs(p_flag: String) -> Array[ProjectileBase]:
	var out: Array[ProjectileBase] = []
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		if is_instance_valid(p) and p is ProjectileBase \
				and bool(p.get(p_flag)) and bool(p.get("_live")):
			out.append(p)
	return out


func _run_axes_to_completion(p_max_iters: int = 300) -> void:
	for i in range(p_max_iters):
		var flying := _live_projs("_flight_axe")
		if flying.is_empty():
			return
		_bump()
		for a in flying:
			if is_instance_valid(a):
				a.tick(DT)


func _run_swords_to_completion(p_max_iters: int = 600) -> void:
	for i in range(p_max_iters):
		var flying := _live_projs("_flight_sword")
		if flying.is_empty():
			return
		_bump()
		for s in flying:
			if is_instance_valid(s):
				s.tick(DT)


func _trait(p_id: StringName) -> TraitData:
	return _gl.registry.get_trait(p_id)


func _gold_link() -> TraitData:
	# 金档 MEC_ORBIT_LINK（card_generator RARITY_VALUE_SCALE[3]=2.6 同式落值）：
	# value 1.45×2.6≈3.77 → _orbit_link_count round=4/层
	var td: TraitData = _trait(&"MEC_ORBIT_LINK").duplicate(true)
	td.value = float(td.value) * GOLD_SCALE
	return td


func _attach_n(p_weapon: WeaponBase, p_td: TraitData, p_n: int) -> bool:
	var ok := true
	for i in range(p_n):
		ok = p_weapon.attach_trait(p_td) and ok
	return ok


func _string_array_eq(p_got: Array, p_want: Array) -> bool:
	if p_got.size() != p_want.size():
		return false
	for i in range(p_got.size()):
		if String(p_got[i]) != String(p_want[i]):
			return false
	return true


func _int_array_eq(p_got: Array, p_want: Array) -> bool:
	if p_got.size() != p_want.size():
		return false
	for i in range(p_got.size()):
		if int(p_got[i]) != int(p_want[i]):
			return false
	return true


func _func_body(p_src: String, p_name: String) -> String:
	# 函数体提取（含注释行——结构断言侧先 _strip_comments 再查 token）
	var marker := "func %s(" % p_name
	var start := p_src.find(marker)
	if start < 0:
		return ""
	var nxt_plain := p_src.find("\nfunc ", start + 1)
	var nxt_static := p_src.find("\nstatic func ", start + 1)
	var end_pos := p_src.length()
	for cand in [nxt_plain, nxt_static]:
		if cand > start and cand < end_pos:
			end_pos = cand
	return p_src.substr(start, end_pos - start)


func _strip_comments(p_src: String) -> String:
	var out := ""
	for line in p_src.split("\n"):
		var pos := line.find("#")
		out += (line.substr(0, pos) if pos >= 0 else line) + "\n"
	return out


# ── ① GIANT_BLADE 扩五武器 + 分层半径 ────────────────────────────
func _case1_giant_blade() -> void:
	print("── ① MEC_GIANT_BLADE required_weapon 扩五武器 + 分层断言（§9.1 buff ①） ──")
	var td := _trait(&"MEC_GIANT_BLADE")
	_check("①tres：required_weapon=[W8,W9,W11,W12,W13] + value 0.25/层 + stack_max 2",
		_string_array_eq(td.params.get("required_weapon", []), WANTED_FIVE)
		and is_equal_approx(float(td.value), 0.25) and int(td.stack_max) == 2,
		"req=%s v=%s sm=%d" % [str(td.params.get("required_weapon", [])),
		str(td.value), int(td.stack_max)])
	var w11 := _fresh(&"W11_spirit_sword") as FlyingSwordWeapon
	_check("①W11 G=1：判定半径 9×1.2=10.8",
		w11 != null and w11.attach_trait(td) and absf(w11._sword_hit_radius() - 10.8) < 0.01,
		"r=%s" % str(w11._sword_hit_radius() if w11 != null else -1.0))
	_check("①W11 G=2：判定半径 9×1.4=12.6",
		w11.attach_trait(td) and absf(w11._sword_hit_radius() - 12.6) < 0.01,
		"r=%s" % str(w11._sword_hit_radius()))
	var w12 := _fresh(&"W12_ground_axe") as GroundAxeWeapon
	_check("①W12 G=1：震荡半径 96×1.15=110.4",
		w12 != null and w12.attach_trait(td) and absf(w12._shock_radius() - 110.4) < 0.01,
		"r=%s" % str(w12._shock_radius() if w12 != null else -1.0))
	_check("①W12 G=2：震荡半径 96×1.3=124.8",
		w12.attach_trait(td) and absf(w12._shock_radius() - 124.8) < 0.01,
		"r=%s" % str(w12._shock_radius()))
	var w13 := _fresh(&"W13_great_sword") as OrbitWeapon
	_check("①W13 G=1：斩击半径 190×1.2=228",
		w13 != null and w13.attach_trait(td) and absf(w13.effective_slash_radius() - 228.0) < 0.01,
		"r=%s" % str(w13.effective_slash_radius() if w13 != null else -1.0))
	_check("①W13 G=2：斩击半径 190×1.4=266",
		w13.attach_trait(td) and absf(w13.effective_slash_radius() - 266.0) < 0.01,
		"r=%s" % str(w13.effective_slash_radius()))


# ── ② ORBIT_LINK 扩五武器 + 数量帽 ───────────────────────────────
func _case2_orbit_link() -> void:
	print("── ② MEC_ORBIT_LINK 扩五武器 + 数量帽（§4.3：金 3 层 raw 12 → 额外帽） ──")
	var td := _trait(&"MEC_ORBIT_LINK")
	_check("②tres：required_weapon 五武器 + 描述「近战/法器武器的攻击体 +1/层」+ value 1.45",
		_string_array_eq(td.params.get("required_weapon", []), WANTED_FIVE)
		and String(td.description).contains("近战/法器武器的攻击体 +1/层")
		and is_equal_approx(float(td.value), 1.45),
		"req=%s desc=%s" % [str(td.params.get("required_weapon", [])), str(td.description)])
	var w12 := _fresh(&"W12_ground_axe") as GroundAxeWeapon
	var gold := _gold_link()
	_attach_n(w12, gold, 3)
	_check("②金 3 层 link raw：_orbit_link_count=12（round(1.45×2.6)=4/层 ×3）",
		w12 != null and w12._orbit_link_count() == 12,
		"link=%s" % str(w12._orbit_link_count() if w12 != null else -1))
	_check("②金 3 层 W12 帽：额外 min(12,3)=3 斧（axe_count=1+3=4——§4.3 额外 +3 封顶）",
		w12.axe_count() == 4 and mini(w12._orbit_link_count(), 3) == 3,
		"extra=%d count=%d" % [w12.axe_count() - 1, w12.axe_count()])
	var w11 := _fresh(&"W11_spirit_sword") as FlyingSwordWeapon
	_attach_n(w11, _gold_link(), 3)
	_check("②金 3 层 W11 帽：齐射 1+min(12,6)=7 剑（额外 +6 封顶）",
		w11 != null and w11._volley_sword_count() == 7,
		"volley=%s" % str(w11._volley_sword_count() if w11 != null else -1))
	var w13 := _fresh(&"W13_great_sword") as OrbitWeapon
	_attach_n(w13, _gold_link(), 3)
	if w13 != null:
		w13._queue_phantom_slashes(0.0)
	_check("②金 3 层 W13 帽：幻影斩 min(12,2)=2 道（额外 +2 封顶）",
		w13 != null and w13._phantom_queue.size() == 2,
		"phantom=%s" % str(w13._phantom_queue.size() if w13 != null else -1))


# ── ③ SLASH_TEMPO 加 W13 ─────────────────────────────────────────
func _case3_slash_tempo() -> void:
	print("── ③ MEC_SLASH_TEMPO required_weapon→[W9,W13] + 上架门（§4.2） ──")
	var td := _trait(&"MEC_SLASH_TEMPO")
	_check("③tres：required_weapon 数组化 [W9,W13]（W8/W11/W12 节奏由 AFF_CDR 承载）"
		+ " + 池/值不动（add_cdr 0.15）",
		_string_array_eq(td.params.get("required_weapon", []),
			[&"W9_arc_slash", &"W13_great_sword"])
		and String(td.pool_id) == "add_cdr" and is_equal_approx(float(td.value), 0.15),
		"req=%s pool=%s v=%s" % [str(td.params.get("required_weapon", [])),
		str(td.pool_id), str(td.value)])
	var w9 := _fresh(&"W9_arc_slash")
	var w13 := _fresh(&"W13_great_sword")
	var w8 := _fresh(&"W8_orbit_field")
	var w11 := _fresh(&"W11_spirit_sword")
	var w12 := _fresh(&"W12_ground_axe")
	_check("③上架门：W9 ✓ / W13 ✓ / W8 ✗ / W11 ✗ / W12 ✗",
		CardGenerator.mount_gate_allows(td, w9)
		and CardGenerator.mount_gate_allows(td, w13)
		and not CardGenerator.mount_gate_allows(td, w8)
		and not CardGenerator.mount_gate_allows(td, w11)
		and not CardGenerator.mount_gate_allows(td, w12),
		"w9=%s w13=%s w8=%s w11=%s w12=%s" % [
			str(CardGenerator.mount_gate_allows(td, w9)),
			str(CardGenerator.mount_gate_allows(td, w13)),
			str(CardGenerator.mount_gate_allows(td, w8)),
			str(CardGenerator.mount_gate_allows(td, w11)),
			str(CardGenerator.mount_gate_allows(td, w12))])


# ── ④ FRACTAL 门扩 form3 ─────────────────────────────────────────
func _case4_fractal_gate() -> void:
	print("── ④ MEC_FRACTAL required_forms→[0,2,3] + 五武器/W1 门（§4.5） ──")
	var td := _trait(&"MEC_FRACTAL")
	_check("④tres：required_forms=[0,2,3] + inheritable=true（R187 锁） + hooks [ON_EXPIRE]",
		_int_array_eq(td.params.get("required_forms", []), [0, 2, 3])
		and bool(td.inheritable) and _int_array_eq(td.event_hooks, [5]),
		"forms=%s inh=%s hooks=%s" % [str(td.params.get("required_forms", [])),
		str(td.inheritable), str(td.event_hooks)])
	var w8 := _fresh(&"W8_orbit_field")
	var w9 := _fresh(&"W9_arc_slash")
	var w11 := _fresh(&"W11_spirit_sword")
	var w12 := _fresh(&"W12_ground_axe")
	var w13 := _fresh(&"W13_great_sword")
	var w1 := _fresh(&"W1_pistol")
	_check("④门：W8/W9/W11/W12/W13 全过（form 3）+ W1 过（form 0 保持）",
		CardGenerator.mount_gate_allows(td, w8)
		and CardGenerator.mount_gate_allows(td, w9)
		and CardGenerator.mount_gate_allows(td, w11)
		and CardGenerator.mount_gate_allows(td, w12)
		and CardGenerator.mount_gate_allows(td, w13)
		and CardGenerator.mount_gate_allows(td, w1),
		"w8=%s w9=%s w11=%s w12=%s w13=%s w1=%s" % [
			str(CardGenerator.mount_gate_allows(td, w8)),
			str(CardGenerator.mount_gate_allows(td, w9)),
			str(CardGenerator.mount_gate_allows(td, w11)),
			str(CardGenerator.mount_gate_allows(td, w12)),
			str(CardGenerator.mount_gate_allows(td, w13)),
			str(CardGenerator.mount_gate_allows(td, w1))])


# ── ⑤ 通道 B 单元（EF_FRACTAL melee 臂） ─────────────────────────
func _melee_dispatch(p_weapon: WeaponBase, p_melee: Node2D) -> TraitContext:
	_bump()
	var tctx := TraitContext.new()
	tctx.event = GameConst.TraitEvent.ON_EXPIRE
	tctx.weapon = p_weapon
	tctx.melee = p_melee
	p_weapon.trait_stack.dispatch(GameConst.TraitEvent.ON_EXPIRE, tctx)
	return tctx


func _case5_channel_b_unit() -> void:
	print("── ⑤ 通道 B 单元：melee 臂同参数表 + echo 深度读 melee.generation（§4.5-2） ──")
	var w13 := _fresh(&"W13_great_sword") as OrbitWeapon
	var frac_ok: bool = w13.attach_trait(_trait(&"MEC_FRACTAL"))
	var arc := ArcSlash.new()                      # 未入树——仅作 .get("generation") 载体
	# 守卫回归：双宿主缺位（melee/projectile 皆 null）→ 早退、两侧请求均空
	var tnull := _melee_dispatch(w13, null)
	_check("⑤守卫不放宽回归：双宿主缺位早退（melee_split_request 与 split_request 皆空）",
		frac_ok and tnull.melee_split_request.is_empty() and tnull.split_request.is_empty(),
		"melee_req=%s proj_req=%s" % [str(tnull.melee_split_request),
		str(tnull.split_request)])
	# 1 层表：2 枚/±28°/继承 0.4（写 melee_split_request、不写 split_request）
	var t1 := _melee_dispatch(w13, arc)
	var r1: Dictionary = t1.melee_split_request
	_check("⑤1 层 melee 臂：{count 2, spread ±28°, inherit 0.4, echo false} 且 split_request 恒空",
		int(r1.get("count", 0)) == 2 and is_equal_approx(float(r1.get("spread_deg", 0.0)), 28.0)
		and is_equal_approx(float(r1.get("inherit_ratio", 0.0)), 0.4)
		and not bool(r1.get("echo", true)) and t1.split_request.is_empty(),
		"req=%s" % str(r1))
	# 2 层表：3 枚/±22°/继承 0.45
	w13.attach_trait(_trait(&"MEC_FRACTAL"))
	var t2 := _melee_dispatch(w13, arc)
	var r2: Dictionary = t2.melee_split_request
	_check("⑤2 层 melee 臂：{count 3, spread ±22°, inherit 0.45}",
		int(r2.get("count", 0)) == 3 and is_equal_approx(float(r2.get("spread_deg", 0.0)), 22.0)
		and is_equal_approx(float(r2.get("inherit_ratio", 0.0)), 0.45),
		"req=%s" % str(r2))
	# TH_FRACTAL_ECHO：深度源 = melee.generation（子斩 gen+1）；gen2 → 子 gen3 ≥3 → echo
	w13.data.threshold_traits.append({
		"threshold_id": &"TH_FRACTAL_ECHO", "metric": "split_depth", "threshold": 3.0,
		"effect_id": &"EF_FRACTAL", "params": {"inherit_ratio": 0.6},
	})
	arc.generation = 2
	var t3 := _melee_dispatch(w13, arc)
	var r3: Dictionary = t3.melee_split_request
	_check("⑤echo 复活：melee gen=2（子斩 gen3）→ echo=true + inherit 抬 0.6",
		bool(r3.get("echo", false)) and is_equal_approx(float(r3.get("inherit_ratio", 0.0)), 0.6),
		"req=%s" % str(r3))
	arc.generation = 1
	var t4 := _melee_dispatch(w13, arc)
	var r4: Dictionary = t4.melee_split_request
	_check("⑤阈值下：melee gen=1（子斩 gen2 <3）→ echo=false + inherit 保持 0.45",
		not bool(r4.get("echo", true))
		and is_equal_approx(float(r4.get("inherit_ratio", 0.0)), 0.45),
		"req=%s" % str(r4))
	# OrbitField 宿主无 generation 键 → 深度 0（母引爆）→ echo 不触发、请求照常
	var fld := OrbitField.new()
	var t5 := _melee_dispatch(w13, fld)
	var r5: Dictionary = t5.melee_split_request
	_check("⑤OrbitField 宿主：无代数键 = 深度 0 → echo=false + 请求照常（count 3）",
		not bool(r5.get("echo", true)) and int(r5.get("count", 0)) == 3,
		"req=%s" % str(r5))
	arc.free()
	fld.free()


# ── ⑥ 通道 A 集成（W12 子斧 + W11 迷你飞剑） ─────────────────────
func _case6_channel_a() -> void:
	print("── ⑥ 通道 A：W12×FRACTAL 子斧 + W11 迷你飞剑（§9.1 buff ⑦） ──")
	var axe := _fresh(&"W12_ground_axe") as GroundAxeWeapon
	var frac_ok: bool = axe.attach_trait(_trait(&"MEC_FRACTAL"))
	_spawn_e(Vector2(560.0, 640.0))
	_fire(axe)
	var guard := 0
	while guard < 300 and int(axe.land_count) == 0:
		var flying := _live_projs("_flight_axe")
		if flying.is_empty():
			break
		_bump()
		for a in flying:
			(a as ProjectileBase).tick(DT)
		guard += 1
	var mother_land: Vector2 = axe.last_land_pos
	var children := _live_projs("_flight_axe")
	var child_ok := frac_ok and children.size() == 2 and int(axe.land_count) == 1
	var tp_ok := children.size() == 2
	var tp_detail := ""
	for c in children:
		var cp := c as ProjectileBase
		if not (bool(cp.get("_flight_axe")) and int(cp.get("generation")) == 3
				and is_equal_approx(float(cp.get("_shock_scale")), 0.4)
				and absf(float(cp.get("_panel_base_atk")) - 22.4) < 0.01):
			child_ok = false                       # 56 面板 ×0.4 = 22.4
		var ctp: Vector2 = cp.get("_target_point")
		var d := ctp.distance_to(mother_land)
		if d < 119.0 or d > 121.0:
			tp_ok = false                          # 落点 = 母落点 + 出射方向 ×120（tol 1px）
		tp_detail += "%.2fpx " % d
	_check("⑥W12 母斧落地碎裂 2 子斧：flight_axe 继承 + generation=3 封堵 + shock_scale 0.4 + 面板 22.4",
		child_ok, "n=%d land=%d" % [children.size(), int(axe.land_count)])
	_check("⑥子斧落点 = 母斧落点 + 出射方向 ×120（tol 1px）", tp_ok, "距母落点=%s" % tp_detail)
	var land0: int = DebugStats.get_counter(&"axe_landings")
	var rej0: int = DebugStats.get_counter(&"split_rejected_generation")
	_run_axes_to_completion()
	var land_d: int = DebugStats.get_counter(&"axe_landings") - land0
	var rej_d: int = DebugStats.get_counter(&"split_rejected_generation") - rej0
	_check("⑥子斧二次进入：landings Δ2 + R=96×0.4=38.4 + scale 0.4 读回",
		land_d == 2 and absf(axe.last_land_shock_radius - 38.4) < 0.01
		and is_equal_approx(axe.last_land_shock_scale, 0.4),
		"Δland=%d R=%.3f scale=%.3f" % [land_d, axe.last_land_shock_radius,
		axe.last_land_shock_scale])
	_check("⑥子斧再裂封堵：split_rejected_generation Δ2 + 无 live 斧 + land_count=3",
		rej_d == 2 and _live_projs("_flight_axe").is_empty() and int(axe.land_count) == 3,
		"rejΔ=%d live=%d land=%d" % [rej_d, _live_projs("_flight_axe").size(),
		int(axe.land_count)])
	# W11：子代 = 迷你飞剑（flight_sword 继承，generation=1）
	var w11 := _fresh(&"W11_spirit_sword") as FlyingSwordWeapon
	var frac2_ok: bool = w11.attach_trait(_trait(&"MEC_FRACTAL"))
	_spawn_e(PLAYER_POS + Vector2(200.0, 0.0))
	_fire(w11)
	var swords := _live_projs("_flight_sword")
	var g2 := 0
	while g2 < 120 and swords.size() == 1 and bool(swords[0].get("_live")):
		_bump()
		(swords[0] as ProjectileBase).tick(DT)
		g2 += 1
	var kids := _live_projs("_flight_sword")
	var kids_ok := frac2_ok and kids.size() == 2
	for k in kids:
		if not (bool(k.get("_flight_sword")) and int(k.get("generation")) == 1):
			kids_ok = false
	_check("⑥W11 母剑命中回收 → 恰 2 子代迷你飞剑（flight_sword=true + generation=1）",
		kids_ok, "n=%d frac=%s" % [kids.size(), str(frac2_ok)])
	_run_swords_to_completion()
	_check("⑥W11 子代链收束：代数闸 ≤3 走完后全场无 live 飞剑",
		_live_projs("_flight_sword").is_empty(),
		"live=%d" % _live_projs("_flight_sword").size())


# ── ⑦ W8 子引爆（通道 B 消费端，§4.5-4 终审①） ───────────────────
func _case7_w8_child_detonate() -> void:
	print("── ⑦ W8×FRACTAL 子引爆：数量/半径 + 无孙代（纯结算体结构断言） ──")
	var w8 := _fresh(&"W8_orbit_field") as OrbitWeapon
	var frac_ok: bool = w8.attach_trait(_trait(&"MEC_FRACTAL"))
	var center := Vector2(600.0, 400.0)
	var dir_c := Vector2.from_angle(deg_to_rad(-28.0))   # 子引爆角域（count 2 → ±28°）
	var e_a := _spawn_e(center)                           # 中心：母 + 双子重叠（幂等闸首hit）
	var e_b := _spawn_e(center + Vector2.from_angle(PI) * 100.0)          # 母-only（100≤110）
	var e_c := _spawn_e(center + dir_c * 113.0)           # 子-only（113>110；|113-48|=65≤66.8）
	var e_d := _spawn_e(center + dir_c * 74.4)            # 孙代角域（74.4 ≤110）
	w8._ensure_orbit_field()
	var field := w8.orbit_field
	var hp_a0 := float(e_a.hp)
	var hp_b0 := float(e_b.hp)
	var hp_c0 := float(e_c.hp)
	var hp_d0 := float(e_d.hp)
	var settle0: int = DebugStats.get_counter(&"w8_detonation_aoe_targets")
	_bump()
	field._detonate_aoe(center, 96.0, 50.0)
	_check("⑦母-only 域：B（100px 胞侧）恰 50（子引爆 ±28° 域外溢为零）",
		frac_ok and absf((hp_b0 - float(e_b.hp)) - 50.0) < 0.6,
		"Δhp=%s frac=%s" % [str(hp_b0 - float(e_b.hp)), str(frac_ok)])
	_check("⑦子-only 域：C（113px @-28°，距子心 65≤52.8+14）恰 20（0.4×50——子引爆半径/伤害正确）",
		absf((hp_c0 - float(e_c.hp)) - 20.0) < 0.6,
		"Δhp=%s" % str(hp_c0 - float(e_c.hp)))
	_check("⑦重叠中心幂等：A 恰 50（母+双子同帧 (source,target,frame) 折返单次）",
		absf((hp_a0 - float(e_a.hp)) - 50.0) < 0.6,
		"Δhp=%s" % str(hp_a0 - float(e_a.hp)))
	var settle_d: int = DebugStats.get_counter(&"w8_detonation_aoe_targets") - settle0
	_check("⑦结算次数恰 3（粗相候选 Δ=4+3+3=10）：一次母引爆 + 两枚子引爆，无孙代结算",
		settle_d == 10, "settleΔ=%d" % settle_d)
	# 结构断言（终审①）：_detonate_settle 纯结算体无 ON_EXPIRE 派发面；
	# _detonate_aoe = settle + consume；_consume_melee_split 子代只走 settle 不递归 aoe。
	var src := ""
	var f := FileAccess.open("res://scripts/combat/weapon/melee/orbit_field.gd", FileAccess.READ)
	if f != null:
		src = f.get_as_text()
		f.close()
	var settle_body := _strip_comments(_func_body(src, "_detonate_settle"))
	var aoe_body := _strip_comments(_func_body(src, "_detonate_aoe"))
	var consume_body := _strip_comments(_func_body(src, "_consume_melee_split"))
	var struct_ok := not settle_body.is_empty() and not aoe_body.is_empty() \
		and not consume_body.is_empty() \
		and settle_body.find("dispatch(") < 0 and settle_body.find("ON_EXPIRE") < 0 \
		and settle_body.find("_consume_melee_split") < 0 \
		and settle_body.find("melee_split_request") < 0 \
		and aoe_body.find("_detonate_settle") >= 0 \
		and aoe_body.find("_consume_melee_split") >= 0 \
		and consume_body.find("_detonate_settle") >= 0 \
		and consume_body.find("_detonate_aoe(") < 0
	_check("⑦结构断言：_detonate_settle 无 ON_EXPIRE 派发面 + _detonate_aoe=settle+consume"
		+ " + 子代只走纯结算体不递归", struct_ok,
		"settle=%d aoe=%d consume=%d" % [settle_body.length(), aoe_body.length(),
		consume_body.length()])
	# 负控 + 事后稳定：再派发仍产出请求（非「消费一次即哑」）；帧推进零增量
	for i in range(3):
		_bump()
	var tctx := _melee_dispatch(w8, field)
	var ctrl_ok := int(tctx.melee_split_request.get("count", 0)) == 2 \
		and is_equal_approx(float(tctx.melee_split_request.get("inherit_ratio", 0.0)), 0.4) \
		and DebugStats.get_counter(&"w8_detonation_aoe_targets") - settle0 == 10 \
		and absf((hp_a0 - float(e_a.hp)) - 50.0) < 0.6 \
		and absf((hp_d0 - float(e_d.hp)) - 50.0) < 0.6
	_check("⑦负控+稳定：事后再派发仍写 count 2/0.4 请求（栈未耗尽）+ 帧推进后计数/血量零增量",
		ctrl_ok, "req=%s settleΔ=%d Δd=%s" % [str(tctx.melee_split_request),
		DebugStats.get_counter(&"w8_detonation_aoe_targets") - settle0,
		str(hp_d0 - float(e_d.hp))])


# ── ⑧ AFF_RANGE / MEC_KNOCK 新消费点反死卡 ───────────────────────
func _case8_range_knock() -> void:
	print("── ⑧ AFF_RANGE/MEC_KNOCK 新消费点（终审②反死卡） ──")
	var w11 := _fresh(&"W11_spirit_sword") as FlyingSwordWeapon
	var foe := _spawn_e(PLAYER_POS + Vector2(200.0, 0.0))
	var range0 := w11._sword_range()
	var kb0 := w11.knockback_force()
	_fire(w11)
	var swords := _live_projs("_flight_sword")
	var life0 := -1.0
	if not swords.is_empty():
		life0 = float((swords[0] as ProjectileBase).get("lifetime_left"))
		(swords[0] as ProjectileBase).nullify()
	_check("⑧W11 基线：射程 420 + 剑体击退基础 0（ballistic.knockback 缺键）+ 寿命 0.5616",
		w11 != null and is_equal_approx(range0, 420.0) and absf(kb0) < 0.001
		and absf(life0 - 420.0 / 860.0 * 1.15) < 0.005,
		"range=%.2f kb=%.2f life=%.4f" % [range0, kb0, life0])
	_attach_n(w11, _trait(&"AFF_RANGE"), 3)
	var range1 := w11._sword_range()
	_fire(w11)
	swords = _live_projs("_flight_sword")
	var life1 := -1.0
	if not swords.is_empty():
		life1 = float((swords[0] as ProjectileBase).get("lifetime_left"))
		(swords[0] as ProjectileBase).nullify()
	_check("⑧AFF_RANGE 3 层→W11 飞行射程 420×1.54=646.8 + 寿命随射程延长（0.8651>0.5616×1.4）",
		absf(range1 - 646.8) < 0.05 and life1 > life0 * 1.4
		and absf(life1 - 646.8 / 860.0 * 1.15) < 0.005,
		"range=%.3f life=%.4f" % [range1, life1])
	var knock_ok: bool = w11.attach_trait(_trait(&"MEC_KNOCK"))
	var kb1 := w11.knockback_force()
	_fire(w11)
	_run_swords_to_completion()
	var kv := foe.get("knock_vel") as Vector2
	_check("⑧MEC_KNOCK 1 层→W11 剑体击退=0+60=60 + 命中实测 knock_vel 540（60×9，弹道向）",
		knock_ok and absf(kb1 - 60.0) < 0.01 and absf(kv.length() - 540.0) < 1.0
		and kv.x > kv.length() * 0.99,
		"kb=%.2f |kv|=%.2f frac=%s" % [kb1, kv.length(), str(knock_ok)])
	var w12 := _fresh(&"W12_ground_axe") as GroundAxeWeapon
	_attach_n(w12, _trait(&"AFF_RANGE"), 3)
	var shock1 := w12._shock_radius()
	var knock2_ok: bool = w12.attach_trait(_trait(&"MEC_KNOCK"))
	var kb2 := w12._axe_knockback()
	_check("⑧AFF_RANGE 3 层→W12 震荡半径 96×1.54=147.84 + MEC_KNOCK 1 层→击退 80+60=140",
		absf(shock1 - 147.84) < 0.05 and knock2_ok and absf(kb2 - 140.0) < 0.01,
		"shock=%.3f kb=%.2f" % [shock1, kb2])
	var foe2 := _spawn_e(Vector2(560.0, 640.0))
	_fire(w12)
	_run_axes_to_completion()
	var kv2 := foe2.get("knock_vel") as Vector2
	var radial := (foe2.global_position - w12.last_land_pos).normalized()
	_check("⑧W12 落点实测：径向击退 knock_vel 1260（140×9，落点→目标心）",
		absf(kv2.length() - 1260.0) < 1.0 and kv2.normalized().dot(radial) > 0.99,
		"|kv|=%.2f dot=%.4f" % [kv2.length(),
		kv2.normalized().dot(radial) if kv2.length() > 0.01 else -1.0])
	_check("⑧反死卡门：AFF_RANGE 与 MEC_KNOCK 对 W11/W12 全部上架（mount_gate_allows）",
		CardGenerator.mount_gate_allows(_trait(&"AFF_RANGE"), w11)
		and CardGenerator.mount_gate_allows(_trait(&"AFF_RANGE"), w12)
		and CardGenerator.mount_gate_allows(_trait(&"MEC_KNOCK"), w11)
		and CardGenerator.mount_gate_allows(_trait(&"MEC_KNOCK"), w12),
		"r11=%s r12=%s k11=%s k12=%s" % [
			str(CardGenerator.mount_gate_allows(_trait(&"AFF_RANGE"), w11)),
			str(CardGenerator.mount_gate_allows(_trait(&"AFF_RANGE"), w12)),
			str(CardGenerator.mount_gate_allows(_trait(&"MEC_KNOCK"), w11)),
			str(CardGenerator.mount_gate_allows(_trait(&"MEC_KNOCK"), w12))])


# ── ⑨ 锁定不动 ──────────────────────────────────────────────────
func _case9_locks() -> void:
	print("── ⑨ 锁定不动：MEC_KNOCK 排除/形态门 + AFF_RANGE 门（§4.6） ──")
	var knock := _trait(&"MEC_KNOCK")
	var excluded: Array = knock.params.get("excluded_weapons", [])
	var ex_has_w9 := false
	for w in excluded:
		if String(w) == "W9_arc_slash":
			ex_has_w9 = true
	_check("⑨MEC_KNOCK 锁定：required_forms [0,2,3] + excluded_weapons 含 W9（本任务未动）",
		_int_array_eq(knock.params.get("required_forms", []), [0, 2, 3]) and ex_has_w9,
		"forms=%s excluded=%s" % [str(knock.params.get("required_forms", [])),
		str(excluded)])
	_check("⑨AFF_RANGE 门不动：required_forms [3]（W10 甩程走 add_boom_range 独立池）",
		_int_array_eq(_trait(&"AFF_RANGE").params.get("required_forms", []), [3]),
		"forms=%s" % str(_trait(&"AFF_RANGE").params.get("required_forms", [])))

# tests/runner/r243_boom_cases.gd
# R243 回旋刀（§5.1 前移闸 + §5.2 MEC_THROW_RANGE）用例体
#（入口运行时 load——cases 禁 test_ 前缀防电池 glob 误收）。
# 覆盖（设计 §9.1 test_r243_boom ①②③④⑤⑦ + 验收标准语义边界）：
# ① 前移闸·甩满翻相分裂：挂 EF_FRACTAL 桩翻相帧子代数=2、子代位≈甩满点非玩家位、
#    _boom_expire_fired 置位、ON_EXPIRE 恰派发一次、到手回收后不分裂
# ② 到手回收帧 ON_EXPIRE 不二次派发（_boom_expire_fired 守卫——防双发检测器=无闸 spy）
# ③ 无词条翻相零分裂行为不变（守卫不影响无词条路径——翻相 1 次 + 回收 0 次派发）
# ④ 寿命兜底路径（翻相前 EXPIRED）走原 _recycle 派发行为不变 + 非回旋弹 flag 恒 false 零波及
# ⑤ add_boom_range 三段链：0 层 380 / 1 层 448.4 / 3 层 585.2（tol 0.5）→
#    try_fire spawn "range" → 子弹 _boom_range 快照同值；add_spd 池隔离
# ⑥ MEC_THROW_RANGE.tres 卡面规格（pool 0 / add_boom_range 第 18 员 / 0.18 / 3 层 /
#    required_weapon W10 / rarity 1 / decay 0.85 / 描述）+ 全量校验绿
# ⑦ required_weapon 门：W1 桩拒、W10 正控放行
# ⑧ W10×FRACTAL×KILL_BLAST 双卡（killed_target 桩）：翻相帧 kill_blast 恰 +1 且
#    爆炸位=last_hit_pos（非翻相位）、分裂子代同帧生成、回手回收帧两计数均不再增
#    （防双炸回归）、无 killed_target 时 guard 不炸
# ⑨ 套件总项数断言（R231 假绿教训）
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const EXPECTED_TOTAL := 31

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _reg: DataRegistry = null
var _stubs: Array = []                       # 收尾 free（Node 桩——武器/玩家桩）
var _deps: Dictionary = {}                   # 武器 setup 依赖包（pool/grid 复用）


# ── 检测器桩 ──────────────────────────────────────────────────────
# ExpireSpy：无闸 ON_EXPIRE 计数器（直挂数组通道按 has_method(&"on_event") 派发）。
# 有意不带 TraitBase 的 E-03 帧闸/冷却闸——计的是「派发次数」本身：翻相 1 + 回收 0 =
# 前移闸语义；若守卫失效（回收帧二次派发）本计数即 +2（TraitBase 本体会被同帧闸遮蔽，
# 检测不到双发——故必须用裸 spy）。
class ExpireSpy extends RefCounted:
	var expire_count: int = 0

	func on_event(p_event: int, _p_ctx: TraitContext) -> void:
		if p_event == GameConst.TraitEvent.ON_EXPIRE:
			expire_count += 1


# BlastSpyWeapon：settle_aoe 记录桩——MEC_KILL_BLAST 副作用位（trait_effect_mech.gd:45）
# 的爆炸位/次数观测口（真件 settle_aoe 需网格+管线，桩只记录不结算）。
class BlastSpyWeapon extends WeaponBase:
	var blast_count: int = 0
	var last_blast_pos: Vector2 = Vector2(9999.0, 9999.0)

	func settle_aoe(p_pos: Vector2, _p_radius: float, _p_atk: float, _p_secondary: bool,
			_p_exclude: Node2D = null) -> void:
		blast_count += 1
		last_blast_pos = p_pos


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261008)
	_reg = DataRegistry.new()
	_reg.load_all("res://data/manifest.cfg")
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_case1_flip_split()
	_case2_no_redispatch()
	_case3_no_trait_unchanged()
	_case4_lifetime_fallback()
	_case5_range_chain()
	_case6_card_spec()
	_case7_mount_gate()
	_case8_double_card()
	_cleanup()
	_check("⑨ 套件总项数（EXPECTED=%d——R231 假绿教训）" % EXPECTED_TOTAL,
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


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R243BoomGameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.state = GameConst.GameStatus.MENU
	_gl.player.global_position = Vector2(360.0, 900.0)
	var grid: SpaceGrid = _gl.pools[&"enemy"].get("grid")
	_deps = {
		"projectile_pool": _gl.pools[&"projectile"],
		"enemy_grid": grid,
		"pipeline": null,
	}


func _cleanup() -> void:
	for s in _stubs:
		if s != null and s is Node and is_instance_valid(s):
			(s as Node).free()
	_stubs.clear()
	if _gl != null:
		_gl.free()
		_gl = null


# ── 夹具 ──────────────────────────────────────────────────────────
func _fractal_tb() -> TraitBase:
	# 真卡 MEC_FRACTAL（EF_FRACTAL：ON_EXPIRE 写 split_request 2 枚/±28°/继承 0.4）
	var tb := TraitBase.new()
	tb.setup(load("res://resources/traits/MEC_FRACTAL.tres") as TraitData)
	return tb


func _kill_blast_tb() -> TraitBase:
	# 真卡 MEC_KILL_BLAST（EF_MECH ON_EXPIRE 臂：killed_target 时 settle_aoe(last_hit_pos)）
	var tb := TraitBase.new()
	tb.setup(load("res://resources/traits/MEC_KILL_BLAST.tres") as TraitData)
	return tb


func _throw_range_td() -> TraitData:
	return load("res://resources/traits/MEC_THROW_RANGE.tres") as TraitData


func _spawn_boom(p_pos: Vector2, p_vel: Vector2, p_extra: Dictionary = {},
		p_lifetime: float = 5.0, p_range: float = 380.0) -> ProjectileBase:
	# 直连池直发回旋弹（r241_boomfix 同款口径；p_extra 合并 weapon_ref/traits 等扩展键）
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var p := pool.acquire() as ProjectileBase
	p.pool = pool
	p.enemy_grid = _gl.pools[&"enemy"].get("grid")
	var params := {
		"position": p_pos,
		"velocity": p_vel,
		"lifetime": p_lifetime,
		"range": p_range,
		"pierce": 1,
		"bounces": 0,
		"boomerang": true,
		"hitbox_radius": 7.0,
		"element": GameConst.Element.KIN,
		"attach_value": 0.0,
		"generation": 0,
		"panel_snapshot": {"base_atk": 100.0},
		"team": 0,
	}
	params.merge(p_extra)
	p.spawn(params)
	return p


func _spawn_straight(p_pos: Vector2, p_extra: Dictionary = {},
		p_lifetime: float = 0.2) -> ProjectileBase:
	# 非回旋直弹（flag 恒 false 波及面验证）
	var params := {"boomerang": false, "velocity": Vector2(300.0, 0.0)}
	params.merge(p_extra)
	return _spawn_boom(p_pos, Vector2(300.0, 0.0), params, p_lifetime)


func _gen1_children() -> Array:
	var out: Array = []
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		var pb := p as ProjectileBase
		if pb != null and int(pb.get("generation")) == 1:
			out.append(pb)
	return out


func _release_all(p_list: Array) -> void:
	for v in p_list:
		if v != null and is_instance_valid(v) and bool(v.get("_live")):
			(v.pool as ProjectilePool).release(v)


func _release_proj(p: ProjectileBase) -> void:
	if p != null and is_instance_valid(p) and bool(p.get("_live")):
		(p.pool as ProjectilePool).release(p)


func _tick_to_flip(p: ProjectileBase, p_cap: int = 240) -> int:
	var i := 0
	while i < p_cap and bool(p.get("_live")) and int(p.get("_boom_phase")) == 0:
		p.tick(DT)
		i += 1
	return i


func _tick_to_recycle(p: ProjectileBase, p_cap: int = 600) -> int:
	var i := 0
	while i < p_cap and bool(p.get("_live")):
		p.tick(DT)
		i += 1
	return i


func _mk_weapon(p_wd: WeaponData) -> WeaponBase:
	var w := BallisticWeapon.new()
	w.setup(p_wd, null, _deps)
	_stubs.append(w)
	return w


func _approx(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol


# ═══ ① 前移闸·甩满翻相分裂（EF_FRACTAL 桩） ══════════════════════════
func _case1_flip_split() -> void:
	print("── ① 前移闸：甩满翻相处分裂（EF_FRACTAL 桩） ──")
	var spy := ExpireSpy.new()
	var pm := _spawn_boom(Vector2(360.0, 360.0), Vector2(520.0, 0.0),
		{"traits": [_fractal_tb(), spy]})
	var steps := _tick_to_flip(pm)
	var origin: Vector2 = pm.get("_boom_origin")
	var kids := _gen1_children()
	_check("①a 挂 EF_FRACTAL 翻相帧子代数=2（phase 翻到位）",
		int(pm.get("_boom_phase")) == 1 and steps < 240 and kids.size() == 2,
		"steps=%d kids=%d phase=%s" % [steps, kids.size(), str(pm.get("_boom_phase"))])
	var at_boom := true
	var away_from_player := true
	for k in kids:
		var d: float = (k as Node2D).global_position.distance_to(origin)
		var dp: float = (k as Node2D).global_position.distance_to(_gl.player.global_position)
		if not _approx(d, 380.0, 30.0):
			at_boom = false
		if dp <= 300.0:
			away_from_player = false
	_check("①b 子代位≈甩满点（距原点 380±30）且非玩家位（距玩家>300）",
		kids.size() == 2 and at_boom and away_from_player,
		"origin=%s kid0=%s player=%s" % [str(origin),
		str(kids[0].global_position if not kids.is_empty() else Vector2.INF),
		str(_gl.player.global_position)])
	_check("①c 翻相帧 _boom_expire_fired 已置位（前移闸旗标）",
		bool(pm.get("_boom_expire_fired")))
	_check("①d 翻相帧 ON_EXPIRE 恰派发一次（spy==1）", spy.expire_count == 1,
		"spy=%d" % spy.expire_count)
	_tick_to_recycle(pm)
	var kids_after := _gen1_children()
	_check("①e 到手回收后子代数仍=2（回收帧不分裂）",
		not bool(pm.get("_live")) and kids_after.size() == 2,
		"live=%s kids=%d" % [str(bool(pm.get("_live"))), kids_after.size()])
	_release_proj(pm)
	_release_all(kids_after)


# ═══ ② 到手回收 ON_EXPIRE 不二次派发（守卫） ═════════════════════════
func _case2_no_redispatch() -> void:
	print("── ② 到手回收帧 ON_EXPIRE 不二次派发（_boom_expire_fired 守卫） ──")
	var spy := ExpireSpy.new()
	var pm := _spawn_boom(Vector2(360.0, 300.0), Vector2(520.0, 0.0),
		{"traits": [_fractal_tb(), spy]})
	_tick_to_flip(pm)
	var at_flip := spy.expire_count
	var forced0 := DebugStats.get_counter(&"recycle_reason_4")   # RecycleReason.FORCED=4
	_tick_to_recycle(pm)
	var forced_delta := DebugStats.get_counter(&"recycle_reason_4") - forced0
	_check("②a 到手回收后 ON_EXPIRE 不二次派发（spy 翻相 1 → 回收后仍 1）",
		at_flip == 1 and spy.expire_count == 1,
		"flip=%d end=%d" % [at_flip, spy.expire_count])
	_check("②b 母弹确已到手回收（FORCED 收回路径计数 +1——非寿命兜底 EXPIRED）",
		not bool(pm.get("_live")) and forced_delta >= 1,
		"live=%s forced=%d" % [str(bool(pm.get("_live"))), forced_delta])
	_release_proj(pm)
	_release_all(_gen1_children())


# ═══ ③ 无词条翻相零分裂、行为不变 ═══════════════════════════════════
func _case3_no_trait_unchanged() -> void:
	print("── ③ 无词条翻相零分裂（守卫不影响无词条路径） ──")
	var spy := ExpireSpy.new()
	var pm := _spawn_boom(Vector2(360.0, 360.0), Vector2(520.0, 0.0), {"traits": [spy]})
	var steps := _tick_to_flip(pm)
	_check("③a 无词条翻相零分裂（gen1==0）且翻相仍发生（R78 定距语义保持）",
		int(pm.get("_boom_phase")) == 1 and steps < 240 and _gen1_children().is_empty(),
		"steps=%d kids=%d" % [steps, _gen1_children().size()])
	_tick_to_recycle(pm)
	_check("③b 到手回收后仍零分裂且已回收", not bool(pm.get("_live"))
		and _gen1_children().is_empty(),
		"live=%s kids=%d" % [str(bool(pm.get("_live"))), _gen1_children().size()])
	_check("③c 无词条全寿命 ON_EXPIRE 恰 1 次（翻相 1+回收 0——守卫路径零额外派发）",
		spy.expire_count == 1, "spy=%d" % spy.expire_count)
	_release_proj(pm)


# ═══ ④ 寿命兜底走原路 + 非回旋零波及 ═════════════════════════════════
func _case4_lifetime_fallback() -> void:
	print("── ④ 寿命兜底（翻相前 EXPIRED）原 _recycle 派发 + 非回旋零波及 ──")
	# ④a/④b：翻相前寿命耗尽（0.3s×~500px/s≈150px < 380 甩满）——_recycle 派发 ON_EXPIRE
	# 行为不变（flag 未置位 → 原路径），分裂落在消亡位
	var spy := ExpireSpy.new()
	var pm := _spawn_boom(Vector2(360.0, 360.0), Vector2(520.0, 0.0),
		{"traits": [_fractal_tb(), spy]}, 0.3)
	var origin: Vector2 = pm.get("_boom_origin")
	_tick_to_recycle(pm)
	var kids := _gen1_children()
	_check("④a 翻相前寿命兜底：_recycle 派发 ON_EXPIRE（spy==1）+ 分裂 2 枚（原行为不变）",
		spy.expire_count == 1 and kids.size() == 2,
		"spy=%d kids=%d" % [spy.expire_count, kids.size()])
	var near_death := true
	for k in kids:
		if (k as Node2D).global_position.distance_to(origin) >= 300.0:
			near_death = false
	_check("④b 分裂位=消亡位（距原点<300，非甩满点 380——未前移未翻相）",
		kids.size() == 2 and near_death, "origin=%s" % str(origin))
	_release_proj(pm)
	_release_all(kids)
	# ④c：非回旋弹 flag 恒 false——寿命耗尽走 _recycle 原派发（1 次）+ 分裂照常
	var spy2 := ExpireSpy.new()
	var ps := _spawn_straight(Vector2(360.0, 400.0), {"traits": [_fractal_tb(), spy2]})
	_tick_to_recycle(ps)
	var kids2 := _gen1_children()
	_check("④c 非回旋弹 flag 恒 false 零波及：_recycle 派发恰 1 次 + 分裂 2 枚不变",
		spy2.expire_count == 1 and kids2.size() == 2,
		"spy=%d kids=%d" % [spy2.expire_count, kids2.size()])
	_release_proj(ps)
	_release_all(kids2)


# ═══ ⑤ add_boom_range 消费链三段同值 ═════════════════════════════════
func _case5_range_chain() -> void:
	print("── ⑤ MEC_THROW_RANGE：_range()→spawn \"range\"→_boom_range 三段同值 ──")
	var wd10: WeaponData = _reg.get_weapon(&"W10_boomerang")
	var td := _throw_range_td()
	var w10 := _mk_weapon(wd10)
	_check("⑤a 0 层 _range()=380（纯表读，池空乘 1.0）",
		_approx(w10._range(), 380.0, 0.5), "r=%s" % str(w10._range()))
	w10.trait_stack.attach(td)
	_check("⑤b 1 层 _range()=448.4（380×1.18）",
		_approx(w10._range(), 448.4, 0.5), "r=%s" % str(w10._range()))
	w10.trait_stack.attach(td)
	w10.trait_stack.attach(td)
	_check("⑤c 3 层 _range()=585.2（380×1.54，tol 0.5——ask 口径）",
		_approx(w10._range(), 585.2, 0.5), "r=%s" % str(w10._range()))
	var fired: bool = w10.try_fire()
	var spawned: ProjectileBase = null
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		var pb := p as ProjectileBase
		if pb != null and int(pb.get("weapon_uid")) == int(w10.uid) \
				and int(pb.get("generation")) == 0:
			spawned = pb
			break
	_check("⑤d 消费链三段同值：try_fire spawn → 子弹 _boom_range 快照=585.2（地板 120 不触）",
		fired and spawned != null and _approx(float(spawned.get("_boom_range")), 585.2, 0.5),
		"fired=%s boom_range=%s" % [str(fired),
		str(float(spawned.get("_boom_range")) if spawned != null else -1.0)])
	_release_proj(spawned)
	# 池隔离：只有 add_boom_range 动甩程——挂 add_spd（AFF_PROJ_SPD）后 _range 不变
	var spd_tb := TraitBase.new()
	spd_tb.setup(load("res://resources/traits/AFF_PROJ_SPD.tres") as TraitData)
	w10.trait_stack.attach(spd_tb.data)
	_check("⑤e 池隔离：挂 add_spd 后 _range() 仍 585.2（add_boom_range 单源消费）",
		_approx(w10._range(), 585.2, 0.5), "r=%s" % str(w10._range()))
	# 直弹武器零影响：W1 桩（required_weapon 门拒挂 → 池空乘 1.0 表值不变）
	var w1 := _mk_weapon(_reg.get_weapon(&"W1_pistol"))
	_check("⑤f 直弹武器（W1 桩）_range()=表值 680（无此池乘 1.0 零影响）",
		_approx(w1._range(), 680.0, 0.5), "r=%s" % str(w1._range()))


# ═══ ⑥ MEC_THROW_RANGE.tres 卡面规格 ═════════════════════════════════
func _case6_card_spec() -> void:
	print("── ⑥ MEC_THROW_RANGE.tres 规格 + 注册表 + 全量校验 ──")
	var td := _throw_range_td()
	_check("⑥a 卡面数值键：pool=0/pool_id=add_boom_range/value=0.18/stack_max=3/rarity=1/decay=0.85",
		td != null and int(td.pool) == GameConst.PoolClass.ADD
		and String(td.pool_id) == "add_boom_range"
		and is_equal_approx(td.value, 0.18) and int(td.stack_max) == 3
		and int(td.rarity) == 1 and is_equal_approx(td.decay_delta, 0.85),
		"td=%s" % str(td))
	_check("⑥b params.required_weapon=&\"W10_boomerang\" + 描述「回旋刃甩程 +18%，可叠 3 层」",
		td != null and StringName(str(td.params.get("required_weapon", ""))) == &"W10_boomerang"
		and td.description == "回旋刃甩程 +18%，可叠 3 层",
		"req=%s desc=%s" % [str(td.params.get("required_weapon", "")), td.description])
	_check("⑥c add_boom_range ∈ ADD_POOL_IDS 第 18 员（追加不重排）",
		DataValidator.ADD_POOL_IDS.size() == 18
		and DataValidator.ADD_POOL_IDS[17] == &"add_boom_range",
		"size=%d" % DataValidator.ADD_POOL_IDS.size())
	var rejected_n := int(_reg.report.get("rejected", -1))
	_check("⑥d registry 全量校验 rejected==0（新卡入库全绿）", rejected_n == 0,
		"rejected=%d total=%d" % [rejected_n, int(_reg.report.get("total", 0))])


# ═══ ⑦ required_weapon 门 ════════════════════════════════════════════
func _case7_mount_gate() -> void:
	print("── ⑦ required_weapon 门：W1 桩拒 / W10 放行 ──")
	var td := _throw_range_td()
	var w1_target := WeaponBase.new()
	w1_target.data = _reg.get_weapon(&"W1_pistol")
	_stubs.append(w1_target)
	var w10_target := WeaponBase.new()
	w10_target.data = _reg.get_weapon(&"W10_boomerang")
	_stubs.append(w10_target)
	_check("⑦a W1 桩挂 MEC_THROW_RANGE 被 required_weapon 门拒（mount_gate_allows=false）",
		not CardGenerator.mount_gate_allows(td, w1_target))
	_check("⑦b W10 正控放行（mount_gate_allows=true）",
		CardGenerator.mount_gate_allows(td, w10_target))


# ═══ ⑧ W10×FRACTAL×KILL_BLAST 双卡回归（防双炸） ═════════════════════
func _case8_double_card() -> void:
	print("── ⑧ FRACTAL×KILL_BLAST 双卡：翻相帧恰 1 炸 @last_hit_pos + 回收不增 ──")
	var wd10: WeaponData = _reg.get_weapon(&"W10_boomerang")
	var blast_weapon := BlastSpyWeapon.new()
	blast_weapon.setup(wd10, null, _deps)
	_stubs.append(blast_weapon)
	var spy := ExpireSpy.new()
	var pm := _spawn_boom(Vector2(360.0, 360.0), Vector2(520.0, 0.0), {
		"traits": [_fractal_tb(), _kill_blast_tb(), spy],
		"weapon_ref": blast_weapon,
	})
	pm.set("killed_target", true)            # 击杀证据桩（MEC_KILL_BLAST guard 输入）
	pm.set("last_hit_pos", Vector2(600.0, 360.0))   # 爆炸锚桩（≠翻相位 ~740）
	var kb0 := DebugStats.get_counter(&"kill_blast_triggered")
	_tick_to_flip(pm)
	var kb_flip := DebugStats.get_counter(&"kill_blast_triggered") - kb0
	var kids := _gen1_children()
	_check("⑧a 翻相帧 kill_blast 计数恰 +1（时点前移到甩程末端）", kb_flip == 1,
		"delta=%d" % kb_flip)
	_check("⑧b 爆炸位=last_hit_pos(600,360) 非翻相位（trait_effect_mech 结算位与派发时点无关）",
		blast_weapon.blast_count == 1 and blast_weapon.last_blast_pos == Vector2(600.0, 360.0),
		"n=%d pos=%s" % [blast_weapon.blast_count, str(blast_weapon.last_blast_pos)])
	_check("⑧c 分裂子代同帧生成（同一次 ON_EXPIRE 派发双卡全收）", kids.size() == 2,
		"kids=%d" % kids.size())
	_tick_to_recycle(pm)
	var kb_end := DebugStats.get_counter(&"kill_blast_triggered") - kb0
	var kids_end := _gen1_children()
	_check("⑧d 回手回收帧两计数均不再增（防双炸：kill_blast 恒 1、子代恒 2、ON_EXPIRE 恒 1）",
		kb_end == 1 and kids_end.size() == 2 and spy.expire_count == 1,
		"kb=%d kids=%d spy=%d" % [kb_end, kids_end.size(), spy.expire_count])
	_release_proj(pm)
	_release_all(kids_end)
	# ⑧e 无 killed_target：guard 原样不炸（分裂照常、爆炸零次）
	var pm2 := _spawn_boom(Vector2(360.0, 360.0), Vector2(520.0, 0.0), {
		"traits": [_fractal_tb(), _kill_blast_tb()],
		"weapon_ref": blast_weapon,
	})
	var kb0b := DebugStats.get_counter(&"kill_blast_triggered")
	_tick_to_flip(pm2)
	var kb_flip2 := DebugStats.get_counter(&"kill_blast_triggered") - kb0b
	_check("⑧e 无 killed_target 时 guard 不炸（计数 +0）且分裂 2 枚照常",
		kb_flip2 == 0 and blast_weapon.blast_count == 1 and _gen1_children().size() == 2,
		"delta=%d blasts=%d kids=%d" % [kb_flip2, blast_weapon.blast_count,
		_gen1_children().size()])
	_release_proj(pm2)
	_release_all(_gen1_children())

# tests/qa_r290_indep_accept_cases.gd
# R290 独立 QA 验收探针用例体。契约来源 = 验收依据 1-5（保帧三刀）：
#   点1 闩可靠置位：boost 开 / deep_override=-1 / PLAYING 未暂停，死区 fps=40 先行，
#       再 fps=20 累计 2s ⇒ deep_active true（含死区不清低帧累计的判别性变体）。
#   点2 负载门保位：闩置位且驻留≥10s，场地满载（spawner.active≥30）高帧 4s 不撤；
#       场地清空后再高帧 4s 必撤。
#   点3 深载档位：boost∧deep ⇒ 敌帽 40 / BOOST_DEEP_TEAM0_CAP 120；deep 关 ⇒ 90；
#       boost 关 ⇒ 120 且不触玩家弹帽。
#   点4 W9 缓存等价：ArcSlash._bullet_block_chance 同世代多次调用=逐拍直算且命中缓存；
#       runtime_generation 变化/换宿主即重取；无 trait_stack 的桩走直算不缓存。
#   点5 关态零位移：boost 关 ⇒ deep_load 恒 false / 敌帽 120 / 玩家弹无深载帽 /
#       _update_deep_load_at 仍清闩并复位计时。
# 夹具：main.tscn 真链 boot 后冻结引擎自动 process，全部直驱；结束还原。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"


# R290 点4 桩宿主：真实 WeaponBase（保证 ArcSlash.weapon 类型兼容 + trait_stack 槽位），
# 覆写 bullet_block_chance 计数并返回可控「聚合值」——用于验证缓存命中/失效真值。
class StubHost extends WeaponBase:
	var stub_value: float = 0.25
	var calls: int = 0

	func bullet_block_chance() -> float:
		calls += 1
		return stub_value


var tree: SceneTree
var _gl: Node = null
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _saved_settings: Dictionary = {}
var _saved_first_met: Dictionary = {}
var _saved_codex_weapons: Dictionary = {}
var _saved_css: Vector2i = Vector2i.ZERO
var _saved_zoom: Vector2 = Vector2.ONE
var _saved_notch: int = 0
var _saved_snotch: int = 0
var _acquired: Array[Node] = []


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


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(290)
	_saved_settings = Meta._settings.duplicate()
	_saved_first_met = Meta.codex_first_met.duplicate()
	_saved_codex_weapons = Meta.codex_weapons.duplicate()
	await _boot()
	PerfGovernor.set_process(false)
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = 3
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = -1
	PerfGovernor.set_deep_active(false)
	Meta.set_setting("fx_quality", 2)
	Meta.set_setting("boost_res", 85)
	Meta.set_setting("perf_boost", 1)
	_gl.state = GameConst.GameStatus.PLAYING
	_gl.player.set("_dead", false)
	tree.paused = false
	_saved_css = _gl.get_window().content_scale_size
	_saved_zoom = _gl.camera.zoom if _gl.camera != null else Vector2.ONE
	_saved_notch = int(_gl._boost_applied_notch)
	_saved_snotch = GameLoop._s_boost_applied_notch
	_p1_latch_set()
	_p2_load_gate()
	_p3_caps()
	_p4_w9_cache()
	_p5_off_zero_drift()
	await _cleanup()


func _boot() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate()
	_gl.name = "R290IndepAccept"
	tree.root.add_child(_gl)
	await tree.process_frame
	await tree.process_frame
	if not bool(_gl.get("boot_ready")):
		_check("boot 成功（main.tscn 真链）", false, str(_gl.get("boot_fatal")))
	else:
		_check("boot 成功（main.tscn 真链）", true, "")
	_gl.set_physics_process(false)
	_gl.set_process(false)


func _reset_deep() -> void:
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = -1
	PerfGovernor.set_deep_active(false)
	_gl._deep_on_acc = 0.0
	_gl._deep_off_acc = 0.0
	_gl._deep_dwell_s = 0.0
	tree.paused = false
	_gl.state = GameConst.GameStatus.PLAYING


func _deep_steps(p_fps: float, p_seconds: float) -> void:
	var n := int(round(p_seconds / 0.1))
	for _i in range(n):
		_gl._update_deep_load_at(p_fps, 0.1)


# ── 点1：闩可靠置位（死区先行不阻遏） ─────────────────────────────
func _p1_latch_set() -> void:
	print("── 点1 闩可靠置位（死区 fps=40 先行 → fps=20 累计 2s 置位） ──")
	# 验收原序：boost 开 / deep_override=-1 / PLAYING 未暂停；40×1.0s → 20×2.0s
	_reset_deep()
	_deep_steps(40.0, 1.0)
	var mid_ok := not PerfGovernor.deep_active()
	_deep_steps(20.0, 1.9)
	var near_ok := not PerfGovernor.deep_active()
	_deep_steps(20.0, 0.1)
	_check("1a 死区 40×1.0s → 20×2.0s ⇒ deep_active true",
		mid_ok and near_ok and PerfGovernor.deep_active(),
		"mid=%s near=%s active=%s" % [str(mid_ok), str(near_ok),
			str(PerfGovernor.deep_active())])

	# 判别性变体（原「死区双侧清零」下不可达）：20×1.0（累计 1.0）→ 死区 40×1.0（不得清零）
	# → 20×1.0（累计 2.0 置位）
	_reset_deep()
	_deep_steps(20.0, 1.0)
	_deep_steps(40.0, 1.0)
	var kept_ok := not PerfGovernor.deep_active() \
		and absf(float(_gl._deep_on_acc) - 1.0) < 1.0e-6
	_deep_steps(20.0, 1.0)
	_check("1b 死区保留低帧累计：20×1.0→40×1.0(保留 1.0)→20×1.0 ⇒ 置位",
		kept_ok and PerfGovernor.deep_active(),
		"kept=%s on=%.4f active=%s" % [str(kept_ok), float(_gl._deep_on_acc),
			str(PerfGovernor.deep_active())])


# ── 点2：负载门保位 ──────────────────────────────────────────────
func _p2_load_gate() -> void:
	print("── 点2 清位负载门（满载不撤 / 清空必撤） ──")
	_clear_pool()
	# 置位并驻留到 ≥10s（死区 40 段不计高帧侧，仅累计驻留）
	_reset_deep()
	_deep_steps(20.0, 2.0)
	var set_ok := PerfGovernor.deep_active()
	_deep_steps(40.0, 11.0)                        # 死区驻留：置位时 dwell 已复位，需再攒满 10s
	var dwell_ok := PerfGovernor.deep_active() and float(_gl._deep_dwell_s) >= 10.0
	# 场地满载：注入 >=DEEP_CLEAR_QUIET_ENEMIES 敌
	var sp: Variant = _gl.get("spawner")
	var act: Array = [] if sp == null else (sp.get("active") as Array)
	var inj: Array[Node2D] = []
	if sp != null:
		for _i in range(GameLoop.DEEP_CLEAR_QUIET_ENEMIES + 6):
			var n := Node2D.new()
			inj.append(n)
			act.append(n)
	_deep_steps(60.0, 4.0)
	_check("2a 闩置位且驻留≥10s，场地满载敌≥30 高帧 4s 不撤深载",
		set_ok and dwell_ok and PerfGovernor.deep_active() \
		and act.size() == GameLoop.DEEP_CLEAR_QUIET_ENEMIES + 6,
		"set=%s dwell=%s active=%s n=%d" % [str(set_ok), str(dwell_ok),
			str(PerfGovernor.deep_active()), act.size()])
	# 清空场地 → 再高帧 4s 必撤
	if sp != null:
		for n2 in inj:
			act.erase(n2)
			n2.free()
	_deep_steps(60.0, 4.0)
	_check("2b 场地清空后再高帧 4s ⇒ 撤档",
		not PerfGovernor.deep_active(), "active=%s" % str(PerfGovernor.deep_active()))


# ── 点3：深载档位 ────────────────────────────────────────────────
func _p3_caps() -> void:
	print("── 点3 深载档位（敌帽 40 / 弹帽 120；deep 关 90；boost 关 120） ──")
	_check("3a ProjectilePool.BOOST_DEEP_TEAM0_CAP==120",
		ProjectilePool.BOOST_DEEP_TEAM0_CAP == 120,
		str(ProjectilePool.BOOST_DEEP_TEAM0_CAP))
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = 1
	_check("3b boost∧deep ⇒ EnemySpawner.max_onscreen()==40",
		EnemySpawner.max_onscreen() == 40, str(EnemySpawner.max_onscreen()))
	PerfGovernor.deep_override = 0
	_check("3c deep_override=0 ⇒ max_onscreen()==90",
		EnemySpawner.max_onscreen() == 90, str(EnemySpawner.max_onscreen()))
	PerfGovernor.boost_override = 0
	PerfGovernor.deep_override = 1
	_check("3d boost_override=0 ⇒ max_onscreen()==120（且 deep_load false）",
		EnemySpawner.max_onscreen() == 120 and not PerfGovernor.deep_load(),
		"cap=%d" % EnemySpawner.max_onscreen())


# ── 点4：W9 挡弹概率缓存等价 ────────────────────────────────────
func _p4_w9_cache() -> void:
	print("── 点4 W9 挡弹概率缓存等价（同世代直算一致 / 世代+1 重取 / 无栈不缓存） ──")
	var host := StubHost.new()
	host.stub_value = 0.25
	var ts := TraitStack.new()
	host.trait_stack = ts
	var arc := ArcSlash.new()
	arc.weapon = host
	arc.block_chance = -1.0

	# (a) 首次调用=逐拍直算值，且缓存锚（世代+宿主 id）就位
	var v1 := arc._bullet_block_chance()
	_check("4a 首次调用=直算值且缓存锚就位",
		absf(v1 - 0.25) < 1.0e-9 and int(host.calls) == 1 \
		and int(arc.get("_bc_gen")) == int(ts.runtime_generation) \
		and int(arc.get("_bc_owner")) == host.get_instance_id(),
		"v=%.4f calls=%d gen=%d owner=%d" % [v1, int(host.calls),
			int(arc.get("_bc_gen")), int(arc.get("_bc_owner"))])

	# (b) 同世代多次调用：命中缓存（宿主不再被调）且取值与逐拍直算一致
	var same_ok := true
	for _i in range(20):
		if absf(arc._bullet_block_chance() - 0.25) > 1.0e-9:
			same_ok = false
	_check("4b 同世代 20 次调用取值一致且命中缓存（宿主仅被调 1 次）",
		same_ok and int(host.calls) == 1, "calls=%d" % int(host.calls))

	# (c) runtime_generation 变化 → 下次调用取到新聚合值
	host.stub_value = 0.70
	ts.runtime_generation += 1
	var v3 := arc._bullet_block_chance()
	_check("4c 世代+1 后下次调用重取（新聚合值 0.70）",
		absf(v3 - 0.70) < 1.0e-9 and int(host.calls) == 2,
		"v=%.4f calls=%d" % [v3, int(host.calls)])

	# (d) 换宿主实例（世代不变）→ 宿主 id 变化失效重取
	var host2 := StubHost.new()
	host2.stub_value = 0.10
	host2.trait_stack = ts
	arc.weapon = host2
	var v4 := arc._bullet_block_chance()
	_check("4d 换宿主（同世代）→ 宿主 id 失效重取 0.10",
		absf(v4 - 0.10) < 1.0e-9 and int(host2.calls) == 1,
		"v=%.4f calls=%d" % [v4, int(host2.calls)])

	# (e) 无 trait_stack 的桩走直算不缓存（每次调用都打到宿主，且不写缓存锚）
	host2.trait_stack = null
	arc.set("_bc_gen", -1)
	arc.set("_bc_owner", 0)
	var c0 := int(host2.calls)
	var e_ok := true
	for _i in range(5):
		if absf(arc._bullet_block_chance() - 0.10) > 1.0e-9:
			e_ok = false
	_check("4e 无 trait_stack 宿主走直算不缓存（5 次调用宿主 5 次，锚不写）",
		e_ok and int(host2.calls) - c0 == 5 and int(arc.get("_bc_gen")) == -1,
		"Δcalls=%d gen=%d" % [int(host2.calls) - c0, int(arc.get("_bc_gen"))])

	# (f) block_chance>=0 快照短路优先（不经宿主——W13 快照口径）
	arc.block_chance = 0.40
	var c1 := int(host2.calls)
	_check("4f block_chance>=0 快照优先（不触宿主）",
		absf(arc._bullet_block_chance() - 0.40) < 1.0e-9 and int(host2.calls) == c1,
		"calls=%d" % int(host2.calls))

	# (g) spawn 重铺复位缓存锚（-1 = 重算）
	arc.block_chance = -1.0
	arc.spawn({})
	_check("4g spawn 重铺后缓存锚复位 -1（换宿主/换构筑必重算）",
		int(arc.get("_bc_gen")) == -1 and int(arc.get("_bc_owner")) == 0,
		"gen=%d owner=%d" % [int(arc.get("_bc_gen")), int(arc.get("_bc_owner"))])

	arc.free()
	host.free()
	host2.free()


# ── 点5：关态零位移 ─────────────────────────────────────────────
func _p5_off_zero_drift() -> void:
	print("── 点5 关态零位移（boost 关：恒 false / 敌帽 120 / 玩家弹无深载帽 / 写点复位） ──")
	_clear_pool()
	PerfGovernor.boost_override = 0
	PerfGovernor.deep_override = 1
	_check("5a boost 关 ⇒ deep_load 恒 false", not PerfGovernor.deep_load(),
		"active=%d" % int(PerfGovernor.deep_active()))
	_check("5b boost 关 ⇒ 敌帽 120", EnemySpawner.max_onscreen() == 120,
		str(EnemySpawner.max_onscreen()))

	# 玩家弹：boost 关时无深载帽——acquire 130 颗全获（> 深载帽 120）
	var pool: ProjectilePool = _gl._projectile_pool
	var got := 0
	for _i in range(130):
		var p0: ProjectileBase = pool.acquire(0)
		if p0 == null:
			break
		got += 1
		_acquired.append(p0)
	_check("5c boost 关 ⇒ 玩家弹无深载帽（acquire 130 全获）", got == 130,
		"got=%d total=%d" % [got, pool.total_active()])
	var cap0 := int(DebugStats.get_counter(&"deep_bullet_capped"))
	_check("5d boost 关 ⇒ acquire 不误计 deep_bullet_capped（增量 0，关态无深载帽）",
		int(DebugStats.get_counter(&"deep_bullet_capped")) == cap0,
		"Δ=%d" % (int(DebugStats.get_counter(&"deep_bullet_capped")) - cap0))
	_clear_pool()

	# 写点关态仍清闩并复位三计时
	PerfGovernor.boost_override = 0
	PerfGovernor.deep_override = -1
	PerfGovernor.set_deep_active(true)
	_gl._deep_on_acc = 1.5
	_gl._deep_off_acc = 1.5
	_gl._deep_dwell_s = 12.0
	_gl._update_deep_load_at(20.0, 10.0)
	_check("5e boost 关 ⇒ 写点清闩并复位 on/off/dwell",
		not PerfGovernor.deep_active() and absf(float(_gl._deep_on_acc)) < 1.0e-9 \
		and absf(float(_gl._deep_off_acc)) < 1.0e-9 and absf(float(_gl._deep_dwell_s)) < 1.0e-9,
		"active=%s on=%.4f off=%.4f dwell=%.4f" % [str(PerfGovernor.deep_active()),
			float(_gl._deep_on_acc), float(_gl._deep_off_acc), float(_gl._deep_dwell_s)])


func _clear_pool() -> void:
	var pool: ProjectilePool = _gl._projectile_pool
	var live: Array = pool.active_projectiles().duplicate()
	for p in live:
		if p != null and is_instance_valid(p):
			pool.release(p)
	_acquired.clear()


func _cleanup() -> void:
	print("── 收尾（池/设置/画布/闩还原） ──")
	_clear_pool()
	PerfGovernor.boost_override = -1
	PerfGovernor.deep_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.set_deep_active(false)
	_gl._deep_on_acc = 0.0
	_gl._deep_off_acc = 0.0
	_gl._deep_dwell_s = 0.0
	_gl.set_process(true)
	_gl.set_physics_process(true)
	_gl.get_window().content_scale_size = _saved_css
	if _gl.camera != null:
		_gl.camera.zoom = _saved_zoom
	_gl._boost_applied_notch = _saved_notch
	GameLoop._s_boost_applied_notch = _saved_snotch
	tree.paused = false
	RunSave.clear()
	Meta.codex_first_met = _saved_first_met.duplicate()
	Meta.codex_weapons = _saved_codex_weapons.duplicate()
	Meta._settings = _saved_settings.duplicate()
	Meta._save()
	_gl.queue_free()
	await tree.process_frame
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])
	if _fail > 0:
		for f in _failures:
			print("  FAIL 项：%s" % f)

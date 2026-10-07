# tests/runner/r238_shieldfix_cases.gd
# R238 护盾五面修复用例体（入口运行时 load——cases 禁 test_ 前缀防电池 glob 误收）。
# 数值锚（MEC_SHIELD.tres params {interval_s:8.0, interval_lv2:5.5}，白 value 1.0/金 2.6）：
# 几何逐层 interval(N) = 8 × (5.5/8)^(N-1)：1 层 8.0 / 2 层 5.5 / 3 层 3.78125 / 4 层 2.5996；
# 金卡 ÷2.6：2 层金 2.1154 / 3 层金 1.4543。
# 覆盖：①H4 首挂即就绪+挡伤 ②H1 几何逐层（白 1-4 层+金档）③H3 跨武器聚合不回退
# ④H2 栈满 apply_choice → 横幅明示+FALLBACK ⑤H5 出生位重叠预判 arm（贴身 arm+掉血/
# 远位不 arm）⑥ 总项数。真工程对象（main.tscn 真起 GameLoop·真武器槽·真注册表）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const EXPECTED_TOTAL := 18

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _intro_last: String = ""
var _intro_cb: Callable = Callable()


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261007)
	await _boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_gl.state = GameConst.GameStatus.MENU             # 静止环境（r230/r236/r237 先例）
	PerfGovernor.set_process(false)
	GameLoop.SIM_30HZ_ENABLED = false
	GameLoop.sim30_override = -1
	# ③④ 前置：双武器在位（boot 只装 1 把——add_weapon 同款数据造第 2 把，
	# 跨武器聚合/降级落位用例需要）
	if _gl.player.weapon_slots.size() < 2 or _gl.player.weapon_slots[1] == null:
		_gl.player.add_weapon(_gl.player.weapon_slots[0].data)
	_intro_cb = func(t: String) -> void: _intro_last = t
	EventBus.mechanics_intro.connect(_intro_cb)
	_reset_fixture()
	_test_1_h4_first_instant()
	_test_2_h1_geometric_layers()
	await _test_3_h3_cross_weapon()
	_test_4_h2_fallback_banner()
	await _test_5_h5_birth_overlap()
	_reset_fixture()
	EventBus.mechanics_intro.disconnect(_intro_cb)
	PerfGovernor.set_process(true)
	_check("⑥ 套件总项数（EXPECTED=%d——R231 假绿教训）" % EXPECTED_TOTAL,
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
	var main: Node = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	await tree.process_frame
	_gl = tree.root.get_node_or_null("Main") as GameLoop
	if _gl == null:
		for c in tree.root.get_children():
			if c is GameLoop:
				_gl = c
				break


func _reset_fixture() -> void:
	# 探针 r238_barrier_repro_cases._reset_fixture 同款（真栈清空+玩家盾态归零）
	var player := _gl.player
	for w in player.weapon_slots:
		if w is WeaponBase and is_instance_valid(w) and (w as WeaponBase).trait_stack != null:
			(w as WeaponBase).trait_stack.clear()
	player.shield_interval = 0.0
	player.shield_timer = 0.0
	player.shield_ready = false
	player.max_hp = 100.0
	player.hp = 100.0
	player.invuln_left = 0.0
	player._dead = false
	player.dr_left = 0.0
	player.dr_value = 0.0
	_intro_last = ""


func _shield_params() -> Dictionary:
	return _gl.registry.get_trait(&"MEC_SHIELD").params


# ═══ ① H4 首挂即就绪 ══════════════════════════════════════════
func _test_1_h4_first_instant() -> void:
	print("── ① H4 首挂即就绪（原首充 8s 空窗） ──")
	var p := _gl.player
	p.apply_shield_trait(1, _shield_params(), 1.0)
	_check("①a 首挂 interval=8.0 且 shield_ready=true（R238 契约——不再等 8s 空窗）",
		absf(p.shield_interval - 8.0) <= 0.01 and p.shield_ready,
		"i=%.4f ready=%s" % [p.shield_interval, str(p.shield_ready)])
	var hp0: float = p.hp
	p.invuln_left = 0.0
	p.take_contact_damage(50.0)
	_check("①b 选卡瞬间挨打=被挡（HP 不掉+进入再充能 timer=8.0）",
		absf(p.hp - hp0) <= 0.01 and not p.shield_ready
		and absf(p.shield_timer - 8.0) <= 0.01,
		"hp %.0f→%.0f timer=%.3f" % [hp0, p.hp, p.shield_timer])
	_check("①c 挡N 计数在位（R238 诊断键——shield_blocks≥1，1Hz 行效果可判读口）",
		DebugStats.get_counter(&"shield_blocks") >= 1,
		"n=%d" % DebugStats.get_counter(&"shield_blocks"))
	_reset_fixture()


# ═══ ② H1 几何逐层 ════════════════════════════════════════════
func _test_2_h1_geometric_layers() -> void:
	print("── ② H1 层数几何逐层（原两档封顶） ──")
	var p := _gl.player
	var expect := [8.0, 5.5, 3.78125, 2.5996]
	for n in range(1, 5):
		p.apply_shield_trait(n, _shield_params(), 1.0)
		_check("②%s %d 层白卡 interval≈%.4f（几何递减非饱和）" % ["abcd"[n - 1], n, expect[n - 1]],
			absf(p.shield_interval - expect[n - 1]) <= 0.01,
			"i=%.4f" % p.shield_interval)
	p.apply_shield_trait(3, _shield_params(), 2.6)
	_check("②e 3 层金卡（×2.6）≈1.4543（品质梯×层数增益叠加）",
		absf(p.shield_interval - 3.78125 / 2.6) <= 0.01,
		"i=%.4f" % p.shield_interval)
	_reset_fixture()


# ═══ ③ H3 跨武器聚合 ══════════════════════════════════════════
func _test_3_h3_cross_weapon() -> void:
	print("── ③ H3 跨武器全槽聚合（原宿主单栈低卡覆写） ──")
	var p := _gl.player
	var w1: WeaponBase = p.weapon_slots[0]
	var w2: WeaponBase = p.weapon_slots[1]
	if w1 == null or w2 == null:
		_check("③ 前置：双武器槽在位", false, "w1=%s w2=%s" % [str(w1), str(w2)])
		return
	var gold: TraitData = (_gl.registry.get_trait(&"MEC_SHIELD").duplicate() as TraitData)
	gold.value = 2.6
	w1.attach_trait(gold)
	w1.attach_trait(gold.duplicate() as TraitData)     # W1 金 2 层
	_check("③a W1 金 2 层 → interval≈2.1154（5.5/2.6）",
		absf(p.shield_interval - 5.5 / 2.6) <= 0.01,
		"i=%.4f" % p.shield_interval)
	var white: TraitData = _gl.registry.get_trait(&"MEC_SHIELD")
	w2.player = p
	w2.attach_trait(white)                             # W2 后挂白 1 层（旧行为=覆写回 8s）
	_check("③b W2 白 1 层后 → 3 层聚合≈1.4543（非 8s 覆写回退）",
		absf(p.shield_interval - (8.0 * pow(5.5 / 8.0, 2)) / 2.6) <= 0.01,
		"i=%.4f" % p.shield_interval)
	_check("③c 层数=全槽之和（2+1=3——档位随聚合层数上升）",
		absf(p.shield_interval) < absf(5.5 / 2.6),
		"i=%.4f < %.4f" % [p.shield_interval, 5.5 / 2.6])
	_reset_fixture()


# ═══ ④ H2 栈满降级横幅 ════════════════════════════════════════
func _test_4_h2_fallback_banner() -> void:
	print("── ④ H2 栈满降级横幅（原静默替换） ──")
	var p := _gl.player
	var w1: WeaponBase = p.weapon_slots[0]
	var prefill := _pick_prefill_ids(12)
	if prefill.size() < 12:
		_check("④a 前置：ADD 池可取 12 种类", false, "n=%d" % prefill.size())
		return
	for tid in prefill:
		w1.attach_trait(_gl.registry.get_trait(tid).duplicate() as TraitData)
	_check("④a W1 栈 12 种类帽满", w1.trait_stack.size() == 12,
		"size=%d" % w1.trait_stack.size())
	var cg := _gl.card_generator
	var card: Dictionary = cg._make_trait_card(&"MEC_SHIELD", 1, w1)
	cg.apply_choice(card, p)
	var shield_gone: bool = not _stack_has(w1, &"MEC_SHIELD")
	var fb_landed: bool = _stack_has(w1, &"FALLBACK_ATK") \
		or _stack_has(p.weapon_slots[1], &"FALLBACK_ATK")   # w1 帽满 → fb 落下一个空位武器
	_check("④b 护盾未落栈+FALLBACK 落位（降级发生）", shield_gone and fb_landed,
		"shield_gone=%s fb=%s" % [str(shield_gone), str(fb_landed)])
	_check("④c 横幅明示「词条栏已满…应急强化」（R238 新增——不再静默）",
		_intro_last.contains("应急强化"), "banner=%s" % _intro_last)
	_reset_fixture()


# ═══ ⑤ H5 出生位重叠预判 arm ══════════════════════════════════
func _test_5_h5_birth_overlap() -> void:
	print("── ⑤ H5 出生位重叠预判 arm（信号缓存缺口） ──")
	var p := _gl.player
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire()
	e.spawn(_fixture_enemy(&"E_R238_H5A", 100.0, 25.0), 1, 0)
	e.global_position = p.global_position + Vector2(20.0, 0.0)   # 贴身出生（<reach 30）
	e.ip_birth_snap()                                            # spawner 挂位后必调口
	_check("⑤a 出生位重叠 → _contact_player 已 arm（原信号缺口=永不 arm）",
		e._contact_player == p, "arm=%s" % str(e._contact_player != null))
	p.hp = 1000.0
	p.invuln_left = 0.0
	p.shield_interval = 0.0                                      # 无盾裸测接触结算
	p.shield_ready = false
	e.tick(DT)
	_check("⑤b 贴身 tick 结算接触伤（hp 1000→975——链路通）",
		absf(p.hp - 975.0) < 0.001, "hp=%.1f" % p.hp)
	pool.release(e)
	var e2 := pool.acquire()
	e2.spawn(_fixture_enemy(&"E_R238_H5B", 100.0, 0.0), 1, 0)
	e2.global_position = p.global_position + Vector2(1000.0, 0.0)  # 远位出生
	e2.ip_birth_snap()
	_check("⑤c 远位出生 → 不误 arm", e2._contact_player == null,
		"arm=%s" % str(e2._contact_player != null))
	pool.release(e2)


func _pick_prefill_ids(p_n: int) -> Array[StringName]:
	# 探针 r238_barrier_repro_cases 同款思路：ADD 池真词条取 N 个（排除 MEC_SHIELD/
	# FALLBACK_ATK 自身），供 12 种类帽预填
	var out: Array[StringName] = []
	for tid in _gl.registry.trait_ids_by_pool(GameConst.PoolClass.ADD):
		if tid == &"MEC_SHIELD" or tid == &"FALLBACK_ATK":
			continue
		if _gl.registry.get_trait(tid) == null:
			continue
		out.append(tid)
		if out.size() >= p_n:
			break
	return out


func _stack_has(p_w: WeaponBase, p_tid: StringName) -> bool:
	if p_w == null or not is_instance_valid(p_w) or p_w.trait_stack == null:
		return false
	for mounted in p_w.trait_stack.traits:
		if mounted.data != null and mounted.data.id == p_tid:
			return true
	return false


func _fixture_enemy(p_id: StringName, p_hp: float, p_dmg: float = 0.0) -> EnemyData:
	# r202_g3/r237_contact_radial 同款夹具（静态：spd 0 / 可配 dmg）
	var d := EnemyData.new()
	d.id = p_id
	d.display_name = String(p_id)
	d.hp_base = p_hp
	d.spd_base = 0.0
	d.dmg_base = p_dmg
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d

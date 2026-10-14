# tests/runner/r253_backlog_cases.gd
# R253 缓办清账批用例体（入口运行时 load——cases 禁 test_ 前缀防电池 glob 误收）。
# 覆盖：A) 独立计时运行时补充 B) 防御六遗物 C) 保底遗物 D) 每日难度 E) fission 首发门
# F) 源码锚。真工程对象（main.tscn 真起 GameLoop·真注册表·真 RelicHandler）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const EXPECTED_TOTAL := 35

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261008)
	await _boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_gl.state = GameConst.GameStatus.MENU             # 静止环境（r238/r249 先例）
	PerfGovernor.set_process(false)
	GameLoop.SIM_30HZ_ENABLED = false
	GameLoop.sim30_override = -1
	_test_a_shield_units_runtime()
	_test_b_defense_relics()
	await _test_c_guarantee_relic()
	_test_d_daily_difficulty()
	_test_e_fission_gate()
	_test_f_source_anchors()
	PerfGovernor.set_process(true)
	_check("总项数（EXPECTED=%d）" % EXPECTED_TOTAL,
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


func _shield_params() -> Dictionary:
	return _gl.registry.get_trait(&"MEC_SHIELD").params


# ═══ A 独立计时运行时补充（r238 ③ 锁跨武器静态，本组锁动态） ══════
func _test_a_shield_units_runtime() -> void:
	print("── A 独立计时运行时（tick 逐单元/重挂保进度/视图同步） ──")
	var p := _gl.player
	for w in p.weapon_slots:
		if w is WeaponBase and is_instance_valid(w) and (w as WeaponBase).trait_stack != null:
			(w as WeaponBase).trait_stack.clear()
	p._shield_units.clear()
	p.shield_interval = 0.0
	p.shield_ready = false
	p.apply_shield_trait(1, _shield_params(), 1.0, 100)   # 单元 A：白 1 层 8s
	p.apply_shield_trait(1, _shield_params(), 2.6, 200)   # 单元 B：金 1 层 ≈3.08s
	_check("A1 双单元视图：layers=2 / 任一就绪 ready=true",
		p.shield_layers == 2 and p.shield_ready and p._shield_units.size() == 2,
		"layers=%d ready=%s units=%d" % [p.shield_layers, str(p.shield_ready), p._shield_units.size()])
	# 消耗两次：间隔大者（A 8s）先挡、再 B——两份各挡一次（独立计时的核心收益；
	# 每击间清无敌帧——首次格挡给 0.6s contact_tick，不清则第二击被无敌帧吞）
	p.invuln_left = 0.0
	p.take_contact_damage(50.0)
	p.invuln_left = 0.0
	p.take_contact_damage(50.0)
	_check("A2 两连击各耗一份（A/B 均转充能、不再有就绪盾）",
		not bool(p._shield_units[100].ready) and not bool(p._shield_units[200].ready)
			and not p.shield_ready,
		"a=%s b=%s" % [str(p._shield_units[100].ready), str(p._shield_units[200].ready)])
	_check("A3 消耗后视图 interval=未就绪最快者（B 金 3.08s 档）",
		absf(p.shield_interval - 8.0 / 2.6) <= 0.01, "i=%.4f" % p.shield_interval)
	# tick 推进：B（金 3.08s）先回就绪，A（白 8s）仍在充
	p.tick(3.2, Vector2.ZERO)
	_check("A4 tick 3.2s：B 单元（金 ≈3.08s）回就绪、A（白 8s）未回",
		bool(p._shield_units[200].ready) and not bool(p._shield_units[100].ready)
			and p.shield_ready,
		"a=%s b=%s" % [str(p._shield_units[100].ready), str(p._shield_units[200].ready)])
	# 重挂同单元：间隔刷新、充能进度与就绪态保持
	p._shield_units[200].ready = false
	p._shield_units[200].timer = 1.0
	p.apply_shield_trait(2, _shield_params(), 2.6, 200)   # 重挂：2 层金 ≈2.12s
	_check("A5 重挂保持进度：B 未就绪 timer=1.0 不重置、interval 刷新 2.12s 档",
		not bool(p._shield_units[200].ready) and absf(float(p._shield_units[200].timer) - 1.0) < 0.001
			and absf(float(p._shield_units[200].interval) - 5.5 / 2.6) <= 0.01,
		"ready=%s timer=%.3f i=%.4f" % [str(p._shield_units[200].ready),
		float(p._shield_units[200].timer), float(p._shield_units[200].interval)])
	p._shield_units.clear()
	p.shield_interval = 0.0
	p.shield_ready = false


# ═══ B 防御控制向六遗物 ═════════════════════════════════════════
func _test_b_defense_relics() -> void:
	print("── B 防御控制向六遗物（激活 + 效果落点） ──")
	var rh: RelicHandler = _gl.relic_handler
	var p := _gl.player
	rh.reset_run()
	p.max_hp = 100.0
	p.hp = 100.0
	p.invuln_left = 0.0
	p.relic_dr = 0.0
	# 末路壁垒：满血不触发；hp<30% → dr 0.25
	_check("B1 末路壁垒激活", rh.activate(&"REL_LAST_BULWARK"))
	rh.tick(DT)
	_check("B1a 满血 relic_dr=0（不触发）", is_equal_approx(p.relic_dr, 0.0),
		"dr=%.3f" % p.relic_dr)
	p.hp = 25.0
	rh.tick(DT)
	_check("B1b hp 25%<30% → relic_dr=0.25（受伤 ×0.75）",
		is_equal_approx(p.relic_dr, 0.25), "dr=%.3f" % p.relic_dr)
	# 减伤真实落账：25 伤 ×0.75 → 18.75
	p.invuln_left = 0.0
	p.shield_interval = 0.0
	p._shield_units.clear()
	p.temp_shield_stacks = 0
	var hp0: float = p.hp
	p.take_contact_damage(25.0)
	_check("B1c 实伤落账 25×0.75=18.75", absf(hp0 - p.hp - 18.75) < 0.01,
		"dropped=%.2f" % (hp0 - p.hp))
	# 守护本能：失 50% → floor(0.5/0.1)×0.02=0.10；与末路并存取 max（0.25 不被拉低）
	_check("B2 守护本能激活", rh.activate(&"REL_GUARD_INSTINCT"))
	p.hp = 50.0
	rh.tick(DT)
	_check("B2a 失血 50% → 守护档 0.10（末路 <30% 不在场；并存取 max 在 B1b hp25% 场景）",
		is_equal_approx(p.relic_dr, 0.10), "dr=%.3f" % p.relic_dr)
	# 壁垒契约：2 层橙盾 → 0.06（cap 0.18 内；被 0.25 掩护——单持语义在断言 D）
	_check("B3 壁垒契约激活", rh.activate(&"REL_BULWARK_PACT"))
	p.hp = 100.0
	p.temp_shield_stacks = 2
	p._dodge_frame_stamp = -1
	rh.tick(DT)
	_check("B3a 满血+2 橙盾层 → relic_dr=0.06（2×0.03）",
		is_equal_approx(p.relic_dr, 0.06), "dr=%.3f" % p.relic_dr)
	# 金钟罩：静默 grant + 独立计数
	var gain0: int = DebugStats.get_counter(&"orange_gain")
	var gain_r0: int = DebugStats.get_counter(&"orange_gain_relic")
	p.temp_shield_stacks = 0
	p.grant_temp_shield(true)
	_check("B4 金钟罩静默授予：+1 层且计数走独立键",
		p.temp_shield_stacks == 1 and DebugStats.get_counter(&"orange_gain_relic") == gain_r0 + 1
			and DebugStats.get_counter(&"orange_gain") == gain0,
		"stacks=%d" % p.temp_shield_stacks)
	# 霜寒守卫：player_hit 触发冻结（真敌在场）
	_check("B5 霜寒守卫激活", rh.activate(&"REL_FROST_WARD"))
	rh._frost_ward_cd_left = 0.0
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire()
	e.spawn(_fixture_enemy(), 1, 0)
	e.global_position = p.global_position + Vector2(60.0, 0.0)
	e.ip_birth_snap()
	e.tick(DT)
	_gl.enemy_grid.rebuild([e])                         # grid 由 GameLoop 从 spawner.active
	                                                   # 全量重建（:797）——测试敌手动入册
	_gl.elemental.register_host(e)                      # M-11：elemental 由 ElementalSystem
	                                                   # 挂入（pool.acquire+spawn 不含此步）
	rh._on_player_hit(10.0, 0)
	var frozen: bool = e.elemental != null and e.elemental.freeze_timer > 0.0
	_check("B5a 受击寒波冻结近敌（1.2s）+ icd 置位", frozen and rh._frost_ward_cd_left > 0.0,
		"frozen=%s icd=%.2f" % [str(frozen), rh._frost_ward_cd_left])
	pool.release(e)
	# 磁守结界：mine_dodged → 击退（近敌被推开位移）
	_check("B6 磁守结界激活", rh.activate(&"REL_SAFE_ORBIT"))
	var e2 := pool.acquire()
	e2.spawn(_fixture_enemy(), 1, 0)
	var pos0 := p.global_position + Vector2(40.0, 0.0)
	e2.global_position = pos0
	e2.ip_birth_snap()
	e2.tick(DT)
	_gl.enemy_grid.rebuild([e2])                        # 手动入册（同 B5a）
	EventBus.emit_mine_dodged(p.global_position)
	e2.tick(DT)                                         # knock_vel 冲量随 tick 滑出（阻尼 9/s）
	_check("B6a 获盾震开：近敌被击退位移>0", e2.global_position.distance_to(pos0) > 1.0,
		"moved=%.1f" % e2.global_position.distance_to(pos0))
	pool.release(e2)
	rh.reset_run()
	p.relic_dr = 0.0
	p.temp_shield_stacks = 0


func _fixture_enemy() -> EnemyData:
	var d := EnemyData.new()
	d.id = &"E_R253_B"
	d.display_name = "R253B"
	d.hp_base = 100.0
	d.spd_base = 0.0
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


# ═══ C 第 2 关保底遗物 ══════════════════════════════════════════
func _test_c_guarantee_relic() -> void:
	print("── C 保底遗物（第 2 关起零遗物保底 1 件） ──")
	var map_saved: StringName = Meta.run_map_id()
	# 第 2 关 + 零遗物 → start_run 保底激活 + 横幅
	Meta.set_run_map(&"world_frost")                     # 第 2 图寒霜冰原（map_index=1）——纯运行态不落盘
	_gl.current_map_id = &"world_frost"
	_gl.relic_handler.reset_run()
	_gl.card_generator.owned_relics.clear()
	_gl._run_intro_lines.clear()
	_gl._active_daily_seed = -1
	_gl.start_run(-1)
	await tree.process_frame
	var owned_n: int = _gl.relic_handler.owned_count()
	var lines_txt := "
".join(_gl._run_intro_lines)
	_check("C1 第 2 关开局零遗物 → 保底激活 1 件", owned_n == 1, "owned=%d" % owned_n)
	_check("C2 卡池 owned 同步（保底件不再上架）",
		_gl.card_generator.owned_relics.size() == 1,
		"n=%d" % _gl.card_generator.owned_relics.size())
	_check("C3 横幅含「保底遗物」行", lines_txt.contains("保底遗物"), "lines=%s" % lines_txt)
	_gl.state = GameConst.GameStatus.MENU                 # 回静止
	_gl.relic_handler.reset_run()
	_gl.card_generator.owned_relics.clear()
	# 第 1 关（map_index=0）无保底
	Meta.set_run_map(&"world_grass")
	_gl.current_map_id = &"world_grass"
	_gl.start_run(-1)
	await tree.process_frame
	_check("C4 第 1 关（遗物门未开）无保底", _gl.relic_handler.owned_count() == 0,
		"owned=%d" % _gl.relic_handler.owned_count())
	_gl.state = GameConst.GameStatus.MENU
	Meta.set_run_map(map_saved)                           # 运行态还原


# ═══ D 每日挑战固定普通 ═════════════════════════════════════════
func _test_d_daily_difficulty() -> void:
	print("── D 每日挑战难度（固定普通——不继承上一局） ──")
	_gl._difficulty = GameConst.Difficulty.HELL          # 模拟上一局地狱残留
	_gl.state = GameConst.GameStatus.MENU
	_gl._on_menu_start_daily()
	_check("D1 每日启动后 _difficulty=NORMAL（原继承上一局地狱）",
		_gl._difficulty == GameConst.Difficulty.NORMAL, "d=%d" % _gl._difficulty)
	_gl.state = GameConst.GameStatus.MENU


# ═══ E fission 首发难度门 ═══════════════════════════════════════
func _test_e_fission_gate() -> void:
	print("── E fission 自定义首发难度门 ──")
	# 地狱限定武器（W13 阔剑 melee 族）作自定义 → 普通局回落手枪
	_gl._difficulty = GameConst.Difficulty.NORMAL
	var saved_cw: String = Meta.custom_weapon_id          # 内存字段直改（不走写口——持久
	Meta.custom_weapon_id = "W13_great_sword"             # 写+解锁守卫会拒未解锁档，测试零污染）
	var got := _gl._starting_weapon_id(&"fission")
	_check("E1 普通难度自定义地狱武器（W13）→ 回落 W1",
		got == _gl.STARTING_WEAPON_ID, "got=%s" % String(got))
	_gl._difficulty = GameConst.Difficulty.HELL
	var got2 := _gl._starting_weapon_id(&"fission")
	_check("E2 地狱难度 W13 放行", got2 == &"W13_great_sword", "got=%s" % String(got2))
	Meta.custom_weapon_id = saved_cw                      # 内存还原（不落盘）
	_gl._difficulty = GameConst.Difficulty.NORMAL


# ═══ F 源码锚 ══════════════════════════════════════════════════
func _test_f_source_anchors() -> void:
	print("── F 源码锚（红卡排除/横幅抽公共/消歧/SpellRing） ──")
	var gl_src := _read("res://scripts/loop/game_loop.gd")
	_check("F1 溢出批红卡门：_pick_merged_card 排除 SUBLIME（R245 遗留 a）",
		gl_src.contains("CardGenerator.CardKind.SUBLIME") and gl_src.contains("for _retry in range(20)"))
	_check("F2 横幅抽公共（continue_run 补发复用）",
		gl_src.contains("func _append_difficulty_intro_lines()")
			and gl_src.count("_append_difficulty_intro_lines()") >= 3)
	_check("F3 保底遗物段在位", gl_src.contains("relic_guarantee"))
	var menu_src := _read("res://scripts/ui/menu_screen.gd")
	_check("F4 词缀消歧：选关/每日前缀「祝」→「兆」（前缀无「祝　」残留）",
		menu_src.contains('"兆　%s"') and not menu_src.contains('"祝　%s"')
			and menu_src.contains('_make_daily_row("兆"'))
	_check("F5 fission 候选难度门（菜单侧 _sel_difficulty 过滤）",
		menu_src.contains("weapon_difficulty_min(sid) > _sel_difficulty"))
	var en_src := _read("res://scripts/entities/enemy/enemy.gd")
	_check("F6 SpellRing 进度弧推进（宿主 tick 驱动）",
		en_src.contains("_spell_ring.progress = minf(_spell_ring.progress + p_game_delta / _spell_delay")
			and en_src.contains("var _spell_ring: Telegraph.TelegraphCircle"))
	var rh_src := _read("res://scripts/loop/relic_handler.gd")
	_check("F7 防御六件分发在位（霜寒 player_hit 臂 / mine_dodged 直连 / dr 维护）",
		rh_src.contains("REL_EF_FROST_WARD") and rh_src.contains("_on_mine_dodged_relic")
			and rh_src.contains("_maintain_relic_dr"))
	var pyre_src := _read("res://resources/relics/REL_PYRE.tres")
	_check("F8 PYRE 文案明示基数（不吃乘区）", pyre_src.contains("不吃伤害乘区"))
	var hud_src := _read("res://scripts/ui/hud.gd")
	_check("F9 toast 多行帽（TOAST_MAX_LINES）+ /10.0 常量化",
		hud_src.contains("TOAST_MAX_LINES") and hud_src.contains("Player.TEMP_SHIELD_TIME")
			and not hud_src.contains("t_left / 10.0"))


func _read(p_path: String) -> String:
	var f := FileAccess.open(p_path, FileAccess.READ)
	if f == null:
		return ""
	var content := f.get_as_text()
	f.close()
	return content

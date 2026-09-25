# tests/runner/r187_rework_cases.gd
# R187 武器五方向重做整案·验收用例体（由 test_r187_rework.gd 入口加载）。
# 真源：docs/design/R187_WEAPON_REWORK.md §2.1~§2.5 五方向 Acceptance 全量映射，
# 方向键口径：laser / prism / rockets / pistol / orbit。
# 夹具口径：seed(42) + GameLoop 真件（main.tscn 全栈启动）+ 静止敌 + DT=1/120 手动
# 计帧驱动（E-03 帧戳推进）；伤害探针用 crit=0 副本数据 + meta 修正归零保证确定性。
# 暴露的实现缺陷不改实现——按验收规格断言，FAIL 项列入交付报告。
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _subbeam_kinds: Array[int] = []            # laser_subbeam_spawned 归属字段记录
var _mirror_banner: String = ""                # mirror_formed 横幅记录


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	EventBus.laser_subbeam_spawned.connect(_on_subbeam_spawned)
	EventBus.mirror_formed.connect(_on_mirror_formed)
	# ── 数据契约层（五方向 .tres / 词条 / validator / 表现文案） ──
	_test_data_contract()
	# ── laser（W4 裂片棱镜） ──
	_test_laser_default_single_beam()
	_test_laser_stack_hardcap()
	_test_laser_focus_ownership()
	_test_laser_scorch_single_pool()
	_test_laser_budget_and_dps()
	_test_laser_r183_copy()
	# ── pistol（W1 并行弹幕×跳弹增值） ──
	_test_pistol_anchors()
	_test_pistol_formation_geometry()
	_test_pistol_bounce_axis()
	_test_pistol_volley_state()
	_test_pistol_distinction()
	# ── rockets（W6/W7 蜂群与攻城锤） ──
	_test_rocket_volley_behavior()
	_test_rocket_fuse_coaxial()
	_test_rocket_r183_reduction_and_soak()
	_test_rocket_blast_tier()
	# ── prism（W5 万镜回廊） ──
	_test_prism_whiteboard()
	_test_prism_permanence()
	_test_prism_buff_conduction()
	_test_prism_ele_single_source()
	_test_prism_capacity_cap()
	_test_prism_tempo_budget_pointer()
	_test_prism_r183_exclusion()
	# ── orbit（W8 蓄能轨道） ──
	_test_orbit_r186_removal()
	_test_orbit_charge_determinism()
	_test_orbit_detonate_gates()
	_test_orbit_cap_and_copies()
	_test_orbit_pulse_cdr_cards()
	_test_orbit_dps_probes()
	_test_review1_fixes()
	EventBus.laser_subbeam_spawned.disconnect(_on_subbeam_spawned)
	EventBus.mirror_formed.disconnect(_on_mirror_formed)
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("R187 用例分账：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


func total_count() -> int:
	return _pass + _fail


# ── 通用夹具 ──────────────────────────────────────────────────────
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
	_gl.player.global_position = Vector2(360.0, 640.0)
	Meta.set_setting("shake_on", true)             # 震屏分档断言前置（默认 true，显式钉死）


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
		_failures.append("%s | %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _on_subbeam_spawned(p_owner_kind: int) -> void:
	_subbeam_kinds.append(int(p_owner_kind))


func _on_mirror_formed(p_text: String) -> void:
	_mirror_banner = String(p_text)


func _add(p_id: StringName) -> WeaponBase:
	return _gl.player.add_weapon(_gl.registry.get_weapon(p_id))


func _make_w(p_id: StringName, p_level: int = 1, p_no_crit: bool = false) -> WeaponBase:
	# 装配真件（add_weapon 全依赖注入）；no_crit = 副本数据去暴击（伤害探针确定性）
	var w: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(p_id))
	if w == null:
		return null
	if p_no_crit:
		w.data = w.data.duplicate(true)
		w.data.crit_rate = 0.0
	w.level = clampi(p_level, 1, 5)
	w.meta_atk_pct = 0.0
	w.call("_invalidate_panel")
	return w


func _kill_weapon(p_w: WeaponBase) -> void:
	# 组间回收：弹/束清池 + 摘槽 + 立即释放（free 触发 _exit_tree——束统一回收）
	if p_w == null or not is_instance_valid(p_w):
		return
	for pool_id in [&"projectile", &"homing"]:
		var pool: ProjectilePool = _gl.pools[pool_id]
		var snapshot: Array = pool.active_projectiles().duplicate()
		for p in snapshot:
			if p is ProjectileBase and (p as ProjectileBase).weapon_uid == p_w.uid:
				(p as ProjectileBase).nullify()
	var beams_v: Variant = p_w.get("active_beams")
	if beams_v is Array:
		for b in (beams_v as Array):
			if b != null and is_instance_valid(b) and b.is_live():
				b._recycle()
	var slots: Array = _gl.player.weapon_slots
	for i in range(slots.size()):
		if slots[i] == p_w:
			slots[i] = null
	p_w.free()


func _wipe_weapons() -> void:
	# 全场清场（段落隔离）：复制体/镜面/武器槽/弹池
	for copy in _gl.player._summon_copies.duplicate():
		if copy != null and is_instance_valid(copy):
			copy.free()
	_gl.player._summon_copies.clear()
	_gl.player.clear_mirrors()
	for child in _gl.player.get_children():
		if child is MirrorImage:
			(child as Node).free()
	var slots: Array = _gl.player.weapon_slots
	for i in range(slots.size()):
		var w: Variant = slots[i]
		if w != null and is_instance_valid(w):
			slots[i] = null
			_kill_weapon(w)
	for pool_id in [&"projectile", &"homing"]:
		var pool: ProjectilePool = _gl.pools[pool_id]
		var snapshot: Array = pool.active_projectiles().duplicate()
		for p in snapshot:
			if p is ProjectileBase:
				(p as ProjectileBase).nullify()


func _spawn_e(p_pos: Vector2, p_hp: float = 1000000.0) -> Node2D:
	# 静止夹具敌（E1_grunt resist 0——w8_charge 同款；速度 0 几何确定性）
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


func _adv() -> void:
	GameConfig.advance_frame()                     # E-03 帧戳推进（灼焦帧闸/幂等键时钟）


func _drive_weapon(p_w: WeaponBase, p_ticks: int) -> void:
	for i in range(p_ticks):
		_adv()
		p_w.tick(DT)


func _drive_player(p_ticks: int) -> void:
	for i in range(p_ticks):
		_adv()
		_gl.player.tick(DT, Vector2.ZERO)


func _threshold_of(p_data: WeaponData, p_id: StringName) -> Dictionary:
	for tt in p_data.threshold_traits:
		if StringName(str(tt.get("threshold_id", ""))) == p_id:
			return tt
	return {}


func _has_threshold(p_data: WeaponData, p_id: StringName) -> bool:
	return not _threshold_of(p_data, p_id).is_empty()


func _threshold_threshold(p_data: WeaponData, p_id: StringName) -> float:
	return float(_threshold_of(p_data, p_id).get("threshold", -1.0))


func _farray(p_seg: Dictionary, p_key: String) -> Array[float]:
	var out: Array[float] = []
	var raw: Variant = p_seg.get(p_key, null)
	if raw is Array:
		for v in (raw as Array):
			out.append(float(v))
	return out


func _approx(p_a: float, p_b: float, p_tol: float) -> bool:
	return absf(p_a - p_b) <= p_tol


func _validator_errors(p_data: WeaponData) -> Array:
	var out: Array = []
	for v in DataValidator.new().validate_weapon(p_data):
		if String(v.get("severity", "error")) == "error":
			out.append(v)
	return out


# ── 数据契约层（五方向 .tres / 词条 / validator / 图标 / 文案） ────
func _test_data_contract() -> void:
	print("── 数据契约：五方向 .tres 锚 / 词条上架 / DataValidator / 图标文案 ──")
	# 全武器 validator 零 error（R187 新键过域 + 真删零告警的总口径）
	var total_errors: Array = []
	for wid in _gl.registry.weapons.keys():
		var w: WeaponData = _gl.registry.weapons[wid]
		total_errors.append_array(_validator_errors(w))
	_check("契约：registry 全 10 武器 DataValidator 零 error", total_errors.is_empty(),
		str(total_errors))
	# ── laser：W4 数据锚（§2.1 Design 1/2/10 + 验收 1 前置） ──
	var w4: WeaponData = _gl.registry.get_weapon(&"W4_pulse_beam")
	var l4: Dictionary = w4.laser
	var atk4 := _farray_level_atks(w4)
	_check("laser·锚：base_atk 6/7/7/9/11（注释 A3 tick_atk 兑现）",
		atk4 == [6.0, 7.0, 7.0, 9.0, 11.0], str(atk4))
	var rof4: Array[float] = []
	for lv in w4.upgrade_table:
		rof4.append(float(lv.rof))
	_check("laser·锚：跳频=L 表 rof 8/8/9/9/9", rof4 == [8.0, 8.0, 9.0, 9.0, 9.0], str(rof4))
	_check("laser·锚：死键真删（pulse_duration/tick_rate）",
		not l4.has("pulse_duration") and not l4.has("tick_rate"), str(l4.keys()))
	_check("laser·锚：sub_ratio_levels=[0.6,0.6,0.6,0.6,0.75]",
		_farray(l4, "sub_ratio_levels") == [0.6, 0.6, 0.6, 0.6, 0.75],
		str(l4.get("sub_ratio_levels")))
	_check("laser·锚：scorch_max_layers_levels=[5,5,5,5,8]（L5 八层）",
		_farray(l4, "scorch_max_layers_levels") == [5.0, 5.0, 5.0, 5.0, 8.0],
		str(l4.get("scorch_max_layers_levels")))
	_check("laser·锚：TH_PRISM_CHOIR 在册（sub_beam_count≥3 / EF_CHOIR）",
		_threshold_of(w4, &"TH_PRISM_CHOIR").get("metric", "") == "sub_beam_count"
		and _threshold_of(w4, &"TH_PRISM_CHOIR").get("effect_id", "") == &"EF_CHOIR"
		and _threshold_threshold(w4, &"TH_PRISM_CHOIR") == 3.0)
	_check("laser·锚：TH_CRIT_SHARD 0.6→0.35 且弹道死三声明退役",
		_threshold_threshold(w4, &"TH_CRIT_SHARD") == 0.35
		and not _has_threshold(w4, &"TH_SIZE_NOVA")
		and not _has_threshold(w4, &"TH_FRACTAL_ECHO")
		and not _has_threshold(w4, &"TH_BOUNCE_ETERNAL"))
	# ── prism：W5 数据锚（§2.2 Design 1/3 + 验收 9） ──
	var w5: WeaponData = _gl.registry.get_weapon(&"W5_prism")
	var l5: Dictionary = w5.laser
	_check("prism·锚：refract 五键真删",
		not l5.has("refract_beams") and not l5.has("refract_ratio")
		and not l5.has("refract_depth") and not l5.has("refract_beams_levels")
		and not l5.has("refract_ratio_levels"), str(l5.keys()))
	_check("prism·锚：mirrors_count_levels=[1,1,2,2,3]",
		_farray(l5, "mirrors_count_levels") == [1.0, 1.0, 2.0, 2.0, 3.0],
		str(l5.get("mirrors_count_levels")))
	_check("prism·锚：mirror_ratio_levels=[0.4,0.45,0.5,0.55,0.6]",
		_farray(l5, "mirror_ratio_levels") == [0.4, 0.45, 0.5, 0.55, 0.6],
		str(l5.get("mirror_ratio_levels")))
	_check("prism·锚：mirror_budget_per_s=600（落 W5 数据不落全局表）+ mirror_laser_cap=2",
		_approx(float(l5.get("mirror_budget_per_s", 0.0)), 600.0, 0.001)
		and int(l5.get("mirror_laser_cap", -1)) == 2)
	var atk5 := _farray_level_atks(w5)
	_check("prism·锚：校准锚束 tick_atk 7/9/11/14/15 不动",
		atk5 == [7.0, 9.0, 11.0, 14.0, 15.0], str(atk5))
	_check("prism·锚：TH_MIRROR_CHOIR 在册 + CRIT_SHARD 0.35",
		_has_threshold(w5, &"TH_MIRROR_CHOIR")
		and _threshold_threshold(w5, &"TH_MIRROR_CHOIR") == 3.0
		and _threshold_threshold(w5, &"TH_CRIT_SHARD") == 0.35)
	var note5 := GameConst.weapon_note("W5_prism")
	_check("prism·读感：weapon_note 含「镜」禁「折射/分光」",
		note5.contains("镜") and not note5.contains("折射") and not note5.contains("分光"),
		note5)
	# ── rockets：W6/W7 30% 规格（§2.3 Design 1/2/4/6 + 验收 1） ──
	var w6: WeaponData = _gl.registry.get_weapon(&"W6_micro_missile")
	var w7: WeaponData = _gl.registry.get_weapon(&"W7_cluster_rocket")
	var h6: Dictionary = w6.homing
	var h7: Dictionary = w7.homing
	var atk6 := _farray_level_atks(w6)
	var atk7 := _farray_level_atks(w7)
	var blast := _farray(h6, "blast_r_levels")
	var ratios_ok := blast.size() == 5
	var mean_blast := 0.0
	for i in range(blast.size()):
		var r: float = blast[i] / 110.0
		mean_blast += r
		if r < 0.25 or r > 0.36:
			ratios_ok = false
	mean_blast /= float(blast.size())
	_check("rockets·30%：逐级 blast_r/110∈[0.25,0.36] 均值∈[0.27,0.34]",
		ratios_ok and mean_blast >= 0.27 and mean_blast <= 0.34,
		"blast=%s mean=%.3f" % [str(blast), mean_blast])
	var splash_ok := true
	var mean_splash := 0.0
	for i in range(5):
		var s: float = (0.6 * atk6[i]) / atk7[i]
		mean_splash += s
		if s > 0.40:
			splash_ok = false
	mean_splash /= 5.0
	_check("rockets·30%：(0.6×W6.atk)/W7.atk 逐级 ≤0.40 均值∈[0.28,0.33]",
		splash_ok and mean_splash >= 0.28 and mean_splash <= 0.33,
		"mean=%.3f" % mean_splash)
	_check("rockets·30%：blast_atk_ratio W6=0.6 / W7=1.0",
		_approx(float(h6.get("blast_atk_ratio", 0.0)), 0.6, 0.0001)
		and _approx(float(h7.get("blast_atk_ratio", 0.0)), 1.0, 0.0001))
	_check("rockets·W6：atk 18/22/22/27/32 + volley_count_levels=[1,1,2,2,3]"
		+ " + proj_speed_init 240→420",
		atk6 == [18.0, 22.0, 22.0, 27.0, 32.0]
		and _farray(h6, "volley_count_levels") == [1.0, 1.0, 2.0, 2.0, 3.0]
		and _approx(float(h6.get("proj_speed_init", 0.0)), 420.0, 0.001),
		"%s %s" % [str(atk6), str(h6.get("proj_speed_init"))])
	_check("rockets·W7 现网冻结：atk 38/38/46/54/68 + sub [5,6,6,8,8] + blast_r 110",
		atk7 == [38.0, 38.0, 46.0, 54.0, 68.0]
		and _farray(h7, "sub_count_levels") == [5.0, 6.0, 6.0, 8.0, 8.0]
		and _approx(float(h7.get("blast_r", 0.0)), 110.0, 0.001)
		and _approx(float(atk7[4] / w7.upgrade_table[4].cd), 26.15, 0.1))
	_check("rockets·阈值分叉：W6 含 TH_SWARM_NOVA 不含 TH_SIZE_NOVA；W7 保留 TH_SIZE_NOVA",
		_has_threshold(w6, &"TH_SWARM_NOVA") and not _has_threshold(w6, &"TH_SIZE_NOVA")
		and _has_threshold(w7, &"TH_SIZE_NOVA"))
	# ── pistol：W1 五级表重排（§2.4 Design 1/2/4 + 验收 1/7） ──
	var w1: WeaponData = _gl.registry.get_weapon(&"W1_pistol")
	var b1: Dictionary = w1.ballistic
	_check("pistol·锚：upgrade_table 恰 5 项", w1.upgrade_table.size() == 5)
	var dps_ok := true
	var dps_expect: Array[float] = [70.0, 80.0, 121.0, 143.0, 198.0]
	for i in range(5):
		var lv = w1.upgrade_table[i]
		var dps := float(lv.base_atk) * float(lv.rof) * float(lv.pellets)
		if not _approx(dps, dps_expect[i], 0.5):
			dps_ok = false
	_check("pistol·锚：面板 DPS 70/80/121/143/198±0.5", dps_ok)
	var pierce_ok := true
	var pellet_ok := true
	for i in range(5):
		if int(w1.upgrade_table[i].pierce) != [1, 1, 2, 2, 2][i]:
			pierce_ok = false
		if int(w1.upgrade_table[i].pellets) != [1, 1, 2, 2, 3][i]:
			pellet_ok = false
	_check("pistol·锚：pierce 1/1/2/2/2（L4 倒退修复）+ pellets 1/1/2/2/3",
		pierce_ok and pellet_ok)
	_check("pistol·锚：lateral_gap [0,0,12,12,12] / converge [0,0,0,0,0.55]"
		+ " / bounce [0,0,1,1,2] / bounce_amp 0.12 cap 1.0",
		_farray(b1, "lateral_gap_levels") == [0.0, 0.0, 12.0, 12.0, 12.0]
		and _farray(b1, "converge_pct_levels") == [0.0, 0.0, 0.0, 0.0, 0.55]
		and _farray(b1, "bounce_levels") == [0.0, 0.0, 1.0, 1.0, 2.0]
		and _approx(float(b1.get("bounce_amp", 0.0)), 0.12, 0.0001)
		and _approx(float(b1.get("bounce_amp_cap", 0.0)), 1.0, 0.0001))
	_check("pistol·锚：TH_VOLLEY_STATE(pellets≥6/EF_VOLLEY) + TH_BANK_SHOT(bounce≥12/EF_BANK)",
		_threshold_of(w1, &"TH_VOLLEY_STATE").get("metric", "") == "pellets"
		and _threshold_of(w1, &"TH_VOLLEY_STATE").get("effect_id", "") == &"EF_VOLLEY"
		and _threshold_threshold(w1, &"TH_VOLLEY_STATE") == 6.0
		and _threshold_of(w1, &"TH_BANK_SHOT").get("effect_id", "") == &"EF_BANK"
		and _threshold_threshold(w1, &"TH_BANK_SHOT") == 12.0)
	# ── orbit：W8 蓄能数据键全落 melee 段（§2.5 Design 8/9 + 验收 2） ──
	var w8d: WeaponData = _gl.registry.get_weapon(&"W8_orbit_field")
	var m8: Dictionary = w8d.melee
	_check("orbit·锚：charge_max=5 / charge_gain_cd_levels=[0.5,0.45,0.4,0.35,0.3]",
		int(m8.get("charge_max", 0)) == 5
		and _farray(m8, "charge_gain_cd_levels") == [0.5, 0.45, 0.4, 0.35, 0.3],
		str(m8.get("charge_max")) + str(m8.get("charge_gain_cd_levels")))
	_check("orbit·锚：detonate_mult=5 / radius=90 / global_icd=0.5 / pulse_cd=3.0 / blade_cap=8",
		_approx(float(m8.get("detonate_mult", 0.0)), 5.0, 0.001)
		and _approx(float(m8.get("detonate_radius", 0.0)), 90.0, 0.001)
		and _approx(float(m8.get("detonate_global_icd", 0.0)), 0.5, 0.001)
		and _approx(float(m8.get("pulse_cd", 0.0)), 3.0, 0.001)
		and int(m8.get("effective_blade_cap", 0)) == 8)
	_check("orbit·锚：投射物死三声明退役 + ECHO@8 / RING@60 + CRIT_SHARD 0.35",
		not _has_threshold(w8d, &"TH_SIZE_NOVA")
		and not _has_threshold(w8d, &"TH_FRACTAL_ECHO")
		and not _has_threshold(w8d, &"TH_BOUNCE_ETERNAL")
		and _threshold_threshold(w8d, &"TH_DETONATION_ECHO") == 8.0
		and _threshold_threshold(w8d, &"TH_RING_PRESSURE") == 60.0
		and _threshold_threshold(w8d, &"TH_CRIT_SHARD") == 0.35)
	var note8 := GameConst.weapon_note("W8_orbit_field")
	_check("orbit·读感：weapon_note 含「蓄能/引爆」禁「护盾」",
		note8.contains("蓄能") and not note8.contains("护盾"), note8)
	# ── 新词条 22 个全局唯一 + 关键 params + 共享改单 ──
	var seen: Dictionary = {}
	var dup := false
	for tid in _gl.registry.traits.keys():
		if seen.has(tid):
			dup = true
		seen[tid] = true
	_check("词条：registry traits id 全局唯一不撞名", not dup)
	var new_ids: Array[StringName] = [
		&"MEC_SPLIT_PRISM", &"MEC_BEAM_TRACK", &"MEC_BEAM_FAN", &"MEC_BEAM_COFOCUS",
		&"MEC_PHASE_SYNC", &"MEC_BEAM_LAG", &"MEC_BEAM_SPECTRA", &"TH_PRISM_CHOIR",
		&"MEC_MIRROR_SPLIT", &"MEC_MIRROR_LOCK", &"MEC_MIRROR_WEIGHT", &"MEC_MIRROR_TEMPO",
		&"TH_MIRROR_CHOIR", &"MEC_HIVE_RACK", &"MEC_FUSE_COAT", &"MEC_FUSE_DETONATE",
		&"TH_SWARM_NOVA", &"MEC_PARALLEL_CAL", &"MEC_RICOCHET_HALL", &"TH_VOLLEY_STATE",
		&"TH_BANK_SHOT", &"MEC_CRITICAL_MASS", &"MEC_CHAIN_DETONATE",
		&"TH_DETONATION_ECHO", &"TH_RING_PRESSURE",
	]
	var missing: Array[StringName] = []
	for id in new_ids:
		if _gl.registry.get_trait(id) == null:
			missing.append(id)
	_check("词条：R187 新词条 25 个全部在册", missing.is_empty(), str(missing))
	var r6 := _gl.registry.get_trait(&"MEC_HIVE_RACK")
	var r7 := _gl.registry.get_trait(&"MEC_FUSE_DETONATE")
	var rm := _gl.registry.get_trait(&"MEC_MIRROR_SPLIT")
	var rc := _gl.registry.get_trait(&"MEC_CRITICAL_MASS")
	_check("词条：required_weapon 门（HIVE/COAT→W6；DETONATE→W7；MIRROR_SPLIT/TEMPO→W5"
		+ "；CRITICAL_MASS/CHAIN→W8）",
		(r6.params.get("required_weapon", []) as Array).has(&"W6_micro_missile")
		and (r7.params.get("required_weapon", []) as Array).has(&"W7_cluster_rocket")
		and (rm.params.get("required_weapon", []) as Array).has(&"W5_prism")
		and (rc.params.get("required_weapon", []) as Array).has(&"W8_orbit_field"))
	_check("共享改单：MEC_KNOCK required_forms 含 3（W8 解锁）+ MEC_FRACTAL inheritable=true",
		(_gl.registry.get_trait(&"MEC_KNOCK").params.get("required_forms", [])
			as Array).has(3)
		and bool(_gl.registry.get_trait(&"MEC_FRACTAL").inheritable))
	_check("共享改单：COUNT_TRAIT_IDS 增补 SPLIT_PRISM/MIRROR_SPLIT/HIVE_RACK",
		CardGenerator.COUNT_TRAIT_IDS.has(&"MEC_SPLIT_PRISM")
		and CardGenerator.COUNT_TRAIT_IDS.has(&"MEC_MIRROR_SPLIT")
		and CardGenerator.COUNT_TRAIT_IDS.has(&"MEC_HIVE_RACK"))
	# validator 负例（rockets 验收 4 + pistol 验收 7）
	var bad6: WeaponData = w6.duplicate(true)
	(bad6.homing)["volley_count_levels"] = [0.0, 1.0, 2.0, 2.0, 3.0]
	_check("validator 负例：volley_count 越域（<1）报 error",
		not _validator_errors(bad6).is_empty())
	var bad6b: WeaponData = w6.duplicate(true)
	(bad6b.homing)["blast_r_levels"] = [30.0, 32.0, 34.0, 36.0, 200.0]
	_check("validator 负例：blast_r_levels 逐级越 128 报 error",
		not _validator_errors(bad6b).is_empty())
	var bad6c: WeaponData = w6.duplicate(true)
	(bad6c.homing)["blast_atk_ratio"] = 1.5
	_check("validator 负例：blast_atk_ratio >1 报 error",
		not _validator_errors(bad6c).is_empty())
	var bad6d: WeaponData = w6.duplicate(true)
	(bad6d.homing)["volley_count_levels"] = [1.0, 1.0, 2.0]
	_check("validator 负例：_levels 长度≠5 报 error（通用补口）",
		not _validator_errors(bad6d).is_empty())
	var bad1: WeaponData = w1.duplicate(true)
	(bad1.ballistic)["lateral_gap_levels"] = [0.0, 0.0, 12.0]
	_check("validator 负例：ballistic lateral_gap_levels 长度≠5 报 error",
		not _validator_errors(bad1).is_empty())
	var bad1b: WeaponData = w1.duplicate(true)
	(bad1b.ballistic)["bounce_levels"] = [0.0, 0.0, 6.0, 1.0, 2.0]
	_check("validator 负例：bounce_levels 逐级越 [0,5] 域报 error",
		not _validator_errors(bad1b).is_empty())
	# EF 白名单反证：悬空 effect_id threshold 被剔除（check_references 告警 + 移除）
	var original_th: Array = w1.threshold_traits
	w1.threshold_traits = original_th.duplicate()
	w1.threshold_traits.append({
		"threshold_id": &"TH_NOPE", "metric": "pellets", "threshold": 6.0,
		"effect_id": &"EF_NOPE", "params": {},
	})
	var refs: Array = DataValidator.new().check_references(_gl.registry)
	var th_removed: bool = w1.threshold_traits.size() == original_th.size()
	w1.threshold_traits = original_th
	_check("validator 反证：EF 未入白名单 → threshold 条目剔除 + 告警",
		th_removed and refs.size() > 0,
		"removed=%s issues=%d" % [str(th_removed), refs.size()])
	# 图标互异（§三.1：W5 棱形镜子与其余 9 武器像素互异）
	var icon_hashes: Array = []
	for wid in _gl.registry.weapons.keys():
		var tex := TextureFactory.weapon_icon(wid)
		var img := tex.get_image()
		icon_hashes.append(hash(img.get_data()))
	var icon_dup := false
	for a in range(icon_hashes.size()):
		for b in range(a + 1, icon_hashes.size()):
			if icon_hashes[a] == icon_hashes[b]:
				icon_dup = true
	_check("表现：10 武器图标像素两两互异（含 W5 棱镜新图标）", not icon_dup,
		str(icon_hashes))
	_wipe_weapons()


func _farray_level_atks(p_data: WeaponData) -> Array[float]:
	var out: Array[float] = []
	for lv in p_data.upgrade_table:
		out.append(float(lv.base_atk))
	return out


# ── laser（W4 裂片棱镜） ──────────────────────────────────────────
func _test_laser_default_single_beam() -> void:
	print("── laser·验收 1：默认单束（常驻 + 锁定最近敌） ──")
	LaserBeam.scorch_pool_reset()
	_clear_enemies()
	var w4 := _make_w(&"W4_pulse_beam")
	_check("laser·验收1 前置：W4 装配", w4 != null)
	if w4 == null:
		return
	var e := _spawn_e(Vector2(360.0, 600.0))
	w4.try_fire()
	var beams: Array = _live_beams(w4)
	_check("laser·验收1：try_fire 后 laser 段计数==1（白板期单主束）", beams.size() == 1,
		str(beams.size()))
	if beams.size() != 1:
		_kill_weapon(w4)
		_clear_enemies()
		return
	var main: LaserBeam = beams[0]
	_check("laser·验收1：lifetime==0（常驻——删 pulse_duration 后缺省 0）",
		main.lifetime == 0.0, "lifetime=%.3f" % main.lifetime)
	_drive_weapon(w4, 16)                          # 1/8s 首跳结算 → last_hit_uid 落值
	_check("laser·验收1：主束锁定最近敌", main.last_hit_uid == int(e.get("uid")),
		"hit=%d expect=%d" % [main.last_hit_uid, int(e.get("uid"))])
	_check("laser·验收1：pkg3 激光段契约保留（try_fire 返回 true 维持全自动）",
		w4.try_fire())
	_kill_weapon(w4)
	_clear_enemies()


func _test_laser_stack_hardcap() -> void:
	print("── laser·验收 2：叠束与硬帽（×0.6/0.75 + 互斥 + 第 4 张拒） ──")
	LaserBeam.scorch_pool_reset()
	_clear_enemies()
	var w4 := _make_w(&"W4_pulse_beam")
	if w4 == null:
		_check("laser·验收2 前置：W4 装配", false)
		return
	var prism := _gl.registry.get_trait(&"MEC_SPLIT_PRISM")
	var e1 := _spawn_e(Vector2(360.0, 600.0))
	var e2 := _spawn_e(Vector2(300.0, 540.0))
	var e3 := _spawn_e(Vector2(430.0, 520.0))
	var e4 := _spawn_e(Vector2(330.0, 420.0))
	for i in range(3):
		w4.attach_trait(prism)
	w4.try_fire()
	var beams: Array = _live_beams(w4)
	_check("laser·验收2：3×MEC_SPLIT_PRISM → 段数==4（1 主 + 3 副）", beams.size() == 4,
		str(beams.size()))
	var subs: Array = []
	var main: LaserBeam = null
	for b in beams:
		if b.sub_beam:
			subs.append(b)
		else:
			main = b
	var mult_ok := subs.size() == 3
	for s in subs:
		if not _approx(s.dmg_mult, 0.6, 0.000001):
			mult_ok = false
	_check("laser·验收2：副束 dmg_mult==主束×0.6（L1-4）±1e-6",
		mult_ok and _approx(main.dmg_mult, 1.0, 0.000001),
		"subs=%d" % subs.size())
	var uid_set: Dictionary = {}
	for s in subs:
		uid_set[int(s.target_uid)] = true
	var expect := {int(e1.get("uid")): true, int(e2.get("uid")): true,
		int(e3.get("uid")): true, int(e4.get("uid")): true}
	var excl_ok: bool = uid_set.size() == 3
	for s in subs:
		if not expect.has(int(s.target_uid)):
			excl_ok = false
	_drive_weapon(w4, 16)
	var main_hit: int = main.last_hit_uid if main != null else 0
	_check("laser·验收2：副束目标两两互斥且落在 4 夹具内（不与主束目标重合）",
		excl_ok and main_hit == int(e1.get("uid")),
		"uids=%s main_hit=%d" % [str(uid_set.keys()), main_hit])
	# 第 4 张：stack_max=3 拒绝 + DebugStats 计数 +1
	var rej0: int = DebugStats.get_counter(&"trait_attach_rejected_stack")
	var ok4: bool = w4.attach_trait(prism)
	_check("laser·验收2：第 4 张被 stack_max=3 拒绝",
		not ok4 and DebugStats.get_counter(&"trait_attach_rejected_stack") == rej0 + 1,
		"ok=%s" % str(ok4))
	_check("laser·验收2：拒绝后段数仍==4（副束 cap 生效）", _live_beams(w4).size() == 4)
	_kill_weapon(w4)
	_clear_enemies()
	# L5 曲线：×0.75（双敌——单敌会走重叠回退 0.5，非真副束寻的）
	var w5lv := _make_w(&"W4_pulse_beam", 5, true)
	_spawn_e(Vector2(360.0, 600.0))
	_spawn_e(Vector2(300.0, 540.0))
	w5lv.attach_trait(prism)
	w5lv.try_fire()
	var ratio_ok := false
	var sub_count := 0
	for b in _live_beams(w5lv):
		if b.sub_beam:
			sub_count += 1
			if _approx(b.dmg_mult, 0.75, 0.000001) and not b.overlap_fallback:
				ratio_ok = true
	_check("laser·验收2：L5 副束 dmg_mult==主束×0.75±1e-6", ratio_ok and sub_count >= 1,
		"subs=%d" % sub_count)
	_kill_weapon(w5lv)
	_clear_enemies()


func _test_laser_focus_ownership() -> void:
	print("── laser·验收 3：聚焦归属（主束爬坡 / 副束恒 1 / PHASE_SYNC / CDR 换挂） ──")
	LaserBeam.scorch_pool_reset()
	_clear_enemies()
	# 主束 6.7s → ×2
	var w4 := _make_w(&"W4_pulse_beam")
	_spawn_e(Vector2(360.0, 600.0))
	_drive_weapon(w4, 830)                         # 6.92s ≥ 6.7s
	var main := _main_beam_of(w4)
	_check("laser·验收3：主束同目标 6.7s focus_mult==2.0±0.05",
		main != null and _approx(main.focus_mult, 2.0, 0.05),
		"mult=%.3f" % (main.focus_mult if main != null else -1.0))
	# 副束 focus_mult 恒 1.0
	var prism := _gl.registry.get_trait(&"MEC_SPLIT_PRISM")
	_spawn_e(Vector2(300.0, 540.0))
	w4.attach_trait(prism)
	w4.try_fire()
	var sub_ok := false
	for b in _live_beams(w4):
		if b.sub_beam:
			sub_ok = sub_ok or _approx(b.focus_mult, 1.0, 0.000001)
			sub_ok = sub_ok and _approx(b.focus_mult, 1.0, 0.000001)
	_check("laser·验收3：副束 focus_mult 恒 1.0（聚焦主束专属）", sub_ok)
	_kill_weapon(w4)
	_clear_enemies()
	# PHASE_SYNC：3.35s 即满
	var w4b := _make_w(&"W4_pulse_beam")
	_spawn_e(Vector2(360.0, 600.0))
	_spawn_e(Vector2(300.0, 540.0))
	_spawn_e(Vector2(430.0, 520.0))
	w4b.attach_trait(prism)
	w4b.attach_trait(prism)
	w4b.attach_trait(_gl.registry.get_trait(&"MEC_PHASE_SYNC"))
	w4b.try_fire()
	_check("laser·验收3 前置：副束≥2 时爬坡速率 30%/s",
		_approx(float(w4b.call("_focus_rate")), 0.30, 0.0001),
		"rate=%.3f" % float(w4b.call("_focus_rate")))
	_drive_weapon(w4b, 410)                        # 3.42s ≥ 3.35s
	var main_b := _main_beam_of(w4b)
	_check("laser·验收3：MEC_PHASE_SYNC 3.35s 即达 ×2", main_b != null
		and _approx(main_b.focus_mult, 2.0, 0.05),
		"mult=%.3f" % (main_b.focus_mult if main_b != null else -1.0))
	_kill_weapon(w4b)
	_clear_enemies()
	# AFF_CDR×4：换目标保留 50% 聚焦进度（更近敌入楔 → 主束换锚，命中 uid 翻转）
	# 布点相对 muzzle_position（化身位≠玩家中心；结算 8Hz → 驱动 ≥1 个结算周期）
	var w4c := _make_w(&"W4_pulse_beam")
	var cdr := _gl.registry.get_trait(&"AFF_CDR")
	for i in range(4):
		w4c.attach_trait(cdr)
	_spawn_e(w4c.muzzle_position() + Vector2(0.0, -60.0))
	_drive_weapon(w4c, 500)                        # 4.17s
	var t0: float = float(w4c.get("_focus_time"))
	_check("laser·验收3 前置：聚焦计时已积累（≈4s）", t0 >= 3.5, "t=%.2f" % t0)
	_spawn_e(w4c.muzzle_position() + Vector2(0.0, -20.0))   # 更近 → 换锚
	_drive_weapon(w4c, 20)                         # ≥1 个跳频结算周期（1/8s）
	var t1: float = float(w4c.get("_focus_time"))
	_check("laser·验收3：AFF_CDR×4 换目标保留 50%±2% 聚焦进度",
		_approx(t1, t0 * 0.5, t0 * 0.02 + 0.05), "t0=%.2f t1=%.2f" % [t0, t1])
	_kill_weapon(w4c)
	_clear_enemies()
	# 对照：无 CDR → 换目标归零（R91 既有契约）
	var w4d := _make_w(&"W4_pulse_beam")
	_spawn_e(w4d.muzzle_position() + Vector2(0.0, -60.0))
	_drive_weapon(w4d, 500)
	_spawn_e(w4d.muzzle_position() + Vector2(0.0, -20.0))
	_drive_weapon(w4d, 20)
	# 0.067 = 翻转清零后残余 tick 的再积累（≥1 结算周期 20 帧——非保留语义）
	_check("laser·验收3：无 AFF_CDR 对照 → 换目标聚焦归零（R91 契约不变）",
		float(w4d.get("_focus_time")) < 0.15,
		"t=%.3f" % float(w4d.get("_focus_time")))
	_kill_weapon(w4d)
	_clear_enemies()


func _test_laser_scorch_single_pool() -> void:
	print("── laser·验收 4：灼焦目标侧单池 + 重叠回退 ──")
	_clear_enemies()
	# 对照：单束 2s → 层数曲线（L1 cap 5）
	var w_a := _make_w(&"W4_pulse_beam")
	var e_c := _spawn_e(Vector2(360.0, 600.0))
	_drive_weapon(w_a, 240)                        # 2.0s
	var layers_single: int = LaserBeam.scorch_layers_of(int(e_c.get("uid")))
	_check("laser·验收4 前置：单束 2s 灼焦达 L1 cap（5 层）", layers_single == 5,
		"layers=%d" % layers_single)
	_kill_weapon(w_a)
	_clear_enemies()
	LaserBeam.scorch_pool_reset()
	# 双束共照同目标：层曲线与单束相等（目标侧单池，不随束数翻倍）
	var w_b := _make_w(&"W4_pulse_beam")
	var w_c := _make_w(&"W4_pulse_beam")
	var e_t := _spawn_e(Vector2(360.0, 600.0))
	w_b.try_fire()
	w_c.try_fire()
	_drive_weapon(w_b, 240)
	_drive_weapon(w_c, 240)
	var layers_dual: int = LaserBeam.scorch_layers_of(int(e_t.get("uid")))
	_check("laser·验收4：两束共照 2s 层数==单束对照（≤8 封顶、单池断言）",
		layers_dual == layers_single, "dual=%d single=%d" % [layers_dual, layers_single])
	_kill_weapon(w_b)
	_kill_weapon(w_c)
	_clear_enemies()
	LaserBeam.scorch_pool_reset()
	# 重叠回退：无多余目标 → 副束并入主束目标 ×0.5、不叠灼焦
	var w_d := _make_w(&"W4_pulse_beam")
	var e_o := _spawn_e(Vector2(360.0, 600.0))
	w_d.attach_trait(_gl.registry.get_trait(&"MEC_SPLIT_PRISM"))
	w_d.try_fire()
	_drive_weapon(w_d, 30)
	var fallback_beam: LaserBeam = null
	var main_d := _main_beam_of(w_d)
	for b in _live_beams(w_d):
		if b.sub_beam:
			fallback_beam = b
	_check("laser·验收4：无多余目标副束并入主束目标（overlap_fallback=true）",
		fallback_beam != null and fallback_beam.overlap_fallback
		and int(fallback_beam.target_uid) == int(e_o.get("uid")),
		"fb=%s" % str(fallback_beam != null))
	_check("laser·验收4：重叠回退伤害 ×0.5（SUB_RATIO_FALLBACK）",
		fallback_beam != null and _approx(fallback_beam.dmg_mult, 0.5, 0.000001),
		"mult=%.3f" % (fallback_beam.dmg_mult if fallback_beam != null else -1.0))
	_drive_weapon(w_d, 210)
	var entry_ok := true
	if main_d != null:
		var pool: Dictionary = LaserBeam._scorch_pool
		var entry: Dictionary = pool.get(int(e_o.get("uid")), {})
		entry_ok = int(entry.get("last_beam", 0)) == main_d.uid
	_check("laser·验收4：重叠回退束不叠灼焦（池 last_beam 恒主束）",
		entry_ok and LaserBeam.scorch_layers_of(int(e_o.get("uid"))) == 5,
		"layers=%d" % LaserBeam.scorch_layers_of(int(e_o.get("uid"))))
	_kill_weapon(w_d)
	_clear_enemies()
	LaserBeam.scorch_pool_reset()


func _test_laser_budget_and_dps() -> void:
	print("── laser·验收 5：池预算 + L5 单体满配 DPS 324.8±5 ──")
	_clear_enemies()
	_check("laser·验收5：laser 池容量 12（不扩）",
		int(GameConfig.get_pool_capacity(&"laser")) == 12,
		str(GameConfig.get_pool_capacity(&"laser")))
	var w4 := _make_w(&"W4_pulse_beam", 5, true)
	if w4 == null:
		_check("laser·验收5 前置：W4 L5 装配", false)
		return
	var prism := _gl.registry.get_trait(&"MEC_SPLIT_PRISM")
	for i in range(3):
		w4.attach_trait(prism)
	# 布局：e1 主束锚（120px，脱离出膛口）；e2/e3/e4 供副束寻的且射线互不穿过
	# （任何副束射线距 e1/>21px——防副束 first_hit 抢结算污染 DPS 探针）
	var e1 := _spawn_e(Vector2(360.0, 520.0))
	_spawn_e(Vector2(260.0, 560.0))
	_spawn_e(Vector2(460.0, 560.0))
	_spawn_e(Vector2(300.0, 420.0))
	w4.try_fire()
	var peak := _live_beams(w4).size()
	_check("laser·验收5：满配 4 段（1+3）峰值 ≤12 预算", peak == 4 and peak <= 12,
		str(peak))
	_drive_weapon(w4, 276)                         # 2.3s → 灼焦满 8 层（L5 cap）
	_check("laser·验收5 前置：目标灼焦满 8 层（L5 scorch cap）",
		LaserBeam.scorch_layers_of(int(e1.get("uid"))) == 8,
		"layers=%d" % LaserBeam.scorch_layers_of(int(e1.get("uid"))))
	w4.set("_focus_time", 6.7)                     # 满聚焦预置（×2 封顶）
	_drive_weapon(w4, 2)
	var main := _main_beam_of(w4)
	_check("laser·验收5 前置：主束 focus_mult==2.0", main != null
		and _approx(main.focus_mult, 2.0, 0.01))
	var settle0: int = main.settle_count if main != null else 0
	var hp0: float = float(e1.hp)
	_drive_weapon(w4, 120)                         # 恰 1.0s 采样窗
	var dps: float = (hp0 - float(e1.hp)) / 1.0
	var settles: int = (main.settle_count - settle0) if main != null else 0
	# L5：tick_atk 11 × 聚焦 2.0 × 满灼焦 1.64 × 跳频 9 = 324.72
	_check("laser·验收5：L5 单体满配 DPS 324.8±5", _approx(dps, 324.72, 5.0),
		"dps=%.2f" % dps)
	_check("laser·验收5：主束每秒结算次数 ≤ 束数×30（跳频钳 [0.5,30]）",
		settles <= 30, "settles=%d" % settles)
	_kill_weapon(w4)
	_clear_enemies()
	LaserBeam.scorch_pool_reset()


func _test_laser_r183_copy() -> void:
	print("── laser·验收 6：R183 复制体只主束 + 灰染 + 归属信号 + W5 束段指纹==1 ──")
	_clear_enemies()
	_subbeam_kinds.clear()
	var w4 := _make_w(&"W4_pulse_beam")
	var e := _spawn_e(Vector2(360.0, 600.0))
	w4.attach_trait(_gl.registry.get_trait(&"MEC_SPLIT_PRISM"))
	w4.try_fire()
	_drive_weapon(w4, 10)
	var body_events := 0
	for k in _subbeam_kinds:
		if k == GameConst.SUBBEAM_OWNER_BODY:
			body_events += 1
	_check("laser·验收6 前置：本体副束派发 laser_subbeam_spawned（BODY）",
		body_events >= 1, "events=%s" % str(_subbeam_kinds))
	# 诺亚复制：只主束 + 灰染
	var copy := _gl.player._make_weapon_copy(w4)
	_check("laser·验收6 前置：复制体构造", copy != null)
	if copy != null:
		_gl.player._summon_copies.append(copy)
		_check("laser·验收6：复制体 sub_beams_override==0（强制只出主束）",
			int(copy.get("sub_beams_override")) == 0)
		_check("laser·验收6：复制体 copy_tint==true（灰染 flag）",
			bool(copy.get("copy_tint")))
		copy.try_fire()
		var copy_beams: Array = _live_beams(copy)
		_check("laser·验收6：复制体并发束==1（副束折减）", copy_beams.size() == 1,
			str(copy_beams.size()))
		var gray_ok := copy_beams.size() == 1 and (copy_beams[0] as LaserBeam).gray_tint
		_check("laser·验收6：复制体束 gray_tint==true", gray_ok)
	var copy_events := 0
	for k in _subbeam_kinds:
		if k == GameConst.SUBBEAM_OWNER_COPY:
			copy_events += 1
	_check("laser·验收6：归属字段无 COPY 事件（折减后恒不发）", copy_events == 0,
		"kinds=%s" % str(_subbeam_kinds))
	# W5 束段指纹 == 1（折射退役 → 锚束单段）
	var w5w := MirrorWeapon.new()
	w5w.setup(_gl.registry.get_weapon(&"W5_prism"), _gl.player, _gl.player.get("_deps"))
	_check("laser·验收6 前置：棱镜装配", _gl.player.equip_weapon(w5w))
	w5w.meta_atk_pct = 0.0
	w5w.try_fire()
	_check("laser·验收6：同场 W5 束段指纹==1（无折射分叉）", _live_beams(w5w).size() == 1,
		str(_live_beams(w5w).size()))
	_gl.player._summon_copies.erase(copy)
	if copy != null and is_instance_valid(copy):
		copy.free()
	_kill_weapon(w5w)
	_kill_weapon(w4)
	_clear_enemies()
	LaserBeam.scorch_pool_reset()


func _live_beams(p_w: WeaponBase) -> Array:
	var out: Array = []
	var beams_v: Variant = p_w.get("active_beams")
	if not (beams_v is Array):
		return out
	for b in (beams_v as Array):
		if b != null and is_instance_valid(b) and b.is_live():
			out.append(b)
	return out


func _main_beam_of(p_w: WeaponBase) -> LaserBeam:
	var main_v: Variant = p_w.get("_main_beam")
	if main_v is LaserBeam and is_instance_valid(main_v) and (main_v as LaserBeam).is_live():
		return main_v
	return null


# ── pistol（W1 并行弹幕 × 跳弹增值） ──────────────────────────────
func _test_pistol_anchors() -> void:
	print("── pistol·验收 1：锚点（面板 DPS 表已由数据契约层锁定——行为级抽查） ──")
	_clear_enemies()
	_gl.player.global_position = Vector2(360.0, 1000.0)
	var w := _make_w(&"W1_pistol", 1, true)
	_check("pistol·验收1 前置：W1 装配", w != null)
	if w == null:
		return
	seed(42)
	w.try_fire()
	var bullets: Array = _my_projectiles(w)
	_check("pistol·验收1：L1 出弹 1 丸（14×5.0 锚——p1_polish 不破）",
		bullets.size() == 1, str(bullets.size()))
	var panel: Dictionary = w.build_panel_snapshot()
	_check("pistol·验收1：L1 面板 base_atk==14（直读表面板）",
		_approx(float(panel.get("base_atk", 0.0)), 14.0, 0.01),
		str(panel.get("base_atk")))
	_kill_weapon(w)
	_clear_enemies()


func _test_pistol_formation_geometry() -> void:
	print("── pistol·验收 2：并排几何确定性 + 收束 ──")
	_clear_enemies()
	_gl.player.global_position = Vector2(360.0, 1000.0)
	# L3：±6px；L5：{-12,0,+12}；seed(42) 重复 10 次一致
	var w3 := _make_w(&"W1_pistol", 3)
	seed(42)
	w3.try_fire()
	var off3 := _lateral_offsets(w3)
	_check("pistol·验收2：L3 双弹 offset={-6,+6}px",
		_offsets_match(off3, [-6.0, 6.0]), str(off3))
	var repeat_ok := true
	for i in range(10):
		_kill_projectiles_of(w3)
		seed(42)
		w3.try_fire()
		if not _offsets_match(_lateral_offsets(w3), [-6.0, 6.0]):
			repeat_ok = false
	_check("pistol·验收2：seed(42) 重复 10 次几何一致", repeat_ok)
	_kill_weapon(w3)
	var w5 := _make_w(&"W1_pistol", 5)
	seed(42)
	w5.try_fire()
	var off5 := _lateral_offsets(w5)
	_check("pistol·验收2：L5 三弹 offset={-12,0,+12}px",
		_offsets_match(off5, [-12.0, 0.0, 12.0]), str(off5))
	# 收束：步进至 55% 射程处三弹距瞄准线 <10px（外弹间距塌缩）；L3 对照全程 12px
	var bullets: Array = _my_projectiles(w5)
	var focal := 0.55 * 680.0
	var ticks := int(focal / 620.0 / DT)
	for i in range(ticks):
		_adv()
		for b in bullets:
			if bool(b.get("_live")):
				b.tick(DT)
	var spacing5 := _outer_spacing(w5)
	_check("pistol·验收2：L5 收束点 55%% 射程外弹间距 <10px（三线收束）",
		spacing5 >= 0.0 and spacing5 < 10.0, "spacing=%.2f" % spacing5)
	_kill_weapon(w5)
	var w3b := _make_w(&"W1_pistol", 3)
	seed(42)
	w3b.try_fire()
	var bullets3: Array = _my_projectiles(w3b)
	for i in range(ticks):
		_adv()
		for b in bullets3:
			if bool(b.get("_live")):
				b.tick(DT)
	var spacing3 := _outer_spacing(w3b)
	_check("pistol·验收2：L3 对照弹全程 12px 间距（无收束）",
		_approx(spacing3, 12.0, 0.6), "spacing=%.2f" % spacing3)
	# 平行校准：阵宽 +4/层、收束点 55%→70%
	var w5b := _make_w(&"W1_pistol", 5)
	var cal := _gl.registry.get_trait(&"MEC_PARALLEL_CAL")
	for i in range(3):
		w5b.attach_trait(cal)
	seed(42)
	w5b.try_fire()
	_check("pistol·验收2：MEC_PARALLEL_CAL×3 → ±24px 覆盖态",
		_offsets_match(_lateral_offsets(w5b), [-24.0, 0.0, 24.0]),
		str(_lateral_offsets(w5b)))
	_check("pistol·验收2：MEC_PARALLEL_CAL×3 → 收束点 55%%→70%%",
		_approx(float(w5b.call("_converge_pct")), 0.70, 0.001),
		"pct=%.3f" % float(w5b.call("_converge_pct")))
	_kill_weapon(w5b)
	_clear_enemies()
	_gl.player.global_position = Vector2(360.0, 640.0)


func _test_pistol_bounce_axis() -> void:
	print("── pistol·验收 3：跳弹预算 / 永存 / 增值乘区 / 黄金弹 ──")
	_clear_enemies()
	var expect := {1: 0, 2: 0, 3: 1, 5: 2}
	for lv in [1, 2, 3, 5]:
		var w := _make_w(&"W1_pistol", lv)
		seed(42)
		w.try_fire()
		var ok := _my_projectiles(w).size() > 0
		for b in _my_projectiles(w):
			if (b as ProjectileBase).bounces_left != int(expect[lv]):
				ok = false
		_check("pistol·验收3：L%d 出弹 bounces_left==%d" % [lv, expect[lv]], ok)
		_kill_weapon(w)
	# 金 MEC_BOUNCE×1（value 5.2）→ L5 预算 2+5=7
	var w5 := _make_w(&"W1_pistol", 5)
	var gold: TraitData = (_gl.registry.get_trait(&"MEC_BOUNCE") as TraitData).duplicate()
	gold.value = 5.2
	w5.attach_trait(gold)
	seed(42)
	w5.try_fire()
	var ok7 := _my_projectiles(w5).size() > 0
	for b in _my_projectiles(w5):
		if (b as ProjectileBase).bounces_left != 7:
			ok7 = false
	_check("pistol·验收3：金 MEC_BOUNCE×1 → L5 反弹预算==7", ok7)
	# 永存：4 次 ON_BOUNCE 不触发 / 第 5 次触发（lifetime≥999）
	var eternal_ok := true
	for b in _my_projectiles(w5):
		for i in range(4):
			GameConfig.advance_frame()
			b.call("_apply_bounce", Vector2(0, 1))
		if float(b.get("lifetime_left")) >= 999.0:
			eternal_ok = false
		GameConfig.advance_frame()
		b.call("_apply_bounce", Vector2(0, 1))
		if float(b.get("lifetime_left")) < 999.0:
			eternal_ok = false
	_check("pistol·验收3：5 次 ON_BOUNCE 触发 TH_BOUNCE_ETERNAL（≥999）/ 4 次不触发",
		eternal_ok)
	# 增值乘区：bounce_amp 0.12/跳 加算、cap +100%（ctx 注入口直验）
	var amp_ok := true
	for n in [4, 20]:
		var ctx := DamageContext.make()
		ctx.base_atk = 10.0
		ctx.bounce_count = n
		w5.inject_relic_pools(ctx, null)
		var found := false
		for pool in ctx.mult_pools:
			if pool.get("pool_id", &"") == &"bounce_amp":
				found = true
				var expect_c: float = minf(float(n) * 0.12, 1.0)
				if not _approx(float(pool.get("contrib", 0.0)), expect_c, 0.0001):
					amp_ok = false
		if not found:
			amp_ok = false
	_check("pistol·验收3：增值乘区 bounce_count×0.12（cap_prod 域内 +100% 封顶）", amp_ok)
	# 黄金弹：单弹反弹 ≥12 → 必暴（crit_chance 置 1）
	var ctx12 := DamageContext.make()
	ctx12.base_atk = 10.0
	ctx12.crit_chance = 0.0
	ctx12.bounce_count = 12
	w5.inject_relic_pools(ctx12, null)
	_check("pistol·验收3：反弹累计≥12 黄金弹必暴（crit_chance==1）",
		_approx(ctx12.crit_chance, 1.0, 0.0001),
		"crit=%.3f" % ctx12.crit_chance)
	_kill_weapon(w5)
	_clear_enemies()


func _test_pistol_volley_state() -> void:
	print("── pistol·验收 4：TH_VOLLEY_STATE 弹幕态 ──")
	_clear_enemies()
	var w := _make_w(&"W1_pistol", 5)
	var multi := _gl.registry.get_trait(&"AFF_MULTI")
	w.attach_trait(multi)                          # 3+1=4 <6：不触发
	_check("pistol·验收4：pellets==4（<6 不触发对照）", int(w.call("_pellet_count")) == 4,
		str(int(w.call("_pellet_count"))))
	seed(42)
	w.try_fire()
	_check("pistol·验收4：弹幕态未激活", float(w.get("_volley_left")) <= 0.0)
	_kill_projectiles_of(w)
	w.attach_trait(multi)                          # 3+3=6 ≥6：触发
	_check("pistol·验收4：pellets==6 触发门", int(w.call("_pellet_count")) == 6)
	var hits: Array = [0]
	var cb := func(_tid: StringName, _n: String, _m: float) -> void:
		hits[0] += 1
	EventBus.trait_milestone.connect(cb)
	var counter0: int = DebugStats.get_counter(&"volley_state_active")
	var base_interval: float = float(w.call("_fire_interval"))
	seed(42)
	w.try_fire()
	_check("pistol·验收4：弹幕态激活（_volley_left>0）", float(w.get("_volley_left")) > 0.0)
	_check("pistol·验收4：首发激活 trait_milestone 恰 1 次 + volley_state_active +1",
		hits[0] == 1 and DebugStats.get_counter(&"volley_state_active") == counter0 + 1,
		"hits=%d" % hits[0])
	_check("pistol·验收4：弹幕态开火间隔 ×0.8",
		_approx(float(w.call("_fire_interval")), base_interval * 0.8, 0.0001),
		"iv=%.4f base=%.4f" % [float(w.call("_fire_interval")), base_interval])
	_check("pistol·验收4：弹幕态并排 +2（8 弹 ±42px 阵）",
		_offsets_match(_lateral_offsets(w),
			[-42.0, -30.0, -18.0, -6.0, 6.0, 18.0, 30.0, 42.0]),
		str(_lateral_offsets(w)))
	# 4.0s 激活 → 3.0s 散热 → 就绪可再触发（首发播报不重复）
	for i in range(485):
		_adv()
		w.tick(DT)
	_check("pistol·验收4：激活 4.0s 后进入散热（cd≈3.0）",
		float(w.get("_volley_left")) <= 0.0 and float(w.get("_volley_cd_left")) > 2.9,
		"left=%.3f cd=%.3f" % [float(w.get("_volley_left")), float(w.get("_volley_cd_left"))])
	_check("pistol·验收4：散热期 interval 恢复 ×1.0",
		_approx(float(w.call("_fire_interval")), base_interval, 0.0001))
	for i in range(370):
		_adv()
		w.tick(DT)
	_check("pistol·验收4：散热 3.0s 后就绪",
		float(w.get("_volley_cd_left")) <= 0.0 and float(w.get("_volley_left")) <= 0.0)
	seed(42)
	w.try_fire()
	_check("pistol·验收4：散热后可再触发（首发播报不重复）",
		float(w.get("_volley_left")) > 0.0 and hits[0] == 1
		and DebugStats.get_counter(&"volley_state_active") == counter0 + 2)
	EventBus.trait_milestone.disconnect(cb)
	_kill_weapon(w)
	_clear_enemies()


func _test_pistol_distinction() -> void:
	print("── pistol·验收 6：区分度（同 lane 副本 / 独立弹幕态 / 回响绕门负例） ──")
	_clear_enemies()
	_gl.player.global_position = Vector2(360.0, 1000.0)
	# 诺亚副本：同 lane 几何 + 独立弹幕态计时
	var w1 := _make_w(&"W1_pistol", 3)
	var copy := _gl.player._make_weapon_copy(w1)
	_gl.player._summon_copies.append(copy)
	seed(42)
	w1.try_fire()
	seed(42)
	copy.try_fire()
	_check("pistol·验收6：副本同 lane 几何（offset 集合 {−6,+6} 同源）",
		_offsets_match(_lateral_offsets(copy), [-6.0, 6.0]),
		str(_lateral_offsets(copy)))
	_kill_projectiles_of(copy)
	_kill_projectiles_of(w1)
	var w5c := _make_w(&"W1_pistol", 5)            # L5（pellets 3）供弹幕态独立断言
	var copy5 := _gl.player._make_weapon_copy(w5c)
	_gl.player._summon_copies.append(copy5)
	var multi := _gl.registry.get_trait(&"AFF_MULTI")
	copy5.attach_trait(multi)
	copy5.attach_trait(multi)                      # 副本 pellets 3+3=6 → 弹幕态
	seed(42)
	copy5.try_fire()
	_check("pistol·验收6：副本弹幕态计时独立（副本激活、本体未激活）",
		float(copy5.get("_volley_left")) > 0.0 and float(w5c.get("_volley_left")) <= 0.0,
		"copy=%.2f main=%.2f" % [float(copy5.get("_volley_left")), float(w5c.get("_volley_left"))])
	_gl.player._summon_copies.erase(copy)
	copy.free()
	_gl.player._summon_copies.erase(copy5)
	copy5.free()
	_kill_weapon(w5c)
	_kill_weapon(w1)
	# REL_ECHO 绕门负例：多丸弹道武器（W3 霰弹）无 lateral_gap_levels 键 → 阵宽词条不生效
	var w3 := _make_w(&"W3_shotgun", 1)
	var cal := _gl.registry.get_trait(&"MEC_PARALLEL_CAL")
	for i in range(3):
		w3.attach_trait(cal)
	_check("pistol·验收6：W3 无编队键 → _formation_enabled()==false（回响绕门防）",
		not bool(w3.call("_formation_enabled")))
	seed(42)
	w3.try_fire()
	var all_zero := _my_projectiles(w3).size() > 0
	for b in _my_projectiles(w3):
		if absf(float(b.global_position.x) - float(w3.muzzle_position().x)) > 0.05:
			all_zero = false
	_check("pistol·验收6：REL_ECHO 把「平行校准」挂非 W1 → add_gap 不生效（offset 全 0）",
		all_zero)
	_kill_weapon(w3)
	_clear_enemies()
	_gl.player.global_position = Vector2(360.0, 640.0)


func _lateral_offsets(p_w: WeaponBase) -> Array[float]:
	var muzzle: Vector2 = p_w.muzzle_position()
	var out: Array[float] = []
	for b in _my_projectiles(p_w):
		out.append(float(b.global_position.x) - muzzle.x)
	out.sort()
	return out


func _offsets_match(p_actual: Array[float], p_expected: Array[float],
		p_tol: float = 0.05) -> bool:
	if p_actual.size() != p_expected.size():
		return false
	for i in range(p_actual.size()):
		if absf(p_actual[i] - p_expected[i]) > p_tol:
			return false
	return true


func _outer_spacing(p_w: WeaponBase) -> float:
	var xs: Array[float] = []
	for b in _my_projectiles(p_w):
		if bool(b.get("_live")):
			xs.append(float(b.global_position.x))
	if xs.size() < 2:
		return -1.0
	xs.sort()
	return xs[xs.size() - 1] - xs[0]


func _my_projectiles(p_w: WeaponBase) -> Array:
	var out: Array = []
	for pool_id in [&"projectile", &"homing"]:
		var pool: ProjectilePool = _gl.pools[pool_id]
		for p in pool.active_projectiles():
			if p is ProjectileBase and (p as ProjectileBase).weapon_uid == p_w.uid \
					and bool(p.get("_live")):
				out.append(p)
	return out


func _kill_projectiles_of(p_w: WeaponBase) -> void:
	for b in _my_projectiles(p_w):
		(b as ProjectileBase).nullify()


# ── rockets（W6/W7 蜂群与攻城锤） ─────────────────────────────────
func _test_rocket_volley_behavior() -> void:
	print("── rockets·验收 2：齐射行为（第 i 近锁定 / ×0.6^j 递减 / HIVE_RACK / 池满） ──")
	_clear_enemies()
	var w6 := _make_w(&"W6_micro_missile", 5, true)
	_check("rockets·验收2 前置：W6 L5 装配", w6 != null)
	if w6 == null:
		return
	# 对 3 dummy：单节拍恰 3 弹 target_uid 互异
	var e1 := _spawn_e(Vector2(360.0, 300.0))
	_spawn_e(Vector2(300.0, 320.0))
	_spawn_e(Vector2(420.0, 340.0))
	w6.try_fire()
	var missiles := _live_missiles(w6)
	_check("rockets·验收2：L5 volley=3 → 单节拍恰 3 弹", missiles.size() == 3,
		str(missiles.size()))
	var uid_set: Dictionary = {}
	for m in missiles:
		uid_set[int((m as HomingProjectile).target_uid)] = true
	_check("rockets·验收2：3 弹 target_uid 互异（第 i 发锁第 i 近）", uid_set.size() == 3,
		str(uid_set.keys()))
	_kill_weapon(w6)
	_clear_enemies()
	# 对 1 dummy：3 弹同锁 + 伤害序列 atk×[1.0,0.6,0.36]
	var w6b := _make_w(&"W6_micro_missile", 5, true)
	var dummy := _spawn_e(Vector2(360.0, 300.0))
	w6b.try_fire()
	var volley := _live_missiles(w6b)
	var same := volley.size() == 3
	for m in volley:
		if int((m as HomingProjectile).target_uid) != int(dummy.get("uid")):
			same = false
	_check("rockets·验收2：目标不足 → 3 弹同锁最近 dummy", same)
	var deltas: Array[float] = []
	var guard := 0
	while _live_missiles(w6b).size() > 0 and guard < 600:
		_adv()
		for m in _live_missiles(w6b):
			var before: float = float(dummy.hp)
			(m as ProjectileBase).tick(DT)
			var d: float = before - float(dummy.hp)
			if d > 0.001:
				deltas.append(d)
		guard += 1
	deltas.sort()
	var seq_ok: bool = deltas.size() == 3
	if seq_ok:
		seq_ok = _approx(deltas[0], 32.0 * 0.36, 1.0) \
			and _approx(deltas[1], 32.0 * 0.6, 1.0) \
			and _approx(deltas[2], 32.0, 1.0)
	_check("rockets·验收2：直击伤害序列 = atk×[1.0,0.6,0.36]±1", seq_ok, str(deltas))
	_kill_weapon(w6b)
	_clear_enemies()
	# HIVE_RACK×2 → 5 弹（clamp [1,5]）
	var w6c := _make_w(&"W6_micro_missile", 5, true)
	var rack := _gl.registry.get_trait(&"MEC_HIVE_RACK")
	w6c.attach_trait(rack)
	w6c.attach_trait(rack)
	_spawn_e(Vector2(360.0, 300.0))
	_check("rockets·验收2：HIVE_RACK×2 → volley_eff==5（clamp [1,5]）",
		w6c.try_fire() and int(w6c.get("volley_eff")) == 5,
		str(w6c.get("volley_eff")))
	_check("rockets·验收2：单节拍恰 5 弹（硬顶 5 枚/轮）", _live_missiles(w6c).size() == 5,
		str(_live_missiles(w6c).size()))
	_kill_weapon(w6c)
	_clear_enemies()
	# 池满：try_fire 返回 false 不崩 + homing_volley_dropped 计数
	var drops0: int = DebugStats.get_counter(&"homing_volley_dropped")
	var mini := ProjectilePool.new()
	mini.name = "R187MiniHomingPool"
	tree.get_root().add_child(mini)
	mini.setup(&"r187_mini_homing", load("res://scenes/combat/projectiles/homing_projectile.tscn"), 4)
	var w6d := _make_w(&"W6_micro_missile", 5, true)
	w6d.attach_trait(rack)
	w6d.attach_trait(rack)
	w6d.set("homing_pool", mini)
	_spawn_e(Vector2(360.0, 300.0))
	_check("rockets·验收2：池容 4 → 出膛 4 弃 1（try_fire 仍成功）",
		w6d.try_fire() and int(mini.get("_live_order").size()) == 4,
		str(mini.get("_live_order").size()))
	_check("rockets·验收2：池满弃发计数 +1（homing_volley_dropped 可读）",
		DebugStats.get_counter(&"homing_volley_dropped") == drops0 + 1)
	_check("rockets·验收2：池空再射 try_fire 返回 false 不崩",
		not w6d.try_fire()
		and DebugStats.get_counter(&"homing_volley_dropped") == drops0 + 2)
	mini.free()
	_kill_weapon(w6d)
	_clear_enemies()


func _test_rocket_fuse_coaxial() -> void:
	print("── rockets·验收 3：引信涂层 / 幂等 / ×1.4 / 定向爆破护栏 ──")
	_clear_enemies()
	var coat := _gl.registry.get_trait(&"MEC_FUSE_COAT")
	var det := _gl.registry.get_trait(&"MEC_FUSE_DETONATE")
	_check("rockets·验收3 前置：FUSE_COAT / FUSE_DETONATE 在册", coat != null and det != null)
	var w6 := _make_w(&"W6_micro_missile", 1, true)
	w6.attach_trait(coat)
	w6.attach_trait(coat)
	var w7 := _make_w(&"W7_cluster_rocket", 1, true)
	w7.attach_trait(det)
	w7.attach_trait(det)
	# 探针隔离：W7 去子弹头（sub_count_levels 摘除 + sub_count=0——防子弹头爆溅射污染测量）
	(w7.data.homing).erase("sub_count_levels")
	(w7.data.homing)["sub_count"] = 0.0
	# A：直击挂引信 4s + 幂等刷新
	var b_target := _spawn_e(Vector2(360.0, 570.0))
	_fire_and_settle(w6, b_target)
	_check("rockets·验收3：FUSE_COAT×2 直击 → fuse_mark_left==4.0（敌侧通道）",
		_approx(float(b_target.get("fuse_mark_left")), 4.0, 0.001),
		str(b_target.get("fuse_mark_left")))
	_fire_and_settle(w6, b_target)
	_check("rockets·验收3：重复命中幂等（续 4s 不叠加）",
		_approx(float(b_target.get("fuse_mark_left")), 4.0, 0.001),
		str(b_target.get("fuse_mark_left")))
	# B：引信敌受自导爆炸 ×1.4（F 引信 / G 无引信对照，距爆心等距 25px）
	# 同场景无清场（敌还池会清引信标记）：F 铺引信后平移让位，再入 G/H
	b_target.global_position = Vector2(335.0, 580.0)                        # F（已引信）
	var ctrl := _spawn_e(Vector2(385.0, 580.0))                             # G 对照
	var center := _spawn_e(Vector2(360.0, 580.0))                           # H 爆心（最近）
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var hp_f: float = float(b_target.hp)
	var hp_g: float = float(ctrl.hp)
	_fire_and_settle(w6, center)
	var d_f: float = hp_f - float(b_target.hp)
	var d_g: float = hp_g - float(ctrl.hp)
	_check("rockets·验收3：引信敌受自导爆炸 ×1.4（F=10.8×0.667×1.4≈10.08）",
		_approx(d_f, 18.0 * 0.6 * 0.6667 * 1.4, 0.6) and d_f > 0.0,
		"dF=%.2f" % d_f)
	_check("rockets·验收3：无引信对照 ×1.0（G≈7.2）", _approx(d_g, 18.0 * 0.6 * 0.6667, 0.6),
		"dG=%.2f" % d_g)
	_check("rockets·验收3：引信乘区比 ==1.4±0.02",
		d_g > 0.0 and _approx(d_f / d_g, 1.4, 0.02), "%.3f" % (d_f / d_g))
	# C：定向爆破——余波恰一次 2×0.5×atk + 0.5s 护栏（同场景平移换最近目标，零清场）
	var e_f := _spawn_e(Vector2(420.0, 560.0))     # 引信靶
	var d_main := _spawn_e(Vector2(2000.0, 1000.0))    # W7 主靶（暂避远处——铺引信期让位）
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	_fire_and_settle(w6, e_f)                      # W6 铺引信（E 最近）
	_check("rockets·验收3 前置：E 已挂引信",
		_approx(float(e_f.get("fuse_mark_left")), 4.0, 0.001))
	d_main.global_position = Vector2(360.0, 560.0)      # D 归位（80px < E 100px → 主目标）
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var hp_e: float = float(e_f.hp)
	_fire_and_settle(w7, d_main)
	var d_e: float = hp_e - float(e_f.hp)
	# 溅射 38×0.78182×1.4=41.6（§2.3.5 目标侧 amp——W6 涂层标记随敌身，W7 溅射同享）
	# + 余波 2×0.5×38=38（自身公式定额，不叠 amp）
	_check("rockets·验收3：W7 爆炸命中引信敌 → 溅射(×1.4)+余波恰一次 79.6",
		_approx(d_e, 38.0 * 0.78182 * 1.4 + 38.0, 1.0), "dE=%.2f" % d_e)
	_check("rockets·验收3：爆炸消耗引信（fuse_mark_left==0）",
		_approx(float(e_f.get("fuse_mark_left")), 0.0, 0.001),
		str(e_f.get("fuse_mark_left")))
	_check("rockets·验收3：护栏置位 0.5s（fuse_detonate_guard_left）",
		_approx(float(e_f.get("fuse_detonate_guard_left")), 0.5, 0.001),
		str(e_f.get("fuse_detonate_guard_left")))
	# 护栏内第二次：重铺引信 → 溅射有、余波无
	d_main.global_position = Vector2(2000.0, 1000.0)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	_fire_and_settle(w6, e_f)                      # 重铺引信（E 最近）
	d_main.global_position = Vector2(360.0, 560.0)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	hp_e = float(e_f.hp)
	_fire_and_settle(w7, d_main)
	var d_e2: float = hp_e - float(e_f.hp)
	_check("rockets·验收3：0.5s 护栏内第二次爆炸 → 溅射 41.6(×1.4) 无追加余波",
		_approx(d_e2, 38.0 * 0.78182 * 1.4, 1.0), "dE2=%.2f" % d_e2)
	_check("rockets·验收3：护栏内不消耗引信（fuse_mark_left 恒 4）",
		_approx(float(e_f.get("fuse_mark_left")), 4.0, 0.001))
	# 护栏过期 → 余波恢复
	e_f.set("fuse_detonate_guard_left", 0.0)
	hp_e = float(e_f.hp)
	_fire_and_settle(w7, d_main)
	var d_e3: float = hp_e - float(e_f.hp)
	_check("rockets·验收3：护栏过期后余波恢复（溅射×1.4+38）",
		_approx(d_e3, 38.0 * 0.78182 * 1.4 + 38.0, 1.0), "dE3=%.2f" % d_e3)
	_kill_weapon(w6)
	_kill_weapon(w7)
	_clear_enemies()


func _fire_and_settle(p_w: WeaponBase, p_target: Node2D) -> void:
	# 发射 + 将首弹钉到目标心上命中（爆心==敌心的确定性口径，w67 同款）
	p_w.try_fire()
	var missiles := _live_missiles(p_w)
	if missiles.is_empty():
		return
	var m := missiles[0] as ProjectileBase
	m.global_position = p_target.global_position
	m.velocity = Vector2.ZERO
	_adv()
	m.tick(DT)
	var guard := 0
	while _live_missiles(p_w).size() > 0 and guard < 600:
		_adv()
		for rest in _live_missiles(p_w):
			(rest as ProjectileBase).tick(DT)
		guard += 1


func _live_missiles(p_w: WeaponBase) -> Array:
	var out: Array = []
	var pool: ProjectilePool = _gl.pools[&"homing"]
	for p in pool.active_projectiles():
		if p is HomingProjectile and (p as HomingProjectile).weapon_uid == p_w.uid \
				and bool(p.get("_live")):
			out.append(p)
	return out


func _test_rocket_r183_reduction_and_soak() -> void:
	print("── rockets·验收 5：R183 折减（volley_eff=1 / sub_eff=min(sub,3)）+ 10s 池压 ──")
	_clear_enemies()
	var rack := _gl.registry.get_trait(&"MEC_HIVE_RACK")
	var w6 := _make_w(&"W6_micro_missile", 5, true)
	w6.attach_trait(rack)
	w6.attach_trait(rack)
	var w7 := _make_w(&"W7_cluster_rocket", 5, true)
	w6.call("_refresh_r183_effective")             # 折减观察口刷新（非 try_fire 路径直读）
	w7.call("_refresh_r183_effective")
	_check("rockets·验收5 前置：本体满编 volley_eff==5 / sub_eff==8",
		int(w6.get("volley_eff")) == 5 and int(w7.get("sub_eff")) == 8,
		"%s/%s" % [str(w6.get("volley_eff")), str(w7.get("sub_eff"))])
	var copy6 := _gl.player._make_weapon_copy(w6)
	_gl.player._summon_copies.append(copy6)
	var copy7 := _gl.player._make_weapon_copy(w7)
	_gl.player._summon_copies.append(copy7)
	_spawn_e(Vector2(360.0, 300.0))
	copy6.call("_refresh_r183_effective")
	copy7.call("_refresh_r183_effective")
	_check("rockets·验收5：副本 W6 volley_eff==1（齐射折减单发）",
		int(copy6.get("volley_eff")) == 1, str(copy6.get("volley_eff")))
	_check("rockets·验收5：副本 W7 sub_eff==min(sub,3)==3",
		int(copy7.get("sub_eff")) == 3, str(copy7.get("sub_eff")))
	# 满配双火箭 + 双副本 tick 10s：homing 在场弹峰值 ≤64、无崩溃
	for i in range(6):
		_spawn_e(Vector2(200.0 + 60.0 * float(i), 260.0))
	var pool: ProjectilePool = _gl.pools[&"homing"]
	var peak := 0
	var dropped_seen: int = DebugStats.get_counter(&"homing_volley_dropped")
	var drivers: Array = [w6, w7, copy6, copy7]
	for frame in range(1200):                      # 10s @120Hz
		_adv()
		for d in drivers:
			d.tick(DT)
		var snapshot: Array = pool.active_projectiles().duplicate()
		peak = maxi(peak, snapshot.size())
		for p in snapshot:
			if bool(p.get("_live")):
				(p as ProjectileBase).tick(DT)
	dropped_seen = DebugStats.get_counter(&"homing_volley_dropped") - dropped_seen
	_check("rockets·验收5：满配 10s soak——homing 在场弹峰值 ≤64（软上限）",
		peak <= 64, "peak=%d" % peak)
	_check("rockets·验收5：soak 无崩溃 + 丢弃计数可读（%d 弃发）" % dropped_seen,
		dropped_seen >= 0)
	_gl.player._summon_copies.erase(copy6)
	_gl.player._summon_copies.erase(copy7)
	copy6.free()
	copy7.free()
	_kill_weapon(w6)
	_kill_weapon(w7)
	_clear_enemies()


func _test_rocket_blast_tier() -> void:
	print("── rockets·验收 6：表现分档（blast_r<50 → HIT 档震屏） ──")
	var shake: CameraShake = _gl.game_feel.shake
	_check("rockets·验收6 前置：CameraShake 在场", shake != null)
	if shake == null:
		return
	var feel_cfg = _gl.game_feel.feel_config
	var hit_amount: float = float(feel_cfg.shake_trauma[0]) if feel_cfg != null else 0.15
	var crit_amount: float = float(feel_cfg.shake_trauma[1]) if feel_cfg != null else 0.4
	shake.trauma = 0.0
	EventBus.emit_missile_blast(Vector2(360.0, 600.0), 38.0)   # W6 L1 档爆径 <50
	var d_small: float = shake.trauma
	shake.trauma = 0.0
	EventBus.emit_missile_blast(Vector2(360.0, 600.0), 110.0)  # W7 大爆 ≥50
	var d_big: float = shake.trauma
	shake.trauma = 0.0
	_check("rockets·验收6：小爆（blast_r=38<50）震屏档位==HIT 档（%.2f）" % hit_amount,
		_approx(d_small, hit_amount, 0.001),
		"实得 %.2f（若==CRIT 档 %.2f 即分档未实现）" % [d_small, crit_amount])
	_check("rockets·验收6：大爆（110）保持重档（%.2f）" % crit_amount,
		_approx(d_big, crit_amount, 0.001), "实得 %.2f" % d_big)


# ── prism（W5 万镜回廊） ──────────────────────────────────────────
func _make_prism(p_level: int = 1) -> MirrorWeapon:
	var prism := MirrorWeapon.new()
	prism.setup(_gl.registry.get_weapon(&"W5_prism"), _gl.player, _gl.player.get("_deps"))
	prism.meta_atk_pct = 0.0
	if not _gl.player.equip_weapon(prism):
		prism.free()
		return null
	prism.level = clampi(p_level, 1, 5)
	prism.call("_invalidate_panel")
	prism.sync_mirrors(true)
	return prism


func _test_prism_whiteboard() -> void:
	print("── prism·验收 1：白板反向（栈=棱镜栈逐层一致 / 与源武器零交集） ──")
	_clear_enemies()
	_wipe_weapons()
	var src := _add(&"W1_pistol")
	src.attach_trait(_gl.registry.get_trait(&"AFF_ATK_UP"))
	src.attach_trait(_gl.registry.get_trait(&"ELE_IGNITE"))
	var prism := _make_prism(1)
	_check("prism·验收1 前置：棱镜装配（≥1 源在场）", prism != null)
	if prism == null:
		return
	prism.attach_trait(_gl.registry.get_trait(&"AFF_ROF_UP"))   # 棱镜自身词条
	prism.sync_mirrors(true)
	_check("prism·验收1 前置：镜面成军（L1=1 面）", prism.mirrors.size() == 1,
		str(prism.mirrors.size()))
	var img: MirrorImage = prism.mirrors[0]
	_check("prism·验收1：镜面 trait_stack 与内壳同一实例（身份唯一）",
		img.trait_stack == img.inner.trait_stack)
	var mirror_ids: Array[StringName] = []
	for tb in img.trait_stack.traits:
		mirror_ids.append(tb.data.id)
	var prism_ids: Array[StringName] = []
	for tb in prism.trait_stack.traits:
		prism_ids.append(tb.data.id)
	_check("prism·验收1：镜面栈 id 集==棱镜栈 id 集（AFF_ROF_UP 逐层）",
		mirror_ids == prism_ids and prism_ids.has(&"AFF_ROF_UP"), str(mirror_ids))
	var src_ids: Array[StringName] = [&"AFF_ATK_UP", &"ELE_IGNITE"]
	var inter := false
	for id in mirror_ids:
		if src_ids.has(id):
			inter = true
	_check("prism·验收1：与源武器栈条目零交集（R183 反义——源 buff 不复制）", not inter)
	_kill_weapon(prism)
	_kill_weapon(src)
	_clear_enemies()


func _test_prism_permanence() -> void:
	print("── prism·验收 2：永久反义（11s 在场 / _reset 不清 / 不进 _summon_copies） ──")
	_clear_enemies()
	_wipe_weapons()
	var src := _add(&"W1_pistol")
	var prism := _make_prism(1)
	if prism == null:
		_check("prism·验收2 前置：棱镜装配", false)
		return
	prism.sync_mirrors(true)
	_check("prism·验收2 前置：镜面在场", prism.mirrors.size() == 1)
	var source_before: StringName = prism.mirrors[0].source_id()
	_drive_player(1320)                            # 11s > SUMMON_DURATION 10s
	_check("prism·验收2：驱动 11s 镜面仍在场（永久——无 10s 到期）",
		prism.mirrors.size() == 1, str(prism.mirrors.size()))
	_check("prism·验收2：指向不变", prism.mirrors[0].source_id() == source_before,
		"%s→%s" % [str(source_before), str(prism.mirrors[0].source_id())])
	var in_copies := false
	for c in _gl.player._summon_copies:
		if c == prism.mirrors[0]:
			in_copies = true
	_check("prism·验收2：镜面不在 _summon_copies", not in_copies)
	# 真件复制体注入 → _reset_skill_temp_state 后 copies 空而 mirrors 原样
	var fake_copy := _gl.player._make_weapon_copy(src)
	_gl.player._summon_copies.append(fake_copy)
	_gl.player.call("_reset_skill_temp_state")
	_check("prism·验收2：_reset_skill_temp_state 后 _summon_copies 空",
		_gl.player._summon_copies.is_empty())
	_check("prism·验收2：_mirror_images 原样（永久件语义）",
		_gl.player.mirror_count() == 1 and prism.mirrors.size() == 1)
	_kill_weapon(prism)
	_kill_weapon(src)
	_clear_enemies()


func _test_prism_buff_conduction() -> void:
	print("── prism·验收 3：吃棱镜 buff（逐层一致 + 满层质变 ×1.6）+ 强度锚 ──")
	_clear_enemies()
	_wipe_weapons()
	var src := _add(&"W1_pistol")
	src.meta_atk_pct = 0.0
	var prism := _make_prism(1)
	if prism == null:
		_check("prism·验收3 前置：棱镜装配", false)
		return
	prism.attach_trait(_gl.registry.get_trait(&"AFF_ATK_UP"))
	prism.attach_trait(_gl.registry.get_trait(&"AFF_ATK_UP"))   # ×2 层
	prism.sync_mirrors(true)
	var img: MirrorImage = prism.mirrors[0]
	var agg_prism: Dictionary = prism.trait_stack.aggregate_panel()
	var agg_mirror: Dictionary = img.trait_stack.aggregate_panel()
	_check("prism·验收3：镜面 aggregate add_atk 同 id 同层（与棱镜面板一致）",
		_approx(float(agg_mirror.get("add_atk", 0.0)), float(agg_prism.get("add_atk", -1.0)), 0.0001)
		and float(agg_mirror.get("add_atk", 0.0)) > 0.0,
		"mirror=%s prism=%s" % [str(agg_mirror.get("add_atk")), str(agg_prism.get("add_atk"))])
	var panel_mirror: Dictionary = img.inner.build_panel_snapshot()
	_check("prism·验收3：镜面面板 = 源面板 × mirror_ratio（14×0.40=5.6）",
		_approx(float(panel_mirror.get("base_atk", 0.0)), 5.6, 0.05),
		str(panel_mirror.get("base_atk")))
	# 满层质变 ×1.6（第 4 关门开——scope 内切 run_map）
	var map_before: StringName = Meta.run_map_id()
	Meta.set_run_map(&"world_grove")               # map_index 3 → milestone 门开
	prism.attach_trait(_gl.registry.get_trait(&"AFF_ATK_UP"))   # 第 3 层=stack_max → 质变
	prism.sync_mirrors(true)
	img = prism.mirrors[0]
	var mult_mirror := 1.0
	for tb in img.trait_stack.traits:
		if tb.data != null and tb.data.id == &"AFF_ATK_UP":
			mult_mirror = float(tb.value_mult)
	var agg_prism2: Dictionary = prism.trait_stack.aggregate_panel()
	var agg_mirror2: Dictionary = img.trait_stack.aggregate_panel()
	Meta.set_run_map(map_before)
	_check("prism·验收3：满 3 层质变 ×1.6 落镜面栈（value_mult）", _approx(mult_mirror, 1.6, 0.001),
		"mult=%.3f" % mult_mirror)
	_check("prism·验收3：质变后镜面面板与棱镜面板 add_atk 仍逐层一致",
		_approx(float(agg_mirror2.get("add_atk", 0.0)), float(agg_prism2.get("add_atk", -1.0)), 0.0001),
		"mirror=%s prism=%s" % [str(agg_mirror2.get("add_atk")), str(agg_prism2.get("add_atk"))])
	_kill_weapon(prism)
	_kill_weapon(src)
	_clear_enemies()


func _test_prism_ele_single_source() -> void:
	print("── prism·验收 4：ELE 单源防泄漏（注册源数==1 且驱动不增长） ──")
	_clear_enemies()
	_wipe_weapons()
	_gl.elemental.clear_reaction_mults()
	var src_a := _add(&"W1_pistol")
	var src_b := _add(&"W6_micro_missile")
	var prism := _make_prism(5)                    # L5 基线 3 面
	if prism == null:
		_check("prism·验收4 前置：棱镜装配", false)
		return
	var split := _gl.registry.get_trait(&"MEC_MIRROR_SPLIT")
	prism.attach_trait(split)
	prism.attach_trait(split)                      # 容量 5
	prism.attach_trait(_gl.registry.get_trait(&"ELE_REACTION_VOID"))
	prism.sync_mirrors(true)
	_check("prism·验收4 前置：5 镜在场", prism.mirrors.size() == 5,
		str(prism.mirrors.size()))
	var reg := _gl.elemental._reaction_mults
	var count0: int = reg.size()
	_check("prism·验收4：反应乘区注册源数==1（仅棱镜 uid）",
		count0 == 1 and reg.has(prism.uid), "size=%d keys=%s" % [count0, str(reg.keys())])
	_drive_player(240)                             # 2s
	_check("prism·验收4：驱动 2s 注册数不增长（镜面零注册）",
		_gl.elemental._reaction_mults.size() == count0,
		str(_gl.elemental._reaction_mults.size()))
	_gl.elemental.clear_reaction_mults()
	_kill_weapon(prism)
	_kill_weapon(src_a)
	_kill_weapon(src_b)
	_clear_enemies()


func _test_prism_capacity_cap() -> void:
	print("── prism·验收 5：数量帽（L5=3 + SPLIT×2 → 5 钳 / 不占武器槽） ──")
	_clear_enemies()
	_wipe_weapons()
	var src := _add(&"W1_pistol")
	var prism := _make_prism(5)
	if prism == null:
		_check("prism·验收5 前置：棱镜装配", false)
		return
	_check("prism·验收5：L5 基线 3 面", prism.mirrors.size() == 3,
		str(prism.mirrors.size()))
	var split := _gl.registry.get_trait(&"MEC_MIRROR_SPLIT")
	prism.attach_trait(split)
	prism.attach_trait(split)
	prism.sync_mirrors(true)
	_check("prism·验收5：MEC_MIRROR_SPLIT×2 → 5 面（绝对帽 5）",
		prism.mirrors.size() == 5, str(prism.mirrors.size()))
	var rej0: int = DebugStats.get_counter(&"trait_attach_rejected_stack")
	var ok3: bool = prism.attach_trait(split)
	_check("prism·验收5：第 3 张 SPLIT 被 stack_max=2 拒绝",
		not ok3 and DebugStats.get_counter(&"trait_attach_rejected_stack") == rej0 + 1)
	var junk := MirrorImage.new()
	var reg_ok: bool = _gl.player.register_mirror(junk, 5)
	_check("prism·验收5：register_mirror 帽拒（第 6 面被拒 + mirror_rejected 计数）",
		not reg_ok and DebugStats.get_counter(&"mirror_rejected") >= 1)
	junk.free()
	var slot_polluted := false
	for w in _gl.player.weapon_slots:
		if w is MirrorImage:
			slot_polluted = true
	_check("prism·验收5：镜面 ∉ weapon_slots（WEAPON 卡候选集零污染）", not slot_polluted)
	_kill_weapon(prism)
	_kill_weapon(src)
	_clear_enemies()


func _test_prism_tempo_budget_pointer() -> void:
	print("── prism·验收 6/7：攻速传导 / 奏鸣 / 预算闸 / 指向轴 ──")
	_clear_enemies()
	_wipe_weapons()
	var src := _add(&"W1_pistol")                  # 弹道源（add_rof 传导可见——节拍=1/rof）
	var prism := _make_prism(1)
	if prism == null:
		_check("prism·验收6 前置：棱镜装配", false)
		return
	prism.sync_mirrors(true)
	var img: MirrorImage = prism.mirrors[0]
	_check("prism·验收6 前置：镜面指向 W1（单源）", img.source_id() == &"W1_pistol",
		str(img.source_id()))
	# 攻速传导：挂 AFF_ROF_UP → refresh 扩扫后镜面 interval 与内壳同源同值且缩短
	var base_inner: float = float(img.inner.call("_fire_interval"))
	prism.attach_trait(_gl.registry.get_trait(&"AFF_ROF_UP"))
	prism.sync_mirrors(true)
	_gl.player.refresh_weapon_intervals()
	img = prism.mirrors[0]
	var after_inner: float = float(img.inner.call("_fire_interval"))
	_check("prism·验收6：镜面 _fire_interval 与内壳同源同值（AFF_ROF_UP 随栈传导缩短）",
		_approx(img._fire_interval(), after_inner, 0.0001) and after_inner < base_inner,
		"mirror=%.4f inner=%.4f base=%.4f" % [img._fire_interval(), after_inner, base_inner])
	# 镜面 rof 钳 30/s：超高 add_rof → interval 钳 1/30
	var fast: TraitData = (_gl.registry.get_trait(&"AFF_ROF_UP") as TraitData).duplicate()
	fast.value = 50.0
	prism.attach_trait(fast)
	prism.sync_mirrors(true)
	img = prism.mirrors[0]
	_check("prism·验收6：单镜 rof 帽 30/s（interval 钳 1/30）",
		_approx(img._fire_interval(), 1.0 / 30.0, 0.001),
		"iv=%.4f" % img._fire_interval())
	# MEC_MIRROR_TEMPO：仅镜面攻速 +15%/层 ×2 → 自持冷却 ×1.3 推进
	var tempo := _gl.registry.get_trait(&"MEC_MIRROR_TEMPO")
	prism.attach_trait(tempo)
	prism.attach_trait(tempo)
	prism.sync_mirrors(true)
	img = prism.mirrors[0]
	img.cooldown_left = 0.3
	_adv()
	img.tick(DT)
	_check("prism·验收6：MEC_MIRROR_TEMPO×2 → 镜面冷却 ×1.3 推进",
		_approx(img.cooldown_left, 0.3 - DT * 1.3, 0.0001),
		"left=%.5f" % img.cooldown_left)
	# 发射预算闸：耗尽 600 发/s → 该拍静默跳过 + 计数
	_check("prism·验收6 前置：budget_per_s==600", _approx(prism.budget_per_s(), 600.0, 0.001))
	var skip0: int = DebugStats.get_counter(&"mirror_budget_skipped")
	prism.budget_spend(600.0)
	img.cooldown_left = 0.0
	var live_before := _my_projectiles(img).size()
	_adv()
	img.tick(DT)
	_check("prism·验收6：超预算该拍静默跳过（mirror_budget_skipped +1、不出弹）",
		DebugStats.get_counter(&"mirror_budget_skipped") == skip0 + 1
		and _my_projectiles(img).size() == live_before)
	# 指向轴 WEIGHT：恒指向面板 DPS 最高武器（W1 14×5=70 > W6 18/0.55≈32.7）
	var heavy := _add(&"W6_micro_missile")         # 面板 DPS 更低源（WEIGHT 对照）
	var weight := _gl.registry.get_trait(&"MEC_MIRROR_WEIGHT")
	prism.attach_trait(weight)
	prism.sync_mirrors(true)
	var all_w1 := prism.mirrors.size() > 0
	for m in prism.mirrors:
		if m.source_id() != &"W1_pistol":
			all_w1 = false
	_check("prism·验收7：MEC_MIRROR_WEIGHT → 全镜指向面板 DPS 最高武器（W1）", all_w1)
	_kill_weapon(prism)
	_kill_weapon(heavy)
	_clear_enemies()
	# 指向轴 LOCK：既有指向固化（不再重掷）
	_wipe_weapons()
	var src2 := _add(&"W1_pistol")
	var prism2 := _make_prism(1)
	if prism2 == null:
		_check("prism·验收7 前置：棱镜装配", false)
		_kill_weapon(src2)
		return
	prism2.attach_trait(_gl.registry.get_trait(&"MEC_MIRROR_LOCK"))
	prism2.sync_mirrors(true)
	var ids_before: Array[StringName] = []
	for m in prism2.mirrors:
		ids_before.append(m.source_id())
	prism2.sync_mirrors(true)                      # 强制重排（模拟波首）
	var ids_after: Array[StringName] = []
	for m in prism2.mirrors:
		ids_after.append(m.source_id())
	_check("prism·验收7：MEC_MIRROR_LOCK → 波首重排指向不变（确定性出口）",
		ids_before == ids_after and ids_before.size() == 1,
		"%s→%s" % [str(ids_before), str(ids_after)])
	_check("prism·验收7：player._mirror_locked 挂载态同步",
		bool(_gl.player.get("_mirror_locked")))
	# 镜面银白/冰青染色 + 横幅句式（R183 读感区分）。
	# 注：MirrorImage 外壳无 copy_tint 类型化属性（set() 鸭子写是静默 no-op）——
	# 染色真源 = MirrorImage.TINT/EDGE 常量（_draw 棱形标记消费）；内壳旗标才可 get 读。
	var img2: MirrorImage = prism2.mirrors[0]
	var tint: Color = MirrorImage.TINT
	_check("prism·验收9：镜面染色银白/冰青（MirrorImage.TINT，禁金色调性）",
		_approx(tint.r, 0.82, 0.01) and _approx(tint.g, 0.92, 0.01)
		and _approx(tint.b, 1.0, 0.01), str(tint))
	_check("prism·验收9：内壳镜面旗标 is_mirror_image（弹体镜像描边分派读数）",
		img2.inner != null and bool(img2.inner.get("is_mirror_image")))
	_check("prism·验收9：横幅句式「棱镜映照：…」（对照 R183「召唤僚机」）",
		_mirror_banner.begins_with("棱镜映照"), _mirror_banner)
	_kill_weapon(prism2)
	_kill_weapon(src2)
	_clear_enemies()


func _test_prism_r183_exclusion() -> void:
	print("── prism·验收 8：R183 互斥（复制池排除 W5_prism / 双集合互不包含） ──")
	_clear_enemies()
	_wipe_weapons()
	var src := _add(&"W1_pistol")
	var prism := _make_prism(1)
	if prism == null:
		_check("prism·验收8 前置：棱镜装配", false)
		return
	prism.sync_mirrors(true)
	for i in range(8):
		_gl.player.call("_skill_summon_orbs")
	var w5_copied := false
	for c in _gl.player._summon_copies:
		if c != null and is_instance_valid(c) and c.data != null \
				and String(c.data.id) == "W5_prism":
			w5_copied = true
	_check("prism·验收8：8 次召唤复制池零 W5_prism（临时件永不产出永久件）",
		not w5_copied, "copies=%d" % _gl.player._summon_copies.size())
	var overlap := false
	for m in prism.mirrors:
		if _gl.player._summon_copies.has(m):
			overlap = true
	_check("prism·验收8：_mirror_images 与 _summon_copies 互不包含", not overlap)
	_gl.player.call("_summon_restore")
	_kill_weapon(prism)
	_kill_weapon(src)
	_clear_enemies()


# ── orbit（W8 蓄能轨道） ──────────────────────────────────────────
class ElementSpy extends ElementalSystem:
	var attach_calls: int = 0
	func apply_attach(p_enemy: Node2D, p_element: int, p_value: float,
			p_info: Dictionary = {}) -> void:
		attach_calls += 1


func _fresh_w8() -> OrbitWeapon:
	for i in range(_gl.player.weapon_slots.size()):
		var w: Variant = _gl.player.weapon_slots[i]
		if w != null and is_instance_valid(w) and w.data != null \
				and String(w.data.id).begins_with("W8"):
			_gl.player.weapon_slots[i] = null
			(w as WeaponBase).free()
	OrbitField.reset_detonate_gates()
	_clear_enemies()
	_gl.player.set("unlocked_slots", 5)
	var w8: OrbitWeapon = _add(&"W8_orbit_field") as OrbitWeapon
	if w8 != null:
		w8.data = w8.data.duplicate(true)
		w8.data.crit_rate = 0.0
		w8.meta_atk_pct = 0.0
		w8.call("_invalidate_panel")
	return w8


func _ensure_field(p_w8: OrbitWeapon, p_angular: float = 0.0) -> OrbitField:
	p_w8.call("try_fire")
	var field: OrbitField = p_w8.orbit_field
	if field != null:
		field.knockback = 0.0
		field.angular_speed = p_angular
	return field


func _step_w8(p_w8: OrbitWeapon, p_ticks: int) -> void:
	for i in range(p_ticks):
		_adv()
		p_w8.tick(DT)


func _test_orbit_r186_removal() -> void:
	print("── orbit·验收 2：R186 拆除负向锁死（ELE 恒空 + apply_attach 零调用） ──")
	var w8 := _fresh_w8()
	_check("orbit·验收2 前置：W8 装配", w8 != null)
	if w8 == null:
		return
	var field := _ensure_field(w8)
	_check("orbit·验收2 前置：力场创建", field != null)
	if field == null:
		return
	_check("orbit·验收2：attach 三件套零残留（attach_gate/attach_mult/_attach_cd）",
		not ("attach_gate" in field) and not ("attach_mult" in field)
		and not ("_attach_cd" in field))
	_check("orbit·验收2：_orb_element/_enchant_elements 方法不存在",
		not field.has_method("_orb_element") and not field.has_method("_enchant_elements"))
	var spy := ElementSpy.new()
	w8.elemental = spy
	w8.attach_trait(_gl.registry.get_trait(&"ELE_IGNITE"))
	var enemy := _spawn_e(_gl.player.global_position + Vector2(90.0, 0.0))
	_gl.elemental.register_host(enemy)
	var state: ElementalState = enemy.get("elemental")
	_step_w8(w8, 240)
	var empty := true
	if state != null:
		for g in state.gauges:
			if absf(g) > 0.0001:
				empty = false
		if state.burn_layers > 0 or state.burn_timer > 0.0:
			empty = false
	_check("orbit·验收2：挂 ELE 词条 240 帧接触 → 目标 elemental 恒空", empty)
	_check("orbit·验收2：apply_attach 经 W8 路径零调用", spy.attach_calls == 0,
		"calls=%d" % spy.attach_calls)
	_check("orbit·验收2：接触伤害照常落血（拆附着不拆输出底）",
		float(enemy.hp) < 1000000.0 - 10.0, "hp=%s" % str(enemy.hp))
	spy.free()
	_kill_weapon(w8)
	_clear_enemies()


func _test_orbit_charge_determinism() -> void:
	print("── orbit·验收 3：蓄能确定性（逐 tick / 内冷却 / 同帧双球 / 满档恰 1 爆） ──")
	var w8 := _fresh_w8()
	if w8 == null:
		_check("orbit·验收3 前置：W8 装配", false)
		return
	var field := _ensure_field(w8)
	_check("orbit·验收3 前置：力场创建", field != null)
	if field == null:
		return
	var c := _gl.player.global_position
	var e1 := _spawn_e(c + Vector2(90.0, 0.0))
	_step_w8(w8, 1)
	_check("orbit·验收3：首接触 tick 恰 +1 蓄能", OrbitField.charge_of(e1) == 1,
		str(OrbitField.charge_of(e1)))
	_step_w8(w8, 12)                               # 0.1s < charge_gain_cd 0.5s
	_check("orbit·验收3：gain_cd 内冷却（+0）", OrbitField.charge_of(e1) == 1,
		str(OrbitField.charge_of(e1)))
	field.orb_radius = 300.0                       # 双球同帧压住同目标
	field._gain_cd.clear()
	_adv()
	w8.tick(DT)
	_check("orbit·验收3：同帧双球触达同目标蓄能仅 +1", OrbitField.charge_of(e1) == 2,
		str(OrbitField.charge_of(e1)))
	field.orb_radius = 16.0
	# 满 5 恰 1 次引爆 + AoE=5×atk + w8_detonations 逐一吻合
	var det0: int = DebugStats.get_counter(&"w8_detonations")
	var s1 := _spawn_e(c + Vector2(150.0, 0.0))    # 引爆心 60px（90px AoE 内）
	var s2 := _spawn_e(c + Vector2(210.0, 0.0))    # 120px（AoE 外）
	var hp_s1: float = float(s1.hp)
	var hp_s2: float = float(s2.hp)
	var detonated := false
	for i in range(600):
		_step_w8(w8, 1)
		if OrbitField.charge_of(e1) == 0 and i > 12:
			detonated = true
			break
	_check("orbit·验收3：满 5 档恰触发 1 次引爆（池清零）", detonated)
	_check("orbit·验收3：DebugStats w8_detonations 逐一吻合（+1）",
		DebugStats.get_counter(&"w8_detonations") == det0 + 1)
	_check("orbit·验收3：AoE 落伤 =5×atk（60px 内副目标恰 50）",
		_approx(hp_s1 - float(s1.hp), 50.0, 0.05),
		"Δ=%s" % str(hp_s1 - float(s1.hp)))
	_check("orbit·验收3：90px 环外零波及", _approx(hp_s2 - float(s2.hp), 0.0, 0.001),
		"Δ=%s" % str(hp_s2 - float(s2.hp)))
	_kill_weapon(w8)
	_clear_enemies()


func _test_orbit_detonate_gates() -> void:
	print("── orbit·验收 3b：引爆三道闸（全局 ICD ≥0.5s） ──")
	var w8 := _fresh_w8()
	if w8 == null:
		_check("orbit·验收3b 前置：W8 装配", false)
		return
	var field := _ensure_field(w8)
	_check("orbit·验收3b 前置：力场创建", field != null)
	if field == null:
		return
	var c := _gl.player.global_position
	_spawn_e(c + Vector2(90.0, 0.0))
	_spawn_e(c + Vector2(-90.0, 0.0))
	var first_det := -1
	var second_det := -1
	for i in range(900):
		var d0: int = DebugStats.get_counter(&"w8_detonations")
		_step_w8(w8, 1)
		if DebugStats.get_counter(&"w8_detonations") > d0:
			if first_det < 0:
				first_det = i
			elif second_det < 0:
				second_det = i
				break
	var delay := float(second_det - first_det) * DT
	_check("orbit·验收3b：两目标同帧满档 → 第 2 次引爆延后 ≥0.5s（全局 ICD）且 <1.5s",
		first_det >= 0 and second_det >= 0 and delay >= 0.4999 and delay <= 1.5,
		"t1=%d t2=%d delay=%.3f" % [first_det, second_det, delay])
	_kill_weapon(w8)
	_clear_enemies()


func _test_orbit_cap_and_copies() -> void:
	print("── orbit·验收 4：刀数帽 + 复制体蓄能单例（恰 1 爆/周期） ──")
	var w8 := _fresh_w8()
	if w8 == null:
		_check("orbit·验收4 前置：W8 装配", false)
		return
	var field := _ensure_field(w8)
	_check("orbit·验收4 前置：力场创建", field != null)
	if field == null:
		return
	# 单目标刀数帽：帽 2 + 16 刀扫掠 → 命中事件 ≤ 帽等价位
	field.effective_blade_cap = 2
	field.charge_gain_cd = 0.05
	field.orbs = 16
	field.angular_speed = 335.0
	field._gain_cd.clear()
	field._blade_hits.clear()
	var c := _gl.player.global_position
	var e1 := _spawn_e(c + Vector2(120.0, 0.0))
	var events0: int = DebugStats.get_counter(&"orbit_hit")
	_step_w8(w8, 120)                              # 1.0s（<1 公转周，无清闸 wrap）
	var events: int = DebugStats.get_counter(&"orbit_hit") - events0
	var blades: Dictionary = field._blade_hits.get(int(e1.get("uid")), {})
	_check("orbit·验收4：16 刀单目标命中事件 ≤ effective_blade_cap 等价位（≤4）",
		events <= 4, "events=%d" % events)
	_check("orbit·验收4：登记 distinct 刀数 ≤ 帽（2）", blades.size() <= 2,
		str(blades.size()))
	# 复制体：蓄能池目标 uid 单例 → 恰 1 次引爆/周期（间隔 ≥0.5s 全局闸）
	field.effective_blade_cap = 8
	field.charge_gain_cd = 0.5
	field.orbs = 2
	field.angular_speed = 0.0
	field.angle = 0.0
	field._gain_cd.clear()
	field._blade_hits.clear()
	OrbitField.reset_detonate_gates()
	_clear_enemies()
	var copy := _gl.player._make_weapon_copy(w8)
	_gl.player._summon_copies.append(copy)
	copy.call("try_fire")
	var cfield: OrbitField = copy.get("orbit_field")
	_check("orbit·验收4 前置：副本力场创建（独立实体）",
		cfield != null and cfield != field)
	if cfield != null:
		cfield.knockback = 0.0
		cfield.angular_speed = 0.0
		cfield.angle = 0.0                     # R183 相位偏移 45° 定案（评审R5）在本段归零——
	                                       # 「uid 单例恰 1 爆」断言需双源同目标；45° 阵形由评审R5 专测
	var e2 := _spawn_e(c + Vector2(90.0, 0.0))     # 本体+复制体 orb0 同压一目标
	var det_ticks: Array[int] = []
	for i in range(720):                           # 6s：双源加速 → ≥3 周期
		var d0: int = DebugStats.get_counter(&"w8_detonations")
		_adv()
		w8.tick(DT)
		copy.tick(DT)
		if DebugStats.get_counter(&"w8_detonations") > d0:
			det_ticks.append(i)
	var gaps_ok := true
	var prev := -100
	for t in det_ticks:
		if t - prev < 55:                          # <0.46s 即同周期双爆
			gaps_ok = false
		prev = t
	_check("orbit·验收4：整个蓄能周期恰 1 次引爆（uid 单例 + 全局闸间隔 ≥0.5s）",
		det_ticks.size() >= 3 and gaps_ok,
		"dets=%d gaps_ok=%s" % [det_ticks.size(), str(gaps_ok)])
	_gl.player._summon_copies.erase(copy)
	copy.free()
	_kill_weapon(w8)
	_clear_enemies()


func _test_orbit_pulse_cdr_cards() -> void:
	print("── orbit·验收 5：脉冲与 CDR + 塑场 + 形态/当量卡 ──")
	var w8 := _fresh_w8()
	if w8 == null:
		_check("orbit·验收5 前置：W8 装配", false)
		return
	var field := _ensure_field(w8)
	_check("orbit·验收5 前置：力场创建", field != null)
	if field == null:
		return
	var c := _gl.player.global_position
	var e1 := _spawn_e(c + Vector2(90.0, 0.0))
	_step_w8(w8, 1)                                # 接触蓄能 1 档
	_check("orbit·验收5 前置：目标已蓄能", OrbitField.charge_of(e1) == 1)
	_step_w8(w8, 44)                               # 0.367s → 脉冲自闸让位
	var pulses: int = field.gravity_pulse()
	_check("orbit·验收5：已蓄能目标每 pulse 拍 +1（gravity_pulse 命中 1）",
		pulses == 1 and OrbitField.charge_of(e1) == 2,
		"pulses=%d charge=%d" % [pulses, OrbitField.charge_of(e1)])
	# AFF_CDR×2 → 脉冲间隔 = 3.0×(1−0.2)=2.4（weapon_base cd 通道首次生效）
	var iv0: float = float(w8.call("_fire_interval"))
	var cdr := _gl.registry.get_trait(&"AFF_CDR")
	w8.attach_trait(cdr)
	w8.attach_trait(cdr)
	var iv1: float = float(w8.call("_fire_interval"))
	_check("orbit·验收5：AFF_CDR×2 → 脉冲间隔 3.0→2.4",
		_approx(iv0, 3.0, 0.01) and _approx(iv1, 2.4, 0.05),
		"iv=%.3f→%.3f" % [iv0, iv1])
	# MEC_KNOCK：required_forms 解锁 [3] → W8 货架可出 + add_knock 平加击退终值
	var gen := _gl.card_generator
	var knock := _gl.registry.get_trait(&"MEC_KNOCK")
	_check("orbit·验收5：MEC_KNOCK 过 required_forms 门（W8 form=3 可上架）",
		gen._form_allows(knock, w8))
	w8.attach_trait(knock)
	w8.call("refresh_orbit_field")
	_check("orbit·验收5：add_knock 进力场击退终值（40+60=100）",
		_approx(float(w8.orbit_field.knockback), 100.0, 0.01),
		"kb=%.1f" % float(w8.orbit_field.knockback))
	# 塑场：切向 60% + 径向归环 ≤8px/击
	_kill_weapon(w8)
	_clear_enemies()
	var w8b := _fresh_w8()
	var field_b := _ensure_field(w8b)
	if field_b == null:
		_check("orbit·验收5 前置：力场 B", false)
		return
	field_b.knockback = 40.0
	field_b.charge_gain_cd = 99.0                  # 单次命中（防冲量叠加）
	var e2 := _spawn_e(c + Vector2(90.0, 0.0))     # 环上：纯切向（归环死区）
	_adv()
	w8b.tick(DT)
	var f: Vector2 = e2.knock_vel / 9.0            # Enemy.knockback 冲量=位移×9
	_check("orbit·验收6：命中后切向分量 = 击退×60%（>0 沿扫带）",
		_approx(f.dot(Vector2(0.0, 1.0)), 24.0, 0.05) and f.dot(Vector2(0.0, 1.0)) > 0.0,
		"t=%.1f" % f.dot(Vector2(0.0, 1.0)))
	_check("orbit·验收6：环上径向外移 ≤8px/击", absf(f.dot(Vector2.RIGHT)) <= 8.01,
		"r=%.1f" % f.dot(Vector2.RIGHT))
	_clear_enemies()
	var e3 := _spawn_e(c + Vector2(70.0, 0.0))     # 环内：径向归环向外
	_adv()
	w8b.tick(DT)
	var f2: Vector2 = e3.knock_vel / 9.0
	_check("orbit·验收6：环内目标归环向外推（>0）且 ≤8px/击",
		f2.dot(Vector2.RIGHT) > 0.0 and f2.dot(Vector2.RIGHT) <= 8.01,
		"r=%.1f" % f2.dot(Vector2.RIGHT))
	# 当量/传导新卡（§2.5 Design 6）：临界质量 5×→7× / 链式引爆转移 2 档
	_kill_weapon(w8b)
	_clear_enemies()
	var w8c := _fresh_w8()
	var field_c := _ensure_field(w8c)
	if field_c == null:
		_check("orbit·验收5 前置：力场 C", false)
		return
	var cm_ok: bool = w8c.attach_trait(_gl.registry.get_trait(&"MEC_CRITICAL_MASS"))
	w8c.attach_trait(_gl.registry.get_trait(&"MEC_CRITICAL_MASS"))
	w8c.call("refresh_orbit_field")
	_check("orbit·新卡：MEC_CRITICAL_MASS×2 → 引爆倍率 5×→7×",
		cm_ok and _approx(float(w8c.orbit_field.detonate_mult), 7.0, 0.001),
		"mult=%.1f（若仍 5.0 即消费点未接线）" % float(w8c.orbit_field.detonate_mult))
	var chain_ok: bool = w8c.attach_trait(_gl.registry.get_trait(&"MEC_CHAIN_DETONATE"))
	var e4 := _spawn_e(c + Vector2(90.0, 0.0))
	var neighbor := _spawn_e(c + Vector2(190.0, 0.0))   # 100px <160px 传导半径
	OrbitField.set_charge(neighbor, 0)
	OrbitField.set_charge(e4, 4)                   # 夹具补口：前置 4 档——本帧接触 +1 满档引爆
	_step_w8(w8c, 1)                               # 引爆 e4（满档）
	_check("orbit·新卡：MEC_CHAIN_DETONATE → 引爆转移 floor(5×0.4)=2 档给 160px 内最近敌",
		chain_ok and OrbitField.charge_of(neighbor) == 2,
		"charge=%d（若 0 即消费点未接线）" % OrbitField.charge_of(neighbor))
	_kill_weapon(w8c)
	_clear_enemies()


func _test_orbit_dps_probes() -> void:
	print("── orbit·验收 7：数值探针（L1 裸装 33.3 / L5 裸装 113.3，±10%） ──")
	var w8 := _fresh_w8()
	if w8 == null:
		_check("orbit·验收7 前置：W8 装配", false)
		return
	var field := _ensure_field(w8, 240.0)          # L1 真实转速表
	_check("orbit·验收7 前置：力场创建", field != null)
	if field == null:
		return
	var c := _gl.player.global_position
	# 45° 环位：解调脉冲节拍与接触节拍谐波锁死（w8_charge 同款夹具口径）
	var e1 := _spawn_e(c + Vector2(90.0, 0.0).rotated(deg_to_rad(45.0)), 100000.0)
	_step_w8(w8, 3600)                             # 30s 稳态采样
	var dps1: float = (100000.0 - float(e1.hp)) / 30.0
	_check("orbit·验收7：L1 裸装 DPS 33.3±10%（接触 16.7+引爆 16.7）",
		dps1 >= 30.0 and dps1 <= 36.7, "dps=%.2f" % dps1)
	w8.level = 5
	w8.call("_invalidate_panel")
	w8.call("refresh_orbit_field")
	field = w8.orbit_field
	field.knockback = 0.0
	OrbitField.reset_detonate_gates()
	_clear_enemies()
	var e5 := _spawn_e(c + Vector2(120.0, 0.0).rotated(deg_to_rad(45.0)), 100000.0)
	_step_w8(w8, 3600)
	var dps5: float = (100000.0 - float(e5.hp)) / 30.0
	_check("orbit·验收7：L5 裸装 DPS 113.3±10%（×3.4，锚 L5≥110）",
		dps5 >= 102.0 and dps5 <= 124.7, "dps=%.2f" % dps5)
	_kill_weapon(w8)
	_clear_enemies()


# ── 评审修复回归（第 1 轮评审 11 项落地点锁死） ──────────────────
func _test_review1_fixes() -> void:
	print("── 评审修复回归：回响门 / 回廊镜像 / 索敌 350 / 复制阵 / 余波 AoE / 品质梯 ──")
	_wipe_weapons()
	_clear_enemies()
	# ① R7 防回响绕门：MEC_HIVE_RACK(required_weapon=W6) 门拒 W7 / 放行 W6
	var hive := _gl.registry.get_trait(&"MEC_HIVE_RACK")
	var w6 := _make_w(&"W6_micro_missile", 1, true)
	var w7 := _make_w(&"W7_cluster_rocket", 1, true)
	_check("评审R7：mount_gate_allows(HIVE_RACK, W6)==true / (W7)==false",
		hive != null and CardGenerator.mount_gate_allows(hive, w6)
		and not CardGenerator.mount_gate_allows(hive, w7))
	# 回响负例：仅 W7 在场 → 任意种子回响都不落卡（echo_copies 不增、W7 零挂载）
	var rh: RelicHandler = _gl.relic_handler
	var echo_ok: bool = rh.activate(&"REL_ECHO")
	_check("评审R7 前置：REL_ECHO 激活", echo_ok)
	_kill_weapon(w6)
	var echoes0: int = rh.echo_copies
	for s in range(64):
		rh.rng.seed = s + 512
		rh._on_card_chosen(hive.id, 1)
	var w7_clean := true
	for tb in w7.trait_stack.traits:
		if tb.data != null and tb.data.id == &"MEC_HIVE_RACK":
			w7_clean = false
	_check("评审R7：回响仅 W7 在场 64 种子 → HIVE_RACK 零落卡（防 Boss 全中 ~700 崩坏链）",
		rh.echo_copies == echoes0 and w7_clean)
	# 回响正例：W6+W7 双枪 → 适配门内必落 W6（功能不死）
	var w6b := _make_w(&"W6_micro_missile", 1, true)
	for s2 in range(64):
		rh.rng.seed = s2 + 1024
		rh._on_card_chosen(hive.id, 1)
	var w6_hit := false
	var w7_hit := false
	for tb2 in w6b.trait_stack.traits:
		if tb2.data != null and tb2.data.id == &"MEC_HIVE_RACK":
			w6_hit = true
	for tb3 in w7.trait_stack.traits:
		if tb3.data != null and tb3.data.id == &"MEC_HIVE_RACK":
			w7_hit = true
	_check("评审R7：W6+W7 双枪回响 → HIVE_RACK 落 W6 不落 W7（门内功能保持）",
		rh.echo_copies > echoes0 and w6_hit and not w7_hit)
	_kill_weapon(w6b)
	_kill_weapon(w7)
	# ② R3/R8 回廊弹幕：反弹后 offset 镜像（corridor 消费点 + lane 翻转）
	var w1 := _make_w(&"W1_pistol", 3)
	w1.attach_trait(_gl.registry.get_trait(&"MEC_BOUNCE"))
	w1.attach_trait(_gl.registry.get_trait(&"MEC_RICOCHET_HALL"))
	_check("评审R3 前置：W1 L3 回廊标记激活（formation + HALL 挂载）",
		bool(w1.call("_corridor_active")))
	seed(42)
	w1.try_fire()
	var bullets: Array = _my_projectiles(w1)
	var mirror_ok: bool = bullets.size() == 2
	var xs_before: Array[float] = []
	if mirror_ok:
		for b in bullets:
			xs_before.append(float(b.get("_conv_gap")))
		for i in range(600):
			var all_bounced := true
			for b2 in bullets:
				if int(b2.get("_bounces_done")) == 0:
					all_bounced = false
				if bool(b2.get("_live")):
					(b2 as ProjectileBase).tick(DT)
			if all_bounced:
				break
		for i2 in range(2):
			var g0: float = xs_before[i2]
			var g1: float = float(bullets[i2].get("_conv_gap"))
			if not _approx(g1, -g0, 0.01):
				mirror_ok = false
	_check("评审R3：反弹后 lane offset 镜像（_conv_gap 符号翻转、模长保持 ±6）", mirror_ok)
	_kill_weapon(w1)
	_clear_enemies()
	# ③ R2 N=2 束质变：SPLIT_PRISM×2 → 副束索敌半径 250→350px
	var w4 := _make_w(&"W4_pulse_beam", 1)
	var far_e := _spawn_e(_gl.player.global_position + Vector2(300.0, 0.0))
	var prism := _gl.registry.get_trait(&"MEC_SPLIT_PRISM")
	var far300: Node2D = w4.call("_nearest_unhit", w4.muzzle_position(), [])
	_check("评审R2 前置：无棱镜 300px 敌不在 250px 索敌域", far300 == null)
	w4.attach_trait(prism)
	var mid: Node2D = w4.call("_nearest_unhit", w4.muzzle_position(), [])
	w4.attach_trait(prism)
	var far350: Node2D = w4.call("_nearest_unhit", w4.muzzle_position(), [])
	_check("评审R2：副束=1 → 250px 不索 / 副束=2 → 350px 索得 300px 敌",
		mid == null and far350 == far_e and int(w4.call("_sub_beam_count")) == 2)
	_kill_weapon(w4)
	_clear_enemies()
	# ④ R5 W8 复制体：BASE 单环阵 + 相位偏移 45°
	var w8s := _fresh_w8()
	if w8s == null:
		_check("评审R5 前置：W8 装配", false)
	else:
		w8s.call("try_fire")                   # 先建场（L1），再升 L5 重铺——源场=120px 等级表
		w8s.level = 5
		w8s.call("refresh_orbit_field")
		var src_radius: float = float(w8s.orbit_field.orbit_radius)
		var copy8: OrbitWeapon = _gl.player._make_weapon_copy(w8s) as OrbitWeapon
		_gl.player._summon_copies.append(copy8)
		copy8.try_fire()
		_check("评审R5：W8 复制体 BASE 单环阵（L5 源 120px → 副本 90px 基线）",
			copy8.orbit_field != null and _approx(float(copy8.orbit_field.orbit_radius), 90.0, 0.01)
			and _approx(src_radius, 120.0, 0.01))
		_check("评审R5：W8 复制体相位偏移 45°（本体 0）",
			copy8.orbit_field != null and _approx(copy8.orbit_field.angle, deg_to_rad(45.0), 0.001)
			and _approx(w8s.orbit_field.angle, 0.0, 0.001))
		_gl.player._summon_copies.erase(copy8)
		copy8.free()
		_kill_weapon(w8s)
	_clear_enemies()
	# ⑤ R4 引爆余波 AoE：0.5×blast_r 内邻近敌恰吃余波 38（无溅射污染的净几何）
	var w6c := _make_w(&"W6_micro_missile", 1, true)
	w6c.attach_trait(_gl.registry.get_trait(&"MEC_FUSE_COAT"))
	w6c.attach_trait(_gl.registry.get_trait(&"MEC_FUSE_COAT"))
	var w7c := _make_w(&"W7_cluster_rocket", 1, true)
	w7c.attach_trait(_gl.registry.get_trait(&"MEC_FUSE_DETONATE"))
	w7c.attach_trait(_gl.registry.get_trait(&"MEC_FUSE_DETONATE"))
	(w7c.data.homing).erase("sub_count_levels")
	(w7c.data.homing)["sub_count"] = 0.0
	var e_c := _spawn_e(Vector2(360.0, 560.0))     # 引信靶（爆心 D 左侧 100px）
	var e_n := _spawn_e(Vector2(414.0, 560.0))     # 邻靶：距引信靶 54px（<55 余波域 / >52 W6 爆径+hitbox）
	var d_c := _spawn_e(Vector2(260.0, 560.0))     # W7 主靶（爆心）
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	_fire_and_settle(w6c, e_c)                     # W6 铺引信（直击，38 爆径+14 hitbox 不及邻靶 54px）
	_check("评审R4 前置：引信靶挂标、邻靶零伤", _approx(float(e_c.get("fuse_mark_left")), 4.0, 0.001)
		and _approx(1000000.0 - float(e_n.hp), 0.0, 0.01))
	var hp_n: float = float(e_n.hp)
	_fire_and_settle(w7c, d_c)                     # W7 引爆：溅射中心 100px → 引信靶吃、邻靶只吃余波
	var d_n: float = hp_n - float(e_n.hp)
	_check("评审R4：余波 AoE 半径 0.5×blast_r → 邻靶恰吃 2×0.5×38=38（无溅射污染）",
		_approx(d_n, 38.0, 1.0), "dN=%.2f" % d_n)
	_kill_weapon(w6c)
	_kill_weapon(w7c)
	_clear_enemies()
	# ⑥ R9 品质梯：value 取整 × 层数（蓝档 2.03 → +2/层，卡面与消费端一致）
	var w4b := _make_w(&"W4_pulse_beam", 1)
	var prism_blue: TraitData = (_gl.registry.get_trait(&"MEC_SPLIT_PRISM") as TraitData).duplicate()
	prism_blue.value = 2.03
	w4b.attach_trait(prism_blue)
	_check("评审R9：SPLIT_PRISM 蓝(+2) 单挂 → 副束 2（原恒 1）",
		int(w4b.call("_sub_beam_count")) == 2)
	_kill_weapon(w4b)
	var w6d := _make_w(&"W6_micro_missile", 1, true)
	var rack_blue: TraitData = (_gl.registry.get_trait(&"MEC_HIVE_RACK") as TraitData).duplicate()
	rack_blue.value = 2.03
	w6d.attach_trait(rack_blue)
	w6d.call("_refresh_r183_effective")
	_check("评审R9：HIVE_RACK 蓝(+2) 单挂 → volley_eff 1+2=3",
		int(w6d.get("volley_eff")) == 3, str(w6d.get("volley_eff")))
	_kill_weapon(w6d)
	_clear_enemies()
	_wipe_weapons()

# r250_difficulty_weapon_cases.gd（二dc 难度武器门用例体——入口运行时加载）
# 口径：无局态门全开（基线）；进局态=大关门 AND 难度门。boot 用 r249 同款 GameLoop
# 模板；难度注入走 gl._difficulty 直设 + start_run（内部 set_run_difficulty 武装），
# 大关注入走 Meta.set_run_map（第 4/5 关）。
extends RefCounted

const GATE_SOURCE := "res://scripts/meta/mechanic_gate.gd"
const META_SOURCE := "res://scripts/meta/meta_manager.gd"
const GL_SOURCE := "res://scripts/loop/game_loop.gd"
const MENU_SOURCE := "res://scripts/ui/menu_screen.gd"
const ORBIT_SOURCE := "res://scripts/combat/weapon/melee/orbit_field.gd"

const FIVE := [&"W8_orbit_field", &"W9_arc_slash", &"W11_spirit_sword",
	&"W12_ground_axe", &"W13_great_sword"]
# 第 4/5 关 map id（大关门放行 W8/W9/W11/W12 / 全放）
const MAP4 := &"world_frost"
const MAP5 := &"world_swamp"

var tree: SceneTree
var _fails: int = 0


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> bool:
	if p_cond:
		print("  PASS | %s" % p_name)
	else:
		_fails += 1
		print("  FAIL | %s %s" % [p_name, p_detail])
	return p_cond


func fail_count() -> int:
	return _fails


func _read_source(p_path: String) -> String:
	var fs := FileAccess.open(p_path, FileAccess.READ)
	if fs == null:
		return ""
	var txt := fs.get_as_text()
	fs.close()
	return txt


func _map_id_at(p_idx: int) -> StringName:
	var m: Dictionary = MapTable.MAPS[p_idx] if p_idx >= 0 and p_idx < MapTable.MAPS.size() else {}
	return StringName(String(m.get("id", &"")))


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	print("── 0 环境 ──")
	RunSave.clear()
	_test_a_matrix_anchors()
	_test_b_no_run_all_open()
	_test_c_meta_armed()
	await _test_d_gate_matrix()
	await _test_e_card_pool_integration()
	_test_f_codex_locked_line()
	_test_g_intro_lines_anchor()
	_test_h_intro_filter_and_desc()


# ── A：矩阵源码锚 ─────────────────────────────────────────────────
func _test_a_matrix_anchors() -> void:
	print("── A 难度矩阵源码锚 ──")
	var src := _read_source(GATE_SOURCE)
	_check("A1 WEAPON_DIFFICULTY_GATE 五键（W8/W9=1 · W11/W12/W13=2）",
		src.contains("&\"W8_orbit_field\": 1") and src.contains("&\"W9_arc_slash\": 1")
			and src.contains("&\"W11_spirit_sword\": 2") and src.contains("&\"W12_ground_axe\": 2")
			and src.contains("&\"W13_great_sword\": 2"))
	_check("A2 weapon_allowed 叠难度门（run_gate_difficulty 消费在位）",
		src.contains("var d := Meta.run_gate_difficulty()")
			and src.contains("d < 0 or d >= weapon_difficulty_min(p_wid)"))
	_check("A3 未登记武器难度需求=0（漏登记不上锁）",
		MechanicGate.weapon_difficulty_min(&"W1_pistol") == 0
			and MechanicGate.weapon_difficulty_min(&"W10_boomerang") == 0)
	var msrc := _read_source(META_SOURCE)
	_check("A4 Meta 武装哨兵在位（run_gate_difficulty 单点）",
		msrc.contains("func run_gate_difficulty()") and msrc.contains("_run_difficulty_armed = true"))


# ── B：无局态全开（基线不动） ────────────────────────────────────
func _test_b_no_run_all_open() -> void:
	print("── B 无局态门全开 ──")
	# 口径：无局冷启动 run_map 默认 FIRST_MAP_ID（R196——大关门非 -1，此为既有行为，
	# 本批不碰）。难度层基线 = 未武装时不添乱：map 门放行语境下五武器全放。
	Meta.set_run_map(_map_id_at(4))
	var all_open := true
	for wid in FIVE:
		if not MechanicGate.weapon_allowed(wid):
			all_open = false
	_check("B1 未武装难度门不添乱（第 5 关语境五武器全放）", all_open,
		"gate=%s" % str(Meta.run_gate_difficulty()))


# ── C：Meta 武装哨兵 ──────────────────────────────────────────────
func _test_c_meta_armed() -> void:
	print("── C 武装哨兵语义 ──")
	_check("C1 未注入 → -1（与普通档 0 不混淆）", Meta.run_gate_difficulty() == -1)
	Meta.set_run_difficulty(0)
	_check("C2 set(0) 武装 → 0", Meta.run_gate_difficulty() == 0)
	Meta.set_run_difficulty(7)
	_check("C3 越界钳 2（clamp 既有语义）", Meta.run_gate_difficulty() == 2)


# ── D：门矩阵（大关 AND 难度） ───────────────────────────────────
func _test_d_gate_matrix() -> void:
	print("── D 双门组合 ──")
	# 大关第 4 关（map 门放 W8/W9/W11/W12；W13 须第 5 关）
	Meta.set_run_map(_map_id_at(3))
	Meta.set_run_difficulty(0)
	_check("D1 普通：五武器全锁（第 4 关语境）",
		not MechanicGate.weapon_allowed(&"W8_orbit_field")
			and not MechanicGate.weapon_allowed(&"W9_arc_slash")
			and not MechanicGate.weapon_allowed(&"W11_spirit_sword")
			and not MechanicGate.weapon_allowed(&"W12_ground_axe")
			and not MechanicGate.weapon_allowed(&"W13_great_sword"))
	Meta.set_run_difficulty(1)
	_check("D2 困难：W8/W9 放行，W11/W12/W13 仍锁",
		MechanicGate.weapon_allowed(&"W8_orbit_field")
			and MechanicGate.weapon_allowed(&"W9_arc_slash")
			and not MechanicGate.weapon_allowed(&"W11_spirit_sword")
			and not MechanicGate.weapon_allowed(&"W12_ground_axe")
			and not MechanicGate.weapon_allowed(&"W13_great_sword"))
	Meta.set_run_difficulty(2)
	_check("D3 地狱·第 4 关：W8/W9/W11/W12 放行，W13 仍锁（AND 大关门）",
		MechanicGate.weapon_allowed(&"W8_orbit_field")
			and MechanicGate.weapon_allowed(&"W9_arc_slash")
			and MechanicGate.weapon_allowed(&"W11_spirit_sword")
			and MechanicGate.weapon_allowed(&"W12_ground_axe")
			and not MechanicGate.weapon_allowed(&"W13_great_sword"))
	Meta.set_run_map(_map_id_at(4))
	_check("D4 地狱·第 5 关：W13 放行（全族开放）",
		MechanicGate.weapon_allowed(&"W13_great_sword"))
	_check("D5 非族武器不受难度门（W1/W2/W4/W10 恒放）",
		MechanicGate.weapon_allowed(&"W1_pistol")
			and MechanicGate.weapon_allowed(&"W2_gatling")
			and MechanicGate.weapon_allowed(&"W4_pulse_beam")
			and MechanicGate.weapon_allowed(&"W10_boomerang"))


# ── E：卡池集成（boot 进局） ────────────────────────────────────
func _boot_run(p_name: String, p_difficulty: int) -> GameLoop:
	# 独立实例开局：直设 current_map_id（start_run 消费它 set_run_map——预设 Meta 会被
	# 覆盖，r250 首跑实证）+ _difficulty（start_run 内 set_run_difficulty 武装）
	var gl: GameLoop = GameLoop.new()
	gl.name = p_name
	tree.get_root().add_child(gl)
	await tree.process_frame
	await tree.process_frame
	gl.current_map_id = _map_id_at(4)
	gl._difficulty = p_difficulty
	gl.start_run()
	await tree.process_frame
	return gl


func _test_e_card_pool_integration() -> void:
	print("── E 卡池集成 ──")
	var gl := await _boot_run("R250HellRun", 2)
	_check("E1 前置：地狱局 PLAYING", gl.state == GameConst.GameStatus.PLAYING,
		"state=%d" % gl.state)
	var pool_hell: Array = gl.card_generator.call(&"_weapon_candidates", gl.player)
	var has_w8 := false
	var has_w13 := false
	for wd in pool_hell:
		var wid := StringName(String(wd.get("id")))
		if wid == &"W8_orbit_field":
			has_w8 = true
		if wid == &"W13_great_sword":
			has_w13 = true
	_check("E2 地狱·第 5 关：候选池含 W8 与 W13（全族开放）",
		has_w8 and has_w13,
		"w8=%s w13=%s pool=%d" % [str(has_w8), str(has_w13), pool_hell.size()])
	gl.queue_free()
	await tree.process_frame
	# 普通局：同图独立实例（避免 quit_to_menu 局态清场语义混入）
	RunSave.clear()
	var gl2 := await _boot_run("R250NormalRun", 0)
	_check("E3 前置：普通局 PLAYING", gl2.state == GameConst.GameStatus.PLAYING,
		"state=%d" % gl2.state)
	var pool_norm: Array = gl2.card_generator.call(&"_weapon_candidates", gl2.player)
	var five_count := 0
	for wd in pool_norm:
		var wid := StringName(String(wd.get("id")))
		if wid in FIVE:
			five_count += 1
	_check("E4 普通·第 5 关：候选池零近战/法器", five_count == 0,
		"five_in_pool=%d pool=%d" % [five_count, pool_norm.size()])
	gl2.queue_free()
	await tree.process_frame


# ── F：图鉴锁行难度句 ─────────────────────────────────────────────
func _test_f_codex_locked_line() -> void:
	print("── F 图鉴锁行 ──")
	_check("F1 W8 锁行含困难提示", MechanicGate.weapon_locked_line(&"W8_orbit_field").contains("困难"),
		MechanicGate.weapon_locked_line(&"W8_orbit_field"))
	_check("F2 W11/W13 锁行含地狱提示",
		MechanicGate.weapon_locked_line(&"W11_spirit_sword").contains("地狱")
			and MechanicGate.weapon_locked_line(&"W13_great_sword").contains("地狱"))
	_check("F3 W1 锁行无难度句（非族武器零噪音）",
		not MechanicGate.weapon_locked_line(&"W1_pistol").contains("难度")
			and not MechanicGate.weapon_locked_line(&"W1_pistol").contains("困难"))


# ── G：开局横幅源码锚 ─────────────────────────────────────────────
func _test_g_intro_lines_anchor() -> void:
	print("── G 开局横幅 ──")
	var src := _read_source(GL_SOURCE)
	_check("G1 三档横幅文案锚（普通未开放/困难首对第4关起/地狱全开按大关推进）",
		src.contains("近战/法器类武器未开放")
			and src.contains("天狼刀（近战）· 旋风刀（法器）——第 4 关起上架")
			and src.contains("【地狱】近战/法器类全部开放（仍按大关推进）"))
	# QA BUG-1：横幅构建 R253 抽为 _append_difficulty_intro_lines——落位语义改锁 start_run
	# 内调用序（清行发生在 _grant_random_dual_loadout 非 echo 路径，追加调用必须在其后）
	var clear_at := src.find("_grant_random_dual_loadout(_active_daily_seed)")
	var banner_at := src.find("_append_difficulty_intro_lines()", clear_at)
	_check("G2 横幅调用在双武装清行之后（非 echo 角色不被吞——QA BUG-1；R253 抽函数版）",
		clear_at > 0 and banner_at > clear_at, "clear@%d banner@%d" % [clear_at, banner_at])


# ── H：intro 难度过滤 + 告知面（QA/评审修后锚） ────────────────────
func _test_h_intro_filter_and_desc() -> void:
	print("── H intro 过滤与告知面 ──")
	var i4n: String = MechanicGate.intro_for_map(3, 0)
	_check("H1 普通第 4 关 intro 无族武器名（假话消除——评审 H1）",
		not i4n.contains("天狼刀") and not i4n.contains("旋风刀")
			and not i4n.contains("灵剑") and not i4n.contains("裂地斧"), i4n)
	var i4h: String = MechanicGate.intro_for_map(3, 1)
	_check("H2 困难第 4 关 intro 只剩 W8/W9（滤灵剑/裂地斧）",
		i4h.contains("天狼刀") and i4h.contains("旋风刀")
			and not i4h.contains("灵剑") and not i4h.contains("裂地斧"), i4h)
	var i4l: String = MechanicGate.intro_for_map(3, 2)
	_check("H3 地狱第 4 关 intro 原文全量（四把族武器在列）",
		i4l.contains("天狼刀") and i4l.contains("旋风刀")
			and i4l.contains("灵剑") and i4l.contains("裂地斧"))
	var i5n: String = MechanicGate.intro_for_map(4, 0)
	_check("H4 普通第 5 关 intro 滤阔剑留回旋刃（非族不受滤）",
		not i5n.contains("阔剑") and i5n.contains("回旋刃"), i5n)
	_check("H5 默认 -1 原文（mech_gate 既有断言兼容面）",
		MechanicGate.intro_for_map(3).contains("灵剑"))
	var menu_src := _read_source(MENU_SOURCE)
	_check("H6 图鉴可获取态难度尾注（评审 M1——menu 可获取分支接 weapon_difficulty_min）",
		menu_src.contains("var gd_min := MechanicGate.weapon_difficulty_min(wid)")
			and menu_src.contains("仅地狱难度对局可获取"))
	_check("H7 difficulty_desc 三档武器差异句（评审 M2）",
		GameConst.difficulty_desc(0).contains("近战/法器类不开放")
			and GameConst.difficulty_desc(1).contains("解锁近战/法器首批")
			and GameConst.difficulty_desc(2).contains("近战/法器全开"))
	var of_src := _read_source(ORBIT_SOURCE)
	_check("H8 W9 追击标注格式串修复（QA BUG-2——分支各自格式化）",
		of_src.contains("\"追击 ×%d · %.0f/斩\" % [orbs, atk]"))

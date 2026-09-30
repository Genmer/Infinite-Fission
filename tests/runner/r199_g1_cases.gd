# tests/runner/r199_g1_cases.gd
# R199-G1 局内循环组用例体（由 test_r199_g1.gd 入口加载）。
# 覆盖（R199 规划 G1 组四项）：
#   · C10（medium）boot 空表闸 weapons 同判：weapons 缺失 + enemies/total 满 → boot_fatal
#     置位拒绝入局（修前静默放行 = 静默空手开局，R194 导出漏数据同族）
#   · P01（high）restart_run 补授 GameConst.difficulty_revives(_difficulty)：困难 +1 /
#     地狱 +3 附赠复活在暂停重开 / 结算重开两条路均不缩水（与 start_run/continue_run 同口径）
#   · P18（medium）选卡收口 / continue_endless 直迁 PLAYING 接 0.5s 输入宽限（_arm_resume_grace）：
#     模态期拖动残留不落位（修前 300px 级瞬移）、宽限到期放行（与暂停恢复同款）
#   · N13（medium）换一批复传首 roll 留存保底（_card_rarity_floor）：保底紫+对重发批次成立；
#     WORDS_TIDE 自动重随走 fixed_rarities 保序口径不回归；保底不跨流泄漏
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_test_c10_boot_gate_weapons()
	_test_p01_restart_difficulty_revives()
	_test_p18_card_choice_grace()
	_test_p18_continue_endless_grace()
	_test_n13_reroll_keeps_rarity_floor()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R199G1GameLoopUnderTest"
	tree.get_root().add_child(_gl)              # _ready 同步跑完整 boot 段（history_cases 同口径）
	_gl.current_map_id = MapTable.FIRST_MAP_ID


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


func _menu_start(p_difficulty: int) -> void:
	_gl.state = GameConst.GameStatus.MENU
	_gl.call(&"_on_menu_start", StringName("world_grass"), p_difficulty)


# ── R199-C10：boot 空表闸 weapons 同判 ────────────────────────────
func _test_c10_boot_gate_weapons() -> void:
	print("── R199-C10 boot 空表闸 weapons 同判 ──")
	_check("R199-C10 前置：共享 GL 满注册表正常入 MENU（boot_fatal 空）",
		_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU
		and _gl.boot_fatal.is_empty())
	# 裸 GameLoop 直驱闸方法（export_data_cases.gd T4 同口径；不入树，用毕 free）
	var gl2: GameLoop = GameLoop.new()
	gl2.name = "R199G1BootGateUnderTest"
	var reg := DataRegistry.new()
	var ed := EnemyData.new()
	ed.id = &"E_R199_G1"
	ed.hp_base = 10.0
	reg.enemies[&"E_R199_G1"] = ed
	reg.report = {"total": 1, "rejected": 0, "errors": [], "warnings": []}
	gl2.registry = reg
	gl2._boot_check_empty_registry()
	_check("R199-C10① weapons 空 + enemies 满 + total>0 → boot_fatal 置位（拒绝入局）",
		not gl2.boot_fatal.is_empty(), str(gl2.boot_fatal))
	_check("R199-C10①b 闸诊断文本含 weapons=0 计数（导出漏类目可定位）",
		not gl2.boot_fatal.is_empty() and String(gl2.boot_fatal[0]).contains("weapons=0"),
		str(gl2.boot_fatal))
	# 正态对照：weapons 回填 → 放行（enemies/total/weapons 同判不误伤满注册表）
	var wd := WeaponData.new()
	wd.id = &"W_R199_G1"
	reg.weapons[&"W_R199_G1"] = wd
	gl2.boot_fatal = []
	gl2._boot_check_empty_registry()
	_check("R199-C10② weapons 回填后放行（boot_fatal 保持空）",
		gl2.boot_fatal.is_empty(), str(gl2.boot_fatal))
	gl2.free()


# ── R199-P01：restart_run 难度附赠复活补授 ────────────────────────
func _test_p01_restart_difficulty_revives() -> void:
	print("── R199-P01 restart_run 难度附赠复活 ──")
	var meta_charges := int(Meta.revive_charges())
	# 困难（附赠 1）：暂停面板「重新开始」路（PAUSED → restart_run）
	_menu_start(1)
	var revives_hard := int(_gl.player.revives_left)
	_check("R199-P01① 困难开局 revives = 养成 %d + 附赠 1" % meta_charges,
		revives_hard == meta_charges + 1, "revives=%d" % revives_hard)
	_gl.request_pause()
	_check("R199-P01② 暂停重开后困难附赠复活保留（不回落养成值）",
		_gl.restart_run() and int(_gl.player.revives_left) == revives_hard,
		"restart 后 revives=%d（开局 %d）" % [int(_gl.player.revives_left), revives_hard])
	_gl.quit_to_menu()
	# 地狱（附赠 3）：结算屏「再来一局」路（GAME_OVER → restart_run）
	_menu_start(2)
	var revives_hell := int(_gl.player.revives_left)
	_check("R199-P01③ 地狱开局 revives = 养成 %d + 附赠 3" % meta_charges,
		revives_hell == meta_charges + 3, "revives=%d" % revives_hell)
	_gl.change_state(GameConst.GameStatus.GAME_OVER)
	_check("R199-P01④ 结算重开后地狱附赠复活保留",
		_gl.restart_run() and int(_gl.player.revives_left) == revives_hell,
		"restart 后 revives=%d（开局 %d）" % [int(_gl.player.revives_left), revives_hell])
	_gl.quit_to_menu()
	# 普通（附赠 0）对照：重开不凭空增发、也不缩水
	_menu_start(0)
	_gl.change_state(GameConst.GameStatus.GAME_OVER)
	_check("R199-P01⑤ 普通局重开 revives = 养成值（附赠 0 口径不变）",
		_gl.restart_run() and int(_gl.player.revives_left) == meta_charges,
		"revives=%d 养成=%d" % [int(_gl.player.revives_left), meta_charges])
	_gl.quit_to_menu()


# ── R199-P18①：选卡收口输入宽限（拖动残留不落位） ─────────────────
func _test_p18_card_choice_grace() -> void:
	print("── R199-P18 选卡收口输入宽限 ──")
	_gl.state = GameConst.GameStatus.MENU
	_gl.start_run()
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.set("invuln_left", 9999.0)
	for i in range(10):
		_gl._physics_process(DT)               # 出生位稳定（history_cases 同口径）
	# 合法活动域（player.gd _clamp_to_playfield：y ≥ size.y×0.6）——置下半场防合法钳制
	# 干扰「残留拖动不落位」断言（置 640 会被钳到 768 = 假阳性瞬移）
	_gl.player.global_position = Vector2(360.0, 1000.0)
	_gl.player.gain_xp(_gl.player.xp_need)     # → LEVEL_UP 弹卡
	_check("R199-P18 前置：升级弹卡（LEVEL_UP）",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open)
	_gl.player._drag_accum = Vector2(300.0, -600.0)   # 选卡模态期拖动残留（probe v3 D 路同口径）
	var pos0: Vector2 = _gl.player.global_position
	_gl._on_card_choice([_gl.current_candidates[0]])
	_gl.player.set("xp_need", 1e18)            # 防后续驱动期拾取/击杀弹卡（保宽限计时连续）
	_check("R199-P18① 选卡收口回 PLAYING + 宽限置位（grace>0 且 input_enabled=false）",
		_gl.state == GameConst.GameStatus.PLAYING
		and _gl.resume_grace_left > 0.0 and not _gl.player.input_enabled,
		"grace=%.3f input=%s" % [_gl.resume_grace_left, str(_gl.player.input_enabled)])
	for i in range(5):
		_gl._physics_process(DT)
	var jump: Vector2 = _gl.player.global_position - pos0
	_check("R199-P18② 收口后 5 帧位移 ≈0（300px 级拖动残留被宽限吞掉，不瞬移）",
		jump.length() < 1.0, "jump=%s |jump|=%.1f" % [str(jump), jump.length()])
	_check("R199-P18③ 宽限期内输入保持禁用", not _gl.player.input_enabled)
	for i in range(90):                            # 0.5s = 60 帧 + 浮点余量（pkg4 同手法）
		_gl._physics_process(DT)
	_check("R199-P18④ 宽限到期输入放行（与暂停恢复同款 0.5s）",
		_gl.resume_grace_left == 0.0 and _gl.player.input_enabled,
		"grace=%.6f input=%s" % [_gl.resume_grace_left, str(_gl.player.input_enabled)])
	_gl.request_pause()
	_gl.quit_to_menu()


# ── R199-P18②：continue_endless 直迁接宽限 ───────────────────────
func _test_p18_continue_endless_grace() -> void:
	print("── R199-P18 无尽继续输入宽限 ──")
	# Meta 结算快照隔离（verify_feedback R62 同口径：收尾结算改写的记录测试尾整体还原）
	var saved_records: Dictionary = Meta.records.duplicate()
	var saved_crystals: int = Meta.crystals
	var saved_mr: Dictionary = {}
	for k in Meta.map_records:
		saved_mr[k] = (Meta.map_records[k] as Dictionary).duplicate()
	RunSave.clear()
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = &"world_grass"        # final_wave=10
	_gl.start_run()
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.set("invuln_left", 9999.0)
	_gl.player.set("xp_need", 1e18)            # 防驱动期弹卡
	_gl.wave_director.start_wave(10)
	EventBus.emit_wave_cleared(10)             # final 波清空 → 收尾窗
	_gl._tick_victory_pending(0.02)
	_gl._tick_victory_pending(2.3)             # 窗结束 → GAME_OVER（胜利屏）
	_check("R199-P18 前置：胜利结算进 GAME_OVER",
		_gl.state == GameConst.GameStatus.GAME_OVER)
	var pos0: Vector2 = _gl.player.global_position
	_gl.player._drag_accum = Vector2(300.0, -600.0)   # 结算屏期拖动残留
	_check("R199-P18⑤ continue_endless 成功 + 宽限置位",
		_gl.continue_endless() and _gl.state == GameConst.GameStatus.PLAYING
		and _gl.resume_grace_left > 0.0 and not _gl.player.input_enabled,
		"grace=%.3f input=%s" % [_gl.resume_grace_left, str(_gl.player.input_enabled)])
	for i in range(5):
		_gl._physics_process(DT)
	var jump: Vector2 = _gl.player.global_position - pos0
	_check("R199-P18⑥ 无尽续打后 5 帧位移 ≈0（残留不落位）",
		jump.length() < 1.0, "jump=%s |jump|=%.1f" % [str(jump), jump.length()])
	# 收尾：无尽局死亡结算 → 回菜单（结算改写用快照还原）
	_gl.change_state(GameConst.GameStatus.GAME_OVER)
	_gl.quit_to_menu()
	Meta.records = saved_records
	Meta.crystals = saved_crystals
	Meta.map_records = saved_mr
	RunSave.clear()


# ── R199-N13：换一批复传稀有度保底 ────────────────────────────────
func _test_n13_reroll_keeps_rarity_floor() -> void:
	print("── R199-N13 换一批保底留存 ──")
	_gl.state = GameConst.GameStatus.MENU
	_gl.start_run()
	_gl.player.set("reroll_charges", 5)
	_gl.card_generator.rng.seed = 20261001     # 固定卡池序列（断言确定性）
	# 首发武器抬到 L3（R85 精通卡去金档：L1-2 精通卡稀有度钳 ≤1——保底紫+落精通卡会被
	# _apply_rarity_values 合法钳回蓝，属 card_generator 侧既定口径；抬 L3 后 cap=2，
	# 本用例隔离验证的是 N13「换一批传真实保底」语义本身）
	var _w0: WeaponBase = _gl.player.weapon_slots[0]
	if _w0 != null and is_instance_valid(_w0):
		while int(_w0.get("level")) < 3:
			_w0.level_up()
	# 白盒注入保底（REL_OVERCLOCK 精英首杀真链 pkg5:488-494 已覆盖，此处直设等效值 2=紫）
	_gl.relic_handler.rarity_floor_next = 2
	_gl.player.gain_xp(_gl.player.xp_need)     # → _open_card_flow 消费保底开流
	_check("R199-N13① 首 roll 保底落首卡（rarity≥2）+ 值留存本类 + 源头消费即焚",
		_gl.state == GameConst.GameStatus.LEVEL_UP
		and int(_gl.current_candidates[0].get("rarity", 0)) >= 2
		and int(_gl.get("_card_rarity_floor")) == 2
		and int(_gl.relic_handler.rarity_floor_next) == -1,
		"r0=%d floor=%d next=%d" % [int(_gl.current_candidates[0].get("rarity", 0)),
		int(_gl.get("_card_rarity_floor")), int(_gl.relic_handler.rarity_floor_next)])
	var charges0 := int(_gl.player.reroll_charges)
	_gl._on_card_reroll()                      # 本局首次免费
	_check("R199-N13② 换一批后首卡仍 ≥2（保底不洗掉——R199 核心回归断言）",
		int(_gl.current_candidates[0].get("rarity", 0)) >= 2,
		"r0=%d" % int(_gl.current_candidates[0].get("rarity", 0)))
	_check("R199-N13③ 首次换一批免费（次数不扣）",
		int(_gl.player.reroll_charges) == charges0)
	_gl._on_card_reroll()                      # 第二次：扣 1 次
	_gl._on_card_reroll()                      # 第三次：再扣 1 次
	_check("R199-N13④ 多批换一批持续 ≥2 + 次数按次扣（5→3）",
		int(_gl.current_candidates[0].get("rarity", 0)) >= 2
		and int(_gl.player.reroll_charges) == charges0 - 2,
		"r0=%d charges=%d" % [int(_gl.current_candidates[0].get("rarity", 0)),
		int(_gl.player.reroll_charges)])
	# WORDS_TIDE 口径（R199 勿回归）：自动重随走 fixed_rarities 保序，保底经首 roll 折入
	_gl._on_card_choice([_gl.current_candidates[0]])   # 收口当前流
	_gl.player.set("xp_need", 10)
	_gl.relic_handler.reroll_pending = true    # 波开始重随申请（白盒等效 pkg5:500-503）
	_gl.relic_handler.rarity_floor_next = 2
	_gl.player.gain_xp(10)                     # → 新流：首 roll 保底 + WORDS_TIDE 自动重随
	_check("R199-N13⑤ WORDS_TIDE 自动重随：首卡 ≥2（保底折入首 roll 序列且被保序保留）",
		_gl.state == GameConst.GameStatus.LEVEL_UP
		and int(_gl.current_candidates[0].get("rarity", 0)) >= 2,
		"r0=%d" % int(_gl.current_candidates[0].get("rarity", 0)))
	_gl._on_card_reroll()
	_check("R199-N13⑥ WORDS_TIDE 流内手动换一批仍 ≥2",
		int(_gl.current_candidates[0].get("rarity", 0)) >= 2,
		"r0=%d" % int(_gl.current_candidates[0].get("rarity", 0)))
	# 保底不跨流泄漏：新流无新保底 → 留存值复位 -1（首卡稀有度不受约束）
	_gl._on_card_choice([_gl.current_candidates[0]])
	_gl.player.set("xp_need", 10)
	_gl.player.gain_xp(10)
	_check("R199-N13⑦ 下一流无保底（floor=-1，不跨流泄漏）",
		int(_gl.get("_card_rarity_floor")) == -1,
		"floor=%d" % int(_gl.get("_card_rarity_floor")))
	_gl._on_card_choice([_gl.current_candidates[0]])
	_gl.request_pause()
	_gl.quit_to_menu()

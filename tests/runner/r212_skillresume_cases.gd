# tests/runner/r212_skillresume_cases.gd
# R212 技能冷却随档·用例体（由 test_r212_skillresume.gd 入口在 autoload 就绪后运行时
# 加载编译）。
# 背景：用户 bug「返回主菜单，再回到游戏内，会刷新角色技能」——根因（探索期已实测
# 复现 60→0）：暂停卡「回主菜单」→ quit_to_menu 落盘 serialize_run（快照原 19 键无任何
# 技能态）→ 菜单「继续上次进度」→ continue_run → _restore_run_state → set_character
# （player.gd:494 skill_cd_left=0.0）之后的数值覆写区无技能覆写 → 冷却归零、技能立即
# 可用（HUD 直读 skill_cd_left 故用户可见）。
# 修法：快照加 "skill_cd" 键 + 恢复区（set_character 后，词条/遗物重建已定 skill_cd_base
# 基线）clampf 回填；旧档无键 → 0 保持原行为零迁移。
# 覆盖：① 快照含键 ② 暂停→回菜单→继续 往返保真（含落盘透传与清场归零对照）
# ③ 满 CD 边界（clamp 上界不误伤合法值）④ 旧档无键零迁移 ⑤ 脏档超界 clamp
# ⑥ 恢复后就绪态口径（未就绪不回归 + 零 CD 常规往返不受扰）。
extends RefCounted

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
	await tree.process_frame
	await tree.process_frame
	_test_1_snapshot_has_skill_cd()
	_test_2_pause_roundtrip()
	_test_3_full_cd_boundary()
	_test_4_legacy_save_without_key()
	_test_5_dirty_save_clamped()
	_test_6_ready_semantics()
	_teardown_game_loop()
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


# ── 引导/拆除（r211 骨架：main 场景实例化 GameLoop → MENU → start_run） ──
func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R212GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()


func _teardown_game_loop() -> void:
	# 本套件只读写 RunSave 局内存档（headless 自动隔离 run_save_test.cfg）与 player 会话
	# 态，不动 Meta.settings——无需设置复位；清档防跨套件残留「继续」入口
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


# 暂停态直切（绕过 change_state 副作用——quit_to_menu 只读 state 判 was_paused 落盘）
func _force_pause() -> void:
	_gl.state = GameConst.GameStatus.PAUSED


# ── ① 快照含键：serialize_run 携带技能冷却剩余 ──
func _test_1_snapshot_has_skill_cd() -> void:
	print("── ① 快照含 skill_cd 键 ──")
	var player := _gl.player
	_check("前提：默认角色有技能（skill_cd_base>0）", player.skill_cd_base > 0.0,
		"base=%s" % str(player.skill_cd_base))
	var half: float = player.skill_cd_base * 0.5
	player.skill_cd_left = half
	var snap: Dictionary = _gl.serialize_run()
	_check("serialize_run 含 skill_cd 键（原 19 键无技能态）", snap.has("skill_cd"),
		"keys=%s" % str(snap.keys()))
	_check("快照值保真（半 CD）", absf(float(snap.get("skill_cd", -1.0)) - half) < 0.01,
		"got=%s want=%s" % [str(snap.get("skill_cd", "?")), str(half)])


# ── ② 用户主诉链路：暂停 → 回主菜单（落盘+清场）→ 继续上次进度 ──
func _test_2_pause_roundtrip() -> void:
	print("── ② 暂停往返保真 ──")
	var half: float = _gl.player.skill_cd_base * 0.5
	_gl.player.skill_cd_left = half
	_force_pause()
	_check("quit_to_menu 成功（PAUSED→MENU）", _gl.quit_to_menu(),
		"state=%s" % str(_gl.state))
	var disk: Dictionary = RunSave.load_run()
	_check("落盘档透传 skill_cd（ConfigFile float 往返）",
		absf(float(disk.get("skill_cd", -1.0)) - half) < 0.01,
		"disk=%s want=%s" % [str(disk.get("skill_cd", "?")), str(half)])
	_check("回菜单清场后 CD 归零（证明恢复源在档而非实例残留）",
		_gl.player.skill_cd_left == 0.0,
		"left=%s" % str(_gl.player.skill_cd_left))
	_check("continue_run 成功（MENU→PLAYING）", _gl.continue_run(),
		"state=%s" % str(_gl.state))
	_check("往返后 skill_cd_left 保真（修复前此处为 0=技能被刷新）",
		absf(_gl.player.skill_cd_left - half) < 0.5,
		"got=%s want=%s" % [str(_gl.player.skill_cd_left), str(half)])


# ── ③ 边界：满 CD（刚放完技能）往返不被 clamp 误伤 ──
func _test_3_full_cd_boundary() -> void:
	print("── ③ 满 CD 边界 ──")
	_gl.player.skill_cd_left = _gl.player.skill_cd_base
	_force_pause()
	_gl.quit_to_menu()
	_gl.continue_run()
	_check("满 CD 往返保真（clamp 上界=恢复后基线，合法满值不截断）",
		is_equal_approx(_gl.player.skill_cd_left, _gl.player.skill_cd_base),
		"got=%s base=%s" % [str(_gl.player.skill_cd_left), str(_gl.player.skill_cd_base)])


# ── ④ 旧档兼容：无 skill_cd 键（R212 之前落的档）恢复 0 不炸 ──
func _test_4_legacy_save_without_key() -> void:
	print("── ④ 旧档无键零迁移 ──")
	_gl.player.skill_cd_left = _gl.player.skill_cd_base * 0.5
	_force_pause()
	_gl.quit_to_menu()
	var data: Dictionary = RunSave.load_run()
	data.erase("skill_cd")                       # 模拟 R212 之前的旧档
	RunSave.save_run(data)
	_check("旧档 continue_run 成功（缺键不炸）", _gl.continue_run(),
		"state=%s" % str(_gl.state))
	_check("旧档无键 → 恢复 0（保持原行为零迁移）", _gl.player.skill_cd_left == 0.0,
		"left=%s" % str(_gl.player.skill_cd_left))


# ── ⑤ 脏档防御：skill_cd 超界值 clamp 到恢复后基线 ──
func _test_5_dirty_save_clamped() -> void:
	print("── ⑤ 脏档超界 clamp ──")
	_gl.player.skill_cd_left = _gl.player.skill_cd_base * 0.5
	_force_pause()
	_gl.quit_to_menu()
	var data: Dictionary = RunSave.load_run()
	data["skill_cd"] = 99999.0                   # 手改档/坏档防御
	RunSave.save_run(data)
	_gl.continue_run()
	_check("脏档超界被 clamp 到 skill_cd_base（不产出 >基线 的非法倒计时）",
		is_equal_approx(_gl.player.skill_cd_left, _gl.player.skill_cd_base),
		"got=%s base=%s" % [str(_gl.player.skill_cd_left), str(_gl.player.skill_cd_base)])


# ── ⑥ 就绪态口径：恢复后未就绪不回归 + 零 CD 常规往返不受扰 ──
func _test_6_ready_semantics() -> void:
	print("── ⑥ 恢复后就绪态 ──")
	# 半 CD 往返 → 未就绪（修复前恢复即可用=用户感知的「技能被刷新」）
	_gl.player.skill_cd_left = _gl.player.skill_cd_base * 0.5
	_force_pause()
	_gl.quit_to_menu()
	_gl.continue_run()
	_check("半 CD 往返后技能未就绪（skill_ready()==false）",
		not _gl.player.skill_ready(),
		"left=%s ready=%s" % [str(_gl.player.skill_cd_left), str(_gl.player.skill_ready())])
	# 零 CD（开局未放技能）往返 → 仍就绪（常规继续局不受扰）
	_gl.player.skill_cd_left = 0.0
	_force_pause()
	_gl.quit_to_menu()
	_gl.continue_run()
	_check("零 CD 往返后保持就绪（开局未放技能语义不回归）",
		_gl.player.skill_cd_left == 0.0 and _gl.player.skill_ready(),
		"left=%s ready=%s" % [str(_gl.player.skill_cd_left), str(_gl.player.skill_ready())])

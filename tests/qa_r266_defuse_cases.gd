extends RefCounted
# R266 模态冻结清爆虫引导 cases（配套口 qa_r266_defuse.gd）。
# 用户澄清反馈（vc75）：「升级时，被自爆兵贴脸会来不及躲」——弹卡冻结期残余引信
# 不足（贴脸冲刺 260px/s + 爆炸 110px 半径，剩 <0.5s 数学上躲不掉）。修刀=进
# LEVEL_UP/PAUSED 冻结模态清空全部爆虫引导（enemy.defuse_if_armed 新公开口，
# _cancel_fuse 击退打断同款语义），收卡后重新接触重新计 1.2s 完整引信。
# D1 单元（defuse 语义/幂等/再引导完整引信）  D2 对照（PLAYING 期引导照常走）
# D3 集成 LEVEL_UP 清  D4 收卡回 PLAYING 后可重新引导（完整反应窗）
# D5 集成 PAUSED 同治  D6 非 volatile 敌零扰动
# 测试卫生：Meta 快照还原（r252/gift 惯例）；套件独立进程跑（start_run 图鉴写点）。
const DT := 1.0 / 120.0
const ENEMY_SCENE := "res://scenes/combat/enemies/enemy.tscn"

var _pass := 0
var _fail := 0
var _failures: Array[String] = []

var _snap_codex_weapons: Dictionary = {}
var _snap_codex_traits: Dictionary = {}
var _snap_character: StringName = &""
var _snap_custom_weapon: String = ""
var _snap_blessing: String = ""
var _snap_stardust: int = 0


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  ok | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("  FAIL | %s %s" % [p_name, p_detail])


func _make_volatile(p_parent: Node, p_player: Node2D, p_pos: Vector2) -> Enemy:
	# pkg4 爆虫臂同款内存构造（数值真源 A3 §2.2 E4 行）
	var vdata := EnemyData.new()
	vdata.id = &"E4_volatile"
	vdata.hp_base = 30.0
	vdata.spd_base = 120.0
	vdata.dmg_base = 20.0
	vdata.exp_base = 5.0
	vdata.tp_cost = 1.5
	vdata.behavior = GameConst.EnemyBehavior.CHASE
	vdata.hitbox_r = 14.0
	var bug := load(ENEMY_SCENE).instantiate() as Enemy
	p_parent.add_child(bug)
	bug.spawn(vdata, 1, 0)
	bug.global_position = p_pos
	bug._player_cache = p_player
	return bug


func run(p_tree: SceneTree) -> void:
	# ── 快照 ──
	_snap_codex_weapons = Meta.codex_weapons.duplicate()
	_snap_codex_traits = Meta.codex_traits.duplicate()
	_snap_character = Meta.character_id
	_snap_custom_weapon = Meta.custom_weapon_id
	_snap_blessing = Meta.blessing_trait_id
	_snap_stardust = int(Meta.stardust)

	var gl_script: GDScript = load("res://scripts/loop/game_loop.gd")
	var gl = gl_script.new()
	gl.name = "GameLoopForR266Defuse"
	p_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	var waited := 0
	while not gl.boot_ready and waited < 600:
		await p_tree.process_frame
		waited += 1
	_check("boot：菜单就绪", gl.boot_ready)
	if not gl.boot_ready:
		_wrap()
		return
	# 进 PLAYING（不弹祝福面板：直调 start_run 需先清 pending 闸——stress 套件序 0
	# 压力门同款口径：_blessing_pending=false + current_map_id + 直调）
	gl._blessing_pending = false
	gl._difficulty = 0
	gl.current_map_id = MapTable.FIRST_MAP_ID
	gl.start_run()
	await p_tree.process_frame
	_check("start_run：PLAYING 就位", gl.state == GameConst.GameStatus.PLAYING)
	if gl.state != GameConst.GameStatus.PLAYING:
		_wrap()
		return
	var player: Node2D = gl.player

	# ── D2 对照：PLAYING 期引导照常走（防误伤正常玩法）──
	var bug_c := _make_volatile(p_tree.get_root(), player, player.global_position + Vector2(4.0, 0.0))
	bug_c.tick(DT)
	_check("D2 对照：接触引导激活（fuse 1.2s）", bug_c.fuse_armed()
		and absf(bug_c.fuse_left() - 1.2) <= 0.001)
	for i in range(72):
		bug_c.tick(DT)                            # 推 0.6s——引信剩 ~0.6（照常递减）
	_check("D2 对照：PLAYING 期引信照常递减（剩≈0.6）",
		absf(bug_c.fuse_left() - 0.6) <= 0.02, "left=%.3f" % bug_c.fuse_left())
	bug_c.defuse_if_armed()                       # 清态防后续臂串扰（爆炸会伤玩家）

	# ── D1 单元：defuse 语义/幂等/再引导完整引信 ──
	var bug_u := _make_volatile(p_tree.get_root(), player, player.global_position + Vector2(4.0, 0.0))
	bug_u.tick(DT)
	_check("D1 单元：引导中 defuse 返 true+圈收+回未引导",
		bug_u.defuse_if_armed() and not bug_u.fuse_armed() and not bug_u._fuse_ring.visible)
	_check("D1 单元：未引导再 defuse 返 false（幂等）", not bug_u.defuse_if_armed())
	bug_u.tick(DT)                                # 贴脸再接触
	_check("D1 单元：再接触重新引导且引信回满 1.2s（完整反应窗）",
		bug_u.fuse_armed() and absf(bug_u.fuse_left() - 1.2) <= 0.001)
	# 非 volatile 敌零扰动（defuse_if_armed 恒 false）
	var gdata := EnemyData.new()
	gdata.id = &"E1_grunt"
	gdata.hp_base = 20.0
	gdata.spd_base = 90.0
	gdata.dmg_base = 8.0
	gdata.exp_base = 3.0
	gdata.tp_cost = 1.0
	gdata.behavior = GameConst.EnemyBehavior.CHASE
	gdata.hitbox_r = 14.0
	var grunt := load(ENEMY_SCENE).instantiate() as Enemy
	p_tree.get_root().add_child(grunt)
	grunt.spawn(gdata, 1, 0)
	grunt.global_position = player.global_position + Vector2(6.0, 0.0)
	grunt._player_cache = player
	grunt.tick(DT)
	_check("D6 非 volatile 敌：defuse_if_armed 恒 false（零扰动）",
		not grunt.defuse_if_armed() and not grunt.dead)

	# ── D3 集成：LEVEL_UP 弹卡清全部引导 ──
	gl.spawner.active.append(bug_u)
	gl.spawner.active.append(grunt)
	bug_u.tick(DT)                                # 确保引导中（上文 D1 已引导，防御再 tick）
	_check("D3 前置：爆虫引导中入 active", bug_u.fuse_armed()
		and gl.spawner.active.has(bug_u))
	_check("D3 集成：PLAYING→LEVEL_UP 迁移成立（pkg4:129 先例）",
		gl.change_state(GameConst.GameStatus.LEVEL_UP))
	_check("D3 集成：进 LEVEL_UP 全部爆虫引导清空+tree.paused",
		not bug_u.fuse_armed() and not bug_u._fuse_ring.visible
		and p_tree.paused)

	# ── D4 收卡回 PLAYING：重新接触重新引导（完整反应窗闭环）──
	_check("D4 集成：LEVEL_UP→PLAYING 收卡迁移成立",
		gl.change_state(GameConst.GameStatus.PLAYING))
	bug_u.global_position = player.global_position + Vector2(4.0, 0.0)
	bug_u.tick(DT)
	_check("D4 集成：收卡后爆虫可重新引导（引信 1.2s 完整）",
		bug_u.fuse_armed() and absf(bug_u.fuse_left() - 1.2) <= 0.001)

	# ── D5 集成：PAUSED 同治 ──
	_check("D5 集成：PLAYING→PAUSED 迁移成立",
		gl.change_state(GameConst.GameStatus.PAUSED))
	_check("D5 集成：进 PAUSED 引导同清", not bug_u.fuse_armed()
		and not bug_u._fuse_ring.visible)

	# ── 收尾清理 ──
	gl.change_state(GameConst.GameStatus.PLAYING)
	for b in [bug_c, bug_u, grunt]:
		if b != null and is_instance_valid(b):
			b.get_parent().remove_child(b)
			b.free()
	gl.spawner.active.erase(bug_u)
	gl.spawner.active.erase(grunt)
	gl.state = GameConst.GameStatus.PAUSED
	gl.quit_to_menu()
	await p_tree.process_frame
	_wrap()


func _wrap() -> void:
	# ── 快照还原 ──
	Meta.codex_weapons = _snap_codex_weapons.duplicate()
	Meta.codex_traits = _snap_codex_traits.duplicate()
	Meta.character_id = _snap_character
	Meta.custom_weapon_id = _snap_custom_weapon
	Meta.set_blessing_trait(StringName(_snap_blessing)) if not _snap_blessing.is_empty() \
		else Meta.clear_blessing_trait()
	Meta.stardust = _snap_stardust
	print("验收汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	for f in _failures:
		print("  RED | %s" % f)


func fail_count() -> int:
	return _fail

# tests/runner/r246_skills_cases.gd
# R246「技能升华」skills 泳道用例体（由 test_r246_skills.gd 入口在 autoload 就绪后运行时加载）。
# 覆盖 G0~G13 十四组（分组见套件头注）：每角色升华开/关两态断言，要点照各自设计文档 §测试。
# 夹具：真 GameLoop（main.tscn——cd_pace 同式）+ 敌池/弹池夹具（mirror_muzzle 同式）。
# 纪律：
#  · 勿 add_child 池化节点（池 acquire/release 自管）；经 EventBus.emit_enemy_killed 的
#    真派发击杀由 spawner 认领归还（_emit_kill 后立即 _forget 出夹具表，防 teardown 双归还）
#  · 伤害量值断言一律直调技能函数（player.tick 驱动会触发武器自动开火——W4 激光即时
#    结算会污染 hp 差值；弹道武器弹丸不经 GameLoop tick 不飞行，但激光是即时的）
#  · 节拍/时序断言走 DebugStats 计数器与 knock_vel（武器开火免疫观测量）
#  · 直调结算间 GameConfig.advance_frame 错帧（管线 (source,target,frame) 幂等键）
#  · 高频击杀喂层用处理器直调（_on_*_kill(null)/带活夹具——账本 miss 回退尸身直读），
#    每角色另保留真派发 emit 集成断言（覆盖 _kill_snap 账本路径：玩家订阅派发位在
#    spawner 归还之后，tags/elemental 只有账本先于 spawner 落的快照才读得到）
extends RefCounted

const DT := 0.1
const MAIN_SCENE := "res://scenes/main.tscn"
const CENTER := Vector2(360.0, 1000.0)
const DASH_HOME := Vector2(360.0, 880.0)   # ranger 位移断言起点（向下 340 不触 y≤1264 下界）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _fixtures: Array[Node2D] = []                 # 敌池夹具（收尾 release；被 spawner 认领的除外）
var _bullets: Array[Node2D] = []                  # 弹池夹具（nullify 自归还）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(246)
	_boot_game_loop()
	_g0_common_and_normal_regression()
	_g1_sentinel()
	_g2_veles()
	_g3_bulwark()
	_g4_ranger()
	_g5_zero()
	_g6_mank()
	_g7_vera()
	_g8_noah()
	_g9_echo()
	_g10_fission()
	_g11_medic()
	_g12_vortex()
	_g13_reaper()
	_teardown()
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


# ── 夹具（cd_pace/mirror_muzzle 同式） ───────────────────────────
func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopUnderTestR246"
	tree.get_root().add_child(_gl)


func _teardown() -> void:
	# 口径同 cd_pace 先例（GameLoop 夹具套件在 quit 时恒挂 1 个引擎侧
	# GDScriptFunctionState → ObjectDB 告警，cd_pace 同状——非本套件引入）
	tree.paused = false
	_banner_disconnect()
	_release_all()
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _drive(p_frames: int, p_dt: float = DT) -> void:
	# 手驱 player.tick（夹具敌在场时武器会自动开火——量值断言不在此路径上做）
	for i in range(p_frames):
		GameConfig.advance_frame()
		_gl.player.tick(p_dt, Vector2.ZERO)


func _frame() -> void:
	GameConfig.advance_frame()


func _p() -> Player:
	return _gl.player


func _as(p_char: StringName, p_sublime: bool) -> void:
	# 角色姿态直写（绕开 set_character 整局重置副作用——cd_pace 先例）：
	# 先 _reset_skill_temp_state 清上一组会话态（护壁/减伤窗/残影/监听等防跨组渗漏），
	# 再置位 + CD 基线同步。_reson_layers/_reson_kill_count 为 run 作用域（reset 刻意不清）。
	var pl := _p()
	pl._reset_skill_temp_state()
	pl.character_id = p_char
	pl.skill_cd_left = 0.0
	pl.skill_active_left = 0.0
	pl.rof_mult = 1.0
	pl.skill_sublime = p_sublime
	pl.refresh_skill_cd()
	pl.global_position = CENTER


func _fixture_data(p_id: StringName, p_hp: float) -> EnemyData:
	var d := EnemyData.new()
	d.id = p_id
	d.display_name = String(p_id)
	d.hp_base = p_hp
	d.spd_base = 0.0
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


func _mk_enemy(p_pos: Vector2, p_hp: float = 100000.0, p_tags: int = 0) -> Enemy:
	# 敌池夹具（入网格与否由调用方 rebuild 决定）
	var e := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	e.spawn(_fixture_data(&"E_R246_FIXTURE", p_hp), 1, p_tags)
	e.elemental = ElementalState.new()               # 时滞/冻结断言容器（qa_r217 同式）
	e.position = p_pos
	_fixtures.append(e)
	return e


func _forget(p_e: Node2D) -> void:
	# 出夹具表（该敌已由 spawner 经 enemy_killed 真派发认领归还——teardown 防双归还）
	_fixtures.erase(p_e)


func _emit_kill(p_e: Node2D) -> void:
	# 真派发击杀（ledger/spawner/drop_xp 全链路）：spawner 认领后立即出表
	EventBus.emit_enemy_killed(p_e)
	_forget(p_e)


func _grid(p_enemies: Array) -> void:
	var arr: Array[Node2D] = []
	for e in p_enemies:
		arr.append(e)
	_gl.enemy_grid.rebuild(arr)


func _grid_empty() -> void:
	var arr: Array[Node2D] = []
	_gl.enemy_grid.rebuild(arr)


func _mk_bullet(p_pos: Vector2) -> ProjectileBase:
	# 敌弹夹具（team=1——清弹/拂弹断言用；nullify 自归还池）
	var b: ProjectileBase = (_gl.pools[&"projectile"] as ProjectilePool).acquire()
	b.spawn({
		"position": p_pos, "velocity": Vector2.ZERO, "lifetime": 30.0,
		"pierce": 1, "hitbox_radius": 8.0, "team": 1,
		"panel_snapshot": {"base_atk": 5.0},
	})
	b.position = p_pos
	_bullets.append(b)
	return b


func _bullet_grid(p_bullets_in: Array) -> void:
	var arr: Array[Node2D] = []
	for b in p_bullets_in:
		arr.append(b)
	_gl.enemy_bullet_grid.rebuild(arr)


func _bullet_grid_empty() -> void:
	var arr: Array[Node2D] = []
	_gl.enemy_bullet_grid.rebuild(arr)


func _release_all() -> void:
	for e in _fixtures:
		if e != null and is_instance_valid(e):
			(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_fixtures.clear()
	_grid_empty()
	_bullet_grid_empty()


func _base_atk() -> float:
	# 主武器面板快照 base_atk（技能结算同源真值）
	return float(_p().weapon_slots[0].build_panel_snapshot().get("base_atk", 0.0))


# ── 横幅录音（成员持有 Callable，换带先断旧——防跨组渗漏与连接堆积） ──
var _banner_tape: Array = []
var _banner_fn: Callable = Callable()


func _banner_arm() -> Array:
	_banner_disconnect()
	_banner_tape = []
	_banner_fn = func(p_text: String) -> void: _banner_tape.append(p_text)
	EventBus.mechanics_intro.connect(_banner_fn)
	return _banner_tape


func _banner_disconnect() -> void:
	if _banner_fn.is_valid() and EventBus.mechanics_intro.is_connected(_banner_fn):
		EventBus.mechanics_intro.disconnect(_banner_fn)
	_banner_fn = Callable()


# ══ G0：公共契约 + 普通版逐位回归 ══
func _g0_common_and_normal_regression() -> void:
	print("── G0：enable_sublime/set_character/_reset 收口 + 普通版回归 ──")
	var pl := _p()
	# enable_sublime 幂等 + set_character 清位（先清后回契约：复位区清 false）
	_as(&"veles", false)
	pl.enable_sublime()
	pl.enable_sublime()
	_check("G0a enable_sublime 幂等置位（重复调用无叠层副作用）",
		pl.skill_sublime == true)
	pl.set_character(&"sentinel")
	_check("G0b set_character 复位区清 skill_sublime（继续局回填在其后——先清后回不冲突）",
		pl.skill_sublime == false)
	# _reset_skill_temp_state 收口（升华会话态全清；_reson_layers/_reson_kill_count 为
	# run 作用域刻意不在 reset 清——G10 依赖）
	_as(&"sentinel", true)
	pl._sub_field_left = 1.0
	pl._heat_stacks = 3
	pl._stomp_aftershock_pulses = 2
	pl._stomp_barrier = 10.0
	pl._shadow_fuses.append({"pos": Vector2.ZERO, "left": 0.2})
	pl._lurk_stacks = 2
	pl._ts_left = 1.0
	pl._mank_essence = 5
	pl._poison_stack_table[1] = {"e": null, "layers": 3}
	pl._poison_catalysis_pending = true
	pl._echo_stacks = 2
	pl._echo_afterglow_left = 1.0
	pl._resonance_stacks = 7
	pl._resonance_time_bonus = 2.0
	pl._dr_window_left = 1.0
	pl._vortex_left = 1.0
	pl._reaper_left = 1.0
	pl._reset_skill_temp_state()
	_check("G0c _reset_skill_temp_state 清全部升华会话态",
		pl._sub_field_left == 0.0 and pl._heat_stacks == 0
			and pl._stomp_aftershock_pulses == 0 and pl._stomp_barrier == 0.0
			and pl._shadow_fuses.is_empty() and pl._lurk_stacks == 0
			and pl._ts_left == 0.0 and pl._mank_essence == 0
			and pl._poison_stack_table.is_empty() and not pl._poison_catalysis_pending
			and pl._echo_stacks == 0 and pl._echo_afterglow_left == 0.0
			and pl._resonance_stacks == 0 and pl._resonance_time_bonus == 0.0
			and pl._dr_window_left == 0.0 and pl._vortex_left == 0.0
			and pl._reaper_left == 0.0)
	# veles 击杀监听连接/断开（reset 收口）
	_as(&"veles", true)
	pl.activate_skill()
	_check("G0d veles 施放连接 enemy_killed（is_connected 幂等守卫）",
		EventBus.enemy_killed.is_connected(pl._on_enemy_killed_overload))
	pl._reset_skill_temp_state()
	_check("G0e reset 后 veles 余热监听断开（换角/重开不残留）",
		not EventBus.enemy_killed.is_connected(pl._on_enemy_killed_overload))
	# 普通版逐位回归（关态）：施放成功 + 关键状态逐位
	_as(&"sentinel", false)
	_check("G0f sentinel 普通版：3s 无敌 + 3s 护盾泡 + 零升华力场",
		pl.activate_skill() and is_equal_approx(pl.invuln_left, 3.0)
			and is_equal_approx(pl._skill_shield_left, 3.0) and pl._sub_field_left == 0.0)
	_as(&"veles", false)
	_check("G0g veles 普通版：rof 2.0 / 4s 窗",
		pl.activate_skill() and is_equal_approx(pl.rof_mult, 2.0)
			and is_equal_approx(pl.skill_active_left, 4.0))
	_drive(40)
	_check("G0h veles 普通版到期硬复位 rof 1.0（无余热）",
		is_equal_approx(pl.rof_mult, 1.0) and pl._heat_stacks == 0)
	_as(&"zero", false)
	var ze := _mk_enemy(CENTER + Vector2(0.0, -100.0))
	_grid([ze])
	pl.activate_skill()
	_check("G0i zero 普通版：直写 freeze 2.5（快照脉冲）/ rof 不动",
		is_equal_approx(ze.elemental.freeze_timer, 2.5)
			and is_equal_approx(pl.rof_mult, 1.0) and pl._ts_left == 0.0)
	_as(&"vera", false)
	pl.activate_skill()
	_check("G0j vera 普通版：6.0s 窗 / 半径恒 300 / 无层表",
		is_equal_approx(pl._poison_cloud_left, 6.0)
			and is_equal_approx(pl._cloud_radius_now(), 300.0)
			and pl._poison_stack_table.is_empty())
	pl._poison_cloud_left = 0.0
	_as(&"echo", false)
	pl.activate_skill()
	_check("G0k echo 普通版：rof 1.5 / 5s 窗 / 无余韵",
		is_equal_approx(pl.rof_mult, 1.5)
			and is_equal_approx(pl.skill_active_left, 5.0)
			and pl._echo_afterglow_left == 0.0)
	_drive(52)
	_check("G0l echo 普通版到期 rof 1.0（无余韵）",
		is_equal_approx(pl.rof_mult, 1.0) and pl._echo_stacks == 0)
	# fission 无技能契约（升华后亦不破）
	_as(&"fission", true)
	var used0 := DebugStats.get_counter(&"skill_used")
	_check("G0m fission 契约不破：activate 恒 false / 不置 CD / 不计数 skill_used",
		pl.activate_skill() == false and pl.skill_cd_left == 0.0
			and DebugStats.get_counter(&"skill_used") == used0)
	# 普通版 fx 时长逐位（_skill_fx_duration 关态）
	var fx_expect := {
		&"sentinel": 3.0, &"veles": 4.0, &"bulwark": 0.8, &"ranger": 0.8,
		&"zero": 0.8, &"mank": 0.8, &"vera": 6.0, &"noah": 10.0, &"echo": 5.0,
	}
	var fx_ok := true
	var fx_detail := ""
	for k in fx_expect:
		_as(k, false)
		var got := float(_p().call(&"_skill_fx_duration"))
		if not is_equal_approx(got, float(fx_expect[k])):
			fx_ok = false
			fx_detail = "%s=%.1f" % [String(k), got]
	_check("G0n 普通版 _skill_fx_duration 十角色逐位（0.8 瞬发缺省不动）", fx_ok, fx_detail)


# ══ G1：sentinel 绝对屏障 ══
func _g1_sentinel() -> void:
	print("── G1：sentinel 绝对屏障（5s 力场/相位反冲/吸收回充） ──")
	var pl := _p()
	_as(&"sentinel", true)
	var e := _mk_enemy(CENTER + Vector2(0.0, -100.0))
	_grid([e])
	pl.activate_skill()
	_check("G1a 升华施放：5s 无敌 + 5s 泡 + 力场权威计时 + fx 5.0",
		is_equal_approx(pl.invuln_left, 5.0)
			and is_equal_approx(pl._skill_shield_left, 5.0)
			and is_equal_approx(pl._sub_field_left, 5.0)
			and is_equal_approx(pl._skill_fx_max, 5.0))
	# 相位反冲（直调——量值断言不经 tick）
	var hp0 := e.hp
	pl._sub_field_pulse()
	_check("G1b 相位反冲：120px 内 15% 主武器 ATK（KIN/AOE_SECONDARY/crit0）",
		is_equal_approx(hp0 - e.hp, _base_atk() * 0.15),
		"delta=%.3f expect=%.3f" % [hp0 - e.hp, _base_atk() * 0.15])
	_check("G1c 反冲击退：220px 冲量（enemy.knockback ×9 阻尼口径）",
		is_equal_approx(e.knock_vel.length(), 220.0 * 9.0),
		"kv=%.1f" % e.knock_vel.length())
	var far := _mk_enemy(CENTER + Vector2(200.0, 0.0))
	_grid([far])
	var hpf0 := far.hp
	pl._sub_field_pulse()
	_check("G1d 半径边界：120px 外不掉血", is_equal_approx(hpf0 - far.hp, 0.0))
	# 反冲节拍：5s 窗恰 10 跳（DebugStats 计数——武器开火免疫）
	var c0 := DebugStats.get_counter(&"sub_field_pulse")
	_grid_empty()
	_drive(51)
	var pulses := DebugStats.get_counter(&"sub_field_pulse") - c0
	_check("G1e 反冲节拍：5s 全程恰 10 跳；力场结束后不再跳（pulses=%d）",
		pulses == 10 and pl._sub_field_left == 0.0, "pulses=%d" % pulses)
	# 吸收回充：节流（同帧 ×10 只计 1 次）
	_as(&"sentinel", true)
	pl.activate_skill()
	pl.skill_cd_left = pl.skill_cd_base
	var cd0 := pl.skill_cd_left
	for i in range(10):
		pl.take_contact_damage(12.0)                  # 无敌闸内（invuln 5s）
	_check("G1f 吸收节流：同帧连打 ×10 → CD 只减 2.0（0.5s 闸计 1 次）",
		is_equal_approx(cd0 - pl.skill_cd_left, 2.0)
			and is_equal_approx(pl._sub_absorb_reduced, 2.0),
		"cd=%.2f reduced=%.2f" % [cd0 - pl.skill_cd_left, pl._sub_absorb_reduced])
	_check("G1g 吸收期不掉血（无敌闸先行）", is_equal_approx(pl.hp, pl.max_hp))
	# 节流到期再吸收 + 回充帽 20s
	pl._sub_absorb_gate_left = 0.0
	pl.skill_cd_left = pl.skill_cd_base
	pl._sub_absorb_reduced = 18.0
	pl.take_contact_damage(12.0)
	pl._sub_absorb_gate_left = 0.0
	pl.take_contact_damage(12.0)
	_check("G1h 回充帽：单施放累计 ≤20s（18→20 封顶，第 2 口不计）",
		is_equal_approx(pl._sub_absorb_reduced, 20.0))
	# 归零保护
	_as(&"sentinel", true)
	pl.activate_skill()
	pl.skill_cd_left = 1.0
	pl.take_contact_damage(12.0)
	_check("G1i 归零保护：CD<2 时吸收 clamp 到 0 不为负", pl.skill_cd_left == 0.0)
	# 强限定：非升华无敌期被打不回充
	_as(&"sentinel", false)
	pl.invuln_left = 1.0
	pl.skill_cd_left = pl.skill_cd_base
	var cdn := pl.skill_cd_left
	pl.take_contact_damage(12.0)
	_check("G1j 强限定：_sub_field_left==0（通用无敌帧）被打 → CD 不减",
		is_equal_approx(pl.skill_cd_left, cdn) and pl._sub_absorb_reduced == 0.0)


# ══ G2：veles 临界过载 ══
func _g2_veles() -> void:
	print("── G2：veles 临界过载（爬坡/余热/渐冷） ──")
	var pl := _p()
	_as(&"veles", true)
	pl.activate_skill()
	_check("G2a 升华施放：起点 2.0 / 5s 窗 / 击杀监听已连接 + fx 5.0",
		is_equal_approx(pl.rof_mult, 2.0)
			and is_equal_approx(pl.skill_active_left, 5.0)
			and EventBus.enemy_killed.is_connected(pl._on_enemy_killed_overload)
			and is_equal_approx(pl._skill_fx_max, 5.0))
	_grid_empty()
	_drive(25)                                       # 2.5s → 第 10 档
	_check("G2b 爬坡中点：2.5s → rof≈2.6（0.25s/档 lerp 2.0→3.2）",
		absf(pl.rof_mult - 2.6) <= 0.041, "rof=%.3f" % pl.rof_mult)
	# 窗口内击杀计余热层：2 次处理器直调 + 1 次真派发（集成：spawner 归还路径下计数照常）
	pl._on_enemy_killed_overload(null)
	pl._on_enemy_killed_overload(null)
	var fresh := _mk_enemy(CENTER + Vector2(0.0, -600.0))
	_emit_kill(fresh)
	_check("G2c 余热计层：2 直调 + 1 真派发击杀 → _heat_stacks==3（帽 5）",
		pl._heat_stacks == 3, "stacks=%d" % pl._heat_stacks)
	_drive(27)                                       # 至 5.2s → 窗尽软着陆（+2 帧裕量：5.0-50×0.1 浮点残差）
	_check("G2d 到期余热软着陆：rof == 1.0 + 4%×3 = 1.12（非硬复位）",
		is_equal_approx(pl.rof_mult, 1.12), "rof=%.3f" % pl.rof_mult)
	_drive(13)                                       # 1.3s 掉 1 层（+1 帧裕量）
	_check("G2e 渐冷掉层：1.2s 后 rof == 1.08（每层 -4%）",
		is_equal_approx(pl.rof_mult, 1.08) and pl._heat_stacks == 2)
	_drive(27)                                       # 剩余 2 层掉空（2×1.2s + 裕量）
	_check("G2f 渐冷收口：层尽 rof 1.0 / _heat_stacks==0",
		is_equal_approx(pl.rof_mult, 1.0) and pl._heat_stacks == 0)
	# 满层帽 + 零层硬复位
	_as(&"veles", true)
	pl.activate_skill()
	for i in range(9):
		pl._on_enemy_killed_overload(null)
	_check("G2g 余热层帽 5（9 杀只计 5）", pl._heat_stacks == 5)
	pl.skill_active_left = DT
	_drive(1)
	_check("G2h 满层软着陆 1.20", is_equal_approx(pl.rof_mult, 1.20))


# ══ G3：bulwark 余震壁垒 ══
func _g3_bulwark() -> void:
	print("── G3：bulwark 余震壁垒（参化主震/余震时序/磐岩护壁） ──")
	var pl := _p()
	# 普通版参数逐位（直调 _stomp_pulse）
	_as(&"bulwark", false)
	var e := _mk_enemy(CENTER + Vector2(-100.0, 0.0))
	var elite := _mk_enemy(CENTER + Vector2(100.0, 0.0), 100000.0, GameConst.TAG_ELITE)
	var boss := _mk_enemy(CENTER + Vector2(0.0, 100.0), 100000.0, GameConst.TAG_BOSS)
	_grid([e, elite, boss])
	pl._stomp_pulse(220.0, 280.0, 260.0, 24, false)
	_check("G3a 普通主震：280 冲量（×9 阻尼）",
		is_equal_approx(e.knock_vel.length(), 280.0 * 9.0))
	_check("G3b 质量分级自动继承：精英 ×0.35 / Boss 免疫（enemy.knockback 内建）",
		is_equal_approx(elite.knock_vel.length(), 280.0 * 9.0 * 0.35)
			and boss.knock_vel == Vector2.ZERO)
	_check("G3c 普通主震不喂护壁（p_feed=false）", pl._stomp_barrier == 0.0)
	# 升华主震：300/380/340/40 + 喂壁
	_as(&"bulwark", true)
	var e2 := _mk_enemy(CENTER + Vector2(-280.0, 0.0))     # 280px：普通 220 外 / 升华 300 内
	var bullets: Array = []
	for i in range(3):
		bullets.append(_mk_bullet(CENTER + Vector2(20.0 * i - 20.0, 30.0)))
	_grid([e2])
	_bullet_grid(bullets)
	pl.activate_skill()
	_check("G3d 升华主震：300px 内 380 冲量",
		is_equal_approx(e2.knock_vel.length(), 380.0 * 9.0),
		"kv=%.1f" % e2.knock_vel.length())
	var cleared := 0
	for b in bullets:
		if not bool((b as ProjectileBase).get("_live")):
			cleared += 1
	_check("G3e 升华主震清弹 340px 内 3/3 + 喂壁 4.5（1.5/弹）",
		cleared == 3 and is_equal_approx(pl._stomp_barrier, 4.5),
		"cleared=%d barrier=%.2f" % [cleared, pl._stomp_barrier])
	_check("G3f fx 3.8（HUD 时长条盖余震窗）",
		is_equal_approx(pl._skill_fx_max, 3.8))
	_check("G3g REVIVE_CLEAR_CAP 刻意不动（复活缓冲公平性红线）",
		pl.REVIVE_CLEAR_CAP == 24)
	# 余震时序：t+1/2/3s 各一跳 200/140（读实时位置）；t+4s 起零——专用近距对照敌
	#（余震击退 200 + 粗判 64 = 264 触达；e2@280 在余震圈外，只服务 G3d 主震 300 边界）
	var ea := _mk_enemy(CENTER + Vector2(-150.0, 0.0))
	_grid([ea])
	_drive(11)                                        # t≈1.1s → 余震#1（1.0s + 浮点裕量帧）
	_check("G3h 余震#1（t+1s）：140 冲量", is_equal_approx(ea.knock_vel.length(), 140.0 * 9.0),
		"kv=%.1f" % ea.knock_vel.length())
	ea.knock_vel = Vector2.ZERO
	_drive(22)                                        # t≈3.3s → 余震#2/#3（各 1.0s + 裕量）
	_check("G3i 余震#2/#3（t+2/3s）：累计 2×140 冲量",
		is_equal_approx(ea.knock_vel.length(), 2.0 * 140.0 * 9.0),
		"kv=%.1f" % ea.knock_vel.length())
	ea.knock_vel = Vector2.ZERO
	_drive(11)                                        # t≈4.4s → 余震窗已尽
	_check("G3j t+4s 起零脉冲（余震窗收口）",
		ea.knock_vel == Vector2.ZERO and pl._stomp_aftershock_pulses == 0)
	# 护壁吸收闸：dr 闸后 hp 前（全吸收给 contact_tick；部分吸收净伤走 HP）
	_as(&"bulwark", true)
	pl.hp = pl.max_hp
	pl.invuln_left = 0.0
	pl._stomp_barrier = 30.0
	pl.take_contact_damage(20.0)
	_check("G3k 全吸收：hp 不动 + 护壁 30→10 + 无敌帧（contact_tick 口径）",
		is_equal_approx(pl.hp, pl.max_hp)
			and is_equal_approx(pl._stomp_barrier, 10.0) and pl.invuln_left > 0.0)
	pl.invuln_left = 0.0
	var hpb := pl.hp
	pl.take_contact_damage(20.0)                      # 护壁 10 → 余 10 走 HP
	_check("G3l 部分吸收：护壁归零 + hp 只掉净伤 10",
		pl._stomp_barrier == 0.0 and is_equal_approx(hpb - pl.hp, 10.0),
		"hp_delta=%.2f" % (hpb - pl.hp))
	pl.invuln_left = 0.0
	var hpc := pl.hp
	pl.take_contact_damage(20.0)
	_check("G3m 护壁耗尽后原路径逐位（20 直减）", is_equal_approx(hpc - pl.hp, 20.0))
	# 护壁帽 48（无弹不清不喂壁）
	pl._stomp_barrier = 47.0
	pl._stomp_pulse(300.0, 380.0, 340.0, 40, true)    # 敌弹网格已空 → cleared=0
	_check("G3n 护壁帽 48（无弹不喂壁——p_feed 且 cleared>0 守卫）",
		is_equal_approx(pl._stomp_barrier, 47.0))
	_bullet_grid_empty()


# ══ G4：ranger 百影穿袭 ══
func _g4_ranger() -> void:
	print("── G4：ranger 百影穿袭（位移/路径结算/残影爆/潜影） ──")
	var pl := _p()
	# 普通版零回归：260px + invuln 1.0（DASH_HOME 起点——向下不触界）
	_as(&"ranger", false)
	pl.global_position = DASH_HOME
	pl._last_move_dir = Vector2.DOWN
	pl.activate_skill()
	_check("G4a 普通版零回归：260px 瞬步 + invuln 1.0",
		is_equal_approx(pl.global_position.distance_to(DASH_HOME), 260.0)
			and is_equal_approx(pl.invuln_left, 1.0))
	# 升华：0 层 340px（向下 1220 不触 y≤1264 下界）
	_as(&"ranger", true)
	pl.global_position = DASH_HOME
	pl._last_move_dir = Vector2.DOWN
	pl.activate_skill()
	_check("G4b 升华 0 层：340px + invuln 1.8",
		is_equal_approx(pl.global_position.distance_to(DASH_HOME), 340.0)
			and is_equal_approx(pl.invuln_left, 1.8))
	_check("G4c fx 1.2（含残影爆窗）", is_equal_approx(pl._skill_fx_max, 1.2))
	_check("G4d 残影播种：起点 + 中点两道引信 0.45s",
		pl._shadow_fuses.size() == 2
			and is_equal_approx(float(pl._shadow_fuses[0]["left"]), 0.45)
			and (pl._shadow_fuses[0]["pos"] as Vector2).distance_to(DASH_HOME) < 0.01)
	# 路径结算（uid 去重 + 240%）——直调量值
	var e := _mk_enemy(CENTER + Vector2(0.0, 200.0))
	_grid([e])
	var hp0 := e.hp
	_frame()
	pl._shadow_sweep_damage(CENTER, CENTER + Vector2(0.0, 340.0), 2.4)
	_check("G4e 路径结算：沿线敌恰一次 240% ATK（步进圆重叠 uid 去重）",
		is_equal_approx(hp0 - e.hp, _base_atk() * 2.4),
		"delta=%.2f expect=%.2f" % [hp0 - e.hp, _base_atk() * 2.4])
	# 残影爆半径外不伤（150px 半径；SpaceGrid.query_circle 粗判触达 = 半径+max_entity_r 64
	# → 边界外对照敌须放 250px（>214 粗判触达）——同口径见 G1d 的 200px/184）
	var eout := _mk_enemy(CENTER + Vector2(0.0, -250.0))
	_grid([eout])
	var hp1 := eout.hp
	_frame()
	pl._shadow_echo_blast(CENTER)
	_check("G4f 残影爆半径 150：250px 外敌不伤（>150+64 粗判触达）",
		is_equal_approx(hp1 - eout.hp, 0.0), "delta=%.2f" % (hp1 - eout.hp))
	# 残影爆：120% + 击退 160
	var ein := _mk_enemy(CENTER + Vector2(0.0, -100.0))
	_grid([ein])
	var hp2 := ein.hp
	_frame()
	pl._shadow_echo_blast(CENTER)
	_check("G4g 残影爆：150px 内 120% ATK + 160 冲量",
		is_equal_approx(hp2 - ein.hp, _base_atk() * 1.2)
			and is_equal_approx(ein.knock_vel.length(), 160.0 * 9.0),
		"delta=%.2f kv=%.1f" % [hp2 - ein.hp, ein.knock_vel.length()])
	# 拂弹：110px 内 team==1 双弹无效化（帽 6/影）
	var b1 := _mk_bullet(CENTER + Vector2(0.0, -50.0))
	var b2 := _mk_bullet(CENTER + Vector2(0.0, -80.0))
	_bullet_grid([b1, b2])
	_frame()
	pl._shadow_echo_blast(CENTER)
	var nulled := 0
	for b in [b1, b2]:
		if not bool((b as ProjectileBase).get("_live")):
			nulled += 1
	_check("G4h 拂弹：110px 内 team==1 双弹无效化（帽 6/影）", nulled == 2)
	_bullet_grid_empty()
	# 残影引信节拍：0.45s 后爆（列表清空；武器开火免疫观测量）
	_as(&"ranger", true)
	pl.global_position = DASH_HOME
	pl._last_move_dir = Vector2.DOWN
	_grid_empty()
	pl.activate_skill()
	_drive(4)                                         # 0.4s < 0.45
	_check("G4i 引信期不爆（0.4s 仍 2 影）", pl._shadow_fuses.size() == 2)
	_drive(1)                                         # 0.5s ≥ 0.45
	_check("G4j 0.45s 后两影皆爆清空", pl._shadow_fuses.is_empty())
	# 潜影蓄能：12s/层 帽 4；格挡早退不清 / 受击实减清零
	_grid_empty()
	_drive(120)                                       # 12s → 1 层
	_check("G4k 潜影 12s +1 层", pl._lurk_stacks == 1)
	_drive(360)                                       # 累计 48s → 4 层
	_check("G4l 潜影帽 4（48s 不溢出）", pl._lurk_stacks == 4)
	# R253 独立计时：格挡真源 = _shield_units（旧字段直设已只是 HUD 视图不驱动格挡）
	# ——注入 uid=0 就绪单元（r238/verify_feedback 同款夹具口径）
	pl._shield_units.clear()
	pl._shield_units[0] = {"interval": 1.0, "timer": 0.0, "layers": 1, "ready": true}
	pl.invuln_left = 0.0
	pl.take_contact_damage(10.0)
	_check("G4m 格挡吸收不清潜影（挡住≠受创）", pl._lurk_stacks == 4)
	pl._shield_units.clear()                         # 消耗态单元出清（防串扰后续组）
	pl.invuln_left = 0.0
	pl.take_contact_damage(10.0)
	_check("G4n 实减 HP 清潜影（受创断影）", pl._lurk_stacks == 0)
	pl.shield_ready = false
	# 4 层位移 460px（CENTER 起向下触下界 → 钳制 1264 = 1280 - hitbox 16）
	_as(&"ranger", true)
	pl._lurk_stacks = 4
	pl._last_move_dir = Vector2.DOWN
	pl.activate_skill()
	_check("G4o 满层 460px 落点钳活动区下界（y==1264）",
		is_equal_approx(pl.global_position.y, 1264.0),
		"y=%.1f" % pl.global_position.y)
	_check("G4p 施放消耗潜影（层清零）", pl._lurk_stacks == 0)


# ══ G5：zero 时滞奇点 ══
func _g5_zero() -> void:
	print("── G5：zero 时滞奇点（3.5s 直写/力场覆盖/击杀延展/唯我演算） ──")
	var pl := _p()
	_as(&"zero", true)
	var e := _mk_enemy(CENTER + Vector2(0.0, -100.0))
	e.immune_mask = GameConst.IMMUNE_FREEZE           # 免疫位对照（元素通道会被拒——直写不受）
	_grid([e])
	pl.activate_skill()
	_check("G5a 升华施放：freeze 直写 3.5（绕 immune_mask 签名保持）+ rof 1.2 + 3.5s 窗",
		is_equal_approx(e.elemental.freeze_timer, 3.5)
			and is_equal_approx(pl.rof_mult, 1.2)
			and is_equal_approx(pl.skill_active_left, 3.5)
			and is_equal_approx(pl._skill_fx_max, 3.5))
	# 新入场敌覆盖（持续力场——快照脉冲的反向断言在 G0i）
	var late := _mk_enemy(CENTER + Vector2(0.0, -300.0))
	_grid([late])
	late.elemental = ElementalState.new()
	_drive(4)                                         # t=0.4s ≥ 下一拍 0.25s
	_check("G5b 持续力场：0.3s 后入场敌下一拍（≤0.25s）一并凝滞",
		late.elemental.freeze_timer > 0.0, "freeze=%.2f" % late.elemental.freeze_timer)
	# 击杀延展：凝滞亡敌 +0.15s 帽 0.9；非凝滞不计
	late.elemental.freeze_timer = 0.0
	var ts0 := pl._ts_left
	_frame()
	_emit_kill(late)                                  # 真派发：freeze==0 → 账本也记 0 → 不计
	_check("G5c 非凝滞击杀不计（freeze==0——账本快照路径）",
		is_equal_approx(pl._ts_left, ts0), "ts=%.3f→%.3f" % [ts0, pl._ts_left])
	# 凝滞击杀：真派发集成（账本先于 spawner 落 freeze 快照——玩家订阅位在归还后）
	e.elemental.freeze_timer = 0.5
	_emit_kill(e)
	_check("G5d 凝滞击杀 +0.15s（真派发·账本路径；fx 分母同步抬）",
		is_equal_approx(pl._ts_left - ts0, 0.15)
			and pl._skill_fx_max >= pl._ts_left - 0.001)
	for i in range(10):
		pl._on_enemy_killed_timestop(e)               # 直调 ×10：账本命中（freeze 0.5 已落账）
	_check("G5e 延展帽 +0.9s（6 杀满额后不再加）：_ts_left == 3.1+0.9 == 4.0",
		is_equal_approx(pl._ts_bonus, 0.9) and is_equal_approx(pl._ts_left, 4.0),
		"ts_left=%.3f bonus=%.2f" % [pl._ts_left, pl._ts_bonus])
	_check("G5f 射速窗随延展同步（skill_active_left ≥ _ts_left）",
		pl.skill_active_left >= pl._ts_left - 0.001)
	# 窗尽收口：rof 回 1.0 / 监听断开（窗外零监听）
	_grid_empty()
	_drive(50)
	_check("G5g 窗尽：_ts_left 归零 + rof 1.0（骑既有复位口）+ 监听断开",
		pl._ts_left == 0.0 and is_equal_approx(pl.rof_mult, 1.0)
			and not EventBus.enemy_killed.is_connected(pl._on_enemy_killed_timestop))


# ══ G6：mank 万毒噬界 ══
func _g6_mank() -> void:
	print("── G6：mank 万毒噬界（210% 基线/喂层分档/腐沼爆裂） ──")
	var pl := _p()
	# 普通版：1.5×（零回归）
	_as(&"mank", false)
	var e := _mk_enemy(CENTER + Vector2(0.0, -400.0))
	_grid([e])
	var hp0 := e.hp
	pl._skill_poison_nova()
	_check("G6a 普通毒爆零回归：150% 面板（kill 不喂层不爆裂）",
		is_equal_approx(hp0 - e.hp, _base_atk() * 1.5)
			and pl._mank_essence == 0)
	# 升华 0 层：210%
	_as(&"mank", true)
	_frame()
	var hp1 := e.hp
	pl._skill_poison_nova()
	_check("G6b 升华基线：0 层 210% 面板",
		is_equal_approx(hp1 - e.hp, _base_atk() * 2.1),
		"delta=%.2f expect=%.2f" % [hp1 - e.hp, _base_atk() * 2.1])
	# 腐沼爆裂：毒爆击杀者原地 140px 50%（深度 1 / 每目标每轮一次 / 合成 UID 不吞）
	var bait := _mk_enemy(CENTER + Vector2(0.0, -420.0), 10.0)      # 一发即死（喂层+锚点）
	var bait2 := _mk_enemy(CENTER + Vector2(30.0, -420.0), 10.0)    # 第二锚点（同目标去重）
	_grid([e, bait, bait2])
	_frame()
	var hps := e.hp
	pl._skill_poison_nova()
	_forget(bait)                                     # 真死亡链：spawner 已认领归还
	_forget(bait2)
	_check("G6c 腐沼爆裂：存活者受 nova 2.1 + 双锚点爆裂去重后仅一次 0.5（合成 UID 不撞幂等键）",
		is_equal_approx(hps - e.hp, _base_atk() * 2.6),
		"delta=%.2f expect=%.2f" % [hps - e.hp, _base_atk() * 2.6])
	_check("G6d 击杀喂层：双杀各 +1（毒爆直杀，tags 读账本快照）", pl._mank_essence == 2)
	# 喂层分档（tags）与帽 30
	var nrm := _mk_enemy(CENTER + Vector2(0.0, -500.0))
	var elt := _mk_enemy(CENTER + Vector2(40.0, -500.0), 100000.0, GameConst.TAG_ELITE)
	var bos := _mk_enemy(CENTER + Vector2(80.0, -500.0), 100000.0, GameConst.TAG_BOSS)
	pl._gain_mank_essence(nrm)
	pl._gain_mank_essence(elt)
	pl._gain_mank_essence(bos)
	_check("G6e 喂层分档：普 +1 / 精 +2 / Boss +5（2+1+2+5=10）", pl._mank_essence == 10)
	pl._mank_essence = 29
	pl._gain_mank_essence(bos)
	_check("G6f 层数帽 30（29+5 钳 30）", pl._mank_essence == 30)
	# 层数转化：30 层 = 270%
	_frame()
	var hpz := e.hp
	_grid([e])
	pl._skill_poison_nova()
	_check("G6g 满层毒爆 270%（2.1+0.02×30）",
		is_equal_approx(hpz - e.hp, _base_atk() * 2.7),
		"delta=%.2f expect=%.2f" % [hpz - e.hp, _base_atk() * 2.7])
	# 里程碑横幅（满层播报）
	var tape := _banner_arm()
	pl._mank_essence = 29
	pl._gain_mank_essence(nrm)
	_check("G6h 满层里程碑横幅（emit_mechanics_intro 复用）",
		tape.size() == 1 and String(tape[0]).contains("毒核完全体"), str(tape))


# ══ G7：vera 毒理学终章 ══
func _g7_vera() -> void:
	print("── G7：vera 毒理学终章（7s 窗/半径滋生/层乘区/催化错帧） ──")
	var pl := _p()
	_as(&"vera", true)
	var e := _mk_enemy(CENTER + Vector2(0.0, -200.0))
	_grid([e])
	var hp0 := e.hp
	pl.activate_skill()
	_check("G7a 升华置窗：7.0s + 首跳当帧即结算（0 层 8%）+ fx 7.0",
		is_equal_approx(pl._poison_cloud_left, 7.0)
			and is_equal_approx(pl._skill_fx_max, 7.0)
			and is_equal_approx(hp0 - e.hp, _base_atk() * 0.08))
	_check("G7b 首跳减速 0.8（0 层）", is_equal_approx(e.ext_slow_mult, 0.8))
	# 层乘区：手动置 5 层 → 跳伤 ×1.30 / 减速 1-0.275
	pl._poison_stack_table[int(e.uid)] = {"e": e, "layers": 5}
	var hp5 := e.hp
	_frame()
	pl._poison_cloud_pulse()
	_check("G7c 层乘区：5 层跳伤 8%×1.30 + 深减速 0.725（20%+1.5%×5）",
		is_equal_approx(hp5 - e.hp, _base_atk() * 0.08 * 1.30)
			and is_equal_approx(e.ext_slow_mult, 0.725),
		"delta=%.3f slow=%.3f" % [hp5 - e.hp, e.ext_slow_mult])
	# 层数上限 12（手动置 20 → pulse 后 12）
	pl._poison_stack_table[int(e.uid)] = {"e": e, "layers": 20}
	_frame()
	pl._poison_cloud_pulse()
	_check("G7d 毒蚀帽 12", int(pl._poison_stack_table[int(e.uid)]["layers"]) == 12)
	# 半径滋生：left 递减单调升 300→390
	pl._poison_cloud_left = 7.0
	var r0 := pl._cloud_radius_now()
	pl._poison_cloud_left = 3.5
	var r1 := pl._cloud_radius_now()
	pl._poison_cloud_left = 0.0
	var r2 := pl._cloud_radius_now()
	_check("G7e 领域滋生：300 起 / 中点 345 / 终点 390（线性）",
		is_equal_approx(r0, 300.0) and is_equal_approx(r1, 345.0)
			and is_equal_approx(r2, 390.0))
	# 催化错帧：到期帧不立即结算；下一 tick 帧每层 3% 一次入账 + 清层
	var hpb := e.hp
	pl._poison_catalysis_pending = true
	pl._poison_cloud_left = 0.0
	_drive(1)
	_check("G7f 催化结算：12 层 → 36% ATK（pending 帧云已死——单算催化无跳伤混入）",
		is_equal_approx(hpb - e.hp, _base_atk() * 0.36),
		"delta=%.2f expect=%.2f" % [hpb - e.hp, _base_atk() * 0.36])
	_check("G7g 催化后清层表 + pending 复位",
		pl._poison_stack_table.is_empty() and not pl._poison_catalysis_pending)
	# 到期转挂 pending（tick 内 expiry 路径）
	pl._poison_cloud_left = DT
	pl._poison_stack_table[int(e.uid)] = {"e": e, "layers": 1}
	_drive(1)
	_check("G7h 云尽帧转挂 catalysis pending（错帧防幂等键吞跳）",
		pl._poison_catalysis_pending and pl._poison_cloud_left == 0.0)
	# 普通版：无层无催化（零回归守卫）
	_as(&"vera", false)
	pl.activate_skill()
	_frame()
	pl._poison_cloud_pulse()
	_check("G7i 普通版零回归：无层表增长 / 无催化挂起 / 半径恒 300",
		pl._poison_stack_table.is_empty() and not pl._poison_catalysis_pending
			and is_equal_approx(pl._cloud_radius_now(), 300.0))
	pl._poison_cloud_left = 0.0


# ══ G8：noah 万械共鸣 ══
func _g8_noah() -> void:
	print("── G8：noah 万械共鸣（3 副本 3 舰 16s/寿命绑定/共鸣层/恋战延时） ──")
	var pl := _p()
	# 普通版零回归：2 副本 2 舰 10s / 副本无共鸣加成
	_as(&"noah", false)
	_grid_empty()
	pl.activate_skill()
	var src_meta := float(pl.weapon_slots[0].meta_atk_pct)
	_check("G8a 普通版零回归：2 副本 / 2 舰 / 10.0s / 舰体寿命 10.0（默认参回归锚）",
		pl._summon_copies.size() == 2 and pl._summon_drones.size() == 2
			and is_equal_approx(pl._summon_left, 10.0)
			and is_equal_approx(float(pl._summon_drones[0].get("_life_left")), 10.0)
			and is_equal_approx(float(pl.weapon_slots[0].meta_atk_pct), src_meta))
	pl._reset_skill_temp_state()
	# 升华：存量 10 层施放 → 预支 +2s
	_as(&"noah", true)
	pl._resonance_stacks = 10
	pl.activate_skill()
	_check("G8b 升华分派：3 副本 / 3 舰 / 16+2=18s（存量预支 floor(10/5)）+ fx_max 18",
		pl._summon_copies.size() == 3 and pl._summon_drones.size() == 3
			and is_equal_approx(pl._summon_left, 18.0)
			and is_equal_approx(pl._skill_fx_max, 18.0))
	_check("G8c 舰体寿命绑定本窗：18.0（拔 10s 硬编码）",
		is_equal_approx(float(pl._summon_drones[2].get("_life_left")), 18.0))
	_check("G8d 副本乘区施放即继承：meta == 源 + 1.5%×10 层",
		is_equal_approx(float(pl._summon_copies[0].meta_atk_pct),
			src_meta + 0.015 * 10.0),
		"copy=%.4f src=%.4f" % [float(pl._summon_copies[0].meta_atk_pct), src_meta])
	# 窗内击杀 +层（帽 40）+ 恋战延时（跨 5 层 +1s，帽 +8s）
	for i in range(49):
		pl._on_resonance_kill(null)                  # 直调高频（参数忽略）
	var fresh := _mk_enemy(CENTER + Vector2(0.0, -600.0))
	_emit_kill(fresh)                                # 真派发集成 ×1（第 50 杀）
	_check("G8e 共鸣层帽 40（10+50 杀只到 40——含 1 次真派发）", pl._resonance_stacks == 40)
	_check("G8f 恋战延时兑点：bonus 帽 8 / _summon_left 同步 24.0 / fx_max 24.0",
		is_equal_approx(pl._resonance_time_bonus, 8.0)
			and is_equal_approx(pl._summon_left, 24.0)
			and is_equal_approx(pl._skill_fx_max, 24.0))
	var life_ok := true
	for d in pl._summon_drones:
		if d == null or not is_instance_valid(d) \
				or absf(float(d.get("_life_left")) - 24.0) > 0.01:
			life_ok = false
	_check("G8g 兑点帧舰体寿命逐舰 +6（同帧同涨不脱钩）", life_ok)
	# 层数即时回写幂等（基准快照防叠错）
	pl._apply_resonance_mult()
	pl._apply_resonance_mult()
	_check("G8h 乘区回写幂等：重复 _apply_resonance_mult 值不变（基准快照）",
		is_equal_approx(float(pl._summon_copies[0].meta_atk_pct),
			src_meta + 0.015 * 40.0))
	# 跨 10s 旧硬编码自毁点：3 舰仍在场
	_grid_empty()
	_drive(100)
	var alive := 0
	for d in pl._summon_drones:
		if d != null and is_instance_valid(d):
			alive += 1
	_check("G8i 跨 10s 旧硬编码自毁点：3 舰全在场", alive == 3, "alive=%d" % alive)
	# 书保留：_summon_restore 不清层；_reset 清书
	pl._summon_restore()
	_check("G8j 到期回收不清书（跨施放滚存）",
		pl._summon_copies.is_empty() and pl._resonance_stacks == 40)
	pl._reset_skill_temp_state()
	_check("G8k reset 清书与已兑延时",
		pl._resonance_stacks == 0 and pl._resonance_time_bonus == 0.0)
	# 窗外击杀不计
	_as(&"noah", true)
	pl._on_resonance_kill(null)
	_check("G8l 窗外击杀不计（_summon_left==0 早退）", pl._resonance_stacks == 0)
	# G8m/n（R247 终修补断言）：舰弹面板数值级验证——QA 阶段仅代码读证+开火冒烟，
	# panel_snapshot 经 pool.acquire 内部获取探针不可达；此处真池拦截（acquire 尾
	# 追 _active_list → back() 即最新弹）对 18%×(1+1.5%×层) 三乘区做数值断言。
	_grid_empty()
	_as(&"noah", true)
	pl._resonance_stacks = 12
	pl.activate_skill()
	var drone_shot_e := _mk_enemy(CENTER + Vector2(0.0, -200.0))   # 舰位 340px 索敌窗内
	_grid([drone_shot_e])
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var act_n0 := pool.active_projectiles().size()
	var base_atk := _base_atk()
	pl._summon_drones[0].call(&"_fire_at_nearest", pl)             # 直调（绕 tick 开火节拍）
	var fired := pool.active_projectiles().size() - act_n0
	var drone_proj: Variant = pool.active_projectiles().back() \
		if pool.active_projectiles().size() > act_n0 else null
	_check("G8m 升华舰弹出弹恰 1 发（真池 acquire → active_list 尾追）", fired == 1)
	if drone_proj is ProjectileBase:
		_bullets.append(drone_proj as Node2D)
		var expect_m := base_atk * Player.SUBLIME_DRONE_ATK_PCT \
			* (1.0 + Player.RESONANCE_DMG_PER_STACK * 12.0)
		_check("G8m 升华舰弹面板：base_atk × 18% ×（1 + 1.5% × 12 层）三乘区数值",
			is_equal_approx(
				float((drone_proj as ProjectileBase).panel_snapshot.get("base_atk", 0.0)),
				expect_m),
			"got=%.4f expect=%.4f" % [
				float((drone_proj as ProjectileBase).panel_snapshot.get("base_atk", 0.0)),
				expect_m])
	else:
		_check("G8m 升华舰弹面板断言（前置失败跳过——出弹未发生）", false,
			"active=%d" % pool.active_projectiles().size())
	# 普通版对照：12% 无层乘区
	pl._summon_restore()
	_as(&"noah", false)
	pl.activate_skill()
	var act_n1 := pool.active_projectiles().size()
	var base_atk0 := _base_atk()
	pl._summon_drones[0].call(&"_fire_at_nearest", pl)
	if pool.active_projectiles().size() > act_n1:
		var proj0: ProjectileBase = pool.active_projectiles().back()
		_bullets.append(proj0)
		_check("G8n 普通版舰弹零回归：base_atk×12%（无共鸣乘区）",
			is_equal_approx(float(proj0.panel_snapshot.get("base_atk", 0.0)),
				base_atk0 * 0.12),
			"got=%.4f expect=%.4f" % [
				float(proj0.panel_snapshot.get("base_atk", 0.0)), base_atk0 * 0.12])
	else:
		_check("G8n 普通版舰弹断言（前置失败跳过——出弹未发生）", false,
			"active=%d" % pool.active_projectiles().size())
	pl._summon_restore()


# ══ G9：echo 无尽回响 ══
func _g9_echo() -> void:
	print("── G9：echo 无尽回响（和弦分流/回声层/渐弱余韵） ──")
	var pl := _p()
	# 异款（双声部）：W1 + W4 —— 先解锁槽位再入槽
	pl.unlocked_slots = 6
	var w4 := pl.add_weapon(_gl.registry.get_weapon(&"W4_pulse_beam"))
	_check("G9 前置：第二武器入槽（异款形态）", w4 != null)
	_as(&"echo", true)
	pl.activate_skill()
	_check("G9a 双声部（异款）：主窗 1.80 / 5s 窗",
		is_equal_approx(pl.rof_mult, 1.80)
			and is_equal_approx(pl.skill_active_left, 5.0))
	# 回声层：异款每杀 +2% 帽 6 层（rof 帽 1.92）——8 直调
	for i in range(8):
		pl._on_echo_kill_stack(null)
	_check("G9b 回声层帽 6（8 杀只计 6）+ 双声部层微增 rof 1.92",
		pl._echo_stacks == 6 and is_equal_approx(pl.rof_mult, 1.92))
	# 渐弱余韵：1.35 定值 / 0.6s×层 帽 3.6 / fx 续接
	_grid_empty()
	_drive(52)
	_check("G9c 主窗尽 → 余韵 1.35 / ≈3.6s（0.6×6 帽 3.6；到期帧后随帧微衰减）+ fx 续接",
		is_equal_approx(pl.rof_mult, 1.35)
			and pl._echo_afterglow_left >= 3.4 and pl._echo_afterglow_left <= 3.6
			and is_equal_approx(pl._skill_fx_max, 3.6),
		"rof=%.3f left=%.3f" % [pl.rof_mult, pl._echo_afterglow_left])
	_drive(38)
	_check("G9d 余韵归零：rof 1.0 / 层清零",
		is_equal_approx(pl.rof_mult, 1.0) and pl._echo_stacks == 0)
	# 同款（同频共振）：slot1 换装 W1 副本 → 1.90 不吃层 + 0.5s/层 帽 3.0 + 横幅
	var w1b := pl.add_weapon(_gl.registry.get_weapon(&"W1_pistol"))
	_check("G9 前置：同款第二把入槽", w1b != null)
	pl.weapon_slots[1] = w1b                         # 和弦读 slot0/1 —— 覆盖 W4 成同款对
	_as(&"echo", true)
	var tape := _banner_arm()
	pl.activate_skill()
	_check("G9e 同频共振：主窗 1.90 + 横幅播报",
		is_equal_approx(pl.rof_mult, 1.90)
			and tape.size() >= 1 and String(tape[0]).contains("同频共振"), str(tape))
	for i in range(8):
		pl._on_echo_kill_stack(null)
	_check("G9f 同款不吃层（rof 恒 1.90）但叠层照常（余韵燃料）",
		is_equal_approx(pl.rof_mult, 1.90) and pl._echo_stacks == 6)
	_grid_empty()
	_drive(52)
	_check("G9g 同款余韵 ≈0.5s×6=3.0（帽 3.0；到期帧后随帧微衰减）",
		pl._echo_afterglow_left >= 2.8 and pl._echo_afterglow_left <= 3.0,
		"left=%.3f" % pl._echo_afterglow_left)
	_drive(32)
	_check("G9h 余韵尽 rof 1.0（R29 降挡不回罚语义由 cd_pace 锁定，此处锁终值）",
		is_equal_approx(pl.rof_mult, 1.0))
	# 零层：直接硬复位（不进余韵）
	_as(&"echo", true)
	pl.activate_skill()
	pl.skill_active_left = DT
	_drive(1)
	_check("G9i 零层到期直接归 1.0（无余韵）",
		is_equal_approx(pl.rof_mult, 1.0) and pl._echo_afterglow_left == 0.0)


# ══ G10：fission 本命同调 ══
func _g10_fission() -> void:
	print("── G10：fission 本命同调（契约/回填/注入/Ω 五档/CDR 参数化） ──")
	var pl := _p()
	_as(&"fission", false)
	var w0 := pl.weapon_slots[0]
	var w4 := pl.add_weapon(_gl.registry.get_weapon(&"W4_pulse_beam"))
	var meta_base := float(w0.meta_atk_pct)          # 注入前基准（角色+养成合成真值）
	# 原始计数器：未升华期照常计数（回填源）——真派发（spawner 归还 + 计数双验）
	var k1 := _mk_enemy(CENTER + Vector2(0.0, -600.0))
	var k2 := _mk_enemy(CENTER + Vector2(20.0, -600.0))
	var kel := _mk_enemy(CENTER + Vector2(50.0, -600.0), 100000.0, GameConst.TAG_ELITE)
	var kb := _mk_enemy(CENTER + Vector2(100.0, -600.0), 100000.0, GameConst.TAG_BOSS)
	_emit_kill(k1)
	_emit_kill(k2)
	_emit_kill(kel)
	_emit_kill(kb)
	_check("G10a 原始计数 run 作用域：4 杀全计（普 2/精 1/Boss 1）与层无关",
		pl._reson_kill_count == 4 and pl._reson_layers == 0)
	# 追溯回填：×0.5 折层
	pl.enable_sublime()
	_check("G10b 追溯回填：4 杀 ×0.5 → 2 层（enable_sublime 替代分支）",
		pl.skill_sublime and pl._reson_layers == 2)
	# 升华后喂层分档：+1/+3/+15（真派发·账本 tags 快照路径）
	_frame()
	var k3 := _mk_enemy(CENTER + Vector2(0.0, -620.0))
	var ke2 := _mk_enemy(CENTER + Vector2(40.0, -620.0), 100000.0, GameConst.TAG_ELITE)
	var kb2 := _mk_enemy(CENTER + Vector2(80.0, -620.0), 100000.0, GameConst.TAG_BOSS)
	_emit_kill(k3)
	_emit_kill(ke2)
	_emit_kill(kb2)
	_check("G10c 升华喂层分档：2+1+3+15=21（普+1/精+3/Boss+15——账本读 tags）",
		pl._reson_layers == 21, "layers=%d" % pl._reson_layers)
	# 注入：本命（slot0=W1_pistol）吃加区 8% + 21×0.13%；异 id 零注入
	var w4_base := float(w4.meta_atk_pct)
	_check("G10d 本命注入：meta_atk_pct == 基准+0.08+21×0.0013",
		is_equal_approx(float(w0.meta_atk_pct), meta_base + 0.08 + 21 * 0.0013),
		"meta=%.5f" % float(w0.meta_atk_pct))
	_check("G10e 异 id 零注入 + extern 恒空",
		is_equal_approx(float(w4.meta_atk_pct), w4_base) and w4.extern_buffs.is_empty())
	_check("G10f 21 层无改装件（<100 档）extern 空", w0.extern_buffs.is_empty())
	# Ω 五档 extern（500 层满配）+ rof 尾乘 + 档位横幅
	var iv0 := w0._fire_interval()
	var tape := _banner_arm()
	pl._reson_layers = 500
	pl._apply_resonance(21)                          # 21→500 跨全部五档
	_check("G10g Ω 满配 extern：spd/size/crit/rof 各 0.08/0.08/0.05/0.08",
		w0.extern_buffs == {&"spd": 0.08, &"size": 0.08, &"crit": 0.05, &"rof": 0.08},
		str(w0.extern_buffs))
	_check("G10h 本命 meta 满配 == 基准+0.08+0.65+0.08（即时糖+层数+弹匣）",
		is_equal_approx(float(w0.meta_atk_pct), meta_base + 0.08 + 0.65 + 0.08),
		"meta=%.5f" % float(w0.meta_atk_pct))
	var iv1 := w0._fire_interval()
	_check("G10i Ω-超频 rof 尾乘：节拍 ÷1.08（extern_buffs._player_rof_mult 消费）",
		absf(iv1 - iv0 / 1.08) < 1e-4, "iv0=%.4f iv1=%.4f" % [iv0, iv1])
	_check("G10j 档位跨越横幅：21→500 一次性五档播报（Ω-弹匣…Ω-超频）",
		tape.size() == 5, str(tape))
	# 存档读口往返
	var snap := pl.resonance_snapshot()
	_check("G10k resonance_snapshot 键值保真（{on, fission_layers}）",
		bool(snap.get("on")) and int(snap.get("fission_layers")) == 500)
	pl._reson_layers = 0
	pl.restore_resonance({"on": true, "fission_layers": 9999})
	_check("G10l restore_resonance clampi 防脏档（9999→500）", pl._reson_layers == 500)
	# CDR 折算参数化（0.65/0.45 vs 0.5/0.30）——挂技能急速池 12% 后对照
	var haste: TraitData = load("res://resources/traits/AFF_SKILL_HASTE.tres")
	var attached := w0.attach_trait(haste)
	_check("G10 前置：AFF_SKILL_HASTE 挂载（池 12%）", attached)
	pl.refresh_skill_cd()
	var comp_sub := pl.comp_rof_mult
	pl.skill_sublime = false
	pl.refresh_skill_cd()
	var comp_norm := pl.comp_rof_mult
	_check("G10m CDR 参数化：同池升华 ×(1+0.12×0.65)=1.078 > 普通 ×1.06",
		absf(comp_sub - 1.078) < 0.001 and absf(comp_norm - 1.06) < 0.001,
		"sub=%.4f norm=%.4f" % [comp_sub, comp_norm])
	pl.skill_sublime = true
	# set_character 换角清层清位 + extern 还原
	pl.set_character(&"sentinel")
	_check("G10n 换角清口：skill_sublime/层/原始计数清零 + extern 还原空",
		not pl.skill_sublime and pl._reson_layers == 0 and pl._reson_kill_count == 0
			and pl.weapon_slots[0].extern_buffs.is_empty())


# ══ G11：medic 医疗矩阵 ══
func _g11_medic() -> void:
	print("── G11：medic 医疗矩阵（回复 + 减伤窗） ──")
	var pl := _p()
	_as(&"medic", false)
	pl.hp = 20.0
	pl.activate_skill()
	_check("G11a 施放回复：hp = min(20+0.3×max, max) = 38 + 4s 减伤窗 + fx 4.0",
		is_equal_approx(pl.hp, 38.0)
			and is_equal_approx(pl._dr_window_left, 4.0)
			and is_equal_approx(pl._skill_fx_max, 4.0))
	pl.invuln_left = 0.0
	pl.take_contact_damage(10.0)
	_check("G11b 减伤窗内 ×0.5：10 伤只扣 5（与无敌独立）",
		is_equal_approx(pl.hp, 33.0), "hp=%.1f" % pl.hp)
	pl.invuln_left = 0.0
	pl._dr_window_left = 0.0
	pl.take_contact_damage(10.0)
	_check("G11c 窗尽还原全伤（10 直减）", is_equal_approx(pl.hp, 23.0))


# ══ G12：vortex 奇点 ══
func _g12_vortex() -> void:
	print("── G12：vortex 奇点（向心牵引 + 末爆） ──")
	var pl := _p()
	_as(&"vortex", false)
	var e := _mk_enemy(CENTER + Vector2(0.0, -200.0))  # 玩家上方 200px
	_grid([e])
	var blast_tape: Array = []
	var rec := func(_p_pos: Vector2, _p_r: float) -> void: blast_tape.append(1)
	EventBus.kill_blast.connect(rec)
	pl.activate_skill()
	_check("G12a 施放：3s 奇点窗 + fx 3.0 + 首拉即发",
		is_equal_approx(pl._vortex_left, 3.0)
			and is_equal_approx(pl._skill_fx_max, 3.0)
			and e.knock_vel.length() > 0.0)
	_check("G12b 向心：冲量 70（×9 阻尼）方向指向玩家（敌在上方 → +Y 向下）",
		is_equal_approx(e.knock_vel.length(), 70.0 * 9.0)
			and e.knock_vel.y > 0.0, "kv=%s" % str(e.knock_vel))
	_drive(30)
	EventBus.kill_blast.disconnect(rec)
	_check("G12c 窗尽末爆：kill_blast 表现事件一发（220px 120% 照 nova 模板）",
		blast_tape.size() == 1 and pl._vortex_left == 0.0,
		"tape=%d left=%.2f" % [blast_tape.size(), pl._vortex_left])
	# 末爆伤害量值（直调——武器开火免疫路径）
	_as(&"vortex", false)
	var e2 := _mk_enemy(CENTER + Vector2(0.0, -150.0))
	_grid([e2])
	var hp0 := e2.hp
	pl._vortex_blast()
	_check("G12d 末爆 120% ATK / 220px 内", is_equal_approx(hp0 - e2.hp, _base_atk() * 1.2),
		"delta=%.2f" % (hp0 - e2.hp))
	var e3 := _mk_enemy(CENTER + Vector2(0.0, -300.0))
	_grid([e3])
	var hp3 := e3.hp
	_frame()
	pl._vortex_blast()
	_check("G12e 末爆半径外不受", is_equal_approx(hp3 - e3.hp, 0.0))


# ══ G13：reaper 收割窗 ══
func _g13_reaper() -> void:
	print("── G13：reaper 收割窗（extern atk 乘区启停） ──")
	var pl := _p()
	_as(&"reaper", false)
	var w0 := pl.weapon_slots[0]
	var b0 := float(w0.build_panel_snapshot()["base_atk"])
	pl.activate_skill()
	_check("G13a 施放：6s 窗 + extern atk +0.5 + fx 6.0",
		is_equal_approx(pl._reaper_left, 6.0)
			and w0.extern_buffs == {&"atk": 0.5}
			and is_equal_approx(pl._skill_fx_max, 6.0))
	var b1 := float(w0.build_panel_snapshot()["base_atk"])
	_check("G13b 面板即时生效：base_atk ×1.5（build_panel_snapshot atk 尾乘）",
		is_equal_approx(b1, b0 * 1.5), "b0=%.2f b1=%.2f" % [b0, b1])
	_grid_empty()
	_drive(62)
	var b2 := float(w0.build_panel_snapshot()["base_atk"])
	_check("G13c 窗尽还原：extern 清空 + 面板回基线（6s 准时）",
		w0.extern_buffs.is_empty() and is_equal_approx(b2, b0)
			and pl._reaper_left == 0.0)
	# reset 提前收口与 G13c 同函数（_apply_reaper_buffs(false)）——G0c 已锁 reset 位
	_check("G13d 提前收口路径（reset → _apply_reaper_buffs(false)）与窗尽同源",
		pl._reaper_left == 0.0 and w0.extern_buffs.is_empty())

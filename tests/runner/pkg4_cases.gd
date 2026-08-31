# tests/runner/pkg4_cases.gd
# 包 4 自测用例体（由 test_pkg4.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖任务书必测要点 1~10（见 test_pkg4.gd 头注释）。
# 确定性：GameLoop 完整 Boot（DataRegistry 66 资源 + 池预热）→ 手动驱动 _physics_process(raw)；
# 固定 RNG 种子；爆虫/伴随怪用例用内存 EnemyData/WaveTableData（真源数值注释标注）。
extends RefCounted

const ENEMY_SCENE := "res://scenes/combat/enemies/enemy.tscn"
const DT := 1.0 / 120.0                          # 120Hz 物理帧
const HIT_STOP_TOL := 0.002                      # 顿帧时长断言容差 s（±1 帧 @120Hz ≈ 8.3ms 内）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null                         # 共享 GameLoop（Boot 一次）
var _card_chosen_log: Array = []                 # card_chosen 事件记录 [[id, kind], …]


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_ensure_autoloads()
	_boot_game_loop()
	_test_state_machine()                         # 要点 1
	_test_hit_stop_and_dual_channel()             # 要点 2 / 3
	_test_trauma_levels_and_decay()               # 要点 4
	_test_frame_order()                           # 要点 5
	_test_hud_binding()                           # 要点 6
	_test_popup_pool()                            # 要点 7
	_test_card_flow()                             # 要点 8
	_teardown_game_loop()
	_test_volatile_bug()                          # 要点 9（脱离 GameLoop 的独立环境）
	_test_boss_escort()                           # 要点 10
	# 汇总
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 环境引导 ──────────────────────────────────────────────────────
func _ensure_autoloads() -> void:
	_check("autoload 就绪（EventBus/GameConfig/DebugStats）",
		EventBus != null and GameConfig != null and DebugStats != null)
	_check("GameConfig 非致命（balance 加载）", not GameConfig.is_fatal() and GameConfig.balance != null)


func _boot_game_loop() -> void:
	# GameLoop 完整 Boot（架构 §六.2 序列）：fatal 检查 → registry → 池×5 → 子系统 → MENU
	_gl = GameLoop.new()
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_check("Boot：完成且进入 MENU", _gl.boot_ready and _gl.state == GameConst.GameStatus.MENU)
	_check("Boot：致命清单为空", _gl.boot_fatal.is_empty())
	_check("Boot：子系统组装齐全（player/wave/spawner/elemental/gamefeel/hud/popup/cards）",
		_gl.player != null and _gl.wave_director != null and _gl.spawner != null
		and _gl.elemental != null and _gl.game_feel != null and _gl.hud != null
		and _gl.popup_manager != null and _gl.card_generator != null and _gl.card_select_ui != null)
	_check("Boot：双网格持有（§1.3-6）", _gl.enemy_grid != null and _gl.enemy_bullet_grid != null)
	# v0.6.0 授权更新：池数量断言 ×6 → ×7（金币池挂载，A4 §7；沿用 xp 池断言的授权更新模式）
	_check("Boot：池×7 就绪（含 xp/gold——经验链路 + v0.6.0 金币链路挂载）", _gl.pools.size() == 7
		and _gl.pools[&"projectile"] != null and _gl.pools[&"enemy"] != null
		and _gl.pools[&"popup"] != null and _gl.pools[&"particle"] != null
		and _gl.pools[&"laser"] != null and _gl.pools[&"xp"] != null
		and _gl.pools[&"gold"] != null)
	_check("Boot：首发手枪（Q-4）", _gl.player.weapon_slots[0] != null)
	_check("Boot：time_scale 初始 1.0 / Engine.time_scale 未被改写",
		_gl.time_scale == 1.0 and Engine.time_scale == 1.0)


func _teardown_game_loop() -> void:
	tree.paused = false
	if _gl != null:
		_gl.free()
		_gl = null


# ── 要点 1：状态机迁移矩阵（含非法迁移拒绝 / E-16 仲裁） ────────────
func _test_state_machine() -> void:
	print("── 状态机迁移矩阵 ──")
	# 非法迁移：MENU → PAUSED / MENU → LEVEL_UP 拒绝
	var rej0: int = _gl.rejected_transitions
	_check("非法迁移拒绝：MENU→PAUSED", not _gl.change_state(GameConst.GameStatus.PAUSED))
	_check("非法迁移拒绝：MENU→LEVEL_UP", not _gl.change_state(GameConst.GameStatus.LEVEL_UP))
	_check("非法迁移计数累计", _gl.rejected_transitions == rej0 + 2)
	_check("拒绝后状态仍在 MENU", _gl.state == GameConst.GameStatus.MENU)
	# MENU → PLAYING（start_run）
	_check("start_run：MENU→PLAYING + 波次 1 开局", _gl.start_run()
		and _gl.state == GameConst.GameStatus.PLAYING and _gl.wave_director.current_wave == 1)
	# PLAYING ⇄ PAUSED（tree.paused 联动）
	_check("request_pause：PLAYING→PAUSED + tree.paused",
		_gl.request_pause() and _gl.state == GameConst.GameStatus.PAUSED and tree.paused)
	_check("request_resume：PAUSED→PLAYING + 恢复运行",
		_gl.request_resume() and _gl.state == GameConst.GameStatus.PLAYING and not tree.paused)
	# E-16：player_died 优先级最高（PLAYING → GAME_OVER，真实受击路径）
	var hp0: float = _gl.player.hp
	_gl.player.take_contact_damage(hp0 + 1.0)     # 必死一击（简化路径 Q-16 → player_died）
	_check("死亡仲裁：PLAYING→GAME_OVER（E-16 最高优先）",
		_gl.state == GameConst.GameStatus.GAME_OVER and _gl.player.hp <= 0.0)
	# E-16：GameOver 状态升级请求丢弃 + 计数
	var drop0: int = _gl.dropped_level_ups
	EventBus.emit_level_up(9)
	_check("GameOver 丢弃升级请求（E-16）", _gl.dropped_level_ups == drop0 + 1
		and _gl.state == GameConst.GameStatus.GAME_OVER)
	# 非法迁移：GAME_OVER → PAUSED 拒绝；GAME_OVER → PLAYING 不经 restart 不给（restart_run 才放行）
	_check("非法迁移拒绝：GAME_OVER→PAUSED", not _gl.change_state(GameConst.GameStatus.PAUSED))
	# 重开：GAME_OVER → PLAYING + 状态重置
	_check("restart_run：GAME_OVER→PLAYING + 波次重开", _gl.restart_run()
		and _gl.state == GameConst.GameStatus.PLAYING and _gl.wave_director.current_wave == 1)
	_check("restart_run：玩家 HP/经验/武器重置", _gl.player.hp == _gl.player.max_hp
		and _gl.player.level == 1 and _gl.player.weapon_slots[0] != null)
	# 升级仲裁：PLAYING → LEVEL_UP（选卡流打开）——详细流程在卡牌用例
	EventBus.emit_level_up(2)
	_check("升级仲裁：PLAYING→LEVEL_UP", _gl.state == GameConst.GameStatus.LEVEL_UP and tree.paused)
	# LEVEL_UP 中再收升级 → 排队
	EventBus.emit_level_up(3)
	_check("多级连升排队（A3 §6.2）", _gl.pending_level_ups == 1)
	# 选卡恢复（卡牌用例细化）
	_gl.card_select_ui.choose(0)
	_check("选卡后恢复 PLAYING + 排队继续弹",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.pending_level_ups == 0
		and _gl.card_select_ui.is_open)
	_gl.card_select_ui.choose(0)
	_check("第二张选完回 PLAYING", _gl.state == GameConst.GameStatus.PLAYING
		and not tree.paused and not _gl.card_select_ui.is_open)


# ── 要点 2/3：顿帧档位 / Engine.time_scale 恒不变 / 双时间通道 ──────
func _test_hit_stop_and_dual_channel() -> void:
	print("── 顿帧双通道 ──")
	_gl.game_feel.hit_stop_left = 0.0
	_gl.set_time_scale(1.0, &"test")
	# 档位真源：gamefeel 配置 hit_stop_ms=[0,30,50,120]（pkg0 锁定值）
	var cfg: GameFeelConfig = _gl.game_feel.feel_config
	var ms: Array[int] = cfg.hit_stop_ms
	_check("档位真源：hit_stop_ms=[0,30,50,120]",
		ms.size() == 4 and ms[0] == 0 and ms[1] == 30 and ms[2] == 50 and ms[3] == 120)
	# CRIT 档 30ms：damage_resolved 分级入口
	var r := DamageResult.new()
	r.feel_level = GameConst.FeelLevel.CRIT
	_gl.game_feel.on_damage_resolved(r)
	_check("CRIT 顿帧 30ms（档位来自配置）", absf(_gl.game_feel.hit_stop_left - 0.03) <= HIT_STOP_TOL)
	# CATALYST 50ms：取最大不叠加（AC-15.2）
	_gl.game_feel.on_damage_resolved(r)
	_check("合并不叠加：激活中同档再触发不延长",
		absf(_gl.game_feel.hit_stop_left - 0.03) <= HIT_STOP_TOL)
	var rc := DamageResult.new()
	rc.feel_level = GameConst.FeelLevel.CATALYST
	_gl.game_feel.on_damage_resolved(rc)
	_check("合并取最大：CRIT→CATALYST 50ms", absf(_gl.game_feel.hit_stop_left - 0.05) <= HIT_STOP_TOL)
	# BOSS_DEATH 120ms 档（enemy_killed 分级入口——用真 Enemy 实例携带 tags 字段）
	var boss: Enemy = _gl.pools[&"enemy"].acquire() as Enemy
	boss.tags = GameConst.TAG_BOSS
	_gl.game_feel.on_enemy_killed(boss)
	_check("BOSS_DEATH 顿帧 120ms（档位来自配置）",
		absf(_gl.game_feel.hit_stop_left - 0.12) <= HIT_STOP_TOL)
	(_gl.pools[&"enemy"] as EnemyPool).release(boss)
	# 双通道：一顿帧内驱动 3 帧——time_scale=0.05、game_delta≈0、raw 正常、Engine.time_scale 不变
	var raw := DT
	_gl._physics_process(raw)
	_check("顿帧激活：time_scale=hit_stop_scale(0.05)", absf(_gl.time_scale - 0.05) <= 0.0001)
	_check("冻结契约：Engine.time_scale 恒为 1.0", Engine.time_scale == 1.0)
	_check("双通道：顿帧期 game_delta = raw×0.05 ≈ 0",
		absf(_gl._game_delta(raw) - raw * 0.05) <= 0.0001 and _gl._game_delta(raw) < 0.0008)
	_check("双通道：raw 通道不受缩放（gamefeel 剩余按 raw 衰减）",
		_gl.game_feel.hit_stop_left > 0.10 and _gl.game_feel.hit_stop_left < 0.12)
	# 恢复：连续 tick 至顿帧耗尽（±1 帧内回 1.0，AC-15.1）
	for i in range(16):
		_gl._physics_process(raw)
	_check("顿帧结束 ±1 帧恢复 time_scale=1.0",
		_gl.time_scale == 1.0 and _gl.game_feel.desired_time_scale() == 1.0)
	_gl.game_feel.hit_stop_left = 0.0
	_gl.game_feel.hit_stop_active_ms = 0.0


# ── 要点 4：trauma 档位与衰减（AC-15.3） ──────────────────────────
func _test_trauma_levels_and_decay() -> void:
	print("── trauma 档位/衰减 ──")
	var feel := _gl.game_feel
	var shake := feel.shake
	shake.trauma = 0.0
	# 档位：shake_trauma=[0.15,0.4,0.5,1.0]（pkg0 锁定）
	var tra: Array[float] = feel.feel_config.shake_trauma
	_check("档位真源：shake_trauma=[0.15,0.4,0.5,1.0]",
		tra.size() == 4 and absf(tra[0] - 0.15) <= 0.0001 and absf(tra[1] - 0.4) <= 0.0001
		and absf(tra[2] - 0.5) <= 0.0001 and absf(tra[3] - 1.0) <= 0.0001)
	feel.add_trauma_for_level(GameConst.FeelLevel.HIT)
	_check("HIT 档 trauma 0.15", absf(shake.trauma - 0.15) <= 0.0001)
	feel.add_trauma_for_level(GameConst.FeelLevel.CATALYST)
	_check("CATALYST 档叠加 0.5 → 0.65", absf(shake.trauma - 0.65) <= 0.0001)
	feel.add_trauma_for_level(GameConst.FeelLevel.BOSS_DEATH)
	feel.add_trauma_for_level(GameConst.FeelLevel.BOSS_DEATH)
	_check("trauma clamp 1.0", shake.trauma == 1.0)
	# 上限映射：trauma=1 → |offset| ≤ 8px、|rot| ≤ 1.5°（Q-12）
	for i in range(200):
		var v := shake.offset_and_rotation()
		if Vector2(v.x, v.y).length() > 8.0 + 0.001 or absf(rad_to_deg(v.z)) > 1.5 + 0.001:
			_check("震屏上限 8px + 1.5°（Q-12）", false, "offset=%s rot=%s" % [str(v), str(v.z)])
			shake.trauma = 0.0
			return
	_check("震屏上限 8px + 1.5°（Q-12）", true)
	# 衰减：0.4s 内线性归零（raw 通道）
	shake.tick(0.2)
	_check("衰减 0.2s → 0.5", absf(shake.trauma - 0.5) <= 0.01)
	shake.tick(0.25)
	_check("衰减 0.45s → 归零", shake.trauma == 0.0)
	# 玩家受击 → HIT 档 trauma（player_hit 订阅；签名对齐 EventBus 双参信号——集成包）
	feel.on_player_hit(10.0, 1)
	_check("player_hit → trauma 0.15（HIT 档）", absf(shake.trauma - 0.15) <= 0.0001)
	shake.trauma = 0.0
	# 色差：CRIT 触发 0.004×2，0.15s 内线性归零（AC-15.4；先清残留段）
	_gl.game_feel.current_ca_intensity = 0.0
	_gl.game_feel.set("_ca_peak", 0.0)
	_gl.game_feel.set("_ca_left", 0.0)
	var rcrit := DamageResult.new()
	rcrit.feel_level = GameConst.FeelLevel.CRIT
	feel.on_damage_resolved(rcrit)
	_check("色差起跳 0.004×2（CRIT 档）", absf(feel.current_ca_intensity - 0.008) <= 0.0005)
	feel.tick(0.15)
	_check("色差 0.15s 内线性归零", feel.current_ca_intensity <= 0.0001)


# ── 要点 5：固定帧序（一次 tick 内调用顺序） ──────────────────────
func _test_frame_order() -> void:
	print("── 固定帧序 ──")
	_gl.frame_order.clear()
	_gl._physics_process(DT)
	var expect: Array[StringName] = [&"input", &"player", &"grid_projectile", &"enemy",
		&"wave", &"feel", &"ui"]
	_check("PLAYING 帧序 = ①输入②玩家(+武器)④网格弹⑤敌⑥波⑦feel⑧ui（架构 §2.17）",
		_gl.frame_order == expect, str(_gl.frame_order))
	# PAUSED：仅 ⑦⑧（raw 通道）
	_gl.request_pause()
	_gl.frame_order.clear()
	_gl._physics_process(DT)
	var expect_frozen: Array[StringName] = [&"feel", &"ui"]
	_check("PAUSED 帧序 = 仅⑦⑧（raw 通道）", _gl.frame_order == expect_frozen,
		str(_gl.frame_order))
	_gl.request_resume()
	# 帧尾钩子：EventBus 风暴计数每帧清零（end_frame 由 GameLoop 帧末驱动）
	EventBus._track_dispatch(&"pkg4_probe")
	_gl._physics_process(DT)
	_check("帧尾钩子：pipeline/EventBus end_frame 每帧驱动（计数清零）",
		EventBus.get_dispatch_count(&"pkg4_probe") == 0)


# ── 要点 6：HUD 数值绑定 ─────────────────────────────────────────
func _test_hud_binding() -> void:
	print("── HUD 数值绑定 ──")
	var hud := _gl.hud
	var player := _gl.player
	hud.refresh_stats()
	_check("HUD HP 绑定", hud.displayed_hp_text() == "HP %d/%d" % [int(player.hp), int(player.max_hp)])
	player.hp = 55.0
	hud.refresh_stats()
	_check("HUD HP 刷新（55/100）", hud.displayed_hp_text() == "HP 55/100")
	EventBus.emit_wave_started(7)
	_check("HUD 波次绑定（wave_started）", hud.displayed_wave() == 7)
	var k0: int = hud.displayed_kills()
	var probe_body := Node2D.new()                 # 击杀事件探针（裸实体，用后 free）
	EventBus.emit_enemy_killed(probe_body)
	probe_body.free()
	_check("HUD 击杀计数（enemy_killed）", hud.displayed_kills() == k0 + 1)
	# 经验/等级绑定：gain_xp 升级会触发 GameLoop 仲裁（E-16）进入选卡流——顺带断言状态提示
	var lv0: int = player.level
	player.gain_xp(player.xp_need)
	_check("HUD 等级绑定（升级后）", hud.displayed_level_text() == "Lv %d" % player.level
		and player.level == lv0 + 1,
		"text=%s lv=%d lv0=%d xp=%f need=%f" % [hud.displayed_level_text(), player.level, lv0, player.xp, player.xp_need])
	_check("升级仲裁联动：gain_xp → LEVEL_UP 选卡流打开", _gl.state == GameConst.GameStatus.LEVEL_UP
		and _gl.card_select_ui.is_open)
	_check("HUD 状态提示（LEVEL_UP 覆盖显示）", _gl.hud._state_label.visible
		and _gl.hud._state_label.text == "LEVEL UP - choose a card")
	_gl.card_select_ui.choose(0)
	_check("选卡恢复 PLAYING（状态提示隐藏）", _gl.state == GameConst.GameStatus.PLAYING
		and not _gl.hud._state_label.visible)


# ── 要点 7：跳字池化（0 运行期实例化 + 合并 + 上限） ──────────────
func _test_popup_pool() -> void:
	print("── 跳字池化 ──")
	var pm := _gl.popup_manager
	var pool: PopupPool = _gl.pools[&"popup"]
	pool.prewarm(GameConfig.get_pool_capacity(&"popup"))
	var inst0: int = int(pool.stats()["runtime_instantiates"])
	pm.tick(10.0)                                  # 清场
	# 基础弹出
	var r := DamageResult.new()
	r.final_value = 12.0
	r.target_uid = 101
	r.pos = Vector2(100, 200)
	r.popup_style = GameConst.PopupStyle.NORMAL
	pm.on_damage_resolved(r)
	_check("跳字弹出（active=1）", pm.active_popups == 1)
	# 合并窗（0.12s）内同目标 → 合并不新增（E-17）
	var r2 := DamageResult.new()
	r2.final_value = 8.0
	r2.target_uid = 101
	r2.pos = Vector2(100, 200)
	pm.on_damage_resolved(r2)
	_check("合并窗内同目标合并（active 仍 =1）", pm.active_popups == 1)
	var popup: DamagePopup = pm._active_list[0]
	_check("合并数值累加（12+8=20）", absf(popup.merged_value - 20.0) <= 0.001)
	# 池化：回收后 0 运行期实例化（AC-14.1）
	pm.tick(0.7)
	_check("到期归还（active=0）", pm.active_popups == 0)
	_check("池循环 0 运行期实例化", int(pool.stats()["runtime_instantiates"]) == inst0)
	# 同屏上限 80（E-09）
	for i in range(90):
		var rr := DamageResult.new()
		rr.final_value = 1.0
		rr.target_uid = 1000 + i
		rr.pos = Vector2(10 + i, 10)
		pm.on_damage_resolved(rr)
	_check("同屏上限 ≤80（超限丢弃计数）", pm.active_popups <= pm.MAX_ACTIVE
		and pm.dropped_count() > 0)
	pm.tick(10.0)
	_check("上限流量全量归还", pm.active_popups == 0)


# ── 要点 8：三选一卡牌流 ─────────────────────────────────────────
func _test_card_flow() -> void:
	print("── 三选一卡牌流 ──")
	var gen := _gl.card_generator
	gen.rng.seed = 1234
	var player := _gl.player
	# roll 数量与形状
	var cands := gen.generate_candidates({"player": player, "wave": 5})
	_check("三选一 roll 数量 = 3", cands.size() == 3)
	var kinds_ok := true
	for c in cands:
		if not c.has("kind") or not c.has("id") or not c.has("display_name"):
			kinds_ok = false
	_check("卡面字段齐全（kind/id/display_name）", kinds_ok)
	# 稀有度 roll（A3 §6.1 权重分布抽样：金卡概率 2/100 → 500 抽 0~30 张）
	var gold := 0
	gen.rng.seed = 777
	for i in range(500):
		if gen._roll_rarity(5) == 3:
			gold += 1
	_check("稀有度权重分布合理（金卡 500 抽 ≤40，w<10 基础权重 2%）", gold <= 40, "gold=%d" % gold)
	# 池过滤：叠层上限（AFF_ATK_UP stack_max=3，§6.4 至上限移出池）
	var atk := _gl.registry.get_trait(&"AFF_ATK_UP")
	_check("夹具：AFF_ATK_UP 存在（stack_max=3）", atk != null and atk.stack_max == 3)
	var weapon: WeaponBase = player.weapon_slots[0]
	for i in range(atk.stack_max):
		weapon.attach_trait(atk)
	var add_pool := gen._trait_candidates("ADD", player, [])
	_check("叠层上限过滤：满层 ID 移出候选池", not add_pool.has(&"AFF_ATK_UP"))
	# 同批去重
	var dup := gen._trait_candidates("ADD", player, [&"AFF_HP_UP"] as Array[StringName])
	_check("同批货架去重（picked 过滤）", not dup.has(&"AFF_HP_UP"))
	# fallback：空注册表 + 武器全满级（MASTERY 池空）→ 全 fallback（AC-16.4 界面永不空）
	var empty_gen := CardGenerator.new()
	empty_gen.setup(DataRegistry.new())
	empty_gen.rng.seed = 42
	var lv_keep: int = weapon.level
	weapon.level = WeaponBase.MAX_LEVEL            # 满 5 级 → 精通池空（A3 §3.10 封顶移出）
	var fb := empty_gen.generate_candidates({"player": player, "wave": 1})
	var all_fallback := true
	for c in fb:
		if int(c["kind"]) != CardGenerator.CardKind.FALLBACK:
			all_fallback = false
	_check("卡池耗尽 → 全 fallback（AC-16.4）", fb.size() == 3 and all_fallback)
	# fallback 应用：+5% 攻击入主武器栈
	var stack_before: int = weapon.trait_stack.size()
	empty_gen.apply_choice(empty_gen._fallback_stat_card(), player)
	_check("fallback 应用：主武器栈 +1", weapon.trait_stack.size() == stack_before + 1)
	weapon.level = lv_keep                          # 恢复等级（后续 MASTERY 用例需要未满级）
	# MASTERY 应用：武器等级 +1（≤MAX_LEVEL）
	var lv0: int = weapon.level
	var mastery := {
		"kind": CardGenerator.CardKind.MASTERY, "id": weapon.data.id, "rarity": 0,
		"data": weapon.data, "weapon": weapon, "display_name": "t", "description": "t",
	}
	gen.apply_choice(mastery, player)
	_check("MASTERY 应用：武器 +1 级", weapon.level == lv0 + 1,
		"lv0=%d lv=%d" % [lv0, weapon.level])
	# 遗物唯一（A3 §5 unique 每场唯一）
	var relic_ids := _gl.registry.relics.keys()
	if relic_ids.size() > 0:
		var rid: StringName = relic_ids[0]
		gen.owned_relics.clear()
		gen.apply_choice({"kind": CardGenerator.CardKind.RELIC, "id": rid,
			"data": null, "display_name": "r", "description": ""}, player)
		gen.apply_choice({"kind": CardGenerator.CardKind.RELIC, "id": rid,
			"data": null, "display_name": "r", "description": ""}, player)
		_check("遗物唯一：重复应用不重复入列", gen.owned_relics.count(rid) == 1)
	# card_chosen 事件（下游遗物回响/HUD 构筑统计源）
	var log0: int = _card_chosen_log.size()
	EventBus.card_chosen.connect(_on_card_chosen)
	gen.apply_choice({"kind": CardGenerator.CardKind.FALLBACK, "id": &"FALLBACK_ATK",
		"data": gen._fallback_stat_card()["data"], "display_name": "f", "description": ""},
		player)
	EventBus.card_chosen.disconnect(_on_card_chosen)
	_check("card_chosen 事件派发（id+kind）", _card_chosen_log.size() == log0 + 1)


func _on_card_chosen(p_id: StringName, p_kind: int) -> void:
	_card_chosen_log.append([p_id, p_kind])


# ── 要点 9：爆虫自爆（引爆时序 / 警示圈 / 击退打断 / 半径判定） ────
func _test_volatile_bug() -> void:
	print("── 爆虫自爆 ──")
	# 独立环境：池 + 爆虫 + 独立玩家（注入 _player_cache 隔离组查找）
	var pool := EnemyPool.new()
	tree.get_root().add_child(pool)
	pool.setup(&"enemy_pkg4", load(ENEMY_SCENE), 8)
	pool.prewarm(4)
	var player := Player.new()
	tree.get_root().add_child(player)              # Player._ready 组装命中盒
	player.max_hp = 100.0
	player.hp = 100.0
	# 爆虫数据（内存构造；数值真源 A3 §2.2 E4 行 = E4_volatile.tres 同值）
	var vdata := EnemyData.new()
	vdata.id = &"E4_volatile"
	vdata.hp_base = 30.0
	vdata.spd_base = 120.0
	vdata.dmg_base = 20.0
	vdata.exp_base = 5.0
	vdata.tp_cost = 1.5
	vdata.behavior = GameConst.EnemyBehavior.CHASE
	vdata.hitbox_r = 14.0
	var bug := pool.acquire() as Enemy
	bug.spawn(vdata, 1, 0)
	bug.position = Vector2(500, 500)
	bug._player_cache = player                     # 隔离：不走路由组查找
	player.global_position = Vector2(510, 500)     # 距离 10 < 命中盒和 + 余量 → 接触
	# 未接触前不引导
	bug.global_position = Vector2(800, 800)
	bug.tick(DT)
	_check("爆虫：未接触不引导", not bug.fuse_armed() and not bug._fuse_ring.visible)
	# 接触 → 引导 + 警示圈
	bug.global_position = Vector2(505, 500)
	player.global_position = Vector2(505, 500)
	bug.tick(DT)
	_check("爆虫：接触后引导激活（A3 接触后 1.2s 引爆）", bug.fuse_armed()
		and absf(bug.fuse_left() - 1.2) <= 0.001)
	_check("爆虫：警示圈程序化绘制（可见）", bug._fuse_ring.visible
		and bug._fuse_ring.radius == 110.0)
	# 时序：恰在 1.2s 引爆（120Hz × 1.2s = 144 帧 ±2；激活帧扣一次）
	var frames := 0
	while not bug.dead and frames < 400:
		bug.tick(DT)
		frames += 1
	_check("爆虫：恰在 1.2s 引爆（144 帧 ±2 @120Hz）", absi(frames - 144) <= 2,
		"frames=%d" % frames)
	_check("爆虫：爆炸伤害玩家（dmg_base=20 @w1）", absf(player.hp - 80.0) <= 0.001)
	_check("爆虫：爆炸后警示圈收起", not bug._fuse_ring.visible)
	# 半径判定：距离 >110 的玩家不受爆炸伤害
	var bug2 := pool.acquire() as Enemy
	bug2.spawn(vdata, 1, 0)
	bug2._player_cache = player
	bug2.global_position = Vector2(0, 0)
	player.global_position = Vector2(1000, 0)
	player.hp = 100.0
	bug2.tick(DT)                                  # 距离 1000 不触发
	_check("爆虫：远离不触发", not bug2.fuse_armed())
	player.global_position = Vector2(10, 0)        # 接触触发
	bug2.tick(DT)
	_check("爆虫：再次接触可再引导", bug2.fuse_armed())
	player.global_position = Vector2(500, 0)       # 拉到爆炸半径外（490 > 110）
	var frames2 := 0
	while not bug2.dead and frames2 < 400:
		bug2.tick(DT)
		frames2 += 1
	_check("爆虫：110px 半径外不受爆炸伤害", player.hp == 100.0 and bug2.dead)
	# 击退打断（A3 §3.9：击退可打断自爆引导）
	var bug3 := pool.acquire() as Enemy
	bug3.spawn(vdata, 1, 0)
	bug3._player_cache = player
	bug3.global_position = Vector2(500, 500)
	player.global_position = Vector2(505, 500)
	bug3.tick(DT)
	_check("爆虫：第三只正常引导", bug3.fuse_armed())
	bug3.knockback(Vector2(60, 0))
	_check("爆虫：击退打断引导（警示圈收起）", not bug3.fuse_armed()
		and not bug3._fuse_ring.visible)
	bug3.tick(DT)
	_check("爆虫：打断后不引爆（可再触发）", not bug3.dead)
	# 非爆虫不触发（种类判定按 id）
	var gdata := EnemyData.new()
	gdata.id = &"E1_grunt"
	gdata.hp_base = 72.0
	gdata.spd_base = 75.0
	gdata.dmg_base = 8.0
	gdata.tp_cost = 1.0
	gdata.behavior = GameConst.EnemyBehavior.CHASE
	gdata.hitbox_r = 14.0
	var grunt := pool.acquire() as Enemy
	grunt.spawn(gdata, 1, 0)
	grunt._player_cache = player
	grunt.global_position = Vector2(500, 500)
	player.global_position = Vector2(503, 500)
	grunt.tick(DT)
	_check("非爆虫（E1）贴脸不进入引导", not grunt.fuse_armed())
	# 清理
	for e in [bug, bug2, bug3, grunt]:
		if not (e as Enemy).dead:
			(e as Enemy).hp = 0.0
			(e as Enemy)._on_died()
		# dead 标志置位后由池回收路径处理（on_enemy_killed 未接——直接 free）
	player.free()
	pool.free()


# ── 要点 10：Boss 波伴随怪（波表驱动 + fallback 兼容） ─────────────
func _test_boss_escort() -> void:
	print("── Boss 波伴随怪 ──")
	# 注册表：E1（最便宜）/E2（疾冲）/BOSS/ELITE（精英模板——不入伴随池）
	var registry := DataRegistry.new()
	registry.enemies[&"E1"] = _make_enemy(&"E1", 1.0)
	registry.enemies[&"E2"] = _make_enemy(&"E2", 1.2)
	var boss := _make_enemy(&"BOSS", 999.0)
	boss.tags = GameConst.TAG_BOSS
	registry.enemies[&"BOSS"] = boss
	var elite := _make_enemy(&"ELITE", 16.0)
	elite.elite_mult = {"hp": 4.2, "spd": 0.92, "dmg": 1.5, "exp": 8.0}   # A3 §2.2 精英模板
	registry.enemies[&"ELITE"] = elite
	# 内存波表：composition 首现序 E1(w1) → E2(w3)
	var table := WaveTableData.new()
	var w1 := WaveEntryData.new()
	w1.index = 1
	w1.composition = [{"enemy_id": &"E1", "count": 5}]
	var w3 := WaveEntryData.new()
	w3.index = 3
	w3.composition = [{"enemy_id": &"E1", "count": 3}, {"enemy_id": &"E2", "count": 2}]
	var w9 := WaveEntryData.new()
	w9.index = 9
	w9.composition = [{"enemy_id": &"E1", "count": 3}, {"enemy_id": &"E4x", "count": 1}]
	table.entries = [w1, w3, w9]
	var env := _setup_escort_env(registry, table)
	var d: WaveDirector = env["director"]
	# w10：伴 G（池首个基础敌）×1/2.5s ≤12（A3 §2.4 w10 行）
	d.start_wave(10)
	var r10 := d._escort_rhythm(10)
	_check("w10 节奏：×1/2.5s 场上≤12", float(r10["interval"]) == 2.5 and int(r10["cap"]) == 12)
	_check("w10 伴 G（波表基础敌池首个）", (r10["mix"] as Array).size() == 1
		and (r10["mix"][0] as EnemyData).id == &"E1")
	# w20：伴 R（池第 2 首现敌 = 疾冲者）×1/2.5s ≤12（A3 §2.4 w20 行）
	d.start_wave(20)
	var r20 := d._escort_rhythm(20)
	_check("w20 节奏：×1/2.5s 场上≤12", float(r20["interval"]) == 2.5 and int(r20["cap"]) == 12)
	_check("w20 伴 R（波表基础敌池第 2 首现敌）", (r20["mix"] as Array).size() == 1
		and (r20["mix"][0] as EnemyData).id == &"E2")
	# w30：混合怪 ×1/2s 场上≤14（全池轮转；Boss/精英排除；悬空 E4x 跳过）（A3 §2.4 w30 行）
	d.start_wave(30)
	var r30 := d._escort_rhythm(30)
	_check("w30 节奏：混合怪 ×1/2s 场上≤14", float(r30["interval"]) == 2.0 and int(r30["cap"]) == 14)
	var mix30: Array = r30["mix"]
	_check("w30 混合池：全基础敌轮转（Boss/精英/悬空排除）", mix30.size() == 2
		and (mix30[0] as EnemyData).id == &"E1" and (mix30[1] as EnemyData).id == &"E2")
	# 实际刷怪节奏：w20 波 tick → 伴随怪全部 E2、2.5s 一只
	d.start_wave(20)
	for i in range(400):                           # 3.33s：t=2.5s 第 1 只
		d.tick(DT)
	_check("w20 实刷：3.33s 内伴随 1 只（2.5s 节奏）", _count_escort(env, &"E2") == 1,
		"e2=%d" % _count_escort(env, &"E2"))
	for i in range(400):                           # 累计 6.67s：t=5.0s 第 2 只
		d.tick(DT)
	_check("w20 实刷：6.67s 累计 2 只", _count_escort(env, &"E2") == 2,
		"e2=%d" % _count_escort(env, &"E2"))
	_check("w20 实刷：伴随全部为 R（E2）", _count_escort(env, &"E1") == 0)
	_teardown_escort_env(env)
	# fallback 兼容（pkg2 冻结行为）：无波表 → 最便宜敌 ×1/2.5s ≤12
	var env2 := _setup_escort_env(registry, null)
	var d2: WaveDirector = env2["director"]
	d2.start_wave(20)
	var rf := d2._escort_rhythm(20)
	_check("无波表 fallback：×1/2.5s 场上≤12（pkg2 兼容）",
		float(rf["interval"]) == 2.5 and int(rf["cap"]) == 12 and (rf["mix"] as Array).is_empty())
	d2.start_wave(10)
	for i in range(1300):
		d2.tick(DT)
	_check("无波表 fallback 实刷：伴随最便宜敌且场上 ≤12",
		_count_escort(env2, &"E1") > 0 and _count_escort(env2, &"E2") == 0
		and (env2["spawner"] as EnemySpawner).active_count() <= 12)
	_teardown_escort_env(env2)


func _make_enemy(p_id: StringName, p_tp: float) -> EnemyData:
	# 内存敌数据（跟随 pkg2 _make_enemy_data 口径）
	var e := EnemyData.new()
	e.id = p_id
	e.display_name = String(p_id)
	e.behavior = GameConst.EnemyBehavior.CHASE
	e.hp_base = 60.0
	e.spd_base = 80.0
	e.dmg_base = 8.0
	e.exp_base = 3.0
	e.tp_cost = p_tp
	e.hitbox_r = 14.0
	return e


func _setup_escort_env(p_registry: DataRegistry, p_table: WaveTableData) -> Dictionary:
	var pool := EnemyPool.new()
	pool.name = "EscortEnemyPool"
	tree.get_root().add_child(pool)
	pool.setup(&"enemy_escort", load(ENEMY_SCENE), 60)
	var spawner := EnemySpawner.new()
	spawner.name = "EscortSpawner"
	tree.get_root().add_child(spawner)
	spawner.pool = pool
	spawner.registry = p_registry
	var director := WaveDirector.new()
	director.name = "EscortDirector"
	tree.get_root().add_child(director)
	director.spawner = spawner
	director.registry = p_registry
	director.wave_table = p_table
	return {"pool": pool, "spawner": spawner, "director": director}


func _teardown_escort_env(p_env: Dictionary) -> void:
	tree.paused = false
	(p_env["director"] as WaveDirector).free()
	(p_env["spawner"] as EnemySpawner).free()
	(p_env["pool"] as EnemyPool).free()


func _count_escort(p_env: Dictionary, p_id: StringName) -> int:
	# 统计场上指定 data.id 的伴随怪（排除 Boss）
	var n := 0
	for e in (p_env["spawner"] as EnemySpawner).active:
		var enemy := e as Enemy
		if enemy != null and enemy.data != null and enemy.data.id == p_id:
			n += 1
	return n


# ── 断言 ──────────────────────────────────────────────────────────
func _check(p_msg: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_msg)
	else:
		_fail += 1
		var line := "FAIL | %s" % p_msg
		if p_detail != "":
			line += "　[%s]" % p_detail
		print(line)
		_failures.append(line)

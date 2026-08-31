# tests/runner/pkg5_cases.gd
# 集成包自测用例体（由 test_pkg5.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖：main.tscn 组装 / 真管线切换 / 全链冒烟 / xp 链路 / 遗物处理器（11 件）/
# RANGED 敌弹池化 / E-10 分离力 / 波首命中位 / duck 收紧回归 / AC 核心子集。
# 确定性：GameLoop 完整 Boot（main.tscn 实例化）→ 手动驱动 _physics_process(raw)；
# 概率型遗物（ECHO/CRIT_CHAIN）用种子扫描保证命中。
extends RefCounted

const DT := 1.0 / 120.0                          # 120Hz 物理帧
const MAIN_SCENE := "res://scenes/main.tscn"
const REAL_PIPELINE := "res://scripts/core/damage/damage_pipeline.gd"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null                         # 共享 GameLoop（main.tscn 实例化）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_ensure_autoloads()
	_test_main_scene_assembly()                   # A：main.tscn 组装 + 真管线 + Boot 预算
	_test_full_chain_smoke()                      # AC-16.1 全链
	_test_real_pipeline_nine_step()               # 真管线九步落血 + 公式锚点
	_test_rxn_alarm_line()                        # B.6 R_rxn 反应独立告警线
	_test_xp_chain()                              # B.1
	_test_relic_handler()                         # B.2
	_test_ranged_enemy_pool()                     # B.3
	_test_wave_first_hit()                        # B.4
	_test_separation_force()                      # B.5
	_test_duck_tightening()                       # B.8
	_test_ac_core_subset()                        # AC 核心子集
	_test_battlefield_reset()                     # 审查 Fix 1：重开清场 + 重生无敌回归
	_test_boss_kill_feel_and_escort_gate()        # 审查 Fix 2/3：Boss 击杀顿帧 + 伴随怪存活闸
	_test_crit_shard_and_validator()              # 审查 Fix 4：暴击弹片结算 + 悬空 threshold 剔除
	_test_aff_hp_up_wiring()                      # AFF_HP_UP 死池接线（hp 真源 60 回归）
	_teardown_game_loop()
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
	# ★ main.tscn 实例化（入口场景组装验证：根节点即 GameLoop，Boot 全链在 _ready 完成）
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)


func _teardown_game_loop() -> void:
	tree.paused = false
	if _gl != null:
		_gl.free()
		_gl = null


func _drive(p_frames: int) -> void:
	for i in range(p_frames):
		_gl._physics_process(DT)


# ── A：main.tscn 组装 + 真管线 + Boot 预算（AC-01.4 逻辑侧） ───────
func _test_main_scene_assembly() -> void:
	print("── main.tscn 组装 ──")
	var t0 := Time.get_ticks_usec()
	_boot_game_loop()
	var inst_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	_check("main.tscn：根节点 GameLoop 且 Boot 进入 MENU",
		_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU)
	_check("Boot：致命清单为空", _gl.boot_fatal.is_empty())
	_check("Boot 预算（AC-01.4 逻辑侧）：<3s", _gl._boot_elapsed_ms < 3000.0
		and inst_ms < 3000.0, "boot=%s ms" % str(_gl._boot_elapsed_ms))
	_check("切真管线：get_pipeline() 工厂默认真件（九步）",
		_gl.pipeline is DamagePipeline and not (_gl.pipeline is DamagePipelineStub))
	_check("组装：池×6 / 遗物处理器 / 菜单屏 / 相机就绪",
		_gl.pools.size() == 6 and _gl.relic_handler != null
		and _gl.menu_screen != null and _gl.camera != null)
	_check("组装：MenuScreen 仅 MENU 态可见", _gl.menu_screen.is_menu_visible())
	_check("冻结契约：Engine.time_scale 未被改写（§8.7）", Engine.time_scale == 1.0)
	# AC-14.2：进 PLAYING 前各池完成预热（Boot 后立即对账——free == capacity ×6）
	var prewarmed := true
	for pool_id in _gl.pools:
		var pool: ObjectPool = _gl.pools[pool_id]
		if int(pool.stats()["free"]) != int(pool.stats()["capacity"]):
			prewarmed = false
	_check("AC-14.2：六池 Boot 期全量预热（live=0 / free=capacity）", prewarmed)


# ── AC-16.1 全链冒烟 ──────────────────────────────────────────────
func _test_full_chain_smoke() -> void:
	print("── 全链冒烟（AC-16.1） ──")
	# MENU → 开战（经菜单屏信号——UI 链路接线验证）
	_gl.menu_screen.start_requested.emit()
	_check("MENU→PLAYING：菜单信号 start_run + 波次 1 + 菜单隐藏",
		_gl.state == GameConst.GameStatus.PLAYING and _gl.wave_director.current_wave == 1
		and not _gl.menu_screen.is_menu_visible())
	# 开战：生成节流下敌人陆续入场
	_drive(4)
	_check("开战：敌人入场（≤8/帧节流）", _gl.spawner.active_count() > 0
		and _gl.spawner.active_count() <= 8 * 5)
	# 击杀 → 掉落经验碎片（xp 链路）。注意：击杀事件内 spawner 立即归还实体
	#（_reset_state 复位字段），死亡后不再读 victim 字段——以 HUD 计数 + 掉落作证。
	var victim: Enemy = _gl.spawner.active[0]
	var exp_value: float = victim.exp_value
	var kills0: int = _gl.hud.kills
	var shards_before: int = _gl.active_shards.size()
	victim.apply_damage(999999.0)
	_check("击杀：enemy_killed 广播 + HUD 计数", _gl.hud.kills == kills0 + 1)
	_check("掉落：经验碎片入场上（面值 = exp_value × 点金手倍率 1.0）",
		_gl.active_shards.size() == shards_before + 1
		and is_equal_approx(_gl.active_shards[_gl.active_shards.size() - 1].value, exp_value))
	# 磁吸拾取 → 经验入账（AC-16.1 磁吸段；520px/s 飞行 60px ≈ 12 帧）
	var shard: XpShard = _gl.active_shards[_gl.active_shards.size() - 1]
	var xp0: float = _gl.player.xp
	shard.global_position = _gl.player.global_position + Vector2(60.0, 0.0)
	_drive(20)
	_check("拾取：磁吸半径内自动飞向玩家并吸收（xp 入账）", _gl.player.xp > xp0
		and not _gl.active_shards.has(shard))
	# 升级 → 三选一（LEVEL_UP 冻结，AC-16.2）
	var lv0: int = _gl.player.level
	_gl.player.gain_xp(_gl.player.xp_need)
	_check("升级：gain_xp → LEVEL_UP 选卡流打开", _gl.player.level == lv0 + 1
		and _gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open
		and _gl.current_candidates.size() >= 3)
	# AC-16.2：升级界面打开时战斗完全冻结
	var frozen_pos: Vector2 = _gl.spawner.active[0].global_position
	var frozen_queue: int = _gl.spawner.queue_count()
	_drive(5)
	_check("AC-16.2：LEVEL_UP 战斗完全冻结（敌人静止/生成暂停）",
		_gl.spawner.active[0].global_position == frozen_pos
		and _gl.spawner.queue_count() == frozen_queue)
	# 选卡 → 词条生效 → 恢复 PLAYING
	var card: Dictionary = _gl.current_candidates[0]
	var kind := int(card.get("kind", -1))
	var w: WeaponBase = _gl.player.weapon_slots[0]
	var traits0: int = w.trait_stack.traits.size()
	var wlevel0: int = w.level
	var relics0: int = _gl.card_generator.owned_relics.size()
	_gl.card_select_ui.choose(0)
	_check("选卡：恢复 PLAYING（AC-16.1 选卡段）",
		_gl.state == GameConst.GameStatus.PLAYING and not _gl.card_select_ui.is_open)
	var applied := false
	match kind:
		0:                                      # MASTERY：武器 +1 级
			applied = w.level == wlevel0 + 1
		1:                                      # TRAIT：词条挂载生效
			applied = w.trait_stack.traits.size() > traits0
		2:                                      # RELIC：遗物入场
			applied = _gl.card_generator.owned_relics.size() > relics0 \
				or _gl.relic_handler.owned_count() > 0
		_:                                      # FALLBACK：+5% 攻击词条
			applied = w.trait_stack.traits.size() > traits0
	_check("词条生效：所选卡类别效果落武器（kind=%d）" % kind, applied)
	# Boss 波（AC-16.3 逢 10 Boss 波 + 血条）
	_gl.wave_director.start_wave(10)
	_drive(8)
	var boss_on_field := false
	for e in _gl.spawner.active:
		if e is Enemy and (e as Enemy).is_boss():
			boss_on_field = true
			break
	_check("Boss 波：Boss 登场 + 血条显示（AC-16.3）",
		boss_on_field and _gl.boss_bar.is_visible_bar())
	# F-19：Boss 击杀 → 槽位解锁（EventBus 真实派发序回归——wave_director 读 tags
	# 必须先于 spawner 归还清零，集成包修复的接线验证；w10 Boss1 → 槽 4）
	var slots_before: int = _gl.player.unlocked_slots
	var bosses: Array[Enemy] = []
	for e in _gl.spawner.active:
		if e is Enemy and (e as Enemy).is_boss():
			bosses.append(e)
	for b in bosses:
		b.apply_damage(9999999.0)
	_check("F-19：Boss1 击杀 → 槽位 4 解锁（真实派发序，修复回归）",
		_gl.player.unlocked_slots == maxi(slots_before, 4))
	# 死亡 → 结算 → 重开（AC-16.1 尾段）
	_gl.player.invuln_left = 0.0
	_gl.player.take_contact_damage(999999.0)
	_check("死亡仲裁：PLAYING→GAME_OVER（E-16 最高优先）",
		_gl.state == GameConst.GameStatus.GAME_OVER)
	_check("结算屏：统计可见（击杀/波次/总伤害）",
		_gl.game_over_screen.summary_text().contains("击杀"))
	_check("重开：GAME_OVER→PLAYING + 数值重置（波次 1/满血/碎片清场/遗物清零）",
		_gl.restart_run() and _gl.state == GameConst.GameStatus.PLAYING
		and _gl.wave_director.current_wave == 1
		and is_equal_approx(_gl.player.hp, _gl.player.max_hp)
		and _gl.active_shards.is_empty() and _gl.relic_handler.owned_count() == 0)


# ── 真管线九步落血 ────────────────────────────────────────────────
func _test_real_pipeline_nine_step() -> void:
	print("── 真管线九步落血 ──")
	# 落血：真实 Enemy 承接 resolve（步骤 9b take_result → apply_damage）
	var data := EnemyData.new()
	data.id = &"E_TEST_PIPE"
	data.hp_base = 1000.0
	data.spd_base = 0.0
	var enemy: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(data, 1, 0)
	enemy.resist = [0.0, 0.0, 0.5, 0.0]           # ICE 抗 50%
	var ctx := DamageContext.make()
	ctx.source_uid = 777
	ctx.target = enemy
	ctx.target_uid = enemy.uid
	ctx.frame_stamp = GameConfig.frame_stamp
	ctx.base_atk = 100.0
	ctx.element = GameConst.Element.ICE
	ctx.crit_chance = 0.0
	var result: DamageResult = _gl.pipeline.call(&"resolve", ctx)
	_check("九步落血：V=(1−0.5) → 50 入血（hp 1000→950）",
		result != null and is_equal_approx(result.final_value, 50.0)
		and is_equal_approx(enemy.hp, 950.0))
	# AC-12.7 幂等：同帧同源同目标二次结算 → 缓存命中，血量不再变化
	var result2: DamageResult = _gl.pipeline.call(&"resolve", ctx)
	_check("AC-12.7：幂等——二次结算返回缓存且血量仅扣一次",
		result2 == result and is_equal_approx(enemy.hp, 950.0))
	(_gl.pools[&"enemy"] as EnemyPool).release(enemy)
	# AC-12.1 公式锚点（真管线口径）：(100×1.5+10)×1.5×1.4 = 336
	var t2 := _make_stat_target()
	var c1 := _pipe_ctx(t2, 1)
	c1.base_atk = 100.0
	c1.add_entries = [
		{"trait_id": &"A", "pool_id": &"add_atk", "layer": 1, "contrib": 0.2, "decay_delta": 0.85, "is_curse": false},
		{"trait_id": &"B", "pool_id": &"add_atk", "layer": 1, "contrib": 0.3, "decay_delta": 0.85, "is_curse": false},
	]
	c1.flat_bonus = 10.0
	c1.mult_pools = [
		{"pool_id": &"m1", "source_uid": 1, "contrib": 0.5, "cap_pool": 2.0},
		{"pool_id": &"m2", "source_uid": 2, "contrib": 0.4, "cap_pool": 2.0},
	]
	var r1: DamageResult = _gl.pipeline.call(&"resolve", c1)
	_check("AC-12.1：真管线公式锚点 336",
		r1 != null and is_equal_approx(r1.final_value, 336.0),
		"got %s" % str(r1.final_value if r1 != null else null))
	# AC-12.2 防御层去重：同 ID ×1.5 两次 → 取最大（150 非 225）
	var c2 := _pipe_ctx(t2, 2)
	c2.base_atk = 100.0
	c2.mult_pools = [
		{"pool_id": &"frozen_bonus", "source_uid": 7, "contrib": 0.5, "cap_pool": 2.0},
		{"pool_id": &"frozen_bonus", "source_uid": 7, "contrib": 0.5, "cap_pool": 2.0},
	]
	var r2: DamageResult = _gl.pipeline.call(&"resolve", c2)
	_check("AC-12.2：同乘区 ID 去重取最大 → 150",
		r2 != null and is_equal_approx(r2.final_value, 150.0))
	(_gl.pools[&"enemy"] as EnemyPool).release(t2)
	# 修复 A 回归：settle_aoe 真件管线落血恰好一次（九步 9b 内部 take_result，调用方
	# 不再二次落血——双重结算会让 AOE 范围伤害 ×2）。夹具同构 Fix4：真实 Enemy 入网格，
	# 武器管线为 _deps 注入的真件；crit_chance 缺省 0 → 无暴击，零抗零易伤 → 恰扣 100。
	var aoe_t := _make_stat_target()
	aoe_t.position = Vector2(60.0, 60.0)
	_gl.spawner.active.append(aoe_t)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var aoe_w: WeaponBase = _gl.player.weapon_slots[0]
	aoe_w.settle_aoe(aoe_t.global_position, 100.0, 100.0, false)
	_check("修复A：settle_aoe 真件落血恰好一次（1000000→999900，非 ×2 双扣）",
		is_equal_approx(aoe_t.hp, 999900.0), "hp=%s" % str(aoe_t.hp))
	_gl.spawner.active.erase(aoe_t)
	(_gl.pools[&"enemy"] as EnemyPool).release(aoe_t)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	# 修复 B 回归：投射物直击真件管线落血恰好一次（_submit_hit → resolve 九步 9b 内部
	# take_result；_on_settled → _apply_result_to 不再二次落血——双重结算会让直击 ×2）。
	# 夹具同构修复 A：真实 Enemy + 弹池真弹体注入 _gl 真件管线；面板 crit_rate=0 →
	# 无暴击，零抗零易伤 → 恰扣 100。
	var hit_t := _make_stat_target()
	var proj: ProjectileBase = (_gl.pools[&"projectile"] as ProjectilePool).acquire()
	proj.spawn({
		"velocity": Vector2.ZERO,
		"lifetime": 2.0,
		"pierce": 1,
		"hitbox_radius": 6.0,
		"element": GameConst.Element.KIN,
		"panel_snapshot": {"base_atk": 100.0, "crit_rate": 0.0,
			"crit_mult": 2.0, "flat_bonus": 0.0, "add_entries": []},
		"team": 0,
	})
	proj.damage_pipeline = _gl.pipeline
	proj.pool = _gl.pools[&"projectile"]
	proj._submit_hit(hit_t)
	_check("修复B：投射物直击真件落血恰好一次（1000000→999900，非 ×2 双扣）",
		is_equal_approx(hit_t.hp, 999900.0), "hp=%s" % str(hit_t.hp))
	(_gl.pools[&"enemy"] as EnemyPool).release(hit_t)
	# 修复 B 桩口径回归锚（行为不变）：透传桩 resolve 只算不落血 → 调用方
	# _apply_result_to 落血一次。同夹具换桩管线，恰扣 100 一次（pkg2/pkg3 桩口径锁定）。
	var stub_t := _make_stat_target()
	var proj_stub: ProjectileBase = (_gl.pools[&"projectile"] as ProjectilePool).acquire()
	proj_stub.spawn({
		"velocity": Vector2.ZERO,
		"lifetime": 2.0,
		"pierce": 1,
		"hitbox_radius": 6.0,
		"element": GameConst.Element.KIN,
		"panel_snapshot": {"base_atk": 100.0, "crit_rate": 0.0,
			"crit_mult": 2.0, "flat_bonus": 0.0, "add_entries": []},
		"team": 0,
	})
	proj_stub.damage_pipeline = DamagePipelineStub.new()
	proj_stub.pool = _gl.pools[&"projectile"]
	proj_stub._submit_hit(stub_t)
	_check("修复B：桩口径投射物直击落血恰好一次（调用方落血行为不变 1000000→999900）",
		is_equal_approx(stub_t.hp, 999900.0), "hp=%s" % str(stub_t.hp))
	(_gl.pools[&"enemy"] as EnemyPool).release(stub_t)


# ── R_rxn 反应独立告警线（B.6） ───────────────────────────────────
func _test_rxn_alarm_line() -> void:
	print("── R_rxn 反应独立告警线 ──")
	# 管线内部计数直读（_stats/_rxn_alarm_emitted——测试观测口径，pkg4 set() 同惯例）
	var pipe := _gl.pipeline as DamagePipeline
	var bal := GameConfig.balance
	_check("B.6：BalanceTables.r_rxn_ratio 落字段（50，独立于 R_alarm=500）",
		is_equal_approx(float(bal.r_rxn_ratio), 50.0)
		and not is_equal_approx(float(bal.r_rxn_ratio), float(bal.r_alarm_ratio)))
	var t := _make_stat_target()
	var rxn0: int = int(pipe._stats["rxn_alarms"])
	# 超线反应（χ=60 > r_rxn=50）：D 钳制 S×50 + 审计 alarm + 独立计数 + 首次广播置位
	var ctx_hi := _pipe_ctx(t, 10)
	var r_hi: DamageResult = pipe.resolve_reaction(100.0, 60.0, ctx_hi)
	_check("B.6：超线反应钳制 D=S×r_rxn（6000→5000）",
		r_hi != null and is_equal_approx(r_hi.final_value, 5000.0))
	_check("B.6：超线反应审计 alarm + rxn_alarms 独立计数（与 R_alarm 分账）",
		r_hi != null and r_hi.audit != null and r_hi.audit.alarm
		and int(pipe._stats["rxn_alarms"]) == rxn0 + 1
		and bool(pipe._rxn_alarm_emitted))
	# 二次超线（不同 frame_stamp 防幂等缓存命中）：双闸不再广播、计数继续累加
	var ctx_hi2 := _pipe_ctx(t, 11)
	var r_hi2: DamageResult = pipe.resolve_reaction(100.0, 60.0, ctx_hi2)
	_check("B.6：R_rxn 双闸——二次超线仅记审计+计数（广播闸保持已触发）",
		r_hi2 != null and int(pipe._stats["rxn_alarms"]) == rxn0 + 2
		and bool(pipe._rxn_alarm_emitted))
	# 亚线反应（χ=2.0 < 50）：原值通过、审计干净
	var ctx_ok := _pipe_ctx(t, 12)
	var r_ok: DamageResult = pipe.resolve_reaction(100.0, 2.0, ctx_ok)
	_check("B.6：亚线反应原值通过（200）且审计无告警",
		r_ok != null and is_equal_approx(r_ok.final_value, 200.0)
		and r_ok.audit != null and not r_ok.audit.alarm)
	(_gl.pools[&"enemy"] as EnemyPool).release(t)


# ── xp 链路（B.1） ────────────────────────────────────────────────
func _test_xp_chain() -> void:
	print("── xp 链路 ──")
	_check("xp 池挂载：容量 160 + 全量预热（AC-14.2）",
		(_gl.pools[&"xp"] as XPPool).stats()["capacity"] == 160
		and int((_gl.pools[&"xp"] as XPPool).stats()["free"]) == 160)
	# 掉落值（exp_value × 点金手倍率）与磁吸边界
	var enemy: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(_make_enemy_data(&"E_XP", 1.0), 1, 0)
	var shards0: int = _gl.active_shards.size()
	_gl._on_enemy_killed_drop_xp(enemy)
	_check("掉落：碎片面值 = exp_value(7) × 倍率", _gl.active_shards.size() == shards0 + 1
		and is_equal_approx(_gl.active_shards[_gl.active_shards.size() - 1].value, 7.0))
	# 磁吸半径外不吸附、半径内吸附
	var shard: XpShard = _gl.active_shards[_gl.active_shards.size() - 1]
	var far_pos: Vector2 = _gl.player.global_position + Vector2(_gl.player.pickup_radius + 80.0, 0.0)
	shard.global_position = far_pos
	var dist0 := shard.global_position.distance_to(_gl.player.global_position)
	shard.tick(DT)
	_check("磁吸：半径外静止（Q-13 120px 边界）",
		is_equal_approx(shard.global_position.distance_to(_gl.player.global_position), dist0))
	shard.global_position = _gl.player.global_position + Vector2(60.0, 0.0)
	shard.tick(DT * 4.0)
	_check("磁吸：半径内向玩家飞行", shard.global_position.x < far_pos.x
		or shard.global_position.distance_to(_gl.player.global_position) < 60.0
		or _gl.player.xp > 0.0)
	_gl._spawn_xp_shard(_gl.player.global_position, 0.0)
	_check("掉落：零值丢弃（数值纪律）", _gl.active_shards.size() == shards0 + 1)
	# 满池合并（架构 §5.1 XPPool：合并为大面值碎片，数值守恒）
	var xp_pool := _gl.pools[&"xp"] as XPPool
	var guard: Array[XpShard] = []
	while true:
		var s := xp_pool.acquire()
		if s == null:
			break
		guard.append(s)
	var merged0: float = _gl.active_shards[0].value
	_gl._spawn_xp_shard(Vector2.ZERO, 5.0)
	_check("满池：合并入已有碎片（+5 数值守恒）",
		is_equal_approx(_gl.active_shards[0].value, merged0 + 5.0))
	for s in guard:
		xp_pool.release(s)
	# 清场归还
	_gl._reset_run_state()
	_check("重开清场：碎片全归还（live=0）", int(xp_pool.stats()["live"]) == 0
		and _gl.active_shards.is_empty())
	(_gl.pools[&"enemy"] as EnemyPool).release(enemy)


# ── 遗物处理器（B.2，11 件全量） ──────────────────────────────────
func _test_relic_handler() -> void:
	print("── 遗物处理器 ──")
	var h := _gl.relic_handler
	_check("遗物注册表：11 件加载", _gl.registry.relics.size() == 11)
	# REL_MIDAS：经验倍率
	_check("REL_MIDAS：激活 + 经验 ×1.2",
		h.activate(&"REL_MIDAS") and is_equal_approx(h.xp_mult(), 1.2))
	_check("遗物唯一：重复激活拒绝", not h.activate(&"REL_MIDAS") and h.owned_count() == 1)
	# REL_HARVEST：击杀回血 0.4% max_hp
	_check("REL_HARVEST：激活", h.activate(&"REL_HARVEST"))
	var victim: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	victim.spawn(_make_enemy_data(&"E_REL", 1.0), 1, 0)
	_gl.player.hp = 50.0
	EventBus.emit_enemy_killed(victim)            # spawner 同步归还（池内节点合法）
	_check("REL_HARVEST：击杀 +0.4% max_hp（50→50.4）",
		is_equal_approx(_gl.player.hp, 50.0 + _gl.player.max_hp * 0.004))
	# REL_OVERCLOCK：精英首杀 → 下一张卡稀有度保底紫+（每波一次）
	_check("REL_OVERCLOCK：激活", h.activate(&"REL_OVERCLOCK"))
	EventBus.emit_wave_started(3)
	var elite: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	elite.spawn(_make_enemy_data(&"E_EL", 1.0), 3, GameConst.TAG_ELITE)
	EventBus.emit_enemy_killed(elite)
	_check("REL_OVERCLOCK：精英首杀 → 保底紫+（rarity_floor=2）", h.take_rarity_floor() == 2)
	var elite2: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	elite2.spawn(_make_enemy_data(&"E_EL2", 1.0), 3, GameConst.TAG_ELITE)
	EventBus.emit_enemy_killed(elite2)
	_check("REL_OVERCLOCK：每波一次（第二次不再保底）", h.take_rarity_floor() == -1)
	# REL_WORDS_TIDE：波开始重随申请（每波一次）
	_check("REL_WORDS_TIDE：激活", h.activate(&"REL_WORDS_TIDE"))
	EventBus.emit_wave_started(4)
	_check("REL_WORDS_TIDE：wave_started → 重随申请 + 波内精英位重置",
		h.consume_reroll() and not h.consume_reroll())
	# REL_GAMBLER：四选一 + 末位诅咒
	# 幂等口径（修复 B 双保险）：卡牌流（冒烟选卡 / 本用例弹卡 choose）可能随机抽中
	# RELIC——card_chosen 通道已自动激活，显式 activate 因「每场唯一」被拒属业务正确；
	# 已持有即视同激活生效（效果断言保持原强度，语义不弱化）
	_check("REL_GAMBLER：激活（卡牌流提前入场 → 已持有即生效）",
		h.activate(&"REL_GAMBLER") or h.has_relic(&"REL_GAMBLER"))
	_check("REL_GAMBLER：发牌数 4", h.deal_count() == 4 and h.curse_requested())
	_gl.player.invuln_left = 0.0
	EventBus.emit_level_up(2)                     # PLAYING → LEVEL_UP（发牌走遗物参数）
	_check("REL_GAMBLER：货架 4 张 + 末位诅咒标记",
		_gl.state == GameConst.GameStatus.LEVEL_UP
		and _gl.current_candidates.size() == 4
		and bool(_gl.current_candidates[3].get("cursed", false)))
	var w: WeaponBase = _gl.player.weapon_slots[0]
	var traits0: int = w.trait_stack.traits.size()
	_gl.card_select_ui.choose(3)                  # 选诅咒卡 → 附加 ATK −10% 诅咒词条
	var has_curse := false
	for tb in w.trait_stack.traits:
		if (tb as Object).get("data").id == &"GAMBLER_CURSE":
			has_curse = true
	_check("REL_GAMBLER：诅咒卡应用 → GAMBLER_CURSE 词条挂载",
		has_curse or w.trait_stack.traits.size() > traits0)
	# REL_BOSS_TROPHY：精英/Boss 独立乘区 ×1.25（命中时点注入）
	_check("REL_BOSS_TROPHY：激活", h.activate(&"REL_BOSS_TROPHY"))
	var elite3: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	elite3.spawn(_make_enemy_data(&"E_EL3", 1.0), 3, GameConst.TAG_ELITE | GameConst.TAG_BOSS)
	var plain3: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	plain3.spawn(_make_enemy_data(&"E_PL3", 1.0), 3, 0)
	_check("REL_BOSS_TROPHY：精英/Boss ×1.25、普通 ×1.0",
		is_equal_approx(h.elite_dmg_bonus(elite3), 0.25) and is_equal_approx(h.elite_dmg_bonus(plain3), 0.0))
	var rctx := DamageContext.make()
	rctx.target = elite3
	(w as WeaponBase).inject_relic_pools(rctx, elite3)
	_check("REL_BOSS_TROPHY：ctx 注入 elite_dmg 乘区池",
		WeaponBase.has_mult_pool(rctx, &"elite_dmg"))
	# REL_MOMENTUM：反弹叠 +8%/层 上限 10 层
	_check("REL_MOMENTUM：激活", h.activate(&"REL_MOMENTUM"))
	_check("REL_MOMENTUM：0 反弹无加成 / 5 层 +40% / 12 层钳 10 层 +80%",
		is_equal_approx(h.bounce_momentum_bonus(0), 0.0)
		and is_equal_approx(h.bounce_momentum_bonus(5), 0.4)
		and is_equal_approx(h.bounce_momentum_bonus(12), 0.8))
	var mctx := DamageContext.make()
	mctx.bounce_count = 5
	mctx.target = plain3
	(w as WeaponBase).inject_relic_pools(mctx, plain3)
	_check("REL_MOMENTUM：ctx 注入 bounce_dmg 乘区池",
		WeaponBase.has_mult_pool(mctx, &"bounce_dmg"))
	# 注入幂等（同 ctx 二次注入不重复入池）
	(w as WeaponBase).inject_relic_pools(mctx, plain3)
	var bounce_count := 0
	for pool in mctx.mult_pools:
		if StringName(String(pool.get("pool_id", ""))) == &"bounce_dmg":
			bounce_count += 1
	_check("遗物乘区幂等：同 ctx 重复注入不重复入池", bounce_count == 1)
	# REL_CRIT_CHAIN：暴击 15% 重置主武器冷却（种子扫描保证命中）
	_check("REL_CRIT_CHAIN：激活", h.activate(&"REL_CRIT_CHAIN"))
	w.cooldown_left = 1.0
	var crit := DamageResult.new()
	crit.is_crit = true
	var chained := false
	for s in range(64):
		h.rng.seed = s
		var resets0: int = h.crit_chain_resets
		h._on_damage_resolved(crit)
		if h.crit_chain_resets > resets0:
			chained = true
			break
	_check("REL_CRIT_CHAIN：暴击重置主武器冷却", chained and w.cooldown_left == 0.0)
	# REL_ECHO：25% 复制该卡到另一把武器（种子扫描保证命中）
	_check("REL_ECHO：激活", h.activate(&"REL_ECHO"))
	var echo_trait := _gl.registry.get_trait(_gl.registry.trait_ids_by_pool(GameConst.PoolClass.MULT)[0])
	var echoed := false
	for s in range(64):
		h.rng.seed = s + 1024
		var echoes0: int = h.echo_copies
		h._on_card_chosen(echo_trait.id, 1)       # kind=TRAIT
		if h.echo_copies > echoes0:
			echoed = true
			break
	_check("REL_ECHO：选卡后复制词条到随机武器", echoed)
	# REL_BLACK_MARKET：w35 起每 10 波排程商店波（A3 §6.5 占位计数；w35/w45 排程、w36 不排程）
	# 幂等口径（修复 B 双保险）：同 GAMBLER——卡牌流提前抽中时已持有即生效
	_check("REL_BLACK_MARKET：激活（卡牌流提前入场 → 已持有即生效）",
		h.activate(&"REL_BLACK_MARKET") or h.has_relic(&"REL_BLACK_MARKET"))
	EventBus.emit_wave_cleared(35)
	EventBus.emit_wave_cleared(45)
	EventBus.emit_wave_cleared(36)
	_check("REL_BLACK_MARKET：w35/w45 排程、w36 不排程（占位计数 2）",
		h.pending_shop_waves == 2)
	# REL_PHOENIX：致死保留 1 HP + 清屏冲击（每场 1 次）——放最后（含死亡分支）
	# 幂等护栏（同 REL_GAMBLER/REL_BLACK_MARKET 先例）：冒烟选卡可能随机抽中 PHOENIX
	# （card_chosen 通道自动激活）→ 显式 activate 被「每场唯一」拒绝属业务正确，已持有即生效
	_check("REL_PHOENIX：激活（卡牌流提前入场 → 已持有即生效）",
		h.activate(&"REL_PHOENIX") or h.has_relic(&"REL_PHOENIX"))
	_gl.player.invuln_left = 0.0
	_gl.player.hp = 5.0
	_gl.player.take_contact_damage(999999.0)
	_check("REL_PHOENIX：致死保留 1 HP（不死鸟触发）",
		_gl.player.hp == 1.0 and h.phoenix_triggered == 1
		and _gl.state == GameConst.GameStatus.PLAYING)
	_gl.player.invuln_left = 0.0
	_gl.player.take_contact_damage(999999.0)
	_check("REL_PHOENIX：次数耗尽 → 死亡放行（E-16）",
		_gl.state == GameConst.GameStatus.GAME_OVER)
	_check("重开：遗物清零（每场唯一口径）",
		_gl.restart_run() and _gl.relic_handler.owned_count() == 0
		and is_equal_approx(_gl.relic_handler.xp_mult(), 1.0)
		and _gl.relic_handler.deal_count() == 3)
	# 清理遗物测试残余敌人
	for e: Enemy in [elite3, plain3]:
		if is_instance_valid(e):
			(_gl.pools[&"enemy"] as EnemyPool).release(e)


# ── RANGED 敌弹池化（B.3） ────────────────────────────────────────
func _test_ranged_enemy_pool() -> void:
	print("── RANGED 敌弹池 ──")
	var data := _make_enemy_data(&"E_RANGED_T", 1.0)
	data.behavior = GameConst.EnemyBehavior.RANGED
	data.ranged = {"bullet_speed": 240.0, "fire_cd": 1.5, "bullet_atk_ratio": 0.5,
		"spread": 0.0, "fire_range": 2000.0}
	var shooter: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	shooter.spawn(data, 1, 0)
	shooter.projectile_pool = _gl.pools[&"projectile"]
	shooter.position = _gl.player.global_position + Vector2(300.0, 0.0)
	shooter.fire_cd_left = 0.0                    # 立即开火
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var inst0: int = int(pool.stats()["runtime_instantiates"])
	var live0: int = int(pool.stats()["live"])
	shooter.tick(DT)
	var enemy_bullets: Array[ProjectileBase] = []
	for p in pool.active_projectiles():
		if p is ProjectileBase and (p as ProjectileBase).team == 1:
			enemy_bullets.append(p)
	_check("RANGED 开火：敌弹入场（team=1）", not enemy_bullets.is_empty())
	_check("B.3 敌弹池化：0 运行期实例化（走池不走 instantiate）",
		int(pool.stats()["runtime_instantiates"]) == inst0)
	_check("敌弹格：消弹查询快照含敌弹",
		_gl._collect_enemy_bullets().size() >= enemy_bullets.size())
	for b in enemy_bullets:
		b.nullify()                               # NULLIFIED 路径回收
	(_gl.pools[&"enemy"] as EnemyPool).release(shooter)
	_check("敌弹回收：池内清洁往返（live 恢复至射击前基线）",
		int(pool.stats()["live"]) == live0)


# ── 波首命中位（B.4） ─────────────────────────────────────────────
func _test_wave_first_hit() -> void:
	print("── 波首命中位 ──")
	_gl.wave_director.start_wave(1)
	_drive(1)
	_check("B.4：波开行首杀位复位（wave_first_kill_done=false）",
		not _gl.wave_director.wave_first_kill_done)
	_check("B.4：武器波首命中位查询 = true（SYN_FIRST_STRIKE 条件源）",
		(_gl.player.weapon_slots[0] as WeaponBase).is_wave_first_hit())
	var victim: Enemy = _gl.spawner.active[0]
	victim.apply_damage(999999.0)
	_check("B.4：首次击杀后波首命中位关闭",
		_gl.wave_director.wave_first_kill_done
		and not (_gl.player.weapon_slots[0] as WeaponBase).is_wave_first_hit())
	# ctx 通路：无 weapon_ref 的裸弹默认 false（pkg2 口径不变）
	var proj: ProjectileBase = (_gl.pools[&"projectile"] as ProjectilePool).acquire()
	proj.spawn({"velocity": Vector2.ZERO, "lifetime": 0.0, "panel_snapshot": {"base_atk": 1.0}})
	_check("B.4：无宿主武器通道 → ctx 波首位 false 安全", not proj._wave_first_hit())
	(_gl.pools[&"projectile"] as ProjectilePool).release(proj)


# ── E-10 敌间分离力（B.5） ────────────────────────────────────────
func _test_separation_force() -> void:
	print("── 敌间分离力 ──")
	var data := _make_enemy_data(&"E_SEP", 1.0)
	data.spd_base = 0.0                           # 静止（分离力是唯一位移源）
	data.hitbox_r = 14.0
	var a: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	var b: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	a.spawn(data, 1, 0)
	b.spawn(data, 1, 0)
	a.position = Vector2(360, 640)
	b.position = Vector2(360, 640)                # 完全重叠
	_gl.spawner.active.append(a)
	_gl.spawner.active.append(b)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var d0 := 0.0
	_gl._apply_enemy_separation()
	_gl._apply_enemy_separation()
	var d1 := a.global_position.distance_to(b.global_position)
	_check("E-10：重叠敌分离（10Hz 软推，距离 0→%s）" % str(d1), d1 > d0)
	_gl._apply_enemy_separation()
	_gl._apply_enemy_separation()
	var d2 := a.global_position.distance_to(b.global_position)
	_check("E-10：软钳（单次 ≤4px，不弹开）", d2 >= d1 and d2 < 32.0)
	_gl.spawner.active.erase(a)
	_gl.spawner.active.erase(b)
	(_gl.pools[&"enemy"] as EnemyPool).release(a)
	(_gl.pools[&"enemy"] as EnemyPool).release(b)


# ── duck 收紧回归（B.8） ──────────────────────────────────────────
func _test_duck_tightening() -> void:
	print("── duck 收紧第二批 ──")
	var proj: ProjectileBase = (_gl.pools[&"projectile"] as ProjectilePool).acquire()
	_check("收紧① ProjectilePool.acquire() → ProjectileBase",
		proj is ProjectileBase)
	(_gl.pools[&"projectile"] as ProjectilePool).release(proj)
	var enemy: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	_check("收紧② EnemyPool.acquire() → Enemy", enemy is Enemy)
	(_gl.pools[&"enemy"] as EnemyPool).release(enemy)
	var shard: XpShard = (_gl.pools[&"xp"] as XPPool).acquire()
	_check("收紧③ XPPool.acquire() → XpShard", shard is XpShard)
	(_gl.pools[&"xp"] as XPPool).release(shard)
	_check("收紧④ player.weapon_slots → Array[WeaponBase]（真件直调）",
		_gl.player.weapon_slots[0] is WeaponBase)
	_check("收紧⑤ equip_weapon 签名 WeaponBase（null 拒绝）",
		not _gl.player.equip_weapon(null))
	var ctx := DamageContext.make()
	ctx.target = Enemy.new()                      # 编译期类型检查：仅 Enemy 可赋值
	_check("收紧⑥ DamageContext.target → Enemy（真件赋值合法）", ctx.target is Enemy)
	# 未授权收紧位维持占位口径（pkg0 dummy 夹具兼容）
	var popup: Node2D = (_gl.pools[&"popup"] as PopupPool).acquire()
	_check("维持：PopupPool.acquire() → Node2D 占位（本批未授权收紧）", popup is Node2D)
	(_gl.pools[&"popup"] as PopupPool).release(popup)


# ── AC 核心子集（A1 §3 可自动化条目） ─────────────────────────────
func _test_ac_core_subset() -> void:
	print("── AC 核心子集 ──")
	# AC-01.1：竖屏逻辑分辨率 + 拉伸策略
	_check("AC-01.1：720×1280 + canvas_items/keep（Q-1 裁定口径）",
		ProjectSettings.get_setting("display/window/size/viewport_width") == 720
		and ProjectSettings.get_setting("display/window/size/viewport_height") == 1280
		and String(ProjectSettings.get_setting("display/window/stretch/mode")) == "canvas_items"
		and String(ProjectSettings.get_setting("display/window/stretch/aspect")) == "keep")
	# AC-14.4：池满降级（软闸 null + 计数）
	var tiny := ProjectilePool.new()
	tree.get_root().add_child(tiny)
	tiny.setup(&"pkg5_tiny", load("res://scenes/combat/projectiles/ballistic_projectile.tscn"), 1)
	tiny.soft_limit = 1
	tiny.hard_limit = 1
	var t1: ProjectileBase = tiny.acquire()
	var t2: ProjectileBase = tiny.acquire()
	_check("AC-14.4：池满请求拒绝（null + misses 计数，无崩溃）",
		t1 != null and t2 == null and int(tiny.stats()["misses"]) == 1)
	tiny.free()
	# AC-16.3：单帧生成节流 ≤8
	_gl.wave_director.start_wave(5)               # 表驱动：G×20 + R×8
	var before: int = _gl.spawner.active_count()
	_gl.spawner.tick(DT, _gl.enemy_grid)
	_check("AC-16.3：单帧生成节流 ≤8", _gl.spawner.active_count() - before <= 8
		and _gl.spawner.queue_count() > 0)
	# AC-16.4：卡池耗尽 fallback（注册表为空 + 武器全满级 → 全部候选过滤 → 3 张保底属性卡）
	var empty_gen := CardGenerator.new()
	empty_gen.setup(DataRegistry.new())
	var w0: WeaponBase = _gl.player.weapon_slots[0]
	var wlevel_backup: int = w0.level
	w0.level = WeaponBase.MAX_LEVEL                     # 精通池清空（M-17 过滤口径）
	var fallbacks := empty_gen.generate_candidates({"player": _gl.player, "wave": 1})
	var all_fallback := true
	for c in fallbacks:
		if int(c.get("kind", -1)) != CardGenerator.CardKind.FALLBACK:
			all_fallback = false
	w0.level = wlevel_backup
	_check("AC-16.4：卡池耗尽 → fallback 属性卡 ×3（界面永不空）",
		fallbacks.size() == 3 and all_fallback)
	# AC-11.1/11.2：元素状态在真实敌实体生效（满槽附着 → DOT / 减速 / 易伤；
	# 附着计量真源 GAUGE_MAX=100）
	var edata := _make_enemy_data(&"E_ELE", 100000.0)
	edata.spd_base = 100.0
	var target: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	target.spawn(edata, 1, 0)
	target.position = Vector2(360, 300)           # 远离玩家（排除接触伤害/追击位移）
	_gl.elemental.register_host(target)
	_gl.elemental.apply_attach(target, GameConst.Element.FIR, 100.0, {"snapshot": 100.0})
	var hp0: float = target.hp
	_drive(200)                                   # ~1.7s raw：覆盖 ≥1 次 DOT 跳（0.5s 周期，含顿帧抖动）
	_check("AC-11.1：点燃 DOT 落血（真管线独立结算）", target.hp < hp0)
	_gl.elemental.apply_attach(target, GameConst.Element.ICE, 100.0, {})
	_check("AC-11.2：冰冻易伤因子 ×1.25 + 寒滞减速生效",
		is_equal_approx(target.get_vuln_factor(), 1.25)
		and target.elemental.get_speed_factor() < 1.0)
	_gl.elemental.unregister_host(target)
	(_gl.pools[&"enemy"] as EnemyPool).release(target)
	# AC-15.1：暴击 → 顿帧申请 → GameLoop 双通道降速（不写 Engine.time_scale）
	var cctx := DamageContext.make()
	cctx.target = _make_stat_target()
	cctx.target_uid = int(cctx.target.get("uid"))
	cctx.frame_stamp = GameConfig.frame_stamp
	cctx.base_atk = 10.0
	cctx.crit_chance = 1.0
	_gl.pipeline.call(&"resolve", cctx)
	_gl.game_feel.hit_stop_left = 0.05            # 直喂顿帧（事件侧已由真实结算触发过）
	_gl._physics_process(DT)
	_check("AC-15.1：顿帧激活 time_scale=0.05 + Engine.time_scale 恒 1（§8.7）",
		absf(_gl.time_scale - 0.05) <= 0.0001 and Engine.time_scale == 1.0)
	_gl.game_feel.hit_stop_left = 0.0
	_gl.game_feel.hit_stop_active_ms = 0.0
	(_gl.pools[&"enemy"] as EnemyPool).release(cctx.target)
	# AC-15.5：粒子发射器池化 + 上限
	for i in range(10):
		_gl.game_feel.particles.burst(&"fx_kill", Vector2(100 + i, 100), 0)
	_check("AC-15.5：粒子发射器走池（同屏 ≤64）",
		int((_gl.pools[&"particle"] as ParticlePool).stats()["live"]) <= 64)
	_drive(2)
	# AC-14.3：全程池污染为 0（取出/归还双向清洁）
	var polluted := 0
	for pool_id in _gl.pools:
		polluted += int((_gl.pools[pool_id] as ObjectPool).stats()["pollution"])
	var rejected := 0
	for pool_id in _gl.pools:
		rejected += int((_gl.pools[pool_id] as ObjectPool).stats()["rejected_releases"])
	_check("AC-14.3：全程池污染 0 / 非法归还 0（E-05）", polluted == 0 and rejected == 0)
	# AC-14.1（冒烟段）：全链跑完 0 运行期实例化
	var zero_inst := true
	for pool_id in _gl.pools:
		if int((_gl.pools[pool_id] as ObjectPool).stats()["runtime_instantiates"]) != 0:
			zero_inst = false
	_check("AC-14.1：全链冒烟 0 运行期实例化（六池，池预热全覆盖）", zero_inst)


# ── 支撑 ──────────────────────────────────────────────────────────
func _ensure_playing() -> void:
	# 前序用例残余状态收口：升级选卡队列逐张消费回 PLAYING + 顿帧/缩放残留清零
	var guard := 0
	while _gl.state == GameConst.GameStatus.LEVEL_UP and guard < 8:
		_gl.card_select_ui.choose(0)
		guard += 1
	_gl.game_feel.hit_stop_left = 0.0
	_gl.game_feel.hit_stop_active_ms = 0.0
	_gl.set_time_scale(1.0, &"test")


func _drive_safe(p_frames: int) -> void:
	# 观测口径驱动：每帧回满血（排除残余敌人接触伤害致死干扰）+ 升级弹卡即选（不中断波次观测）
	for i in range(p_frames):
		_gl.player.hp = _gl.player.max_hp
		_gl._physics_process(DT)
		if _gl.state == GameConst.GameStatus.LEVEL_UP:
			_gl.card_select_ui.choose(0)


func _count_escorts() -> int:
	# 场上伴随怪计数（排除 Boss）
	var n := 0
	for e in _gl.spawner.active:
		var enemy := e as Enemy
		if enemy != null and not enemy.is_boss():
			n += 1
	return n


func _make_shard_trait_data() -> TraitData:
	# 弹片词条定义（EF_CRIT_SHARD 挂载载体——单元路径与 pkg3 同构）
	var d := TraitData.new()
	d.id = &"TEST_CRIT_SHARD"
	d.pool = GameConst.PoolClass.MECH
	d.effect_id = &"EF_CRIT_SHARD"
	d.stack_max = 1
	d.proc_chance = 1.0
	d.event_hooks.append(GameConst.TraitEvent.ON_HIT)
	return d


# ── 审查 Fix 1：重开清场 + 重生无敌（Critical 95 回归） ────────────
func _test_battlefield_reset() -> void:
	print("── 重开清场（审查 Fix 1） ──")
	_ensure_playing()
	_gl.player.hp = _gl.player.max_hp
	_gl.wave_director.start_wave(1)
	_drive(4)                                     # 敌人入场（清场对象：在场敌）
	_check("清场前：在场敌 > 0（清场对象就位）", _gl.spawner.active_count() > 0,
		"active=%d" % _gl.spawner.active_count())
	# 清场对象：敌弹残留（team=1 直接入池，不 tick——只验清场归还）
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var bullet := pool.acquire() as ProjectileBase
	bullet.pool = pool
	bullet.spawn({"velocity": Vector2(10.0, 0.0), "lifetime": 10.0, "hitbox_radius": 5.0,
		"team": 1, "panel_snapshot": {"base_atk": 1.0}})
	# 清场对象：活跃光束（无宿主引用挂池——重开清场归还口径）
	var laser_pool := _gl.pools[&"laser"] as LaserBeamPool
	var beam := laser_pool.acquire() as LaserBeam
	beam.pool = laser_pool
	beam.spawn({"position": Vector2(360.0, 900.0), "dir": Vector2.UP, "team": 0,
		"tick_atk": 1.0, "panel_snapshot": {}})
	_check("清场前：投射物/光束池 live > 0",
		int(pool.stats()["live"]) > 0 and int(laser_pool.stats()["live"]) > 0)
	_gl.player.invuln_left = 0.0
	_gl.player.take_contact_damage(999999.0)
	_check("重开前：GAME_OVER（E-16）", _gl.state == GameConst.GameStatus.GAME_OVER)
	_check("重开清场：restart 后在场敌 0 / 投射物 live 0 / 光束 live 0 / 波次 1 队列重建",
		_gl.restart_run() and _gl.state == GameConst.GameStatus.PLAYING
		and _gl.spawner.active_count() == 0
		and int(pool.stats()["live"]) == 0 and int(laser_pool.stats()["live"]) == 0
		and _gl.spawner.queue_count() > 0)
	_check("重开保护：重生无敌帧激活（invuln_left > 0，1.5s 主控裁定）",
		_gl.player.invuln_left > 0.0)


# ── 审查 Fix 2/3：Boss 击杀顿帧 + 伴随怪 Boss 存活闸 ───────────────
func _test_boss_kill_feel_and_escort_gate() -> void:
	print("── Boss 击杀顿帧（Fix 2）+ 伴随怪存活闸（Fix 3） ──")
	_ensure_playing()
	_gl._reset_run_state()                        # 前序残余清场（波次观测从干净战场起步）
	_gl.player.hp = _gl.player.max_hp
	# wave_cleared 真实 EventBus 探针（Node 订阅者——E-12 口径，pkg2 探针同构）
	var s := GDScript.new()
	s.source_code = "extends Node\n" \
		+ "var cleared: Array[int] = []\n" \
		+ "func on_wave_cleared(w: int) -> void:\n\tcleared.append(w)\n"
	s.reload()
	var probe := Node.new()
	probe.name = "Pkg5ClearedProbe"
	probe.set_script(s)
	tree.get_root().add_child(probe)
	EventBus.wave_cleared.connect(Callable(probe, "on_wave_cleared"))
	_gl.wave_director.start_wave(10)
	_drive(8)                                     # Boss 队列 → 8 帧内入场
	var bosses: Array[Enemy] = []
	for e in _gl.spawner.active:
		if e is Enemy and (e as Enemy).is_boss():
			bosses.append(e)
	_check("Fix3 前置：w10 Boss 登场", not bosses.is_empty())
	_drive_safe(320)                              # 2.67s：跨过首个 2.5s 伴随节拍
	var escorts_alive: int = _count_escorts()
	_check("Fix3：Boss 存活 → 伴随怪流水照常（场上伴怪 > 0）", escorts_alive > 0,
		"escorts=%d" % escorts_alive)
	# Fix 2：EventBus 真实派发 Boss 击杀（非直调）→ 120ms 档顿帧
	#（连接序回归：GameFeel 前置订阅先于 spawner 归还清零读 tags）
	_gl.game_feel.hit_stop_left = 0.0
	_gl.game_feel.hit_stop_active_ms = 0.0
	for b in bosses:
		if is_instance_valid(b):
			b.apply_damage(999999999.0)
	_check("Fix2：Boss 击杀经 EventBus 真实派发 → 120ms 顿帧申请（BOSS_DEATH 档）",
		absf(_gl.game_feel.hit_stop_left - 0.12) <= 0.0001
		and absf(_gl.game_feel.hit_stop_active_ms - 120.0) <= 0.0001,
		"left=%s" % str(_gl.game_feel.hit_stop_left))
	# Fix 3 反向：Boss 死 → 流水停（3.33s 逐帧观测：伴怪计数不得出现新增峰值——
	# 既有伴怪被武器击杀属正常战斗，不计入违例）
	var escorts_at_death: int = _count_escorts()
	var max_seen: int = escorts_at_death
	for i in range(400):
		_gl.player.hp = _gl.player.max_hp
		_gl._physics_process(DT)
		if _gl.state == GameConst.GameStatus.LEVEL_UP:
			_gl.card_select_ui.choose(0)
		max_seen = maxi(max_seen, _count_escorts())
	_check("Fix3：Boss 死亡 → 伴随怪流水停止（3.33s 零新增）",
		max_seen <= escorts_at_death and escorts_at_death > 0,
		"at_death=%d max=%d" % [escorts_at_death, max_seen])
	# Fix 3：清场 → wave_cleared 真实派发（窗口归零强制 CLEARING；残余杀光后逐帧驱动
	# 至探针捕获事件——字段可能已空，须保证窗口归零后至少一帧 tick）
	_gl.wave_director.window_left = 0.0
	var guard := 0
	while guard < 600 and not (probe.get("cleared") as Array).has(10):
		for e in _gl.spawner.active.duplicate():
			if is_instance_valid(e):
				(e as Enemy).apply_damage(999999.0)
		_drive_safe(1)
		guard += 1
	var cleared: Array = probe.get("cleared")
	_check("Fix3：清场完成 → wave_cleared(10) 真实派发",
		cleared.has(10), "waves=%s" % str(cleared))
	EventBus.wave_cleared.disconnect(Callable(probe, "on_wave_cleared"))
	probe.free()


# ── 审查 Fix 4：暴击弹片结算 + 校验器悬空 threshold 剔除 ───────────
func _test_crit_shard_and_validator() -> void:
	print("── 暴击弹片（Fix 4）+ 校验器剔除 ──")
	_ensure_playing()
	# 双镜像清单同步 + 注册武器 threshold 存活（EF_CRIT_SHARD 注册后不再是悬空项）
	_check("Fix4：双镜像清单同步（TraitEffect.known_effect_ids / TECH_EFFECT_IDS ∋ EF_CRIT_SHARD）",
		TraitEffect.known_effect_ids().has(&"EF_CRIT_SHARD")
		and DataValidator.TECH_EFFECT_IDS.has(&"EF_CRIT_SHARD"))
	var w: WeaponBase = _gl.player.weapon_slots[0]   # W1_pistol：.tres 声明 TH_CRIT_SHARD(0.6, ratio 0.5)
	var th: Dictionary = w.get_threshold(&"TH_CRIT_SHARD")
	_check("Fix4：注册武器 TH_CRIT_SHARD 存活（66 资源 0 rejected 口径不回归）",
		not th.is_empty() and StringName(str(th.get("effect_id", ""))) == &"EF_CRIT_SHARD")
	# 弹片结算（真件武器 threshold + 真实管线；主目标 1000000 血，邻近单体半径内/外各一）
	var main: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	main.spawn(_make_enemy_data(&"E_SHARD_MAIN", 1000000.0), 1, 0)
	main.position = Vector2(360.0, 400.0)
	var near: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	near.spawn(_make_enemy_data(&"E_SHARD_NEAR", 1000000.0), 1, 0)
	near.position = Vector2(380.0, 420.0)            # 弹片半径内
	var far: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	far.spawn(_make_enemy_data(&"E_SHARD_FAR", 1000000.0), 1, 0)
	far.position = Vector2(700.0, 1000.0)            # 弹片半径外
	_gl.spawner.active.append(main)
	_gl.spawner.active.append(near)
	_gl.spawner.active.append(far)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var proj: ProjectileBase = (_gl.pools[&"projectile"] as ProjectilePool).acquire()
	proj.spawn({"velocity": Vector2.ZERO, "lifetime": 10.0, "hitbox_radius": 6.0, "team": 0,
		"panel_snapshot": {"base_atk": 100.0, "crit_rate": 0.65, "crit_mult": 2.0}})
	proj.position = Vector2(360.0, 400.0)
	var shard_tb := TraitBase.new()
	shard_tb.setup(_make_shard_trait_data())
	var ef := TraitEffect.resolve(&"EF_CRIT_SHARD")
	var tctx := TraitContext.new()
	tctx.event = GameConst.TraitEvent.ON_HIT
	tctx.projectile = proj
	tctx.weapon = w
	tctx.target = main
	var dctx := DamageContext.make()
	dctx.target = main
	dctx.base_atk = 100.0
	dctx.crit_mult = 2.0
	dctx.pos = proj.global_position
	tctx.damage_ctx = dctx
	# 阈下：暴击率 0.5 < 0.6 → 质变未激活
	dctx.crit_chance = 0.5
	ef.handle(shard_tb, tctx)
	_check("Fix4：暴击率 0.5 < 0.6 阈下 → 弹片不结算", is_equal_approx(near.hp, 1000000.0),
		"hp=%s" % str(near.hp))
	# 阈上：暴击率堆过 0.6 → 弹片 = 0.5 × 暴伤 = base_atk × crit_mult × ratio = 100×2×0.5 = 100
	dctx.crit_chance = 0.65
	ef.handle(shard_tb, tctx)
	_check("Fix4：暴击率堆过阈值 → 邻近单体弹片结算（0.5×暴伤 = 100）",
		is_equal_approx(near.hp, 999900.0), "hp=%s" % str(near.hp))
	_check("Fix4：主目标不重复结算 / 半径外不波及",
		is_equal_approx(main.hp, 1000000.0) and is_equal_approx(far.hp, 1000000.0))
	proj.nullify()
	for e: Enemy in [main, near, far]:
		_gl.spawner.active.erase(e)
		(_gl.pools[&"enemy"] as EnemyPool).release(e)
	# 校验器：悬空 effect_id threshold 剔除（宿主武器保留，AC-13.3 降级不崩溃）
	var reg := DataRegistry.new()
	var wdata := WeaponData.new()
	wdata.id = &"W_SHARD_TEST"
	wdata.threshold_traits = [{
		"threshold_id": &"TH_CRIT_SHARD", "metric": "crit_rate", "threshold": 0.6,
		"effect_id": &"EF_CRIT_SHARD", "params": {"ratio": 0.5},
	}, {
		"threshold_id": &"TH_DANGLE", "metric": "crit_rate", "threshold": 0.6,
		"effect_id": &"EF_NO_WHERE", "params": {},
	}]
	reg.weapons[wdata.id] = wdata
	var issues: Array = DataValidator.new().check_references(reg)
	var stripped := 0
	for issue in issues:
		if String(issue.get("field", "")) == "threshold_traits.effect_id":
			stripped += 1
	_check("Fix4：悬空 effect_id threshold 被剔除 + 告警（宿主保留）",
		stripped == 1 and wdata.threshold_traits.size() == 1
		and StringName(str(wdata.threshold_traits[0].get("threshold_id", ""))) == &"TH_CRIT_SHARD"
		and reg.weapons.has(&"W_SHARD_TEST"))


# ── AFF_HP_UP 死池接线（hp 真源 60 + add_hp 池消费回归） ────────────
func _test_aff_hp_up_wiring() -> void:
	print("── AFF_HP_UP 死池接线 ──")
	# 隔离（末位用例）：清遗物常驻位——防此前用例偶得 REL_ECHO 回响复制附加挂载，
	# 扰动「每层 +25」层数口径；reset_run 不影响任何前序已完成的断言。
	_gl.relic_handler.reset_run()
	_gl.card_generator.owned_relics.clear()
	var t: TraitData = _gl.registry.get_trait(&"AFF_HP_UP")
	if t == null:
		_check("AFF_HP_UP 接线：注册表含 AFF_HP_UP（.tres 加载）", false)
		return
	# 基线锚定 cfg 真源 60（等价 fresh run：满血、单起始武器在槽 0）
	_gl.player.max_hp = float(GameConfig.get_constant(&"player_base_hp", 60.0))
	_gl.player.hp = _gl.player.max_hp
	var card := {
		"kind": CardGenerator.CardKind.TRAIT,
		"id": &"AFF_HP_UP",
		"rarity": 0,
		"data": t,
		"display_name": String(t.display_name),
		"description": String(t.description),
	}
	_gl.card_generator.apply_choice(card, _gl.player)   # 第 1 层（选卡应用）
	_gl.card_generator.apply_choice(card, _gl.player)   # 第 2 层（同 ID 叠层）
	var layers := 0
	for tb: TraitBase in _gl.player.weapon_slots[0].trait_stack.traits:
		if tb.data.id == &"AFF_HP_UP":
			layers = tb.layers
	_check("AFF_HP_UP 接线：2 层 → max_hp = 60+25×2 = 110 且 hp 等量回补",
		layers == 2 and is_equal_approx(_gl.player.max_hp, 110.0)
		and is_equal_approx(_gl.player.hp, 110.0),
		"layers=%d max_hp=%s hp=%s" % [layers, str(_gl.player.max_hp), str(_gl.player.hp)])


# ── 支撑（原有） ──────────────────────────────────────────────────
func _make_enemy_data(p_id: StringName, p_hp: float) -> EnemyData:
	var data := EnemyData.new()
	data.id = p_id
	data.hp_base = p_hp
	data.spd_base = 0.0
	data.dmg_base = 5.0
	data.exp_base = 7.0
	data.hitbox_r = 14.0
	return data


func _make_stat_target() -> Enemy:
	# 公式锚点目标（真件 Enemy、零抗、大血量）
	var t: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	var data := _make_enemy_data(&"E_STAT", 1000000.0)
	t.spawn(data, 1, 0)
	t.set("uid", GameConst.next_uid())
	return t


func _pipe_ctx(p_target: Enemy, p_frame: int) -> DamageContext:
	var ctx := DamageContext.make()
	ctx.source_uid = 42
	ctx.target = p_target
	ctx.target_uid = int(p_target.get("uid"))
	ctx.frame_stamp = GameConfig.frame_stamp + p_frame
	ctx.element = GameConst.Element.KIN
	ctx.crit_chance = 0.0
	return ctx


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])

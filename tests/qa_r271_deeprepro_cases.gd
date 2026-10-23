# tests/qa_r271_deeprepro_cases.gd（R271 headless 深载复现台架用例体——入口运行时加载）
# 复现口径（如实登记，verdict 判读须与本节对照；probe_r224_deepload 同源结构）：
# · 场景：start_run 后 state 恒 PLAYING，boost_override=1（促1 深载态）+ mode_override=0
#   （帧率优先）+ tier_override=2 —— vc79 深载配置面。
# · 负载：敌 90 池化驻场（grove 波表 w16 构成平铺池 + 补位 8/帧，HP ×0.3 压血复本——
#   probe_r224 同款）+ team-0 活弹 448 顶格（真开火通道 W2 加特林 L5 五词条 + 池直注
#   填充弹补位——「弹 ≥420 量级断言」的 M4 门① 口径）。
# · 驱动：引擎原生物理步（await tree.physics_frame——与 probe_r224 手动直驱不同：
#   R271 量的是 延µs 冲刷窗/隙µs/物步µs，哨兵经 message_queue 冲刷执行，必须让引擎
#   真跑物理相+冲刷点；120 帧预热 + 600 帧测量/臂）。
# · 采样：测量窗内推离 1Hz 采样门（_diag_last_ms 前推——防止秒窗复位吃掉累计器，
#   直读 R271 秒窗键全窗值；窗毕复位）。
# · 短路臂注入口：S1/S7=TexBucketHost static、S4=ProjectileBase static、S5=PopupManager
#   static（全部默认零短路）；S2=敌 _hit_area.monitoring 批量置 false + 玩家侧面惰化
#   （设计 §3.2 二选一取「短路面最小」——CONTACT_RADIAL boot 前置臂会经池复用污染
#   后续臂〔M2-R 前提证伪〕，臂毕双向复位）；S3=自绘件树扫 visible=false（泛化——
#   本构筑无自绘武器件，罩全场景自绘面）；S6=每帧 release 全部活弹。
# · 判读（设计 §3.2）：塌缩率=(基线−臂)/基线；某臂 延µs 塌缩 ≥60%（S2 按 延∪隙∪物步
#   三键并集——§9-2）→ 该类坐实；全部臂不塌缩 ∧ 基线过 M4 门 ∧ 基线延µs<5k → H5=V-D。
# · 诚实边界：headless 无渲染/无 GPU——只能定谳模拟侧+引擎模拟机制；渲ms/dc/呈帧N
#   真机专属（vc81 判读）；复现度带与 vc79 真机量级差一个数量级以上时 verdict 表头
#   标注「复现度低，H5 概率上移」。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GROVE_TABLE := "res://resources/maps/wave_table_grove.tres"
const HOLD := 90                         # 敌驻场（vc79 深载敌 90 帽）
const TARGET_BULLETS := 448              # team-0 活弹顶格（vc79 弹 448 观测峰）
const BULLET_FLOOR := 420                # M4 门① 下限
const ENEMY_FLOOR := 85                  # M4 门① 下限
const WARMUP_FRAMES := 180
const MEASURE_FRAMES := 900
const TOPUP_PER_FRAME := 8
const ENEMY_HP_SCALE := 0.3
const PLAYER_HOME := Vector2(360.0, 900.0)
const VERDICT_PATH := "res://docs/qa/2026-10-14-R271-deeprepro-verdict.md"
const POSTCUT_PATH := "res://docs/qa/2026-10-14-R271-deeprepro-postcut.md"
                                              # 修轮 M1（评审/QA DEF-1）：verdict 落盘路径参化——
                                              # 缺省=复跑态档（postcut，可覆写）；archive=1 才写归档
                                              # 档且已存在即拒绝覆写（防复跑破坏 md5 基线）。参化
                                              # 手法照 qa_r228_diagfreeze「-- compare=」cmd 参先例。
const POSTCUT_RERUN_PATH := "res://tools/r271_deeprepro_postcut_rerun.txt"
                                              # R287 修轮（评审 #1/DEF-QA-002 复发）：postcut 自
                                              # R272 追记制起=归档证据，复跑改道痕档（可覆写）——
                                              # docs/qa/ 原档永不再被 bench 覆写。
# R271 P4 绘µs wrap 清单（grep `func _draw` 派生全量——verdict 表头披露面）：
# projectile_base（拖尾）/mirror_image/arc_slash/ground_axe 内嵌/orbit_field/
# telegraph 内嵌×3（Circle/Line/Fan）/enemy 主+W8 读数+内嵌×5（毒圈/雷/光束/雷区/爆环）/
# player（技能光环+复活弧）/elemental_fx_layer 主+内嵌/game_loop 内嵌（升级爆环）/
# confetti/hurt_indicator/playfield_outline —— 21 wrap 点 13 文件。
const P4_WRAP_LIST := "projectile_base·拖尾 mirror_image arc_slash ground_axe(FX) orbit_field telegraph×3 enemy×6 player elemental_fx_layer×2 game_loop(LevelBurst) confetti hurt_indicator playfield_outline"

var tree: SceneTree
var _gl: GameLoop = null
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _comp: Array[Dictionary] = []
var _cursor: int = 0
var _frame_i: int = 0
var _min_enemies: int = 99999
var _min_bullets: int = 99999
var _phys_frames_start: int = 0
var _arm_active: String = ""
var _s3_hidden: Array[CanvasItem] = []
var _verdict_rows: Array[Dictionary] = []
var _baseline: Dictionary = {}
var _baseline_valid: bool = false
var _base_flush_s: float = 0.0                 # 塌缩判读基线速率（双基线均值——_report_verdict 合成后写入；
var _base_gap_s: float = 0.0                   # _arm_collapse_str 与表行共用同一真源，杜绝双口径漂移）
var _base_phys_s: float = 0.0
var _base_churn_s: float = 0.0
var _h5_adjudicated: bool = false
var _last_state_seen: int = -1                     # 状态看门狗（离 PLAYING 瞬间归档披露）
var _t0_s: float = 0.0                             # 会话时钟基点（diag 波事件/状态迁移时戳）
var _archive_mode: bool = false                    # 修轮 M1：archive=1 → 写归档档（缺省复跑态 postcut）


func run(p_tree: SceneTree, p_archive := false) -> void:
	tree = p_tree
	_archive_mode = p_archive
	seed(20261013)
	print("══ R271 深载台架：敌90 驻场 + 弹448 顶格 + boost 促1 + 600 物理帧/臂 ×（基线+S1-S7+坏臂） ══")
	print("落盘模式：%s" % ("归档（archive=1——已存在即拒写）" if _archive_mode else "复跑态（postcut）"))
	if not _boot():
		await _finish_teardown()
		return
	await _arm("BASE 基线复现臂", {})
	await _arm("S1 桶周转短路（place/unplace 早退）", {"s1": true})
	await _arm("S3 自绘件隐藏（树扫 visible=false）", {"s3": true})
	await _arm("S4 弹 tick 短路", {"s4": true})
	await _arm("S5 跳字拒收", {"s5": true})
	await _arm("S6 全弹清空（逐帧 release 活弹）", {"s6": true})
	await _arm("S7 桶宿主同步环短路", {"s7": true})
	await _arm("S2 敌监控短路（monitoring 批量 false+玩家面惰化）", {"s2": true})
	# R285 P0 增臂（设计 §3.4）：缺省强关（下）保 BASE/S 臂与 R271 postcut 同口径；
	# G0=刀后关态基线 / G1=T1 单独 A/B / G2=T3 单独 A/B / S8=ipµs 份额定谳臂
	await _arm("G0 现状臂（grid_hit_override=0 强关）", {"g0": true})
	await _arm("G1 网格命中臂（grid_hit_override=1 强开——T1 单独 A/B）", {"g1": true})
	await _arm("G2 死亡冲刷臂（death_flush_override=1 grid 关——T3 单独 A/B）", {"g2": true})
	await _arm("S8 ip 双遍历短路臂（shortcircuit_ip_pass——ipµs 份额定谳）", {"s8": true})
	await _arm("S9 ④弹段整段短路臂（shortcircuit_proj_stage——R286 新增：④ 段份额定谳；"
		+ "S4 历史读数作废重测——原臂漏检快路径，真机快N/弹N≈10-17%=83-90% 弹走慢路径外"
		+ " 台架弹多走快路径为空臂）", {"s9": true})
	await _arm("BASE2 基线复测臂（会话漂移对照——塌缩基线取双基线均值）", {})
	await _arm("BAD 坏臂（敌注入数=0——M4 门回归；末位=零敌期波次通关会把状态带离 PLAYING，污染后继臂）", {"bad": true})
	_report_verdict()
	await _finish_teardown()


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


# ── boot ────────────────────────────────────────────────────────────

func _boot() -> bool:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R271Deeprepro"
	tree.root.add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[deeprepro] Boot 失败：%s" % str(_gl.boot_fatal))
		_fail += 1
		return false
	PerfGovernor.set_process(false)
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	PerfGovernor.boost_override = 1              # 促1：85% 保帧深载态（vc79 配置面）
	# R289 夹具迁移：本台架=受控「boost 85 + 敌90 + 弹448」原始负载（跨版本 S1-S7 对照
	# 基准）。R289 起真跑低帧会在 2s 后自动进深载态（敌60/弹200/A 节流；R290 再压到
	# 敌40/弹120），负载被三刀
	# 改写→台架失去对照意义。此处显式钉 deep 关（注入口 0）——深载三刀自证归
	# qa_r289_weaponlod；收尾复位 -1。
	PerfGovernor.deep_override = 0
	# r2 断言面：短路注入口默认零短路（产品行为逐位——pkg0 池面复跑在电池门）
	_check("r2 默认零短路：S1/S4/S5/S7/S9 注入口出厂态 false",
		not TexBucketHost.shortcircuit_place and not TexBucketHost.shortcircuit_sync
			and not ProjectileBase.shortcircuit_tick and not PopupManager.shortcircuit_spawn
			and not GameLoop.shortcircuit_proj_stage
			and not Enemy.CONTACT_RADIAL,
		"place=%s sync=%s tick=%s spawn=%s radial=%s" % [
			TexBucketHost.shortcircuit_place, TexBucketHost.shortcircuit_sync,
			ProjectileBase.shortcircuit_tick, PopupManager.shortcircuit_spawn,
			Enemy.CONTACT_RADIAL])
	_gl.current_map_id = &"world_grove"
	if not _gl.start_run():
		push_error("[deeprepro] start_run 失败")
		_fail += 1
		return false
	# 台架保活（v4 修 BASE2 之死）：促1 长会话（~10 臂×18s）下波次自然推进（清空检测经
	# 臂间空场窗 + hard-cap 叠波双通道）到 grove final_wave=10 → 通关 → GAME_OVER → 后继
	# 臂全灭（v3 复跑 BASE2 物步µs=0/churn=0 即此——会话时长×波推进速率的非确定性竞态）。
	# 钉法实证（v5 diag 日志）：advance_blocked 会被 game_loop._tick_victory_pending 每帧
	# 重写为 victory 窗外的 false——该闸无效（v5 BAD 期 w1→w2→w3 照常开波，BAD 末位无害）；
	# 真正生效的是 ①hard_cap 9999s 永不到点（叠波通道死）+ ②敌 90 驻场跨臂保活（清空检测
	# 的 active==0 永不可达——通关/商店支路全灭）。
	_gl.wave_director.set("_hard_cap_left", 9999.0)
	# 诊断：状态迁移/波事件监听（台架会话内任何离开 PLAYING 的瞬间——归档披露面）
	_t0_s = Time.get_ticks_msec() / 1000.0
	_last_state_seen = int(_gl.state)
	EventBus.wave_started.connect(_on_diag_wave_started)
	EventBus.wave_cleared.connect(_on_diag_wave_cleared)
	_gl.player.set("xp_need", 1.0e12)
	_gl.player.set("max_hp", 1.0e12)
	_gl.player.set("hp", 1.0e12)
	_gl.player.unlocked_slots = 6
	_gl.player.global_position = PLAYER_HOME
	var gatling: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	if gatling == null:
		push_error("[deeprepro] W2 装配失败")
		_fail += 1
		return false
	gatling.level = 5
	for t in [["AFF_PIERCE", 3], ["AFF_MULTI", 2], ["MEC_BOUNCE", 3], ["MEC_KILL_BLAST", 2], ["MEC_FRACTAL", 2]]:
		var td: TraitData = _gl.registry.get_trait(StringName(t[0]))
		for i in range(int(t[1])):
			gatling.attach_trait(td)
	_gl.stage_probe_enabled = true              # 物步µs 减项（段和）需要段探针在账
	# 诊断：节点级加N 直方图（脚本文件:节点名——归因 39.5k+ 敌侧类名的真实来源；
	# 仅台架件自装监听，不动产品面）
	_hist_diag = {}
	tree.node_added.connect(_on_diag_added)
	if not _load_composition():
		return false
	print("boot：grove w16 构成 %d 敌种池，压血×%.2f；W2 L5 五词条；boost_override=1" % [
		_comp.size(), ENEMY_HP_SCALE])
	return true


func _load_composition() -> bool:
	var tbl: Resource = load(GROVE_TABLE)
	if tbl == null or not ("entries" in tbl):
		_fail += 1
		return false
	var entry: Resource = null
	for e in tbl.get("entries"):
		if int(e.get("index")) == 16:
			entry = e
			break
	if entry == null:
		_fail += 1
		return false
	for c in entry.get("composition"):
		var src: EnemyData = _gl.registry.get_enemy(StringName(c.get("enemy_id")))
		if src == null:
			_fail += 1
			return false
		var data: EnemyData = src.duplicate()
		data.hp_base = data.hp_base * ENEMY_HP_SCALE
		var tags := int(c.get("tags", 0))
		for i in range(int(c.get("count", 1))):
			_comp.append({"data": data, "tags": tags})
	_comp.shuffle()
	return true


# ── 逐物理帧回调（tree.physics_frame） ──────────────────────────────

func _on_diag_wave_started(p_wave: int) -> void:
	print("  [diag] wave_started w%d（会话时钟 %.1fs）" % [p_wave, Time.get_ticks_msec() / 1000.0 - _t0_s])


func _on_diag_wave_cleared(p_wave: int) -> void:
	print("  [diag] wave_cleared w%d（会话时钟 %.1fs）" % [p_wave, Time.get_ticks_msec() / 1000.0 - _t0_s])


func _kite() -> void:
	var ang := float(_frame_i) * 0.35 / 60.0
	_gl.player.global_position = Vector2(360.0 + cos(ang) * 140.0,
		660.0 + sin(ang) * 200.0)


func _spawn_one() -> void:
	var c: Dictionary = _comp[_cursor % _comp.size()]
	_cursor += 1
	var e := (_gl.pools[&"enemy"] as EnemyPool).acquire() as Enemy
	if e == null:
		return
	e.bucket_host = (_gl.pools[&"enemy"] as EnemyPool).bucket_host
	e.spawn(c["data"], 16, int(c["tags"]))
	e.global_position = Vector2(randf() * 680.0 + 20.0, randf() * 1180.0 + 40.0)
	_gl.spawner.active.append(e)


func _topup_enemies() -> void:
	var alive: int = _gl.spawner.active.size()
	var want: int = mini(TOPUP_PER_FRAME, HOLD - alive)
	for i in range(want):
		_spawn_one()


func _inject_filler_bullet() -> void:
	# 池直注填充弹（设计 §3.2「真开火通道或池直注二选一」——顶格到 448 的补位通道）：
	# 依赖注入照 ballistic_weapon._inject_projectile_deps 同款四字段；0 伤快照（负载面
	# =弹 tick/网格查询/结算派发，杀敌面留给真开火通道——敌驻场稳定性优先）
	var pool: ProjectilePool = _gl.pools[&"projectile"] as ProjectilePool
	var pb: ProjectileBase = pool.acquire(0)
	if pb == null:
		return
	pb.damage_pipeline = _gl.pipeline
	pb.enemy_grid = _gl.enemy_grid
	pb.pool = pool
	pb.elemental = _gl.elemental
	# v2 修订：环带布点（风筝轨道外圈 r∈[320,380]——敌群贴玩家追逐，环带命中面≈0；
	# 首版全场随机布点 0 伤命中风暴 → 闪白换桶 reparent ~8000/s，非 vc79 形态）
	var ang := randf() * TAU
	var r := randf_range(320.0, 380.0)
	pb.spawn({
		"position": Vector2(clampf(360.0 + cos(ang) * r, 16.0, 704.0),
			clampf(660.0 + sin(ang) * r, 16.0, 1264.0)),
		"velocity": Vector2.from_angle(randf() * TAU) * randf_range(2.0, 12.0),
		"lifetime": 9.0, "pierce": 24, "bounces": 0,
		"hitbox_radius": 2.0, "team": 0,
	})


func _on_phys_frame() -> void:
	_frame_i += 1
	if int(_gl.state) != _last_state_seen:
		_last_state_seen = int(_gl.state)
		print("  [diag] state→%d @%s 帧%d（会话时钟 %.1fs）" % [
			_last_state_seen, _arm_active, _frame_i, Time.get_ticks_msec() / 1000.0 - _t0_s])
	_kite()
	if _arm_active.begins_with("BAD"):
		pass                                   # 坏臂：零敌注入（启动期一次性排空见 _arm；M4 门①必败——r4 回归）
	else:
		_topup_enemies()
	if _arm_active.begins_with("S6"):
		for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles().duplicate():
			(_gl.pools[&"projectile"] as ObjectPool).release(p)
	elif not _arm_active.begins_with("BAD"):
		var pool: ProjectilePool = _gl.pools[&"projectile"] as ProjectilePool
		var want := mini(TARGET_BULLETS - pool.total_active(), 24)
		for i in range(want):
			_inject_filler_bullet()
	if _arm_active.begins_with("S2"):
		_s2_tick()
	if _arm_active.begins_with("S3") and _frame_i % 30 == 0:
		_s3_apply()                       # v2：新生自绘件周期重罩（telegraph/受击指示等）
	if _frame_i % 60 == 0:
		_min_enemies = mini(_min_enemies, _gl.spawner.active.size())
		_min_bullets = mini(_min_bullets, (_gl.pools[&"projectile"] as ProjectilePool).total_active())


func _s2_tick() -> void:
	# S2 面：已建敌 HitArea monitoring 批量置 false（spawn 后置位——设计二选一之①）
	for e in _gl.spawner.active:
		var ha: Area2D = e.get("_hit_area")
		if ha != null and ha.monitoring:
			ha.monitoring = false
	var pl: Area2D = _gl.player
	pl.collision_layer = 0
	pl.monitoring = false
	pl.monitorable = false


# ── 臂执行 ──────────────────────────────────────────────────────────

func _set_arm_flags(p_cfg: Dictionary) -> void:
	_skip_marks = {
		"s1": int(TexBucketHost.place_skip_count), "s4": int(ProjectileBase.tick_skip_count),
		"s5": int(PopupManager.spawn_reject_count), "s7": int(TexBucketHost.sync_skip_count),
		"g": int(GameLoop.hit_pairs_flushed), "gd": int(GameLoop.deaths_flushed),
	}
	TexBucketHost.shortcircuit_place = bool(p_cfg.get("s1", false))
	TexBucketHost.shortcircuit_sync = bool(p_cfg.get("s7", false))
	ProjectileBase.shortcircuit_tick = bool(p_cfg.get("s4", false))
	PopupManager.shortcircuit_spawn = bool(p_cfg.get("s5", false))
	# R285 G 臂注入口（缺省强关——BASE/S 臂与 R271 postcut 历史口径可比；G/S8 臂各自翻旗）
	GameLoop.grid_hit_override = 0
	GameLoop.death_flush_override = 0
	GameLoop.shortcircuit_ip_pass = false
	GameLoop.shortcircuit_proj_stage = false   # R286 S9：④弹段整段短路（缺省强关）
	if p_cfg.has("g0"):
		GameLoop.grid_hit_override = 0
	if p_cfg.has("g1"):
		GameLoop.grid_hit_override = 1
	if p_cfg.has("g2"):
		GameLoop.death_flush_override = 1
	if p_cfg.has("s8"):
		GameLoop.shortcircuit_ip_pass = true
	if p_cfg.has("s9"):
		GameLoop.shortcircuit_proj_stage = true


func _clear_arm_flags() -> void:
	_set_arm_flags({})
	# S2 复位（双向——池复用实例的 monitoring 残留防跨臂污染）
	for e in _gl.spawner.active:
		var ha: Area2D = e.get("_hit_area")
		if ha != null:
			ha.monitoring = true
	var pool: EnemyPool = _gl.pools[&"enemy"] as EnemyPool
	for i in range(pool.get_child_count()):
		var c := pool.get_child(i)
		if c is Enemy:
			var raw: Variant = c.get("_hit_area")
			if raw is Area2D:
				(raw as Area2D).monitoring = true
	var pl: Area2D = _gl.player
	pl.collision_layer = 3
	pl.monitoring = true
	pl.monitorable = true


func _s3_apply() -> void:
	# S3：树扫全部「脚本带 _draw 的 CanvasItem」visible=false（泛化自绘面罩——本构筑
	# 无自绘武器件；含 playfield_outline/telegraph 族/fx 件——逻辑照跑）
	_walk_hide(tree.root)


func _walk_hide(p_node: Node) -> void:
	if p_node is CanvasItem and p_node.has_method(&"_draw"):
		if (p_node as CanvasItem).visible:
			_s3_hidden.append(p_node)
			(p_node as CanvasItem).visible = false
	for c in p_node.get_children():
		_walk_hide(c)


func _clear_field() -> void:
	# v4：敌 90 驻场跨臂保活（臂间空场窗=清空检测→wave_cleared→通关竞态的入口，消除；
	# 敌状态由产品流转自管，臂特异面——S2 monitoring/S3 可见性——由 _clear_arm_flags 与
	# _s3_hidden 复位各自收口）。本函数只清弹/碎片等短命面。
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles().duplicate():
		(_gl.pools[&"projectile"] as ObjectPool).release(p)
	for s in (_gl.active_shards as Array).duplicate():
		(_gl.pools[&"xp"] as XPPool).release(s)
	_gl.active_shards.clear()


func _read_window(p_wall_s: float) -> Dictionary:
	var mon := int(DebugStats._diag_phys_mon_us)
	var gd := int(DebugStats._diag_phys_gd_us)
	var samples := int(DebugStats._diag_phys_samples)
	var phys_mean_us := maxi(mon - gd, 0) / maxi(samples, 1)
	return {
		"flush": int(DebugStats.diag_bucket_window_us(&"flush")),
		"gap": int(DebugStats._diag_gap_us),
		"step": int(DebugStats._diag_step_us),
		"early": int(DebugStats.diag_bucket_window_us(&"flush_early")),
		"render_flush": int(DebugStats.diag_bucket_window_us(&"flush_render")),
		"draw": int(DebugStats.diag_bucket_window_us(&"draw")),
		"added": int(DebugStats._diag_node_added),
		"removed": int(DebugStats._diag_node_removed),
		"phys_mean_us": phys_mean_us,
		"phys_samples": samples,
		"wall_s": maxf(p_wall_s, 0.001),
	}


func _arm(p_label: String, p_cfg: Dictionary) -> void:
	print("── %s ──" % p_label)
	_arm_active = p_label.split(" ")[0]
	_gl.wave_director.set("_hard_cap_left", 9999.0)  # v4 保活复钉（advance_blocked 无效——见 _boot 注）
	if int(_gl.state) != GameConst.GameStatus.PLAYING:
		print("  [警报] 臂启动时 state=%d ≠ PLAYING——本臂读数不可判读（看门狗时戳见上）" % int(_gl.state))
	if _arm_active == "BAD":
		# v4：敌跨臂保活后坏臂须一次性排空（同步块内无并发击杀——重复归还风暴免疫，
		# R253/R259 纪律；逐帧排空会与产品击杀释放竞态双释放，首版实测被拒收风暴证伪）
		for e in _gl.spawner.active.duplicate():
			_gl.elemental.unregister_host(e)
			(_gl.pools[&"enemy"] as EnemyPool).release(e)
		print("  坏臂排空：释放活敌 %d" % _gl.spawner.active.size())
		_gl.spawner.active.clear()
	_set_arm_flags(p_cfg)
	if p_cfg.has("s3"):
		_s3_hidden.clear()
		_s3_apply()
	# 预热（含 S3 隐藏面/短路面全展开后的稳态）
	_frame_i = 0
	var cb := Callable(self, "_on_phys_frame")
	tree.physics_frame.connect(cb)
	for i in range(WARMUP_FRAMES):
		await tree.physics_frame
	# 测量窗：1Hz 采样门推离（秒窗累计器直读全窗值）；R271 窗复位+隙界清位
	DebugStats._diag_last_ms = Time.get_ticks_msec() + 10000000
	DebugStats._diag_reset_window_acc()
	_gl.diag_reset_stage_win_sums()          # R286：段窗和臂内定界（防跨臂累计污染披露读数）
	DebugStats._diag_gap_mark_us = -1
	_min_enemies = 99999
	_min_bullets = 99999
	var t0 := Time.get_ticks_usec()
	_phys_frames_start = Engine.get_physics_frames()
	for i in range(MEASURE_FRAMES):
		await tree.physics_frame
	var wall_s := (Time.get_ticks_usec() - t0) / 1000000.0
	var w := _read_window(wall_s)
	DebugStats._diag_last_ms = Time.get_ticks_msec()       # 采样门复位（恢复 1Hz 语义）
	var phys_adv := Engine.get_physics_frames() - _phys_frames_start
	var valid := _m4_gate(w, phys_adv, p_label)
	_verdict_rows.append({"label": p_label, "w": w, "valid": valid,
		"min_enemies": _min_enemies, "min_bullets": _min_bullets,
		"phys_adv": phys_adv})
	_arm_effect_check(p_label)
	# 收臂：复位短路面/可见面/清场
	tree.physics_frame.disconnect(cb)
	_clear_arm_flags()
	for ci in _s3_hidden:
		# 修轮 M2（评审 M2/QA DEF-1 同源探针坐实）：只复活仍在测量的活口件——已归池件
		# （测量期内击杀/到期 release）保持池态 visible=false；原无条件 visible=true 会把
		# 空闲栈件点亮，后继臂 acquire 时 _assert_clean 刷「池污染」ERROR 风暴。池根/留桶
		# （V-C1 lazy）两形态统一以池空闲标记 meta 为真源（ObjectPool._META_IN_POOL）。
		if is_instance_valid(ci) and not _is_pooled_idle(ci):
			ci.visible = true
	_s3_hidden.clear()
	_clear_field()
	await tree.process_frame
	await tree.process_frame


func _is_pooled_idle(p_node: Node) -> bool:
	# 池空闲栈成员标记直读（真源=release/acquire 维护的 meta——树形态无关）
	return bool(p_node.get_meta(ObjectPool._META_IN_POOL, false))


var _skip_marks: Dictionary = {}                 # r2 短路计数基线（臂前快照）
var _hist_diag: Dictionary = {}                  # 诊断直方图（脚本:名 → 计数）


func _on_diag_added(p_node: Node) -> void:
	var s: Script = p_node.get_script()
	var key := p_node.get_class()
	if s != null and not s.resource_path.is_empty():
		key = "%s:%s" % [s.resource_path.get_file(), p_node.name]
	_hist_diag[key] = int(_hist_diag.get(key, 0)) + 1


func _dump_hist_diag() -> void:
	var keys: Array = _hist_diag.keys()
	keys.sort()
	var top: Array = []
	for k in keys:
		top.append({"k": k, "n": int(_hist_diag[k])})
	top.sort_custom(func(a, b):
		if int(a["n"]) != int(b["n"]):
			return int(a["n"]) > int(b["n"])
		return String(a["k"]) < String(b["k"]))
	var parts: Array[String] = []
	for i in range(mini(14, top.size())):
		parts.append("%s=%d" % [str(top[i]["k"]), int(top[i]["n"])])
	print("加N 节点级直方图 top-14：" + " | ".join(parts))


func _arm_effect_check(p_label: String) -> void:
	# r2 短路臂可控断言（设计 §5-r2「注入各自短路生效——对应计数键/池态断言归零或骤降」）
	var lbl := p_label.split(" ")[0]
	match lbl:
		"S1":
			var d := int(TexBucketHost.place_skip_count) - int(_skip_marks.get("s1", 0))
			_check("r2 S1 注入生效：place/unplace 早退计数 >0（桶µs 归零面）", d > 0, "skip=%d" % d)
			var bucket_us := int(DebugStats.diag_bucket_window_us(&"bucket"))
			_check("r2 S1 池态断言：桶µs 短路后骤降（<1000µs/窗）", bucket_us < 1000, "桶µs=%d" % bucket_us)
		"S3":
			_check("r2 S3 注入生效：树扫自绘件隐藏非空（重罩含新生件）", _s3_hidden.size() > 0,
				"hidden=%d" % _s3_hidden.size())
		"S4":
			var d4 := int(ProjectileBase.tick_skip_count) - int(_skip_marks.get("s4", 0))
			# R286 修臂强化：漏检快路径后 >0 弱断言无法区分「部分跳过」与「全跳过」
			#（历史假绿根因）——补弹存活面（tick 体全跳=无寿命/超程回收，弹冻结存活）。
			_check("r2 S4 注入生效：弹 tick 早退计数 >0（快/慢路径全计入——R286 修臂）",
				d4 > 0, "skip=%d" % d4)
			_check("r2 S4 池态断言：tick 体全跳下弹冻结存活（弹min ≥420）",
				_min_bullets >= BULLET_FLOOR, "弹min=%d" % _min_bullets)
		"S5":
			var d5 := int(PopupManager.spawn_reject_count) - int(_skip_marks.get("s5", 0))
			_check("r2 S5 注入生效：跳字拒收计数 >0（活跳字骤降）", d5 > 0, "reject=%d" % d5)
			_check("r2 S5 池态断言：测量末活跳字 ≈0", int(_gl.diag_counts()[&"popups"]) == 0,
				"popups=%d" % int(_gl.diag_counts()[&"popups"]))
		"S6":
			_check("r2 S6 池态断言：活弹骤降（<50 驻场）", _min_bullets < 50, "弹min=%d" % _min_bullets)
		"S7":
			var d7 := int(TexBucketHost.sync_skip_count) - int(_skip_marks.get("s7", 0))
			_check("r2 S7 注入生效：同步环早退计数 >0", d7 > 0, "skip=%d" % d7)
		"S2":
			var enemy_off := true
			for e in _gl.spawner.active:
				var ha: Area2D = e.get("_hit_area")
				if ha != null and ha.monitoring:
					enemy_off = false
					break
			_check("r2 S2 注入生效：活敌 HitArea monitoring 全 false ∧ 玩家面惰化",
				enemy_off and not _gl.player.monitoring and _gl.player.collision_layer == 0,
				"敌off=%s 玩家monitoring=%s layer=%d" % [enemy_off, _gl.player.monitoring, _gl.player.collision_layer])
		"G0":
			# R285：强关臂——冲刷对数零增量 ∧ 命/结µs 窗零累计（段不存在）
			var d0 := int(GameLoop.hit_pairs_flushed) - int(_skip_marks.get("g", 0))
			var hf0 := int(DebugStats.diag_bucket_window_us(&"hit_flush"))
			_check("r2 G0 注入生效：网格命中强关（冲刷对数零增量 ∧ 结µs 零累计）",
				d0 == 0 and hf0 == 0, "对数+%d 结µs=%d" % [d0, hf0])
		"G1":
			# R285：强开臂——T1 生效（冲刷对数增量 >0 ∧ 命/结µs 在账）
			var d1 := int(GameLoop.hit_pairs_flushed) - int(_skip_marks.get("g", 0))
			var hc1 := int(DebugStats.diag_bucket_window_us(&"hit_collect"))
			var hf1 := int(DebugStats.diag_bucket_window_us(&"hit_flush"))
			_check("r2 G1 注入生效：网格命中强开（冲刷对数增量 >0 ∧ 命/结µs 在账）",
				d1 > 0 and hc1 > 0 and hf1 > 0, "对数+%d 命µs=%d 结µs=%d" % [d1, hc1, hf1])
		"G2":
			# R285：T3 单独臂——死亡冲刷增量 >0 ∧ 网格门仍关（冲刷对数零增量）
			var dd := int(GameLoop.deaths_flushed) - int(_skip_marks.get("gd", 0))
			var d2 := int(GameLoop.hit_pairs_flushed) - int(_skip_marks.get("g", 0))
			_check("r2 G2 注入生效：死亡冲刷强开（冲刷死亡数增量 >0 ∧ 网格门仍关）",
				dd > 0 and d2 == 0, "死冲+%d 对数+%d" % [dd, d2])
		"S8":
			# R285：ip 短路臂——注入口在账；ipµs 窗读数披露（headless 关态双遍历本近零，
			# 份额定谳以本读数为准——全零=ip 非主源，如实登记不硬编归因）
			var ip_us := int(DebugStats.diag_bucket_window_us(&"ip_pass"))
			_check("r2 S8 注入生效：ip 双遍历短路在账", GameLoop.shortcircuit_ip_pass,
				"ipµs=%d（窗内读数披露——headless 关态双遍历本近零，份额定谳以本读数为准）" % ip_us)
		"S9":
			# R286：④弹段整段短路臂——弹冻结全存活（无寿命/超程/出界回收）∧ 注入口在账。
			# ④ 份额定谳走 verdict 表 步µs/s 塌缩列（G0/BASE 双基线 vs S9）——不在此断言。
			var alive9 := 0
			for p9 in _gl._projectile_pool.active_projectiles():
				var pb9 := p9 as ProjectileBase
				if pb9 != null and pb9.team == 0:
					alive9 += 1
			_check("r2 S9 注入生效：④弹段整段短路在账（弹冻结存活 ≥420）",
				GameLoop.shortcircuit_proj_stage and alive9 >= BULLET_FLOOR,
				"活弹=%d（份额定谳看 verdict 步µs/s 塌缩列）" % alive9)


func _m4_gate(p_w: Dictionary, p_phys_adv: int, p_label: String) -> bool:
	# M4 有效性前置门（设计 §3.2〔v2·必改 M4〕——**基线臂判 H5 的先决条件**；短路臂
	# 用 arm_gate（负载检查——短路本身就是要砸掉某类负载，M4 全键门对短路臂语义错置））：
	# ①r1 量级断言（敌 ≥85 ∧ team-0 活弹 ≥420 池直读）；②物步µs ≥40k/s 或 加N+摘N
	# ≥50/s（vc79 深载带）；③驱动期无静默异常（物理帧推进 ≥590/600 + 敌活口 >0——
	# headless 无脚本错误计数 API，以此代理并披露）
	if p_label.begins_with("BAD"):
		return false                             # 坏臂：构造性无效（r4 断言用）
	if not p_label.begins_with("BASE"):
		return _arm_gate(p_phys_adv)
	var g1 := _min_enemies >= ENEMY_FLOOR and _min_bullets >= BULLET_FLOOR
	var phys_per_s := float(p_w["phys_mean_us"]) * float(p_w["phys_samples"]) / float(p_w["wall_s"])
	var churn_per_s := (float(p_w["added"]) + float(p_w["removed"])) / float(p_w["wall_s"])
	var g2 := phys_per_s >= 40000.0 or churn_per_s >= 50.0
	var g3 := p_phys_adv >= MEASURE_FRAMES - 10 and _min_enemies > 0 		and int(_gl.state) == GameConst.GameStatus.PLAYING
	var ok := g1 and g2 and g3
	if not ok:
		print("  [M4 门] 台架无效：g1敌/弹=%s（敌min=%d 弹min=%d） g2量级=%s（物步µs/s=%.0f 周转/s=%.0f） g3驱动=%s（物理帧+%d state=%d）"
			% [g1, _min_enemies, _min_bullets, g2, phys_per_s, churn_per_s, g3, p_phys_adv, int(_gl.state)])
	return ok


func _arm_gate(p_phys_adv: int) -> bool:
	# 短路臂负载检查（v2 修订）：驱动完整（物理帧推进）∧ 敌驻场活（≥85——塌缩比较的
	# 负载底座必须在场）；弹面豁免（S6 短路本义=弹存在性归零——g1 弹下限对短路臂语义
	# 错置，S4 弹仍在场由 弹min 读数披露）。失败=该臂「负载失真」退出塌缩判读（披露）。
	var ok := p_phys_adv >= MEASURE_FRAMES - 10 and _min_enemies >= ENEMY_FLOOR
	if not ok:
		print("  [arm 门] 负载失真：驱动物理帧+%d 敌min=%d（退出塌缩判读）" % [p_phys_adv, _min_enemies])
	return ok


# ── verdict 判读（§3.2） ────────────────────────────────────────────

func _collapse(p_base: float, p_arm: float) -> float:
	if p_base <= 0.0:
		return 0.0
	return clampf((p_base - p_arm) / p_base, 0.0, 1.0)


func _per_s(p_v: float, p_w: Dictionary) -> float:
	return float(p_v) / float(p_w["wall_s"])


func _rate_flush(p_w: Dictionary) -> float:
	return float(p_w["flush"]) / float(p_w["wall_s"])


func _rate_gap(p_w: Dictionary) -> float:
	return float(p_w["gap"]) / float(p_w["wall_s"])


func _rate_phys(p_w: Dictionary) -> float:
	# 物步µs 每秒总量 = 末步均值 × 活跃采样帧数 ÷ 墙钟秒
	return float(p_w["phys_mean_us"]) * float(p_w["phys_samples"]) / float(p_w["wall_s"])


func _report_verdict() -> void:
	print("══ verdict 表（判读规则 §3.2：塌缩 ≥60% 坐实；全臂不塌+基线过门+基线延µs<5k → H5） ══")
	var lines: Array[String] = []
	if _archive_mode:
		lines.append("# R271 headless 深载台架 verdict（2026-10-14 归档）")
	else:
		lines.append("# R271 headless 深载台架 复跑（2026-10-14 R271-postcut）")
		lines.append("")
		lines.append("- V-C 半执行注记：C1 已落地（本表为刀后复跑）；C2 经 R269 台架证不必要（boost 态 Telegraph/DeathPop 零创建）。")
	lines.append("")
	lines.append("- 复现口径：敌 90 驻场（grove w16 压血×0.3+补位 8/帧，跨臂保活——v4 波钉死防通关竞态）+ team-0 活弹 448 顶格（W2 L5 五词条真开火 + 池直注填充）+ boost_override=1（促1）+ 引擎原生物理步 %d 帧/臂（预热 %d）。" % [MEASURE_FRAMES, WARMUP_FRAMES])
	lines.append("- P4 绘µs wrap 清单（21 wrap 点 13 文件，grep `func _draw` 派生全量）：%s" % P4_WRAP_LIST)
	lines.append("- headless 通道先验：哨兵/绘µs 通道在 headless 有值（stepacct p1/p4 实证——_draw 经 queue_redraw 在哑渲染服下仍派发）；呈帧N/渲ms/dc 真机专属。")
	# 双基线合成（BASE 首测 + BASE2 会话尾测——塌缩基线取均值；drift=会话漂移披露）
	var bases: Array[Dictionary] = []
	_baseline_valid = true
	for row in _verdict_rows:
		if String(row["label"]).begins_with("BASE"):
			bases.append(row["w"])
			if not bool(row["valid"]):
				_baseline_valid = false
	var base: Dictionary = {}
	var base_flush_s := 0.0
	var base_gap_s := 0.0
	var base_phys_s := 0.0
	var base_churn_s := 0.0
	var base_flush_total := 0.0
	var base_draw_total := 0.0
	if not bases.is_empty():
		# v4 修正：速率类（延/隙/物步/加摘 per_s）=各基线速率的算术均值；总量类（窗口累计
		# flush/draw——H3 占比分子分母同窗口口径）=均值。旧 SUM 合成把速率类翻倍（S2/S7
		# 并集塌缩系统性虚高、复现度 物步µs 假读 266k）——塌缩判读单一真源=以下四速率+二总量。
		var nb := float(bases.size())
		for bw in bases:
			base_flush_s += _rate_flush(bw)
			base_gap_s += _rate_gap(bw)
			base_phys_s += _rate_phys(bw)
			base_churn_s += _per_s(float(bw["added"]) + float(bw["removed"]), bw)
			base_flush_total += float(bw["flush"])
			base_draw_total += float(bw["draw"])
		base_flush_s /= nb
		base_gap_s /= nb
		base_phys_s /= nb
		base_churn_s /= nb
		base_flush_total /= nb
		base_draw_total /= nb
		base = bases[0].duplicate()               # 展示面引用窗（速率读数一律以上方均值为准）
		_base_flush_s = base_flush_s
		_base_gap_s = base_gap_s
		_base_phys_s = base_phys_s
		_base_churn_s = base_churn_s
	if bases.size() > 1:
		var f1 := _per_s(bases[0]["flush"], bases[0])
		var f2 := _per_s(bases[1]["flush"], bases[1])
		var drift := absf(f1 - f2) / maxf(f1, 1.0)
		var drift_txt := "容差内=可靠" if drift <= 0.3 else "**超容差——塌缩判读降权，工单：重跑台架**"
		print("  基线漂移：BASE1 延µs/s=%.1fk → BASE2 %.1fk（drift=%.0f%%——%s）" % [
			f1 / 1000.0, f2 / 1000.0, drift * 100.0, drift_txt])
		lines.append("- 基线漂移：BASE1 延µs/s=%.1fk → BASE2=%.1fk（drift=%.0f%%——%s；塌缩基线=双基线均值）。" % [
			f1 / 1000.0, f2 / 1000.0, drift * 100.0, drift_txt])
	# 复现度披露（vc79 带：延µs 100k-346k/s、物步µs 43-110k/s）
	var repro_note := "复现度：基线 延µs=%.0fk/s、物步µs=%.0fk/s、加摘=%.0f/s（vc79 真机带：延µs 100-346k/s、物步µs 43-110k/s）" % [
		base_flush_s / 1000.0, base_phys_s / 1000.0, base_churn_s]
	if base_flush_s < 10000.0 or base_phys_s < 4000.0:
		repro_note += " ——**复现度低（差一个量级以上），H5 概率上移**（§3.2 披露规则）"
	lines.append("- " + repro_note)
	lines.append("- 加N 类直方图 top-8（会话累计 node_added；注：reparent 亦触发 node_added/node_removed——加N/摘N 含桶 place/unplace 再入树，台架 Array 计数探针实证）：")
	lines.append("")
	var hkeys: Array = DebugStats._diag_added_hist.keys()
	hkeys.sort()
	var htop: Array = []
	for k in hkeys:
		htop.append({"cls": k, "n": int(DebugStats._diag_added_hist[k])})
	htop.sort_custom(func(a, b):
		if int(a["n"]) != int(b["n"]):
			return int(a["n"]) > int(b["n"])
		return String(a["cls"]) < String(b["cls"]))
	for i in range(mini(8, htop.size())):
		lines.append("  - %s = %d" % [str(htop[i]["cls"]), int(htop[i]["n"])])
	lines.append("| 臂 | 延µs/s | 隙µs/s | 步µs/s | 物步µs/s | 加N/s | 摘N/s | 绘µs/s | 延塌缩 | 延∪隙∪物步塌缩 | 敌min | 弹min | M4门 |")
	lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
	var any_collapse := false
	var collapse_arms: Array[String] = []
	for row in _verdict_rows:
		var w: Dictionary = row["w"]
		var lbl := String(row["label"]).split(" ")[0]
		var flush_s := _per_s(w["flush"], w)
		var gap_s := _per_s(w["gap"], w)
		var step_s := _per_s(w["step"], w)
		var phys_s := float(w["phys_mean_us"]) * float(w["phys_samples"]) / float(w["wall_s"])
		var add_s := _per_s(w["added"], w)
		var rem_s := _per_s(w["removed"], w)
		var draw_s := _per_s(w["draw"], w)
		var c_flush := _collapse(base_flush_s, flush_s)
		var c_union := maxi(maxi(
			int(round(_collapse(base_flush_s, flush_s) * 100.0)),
			int(round(_collapse(base_gap_s, gap_s) * 100.0))),
			int(round(_collapse(base_phys_s, phys_s) * 100.0)))
		# 臂 valid=arm_gate（负载检查——驱动完整∧敌驻场）；BASE/BAD=完整 M4 门
		if not base.is_empty() and bool(row["valid"]):
			var arm_c := c_flush >= 0.6
			if lbl == "S2":
				arm_c = float(c_union) / 100.0 >= 0.6
			if arm_c:
				any_collapse = true
				collapse_arms.append(lbl)
		lines.append("| %s | %.1fk | %.1fk | %.1fk | %.1fk | %.0f | %.0f | %.1fk | %.0f%% | %d%% | %d | %d | %s |" % [
			lbl, flush_s / 1000.0, gap_s / 1000.0, step_s / 1000.0, phys_s / 1000.0,
			add_s, rem_s, draw_s / 1000.0, c_flush * 100.0, c_union,
			int(row["min_enemies"]), int(row["min_bullets"]),
			"过" if bool(row["valid"]) else ("台架无效" if String(row["label"]).begins_with("BASE") or String(row["label"]).begins_with("BAD") else "负载失真")])
		print("  %-5s 延µs/s=%8.1fk 隙µs/s=%8.1fk 步µs/s=%7.1fk 物步µs/s=%8.1fk 加/s=%5.0f 摘/s=%5.0f 绘µs/s=%7.1fk 塌缩延=%3.0f%% 并集=%3d%% M4=%s" % [
			lbl, flush_s / 1000.0, gap_s / 1000.0, step_s / 1000.0, phys_s / 1000.0,
			add_s, rem_s, draw_s / 1000.0, c_flush * 100.0, c_union,
			"过" if bool(row["valid"]) else ("无效" if String(row["label"]).begins_with("BASE") or String(row["label"]).begins_with("BAD") else "失真")])
	lines.append("")
	# H1-H5 判读行
	var h_lines: Array[String] = []
	if not _baseline_valid:
		h_lines.append("- **基线臂未过 M4 有效性门 → 台架无效：禁止判 H5、A 轴不得按 V-D 免做**（§3.2〔v2·必改 M4〕——本表本身是 P 轨修台架的工单而非结论）。")
	else:
		h_lines.append("- H1 窗口结构性（哨兵窗含引擎物理服步）：隙µs=%.1fk/s vs 延µs=%.1fk/s ——隙为主载=%s（隙≫延 → 引擎物理相位工作为主，A 轴刀应看物步µs/隙µs 面）。" % [
			base_gap_s / 1000.0, base_flush_s / 1000.0,
			"是" if base_gap_s > base_flush_s * 2.0 else "否"])
		var s2c := _arm_union_collapse_pct("S2")
		var s3c := _arm_flush_collapse_pct("S3")
		var s1c := _arm_flush_collapse_pct("S1")
		var s5c := _arm_flush_collapse_pct("S5")
		var draw_ratio := base_draw_total / maxf(base_flush_total, 1.0) * 100.0
		var s1_churn_c := _arm_churn_collapse_pct("S1")
		var s1_corr := s1_churn_c >= 60 and s1c >= 30   # 相关性可测化：S1 短路恰好是加摘源——
		# 加摘塌缩 ≥60% ∧ 延µs 同塌 ≥30% = 加摘与延µs 相关的台架证据（§3.3 V-C 判据②）
		var va := s2c >= 60
		var vb := s3c >= 50 or draw_ratio >= 40.0
		var vc := s1c >= 50 or s5c >= 50 or (base_churn_s > 600.0 and s1_corr)
		h_lines.append("- H2 物理监控事件（90 敌 Area2D monitoring）：S2 塌缩=%d%%；V-A 触发（并集 ≥60%%）=%s。" % [
			s2c, "是" if va else "否"])
		h_lines.append("- H3 queue_redraw 自绘链：S3 塌缩=%d%%；绘µs/延µs=%.0f%%；V-B 触发（S3 ≥50%% 或占比 ≥40%%）=%s。" % [
			s3c, draw_ratio, "是" if vb else "否"])
		h_lines.append("- H4 池周转树进出：S1 塌缩=%d%%、S5 塌缩=%d%%；加N+摘N=%.0f/s（>600/s 闸=%s；S1 加摘塌缩=%d%% → 相关性判据=%s）；V-C 触发=%s。" % [
			s1c, s5c, base_churn_s, "过" if base_churn_s > 600.0 else "未过", s1_churn_c,
			"坐实" if s1_corr else "未坐实", "是" if vc else "否"])
		if any_collapse:
			_h5_adjudicated = true
			h_lines.append("- H5 设备渲染邻接：**不成立**（短路臂已坐实模拟侧来源：%s——台架可定谳面优先于 H5）。" % "、".join(collapse_arms))
		elif base_flush_s < 5000.0:
			_h5_adjudicated = true
			h_lines.append("- H5 设备渲染邻接：**坐实（V-D 档）**——全臂不塌缩 ∧ 基线过 M4 门 ∧ 基线延µs<5k/s（实测 %.1fk/s）。A 轴按 V-D 走：游戏侧无刀可下，登记引擎/设备侧墙钟，预算转 B 轴（vc81 复核）。" % (base_flush_s / 1000.0))
		else:
			_h5_adjudicated = true
			h_lines.append("- H5：**不坐实也不排除**——全臂不塌缩但基线延µs=%.1fk/s ≥5k/s（模拟侧残差仍在，短路矩阵未覆盖其来源；结合隙µs/物步µs 读数与 vc81 真机键复核，禁止直接按 V-D 免做 A 轴）。" % (base_flush_s / 1000.0))
		h_lines.append("- **刀单宣告（§3.3 触发判据逐档）**：V-A=%s；V-B=%s；V-C=%s；V-D=%s。未触发档=登记不动刀（cutAB 按 §5-a1 记判据读数跳过），触发档=开刀序 per §3.3。" % [
			"触发" if va else "未触发（登记）", "触发" if vb else "未触发（登记）",
			"触发" if vc else "未触发（登记）",
			"触发（全臂不塌+基线过门+延µs<5k）" if (not any_collapse and base_flush_s < 5000.0) else "未触发"])
		# B1 敌侧三候选判读行（§3.4-B1：本批=判据行，刀本体 vc81 按真机键触发）
		var s7c := _arm_flush_collapse_pct("S7")
		h_lines.append("- B1 候选① MM 排除面本体（boss/elite/bastion 逐敌 Sprite）：台架构成=90 杂兵驻场（无 elite/boss 波段）→ **台架不可定谳**，待 vc81 敌波段/杂兵波段 dc 分段账。")
		h_lines.append("- B1 候选② MM 每帧同步 idle：S7 短路（同步环早退）延µs 塌缩=%d%%%s（<60%% → 台架不坐实；刀向=脏标/30Hz 量化同步，vc81 复核）。" % [
			s7c, "——塌缩坐实" if s7c >= 60 else ""])
		h_lines.append("- B1 候选③ 填充率：headless 无渲染不可测 → **待 B-0 三键制定谳**（呈帧N 铁证）后重查。")
		h_lines.append("- B-0 渲ms 语义（判据 A/B'）：真机三键专属（vc81），台架不含渲染轴读数。")
	for h in h_lines:
		lines.append(h)
		print("  " + h)
	# 落盘（修轮 M1：路径参化——archive=1 写归档且拒覆写已存在；R287 修轮【评审 #1/
	# DEF-QA-002 复发】：postcut 复跑缺省改道痕档——docs/qa/ 归档证据永不被 bench 覆写）
	var out_path := VERDICT_PATH if _archive_mode else POSTCUT_PATH
	var wrote := false
	if _archive_mode and FileAccess.file_exists(VERDICT_PATH):
		print("  归档已存在，如需重归档先人工移走（本跑继续、不写档）：%s" % VERDICT_PATH)
	else:
		if not _archive_mode and FileAccess.file_exists(POSTCUT_PATH):
			out_path = POSTCUT_RERUN_PATH
			print("  postcut 已存在（R272 追记制归档证据）——本次改道重跑痕档（原档不动）：%s" % out_path)
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		if f != null:
			f.store_string("\n".join(lines) + "\n")
			f.close()
			wrote = true
			print("verdict 表已落盘：%s" % out_path)
		else:
			_check("r5 verdict 落盘", false, out_path)
	_check("r5 verdict 表落盘（%s档%s）" % ["归档" if _archive_mode else "复跑态",
		"——已存在拒写、原档保持" if (_archive_mode and not wrote) else ""],
		wrote or (_archive_mode and FileAccess.file_exists(VERDICT_PATH)), out_path)
	# r1/r4 断言
	var base_row: Dictionary = {}
	for row in _verdict_rows:
		if String(row["label"]).begins_with("BASE"):
			base_row = row
	_check("r1 基线臂跑通+量级断言（敌 ≥%d/弹 ≥%d 池活口直读）" % [ENEMY_FLOOR, BULLET_FLOOR],
		bool(base_row.get("valid", false)),
		"敌min=%d 弹min=%d" % [int(base_row.get("min_enemies", -1)), int(base_row.get("min_bullets", -1))])
	var bad_row: Dictionary = {}
	for row in _verdict_rows:
		if String(row["label"]).begins_with("BAD"):
			bad_row = row
	_check("r4 坏臂回归：敌注入 0 → verdict 记「台架无效」", not bool(bad_row.get("valid", true)),
		"valid=%s" % str(bad_row.get("valid")))
	_check("r4 坏臂不产出 H5 判定行（防假触发）", not (_h5_adjudicated and not _baseline_valid),
		"h5_flag=%s base_valid=%s" % [_h5_adjudicated, _baseline_valid])
	# r3 headless 通道先验
	var base_flush := int(base.get("flush", 0))
	_check("r3 headless 通道先验：哨兵键有值（基线 延µs>0）", base_flush > 0, "延µs=%d" % base_flush)
	_check("r3 绘µs 通道先验：基线 绘µs≥0（0=本构筑自绘件不重绘/不入场，通道结构性存在由 stepacct p4 锁）",
		true, "绘µs=%d" % int(base.get("draw", 0)))


func _arm_window(p_arm: String) -> Dictionary:
	for row in _verdict_rows:
		if String(row["label"]).split(" ")[0] == p_arm:
			return row["w"]
	return {}


func _arm_flush_collapse_pct(p_arm: String) -> int:
	# 延µs 塌缩百分（对双基线均值——单源 _base_flush_s）
	var arm := _arm_window(p_arm)
	if arm.is_empty() or _base_flush_s <= 0.0:
		return 0
	return int(round(_collapse(_base_flush_s, _rate_flush(arm)) * 100.0))


func _arm_union_collapse_pct(p_arm: String) -> int:
	# S2 专用并集口径（延∪隙∪物步取最大——§3.2 判读）
	var arm := _arm_window(p_arm)
	if arm.is_empty() or _base_flush_s <= 0.0:
		return 0
	return maxi(maxi(_arm_flush_collapse_pct(p_arm),
		int(round(_collapse(_base_gap_s, _rate_gap(arm)) * 100.0))),
		int(round(_collapse(_base_phys_s, _rate_phys(arm)) * 100.0)))


func _arm_churn_collapse_pct(p_arm: String) -> int:
	# 加N+摘N 塌缩百分（V-C 相关性判据——短路周转源后树进出速率塌了多少；per-s 口径）
	var arm := _arm_window(p_arm)
	if arm.is_empty() or _base_churn_s <= 0.0:
		return 0
	var arm_churn_s := (float(arm["added"]) + float(arm["removed"])) / float(arm["wall_s"])
	return int(round(_collapse(_base_churn_s, arm_churn_s) * 100.0))


func _arm_collapse_str(p_arm: String) -> String:
	# 塌缩判读单源：基线速率=双基线均值（_report_verdict 合成写入 _base_*；与表行同基线，
	# v4 前此处用 BASE1 单窗而表行用 SUM 合成——同一臂数值互相矛盾，已统一）
	var arm := _arm_window(p_arm)
	if arm.is_empty() or _base_flush_s <= 0.0:
		return "无读数"
	if p_arm == "S2":
		var c2 := _arm_union_collapse_pct(p_arm)
		return "%d%%（延∪隙∪物步并集口径）%s" % [c2, "——**塌缩坐实**" if c2 >= 60 else ""]
	var c := _arm_flush_collapse_pct(p_arm)
	return "%.0f%%%s" % [float(c), "——**塌缩坐实**" if c >= 60 else ""]


func _finish_teardown() -> void:
	# 池遥测披露（runtime_instantiates>0 = 池运行期实例化——AC-14.1 口径在台架促1 深载
	# 下的真实读数；加N 类直方图异常量的归因面）
	if _gl != null:
		var ps: Dictionary = DebugStats._pool_snapshot()
		var parts: Array[String] = []
		for pid in ps:
			parts.append("%s(ri=%d live=%d free=%d cap=%d)" % [String(pid),
				int(ps[pid]["runtime_instantiates"]), int(ps[pid]["live"]),
				int(ps[pid]["free"]), int(ps[pid]["capacity"])])
		print("池遥测：" + " ".join(parts))
	_dump_hist_diag()
	EventBus.wave_started.disconnect(_on_diag_wave_started)
	EventBus.wave_cleared.disconnect(_on_diag_wave_cleared)
	TexBucketHost.shortcircuit_place = false
	TexBucketHost.shortcircuit_sync = false
	ProjectileBase.shortcircuit_tick = false
	PopupManager.shortcircuit_spawn = false
	GameLoop.grid_hit_override = -1             # R285：注入口出厂态复位（-1=真值跟 boost）
	GameLoop.death_flush_override = -1
	GameLoop.shortcircuit_ip_pass = false
	GameLoop.grid_hit_frame = false
	GameLoop.death_flush_frame = false
	Enemy.CONTACT_RADIAL = false
	PerfGovernor.boost_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.deep_override = -1             # R289 夹具迁移复位
	PerfGovernor.set_deep_active(false)
	PerfGovernor.set_process(true)
	DebugStats._diag_last_ms = Time.get_ticks_msec()
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame
	RunSave.clear()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for fl in _failures:
			print("  FAIL 详情：%s" % fl)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])

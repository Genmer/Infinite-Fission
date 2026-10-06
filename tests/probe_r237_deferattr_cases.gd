# tests/probe_r237_deferattr_cases.gd（R237 延迟冲刷桶归因用例体——入口运行时加载）
# 复现口径（如实登记，判读须与本节对照）：
# · 夹具=probe_r237_physattr_cases 逐段同构（R224/R230 深载血统）：world_grove 波表
#   index==16 平铺池循环取样补位 ≤8/渲染帧、敌血 ×1.0（physattr run3-5 定标——0.3 会
#   致 FRACTAL 分裂级联弹股顶池帽、敌驻场塌）、风筝轨迹同式（相位推物理帧号）、
#   hp/xp_need 1e12、W2_gatling L5 + 五词条 AFF_PIERCE×3/AFF_MULTI×2/MEC_BOUNCE×3/
#   MEC_KILL_BLAST×2/MEC_FRACTAL×2，无棱镜/无敌方弹注入。调速器冻结（set_process(false)
#   +mode_override=0+tier_override=2）、DamagePipeline.settle_budget_override=-3。定标
#   预期（physattr run5 同款）：敌 115-120 常驻、弹 280-350、fps 5-16、步/活跃帧 5-8。
# · ★物理由引擎自然驱动（physattr 同款——勿手动步进、不改 set_physics_process）：
#   探针侧 60Hz 注入（工程默认 120Hz 自然驱动深载崩 8fps 实证，physattr run1 留档）、
#   不动 max_physics_steps_per_frame（保持默认 8——与 physattr 完全同形，勿抄
#   renderattr 的帽 2）。夹具只做每渲染帧 风筝+补位+臂注入重放。
# · ★resid_alt 口径=physattr 逐式复刻（前实验员口径）：ΣTIME_PHYSICS_PROCESS 读数
#   （物理活跃渲染帧判重）−Σ同末步段和（十六段去 移/火/跳 三子集键+显式加 派µs——
#   CAL0 已实证 monitor=仅末步语义，故段和同取末步值）/活跃帧数，不钳负。
# · ★四 suppression 臂 + 漂移钉（每臂 预热≥1200 步 后 测量 ≥40s 墙钟 且 ≥1200 步，
#   帽 75s/6000 步；臂间清场+复原+复热——跨臂同构对比，禁单窗前后对比）：
#   D0 基线：现状深载（damage_numbers_on=true / DeathPop 自然发射 / fx 层自然）。
#   D1 popup 抑制：Meta._settings 内存合并 damage_numbers_on=false + settings_changed
#   发信号（R230 夹具注入方式——popup_manager._numbers_on_cache 订阅刷新；on_damage_
#   resolved/on_reaction_triggered/on_w8_detonated 入口短路）→ popup 链（发射+冲刷+
#   首排版 deferred）份额 = D0−D1。
#   D2 死亡表现抑制：Enemy.deathpop_cap_override=1（K2c 注入口，任务点名）+ ★代码
#   现实偏差：override 四态无「帽 0」档、DEATHPOP_FX_CAP=const 10——补 Enemy._
#   fx_quality_cache=0（static 注入，physattr 写 Enemy.CONTACT_RADIAL 同款手法）使
#   _on_died 的 _fx_q()>0 门关死 = DeathPop 发射真归零；副作用披露：敌状态表现件
#   （火苗/冰渣/冰环，_state_fx_q 同门）同被压 0 档——其发射在⑤敌段（已计量），
#   残差侧混淆面=树内子件数缓降。Telegraph/警示圈：产品无覆写口（grep 实证），
#   w16 构成无 caster/Boss（E1/E2/E3/E10 全近战族）→ 探针逐秒 Telegraph 活口计数
#   =0 时该项如实记 N/A。
#   D3 fx 抑制：elemental_fx 层根逐帧 visible=false + 色差件逐帧 RS 隐藏（R230 夹具
#   同款 _reaffirm_chromatic）+ Meta._settings fx_opacity=0.3（写口钳制地板）+发信号
#   → fx 份额 = D0−D3。注意：fx 层为预建池+直接属性写发射（elemental_fx_layer.gd
#   _ready 预建/tick 推进），隐藏不停止发射与 tick——本臂量的是「fx 渲染面+由隐藏
#   可省的延迟调用」份额，若 Δ≈0 即结论本身（fx 发射非延迟桶成员）。
#   D0B 基线复跑（漂移钉）：与 D0 同参再跑一轮 → |D0−D0B|/均值 = 场非平稳漂移带
#   （任务纪律 ±20-30%），三臂差值须超带才可信。
# · 计数器（任务要求）：死亡/s（EventBus.enemy_killed 探针侧订阅计数，只读）、
#   popup 起跳/s（popup 池 _hits+懒增长 Δ/墙钟）、DeathPop 发射/s（DeathPop 池
#   news+hits Δ/墙钟——D2 生效性硬门）、Telegraph 活口（逐秒树走查，披露项）。
# · 判读：share_x=(D0−Dx)/D0；其他=100−Σshare；若 Σshare<30% → 「其他」大头嫌疑
#   清单披露（引擎步本体/queue_free/桶 place 重挂/池 reparent 等）。
# · 桌面≠真机声明：绝对值只做构成归因不做收益外推；窗口 vsync 由显示器决定，
#   步/帧分布如实记入 JSON。
# 纪律：只读不改游戏代码（注入全为运行时 static/Meta 字典写，臂末/teardown 复原）；
#   禁 user:// 真档写（APPDATA 沙箱 + Meta.begin_persist_defer 双保险）；无 test_
#   前缀不入电池。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GROVE_TABLE := "res://resources/maps/wave_table_grove.tres"
const HOLD_DEFAULT := 120                  # 驻场敌数（vc40 深载段常驻值——physattr 同款）
const PROBE_PHYS_HZ := 60                  # 探针侧物理频率注入（physattr run1 实证 120Hz 崩 8fps）
const TOPUP_PER_FRAME := 8                 # SPAWN_PER_FRAME 同款补位节流
const WARMUP_STEPS := 1200                 # 20s@60Hz：spin_up 2s + BOUNCE 10s 寿命地板弹股稳态
const WARMUP_MAX_S := 30.0
const MEASURE_MIN_WALL_S := 40.0           # 任务下限①：≥40s
const MEASURE_MIN_STEPS := 1200            # 任务下限②：≥1200 物理步
const MEASURE_MAX_WALL_S := 75.0           # 防拖挂帽
const MEASURE_MAX_STEPS := 6000
# 运行时副本（smoke 档缩短窗——const 不可重赋，_run_arm 读 *_B 变量）
var WARMUP_STEPS_B := WARMUP_STEPS
var MEASURE_MIN_WALL_S_B := MEASURE_MIN_WALL_S
var MEASURE_MIN_STEPS_B := MEASURE_MIN_STEPS
const PLAYER_HOME := Vector2(360.0, 900.0)
const ENEMY_HP_SCALE := 1.0                # physattr run3-5 定标（头注）
const SANDBOX_MARKER := ".qa_sandbox_r237"
const OUT_JSON := "res://docs/qa/probe_r237_deferattr.json"
const FX_OPACITY_FLOOR := 0.3              # D3：fx_opacity 写口钳制地板（meta_manager 0.3~1.0）

var tree: SceneTree
var _gl: GameLoop = null
var _fails: int = 0
var _comp: Array[Dictionary] = []          # 平铺构成池 {data: EnemyData, tags: int}
var _cursor: int = 0
var _is_headless: bool = false
var _smoke: bool = false                   # -- --smoke：管线烟测（缩短窗，不落 JSON）
var _phys_hz_project := 120                # 工程默认物理频率（注入前快照——teardown 还原）
var _phys_hz := 120
var _arm_results: Dictionary = {}          # key -> 结果（入 JSON）
var _gate_results: Dictionary = {}         # 门读数（入 JSON）
var _chrom_node: CanvasItem = null         # 色差件（D3 逐帧 RS 隐藏——R230 同款）
var _death_count: int = 0                  # EventBus.enemy_killed 探针侧计数（窗口差分）
var _spawn_count: int = 0                  # 夹具补位计数（死亡/s 交叉核对）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	_is_headless = DisplayServer.get_name() == "headless"
	_smoke = OS.get_cmdline_user_args().has("--smoke")
	_phys_hz_project = Engine.physics_ticks_per_second
	Engine.physics_ticks_per_second = PROBE_PHYS_HZ      # 探针侧 60Hz（physattr 头注实证）
	_phys_hz = PROBE_PHYS_HZ
	seed(20261006)
	if _smoke:
		# 烟测档：窗长缩短（暖 100 步 / 测 ≥3s 且 ≥200 步）——只验管线不采数
		WARMUP_STEPS_B = 100
		MEASURE_MIN_WALL_S_B = 3.0
		MEASURE_MIN_STEPS_B = 200
	print("══ R237 延迟桶归因：D0 基线 / D1 popup / D2 死亡表现 / D3 fx 抑制 + D0B 漂移钉（%s 档%s）══"
		% ["headless 降级" if _is_headless else "窗口 gl_compatibility",
			" · smoke" if _smoke else ""])
	if not _is_headless and not _sandbox_check():
		_teardown_static()
		return
	if not _boot():
		await _teardown()
		return
	# 臂序：D0 → D1 → D2 → D3 → D0B（漂移钉）；臂间清场+复原+复热
	#（_run_arm 含 await=协程——必须逐臂 await，否则五臂并发交错共毁夹具态）
	await _run_arm("D0", "基线深载（现状：跳字开 / DeathPop 自然发射 / fx 层自然）", "D0")
	await _run_arm("D1", "popup 抑制（damage_numbers_on=false 内存注入+发信号——入口短路）", "D1")
	await _run_arm("D2", "死亡表现抑制（deathpop_cap_override=1 + Enemy._fx_quality_cache=0——DeathPop 发射归零；帽0 无注入口的代码现实偏差见头注）", "D2")
	await _run_arm("D3", "fx 抑制（elemental_fx 层根+色差件逐帧隐藏 + fx_opacity=0.3 地板）", "D3")
	await _run_arm("D0B", "基线复跑（漂移钉——与 D0 同参，差=场非平稳漂移带）", "D0")
	_derive()
	if not _smoke:
		_store_json()
	await _teardown()


func fail_count() -> int:
	return _fails


# ── 引导（probe_r237_physattr_cases._boot 逐段同构）──────────────────

func _boot() -> bool:
	Meta.begin_persist_defer()               # 全程挂起 Meta 落盘（_save 短路——零真档写）
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "ProbeR237Deferattr"
	tree.root.add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[probe] Boot 失败：%s" % str(_gl.boot_fatal))
		_fails += 1
		return false
	# ★引擎自然驱动物理（physattr 同款）：不动 set_physics_process / 追赶帽
	PerfGovernor.set_process(false)
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	DamagePipeline.settle_budget_override = -3
	_gl.current_map_id = &"world_grove"
	if not _gl.start_run():
		push_error("[probe] start_run 失败")
		_fails += 1
		return false
	_gl.player.set("xp_need", 1.0e12)       # 40s+ 窗不开选卡
	_gl.player.set("max_hp", 1.0e12)
	_gl.player.set("hp", 1.0e12)
	_gl.player.unlocked_slots = 6
	_gl.player.global_position = PLAYER_HOME
	var gatling: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	if gatling == null:
		push_error("[probe] W2 加特林装配失败")
		_fails += 1
		return false
	gatling.level = 5
	var ok_counts := {"PIERCE": 0, "MULTI": 0, "BOUNCE": 0, "NOVA": 0, "FRACTAL": 0}
	for pair in [["PIERCE", &"AFF_PIERCE", 3], ["MULTI", &"AFF_MULTI", 2],
			["BOUNCE", &"MEC_BOUNCE", 3], ["NOVA", &"MEC_KILL_BLAST", 2],
			["FRACTAL", &"MEC_FRACTAL", 2]]:
		var td: TraitData = _gl.registry.get_trait(pair[1])
		for i in range(int(pair[2])):
			if gatling.attach_trait(td):
				ok_counts[pair[0]] = int(ok_counts[pair[0]]) + 1
	print("boot.词条：PIERCE×%d/3 MULTI×%d/2 BOUNCE×%d/3 NOVA×%d/2 FRACTAL×%d/2"
		% [ok_counts["PIERCE"], ok_counts["MULTI"], ok_counts["BOUNCE"],
			ok_counts["NOVA"], ok_counts["FRACTAL"]])
	if _gl.player.mirror_count() != 0:
		push_error("[probe] 镜面数 %d ≠ 0（夹具异常）" % _gl.player.mirror_count())
		_fails += 1
		return false
	_gl.stage_probe_enabled = true
	# 死亡计数（只读订阅——窗口差分 死亡/s；teardown 断连）
	EventBus.enemy_killed.connect(_on_enemy_killed_probe)
	_death_count = 0
	_spawn_count = 0
	if _gl.game_feel != null and _gl.game_feel.chromatic_rect != null:
		_chrom_node = _gl.game_feel.chromatic_rect
	if not _load_composition():
		return false
	print("boot：grove w16 构成 %d 敌种池（%s）压血×%.2f；物理引擎自然驱动 %dHz；构筑=W2 L5 五词条（无棱镜）+ 风筝"
		% [_comp.size(), _comp_summary(), ENEMY_HP_SCALE, _phys_hz])
	return true


func _on_enemy_killed_probe(_enemy: Node2D) -> void:
	_death_count += 1


func _sandbox_check() -> bool:
	var udir := OS.get_user_data_dir()
	var ok: bool = udir.contains(SANDBOX_MARKER)
	_gate("G-沙箱 user:// 重定向生效（含 %s）" % SANDBOX_MARKER, ok,
		"user_dir=%s%s" % [udir, "" if ok else " ←未重定向！窗口跑必须 APPDATA 指向仓内沙箱，中止防真档污染"])
	return ok


func _load_composition() -> bool:
	var tbl: Resource = load(GROVE_TABLE)
	if tbl == null or not ("entries" in tbl):
		push_error("[probe] 波表加载失败：%s" % GROVE_TABLE)
		_fails += 1
		return false
	var entry: Resource = null
	for e in tbl.get("entries"):
		if int(e.get("index")) == 16:
			entry = e
			break
	if entry == null:
		push_error("[probe] grove 波表无 index==16 条目")
		_fails += 1
		return false
	for c in entry.get("composition"):
		var src: EnemyData = _gl.registry.get_enemy(StringName(c.get("enemy_id")))
		if src == null:
			push_error("[probe] 敌数据缺失：%s" % str(c.get("enemy_id")))
			_fails += 1
			return false
		var data: EnemyData = src.duplicate()   # 压血复本（探针持有，注册表真件不动）
		data.hp_base = data.hp_base * ENEMY_HP_SCALE
		var tags := int(c.get("tags", 0))
		for i in range(int(c.get("count", 1))):
			_comp.append({"data": data, "tags": tags})
	_comp.shuffle()
	return true


func _comp_summary() -> String:
	var counts: Dictionary = {}
	for c in _comp:
		var id := String((c["data"] as EnemyData).id)
		counts[id] = int(counts.get(id, 0)) + 1
	var parts: Array[String] = []
	for id in counts:
		parts.append("%s×%d" % [id, int(counts[id])])
	return " ".join(parts)


# ── 驻场补位/风筝（physattr 同款）────────────────────────────────────

func _kite() -> void:
	var ang := float(_gl.frame_stamp) * 0.35 / float(_phys_hz)
	_gl.player.global_position = Vector2(360.0 + cos(ang) * 140.0,
		660.0 + sin(ang) * 200.0)


func _spawn_one() -> void:
	var c: Dictionary = _comp[_cursor % _comp.size()]
	_cursor += 1
	_spawn_count += 1
	var e := (_gl.pools[&"enemy"] as EnemyPool).acquire() as Enemy
	if e == null:
		return
	e.bucket_host = (_gl.pools[&"enemy"] as EnemyPool).bucket_host
	e.spawn(c["data"], 16, int(c["tags"]))
	e.global_position = Vector2(randf() * 680.0 + 20.0, randf() * 1180.0 + 40.0)
	_gl.spawner.active.append(e)


func _topup(p_hold: int) -> void:
	var alive: int = _gl.spawner.active.size()
	var want: int = mini(TOPUP_PER_FRAME, p_hold - alive)
	for i in range(want):
		_spawn_one()


# ── 臂注入/重放/复原 ────────────────────────────────────────────────

func _apply_arm_inject(p_mode: String) -> void:
	# 臂注入口（臂首一次性；D3 的可见面逐帧重放另走 _replay_arm）
	match p_mode:
		"D1":
			var s: Dictionary = Meta.get("_settings")
			s["damage_numbers_on"] = false           # R230 内存合并注入（勿走 set_setting 落盘口）
			Meta.settings_changed.emit(&"damage_numbers_on")   # 刷 popup_manager._numbers_on_cache
		"D2":
			Enemy.deathpop_cap_override = 1          # K2c 注入口（任务点名；帽 10 生效）
			Enemy._fx_quality_cache = 0              # ★代码现实偏差补刀：_on_died 的 _fx_q()>0 门关死
			                                          # = DeathPop 发射归零（头注；static 注入，
			                                          # physattr 写 Enemy.CONTACT_RADIAL 同款手法）
		"D3":
			var s3: Dictionary = Meta.get("_settings")
			s3["fx_opacity"] = FX_OPACITY_FLOOR      # 写口钳制地板（game_loop._apply_fx_opacity 折乘）
			Meta.settings_changed.emit(&"fx_opacity")


func _replay_arm(p_mode: String) -> void:
	# 逐帧重放（churn 新件复显封堵——D3 渲染面；D1/D2 哨兵态无逐帧需求=零操作）
	if p_mode != "D3":
		return
	if _gl.elemental_fx != null:
		_gl.elemental_fx.visible = false
	_reaffirm_chromatic()


func _reaffirm_chromatic() -> void:
	# R230 夹具同款：色差件逐帧 RS 隐藏（绕 CanvasItem.visible 复显路径）
	if _chrom_node != null and is_instance_valid(_chrom_node) \
			and _chrom_node.get_canvas_item().is_valid():
		RenderingServer.canvas_item_set_visible(_chrom_node.get_canvas_item(), false)


func _restore_arm_inject(p_mode: String) -> void:
	match p_mode:
		"D1":
			var s: Dictionary = Meta.get("_settings")
			s["damage_numbers_on"] = true
			Meta.settings_changed.emit(&"damage_numbers_on")
		"D2":
			Enemy.deathpop_cap_override = -1         # 复原=真值自动门（产品默认）
			Enemy._fx_quality_cache = -1             # 复原=惰性重读（下次 _fx_q() 按 Meta 真值缓存）
		"D3":
			var s3: Dictionary = Meta.get("_settings")
			s3["fx_opacity"] = 1.0
			Meta.settings_changed.emit(&"fx_opacity")
			if _gl != null and _gl.elemental_fx != null:
				_gl.elemental_fx.visible = true      # 层根复显（色差件产品自管——RS 隐藏随臂止）
		_:
			pass


# ── 采样累计器（debug_stats.gd / physattr Acc 逐式复刻）─────────────

class Acc:
	# Σmon：物理活跃渲染帧上 TIME_PHYSICS_PROCESS 读数 µs 累计；Σseg：同帧段和
	#（十六段去三子集键+派µs，含「他」键）；resid_alt：未乘步数不钳负逐帧序列
	#（physattr 口径——CAL0 实证 monitor=仅末步语义，段和同取末步值）
	const DIAG_KEYS: Array[StringName] = [
		&"player", &"player_mv", &"player_wp", &"shard", &"grid_rebuild", &"grid_projectile",
		&"enemy", &"wave", &"feel_shard", &"feel", &"fx", &"popup", &"ui",
		&"card_open", &"card_drain", &"other",
	]
	const DIAG_SUBSET_KEYS: Array[StringName] = [&"player_mv", &"player_wp", &"popup"]

	var mon_us: int = 0
	var seg_us: int = 0
	var samples: int = 0
	var steps: int = 0
	var resid_alt: Array[float] = []
	var resid_raw: Array[float] = []      # mon − seg×steps（钳负前逐帧——钳负占比判读键）
	var _last_pf: int = -1

	func sample_frame(p_gl: Node) -> void:
		var pf := Engine.get_physics_frames()
		if pf == _last_pf:
			return
		var n_steps := 1 if _last_pf < 0 else int(pf - _last_pf)
		_last_pf = pf
		var probe_raw: Variant = p_gl.get("stage_probe_us")
		if not (probe_raw is Dictionary):
			return                         # 无段帧不采样（debug_stats 同口径）
		var probe: Dictionary = probe_raw
		var m := int(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000000.0)
		var g := int(probe.get(&"dispatch", 0))
		for key in DIAG_KEYS:
			if not DIAG_SUBSET_KEYS.has(key):
				g += int(probe.get(key, 0))
		mon_us += m
		seg_us += g * n_steps
		samples += 1
		steps += n_steps
		resid_alt.append(float(m - g))
		resid_raw.append(float(m - g * n_steps))


# ── 臂驱动 ─────────────────────────────────────────────────────────

func _run_arm(p_key: String, p_label: String, p_mode: String) -> void:
	print("── %s %s ──" % [p_key, p_label])
	_clear_field()
	_cursor = 0
	for i in range(HOLD_DEFAULT):
		_spawn_one()
	_apply_arm_inject(p_mode)
	# 预热：≥WARMUP_STEPS_B 物理步（20s@60Hz——BOUNCE 寿命地板弹股稳态；帽 WARMUP_MAX_S 墙钟）
	var pf0 := Engine.get_physics_frames()
	var wt0 := Time.get_ticks_msec()
	while Engine.get_physics_frames() - pf0 < WARMUP_STEPS_B \
			and Time.get_ticks_msec() - wt0 < int(WARMUP_MAX_S * 1000.0):
		_kite()
		_topup(HOLD_DEFAULT)
		_replay_arm(p_mode)
		await tree.process_frame
	# 测量：≥40s 且 ≥1200 步（双下限；帽 75s/6000 步）——smoke 档窗长见 *_B 副本
	var acc := Acc.new()
	var fps_arr: Array[float] = []
	var enemies_arr: Array[int] = []
	var proj_arr: Array[int] = []
	var popup_arr: Array[int] = []
	var telegraph_arr: Array[int] = []
	var fx_hidden := 0
	var fxchecks := 0
	# 窗口边界计数器快照（差分→速率）
	var d0 := _death_count
	var s0 := _spawn_count
	var pj0 := _popup_acquire_total()
	var dp0 := _deathpop_pop_total()
	var m_pf0 := Engine.get_physics_frames()
	var m_wt0 := Time.get_ticks_msec()
	var sec_last_ms := m_wt0
	_take_load_sample(fps_arr, enemies_arr, proj_arr, popup_arr, telegraph_arr)
	while true:
		_kite()
		_topup(HOLD_DEFAULT)
		_replay_arm(p_mode)
		if p_mode == "D3":
			fxchecks += 1
			if _gl.elemental_fx == null or not _gl.elemental_fx.visible:
				fx_hidden += 1
		acc.sample_frame(_gl)
		await tree.process_frame
		var now_ms := Time.get_ticks_msec()
		if now_ms - sec_last_ms >= 1000:                    # 墙钟 ~1s 节流（fps 无关）
			sec_last_ms = now_ms
			_take_load_sample(fps_arr, enemies_arr, proj_arr, popup_arr, telegraph_arr)
		var wall_s := (Time.get_ticks_msec() - m_wt0) / 1000.0
		var steps_done := Engine.get_physics_frames() - m_pf0
		if (wall_s >= MEASURE_MIN_WALL_S_B and steps_done >= MEASURE_MIN_STEPS_B) \
				or wall_s >= MEASURE_MAX_WALL_S or steps_done >= MEASURE_MAX_STEPS:
			break
	_take_load_sample(fps_arr, enemies_arr, proj_arr, popup_arr, telegraph_arr)
	var wall_s := (Time.get_ticks_msec() - m_wt0) / 1000.0
	var steps_done := Engine.get_physics_frames() - m_pf0
	var deaths := _death_count - d0
	var spawns := _spawn_count - s0
	var popup_jumps := _popup_acquire_total() - pj0
	var deathpop_pops := _deathpop_pop_total() - dp0
	# 段均值档案（µs，十六段逐键——臂间段漂移对账用；末帧段值 physattr 同口径）
	var seg_means: Dictionary = {}
	if acc.samples > 0:
		var probe: Dictionary = _gl.get("stage_probe_us")
		for key in Acc.DIAG_KEYS:
			seg_means[String(key)] = float(int(probe.get(key, 0)))
	var res := {
		"label": p_label, "mode": p_mode,
		"wall_s": wall_s, "steps": steps_done, "samples": acc.samples,
		"steps_per_active_frame": float(acc.steps) / float(maxi(acc.samples, 1)),
		"mon_us_per_step": float(acc.mon_us) / float(maxi(acc.steps, 1)),
		"seg_us_per_step": float(acc.seg_us) / float(maxi(acc.steps, 1)),
		"phys_step_us_per_active_frame": float(maxi(acc.mon_us - acc.seg_us, 0))
			/ float(maxi(acc.samples, 1)),          # 物步µs（诊断键同式——多步帧域预期钳 0，披露）
		"resid_alt_us_per_active_frame": _mean_f(acc.resid_alt),
		"resid_alt_p50": _pct_f(_sorted_f(acc.resid_alt), 0.50),
		"resid_alt_p95": _pct_f(_sorted_f(acc.resid_alt), 0.95),
		"resid_raw_clamped_frac": _clamped_frac(acc.resid_raw),
		"seg_last_frame_us": seg_means,
		"fps_mean": _mean_f(fps_arr),
		"enemies_p50": _pct_i(_sorted_i(enemies_arr), 0.50),
		"projectiles_p50": _pct_i(_sorted_i(proj_arr), 0.50),
		"popups_p50": _pct_i(_sorted_i(popup_arr), 0.50),
		"telegraph_live_p50": _pct_i(_sorted_i(telegraph_arr), 0.50),
		"deaths": deaths, "deaths_per_s": float(deaths) / float(maxf(wall_s, 0.001)),
		"spawns_per_s": float(spawns) / float(maxf(wall_s, 0.001)),
		"popup_jumps": popup_jumps,
		"popup_jumps_per_s": float(popup_jumps) / float(maxf(wall_s, 0.001)),
		"deathpop_pops": deathpop_pops,
		"deathpop_pops_per_s": float(deathpop_pops) / float(maxf(wall_s, 0.001)),
		"fx_hidden_frac": float(fx_hidden) / float(maxi(fxchecks, 1)),
	}
	_arm_results[p_key] = res
	print("读数：resid_alt=%.1fµs/活跃帧（p95=%.1f，钳负帧占%.0f%%）｜物步µs=%.1f｜mon=%.1fµs/步 段和=%.1fµs/步｜步/帧=%.2f 样本=%d 步=%d 墙=%.1fs"
		% [res["resid_alt_us_per_active_frame"], res["resid_alt_p95"],
			float(res["resid_raw_clamped_frac"]) * 100.0,
			res["phys_step_us_per_active_frame"],
			res["mon_us_per_step"], res["seg_us_per_step"], res["steps_per_active_frame"],
			acc.samples, steps_done, wall_s])
	print("负载：敌 p50=%d 弹 p50=%d 跳 p50=%d fps=%.1f｜死亡/s=%.1f（补位/s=%.1f）跳字起跳/s=%.1f DeathPop发射/s=%.1f Telegraph活口p50=%d"
		% [res["enemies_p50"], res["projectiles_p50"], res["popups_p50"], res["fps_mean"],
			res["deaths_per_s"], res["spawns_per_s"], res["popup_jumps_per_s"],
			res["deathpop_pops_per_s"], res["telegraph_live_p50"]])
	_gate("G-%s 采样成立（活跃帧>0 且 步≥%d 且 墙≥%.0fs×0.9）" % [p_key, MEASURE_MIN_STEPS_B, MEASURE_MIN_WALL_S_B],
		acc.samples > 0 and steps_done >= MEASURE_MIN_STEPS_B
			and wall_s >= MEASURE_MIN_WALL_S_B * 0.9,
		"样本=%d 步=%d 墙=%.1fs（帽 %.0fs/%d 步内收口）"
			% [acc.samples, steps_done, wall_s, MEASURE_MAX_WALL_S, MEASURE_MAX_STEPS])
	_gate_disclosed("G-%s 负载带披露（敌 p50≥hold-8 且 弹 p50≥60——physattr 带）" % p_key,
		res["enemies_p50"] >= HOLD_DEFAULT - 8 and res["projectiles_p50"] >= 60,
		"敌=%d/%d 弹=%d 跳=%d" % [res["enemies_p50"], HOLD_DEFAULT, res["projectiles_p50"], res["popups_p50"]])
	# 抑制生效性硬门（差值可信度前提——抑制未生效的臂读数不入饼）
	match p_mode:
		"D1":
			_gate("G-D1 抑制生效：跳字起跳/s ≤1.0（damage_numbers_on 入口短路）",
				res["popup_jumps_per_s"] <= 1.0,
				"起跳/s=%.2f（跳 p50=%d）" % [res["popup_jumps_per_s"], res["popups_p50"]])
		"D2":
			_gate("G-D2 抑制生效：DeathPop 发射/s ≤1.0（_fx_q 门+K2c 帽）",
				res["deathpop_pops_per_s"] <= 1.0,
				"发射/s=%.2f" % res["deathpop_pops_per_s"])
		"D3":
			_gate("G-D3 抑制生效：fx 层隐藏采样占比 ≥99%%",
				res["fx_hidden_frac"] >= 0.99,
				"隐藏占比=%.2f" % res["fx_hidden_frac"])
	_restore_arm_inject(p_mode)
	await tree.process_frame                 # 哨兵/deferred 落地后再生效下一臂


func _take_load_sample(p_fps: Array[float], p_en: Array[int], p_proj: Array[int],
		p_pop: Array[int], p_tel: Array[int]) -> void:
	# 负载快照（墙钟 ~1s 节流 + 窗口首末必采——低 fps 窗渲染帧数可能 <60）
	var d := _gl.diag_counts()
	p_fps.append(float(Engine.get_frames_per_second()))
	p_en.append(int(d.get(&"enemies", 0)))
	p_proj.append(int(d.get(&"projectiles", 0)))
	p_pop.append(int(d.get(&"popups", 0)))
	p_tel.append(_count_telegraph_live())


func _count_telegraph_live() -> int:
	# Telegraph/警示圈活口（树走查 1Hz——D2 覆写口不存在的披露计数）
	var n := 0
	var queue: Array = [tree.root]
	while not queue.is_empty():
		var node: Node = queue.pop_front()
		if node is Telegraph.TelegraphCircle or node is Telegraph.TelegraphFan \
				or node is Telegraph.TelegraphLine:
			n += 1
		for c in node.get_children():
			queue.append(c)
	return n


func _popup_acquire_total() -> int:
	# 跳字取出累计（池命中+容量内懒增长——起跳/s 差分源；miss 不起跳不计）
	var pool: ObjectPool = _gl.pools[&"popup"] as ObjectPool
	return int(pool._hits) + int(pool.runtime_instantiate_count)


func _deathpop_pop_total() -> int:
	var st: Dictionary = Enemy.DeathPop.fx_pool_stats()
	return int(st.get("news", 0)) + int(st.get("hits", 0))


# ── 判读派生（桶构成饼——报告引用本节算出的份额）────────────────────

func _derive() -> void:
	if not (_arm_results.has("D0") and _arm_results.has("D1")
			and _arm_results.has("D2") and _arm_results.has("D3")):
		return
	var d0: Dictionary = _arm_results["D0"]
	var r0: float = float(d0["resid_alt_us_per_active_frame"])
	var d := {}
	# 漂移带（D0B 在档时）：|D0−D0B|/均值——差值可信度界（任务纪律：场非平稳 ±20-30%）
	var drift_band_pct := 0.0
	if _arm_results.has("D0B"):
		var rb: float = float(_arm_results["D0B"]["resid_alt_us_per_active_frame"])
		var m := (r0 + rb) * 0.5
		drift_band_pct = 0.0 if m <= 0.0 else absf(r0 - rb) / m * 100.0
		d["resid_d0b"] = rb
	d["drift_band_pct"] = snappedf(drift_band_pct, 0.1)
	# 三臂差值与份额（分母=D0 resid_alt；正值=抑制后残差下降=该链贡献）
	var drops := {}
	var shares := {}
	var total_drop := 0.0
	for key in ["D1", "D2", "D3"]:
		var rx: float = float(_arm_results[key]["resid_alt_us_per_active_frame"])
		var drop := r0 - rx
		drops[key] = drop
		total_drop += maxf(drop, 0.0)
		shares[key] = 0.0 if r0 <= 0.0 else drop / r0 * 100.0
	d["drops_us"] = drops
	d["shares_pct"] = shares
	d["total_drop_us"] = total_drop
	d["total_share_pct"] = 0.0 if r0 <= 0.0 else total_drop / r0 * 100.0
	d["other_pct"] = 100.0 - d["total_share_pct"]
	# 残差地板两口径（任务判读式「三臂差值合计 vs D0−(残差地板)」）：
	# · 地板=0（无空载物理臂不可直测引擎步本体——下界口径）
	# · 地板=漂移带等效 µs（D0B 噪声下界——超带差值才可信）
	d["floor_note"] = "引擎步本体地板无直测臂（A2K 空物理空间下残差仍 18.9ms=physattr 证）；以 D0/D0B 漂移带为噪声下界"
	d["drift_band_us_equiv"] = r0 * drift_band_pct / 100.0 / 2.0
	_arm_results["derive"] = d
	print("── 派生：D0 resid_alt=%.1f｜D1=%.1f（Δ%+.1f，%.1f%%）D2=%.1f（Δ%+.1f，%.1f%%）D3=%.1f（Δ%+.1f，%.1f%%）｜D0B=%.1f 漂移带=%.1f%%（≈%.1fµs）｜三臂合计=%.1fµs（%.1f%%）→ 其他=%.1f%%"
		% [r0,
			float(_arm_results["D1"]["resid_alt_us_per_active_frame"]), float(drops["D1"]), float(shares["D1"]),
			float(_arm_results["D2"]["resid_alt_us_per_active_frame"]), float(drops["D2"]), float(shares["D2"]),
			float(_arm_results["D3"]["resid_alt_us_per_active_frame"]), float(drops["D3"]), float(shares["D3"]),
			float(d.get("resid_d0b", 0.0)), drift_band_pct, float(d["drift_band_us_equiv"]),
			total_drop, float(d["total_share_pct"]), float(d["other_pct"])])


# ── JSON 留档（性能结论唯一依据）─────────────────────────────────────

func _store_json() -> void:
	var rmethod := str(ProjectSettings.get_setting_with_override(
		&"rendering/renderer/rendering_method"))
	var args := OS.get_cmdline_args()
	for i in range(args.size() - 1):
		if String(args[i]) == "--rendering-method":
			rmethod = String(args[i + 1])
	var root: Dictionary = {
		"meta": {
			"date": "2026-10-06", "package": "desktop-window-probe（归因对象=真机 vc40 深载 物步µs 15-64ms 的延迟冲刷桶构成）",
			"rendering_project_setting": rmethod,
			"adapter_api": RenderingServer.get_video_adapter_api_version(),
			"headless": _is_headless,
			"physics_hz_project": _phys_hz_project,
			"physics_hz_probe": PROBE_PHYS_HZ,
			"physics_catchup_cap": "工程默认 8 未动（physattr 同形——勿抄 renderattr 帽 2）",
			"user_dir": OS.get_user_data_dir(), "physics_hz": _phys_hz,
			"hold": HOLD_DEFAULT, "hp_scale": ENEMY_HP_SCALE,
			"build": "W2_gatling L5 + AFF_PIERCE×3/AFF_MULTI×2/MEC_BOUNCE×3/MEC_KILL_BLAST×2/MEC_FRACTAL×2（physattr 同款，无棱镜/无敌弹注入）",
			"governor": "frozen, mode=frame_priority, tier_override=2, settle_budget=-3",
			"drive": "引擎自然驱动物理（60Hz）+ 夹具每渲染帧 风筝/补位/臂注入重放（physattr 同构）",
			"measure": {"min_wall_s": MEASURE_MIN_WALL_S, "min_steps": MEASURE_MIN_STEPS,
				"max_wall_s": MEASURE_MAX_WALL_S, "max_steps": MEASURE_MAX_STEPS,
				"warmup_steps": WARMUP_STEPS},
			"formula": "resid_alt = Σ(TIME_PHYSICS_PROCESS 末步读数 − 同末步段和)/活跃帧，不钳负（physattr 前实验员口径逐式复刻；CAL0 已实证 monitor=仅末步语义）",
			"arms_note": "D1=Meta 内存注入 damage_numbers_on=false+发信号（R230 方式）；D2=deathpop_cap_override=1（K2c 口）+Enemy._fx_quality_cache=0（★帽0 无注入口的代码现实补刀——_on_died 的 _fx_q()>0 门关死，副作用=敌状态表现件同压 0 档，披露）；D3=elemental_fx 层根+色差件逐帧隐藏+fx_opacity=0.3（渲染面抑制——fx 层预建池直接属性写发射，隐藏不停止发射/tick，Δ≈0 即『fx 发射非延迟桶成员』结论本身）；D0B=漂移钉",
			"note": "桌面绝对值≠真机——只做构成归因（popup/死亡链/fx/其他），不做收益外推；差值结论以 D0B 漂移带为可信度界",
		},
		"arms": _arm_results.duplicate(true),
		"gates": _gate_results.duplicate(true),
	}
	var f := FileAccess.open(OUT_JSON, FileAccess.WRITE)
	if f == null:
		push_error("[probe] JSON 写入失败：%s" % OUT_JSON)
		_fails += 1
		return
	f.store_string(JSON.stringify(root, "\t"))
	f.close()
	print("留档：%s" % OUT_JSON)


func _gate(p_label: String, p_ok: bool, p_detail: String) -> void:
	if p_ok:
		print("  PASS | %s（%s）" % [p_label, p_detail])
	else:
		print("  FAIL | %s（%s）" % [p_label, p_detail])
		_fails += 1
	_gate_results[p_label] = {"ok": p_ok, "detail": p_detail}


func _gate_disclosed(p_label: String, p_ok: bool, p_detail: String) -> void:
	# 披露类门：如实记 FAIL* 但不阻塞退出码（负载带漂移已声明，归因用途不受影响）
	if p_ok:
		print("  PASS | %s（%s）" % [p_label, p_detail])
	else:
		print("  FAIL* | %s（%s）——披露类失配：不阻塞（口径见用例体头注）" % [p_label, p_detail])
	_gate_results[p_label] = {"ok": p_ok, "detail": p_detail, "disclosed": true}


# ── 清场/收尾 ────────────────────────────────────────────────────────

func _clear_field() -> void:
	for e in _gl.spawner.active.duplicate():
		_gl.elemental.unregister_host(e)
		(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_gl.spawner.active.clear()
	_gl.spawner.spawn_queue.clear()
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles().duplicate():
		(_gl.pools[&"projectile"] as ObjectPool).release(p)
	for s in (_gl.active_shards as Array).duplicate():
		(_gl.pools[&"xp"] as XPPool).release(s)
	_gl.active_shards.clear()


func _teardown() -> void:
	# 哨兵防御性复原（臂末已复原——双保险：异常路径漏复原不外溢进程）
	_restore_arm_inject("D1")
	_restore_arm_inject("D2")
	_restore_arm_inject("D3")
	if EventBus.enemy_killed.is_connected(_on_enemy_killed_probe):
		EventBus.enemy_killed.disconnect(_on_enemy_killed_probe)
	DamagePipeline.settle_budget_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.set_process(true)
	Engine.physics_ticks_per_second = _phys_hz_project   # 还原工程默认频率
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame
	# Meta._settings 内存注入不还原真档（persist_defer 全程挂起零落盘——进程即弃）


func _teardown_static() -> void:
	# 沙箱自检失败路径（boot 未跑）：无可还原 static 口（boot 前失败）——仅还原物理频率
	Engine.physics_ticks_per_second = _phys_hz_project


# ── 统计工具 ─────────────────────────────────────────────────────────

func _mean_i(p_arr: Array[int]) -> int:
	if p_arr.is_empty():
		return 0
	var s := 0
	for v in p_arr:
		s += v
	return s / p_arr.size()


func _mean_f(p_arr: Array[float]) -> float:
	if p_arr.is_empty():
		return 0.0
	var s := 0.0
	for v in p_arr:
		s += v
	return s / float(p_arr.size())


func _sorted_i(p_arr: Array[int]) -> Array[int]:
	var s := p_arr.duplicate()
	s.sort()
	return s


func _sorted_f(p_arr: Array[float]) -> Array[float]:
	var s := p_arr.duplicate()
	s.sort()
	return s


func _pct_i(p_sorted: Array[int], p_pct: float) -> int:
	if p_sorted.is_empty():
		return 0
	return p_sorted[clampi(int(float(p_sorted.size()) * p_pct), 0, p_sorted.size() - 1)]


func _pct_f(p_sorted: Array[float], p_pct: float) -> float:
	if p_sorted.is_empty():
		return 0.0
	return p_sorted[clampi(int(float(p_sorted.size()) * p_pct), 0, p_sorted.size() - 1)]


func _clamped_frac(p_resid_raw: Array[float]) -> float:
	if p_resid_raw.is_empty():
		return 0.0
	var neg := 0
	for v in p_resid_raw:
		if v < 0.0:
			neg += 1
	return float(neg) / float(p_resid_raw.size())

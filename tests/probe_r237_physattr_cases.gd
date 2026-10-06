# tests/probe_r237_physattr_cases.gd（R237 物理相归因用例体——入口运行时加载）
# 复现口径（如实登记，判读须与本节对照）：
# · 构成：probe_r224_deepload_cases 同构（world_grove 波表 index==16 平铺池循环取样
#   补位 ≤8/渲染帧、敌血 ×0.3、风筝轨迹同式、hp/xp_need 1e12、W2_gatling L5 + 五词条
#   AFF_PIERCE×3/AFF_MULTI×2/MEC_BOUNCE×3/MEC_KILL_BLAST×2/MEC_FRACTAL×2，无棱镜/无
#   敌方弹注入——R224 定标取舍照旧）。调速器冻结（PerfGovernor.set_process(false)+
#   mode_override=0+tier_override=2）、DamagePipeline.settle_budget_override=-3（R224 S1
#   模拟真机 tier2 档）。
# · ★与 R224/R230 的本质差异：物理由引擎自然驱动（不手动调 _gl._physics_process、
#   不 set_physics_process(false)）——TIME_PHYSICS_PROCESS 监视器量的是引擎物理块
#   （PhysicsServer2D sync/flush_queries/step + 全部 _physics_process 回调 + 物理迭代内
#   MessageQueue flush），必须让引擎真跑才有归因意义；夹具只做 每渲染帧 风筝+补位+臂
#   注入。
# · ★物理频率=探针侧 60Hz（Engine.physics_ticks_per_second 运行时注入，boot 前设置，
#   teardown 还原）：run1 实测工程默认 120Hz 自然驱动下深载稳态 段和~11.7ms/步×120Hz
#   = 1.4s GDScript/s 崩到 8fps（8 步追赶帽全顶满、模拟慢动作、物步µs 钳负 100%——
#   run1 原始日志 docs/qa/probe_r237_run1.log 留档）；60Hz=R224 手动驱动的同款模拟口径
#   （每模拟秒段成本减半、步/活跃帧≈1 → ×steps 减项失真消失，物步µs 诊断键在探针内
#   可读），CAL0 语义结论与频率无关。
# · 物步µs 公式=debug_stats.gd R235 搭车③ 逐式复刻（_diag_accumulate_window 同序）：
#   物理活跃渲染帧（物理帧号变更判重）上 TIME_PHYSICS_PROCESS 读数µs 累计 Σmon，
#   GameLoop 段和（十六段去 移/火/跳 三子集键 + 显式加 派µs——「他」键在十六段内已含
#   未捕获 GDScript）×该帧步数 累计 Σseg，物步µs = max(Σmon−Σseg,0)/活跃帧数。
#   另记未乘步数不钳负的备选口径 resid_alt = Σ(mon−seg)/活跃帧数（多步帧 ×steps 近似
#   的对侧读数——两口径同落 JSON，CAL0 定语义后判读取真）。
# · CAL0 监视器语义标定（boot 前、无 GameLoop）：挂 physics_frame 信号忙等 ~2ms/步 +
#   渲染帧忙等到 ~33ms（→~4 物理步/帧），对比 monitor 与 步耗时/步数——Godot 4.3 本体
#   实证「整帧物理块和」vs「仅末步」，归因判读前置（两语义下 A/B 臂同比仍有效）。
# · 四臂 + 刀态直读臂：A0 现状深载（敌120 常驻）/ A1 敌 _hit_area set_deferred(
#   monitoring,monitorable,false)（形状仍在 broadphase、配对与信号断）/ A2=A1+玩家
#   Area2D 双监测关（潜在配对终局=0）/ A3 敌数 30/60/120 梯度（余同 A0，线性=每敌
#   固定成本 vs 配对爆炸）/ A2K 清退刀态（产品既有 Enemy.CONTACT_RADIAL 旗 boot 前
#   置 true 重挂新实例=敌 HitArea 从不构建+玩家 layer0 双监测关——物理空间真清空，
#   区分「空间形状成本」vs「监测关不掉的物理块内成本」，刀收益直读）。深载 churn 期
#   新出生敌每渲染帧重放关断标记（qa_r230 族掩码重放同思路——一次性关断必被新件
#   污染）；臂末统一复原（含池化复用件）。
# · 测量窗：每臂 预热 ≥600 物理步（≈5s@120Hz，帽 20s）后，测量 ≥40s 墙钟 且 ≥1200
#   物理步（双下限满足任务「≥40s 或 ≥1200 步」；帽 75s/6000 步防拖挂）。每秒拉
#   diag_counts（敌/弹/跳活口）+ fps 校准披露。
# · 桌面≠真机声明：绝对值只做归因（谁贡献的），不做收益外推；窗口 vsync 帧率由
#   显示器决定，步/帧分布如实记入 JSON。
# 纪律：只读不改游戏代码（CONTACT_RADIAL 产品旗默认 false 不触碰——A1/A2 走探针侧
#   set_deferred 注入，测的是「关监测」机制而非产品刀本身）；禁 user:// 真档写（APPDATA
#   沙箱 + Meta.begin_persist_defer 双保险）；无 test_ 前缀不入电池。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GROVE_TABLE := "res://resources/maps/wave_table_grove.tres"
const HOLD_DEFAULT := 120                  # A0/A1/A2 驻场敌数（vc40 深载段常驻值）
const PROBE_PHYS_HZ := 60                  # 探针侧物理频率注入（run1 120Hz 崩 8fps 实证——见头注）
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
# 敌血定标旋钮（R224 先例同款旋钮，取值按本探针窗形重定标并留档）：
# · 0.3（R224 30s 短窗定标值）：自然驱动 ≥40s 长窗下 MEC_FRACTAL×2 分裂/死亡新星级联
#   正反馈把弹股推到 ~700-785（池帽 820），敌驻场塌（35/120——秒杀速率>补位），
#   fps 塌 6-7（run1=120Hz 8fps / run2=60Hz 6-7fps，log 留档 docs/qa/probe_r237_run1/2.log）
#   ——收敛态负载形≠vc40 深载形（敌120 常驻+弹200-400）。
# · 1.0（本跑=w16 波表原生血）：击杀减速 → 敌驻场 120 顶格保持、新星/分裂级联受抑、
#   弹股回带——「敌 120 常驻」是 A3 梯度臂的硬前提，优先保形；击杀率定标差异披露。
const ENEMY_HP_SCALE := 1.0
const SANDBOX_MARKER := ".qa_sandbox_r237"
const OUT_JSON := "res://docs/qa/probe_r237_physattr.json"
const CAL0_BURN_US := 2000                 # CAL0 每物理步忙等 µs（目标 ~2ms）
const CAL0_FRAME_MS := 50.0                # CAL0 渲染帧忙等到 ~50ms → ~3 步/帧@60Hz（歧义分离带）
const CAL0_FRAMES := 90                    # CAL0 采样帧数（≈4.5s）

var tree: SceneTree
var _gl: GameLoop = null
var _fails: int = 0
var _comp: Array[Dictionary] = []          # 平铺构成池 {data: EnemyData, tags: int}
var _cursor: int = 0
var _is_headless: bool = false
var _smoke: bool = false                   # -- --smoke：管线烟测（CAL0+boot+三主臂缩短窗，不落 JSON）
var _phys_hz_project := 120                # 工程默认物理频率（注入前快照——teardown 还原）
var _phys_hz := 120
var _cal0: Dictionary = {}                 # CAL0 语义标定读数
var _arm_results: Dictionary = {}          # key -> 结果（入 JSON）
var _gate_results: Dictionary = {}         # 门读数（入 JSON）
var _flagged: Array[Area2D] = []           # A1/A2 已关断敌 HitArea（臂末复原）
var _flagged_ids: Dictionary = {}          # instance_id -> true（churn 重放去重）
var _player_off: bool = false              # A2 玩家双监测关态闩


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	_is_headless = DisplayServer.get_name() == "headless"
	_smoke = OS.get_cmdline_user_args().has("--smoke")
	_phys_hz_project = Engine.physics_ticks_per_second
	Engine.physics_ticks_per_second = PROBE_PHYS_HZ      # 探针侧 60Hz（头注 run1 实证）
	_phys_hz = PROBE_PHYS_HZ
	seed(20261006)
	if _smoke:
		# 烟测档：窗长缩短（暖 100 步 / 测 ≥3s 且 ≥200 步）——只验管线不采数
		WARMUP_STEPS_B = 100
		MEASURE_MIN_WALL_S_B = 3.0
		MEASURE_MIN_STEPS_B = 200
	print("══ R237 物理相归因：A0/A1/A2 物理面 A/B + A3 敌数梯度（%s 档%s）══"
		% ["headless 降级" if _is_headless else "窗口 gl_compatibility",
			" · smoke" if _smoke else ""])
	if not _is_headless and not _sandbox_check():
		_teardown_static()
		return
	_cal0 = await _arm_cal0()
	if not _boot():
		_teardown()
		return
	# 四臂顺序：A0 → A1 → A2 → A3(30/60/120)；臂间清场+复原+复热
	#（_run_arm 含 await=协程——必须逐臂 await，否则六臂并发交错共毁夹具态）
	await _run_arm("A0", "基线深载（敌 HitArea 监测开 + 玩家 Area2D 监测开）", HOLD_DEFAULT, false, false)
	await _run_arm("A1", "敌 HitArea 双监测关（monitoring/monitorable=false——形状仍入空间）", HOLD_DEFAULT, true, false)
	await _run_arm("A2", "A1 + 玩家双监测关（潜在配对终局=0）", HOLD_DEFAULT, true, true)
	if _smoke:
		# 烟测含 A2K 重挂路径验证（A3 梯度跳过——纯重复机制）
		_free_gl()
		Enemy.CONTACT_RADIAL = true
		seed(20261006)
		var smoke_boot := _boot()
		Enemy.CONTACT_RADIAL = false
		if smoke_boot:
			await _run_arm("A2K", "清退刀态（CONTACT_RADIAL=true：敌 HitArea 不构建+玩家 layer0/双监测关——物理空间真清空）", HOLD_DEFAULT, false, false)
		print("SMOKE 汇总：CAL0+boot+A0/A1/A2+A2K重挂 管线走通（数字不入档——正式跑见头注命令）")
		await _teardown()
		return
	await _run_arm("A3_30", "敌数梯度 30（余同 A0）", 30, false, false)
	await _run_arm("A3_60", "敌数梯度 60（余同 A0）", 60, false, false)
	await _run_arm("A3_120", "敌数梯度 120（=A0 复跑，序效应披露）", 120, false, false)
	# A2K 清退刀态（第 7 臂，run3 后补——A1/A2 只关监测、形状仍在 broadphase，无法
	# 区分「物理空间形状成本」vs「物理块内 MessageQueue flush 成本」；产品码既有
	# Enemy.CONTACT_RADIAL 旗（R237 清退刀，默认 false）在 boot 前置 true = 敌 HitArea
	# 从不构建+玩家 layer0/双监测关 = 物理空间真清空——刀预期收益的直读臂。重挂新
	# GameLoop 实例（池预热期 _ready 读旗——运行中翻旗不追溯已建实例，产品注释同口径）
	# 并重播种=A0 同构对照（同波次推进/同 RNG 起点）。旗为产品既有开关、探针侧注入
	# 不改产品码（R230 哨兵注入同款手法）。
	_free_gl()
	Enemy.CONTACT_RADIAL = true
	seed(20261006)
	var a2k_booted := _boot()
	Enemy.CONTACT_RADIAL = false           # 立即复位（pool 预热已完成读旗；防后续误触）
	if a2k_booted:
		await _run_arm("A2K", "清退刀态（CONTACT_RADIAL=true：敌 HitArea 不构建+玩家 layer0/双监测关——物理空间真清空）", HOLD_DEFAULT, false, false)
	else:
		push_error("[probe] A2K 臂二次 boot 失败（清退刀态读数缺——其余臂不受影响）")
	_derive()
	_store_json()
	await _teardown()


func fail_count() -> int:
	return _fails


# ── CAL0：TIME_PHYSICS_PROCESS 语义标定（整帧物理块和 vs 仅末步）────────
# Godot 4.3 Main::iteration() 物理循环内每步量 physics_process_ticks、帧末 set_monitor
# ——监视器=「末步覆盖写」还是「帧内累计」决定 物步µs 公式的 ×steps 减项口径。本标定
# 用无 GameLoop 的净环境（只剩本夹具的 physics_frame 忙等）实证：monitor ≈ 步耗时×步数
# →帧和语义；monitor ≈ 步耗时 →末步语义。两语义下 A/B 臂同式同比均有效，但绝对判读
#（尤其 H2「引擎计时就这么大」核对）须按本读数取口径。

func _arm_cal0() -> Dictionary:
	print("── CAL0 监视器语义标定（无 GameLoop 净环境：步忙等 %dµs × 帧压 %dms）──"
		% [CAL0_BURN_US, int(CAL0_FRAME_MS)])
	var box: Dictionary = {"last_us": 0}
	var burn := func() -> void:
		# physics_frame 信号在 SceneTree::physics_process 首行发出——必在引擎物理块
		#（monitor 量程）内；忙等 CAL0_BURN_US 每物理步一次
		var t0 := Time.get_ticks_usec()
		while Time.get_ticks_usec() - t0 < CAL0_BURN_US:
			pass
		box["last_us"] = Time.get_ticks_usec() - t0
	tree.physics_frame.connect(burn)
	var steps_arr: Array[int] = []
	var mon_arr: Array[int] = []
	var last_us_arr: Array[int] = []
	var last_pf := -1
	for i in range(CAL0_FRAMES):
		var ft0 := Time.get_ticks_usec()
		while Time.get_ticks_usec() - ft0 < int(CAL0_FRAME_MS * 1000.0):
			pass                                 # 渲染帧压到 ~30fps → ~4 步/帧@120Hz
		await tree.process_frame
		var pf := Engine.get_physics_frames()
		var steps := 1 if last_pf < 0 else maxi(pf - last_pf, 0)
		last_pf = pf
		steps_arr.append(steps)
		mon_arr.append(int(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000000.0))
		last_us_arr.append(int(box["last_us"]))
	tree.physics_frame.disconnect(burn)
	var steps_mean := _mean_i(steps_arr)
	var mon_mean := _mean_i(mon_arr)
	var stepus_mean := _mean_i(last_us_arr)
	var ratio := mon_mean / float(maxi(stepus_mean, 1))
	var verdict := "frame-sum" if ratio > steps_mean * 0.6 else ("last-step" if ratio < 1.6 else "ambiguous")
	var out := {
		"frames": CAL0_FRAMES, "steps_per_frame_mean": steps_mean,
		"monitor_us_mean": mon_mean, "burn_us_measured_mean": stepus_mean,
		"monitor_div_burn": ratio, "verdict": verdict,
	}
	print("CAL0：步/帧=%.2f monitor=%dµs 步耗时=%dµs monitor/步耗时=%.2f → 语义=%s"
		% [steps_mean, mon_mean, stepus_mean, ratio, verdict])
	_gate("CAL0 监视器语义可判（frame-sum / last-step 二选一）",
		verdict == "frame-sum" or verdict == "last-step",
		"ratio=%.2f（歧义窗 1.6~%.1f）" % [ratio, steps_mean * 0.6])
	return out


# ── 引导（probe_r224_deepload_cases._boot 同构 + R230 沙箱/挂起双保险）──

func _boot() -> bool:
	Meta.begin_persist_defer()               # 全程挂起 Meta 落盘（_save 短路——零真档写）
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "ProbeR237Physattr"
	tree.root.add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[probe] Boot 失败：%s" % str(_gl.boot_fatal))
		_fails += 1
		return false
	# ★引擎自然驱动物理：不 set_physics_process(false)、不手动 _physics_process
	PerfGovernor.set_process(false)
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	DamagePipeline.settle_budget_override = -3
	_gl.current_map_id = &"world_grove"
	if not _gl.start_run():
		push_error("[probe] start_run 失败")
		_fails += 1
		return false
	_gl.player.set("xp_need", 1.0e12)       # 30s+ 窗不开选卡（成本归「开」键不在本口径）
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
	if not _load_composition():
		return false
	print("boot：grove w16 构成 %d 敌种池（%s）压血×%.2f；物理引擎自然驱动 %dHz；构筑=W2 L5 五词条（无棱镜）+ 风筝"
		% [_comp.size(), _comp_summary(), ENEMY_HP_SCALE, _phys_hz])
	return true


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


# ── 驻场补位/风筝（R224 同款；风筝相位按物理帧号推——120Hz 半速同墙钟轨迹）──

func _kite() -> void:
	var ang := float(_gl.frame_stamp) * 0.35 / float(_phys_hz)
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


func _topup(p_hold: int) -> void:
	var alive: int = _gl.spawner.active.size()
	var want: int = mini(TOPUP_PER_FRAME, p_hold - alive)
	for i in range(want):
		_spawn_one()


# ── 臂注入（A1/A2：churn 重放关断标记——新出生敌/池复用件统一收口）────────

func _flag_enemies_once() -> void:
	for e in _gl.spawner.active:
		var eid := (e as Object).get_instance_id()
		if _flagged_ids.has(eid):
			continue
		var area: Area2D = (e as Object).get("_hit_area")
		if area == null:
			continue                    # CONTACT_RADIAL 产品旗若开则无 HitArea（本夹具默认关态不触）
		area.set_deferred("monitoring", false)
		area.set_deferred("monitorable", false)
		_flagged.append(area)
		_flagged_ids[eid] = true


func _set_player_off(p_off: bool) -> void:
	_gl.player.set_deferred("monitoring", not p_off)
	_gl.player.set_deferred("monitorable", not p_off)
	_player_off = p_off


func _restore_arm_state() -> void:
	for area in _flagged:
		if is_instance_valid(area):
			area.set_deferred("monitoring", true)
			area.set_deferred("monitorable", true)
	_flagged.clear()
	_flagged_ids.clear()
	if _player_off:
		_set_player_off(false)
		await tree.process_frame                 # deferred 落地后再生效下一臂


# ── 采样累计器（debug_stats.gd _diag_accumulate_window 逐式复刻）──────────

class Acc:
	# Σmon：物理活跃渲染帧上 TIME_PHYSICS_PROCESS 读数 µs 累计（帧间不复位判重——
	#   debug_stats 同口径）；Σseg：同帧段和（十六段去三子集键+派µs，含「他」键）×步数；
	#   resid_alt：未乘步数不钳负逐帧序列（多步帧 ×steps 近似的对侧读数）
	# debug_stats.gd DIAG_STAGE_ORDER 逐字复刻（十六段键——物步µs 段和口径同源；
	# 常量内置本类=内类常量作用域零歧义，外层经 Acc.DIAG_KEYS 引用）
	const DIAG_KEYS: Array[StringName] = [
		&"player", &"player_mv", &"player_wp", &"shard", &"grid_rebuild", &"grid_projectile",
		&"enemy", &"wave", &"feel_shard", &"feel", &"fx", &"popup", &"ui",
		&"card_open", &"card_drain", &"other",
	]
	# 段和剔除三子集键（玩段内部拆键——DIAG_STAGE_ORDER 同款排除）+ 显式加 dispatch
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


# ── 四臂驱动 ─────────────────────────────────────────────────────────

func _run_arm(p_key: String, p_label: String, p_hold: int,
		p_enemy_off: bool, p_player_off_arm: bool) -> void:
	print("── %s %s ──" % [p_key, p_label])
	_clear_field()
	_cursor = 0
	for i in range(p_hold):
		_spawn_one()
	if p_enemy_off:
		_flag_enemies_once()
	if p_player_off_arm:
		_set_player_off(true)
	# 预热：≥WARMUP_STEPS_B 物理步（20s@60Hz——BOUNCE 10s 寿命地板弹股稳态；帽 WARMUP_MAX_S 墙钟）
	var pf0 := Engine.get_physics_frames()
	var wt0 := Time.get_ticks_msec()
	while Engine.get_physics_frames() - pf0 < WARMUP_STEPS_B \
			and Time.get_ticks_msec() - wt0 < int(WARMUP_MAX_S * 1000.0):
		_kite()
		_topup(p_hold)
		if p_enemy_off:
			_flag_enemies_once()
		await tree.process_frame
	# 测量：≥40s 且 ≥1200 步（双下限；帽 75s/6000 步）——smoke 档窗长见 *_B 副本
	var acc := Acc.new()
	var fps_arr: Array[float] = []
	var enemies_arr: Array[int] = []
	var proj_arr: Array[int] = []
	var popup_arr: Array[int] = []
	var m_pf0 := Engine.get_physics_frames()
	var m_wt0 := Time.get_ticks_msec()
	var sec_last_ms := m_wt0
	_take_load_sample(fps_arr, enemies_arr, proj_arr, popup_arr)   # 窗口首样必采（低 fps 窗
	                                                                # 渲染帧数可能 <60——帧计数
	                                                                # 节流会零采样，p50 全 0 假读）
	while true:
		_kite()
		_topup(p_hold)
		if p_enemy_off:
			_flag_enemies_once()
		acc.sample_frame(_gl)
		await tree.process_frame
		var now_ms := Time.get_ticks_msec()
		if now_ms - sec_last_ms >= 1000:                    # 墙钟 ~1s 节流（fps 无关）
			sec_last_ms = now_ms
			_take_load_sample(fps_arr, enemies_arr, proj_arr, popup_arr)
		var wall_s := (Time.get_ticks_msec() - m_wt0) / 1000.0
		var steps_done := Engine.get_physics_frames() - m_pf0
		if (wall_s >= MEASURE_MIN_WALL_S_B and steps_done >= MEASURE_MIN_STEPS_B) \
				or wall_s >= MEASURE_MAX_WALL_S or steps_done >= MEASURE_MAX_STEPS:
			break
	_take_load_sample(fps_arr, enemies_arr, proj_arr, popup_arr)   # 窗口末样必采
	var wall_s := (Time.get_ticks_msec() - m_wt0) / 1000.0
	var steps_done := Engine.get_physics_frames() - m_pf0
	# 段均值档案（µs/步，十六段逐键——A/B 臂间段漂移对账用）
	var seg_means: Dictionary = {}
	if acc.samples > 0:
		var probe: Dictionary = _gl.get("stage_probe_us")
		for key in Acc.DIAG_KEYS:
			seg_means[String(key)] = float(int(probe.get(key, 0)))
	var res := {
		"label": p_label, "hold": p_hold,
		"enemy_off": p_enemy_off, "player_off": p_player_off_arm,
		"wall_s": wall_s, "steps": steps_done, "samples": acc.samples,
		"steps_per_active_frame": float(acc.steps) / float(maxi(acc.samples, 1)),
		"mon_us_per_step": float(acc.mon_us) / float(maxi(acc.steps, 1)),
		"seg_us_per_step": float(acc.seg_us) / float(maxi(acc.steps, 1)),
		"phys_step_us_per_active_frame": float(maxi(acc.mon_us - acc.seg_us, 0))
			/ float(maxi(acc.samples, 1)),          # ← 物步µs（debug_stats 同式：×steps 减项、钳负）
		"resid_alt_us_per_active_frame": _mean_f(acc.resid_alt),
		"resid_alt_p50": _pct_f(_sorted_f(acc.resid_alt), 0.50),
		"resid_alt_p95": _pct_f(_sorted_f(acc.resid_alt), 0.95),
		"resid_raw_clamped_frac": _clamped_frac(acc.resid_raw),
		"seg_last_frame_us": seg_means,
		"fps_mean": _mean_f(fps_arr),
		"enemies_p50": _pct_i(_sorted_i(enemies_arr), 0.50),
		"projectiles_p50": _pct_i(_sorted_i(proj_arr), 0.50),
		"popups_p50": _pct_i(_sorted_i(popup_arr), 0.50),
	}
	_arm_results[p_key] = res
	print("读数：物步µs/活跃帧=%.1f｜resid_alt=%.1f（p95=%.1f，钳负帧占%.0f%%）｜mon=%.1fµs/步 段和=%.1fµs/步｜步/帧=%.2f 样本=%d 步=%d 墙=%.1fs"
		% [res["phys_step_us_per_active_frame"], res["resid_alt_us_per_active_frame"],
			res["resid_alt_p95"], float(res["resid_raw_clamped_frac"]) * 100.0,
			res["mon_us_per_step"], res["seg_us_per_step"], res["steps_per_active_frame"],
			acc.samples, steps_done, wall_s])
	print("负载：敌 p50=%d 弹 p50=%d 跳 p50=%d fps=%.0f"
		% [res["enemies_p50"], res["projectiles_p50"], res["popups_p50"], res["fps_mean"]])
	_gate("G-%s 采样成立（活跃帧>0 且 步≥%d 且 墙≥%.0fs×0.9）" % [p_key, MEASURE_MIN_STEPS_B, MEASURE_MIN_WALL_S_B],
		acc.samples > 0 and steps_done >= MEASURE_MIN_STEPS_B
			and wall_s >= MEASURE_MIN_WALL_S_B * 0.9,
		"样本=%d 步=%d 墙=%.1fs（帽 %.0fs/%d 步内收口）"
			% [acc.samples, steps_done, wall_s, MEASURE_MAX_WALL_S, MEASURE_MAX_STEPS])
	_gate_disclosed("G-%s 负载带披露（敌 p50≥hold-8 且 弹 p50≥60——R224 带 [60,350]）" % p_key,
		res["enemies_p50"] >= p_hold - 8 and res["projectiles_p50"] >= 60,
		"敌=%d/%d 弹=%d 跳=%d" % [res["enemies_p50"], p_hold, res["projectiles_p50"], res["popups_p50"]])
	await _restore_arm_state()


func _take_load_sample(p_fps: Array[float], p_en: Array[int], p_proj: Array[int],
		p_pop: Array[int]) -> void:
	# 负载快照（墙钟 ~1s 节流 + 窗口首末必采——帧计数节流在低 fps 窗会零采样）
	var d := _gl.diag_counts()
	p_fps.append(float(Engine.get_frames_per_second()))
	p_en.append(int(d.get(&"enemies", 0)))
	p_proj.append(int(d.get(&"projectiles", 0)))
	p_pop.append(int(d.get(&"popups", 0)))


# ── 判读派生（H1/H2 裁定数字——报告引用本节算出的比率）─────────────────

func _derive() -> void:
	if not (_arm_results.has("A0") and _arm_results.has("A1")
			and _arm_results.has("A2") and _arm_results.has("A3_30")
			and _arm_results.has("A3_60") and _arm_results.has("A3_120")):
		return
	var a0: Dictionary = _arm_results["A0"]
	var a1: Dictionary = _arm_results["A1"]
	var a2: Dictionary = _arm_results["A2"]
	var d := {}
	d["wu_drop_A1_pct"] = _drop_pct(a0, a1, "phys_step_us_per_active_frame")
	d["wu_drop_A2_pct"] = _drop_pct(a0, a2, "phys_step_us_per_active_frame")
	d["alt_drop_A1_pct"] = _drop_pct(a0, a1, "resid_alt_us_per_active_frame")
	d["alt_drop_A2_pct"] = _drop_pct(a0, a2, "resid_alt_us_per_active_frame")
	d["mon_drop_A2_pct"] = _drop_pct(a0, a2, "mon_us_per_step")
	d["wu_gain_A0_minus_A2"] = float(a0["phys_step_us_per_active_frame"]) \
		- float(a2["phys_step_us_per_active_frame"])
	# A3 线性：每敌边际（120 档−30 档）/90——线性≈常数=每敌固定成本；超线性=配对/级联
	#（梯度口径=resid_alt——物步µs 键在多步帧域恒钳 0 无梯度可读；A3 各档弹股不同
	#  〔30 敌=712 / 120 敌=331——杀率低→跳弹股更深〕，梯度含弹股混杂因子，判读披露）
	var r30: float = _arm_results["A3_30"]["resid_alt_us_per_active_frame"]
	var r60: float = _arm_results["A3_60"]["resid_alt_us_per_active_frame"]
	var r120: float = _arm_results["A3_120"]["resid_alt_us_per_active_frame"]
	d["a3_resid_30"] = r30
	d["a3_resid_60"] = r60
	d["a3_resid_120"] = r120
	d["a3_marginal_30_60"] = (r60 - r30) / 30.0
	d["a3_marginal_60_120"] = (r120 - r60) / 60.0
	# A2K 清退刀态（在档时）：刀收益=A0−A2K（物步µs/resid_alt/mon 三口径同算——
	# 物理空间真清空 vs A1/A2 只关监测的分解读数）
	if _arm_results.has("A2K"):
		var ak: Dictionary = _arm_results["A2K"]
		d["knife_gain_wu"] = float(a0["phys_step_us_per_active_frame"]) \
			- float(ak["phys_step_us_per_active_frame"])
		d["knife_gain_resid_alt"] = float(a0["resid_alt_us_per_active_frame"]) \
			- float(ak["resid_alt_us_per_active_frame"])
		d["knife_gain_mon_per_step"] = float(a0["mon_us_per_step"]) - float(ak["mon_us_per_step"])
		d["knife_drop_resid_alt_pct"] = _drop_pct(a0, ak, "resid_alt_us_per_active_frame")
	_arm_results["derive"] = d
	var knife_line := ""
	if _arm_results.has("A2K"):
		knife_line = "｜A2K 刀态 resid_alt=%.1f 刀收益=%.1fµs/活跃帧（降 %.0f%%）" % [
			float(_arm_results["A2K"]["resid_alt_us_per_active_frame"]),
			d["knife_gain_resid_alt"], d["knife_drop_resid_alt_pct"]]
	print("── 派生：物步µs 降幅 A1=%.0f%% A2=%.0f%%｜resid_alt 降幅 A1=%.0f%% A2=%.0f%%｜mon降幅 A2=%.0f%%｜A3 梯度 resid_alt 30/60/120 = %.1f/%.1f/%.1f 每敌边际[30→60]=%.3f [60→120]=%.3f%s"
		% [d["wu_drop_A1_pct"], d["wu_drop_A2_pct"], d["alt_drop_A1_pct"], d["alt_drop_A2_pct"],
			d["mon_drop_A2_pct"], r30, r60, r120, d["a3_marginal_30_60"], d["a3_marginal_60_120"],
			knife_line])


func _drop_pct(p_base: Dictionary, p_arm: Dictionary, p_key: String) -> float:
	var b := float(p_base[p_key])
	if b <= 0.0:
		return 0.0
	return clampf((b - float(p_arm[p_key])) / b * 100.0, -100.0, 100.0)


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
			"date": "2026-10-06", "package": "desktop-window-probe（归因对象=真机 vc40 深载 物步µs 15-64ms）",
			"rendering_project_setting": rmethod,
			"adapter_api": RenderingServer.get_video_adapter_api_version(),
			"headless": _is_headless,
			"physics_hz_project": _phys_hz_project,
			"physics_hz_probe": PROBE_PHYS_HZ,
			"physics_hz_note": "工程默认 120Hz 自然驱动深载稳态崩 8fps/钳负100%（run1 留档 probe_r237_run1.log）；60Hz=R224 手动驱动同款模拟口径，步/活跃帧≈1 使 ×steps 减项失真消失",
			"user_dir": OS.get_user_data_dir(), "physics_hz": _phys_hz,
			"hold": HOLD_DEFAULT, "hp_scale": ENEMY_HP_SCALE,
			"build": "W2_gatling L5 + AFF_PIERCE×3/AFF_MULTI×2/MEC_BOUNCE×3/MEC_KILL_BLAST×2/MEC_FRACTAL×2（R224 同款，无棱镜/无敌弹注入）",
			"governor": "frozen, mode=frame_priority, tier_override=2, settle_budget=-3",
			"drive": "引擎自然驱动物理（120Hz）+ 夹具每渲染帧 风筝/补位/臂注入（R224/R230 手动驱动的差异见头注）",
			"measure": {"min_wall_s": MEASURE_MIN_WALL_S, "min_steps": MEASURE_MIN_STEPS,
				"max_wall_s": MEASURE_MAX_WALL_S, "max_steps": MEASURE_MAX_STEPS,
				"warmup_steps": WARMUP_STEPS},
			"formula": "物步µs = max(ΣTIME_PHYSICS_PROCESS − Σ(段和×步数),0)/活跃帧（debug_stats.gd R235 搭车③ 同式复刻；resid_alt=未乘步数不钳负对侧口径）",
			"cal0": _cal0,
			"note": "桌面绝对值≠真机——只做归因（H1 物理空间成本 vs H2 扣减公式伪影），不做收益外推",
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


func _free_gl() -> void:
	# A2K 臂前置：释放当前 GameLoop 实例（A2K 需 boot 前读 CONTACT_RADIAL 旗重挂新实例
	# ——池预热在 _ready 期，运行中翻旗不追溯已建 HitArea）。static 注入口保持。
	if _gl != null:
		_gl.queue_free()
		_gl = null
		await tree.process_frame
		await tree.process_frame


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
	DamagePipeline.settle_budget_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.set_process(true)
	Engine.physics_ticks_per_second = _phys_hz_project   # 还原工程默认频率
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame


func _teardown_static() -> void:
	# 沙箱自检失败路径（boot 未跑）：无可还原 static 口（boot 前失败）——空实现占位
	pass


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

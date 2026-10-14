# tests/qa_r228_ospec_cases.gd（R228 对象谱清点用例体——入口运行时加载）
# 复现口径（与 probe_r224_deepload_cases.gd 同构，差异仅测量面）：
# · 构成：world_grove 波表 index==16 按 count 展平平铺池循环取样补位（≤8/帧节流），
#   敌血 ×0.3 定标复本、玩家风筝轨迹、hp/xp_need 1e12、W2_gatling L5 + 五词条满叠
#   （AFF_PIERCE×3/AFF_MULTI×2/MEC_BOUNCE×3/MEC_KILL_BLAST×2/MEC_FRACTAL×2，无棱镜）。
#   手动 spawn 不走 spawner 出生管线 → 敌方弹不在口径（QA D4 同款披露）。
# · 真机深载态 override（R223/R225/R227 哨兵先例，防 headless 误触产品门）：
#   PerfGovernor.set_process(false)+mode_override=0+tier_override=2；Enemy.fullload_
#   override=1（满载敌装饰隐藏=vc33「翻1 后稳态」）；DamagePopup.bitmap_override=1
#   （跳字位图=vc33「全程位图1/补0」）+ PopupGlyphAtlas.runstart_bake_override=1
#   （R227 补烤哨兵——桌面自动门不补烤则位图恒回退 Label，非 vc33 形态）；
#   DamagePipeline.settle_budget_override=-3（r224 S1：tier2 帽96@60Hz）。
# · 清点：预热 300 帧 → 测量窗 900 帧内每 180 帧拉一次整树快照（BFS 自 tree.root，
#   CanvasItem 派生节点按家族归桶）。可见/隐藏双口径：own visible（ask 口径——
#   visible=false 仍占树位）与 is_visible_in_tree（有效可见≈渲染提交子集）分列。
#   Telegraph 内部类（resource_path 为空）按 Telegraph.Circle/Fan/Line 显式识别归
#   「预警件」——初版按脚本路径匹配漏内部类（已修）。
# · 真机深载 o=2100-2700（RenderingServer TOTAL_OBJECTS_IN_FRAME 渲染提交对象）；
#   本清点=场景树节点数（占树位口径，含 visible=false 池内闲置件）——两者语义不同：
#   树清点是 o 的上界口径（渲染面 headless 不可复现，r224 同款披露），对照以「总量带
#   + 家族构成」为口径。跨运行取 3 次独立进程稳定值（判读见输出）。
# · 「磁」家族说明：磁吸在产品内为距离判定（player.gd R220 刀10 摘磁吸 Area2D、
#   pickup.gd XpShard._pickup_radius 距离读），无独立 CanvasItem——真机诊断行「磁N」
#   是磁吸 tick 段名非画件族，本谱按 0 如实登记。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GROVE_TABLE := "res://resources/maps/wave_table_grove.tres"
const DT60 := 1.0 / 60.0
const HOLD := 120                      # 驻场敌数（vc33 深载段常驻值）
const WARMUP_FRAMES := 300             # 5s：加特林 spin_up 2s + 弹/结算/死亡稳态
const MEASURE_FRAMES := 900            # 15s@60Hz 清点窗
const CENSUS_EVERY := 180              # 3s 一拉快照 → 5 次/运行
const TOPUP_PER_FRAME := 8             # SPAWN_PER_FRAME 同款补位节流
const PLAYER_HOME := Vector2(360.0, 900.0)
const ENEMY_HP_SCALE := 0.3            # r224 定标值（击杀率×敌群密度联合旋钮）

var tree: SceneTree
var _gl: GameLoop = null
var _fails: int = 0
var _comp: Array[Dictionary] = []      # 平铺构成池 {data: EnemyData, tags: int}
var _cursor: int = 0


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261004)
	print("══ R228 对象谱清点：翡翠树海 w16 × 敌120 驻场 × 深构筑（r224 同构夹具）══")
	if not _boot():
		_teardown()
		return
	for i in range(HOLD):
		_spawn_one()
	for i in range(WARMUP_FRAMES):
		_kite(i - WARMUP_FRAMES)
		_gl._physics_process(DT60)
		_topup()
		await _pump_process_budget()
	print("boot.稳态预热 %d 帧毕——清点窗 %d 帧 × 每 %d 帧一快照" % [
		WARMUP_FRAMES, MEASURE_FRAMES, CENSUS_EVERY])
	var snaps: Array[Dictionary] = []
	var frame_i := 0
	while frame_i < MEASURE_FRAMES:
		_kite(frame_i)
		_gl._physics_process(DT60)
		_topup()
		await _pump_process_budget()
		frame_i += 1
		if frame_i % CENSUS_EVERY == 0:
			snaps.append(_census(frame_i))
	_report(snaps)
	_teardown()


func fail_count() -> int:
	return _fails


# ── 引导（r224 同构 + 深载态 override）───────────────────────────────

func _boot() -> bool:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "ProbeR228Ospec"
	# 深载表现态哨兵（R223 先例：headless 不触产品门，覆写口注入真机深载形态）——
	# 必须先于 add_child：池预热在 _ready 期跑，DamagePopup._ready 的位图门晚置会
	# 让预热批先装 Label（真机 mobile 门在预热期即位图臂=零 Label）
	Enemy.fullload_override = 1          # 满载敌装饰隐藏（vc33 翻1 后稳态）
	DamagePopup.bitmap_override = 1      # 跳字位图臂（vc33 全程位图1/补0）
	PopupGlyphAtlas.runstart_bake_override = 1  # R227 补烤哨兵：headless 真链测口径
	                                           # （桌面自动门不补烤→位图恒回退 Label，非 vc33 形态）
	DamagePipeline.settle_budget_override = -3
	tree.root.add_child(_gl)
	# 泵帧护轨（r224 夹具隐含假设显式化）：GameLoop 未关引擎自动物理——r224 同步循环
	# 从不 yield 故引擎 tick 进不来；本探针每物理步 await process_frame 泵 _process 时钟
	# （演出件自清用），若不关引擎会自动 _physics_process 双驱（游戏 2 倍速、驻场塌 73
	# 实证）。关后唯一驱动=本探针手动 _physics_process@60Hz（r224 口径）。
	_gl.set_physics_process(false)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[probe] Boot 失败：%s" % str(_gl.boot_fatal))
		_fails += 1
		return false
	# 调速器冻结 + 真机深载档注入（r224 同款）
	PerfGovernor.set_process(false)
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	_gl.current_map_id = &"world_grove"
	var ok_run: bool = _gl.start_run()
	if not ok_run:
		push_error("[probe] start_run 失败")
		_fails += 1
		return false
	_gl.player.set("xp_need", 1.0e12)
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
	var pierce: TraitData = _gl.registry.get_trait(&"AFF_PIERCE")
	var pierce_ok := 0
	for i in range(3):
		if gatling.attach_trait(pierce):
			pierce_ok += 1
	var multi: TraitData = _gl.registry.get_trait(&"AFF_MULTI")
	var multi_ok := 0
	for i in range(2):
		if gatling.attach_trait(multi):
			multi_ok += 1
	var bounce: TraitData = _gl.registry.get_trait(&"MEC_BOUNCE")
	var bounce_ok := 0
	for i in range(3):
		if gatling.attach_trait(bounce):
			bounce_ok += 1
	var nova: TraitData = _gl.registry.get_trait(&"MEC_KILL_BLAST")
	var nova_ok := 0
	for i in range(2):
		if gatling.attach_trait(nova):
			nova_ok += 1
	var fractal: TraitData = _gl.registry.get_trait(&"MEC_FRACTAL")
	var fractal_ok := 0
	for i in range(2):
		if gatling.attach_trait(fractal):
			fractal_ok += 1
	print("boot.词条：PIERCE×%d/3 MULTI×%d/2 BOUNCE×%d/3 NOVA×%d/2 FRACTAL×%d/2（挂载回执）"
		% [pierce_ok, multi_ok, bounce_ok, nova_ok, fractal_ok])
	if _gl.player.mirror_count() != 0:
		push_error("[probe] 镜面数 %d ≠ 0（夹具异常）" % _gl.player.mirror_count())
		_fails += 1
		return false
	_gl.stage_probe_enabled = true            # r224 同款：段探针开（形态对齐，清点不消费）
	print("boot.深载哨兵：fullload=1 位图=1 补烤=1 结算帽=-3 tier=2 帧率优先（vc33 深载稳态档）")
	if not _load_composition():
		return false
	print("boot：grove w16 构成 %d 敌种池（%s）压血×%.2f；位图就绪=%d" % [
		_comp.size(), _comp_summary(), ENEMY_HP_SCALE,
		1 if PopupGlyphAtlas.ready() else 0])
	return true


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
		var data: EnemyData = src.duplicate()
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


# ── 驻场补位/风筝（r224 同构）───────────────────────────────────────

func _kite(p_frame: int) -> void:
	var ang := float(p_frame) * 0.35 / 60.0
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


func _topup() -> void:
	var alive: int = _gl.spawner.active.size()
	var want: int = mini(TOPUP_PER_FRAME, HOLD - alive)
	for i in range(want):
		_spawn_one()


func _pump_process_budget() -> void:
	# 真机「墙钟≈仿真钟」对齐（r224 夹具未覆盖面）：手动 _physics_process 驱动下引擎
	# _process 不走——DeathPop(0.2s)/BlastStarFx(0.5s)/PoisonSplash(0.38s) 等 _process
	# 驱动的一次性演出件永不过期，清点会假性累积（初版实证 1186 件滞留）。每物理步后
	# 泵引擎帧至累计墙钟 ≥ 1/60s——_process 时钟按真机 60Hz 节拍推进，演出件按真实
	# 寿命到期自清。游戏逻辑全走 _physics_process（手动），泵帧不双推游戏态。
	var t0 := Time.get_ticks_usec()
	while Time.get_ticks_usec() - t0 < 16667:
		await tree.process_frame


# ── 对象谱清点（本轮核心）───────────────────────────────────────────

func _census(p_frame: int) -> Dictionary:
	# 实体子树归属表：家族根的 CanvasItem 后代归入何族（""=不传播——各子树根独立
	# 分类；初版两 bug 已修：其他族向子级级联致全树塌「其他」；敌子件不自传播致
	# HitShape 孙辈漏入「其他」）
	const ENTITY_OWNER := {"敌本体": "敌子件", "敌子件": "敌子件", "弹": "弹", "碎片": "碎片",
		"跳字": "跳字", "网": "网", "玩家": "玩家", "UI": "UI"}
	var fams: Dictionary = {}            # fam -> {vis,hid,eff,roots,children,detail,samples}
	var total_ci := 0
	var total_nodes := 0
	var eff_vis := 0
	var queue: Array = [[tree.root, ""]]
	while not queue.is_empty():
		var head: Array = queue.pop_front()
		var n: Node = head[0]
		var owner: String = head[1]
		total_nodes += 1
		var fam := owner
		if fam.is_empty():
			fam = _classify_root(n)
		var child_owner := String(ENTITY_OWNER.get(fam, ""))
		if n is CanvasItem:
			total_ci += 1
			var ci := n as CanvasItem
			var eff := ci.is_visible_in_tree()
			if eff:
				eff_vis += 1
			_bucket(fams, fam, ci.visible, eff, ci, owner.is_empty())
		for c in n.get_children():
			queue.append([c, child_owner])
	fams["磁"] = fams.get("磁", {"vis": 0, "hid": 0, "eff": 0, "roots": 0, "children": 0,
		"detail": {}, "samples": {}})   # 磁=距离判定无画件（头注口径），显式占 0 登记
	var proj_stats: Dictionary = (_gl.pools[&"projectile"] as ProjectilePool).stats()
	var live := {
		"enemies": _gl.spawner.active.size(),
		"proj_live": int(proj_stats["live"]),
		"homing_live": int((_gl.pools[&"homing"] as ProjectilePool).stats()["live"]),
		"popup_live": _gl.popup_manager.active_popups,
		"xp_live": int((_gl.pools[&"xp"] as XPPool).stats()["live"]),
		"particle_live": int((_gl.pools[&"particle"] as ParticlePool).stats()["live"]),
		"laser_live": int((_gl.pools[&"laser"] as LaserBeamPool).stats()["live"]),
		"proj_capacity": int(proj_stats["capacity"]),
		"proj_free": int(proj_stats["free"]),
		"proj_runtime_inst": int(proj_stats["runtime_instantiates"]),
		"o_headless": RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
	}
	return {"frame": p_frame, "fams": fams, "total_ci": total_ci,
		"total_nodes": total_nodes, "eff_vis": eff_vis, "live": live}


func _classify_root(p_n: Node) -> String:
	if p_n is Enemy:
		return "敌本体"
	if p_n is ProjectileBase:
		return "弹"
	if p_n is XpShard:
		return "碎片"
	if p_n is DamagePopup:
		return "跳字"
	if p_n is LaserBeam:
		return "网"
	if p_n is Player:
		return "玩家"
	if p_n is Telegraph.TelegraphCircle or p_n is Telegraph.TelegraphFan \
			or p_n is Telegraph.TelegraphLine:
		return "预警件"                 # 内部类 resource_path 为空——按类型显式识别
	if p_n is Enemy.DeathPop or p_n is Enemy.PoisonSplash or p_n is GameLoop.BlastStarFx \
			or p_n is GameLoop.LevelBurst:
		return "死亡演出件"             # _process 驱动一次性演出件（泵帧口径下按寿命自清）
	if p_n is Enemy.BossMine or p_n is Enemy.BossSweep or p_n is Enemy.HazardPool:
		return "Boss战场件"             # 本夹具无 Boss（预期 0——留名防漏归「其他」）
	if p_n is HUD or p_n is BossBar or p_n is HurtIndicator or p_n is GameOverScreen \
			or p_n is MenuScreen or p_n is SettingsPanel or p_n is PauseOverlay \
			or p_n is ShopUi or p_n is CardSelectUI:
		return "UI"
	if p_n is GPUParticles2D:
		return "粒子发射器"
	if String(p_n.name).begins_with("TexBucket"):
		return "贴图桶"
	var sc: Script = p_n.get_script()
	if sc is GDScript and String(sc.resource_path).find("telegraph.gd") >= 0:
		return "预警件"
	return "其他"


func _bucket(p_fams: Dictionary, p_fam: String, p_vis: bool, p_eff: bool,
		p_n: CanvasItem, p_is_root: bool) -> void:
	if not p_fams.has(p_fam):
		p_fams[p_fam] = {"vis": 0, "hid": 0, "eff": 0, "roots": 0, "children": 0,
			"detail": {}, "samples": {}}
	var d: Dictionary = p_fams[p_fam]
	if p_vis:
		d["vis"] = int(d["vis"]) + 1
	else:
		d["hid"] = int(d["hid"]) + 1
	if p_eff:
		d["eff"] = int(d["eff"]) + 1
	if p_is_root:
		d["roots"] = int(d["roots"]) + 1
	else:
		d["children"] = int(d["children"]) + 1
	var det: Dictionary = d["detail"]
	var key := _det_key(p_n)
	det[key] = int(det.get(key, 0)) + 1
	var samples: Dictionary = d["samples"]   # key -> Array[路径]（每构成键 2 例）
	if not samples.has(key):
		samples[key] = []
	var arr: Array = samples[key]
	if arr.size() < 2:
		arr.append(_short_path(p_n))


func _det_key(p_n: Node) -> String:
	if p_n is Telegraph.TelegraphCircle:
		return "telegraph_circle"
	if p_n is Telegraph.TelegraphFan:
		return "telegraph_fan"
	if p_n is Telegraph.TelegraphLine:
		return "telegraph_line"
	if p_n is Enemy.DeathPop:
		return "death_pop"
	if p_n is Enemy.PoisonSplash:
		return "poison_splash"
	if p_n is GameLoop.BlastStarFx:
		return "blast_star_fx"
	if p_n is GameLoop.LevelBurst:
		return "level_burst"
	var sc: Script = p_n.get_script()
	if sc is GDScript:
		var path := String(sc.resource_path)
		if not path.is_empty():
			return path.get_file()
		return "inner_script"
	return p_n.get_class()


func _short_path(p_n: Node) -> String:
	var p := String(p_n.get_path())
	var prefix := "/root/%s/" % _gl.name
	if p.begins_with(prefix):
		return p.substr(prefix.length())
	return p


# ── 汇总报告 ────────────────────────────────────────────────────────

func _report(p_snaps: Array[Dictionary]) -> void:
	if p_snaps.is_empty():
		_gate("G0 清点可行：至少 1 次快照", false, "0 次快照")
		return
	var fam_order: Array[String] = ["敌本体", "敌子件", "弹", "碎片", "跳字", "网", "磁",
		"UI", "玩家", "粒子发射器", "贴图桶", "预警件", "死亡演出件", "Boss战场件", "其他"]
	var keys: Array = []
	for s in p_snaps:
		for k in (s["fams"] as Dictionary):
			if not keys.has(k):
				keys.append(k)
	for extra in keys:
		if not fam_order.has(extra):
			fam_order.append(extra)
	# 中位快照（构成明细/样例取自它——与中位计数同源，避免 max/median 混口径）
	var med_snap: Dictionary = p_snaps[0]
	var totals: Array[int] = []
	for s in p_snaps:
		totals.append(int(s["total_ci"]))
	var sorted_totals := totals.duplicate()
	sorted_totals.sort()
	var med_total: int = sorted_totals[sorted_totals.size() / 2]
	for s in p_snaps:
		if int(s["total_ci"]) == med_total:
			med_snap = s
			break
	var med_eff := _median_i(p_snaps.map(func(s: Dictionary) -> int: return int(s["eff_vis"])))
	var med_nodes := _median_i(p_snaps.map(func(s: Dictionary) -> int: return int(s["total_nodes"])))
	var med_by_fam: Dictionary = {}
	var sum_vis := 0
	var sum_hid := 0
	var sum_eff := 0
	for fam in fam_order:
		var vis_arr: Array[int] = []
		var hid_arr: Array[int] = []
		var eff_arr: Array[int] = []
		for s in p_snaps:
			var fams: Dictionary = s["fams"]
			var fd: Dictionary = fams.get(fam, {})
			vis_arr.append(int(fd.get("vis", 0)))
			hid_arr.append(int(fd.get("hid", 0)))
			eff_arr.append(int(fd.get("eff", 0)))
		med_by_fam[fam] = {"vis": _median_i(vis_arr), "hid": _median_i(hid_arr),
			"eff": _median_i(eff_arr)}
		sum_vis += _median_i(vis_arr)
		sum_hid += _median_i(hid_arr)
		sum_eff += _median_i(eff_arr)
	print("══ 对象谱构成表（%d 次快照取中位；own visible 口径，另列有效可见）══" % p_snaps.size())
	for fam in fam_order:
		var m: Dictionary = med_by_fam[fam]
		var total := int(m["vis"]) + int(m["hid"])
		if total == 0 and fam != "磁":
			continue
		var detail := _detail_line(med_snap, fam)
		var samples := _samples_line(med_snap, fam)
		print("[%s] 可见own=%d 隐藏own=%d 合计=%d 有效可见=%d | %s | 例 %s" % [
			fam, int(m["vis"]), int(m["hid"]), total, int(m["eff"]), detail, samples])
	print("合计：canvas item=%d（own可见=%d / own隐藏=%d / 有效可见=%d）；全树节点=%d"
		% [med_total, sum_vis, sum_hid, sum_eff, med_nodes])
	var lv: Dictionary = _median_d(p_snaps.map(func(s: Dictionary) -> Dictionary: return s["live"]))
	print("池对账：敌=%d 弹=%d(容%d 闲%d 运行期实例化%d) 自导=%d 跳字=%d 碎片=%d 粒子=%d 光束=%d | headless o=%d（渲染面不可复现——r224 同款披露）"
		% [int(lv["enemies"]), int(lv["proj_live"]), int(lv["proj_capacity"]),
			int(lv["proj_free"]), int(lv["proj_runtime_inst"]), int(lv["homing_live"]),
			int(lv["popup_live"]), int(lv["xp_live"]), int(lv["particle_live"]),
			int(lv["laser_live"]), int(lv["o_headless"])])
	var proj: Dictionary = med_by_fam.get("弹", {"vis": 0, "hid": 0})
	var enemy: Dictionary = med_by_fam.get("敌本体", {"vis": 0, "hid": 0})
	_gate("G0 清点可行：总 canvas item ≥ 1500", med_total >= 1500, "中位 %d" % med_total)
	_gate("G1 深载稳态：敌驻场中位 ∈ [115,125] 且敌本体可见=驻场",
		int(lv["enemies"]) >= 115 and int(lv["enemies"]) <= 125
			and int(enemy["vis"]) == int(lv["enemies"]),
		"池读 %d / 谱读 %d" % [int(lv["enemies"]), int(enemy["vis"])])
	var i1 := "I1 总量带对照：中位 %d（真机 o 2100-2700——口径不同：树清点含隐藏件为上界口径，o=渲染提交对象；有效可见 %d 为 o 的近邻口径）" % [med_total, sum_eff]
	_info(i1)
	var i2 := "I2 弹池对账：弹家族=%d（池容 %d+自导 24 根，子件 Sprite2D ×1/根）" % [int(proj["vis"]) + int(proj["hid"]), int(lv["proj_capacity"])]
	_info(i2)
	var i3 := "I3 不可见项合计：own隐藏 %d + own可见但树内不可见 %d = %d（占 %d%%——o2500 中 ~2000 个非实体项的构成来源：池内闲置+敌隐藏子件+UI 关层残 own 旗）" % [sum_hid, sum_vis - sum_eff, sum_hid + sum_vis - sum_eff, (sum_hid + sum_vis - sum_eff) * 100 / maxi(1, med_total)]
	_info(i3)


func _detail_line(p_snap: Dictionary, p_fam: String) -> String:
	var fams: Dictionary = p_snap["fams"]
	if not fams.has(p_fam):
		return "（空）"
	var det: Dictionary = fams[p_fam]["detail"]
	var entries: Array = det.keys()
	entries.sort_custom(func(a, b): return int(det[a]) > int(det[b]))
	var parts: Array[String] = []
	for i in range(mini(6, entries.size())):
		parts.append("%s×%d" % [String(entries[i]), int(det[entries[i]])])
	if parts.is_empty():
		return "（空）"
	return " ".join(parts)


func _samples_line(p_snap: Dictionary, p_fam: String) -> String:
	var fams: Dictionary = p_snap["fams"]
	if not fams.has(p_fam):
		return "—"
	var samples: Dictionary = fams[p_fam]["samples"]
	var det: Dictionary = fams[p_fam]["detail"]
	var entries: Array = det.keys()
	entries.sort_custom(func(a, b): return int(det[a]) > int(det[b]))
	var out: Array[String] = []
	for i in range(mini(3, entries.size())):
		var k: String = String(entries[i])
		var arr: Array = samples.get(k, [])
		if not arr.is_empty():
			out.append("%s→%s" % [k, String(arr[0])])
		if out.size() >= 3:
			break
	if out.is_empty():
		return "—"
	return " ".join(out)


func _gate(p_label: String, p_ok: bool, p_detail: String) -> void:
	if p_ok:
		print("  PASS | %s（%s）" % [p_label, p_detail])
	else:
		print("  FAIL | %s（%s）" % [p_label, p_detail])
		_fails += 1


func _info(p_line: String) -> void:
	print("  INFO | %s" % p_line)


# ── 收尾/统计 ───────────────────────────────────────────────────────

func _teardown() -> void:
	DamagePipeline.settle_budget_override = -1
	DamagePopup.bitmap_override = -1
	PopupGlyphAtlas.runstart_bake_override = -1
	Enemy.fullload_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.set_process(true)
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame


func _median_i(p_arr: Array) -> int:
	if p_arr.is_empty():
		return 0
	var s := p_arr.duplicate()
	s.sort()
	return int(s[s.size() / 2])


func _median_d(p_arr: Array) -> Dictionary:
	# 字典序列中位：逐键取中位（键集取并集）
	var keys: Array = []
	for d in p_arr:
		for k in (d as Dictionary):
			if not keys.has(k):
				keys.append(k)
	var out: Dictionary = {}
	for k in keys:
		var vals: Array = []
		for d in p_arr:
			vals.append(int((d as Dictionary).get(k, 0)))
		out[k] = _median_i(vals)
	return out

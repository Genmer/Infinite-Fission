# tests/qa_r293qa_render_cases.gd
# R293 QA 独立探针用例体（独立验收，不与开发套件 qa_r293_multimesh 共用断言路径）。
# 契约来源 = R293 验收点 1-6：
#   点1 分桶实例数==活口数（team×贴图双维）——真源=pool.active_projectiles() 池账本
#       （非本套自持清单）：grouped_counts / host.mirror_count / host._mm_lists /
#       逐桶 visible_instance_count 四源对账；实例序==place 序。
#   点2 transform/modulate 与池状态逐帧一致+元素染色保真——多帧运动/自旋跟随
#       （窗口态逐位 parity / headless 结构降级双态，QA-R240-002 同口径）；元素=
#       贴图实例互异（分桶即分色）+MMI.texture 身份等同+弹侧恒白+实例色 parity。
#   点3 拖尾/特效未误伤——回旋自旋通道/灵剑镜像+根可见/R291 拖尾门口径 16 拍
#       独立复算（deep 4 / 关 8——与开发套件 8 拍 2/4 同链路不同拍数）。
#   点4 池 acquire/release/惰性归位契约——lazy 注销留桶/LIFO 复用复注册/留桶空闲弹
#       幽灵负向探针（off→on 翻转追赶扫不复注册）/12 轮 churn 守恒/FORCED 强收守恒/
#       关态归位池根。
#   点5 boost 关侧逐位不变——关态零注册零层/深载承重墙/BODY_MM 真实换键链回退与
#       复原（双向）/关态新贴图桶零 BodyMM（DEN 维度——开发套件用 HYD）。
#   点6 S1/S7 短路臂共门——place_skip_count 恰 host 独写（越权注册即爆）/sync_skip
#       窗口期递增+复位收敛/旗与计数面复位。
# 夹具：main.tscn 真链 boot→MENU（战斗循环停摆=手动 tick/无出界回收），手动
# acquire→注入→spawn（武器侧契约最小夹具）；静态注入口 boost_override/deep_override/
# trail_halffreq_override/BODY_MM/shortcircuit 双臂全部复位；收尾走 R270 盘档毒配方。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const EXPECTED_TOTAL := 30
const MM := preload("res://scripts/render/projectile_body_mm.gd")

var tree: SceneTree
var _gl: GameLoop = null
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _mine: Array[ProjectileBase] = []         # 本套经手弹（收尾归还用——断言真源恒为池账本）
var _saved_settings: Dictionary = {}
var _seq: int = 0                             # 出生位散布序（屏内防出界回收）
var _pol0: int = -1                           # 污染基线（boot 后取一次）
var _base_mc: int = -1                        # 镜像计数基线（P1 前）
var _ltg: ProjectileBase = null               # 点2 承载弹
var _ltg_rot0: float = 0.0
var _idle: ProjectileBase = null              # 点4 LIFO 复用载体（4a 释→4b 复用）
var _ghost: ProjectileBase = null             # 点4c 留桶空闲幽灵载体（沉空闲栈顶之下）
var _mark_place: int = 0                      # 点6 计数器快照
var _mark_sync: int = 0
var _sync_during_window: int = 0
var _phase_gaps: Array[String] = []
var _phase_tally: int = 0


func _tally_phase(p_name: String, p_expect: int) -> void:
	var got: int = _pass + _fail - _phase_tally
	if got != p_expect:
		_phase_gaps.append("%s:%d/%d" % [p_name, got, p_expect])
	_phase_tally = _pass + _fail


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


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(293293)
	_saved_settings = Meta._settings.duplicate()
	_boot_game_loop()
	var boot_frames := 0
	while boot_frames < 600 and not bool(_gl.get("boot_ready")):
		await tree.process_frame
		boot_frames += 1
	_p0_checks()
	_tally_phase("p0", 2)
	# ── 点1 分桶对账（boost 开） ──
	PerfGovernor.boost_override = 1
	_p1_place()
	_p1_counts_sync()
	await tree.process_frame
	await tree.process_frame
	_p1_counts_pumped()
	_release_all_mine()
	_p1_released()
	_tally_phase("p1", 5)
	PerfGovernor.boost_override = 0
	await tree.process_frame
	await tree.process_frame
	# ── 点2 transform/染色（boost 重开） ──
	PerfGovernor.boost_override = 1
	_p2a_place()
	await tree.process_frame
	await tree.process_frame
	_p2a_check()
	_p2b_move()
	await tree.process_frame
	await tree.process_frame
	_p2b_check()
	_p2c_place()
	_p2c_check()
	_release_all_mine()
	PerfGovernor.boost_override = 0
	await tree.process_frame
	await tree.process_frame
	_tally_phase("p2", 5)
	# ── 点3 拖尾/特效（boost 重开） ──
	PerfGovernor.boost_override = 1
	_p3_place()
	_p3_check()
	_p3_gate()
	_release_all_mine()
	PerfGovernor.boost_override = 0
	await tree.process_frame
	await tree.process_frame
	_tally_phase("p3", 3)
	# ── 点4 池契约（boost 重开） ──
	PerfGovernor.boost_override = 1
	_p4a_lazy()
	_p4b_reuse()
	_p4c_arm_off()
	await tree.process_frame
	await tree.process_frame
	_p4c_arm_on()
	await tree.process_frame
	await tree.process_frame
	_p4c_check()
	_p4d_churn()
	_p4e_forced()
	_tally_phase("p4", 5)
	PerfGovernor.boost_override = 0
	await tree.process_frame
	await tree.process_frame
	# ── 点5 关侧逐位 + 点4f 关态归位 ──
	_p5_off_checks()
	PerfGovernor.boost_override = 1
	_p5c_bodymm()
	PerfGovernor.boost_override = 0
	await tree.process_frame
	await tree.process_frame
	_tally_phase("p5", 6)
	# ── 点6 短路臂（boost 开） ──
	PerfGovernor.boost_override = 1
	_p6a_s1()
	_p6b_setup()
	await tree.process_frame
	_p6b_arm()
	await tree.process_frame
	await tree.process_frame
	await tree.process_frame
	_p6b_restore()
	await tree.process_frame
	await tree.process_frame
	_p6b_check()
	_p6c_mark()
	await tree.process_frame
	_p6c_check()
	_tally_phase("p6", 3)
	_cleanup()
	await tree.process_frame
	_check("⑧ 套件总项数（EXPECTED=%d——假绿防线）" % EXPECTED_TOTAL,
		_pass + _fail + 1 == EXPECTED_TOTAL, "实得 %d" % (_pass + _fail + 1))
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("探针汇总：%d/%d 通过" % [_pass, _pass + _fail])
	if _fail > 0:
		var mismatch := ""
		if _pass + _fail + 1 != EXPECTED_TOTAL:
			mismatch = "｜计数缺口：%d≠%d（有用例中途未执行）" % [_pass + _fail + 1, EXPECTED_TOTAL]
		if not _phase_gaps.is_empty():
			mismatch += "｜阶段缺口：" + "、".join(_phase_gaps)
		print("FAIL 合并明细：%s%s" % [" ⦿ ".join(_failures), mismatch])


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R293QARenderProbeGL"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.state = GameConst.GameStatus.MENU
	_gl.player.global_position = Vector2(360.0, 900.0)


func _pool() -> ProjectilePool:
	return _gl.pools[&"projectile"] as ProjectilePool


func _host() -> TexBucketHost:
	return _pool().bucket_host as TexBucketHost


func _headless() -> bool:
	return DisplayServer.get_name() == "headless"


func _spawn(p_team: int, p_element: int, p_extra: Dictionary = {}) -> ProjectileBase:
	# 手动注入口（武器侧 acquire→注入→spawn 契约最小夹具）：无词条/无管线/无网格——
	# 纯视觉与池链路径。出生位屏内散布（防出界回收扰动对账）。
	var pool := _pool()
	var pb := pool.acquire(p_team)
	if pb == null:
		return null
	pb.pool = pool
	pb.enemy_grid = null
	pb.elemental = null
	pb.damage_pipeline = null
	var params := {
		"velocity": Vector2(200.0, 0.0) if p_team == 0 else Vector2(-120.0, 0.0),
		"lifetime": 30.0,
		"pierce": 1,
		"bounces": 0,
		"hitbox_radius": 8.0,
		"element": p_element,
		"team": p_team,
		"position": Vector2(150.0 + float((_seq % 12) * 29.0), 300.0 + float((_seq % 5) * 55.0)),
	}
	_seq += 1
	params.merge(p_extra, true)
	pb.spawn(params)
	_mine.append(pb)
	return pb


func _release_all_mine() -> void:
	# 归还本套经手且仍活着的弹（is_clean=true=已归还件跳过——重复归还会被池拦截计数）
	var pool := _pool()
	for pb in _mine.duplicate():
		if pb != null and is_instance_valid(pb) and not pb.is_clean:
			pool.release(pb)
	_mine.clear()


func _bucket_mmi_count(p_bucket: Node) -> int:
	var n := 0
	if p_bucket != null:
		for c in p_bucket.get_children():
			if c is MultiMeshInstance2D:
				n += 1
	return n


# ═══ 点0 夹具 ═══════════════════════════════════════════════════════
func _p0_checks() -> void:
	print("── 点0 夹具 ──")
	_check("0a boot 成功（main.tscn 真链）",
		_gl != null and bool(_gl.get("boot_ready")), str(_gl.get("boot_fatal")))
	_pol0 = int((_pool().stats())["pollution"])
	_base_mc = _host().mirror_count()
	_check("0b 关态默认：boost_mode 假 且 零册零层零分桶（懒建承诺+残留检测）",
		not PerfGovernor.boost_mode() and _base_mc == 0 and MM.tracked_count() == 0
			and MM.layer_node() == null and MM.grouped_counts().is_empty(),
		"mc=%d tc=%d" % [_base_mc, MM.tracked_count()])


# ═══ 点1 分桶实例数==活口数（真源=池账本） ═══════════════════════════
func _p1_place() -> void:
	print("── 点1 分桶对账（真源=pool.active_projectiles 池账本） ──")
	for i in range(4):
		_spawn(0, GameConst.Element.KIN)
	for i in range(3):
		_spawn(0, GameConst.Element.FIR)
	for i in range(2):
		_spawn(1, GameConst.Element.KIN)


func _p1_counts_sync() -> void:
	var host := _host()
	var ledger: Array[Node2D] = _pool().active_projectiles()
	var expect: Dictionary = {}
	for n in ledger:
		var p := n as ProjectileBase
		var key := Vector2i(int(p._sprite.texture.get_instance_id()), p.team)
		expect[key] = int(expect.get(key, 0)) + 1
	var got: Dictionary = MM.grouped_counts()
	_check("1a grouped_counts==池账本口径（键=(贴图实例id,team)；KIN0×4/FIR0×3/敌1×2）",
		got == expect and expect.size() == 3,
		"expect=%s got=%s" % [str(expect), str(got)])
	var all_keyed := true
	for n in ledger:
		var p := n as ProjectileBase
		if host.mirror_tex_of(p) != p._sprite.texture:
			all_keyed = false
	_check("1b host 在册：逐弹 mirror_tex_of==自身贴图 且 mirror_count==基线+活口数",
		all_keyed and host.mirror_count() == _base_mc + ledger.size(),
		"mc=%d/%d" % [host.mirror_count(), _base_mc + ledger.size()])
	# 1d 实例序==place 序（同桶 KIN0 四件按出生序索引递增）
	var kin_tex: Texture2D = null
	for n in ledger:
		var p := n as ProjectileBase
		if p.team == 0 and p.element == GameConst.Element.KIN:
			kin_tex = p._sprite.texture
			break
	var lst: Array = host._mm_lists.get(kin_tex)
	var order_ok := lst != null
	var prev_idx := -1
	for pb in _mine:
		if pb != null and pb.team == 0 and pb.element == GameConst.Element.KIN:
			var idx := lst.find(pb)
			if idx < 0 or idx <= prev_idx:
				order_ok = false
			prev_idx = idx
	_check("1d 实例序==place 序（KIN0 桶出生序索引严格递增——绘制序与桶序同构）",
		order_ok, "prev=%d" % prev_idx)


func _p1_counts_pumped() -> void:
	var host := _host()
	var ledger: Array[Node2D] = _pool().active_projectiles()
	var per_tex: Dictionary = {}
	for n in ledger:
		var p := n as ProjectileBase
		var tid := int(p._sprite.texture.get_instance_id())
		per_tex[tid] = int(per_tex.get(tid, 0)) + 1
	var vis_ok := true
	var vis_detail := ""
	for tid in per_tex:
		var tex := instance_from_id(int(tid)) as Texture2D
		var mmi: MultiMeshInstance2D = host._mm_meshes.get(tex)
		var vis_n := mmi.multimesh.visible_instance_count if mmi != null else -1
		if mmi == null or vis_n != int(per_tex[tid]):
			vis_ok = false
			vis_detail += "tex%d:%d/%d " % [int(tid) % 1000, vis_n, int(per_tex[tid])]
	_check("1c 泵 2 帧后逐桶 visible_instance_count==该贴图活口数（4/3/2）",
		vis_ok, vis_detail)


func _p1_released() -> void:
	var host := _host()
	_check("1e 全释放后镜像回基线（release→unplace_lazy 注销链零泄漏）",
		host.mirror_count() == _base_mc and MM.grouped_counts().is_empty(),
		"mc=%d/%d" % [host.mirror_count(), _base_mc])


# ═══ 点2 transform 逐帧一致+元素染色保真（双态） ═════════════════════
func _p2a_place() -> void:
	print("── 点2 transform 逐帧一致+染色保真（窗口 parity / headless 结构） ──")
	_ltg = _spawn(0, GameConst.Element.LTG, {"position": Vector2(240.0, 380.0)})
	if _ltg != null:
		_ltg_rot0 = _ltg._sprite.rotation
		_ltg.tick(1.0 / 60.0)                  # 电花自旋 +10rad/s（慢路径 tick 真链）
		_ltg.tick(1.0 / 60.0)


func _p2a_check() -> void:
	var host := _host()
	var spin_ok := _ltg != null and _ltg._sprite.rotation > _ltg_rot0 + 0.2
	var key_ok := _ltg != null and host.mirror_tex_of(_ltg) != null
	var parity := true
	var detail := "headless 结构态"
	if not _headless() and key_ok:
		var tex: Texture2D = host.mirror_tex_of(_ltg)
		var lst: Array = host._mm_lists.get(tex)
		var idx := lst.find(_ltg)
		if idx < 0:
			parity = false
			detail = "实例索引缺失"
		else:
			var mmi: MultiMeshInstance2D = host._mm_meshes.get(tex)
			var ta: Transform2D = mmi.multimesh.get_instance_transform_2d(idx)
			var want: Transform2D = _ltg.global_transform * _ltg._sprite.transform
			parity = (ta.origin.distance_to(want.origin) < 0.001
				and absf(ta.get_rotation() - want.get_rotation()) < 0.001
				and ta.get_scale().distance_to(want.get_scale()) < 0.001)
			detail = "got=%s want=%s" % [str(ta.origin), str(want.origin)]
	_check("2a LTG 自旋跟随：rotation 真增长+注册键在位（窗口态实例 transform==owner.global×body.local 逐位 parity）",
		spin_ok and key_ok and parity, detail)


func _p2b_move() -> void:
	if _ltg != null and is_instance_valid(_ltg):
		_ltg.global_position = Vector2(333.0, 555.0)
		_ltg._sprite.position = Vector2(4.0, -6.0)
		_ltg._sprite.rotation = 1.1


func _p2b_check() -> void:
	var host := _host()
	var key_ok := _ltg != null and host.mirror_tex_of(_ltg) != null
	var tex: Texture2D = host.mirror_tex_of(_ltg) if key_ok else null
	var mmi: MultiMeshInstance2D = host._mm_meshes.get(tex) if tex != null else null
	var idx := -1
	if tex != null:
		idx = (host._mm_lists.get(tex) as Array).find(_ltg)
	var follow_ok := key_ok and mmi != null and mmi.multimesh.visible_instance_count == 1
	var detail := "headless 结构态（vis=%d）" % (mmi.multimesh.visible_instance_count if mmi != null else -1)
	if not _headless() and follow_ok:
		var ta: Transform2D = mmi.multimesh.get_instance_transform_2d(idx)
		var want: Transform2D = _ltg.global_transform * _ltg._sprite.transform
		follow_ok = (ta.origin.distance_to(want.origin) < 0.001
			and absf(ta.get_rotation() - want.get_rotation()) < 0.001
			and ta.get_scale().distance_to(want.get_scale()) < 0.001)
		detail = "got=%s want=%s" % [str(ta.origin), str(want.origin)]
	_check("2b 移动+本体偏移/旋转跟随（泵 2 帧后实例 transform 与池状态逐帧一致——窗口态 parity）",
		follow_ok, detail)
	# 2e 实例色 parity（同帧同弹）
	var color_ok := mmi != null and mmi.multimesh.use_colors
	var cdetail := "headless：use_colors 在位（写路径不可读回）"
	if not _headless() and follow_ok:
		var ica: Color = mmi.multimesh.get_instance_color(idx)
		var want_c: Color = _ltg.modulate * _ltg._sprite.modulate * _ltg._sprite.self_modulate
		color_ok = (absf(ica.r - want_c.r) < 0.002 and absf(ica.g - want_c.g) < 0.002
			and absf(ica.b - want_c.b) < 0.002 and absf(ica.a - want_c.a) < 0.002)
		cdetail = "got=%s want=%s" % [str(ica), str(want_c)]
	_check("2e 实例色==root.modulate×body.modulate×self_modulate（弹侧恒白——染色走贴图通道零损失）",
		color_ok, cdetail)
	if _ltg != null and is_instance_valid(_ltg) and not _ltg.is_clean:
		_pool().release(_ltg)
		_mine.erase(_ltg)


func _p2c_place() -> void:
	# 元素全家福：KIN/FIR/ICE/LTG/HYD 玩家五元素 + 敌方（KIN）——贴图维度互异探针
	_spawn(0, GameConst.Element.KIN)
	_spawn(0, GameConst.Element.FIR)
	_spawn(0, GameConst.Element.ICE)
	_spawn(0, GameConst.Element.LTG)
	_spawn(0, GameConst.Element.HYD)
	_spawn(1, GameConst.Element.KIN)


func _p2c_check() -> void:
	var host := _host()
	var ledger: Array[Node2D] = _pool().active_projectiles()
	var ids: Array[int] = []
	var white_ok := ledger.size() == 6
	var bucket_ok := ledger.size() == 6
	var bdetail := ""
	for n in ledger:
		var p := n as ProjectileBase
		var tid := int(p._sprite.texture.get_instance_id())
		if not ids.has(tid):
			ids.append(tid)
		if p._sprite.modulate != Color.WHITE or p._sprite.self_modulate != Color.WHITE:
			white_ok = false
		var bucket: Node2D = host._buckets.get(p._sprite.texture)
		if bucket == null or bucket.get_child_count() == 0 \
				or not (bucket.get_child(0) is MultiMeshInstance2D) \
				or (bucket.get_child(0) as MultiMeshInstance2D).texture != p._sprite.texture:
			bucket_ok = false
			bdetail = "桶/BodyMM 首位或贴图身份不等（tex%d）" % (tid % 1000)
	_check("2c 元素染色保真：六弹贴图实例互异（分桶即分色）且各桶 BodyMM.texture 身份等同弹贴图",
		ids.size() == 6 and bucket_ok, "ids=%d %s" % [ids.size(), bdetail])
	_check("2d 弹侧染色不落 modulate 通道（六弹 modulate/self_modulate 恒白）",
		white_ok, str(ledger.size()))


# ═══ 点3 拖尾/特效未误伤 ═════════════════════════════════════════════
func _p3_place() -> void:
	print("── 点3 拖尾/特效未误伤 ──")
	_spawn(0, GameConst.Element.KIN, {"boomerang": true, "range": 300.0,
		"position": Vector2(360.0, 880.0)})
	_spawn(0, GameConst.Element.KIN, {"flight_sword": true,
		"position": Vector2(420.0, 880.0)})


func _p3_check() -> void:
	var host := _host()
	var boom: ProjectileBase = null
	var sword: ProjectileBase = null
	for pb in _mine:
		if pb == null or not is_instance_valid(pb):
			continue
		if pb._boomerang:
			boom = pb
		elif pb._flight_sword:
			sword = pb
	var rot0 := 0.0
	if boom != null:
		rot0 = boom._sprite.rotation
		boom.tick(1.0 / 60.0)                  # 旋刃自旋 +16rad/s（慢路径 tick 真链）
	_check("3a 回旋弹：镜像在册+根可见（拖尾画布=弹根 _draw 保留）+旋刃自旋通道活（tick 后 rotation 真增长）",
		boom != null and host.mirror_tex_of(boom) != null and boom.visible
			and not boom._sprite.visible and boom._sprite.rotation > rot0 + 0.1,
		"boom=%s rot=%f" % [str(boom != null), (boom._sprite.rotation if boom != null else -1.0)])
	_check("3b 灵剑：镜像在册+根可见+本体隐（刺击残影=弹根 _draw 绘制面不被镜像杀）",
		sword != null and host.mirror_tex_of(sword) != null and sword.visible
			and not sword._sprite.visible,
		str(sword != null))


func _p3_gate() -> void:
	# R291 拖尾门口径独立复算（16 拍——开发套件 8 拍 2/4 的同链路不同拍数交叉验证）
	var probe := _spawn(0, GameConst.Element.KIN, {"position": Vector2(480.0, 880.0)})
	var due_deep := -1
	var due_plain := -1
	if probe != null:
		ProjectileBase.trail_halffreq_override = 1
		PerfGovernor.deep_override = 1
		due_deep = _count_trail_due(probe, 16)
		PerfGovernor.deep_override = 0
		due_plain = _count_trail_due(probe, 16)
		PerfGovernor.deep_override = -1
		ProjectileBase.trail_halffreq_override = -1
	_check("3c R291 拖尾半频门倍率逐位（16 拍 deep 4 置脏 / 关 8 置脏——镜像注册下门零位移）",
		due_deep == 4 and due_plain == 8, "deep=%d plain=%d" % [due_deep, due_plain])


func _count_trail_due(p_b: ProjectileBase, p_beats: int) -> int:
	p_b._trail_redraw_acc = 0.0
	var n := 0
	for i in range(p_beats):
		if p_b._trail_redraw_due(1.0 / 60.0):
			n += 1
	return n


# ═══ 点4 池 acquire/release/惰性归位契约 ═════════════════════════════
func _p4a_lazy() -> void:
	print("── 点4 池契约/惰性归位 ──")
	var pool := _pool()
	var host := _host()
	_idle = _spawn(0, GameConst.Element.ICE)
	if _idle != null:
		pool.release(_idle)                     # boost 开 → unplace_lazy（留桶不 reparent）
	_check("4a boost 开 release：镜像注销+留桶（parent≠池根）+根隐+is_clean+池账本剔除+零污染",
		_idle != null and host.mirror_tex_of(_idle) == null and _idle.get_parent() != pool
			and not _idle.visible and _idle.is_clean
			and not pool.active_projectiles().has(_idle)
			and int((pool.stats())["pollution"]) == _pol0,
		"reg=%s clean=%s" % [str(host.mirror_tex_of(_idle) == null), str(_idle.is_clean)])


func _p4b_reuse() -> void:
	var host := _host()
	# 注意：release 链 _reset_state→_sync_visual 会把贴图重排回 KIN 缺省——期望键须取
	# TextureFactory 静态缓存单例（同色同实例），不能读归还件残态。
	var ice_tex: Texture2D = TextureFactory.bead(
		PopPalette.ELEMENT_COLORS[GameConst.Element.ICE], 64)
	var rb := _spawn(0, GameConst.Element.ICE)  # LIFO：应复用同一件（保持活态）
	_check("4b 同变体 LIFO 复用：同件复落桶=复注册+贴图回 ICE 缓存实例+sprite 复隐",
		rb != null and rb == _idle and host.mirror_tex_of(rb) == ice_tex
			and rb._sprite.texture == ice_tex and not rb._sprite.visible,
		"same=%s reg=%s tex=%s" % [str(rb == _idle), str(host.mirror_tex_of(rb) != null),
			str(rb != null and rb._sprite.texture == ice_tex)])
	# 幽灵载体布局（LIFO 拓扑约束）：连续取两件→先释 g1 再释 g2——g1 沉到空闲栈顶之
	# 下，点4c 的新弹 acquire 只会弹 g2；g1 保持留桶空闲态（is_clean+根隐+已注销）。
	_ghost = _spawn(0, GameConst.Element.KIN)
	var g2 := _spawn(0, GameConst.Element.FIR)
	if _ghost != null:
		_pool().release(_ghost)
		_mine.erase(_ghost)
	if g2 != null:
		_pool().release(g2)
		_mine.erase(g2)


func _p4c_arm_off() -> void:
	PerfGovernor.boost_override = 0             # 关态翻转（层 _process 拆收——泵 2 帧在 run）


func _p4c_arm_on() -> void:
	PerfGovernor.boost_override = 1             # 重开：首注册重建层→首帧追赶扫（泵 2 帧在 run）
	_spawn(0, GameConst.Element.FIR, {"position": Vector2(520.0, 420.0)})


func _p4c_check() -> void:
	var host := _host()
	var fc: ProjectileBase = null
	for pb in _mine:
		if pb != null and is_instance_valid(pb) and not pb.is_clean \
				and pb.element == GameConst.Element.FIR:
			fc = pb
	_check("4c 幽灵负向探针：off→on 翻转追赶扫后 留桶空闲弹（栈顶之下）零复注册+根仍隐+sprite 已被拆收复原；新弹照常注册",
		_ghost != null and is_instance_valid(_ghost) and host.mirror_tex_of(_ghost) == null
			and not _ghost.visible and _ghost._sprite.visible
			and fc != null and host.mirror_tex_of(fc) != null,
		"ghost_reg=%s ghost_vis=%s sprite=%s fc=%s" % [str(host.mirror_tex_of(_ghost) == null),
			str(not _ghost.visible), str(_ghost._sprite.visible), str(fc != null)])
	if fc != null:
		_pool().release(fc)
		_mine.erase(fc)
	# 4b 的复用件（rb，追赶扫复注册态）归还清场——4d/4e 的守恒基线从零活口起算
	var pool4 := _pool()
	for pb in _mine.duplicate():
		if pb != null and is_instance_valid(pb) and not pb.is_clean:
			pool4.release(pb)
		_mine.erase(pb)
	_idle = null
	_ghost = null


func _p4d_churn() -> void:
	var pool := _pool()
	var host := _host()
	var base := host.mirror_count()
	var elems: Array[int] = [GameConst.Element.KIN, GameConst.Element.FIR, GameConst.Element.ICE]
	for i in range(12):
		var a := _spawn(0, elems[i % 3])
		var b := _spawn(1, GameConst.Element.KIN)
		if a != null:
			pool.release(a)
			_mine.erase(a)
		if b != null:
			pool.release(b)
			_mine.erase(b)
	_check("4d 12 轮混队混元素 acquire/release 环：镜像计数守恒+team1_live 归零+零污染",
		host.mirror_count() == base and pool.team1_live == 0
			and int((pool.stats())["pollution"]) == _pol0,
		"mc=%d/%d t1=%d" % [host.mirror_count(), base, pool.team1_live])


func _p4e_forced() -> void:
	var pool := _pool()
	var host := _host()
	var base := host.mirror_count()
	var f1 := _spawn(0, GameConst.Element.KIN)
	var f2 := _spawn(1, GameConst.Element.KIN)
	var f3 := _spawn(0, GameConst.Element.FIR)
	if f1 != null and f2 != null and f3 != null:
		pool.force_recycle_oldest()
		pool.force_recycle_oldest()
		pool.force_recycle_oldest()
	_check("4e FORCED 强收×3：镜像回基线+活口清零（强收链注销无泄漏）",
		host.mirror_count() == base and pool.active_projectiles().is_empty()
			and pool.total_active() == 0,
		"mc=%d/%d live=%d" % [host.mirror_count(), base, pool.total_active()])


# ═══ 点5 关侧逐位 + 4f 关态归位 ═══════════════════════════════════════
func _p5_off_checks() -> void:
	print("── 点5 boost 关侧逐位不变 ──")
	var pool := _pool()
	var host := _host()
	var a := _spawn(0, GameConst.Element.KIN)
	_check("5a 关态 spawn：sprite 照绘+零注册+零分桶+层无（懒建承诺——关态恒 null）",
		a != null and a._sprite.visible and host.mirror_tex_of(a) == null
			and host.mirror_count() == 0 and MM.grouped_counts().is_empty()
			and MM.layer_node() == null,
		"vis=%s mc=%d" % [str(a != null and a._sprite.visible), host.mirror_count()])
	if a != null:
		pool.release(a)
		_mine.erase(a)
	_check("4f 关态 release 归位池根（r214 现状口径逐位——unplace 非 lazy 分派）",
		a != null and is_instance_valid(a) and a.get_parent() == pool,
		"parent=%s" % str(a.get_parent() if a != null and is_instance_valid(a) else null))
	var d := _spawn(0, GameConst.Element.DEN)
	var d_bucket: Node2D = null
	if d != null:
		d_bucket = host._buckets.get(d._sprite.texture)
	_check("5d 关态新贴图桶（DEN 草）零 BodyMM（桶机制 R214 照走、镜像件不建）",
		d != null and d._sprite.visible and d_bucket != null
			and _bucket_mmi_count(d_bucket) == 0,
		"bucket=%s mmi=%d" % [str(d_bucket != null), _bucket_mmi_count(d_bucket)])
	if d != null:
		pool.release(d)
		_mine.erase(d)
	PerfGovernor.deep_override = 1
	_check("5b 深载承重墙：boost 关+deep_override=1 → deep_load 恒 false",
		not PerfGovernor.deep_load(), "")
	PerfGovernor.deep_override = -1


func _p5c_bodymm() -> void:
	var host := _host()
	var gc := _spawn(0, GameConst.Element.KIN)
	var rekey_ok := false
	if gc != null:
		MM.BODY_MM = false
		gc._vis_variant = -1                    # 真实换键链（反弹金染升格同链路）
		gc._sync_visual()                       # → _apply_visual_variant 尾 _place_in_bucket → notify_place
		rekey_ok = gc._sprite.visible and host.mirror_tex_of(gc) == null and host.mirror_count() == 0
	var gn := _spawn(0, GameConst.Element.FIR)  # 门关态新件（未经册记路径）
	_check("5c BODY_MM=false 单点回退：活弹真实换键链复显+注销 且 新 spawn 零注册零册记",
		gc != null and rekey_ok and gn != null and gn._sprite.visible
			and host.mirror_tex_of(gn) == null and not MM.is_tracked(gn),
		"rekey=%s gn_reg=%s" % [str(rekey_ok), str(gn != null and host.mirror_tex_of(gn) == null)])
	var reback_ok := false
	if gc != null:
		MM.BODY_MM = true
		gc._vis_variant = -1
		gc._sync_visual()
		reback_ok = not gc._sprite.visible and host.mirror_tex_of(gc) != null
	_check("5c2 门恢复：同弹再换键复隐+复注册（单点双向无残留）",
		reback_ok, str(reback_ok))
	if gc != null:
		_pool().release(gc)
		_mine.erase(gc)
	if gn != null:
		_pool().release(gn)
		_mine.erase(gn)


# ═══ 点6 S1/S7 短路臂共门（R271 verdict 保真） ═══════════════════════
func _p6a_s1() -> void:
	print("── 点6 S1/S7 短路臂共门 ──")
	var host := _host()
	_mark_place = TexBucketHost.place_skip_count
	TexBucketHost.shortcircuit_place = true
	var s1 := _spawn(0, GameConst.Element.GEO)  # 新贴图（GEO 岩）——S1 短路=place 早退不建桶
	var s2 := _spawn(1, GameConst.Element.KIN)
	var delta := TexBucketHost.place_skip_count - _mark_place
	_check("6a S1 共门：短路期 2 spawn 零注册零隐藏 且 place_skip_count 恰 +2（host 独写——门面越权注册即爆）",
		delta == 2 and s1 != null and s1._sprite.visible and s2 != null and s2._sprite.visible
			and host.mirror_tex_of(s1) == null and host.mirror_tex_of(s2) == null
			and not MM.is_tracked(s1),
		"delta=%d" % delta)
	TexBucketHost.shortcircuit_place = false
	if s1 != null:
		_pool().release(s1)
		_mine.erase(s1)
	if s2 != null:
		_pool().release(s2)
		_mine.erase(s2)


func _p6b_setup() -> void:
	_spawn(0, GameConst.Element.KIN)
	_spawn(0, GameConst.Element.KIN)
	_mark_sync = TexBucketHost.sync_skip_count


func _p6b_arm() -> void:
	TexBucketHost.shortcircuit_sync = true


func _p6b_restore() -> void:
	TexBucketHost.shortcircuit_sync = false
	_sync_during_window = TexBucketHost.sync_skip_count - _mark_sync


func _p6b_check() -> void:
	var host := _host()
	var kin_tex: Texture2D = null
	var vis_n := -1
	var reg_ok := true
	var hidden_ok := true
	for pb in _mine:
		if pb == null or not is_instance_valid(pb) or pb.is_clean:
			continue
		if kin_tex == null:
			kin_tex = pb._sprite.texture
		if host.mirror_tex_of(pb) == null:
			reg_ok = false
		if pb._sprite.visible:
			hidden_ok = false
	if kin_tex != null:
		var mmi: MultiMeshInstance2D = host._mm_meshes.get(kin_tex)
		vis_n = mmi.multimesh.visible_instance_count if mmi != null else -1
	_check("6b S7 共门：短路窗口 sync_skip_count 递增（≥3 帧）且复位后 visible 收敛==活口（计数器不脏）",
		_sync_during_window >= 3 and vis_n == 2 and reg_ok and hidden_ok,
		"win=%d vis=%d reg=%s hid=%s" % [_sync_during_window, vis_n, str(reg_ok), str(hidden_ok)])
	_release_all_mine()


func _p6c_mark() -> void:
	_mark_place = TexBucketHost.place_skip_count
	_mark_sync = TexBucketHost.sync_skip_count


func _p6c_check() -> void:
	var dp := TexBucketHost.place_skip_count - _mark_place
	var ds := TexBucketHost.sync_skip_count - _mark_sync
	_check("6c 短路旗复位+计数面静态（无短路时零增量——两旗默认 false）",
		not TexBucketHost.shortcircuit_place and not TexBucketHost.shortcircuit_sync
			and dp == 0 and ds == 0,
		"dp=%d ds=%d" % [dp, ds])


func _cleanup() -> void:
	print("── 收尾（池件归还/静态面复位/Meta 消毒/树释放） ──")
	_release_all_mine()
	PerfGovernor.boost_override = -1
	PerfGovernor.deep_override = -1
	ProjectileBase.trail_halffreq_override = -1
	MM.BODY_MM = true
	TexBucketHost.shortcircuit_place = false
	TexBucketHost.shortcircuit_sync = false
	MM.teardown_mirrors()                       # 复原残留 sprite+懒挂层自拆（幂等）
	# R270 盘档毒配方：还原快照后显式 erase 再落盘
	Meta._settings = _saved_settings.duplicate()
	Meta._settings.erase("perf_boost")
	Meta._settings.erase("boost_res")
	Meta._save()
	RunSave.clear()
	if _gl != null:
		_gl.queue_free()
		_gl = null

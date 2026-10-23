# tests/qa_r293_multimesh_cases.gd
# R293 刀A 独立验收用例体：弹幕渲染 MultiMesh 合批。
# 契约来源（验收点 1-6）：
#   点1 分桶实例数==活口数（桶键含贴图与 team——元素染色=贴图键分桶即分色）。
#   点2 transform 与池状态一致（headless 结构 / 窗口态逐位 parity 双态——QA-R240-002
#       同口径：Dummy 渲染器不落地 MM 实例缓冲，读回恒零，headless 降级结构断言）。
#   点3 元素染色保真（逐弹 tint 不丢：换贴图通道 + modulate 恒白 + 换色升格换键迁移）。
#   点4 拖尾仍在（弹根 _draw 画布不动——镜像只隐 _sprite；R291 深载门链路零位移）+
#       4e 叠序翻转披露断言（修轮1：MM 桶首位最低层→拖尾从「体下」翻为「体上」，且同桶
#       全部拖尾恒压全部弹本体——半透明拖尾叠刃体观感差属披露项非缺陷，R240 敌侧同款
#       披露先例）。
#   点5 深载门不动（boost 关→deep 恒 false 承重墙 + R291 2:8/4:8 拖尾门口径逐位 +
#       深载与镜像并存正交）。
#   点6 boost 关侧逐位不变（sprite 照绘/零注册/零层/新桶零 BodyMM/release 归位池根/
#       BODY_MM 单点回退/boost 翻转拆收与重开追赶扫）。
#   点7 生命周期/惰性归位交互（R271 lazy 契约共存——release 注销+留桶+复用复注册+churn 守恒）。
# 夹具：main.tscn 真链 boot（r240_bodymm_cases 同款：MENU 态战斗循环停摆，手动
# acquire+spawn 注入弹）；静态面只走 PerfGovernor.boost_override/deep_override 与
# ProjectileBase.trail_halffreq_override 注入口（零 Meta 写——收尾仍按 R270 配方消毒）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const EXPECTED_TOTAL := 37
const MM := preload("res://scripts/render/projectile_body_mm.gd")

var tree: SceneTree
var _gl: GameLoop = null
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _live: Array[ProjectileBase] = []         # 本套持有活弹（收尾/逐例归还）
var _saved_settings: Dictionary = {}
# 跨阶段夹具态（R2 结构整改：await 上提 run() 后，点2/点6 各相位的承载弹与基线）
var _p2_a: ProjectileBase = null
var _p2_b: ProjectileBase = null
var _p6_e1: ProjectileBase = null
var _p6_e2: ProjectileBase = null
var _p6_mc0: int = 0
var _p6_mirrored: bool = false
# R3 诊断仪器：逐相位点名（GDScript 运行期错误只中止最内层函数、调用方继续——某相位
# 中途出错=其检查静默丢失且 0 FAIL；仪器把计数缺口直名到相位，红态合并行回喂）
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
	seed(20261024)
	_saved_settings = Meta._settings.duplicate()
	_boot_game_loop()
	# boot 收敛改为泵到就绪（死线 600 帧）：并行批改动了 boot 面（诊断键/设置行），
	# 固定三帧不再可靠——r240 的三帧口径在当时成立，这里加墙钟式收敛保险。
	var boot_frames := 0
	while boot_frames < 600 and not bool(_gl.get("boot_ready")):
		await tree.process_frame
		boot_frames += 1
	_p0_boot()
	_tally_phase("p0", 2)
	# R2 结构整改：await 全部上提到本函数——两轮红均为「子协程 post-await 检查丢失」
	#（恰 3 项、守卫无效=非空件崩溃；而本函数 post-await 存活有两轮实证：⑧ 恒执行且
	# 验收汇总恒打印）。检查全部移入同步子函数=post-await 丢失面结构性归零。
	# R3 追加逐相位点名（_tally_phase）——若仍有静默丢失，红态合并行直名相位。
	_p1_place()
	_tally_phase("p1a", 6)
	await tree.process_frame
	await tree.process_frame
	_p1_counts()
	_tally_phase("p1g", 1)
	_p2_place()
	await tree.process_frame
	await tree.process_frame
	_p2_structure()
	_tally_phase("p2s", 3)
	_p2_move()
	await tree.process_frame
	await tree.process_frame
	_p2_follow()
	_tally_phase("p2f", 2)
	_p3_element_color()
	_tally_phase("p3", 4)
	_p4_trails()
	_tally_phase("p4", 5)
	_p5_gates()
	_tally_phase("p5", 3)
	await tree.process_frame
	await tree.process_frame
	_p6_off_side()
	_tally_phase("p6a", 5)
	await tree.process_frame
	await tree.process_frame
	_p6_teardown()
	_tally_phase("p6e", 1)
	await tree.process_frame
	await tree.process_frame
	_p6_catchup()
	_tally_phase("p6f", 1)
	_p7_lifecycle()
	_tally_phase("p7", 3)
	_cleanup()
	await tree.process_frame
	_check("⑧ 套件总项数（EXPECTED=%d——R231 假绿教训）" % EXPECTED_TOTAL,
		_pass + _fail + 1 == EXPECTED_TOTAL, "实得 %d" % (_pass + _fail + 1))
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])
	# 门禁回喂口径=最后一行含「汇总/FAIL」的输出——红态在此追加单行合并明细，
	# 下一轮修环可直接拿到全部失败名与计数缺口（绿态不打印，保持电池行序惯例）。
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
	_gl.name = "R293MultimeshGameLoopUnderTest"
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


func _spawn_bullet(p_team: int, p_element: int, p_extra: Dictionary = {}) -> ProjectileBase:
	# 手动注入口（武器侧 acquire→注入→spawn 契约的最小夹具）：无词条/无管线/无网格
	# ——纯视觉与池链路径（无命中结算发生）。
	var pb := _pool().acquire(p_team)
	if pb == null:
		_check("夹具：acquire 得活弹", false, "pool 满？（后续断言跳过该弹）")
		return null
	pb.pool = _pool()
	pb.enemy_grid = null
	pb.elemental = null
	pb.damage_pipeline = null
	var params := {
		"velocity": Vector2(240.0, 0.0) if p_team == 0 else Vector2(-140.0, 0.0),
		"lifetime": 30.0,
		"pierce": 1,
		"bounces": 0,
		"hitbox_radius": 8.0,
		"element": p_element,
		"team": p_team,
		"position": Vector2(90.0 + float(_live.size() * 37.0),
			210.0 + float((_live.size() % 7) * 61.0)),
	}
	params.merge(p_extra, true)
	pb.spawn(params)
	_live.append(pb)
	return pb


func _release_one(p_pb: ProjectileBase) -> void:
	if p_pb != null and is_instance_valid(p_pb):
		_pool().release(p_pb)
	_live.erase(p_pb)


func _release_all() -> void:
	for pb in _live.duplicate():
		_release_one(pb)


# ═══ 点0 夹具 ═══════════════════════════════════════════════════════
func _p0_boot() -> void:
	print("── 点0 夹具 ──")
	_check("0a boot 成功（main.tscn 真链）",
		_gl != null and bool(_gl.get("boot_ready")), str(_gl.get("boot_fatal")))
	_check("0b 弹池桶宿主在位（TexBucketHost 且具备镜像能力）",
		_host() != null and _host().has_method(&"mirror_register"), str(_host()))


# ═══ 点1 分桶实例数==活口数（桶键含贴图与 team） ═════════════════════
func _p1_place() -> void:
	print("── 点1 分桶实例数==活口数（桶键含贴图与 team） ──")
	PerfGovernor.boost_override = 1
	var host := _host()
	var base_mc := host.mirror_count()
	for i in range(3):
		_spawn_bullet(0, GameConst.Element.KIN)
	for i in range(2):
		_spawn_bullet(0, GameConst.Element.FIR)
	for i in range(2):
		_spawn_bullet(0, GameConst.Element.ICE)
	for i in range(3):
		_spawn_bullet(1, GameConst.Element.KIN)
	var tex_kin: Texture2D = TextureFactory.bead(PopPalette.PLAYER, 64)
	var tex_fir: Texture2D = TextureFactory.bead(
		PopPalette.ELEMENT_COLORS[GameConst.Element.FIR], 64)
	var tex_ice: Texture2D = TextureFactory.bead(
		PopPalette.ELEMENT_COLORS[GameConst.Element.ICE], 64)
	var tex_enemy: Texture2D = TextureFactory.bead(PopPalette.ENEMY, 64)
	var all_hidden := true
	var all_keyed := true
	for pb in _live:
		if is_instance_valid(pb):
			if pb._sprite.visible:
				all_hidden = false
			if host.mirror_tex_of(pb) != pb._sprite.texture:
				all_keyed = false
	_check("1a 10 弹全员注册：sprite 恒隐 且 镜像键==本体贴图",
		all_hidden and all_keyed, "hidden=%s keyed=%s" % [str(all_hidden), str(all_keyed)])
	_check("1b host.mirror_count==活口数（基线+%d）" % 10,
		host.mirror_count() == base_mc + 10, "mc=%d" % host.mirror_count())
	var groups := MM.grouped_counts()
	_check("1c 桶键含贴图与 team：分桶数==4（三玩家色+敌珠）",
		groups.size() == 4, "groups=%d" % groups.size())
	var triples: Array = [
		[tex_kin, 0, 3], [tex_fir, 0, 2], [tex_ice, 0, 2], [tex_enemy, 1, 3],
	]
	var counts_ok := groups.size() == 4
	for t in triples:
		var key := Vector2i(int((t[0] as Texture).get_instance_id()), int(t[1]))
		if int(groups.get(key, -1)) != int(t[2]):
			counts_ok = false
	_check("1d 各桶实例数==活口数（3/2/2/3——grouped_counts 逐桶）", counts_ok, str(groups))
	var enemy_team1: bool = groups.has(Vector2i(int(tex_enemy.get_instance_id()), 1))
	var enemy_team0: bool = groups.has(Vector2i(int(tex_enemy.get_instance_id()), 0))
	var distinct := tex_enemy.get_instance_id() != tex_kin.get_instance_id() \
		and tex_enemy.get_instance_id() != tex_fir.get_instance_id() \
		and tex_kin.get_instance_id() != tex_fir.get_instance_id() \
		and tex_kin.get_instance_id() != tex_ice.get_instance_id()
	_check("1e 桶键 team 位口径（敌弹只计 team=1 桶）且四贴图互为异实例",
		enemy_team1 and not enemy_team0 and distinct, "t1=%s t0=%s" % [str(enemy_team1), str(enemy_team0)])
	var mm_ok := true
	var mm_detail := ""
	for t in triples:
		var bucket: Node2D = host._buckets.get(t[0])
		if bucket == null:
			mm_ok = false
			mm_detail = "桶缺失（测试贴图≠在册键？）"
		elif bucket.get_child_count() == 0 or not (bucket.get_child(0) is MultiMeshInstance2D) \
				or (bucket.get_child(0) as MultiMeshInstance2D).texture != t[0]:
			mm_ok = false
			mm_detail = "首子非MMI（子数%d）" % bucket.get_child_count()
	_check("1f 各桶 BodyMM 挂桶首位且 texture==桶贴图（R240 同规格）", mm_ok, mm_detail)


func _p1_counts() -> void:
	# 点1 后相（R2 结构整改：帧泵在 run()，本函数纯同步——visible 计数核验+归还）
	var host := _host()
	var tex_kin: Texture2D = TextureFactory.bead(PopPalette.PLAYER, 64)
	var tex_fir: Texture2D = TextureFactory.bead(
		PopPalette.ELEMENT_COLORS[GameConst.Element.FIR], 64)
	var tex_ice: Texture2D = TextureFactory.bead(
		PopPalette.ELEMENT_COLORS[GameConst.Element.ICE], 64)
	var tex_enemy: Texture2D = TextureFactory.bead(PopPalette.ENEMY, 64)
	var triples: Array = [
		[tex_kin, 0, 3], [tex_fir, 0, 2], [tex_ice, 0, 2], [tex_enemy, 1, 3],
	]
	var vis_ok := true
	var vis_detail := ""
	for t in triples:
		var mmi: MultiMeshInstance2D = host._mm_meshes.get(t[0])
		var vis_n := mmi.multimesh.visible_instance_count if mmi != null else -1
		if mmi == null or vis_n != int(t[2]):
			vis_ok = false
			vis_detail += "%s:%d/%d " % [str(int(t[1])), vis_n, int(t[2])]
	_check("1g 分桶实例数==活口数（visible_instance_count 逐桶 3/2/2/3）", vis_ok, vis_detail)
	_release_all()


# ═══ 点2 transform 与池状态一致（headless 结构/窗口 parity 双态） ═════
# R2 结构整改：拆四相位（place→泵2帧→structure→move→泵2帧→follow），帧泵在 run()。
func _p2_place() -> void:
	print("── 点2 transform 与池状态一致（双态） ──")
	_p2_a = _spawn_bullet(0, GameConst.Element.KIN, {"position": Vector2(150.0, 300.0)})
	_p2_b = _spawn_bullet(0, GameConst.Element.KIN, {"position": Vector2(150.0, 420.0)})
	if _p2_a != null:
		_p2_a._sprite.rotation = 0.7
	if _p2_b != null:
		_p2_b._sprite.position = Vector2(3.0, -5.0)


func _p2_structure() -> void:
	var headless := DisplayServer.get_name() == "headless"
	var host := _host()
	var a := _p2_a
	var b := _p2_b
	var tex: Texture2D = host.mirror_tex_of(a)
	var mmi: MultiMeshInstance2D = host._mm_meshes.get(tex)
	_check("2a 实例容量≥活口 且 visible==2（结构口径——双态恒跑）",
		mmi != null and mmi.multimesh.instance_count >= 2
			and mmi.multimesh.visible_instance_count == 2,
		"tex=%s inst=%d vis=%d" % [str(tex != null),
			(mmi.multimesh.instance_count if mmi != null else -1),
			(mmi.multimesh.visible_instance_count if mmi != null else -1)])
	var idx_a := _instance_index_of(host, a)
	var idx_b := _instance_index_of(host, b)
	_check("2d 实例序==place 序（先注册低索引——绘制序与桶序同构）",
		idx_a >= 0 and idx_b >= 0 and idx_a < idx_b, "ia=%d ib=%d" % [idx_a, idx_b])
	if headless:
		_check("2b 实例 transform（headless 降级：Dummy 渲染器不落地 MM 缓冲——QA-R240-002 同口径，结构断言见 2a/2d）",
			true, "窗口态跑本套件时为逐位 parity 断言")
	elif mmi != null and idx_a >= 0 and idx_b >= 0:
		var ta: Transform2D = mmi.multimesh.get_instance_transform_2d(idx_a)
		var wa: Transform2D = a.global_transform * a._sprite.transform
		var tb: Transform2D = mmi.multimesh.get_instance_transform_2d(idx_b)
		var wb: Transform2D = b.global_transform * b._sprite.transform
		_check("2b 实例 transform==owner.global×body.local（含 rotation/偏移——窗口态 parity）",
			ta.origin.distance_to(wa.origin) < 0.001
				and absf(ta.get_rotation() - wa.get_rotation()) < 0.001
				and tb.origin.distance_to(wb.origin) < 0.001,
			"got=%s want=%s" % [str(ta.origin), str(wa.origin)])
	else:
		_check("2b 实例 transform==owner.global×body.local（含 rotation/偏移——窗口态 parity）",
			false, "前置缺失：mmi=%s ia=%d ib=%d" % [str(mmi != null), idx_a, idx_b])


func _p2_move() -> void:
	if _p2_a != null:
		_p2_a.global_position = Vector2(333.0, 555.0)


func _p2_follow() -> void:
	var headless := DisplayServer.get_name() == "headless"
	var host := _host()
	var a := _p2_a
	var tex: Texture2D = host.mirror_tex_of(a)
	var mmi: MultiMeshInstance2D = host._mm_meshes.get(tex)
	var idx_a := _instance_index_of(host, a)
	if headless:
		_check("2c 移动跟随（headless 降级：注册面守恒——键仍在册且活口不变）",
			tex != null and host.mirror_tex_of(a) == tex and mmi != null
				and mmi.multimesh.visible_instance_count == 2,
			"tex_reg=%s vis=%d" % [str(host.mirror_tex_of(a) == tex),
				(mmi.multimesh.visible_instance_count if mmi != null else -1)])
	elif mmi != null and idx_a >= 0:
		var tc: Transform2D = mmi.multimesh.get_instance_transform_2d(idx_a)
		var wc: Transform2D = a.global_transform * a._sprite.transform
		_check("2c 移动跟随（实例 transform 与池状态逐帧一致）",
			tc.origin.distance_to(wc.origin) < 0.001,
			"got=%s want=%s" % [str(tc.origin), str(wc.origin)])
	else:
		_check("2c 移动跟随（实例 transform 与池状态逐帧一致）",
			false, "前置缺失：mmi=%s ia=%d" % [str(mmi != null), idx_a])
	if headless:
		_check("2e 实例色通道（headless 降级：use_colors 在位——写路径不可读回）",
			mmi != null and mmi.multimesh.use_colors, "mmi=%s" % str(mmi != null))
	elif mmi != null and idx_a >= 0:
		var ica: Color = mmi.multimesh.get_instance_color(idx_a)
		var wc2: Color = a.modulate * a._sprite.modulate * a._sprite.self_modulate
		_check("2e 实例色==root.modulate×body.modulate×self_modulate（弹侧恒白——染色走贴图）",
			absf(ica.r - wc2.r) < 0.002 and absf(ica.g - wc2.g) < 0.002
				and absf(ica.b - wc2.b) < 0.002 and absf(ica.a - wc2.a) < 0.002,
			"got=%s want=%s" % [str(ica), str(wc2)])
	else:
		_check("2e 实例色==root.modulate×body.modulate×self_modulate（弹侧恒白——染色走贴图）",
			false, "前置缺失：mmi=%s ia=%d" % [str(mmi != null), idx_a])
	_release_all()
	_p2_a = null
	_p2_b = null


func _instance_index_of(p_host: TexBucketHost, p_pb: ProjectileBase) -> int:
	var tex: Texture2D = p_host.mirror_tex_of(p_pb)
	if tex == null:
		return -1
	var lst: Array = p_host._mm_lists.get(tex)
	if lst == null:
		return -1
	return lst.find(p_pb)


# ═══ 点3 元素染色保真（换贴图通道——逐弹 tint 不丢） ═════════════════
func _p3_element_color() -> void:
	print("── 点3 元素染色保真 ──")
	var host := _host()
	var kin := _spawn_bullet(0, GameConst.Element.KIN)
	_spawn_bullet(0, GameConst.Element.FIR)
	_spawn_bullet(0, GameConst.Element.ICE)
	var tex_kin: Texture2D = TextureFactory.bead(PopPalette.PLAYER, 64)
	var tex_fir: Texture2D = TextureFactory.bead(
		PopPalette.ELEMENT_COLORS[GameConst.Element.FIR], 64)
	var tex_ice: Texture2D = TextureFactory.bead(
		PopPalette.ELEMENT_COLORS[GameConst.Element.ICE], 64)
	var eq_k := _live.size() > 0 and host.mirror_tex_of(_live[0]) == tex_kin
	var eq_f := _live.size() > 1 and host.mirror_tex_of(_live[1]) == tex_fir
	var eq_i := _live.size() > 2 and host.mirror_tex_of(_live[2]) == tex_ice
	_check("3a 同色同实例（TextureFactory 静态缓存键含 fill html）：在册键==期望缓存实例",
		eq_k and eq_f and eq_i,
		"live=%d k=%s f=%s i=%s" % [_live.size(), str(eq_k), str(eq_f), str(eq_i)])
	var white_ok := true
	for pb in _live:
		if pb._sprite.modulate != Color.WHITE or pb._sprite.self_modulate != Color.WHITE:
			white_ok = false
	_check("3b 染色不落 modulate 通道（全员恒白——MM 合成色==Sprite 渲染色，逐弹 tint 不丢）",
		white_ok, "")
	var kin_n := int(MM.grouped_counts().get(Vector2i(int(tex_kin.get_instance_id()), 0), 0))
	var fir_n := int(MM.grouped_counts().get(Vector2i(int(tex_fir.get_instance_id()), 0), 0))
	if kin != null:                             # 夹具空件守卫（计数守恒——不增删检查项）
		kin.element = GameConst.Element.FIR
		kin._vis_variant = -1                   # 变体失效点（反弹金染升格同链路 :1384）
		kin._sync_visual()                      # → _apply_visual_variant 尾 _place_in_bucket → 换键迁册
	_check("3c 换色升格链：变体失效→重排→落桶→镜像换键（新色贴图）",
		kin != null and host.mirror_tex_of(kin) == tex_fir and kin._sprite.texture == tex_fir,
		"tex=%s" % str(host.mirror_tex_of(kin) if kin != null else "null"))
	var groups := MM.grouped_counts()
	_check("3d 换色后分桶迁移（旧桶-1 新桶+1）",
		int(groups.get(Vector2i(int(tex_kin.get_instance_id()), 0), 0)) == kin_n - 1
			and int(groups.get(Vector2i(int(tex_fir.get_instance_id()), 0), 0)) == fir_n + 1,
		str(groups))
	_release_all()


# ═══ 点4 拖尾仍在（弹根 _draw 不动——镜像只隐 _sprite） ═══════════════
func _p4_trails() -> void:
	print("── 点4 拖尾/自绘特效保留 ──")
	var host := _host()
	# tick 会走 _check_offscreen——三弹钉在夹具玩家区（(360,900) 半径内必在界内，
	# 防 _live.size() 派生位落入出界裕度被回收造成 4b/4d 假红）
	var boom := _spawn_bullet(0, GameConst.Element.KIN,
		{"boomerang": true, "range": 300.0, "position": Vector2(360.0, 880.0)})
	_check("4a 回旋弹：镜像在册 且 弹根可见（拖尾画布=弹根 Node2D _draw——不被镜像杀）",
		boom != null and host.mirror_tex_of(boom) != null and boom.visible, str(boom != null))
	if boom != null:
		# 置脏分支实证（实跑取证定谳：Godot 4.3 无 is_queued_redraw 公开口；桌面态门早退
		# 恒真不触 acc——故注入 R291 同款 halffreq 让门走累计路径）：预置 acc=1.0（远超
		# 门限）→ tick 到门必判真并复位 0.0=queue_redraw 必经；tick 早退不触门则恒 1.0。
		ProjectileBase.trail_halffreq_override = 1
		boom._trail_redraw_acc = 1.0
		boom.tick(1.0 / 60.0)
	_check("4b 回旋拖尾重绘驱动存活（tick→_trail_redraw_due 判真→queue_redraw 必经——R291 同款注入，链路零位移）",
		boom != null and boom._trail_redraw_acc == 0.0,
		"acc=%f" % (boom._trail_redraw_acc if boom != null else -1.0))
	var ltg := _spawn_bullet(0, GameConst.Element.LTG, {"position": Vector2(400.0, 880.0)})
	if ltg != null:
		ltg.tick(1.0 / 60.0)
	_check("4c LTG 电花自旋通道（tick→_sprite.rotation 每帧真写——MM 每帧同步环承载）",
		ltg != null and absf(ltg._sprite.rotation) > 0.001,
		"rot=%f" % (ltg._sprite.rotation if ltg != null else -1.0))
	var sword := _spawn_bullet(0, GameConst.Element.KIN,
		{"flight_sword": true, "position": Vector2(440.0, 880.0)})
	if sword != null:
		sword._trail_redraw_acc = 1.0            # 同 4b：置脏分支实证（:454 残影重绘口）
		sword.tick(1.0 / 60.0)
	ProjectileBase.trail_halffreq_override = -1  # 注入口复位（4c 区间 LTG 无门消费零影响）
	_check("4d 灵剑刺击残影路径（flight_sword→_trail_redraw_due 判真→queue_redraw 且镜像在册）",
		sword != null and sword._trail_redraw_acc == 0.0
			and host.mirror_tex_of(sword) != null,
		"acc=%f" % (sword._trail_redraw_acc if sword != null else -1.0))
	# 4e 叠序翻转披露面（修轮1）：本体让位 MM 后拖尾叠序翻转——原 _sprite 为弹根子件
	#（父 _draw 恒绘于子件之下=拖尾在体下）；现桶内 BodyMM 恒首位（最低层）、弹根（拖尾
	# 画布）恒在其上 → 拖尾翻为「体上」且同桶全部拖尾恒压全部弹本体（跨个体面）。
	# 结构口径三件：MMI 首位最低层 + 弹根索引恒 > MMI（绘序在其上）+ _sprite 仍为弹根
	# 子件且恒隐（原叠序对照位与让位事实）。
	var mmi_idx := -1
	if boom != null and boom.get_parent() is Node2D:
		for i in range((boom.get_parent() as Node2D).get_child_count()):
			if (boom.get_parent() as Node2D).get_child(i) is MultiMeshInstance2D:
				mmi_idx = i
				break
	_check("4e 拖尾/本体叠序翻转披露（MMI 桶首位最低层，弹根拖尾画布恒压其上；_sprite 仍为弹根子件=原「拖尾在体下」对照位；观感差属披露项非缺陷）",
		boom != null and boom.get_parent() is Node2D and mmi_idx == 0
			and boom.get_index() > mmi_idx
			and boom._sprite.get_parent() == boom and not boom._sprite.visible,
		"mmi_idx=%d boom_idx=%d sprite_child_of_root=%s sprite_hidden=%s" % [mmi_idx,
			(boom.get_index() if boom != null else -1),
			str(boom != null and boom._sprite.get_parent() == boom),
			str(boom != null and not boom._sprite.visible)])
	_release_all()


# ═══ 点5 深载门不动（R291 契约零位移） ═══════════════════════════════
func _p5_gates() -> void:
	# R2 结构整改：尾(boost 关翻转+泵帧)由 run() 承担——本函数纯同步
	print("── 点5 深载门不动 ──")
	PerfGovernor.boost_override = 0
	PerfGovernor.deep_override = 1
	_check("5a boost 关 → deep_load 恒 false（deep_override=1 也不亮——perf_governor 承重墙）",
		not PerfGovernor.deep_load(), "")
	PerfGovernor.boost_override = 1
	ProjectileBase.trail_halffreq_override = 1           # headless 无 mobile 特征位——注入
	var b := _spawn_bullet(0, GameConst.Element.KIN)
	var due_deep := -1
	var due_plain := -1
	if b != null:
		PerfGovernor.deep_override = 1
		due_deep = _count_trail_due(b, 8)
		PerfGovernor.deep_override = 0
		due_plain = _count_trail_due(b, 8)
	PerfGovernor.deep_override = -1
	ProjectileBase.trail_halffreq_override = -1
	_check("5b 拖尾深载门倍率逐位（deep 8 拍 2 置脏 / 关态 4 置脏——R291 套件同口径）",
		due_deep == 2 and due_plain == 4, "deep=%d plain=%d" % [due_deep, due_plain])
	PerfGovernor.deep_override = 1
	var host := _host()
	var n0 := host.mirror_count()
	var c := _spawn_bullet(0, GameConst.Element.FIR)
	_check("5c boost∧deep 并存：镜像照常注册（注册面与深载门正交——合批不劫持门）",
		c != null and host.mirror_count() == n0 + 1 and host.mirror_tex_of(c) != null, "")
	PerfGovernor.deep_override = -1
	_release_all()
	# 点1-5 的 boost 会话收尾：关态翻转走生产拆收路径（层 _process 自拆）——点6 起点
	# 干净基线（零层零册——6a 的「关态=现状」断言不被上一会话遗留件污染）。
	# 收尾泵 2 帧在 run()（本函数尾注：翻转后由 run() await ×2 再进 _p6_off_side）。
	PerfGovernor.boost_override = 0


func _count_trail_due(p_b: ProjectileBase, p_beats: int) -> int:
	p_b._trail_redraw_acc = 0.0
	var n := 0
	for i in range(p_beats):
		if p_b._trail_redraw_due(1.0 / 60.0):
			n += 1
	return n


# ═══ 点6 boost 关侧逐位不变 ═════════════════════════════════════════
func _p6_off_side() -> void:
	# R2 结构整改：点6 拆三相位（off_side→泵2帧→teardown→泵2帧→catchup），帧泵在 run()
	print("── 点6 boost 关侧逐位不变（桌面/headless/测试默认=现状） ──")
	var host := _host()
	var pool := _pool()
	PerfGovernor.boost_override = 0
	var mc0 := host.mirror_count()
	_p6_mc0 = mc0
	var track0 := MM.tracked_count()
	var a := _spawn_bullet(0, GameConst.Element.KIN, {"position": Vector2(200.0, 200.0)})
	_check("6a 关态 spawn：sprite 照绘（逐弹 Sprite 现状）且零注册零册零层",
		a != null and a._sprite.visible and host.mirror_count() == mc0
			and MM.tracked_count() == track0 and MM.layer_node() == null,
		"vis=%s mc=%d/%d tc=%d/%d layer=%s" % [str(a != null and a._sprite.visible),
			host.mirror_count(), mc0, MM.tracked_count(), track0, str(MM.layer_node())])
	var hyd := _spawn_bullet(0, GameConst.Element.HYD, {"position": Vector2(240.0, 200.0)})
	var hyd_bucket: Node2D = null
	if hyd != null:
		hyd_bucket = host._buckets.get(hyd._sprite.texture)
	var has_mmi := false
	if hyd_bucket != null:
		for c in hyd_bucket.get_children():
			if c is MultiMeshInstance2D:
				has_mmi = true
	_check("6b 新贴图桶零 BodyMM（关态不建镜像件）",
		hyd_bucket != null and not has_mmi,
		"bucket=%s mmi=%s" % [str(hyd_bucket != null), str(has_mmi)])
	if hyd != null:
		pool.release(hyd)
		_live.erase(hyd)
	_check("6c 关态 release 归位池根（r214 关态口径逐位）",
		hyd != null and hyd.get_parent() == pool,
		"parent=%s" % (str(hyd.get_parent()) if hyd != null else "null"))
	# BODY_MM 单点回退（boost 开态——r240 ⑥ 同款双向）
	PerfGovernor.boost_override = 1
	var d := _spawn_bullet(0, GameConst.Element.ICE, {"position": Vector2(280.0, 200.0)})
	MM.BODY_MM = false
	if d != null:
		d._place_in_bucket()
	_check("6d BODY_MM=false 单点回退：复显+注销（boost 开态仍逐弹 Sprite）",
		d != null and d._sprite.visible and host.mirror_tex_of(d) == null
			and host.mirror_count() == mc0,
		"vis=%s reg=%s mc=%d/%d" % [str(d != null and d._sprite.visible),
			str(host.mirror_tex_of(d) == null), host.mirror_count(), mc0])
	MM.BODY_MM = true
	if d != null:
		d._place_in_bucket()
	_check("6d2 门恢复：再落桶复注册（单点双向无残留）",
		d != null and not d._sprite.visible and host.mirror_tex_of(d) != null,
		str(d != null))
	# boost 翻转拆收：开→关（层 _process 治理——泵 2 帧在 run()）
	_p6_e1 = _spawn_bullet(0, GameConst.Element.KIN, {"position": Vector2(320.0, 200.0)})
	_p6_e2 = _spawn_bullet(1, GameConst.Element.KIN, {"position": Vector2(360.0, 200.0)})
	_p6_mirrored = _p6_e1 != null and _p6_e2 != null \
		and host.mirror_tex_of(_p6_e1) != null and host.mirror_tex_of(_p6_e2) != null
	PerfGovernor.boost_override = 0


func _p6_teardown() -> void:
	var host := _host()
	var layer_gone: bool = MM.layer_node() == null or not is_instance_valid(MM.layer_node())
	_check("6e boost 翻转拆收（开→关）：全员 sprite 复原+注销+层自拆",
		_p6_mirrored and _p6_e1 != null and _p6_e2 != null \
			and _p6_e1._sprite.visible and _p6_e2._sprite.visible
			and host.mirror_count() == _p6_mc0 and not MM.is_tracked(_p6_e1) and layer_gone,
		"mir=%s v1=%s v2=%s mc=%d/%d trk=%s lyr=%s" % [str(_p6_mirrored),
			str(_p6_e1 != null and _p6_e1._sprite.visible),
			str(_p6_e2 != null and _p6_e2._sprite.visible),
			host.mirror_count(), _p6_mc0, str(not MM.is_tracked(_p6_e1)), str(layer_gone)])
	# boost 重开追赶扫：翻转前已活弹（e1/e2 未重落桶）由层首帧桶内实扫补注册
	#（泵 2 帧在 run()——下一相位 _p6_catchup 核验）
	PerfGovernor.boost_override = 1
	_spawn_bullet(0, GameConst.Element.FIR, {"position": Vector2(400.0, 200.0)})


func _p6_catchup() -> void:
	var host := _host()
	_check("6f boost 重开追赶扫：已活弹补注册复隐（懒挂层首帧实扫）",
		_p6_e1 != null and _p6_e2 != null \
			and not _p6_e1._sprite.visible and not _p6_e2._sprite.visible
			and host.mirror_tex_of(_p6_e1) != null and host.mirror_tex_of(_p6_e2) != null,
		"h1=%s h2=%s r1=%s r2=%s" % [str(_p6_e1 != null and not _p6_e1._sprite.visible),
			str(_p6_e2 != null and not _p6_e2._sprite.visible),
			str(host.mirror_tex_of(_p6_e1) != null), str(host.mirror_tex_of(_p6_e2) != null)])
	_release_all()
	_p6_e1 = null
	_p6_e2 = null


# ═══ 点7 生命周期/惰性归位交互（R271 契约共存） ══════════════════════
func _p7_lifecycle() -> void:
	print("── 点7 生命周期/惰性归位交互 ──")
	PerfGovernor.boost_override = 1          # lazy 归位门（R271——与生产接线同谓词）
	var host := _host()
	var pool := _pool()
	var pol0 := int((pool.stats())["pollution"])
	var a := _spawn_bullet(0, GameConst.Element.ICE, {"position": Vector2(440.0, 300.0)})
	var tex_a: Texture2D = host.mirror_tex_of(a) if a != null else null
	if a != null:
		pool.release(a)
		_live.erase(a)
	_check("7a boost 开 release：镜像注销+留桶（lazy）+根不可见+零池污染",
		a != null and host.mirror_tex_of(a) == null and a.get_parent() != pool and not a.visible
			and int((pool.stats())["pollution"]) == pol0,
		"unreg=%s inbucket=%s inv=%s pol=%d/%d" % [str(a != null and host.mirror_tex_of(a) == null),
			str(a != null and a.get_parent() != pool), str(a != null and not a.visible),
			int((pool.stats())["pollution"]), pol0])
	var b := _spawn_bullet(0, GameConst.Element.ICE, {"position": Vector2(480.0, 300.0)})
	_check("7b 同变体复用（LIFO 同件）：重落桶即复注册+sprite 复隐",
		b != null and b == a and host.mirror_tex_of(b) == tex_a and not b._sprite.visible,
		"same=%s reg=%s hid=%s" % [str(b == a), str(host.mirror_tex_of(b) == tex_a),
			str(b != null and not b._sprite.visible)])
	var base := host.mirror_count()
	for i in range(10):
		var x1 := _spawn_bullet(0, GameConst.Element.KIN, {"position": Vector2(520.0, 300.0)})
		var x2 := _spawn_bullet(1, GameConst.Element.KIN, {"position": Vector2(560.0, 300.0)})
		_release_one(x1)
		_release_one(x2)
	_check("7c 10 轮 acquire/release 环：镜像计数守恒（注销链无泄漏）",
		host.mirror_count() == base, "mc=%d 期望 %d" % [host.mirror_count(), base])
	_release_all()


func _cleanup() -> void:
	print("── 收尾（池件归还/静态面复位/Meta 消毒/树释放） ──")
	_release_all()
	PerfGovernor.boost_override = -1
	PerfGovernor.deep_override = -1
	ProjectileBase.trail_halffreq_override = -1
	MM.BODY_MM = true
	MM.teardown_mirrors()               # 复原残留 sprite+懒挂层自拆（幂等）
	TexBucketHost.shortcircuit_place = false   # 本套未触（防御复位防跨套件泄漏）
	TexBucketHost.shortcircuit_sync = false
	# R270 盘档毒配方（r292 同款）：还原快照后显式 erase 再落盘
	Meta._settings = _saved_settings.duplicate()
	Meta._settings.erase("perf_boost")
	Meta._settings.erase("boost_res")
	Meta._save()
	RunSave.clear()
	if _gl != null:
		_gl.queue_free()
		_gl = null
	# R2 结构整改：尾帧（queue_free 落地收敛帧）由 run() 统一泵——本函数纯同步

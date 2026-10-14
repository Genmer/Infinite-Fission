# tests/_tmp/qa_r271_independent_probe.gd
# R271 QA 独立探针（不信任实施员套件自述——产品行为直证）：
#   A 组：V-C1 弹桶惰性归位玩家可见面（boost 开 release 留桶=hidden/零镜像绘制；
#         同变体复用零树进出；换变体换桶；boost 关逐位回池根；池零增长）
#   B 组：r202_perf S⑤ 伪影论独立复核——产品默认 viewport 态 11 开关行相邻重叠
#         深度实测（实施员申辩：重叠仅存在于套件自设 CANVAS_ITEMS×0.75 窗、产品态 0）
# 纪律：-s 入口编译期先于 autoload 注册——入口零工程类名直引（运行期鸭子面）。
extends SceneTree

var _pass: int = 0
var _fail: int = 0
var _fails: Array[String] = []


func _initialize() -> void:
	_run()


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		_fails.append(p_name)
		print("  FAIL | %s（%s）" % [p_name, p_detail])


func _run() -> void:
	print("══════════ QA 独立探针：R271 V-C1 玩家可见面 + r202 S⑤ 产品态行重叠 ══════════")
	await process_frame
	await process_frame
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	var gl: Node = main_scene.instantiate()
	gl.name = "R271QAProbe"
	root.add_child(gl)
	if not (gl.get("boot_ready") and int(gl.get("state")) == 1):  # GameStatus.MENU==1（BOOT,MENU,PLAYING…）
		print("FAIL | boot 失败：%s" % str(gl.get("boot_fatal")))
		quit(1)
		return
	var pg: Node = root.get_node_or_null("/root/PerfGovernor")
	pg.call("set_process", false)

	# ── A 组：V-C1 独立验证（产品池真件） ──
	print("── A：V-C1 惰性归位（boost 门内）──")
	pg.set("boost_override", 1)
	var pool: Node = (gl.get("pools") as Dictionary).get(&"projectile")
	var host: Node = pool.get("bucket_host")
	var tex_a: Texture2D = PlaceholderTexture2D.new()
	var tex_b: Texture2D = PlaceholderTexture2D.new()
	var pol0: int = int((pool.call("stats") as Dictionary)["pollution"])

	var added: Array = []
	var removed: Array = []
	var on_add := func(n: Node): added.append(str(n.name))
	var on_rem := func(n: Node): removed.append(str(n.name))

	var pb: Node = pool.call("acquire", 0)
	_check("A1 acquire 得活弹（产品池）", pb != null, "")
	host.call("place", pb, tex_a)
	var bucket_a: Node = pb.get_parent()
	_check("A1 place 落桶 A", bucket_a != pool and bucket_a != null, "parent=%s" % str(bucket_a))
	pool.call("release", pb)
	_check("A2 boost 开 release 留桶（parent==桶A 非池根）", pb.get_parent() == bucket_a,
		"parent=%s" % str(pb.get_parent()))
	_check("A2 留桶弹 visible==false（玩家不可见）", not (pb as CanvasItem).visible,
		"visible=%s" % str((pb as CanvasItem).visible))
	_check("A2 留桶弹 processing 关（零绘制零逻辑）",
		not pb.is_processing() and not pb.is_physics_processing(),
		"proc=%s phys=%s" % [str(pb.is_processing()), str(pb.is_physics_processing())])
	_check("A2 留桶弹不在 MM 镜像注册表（host.mirror_tex_of==null）",
		host.call("mirror_tex_of", pb) == null, "")
	_check("A2 release 侧池卫生零污染", int((pool.call("stats") as Dictionary)["pollution"]) == pol0, "")

	# A3：同变体复用零 reparent（树信号直证——不经套件探针）
	added.clear(); removed.clear()
	node_added.connect(on_add)
	node_removed.connect(on_rem)
	var pb2: Node = pool.call("acquire", 0)
	host.call("place", pb2, tex_a)
	node_added.disconnect(on_add)
	node_removed.disconnect(on_rem)
	_check("A3 同变体复用取回同一件（LIFO）", pb2 == pb, "")
	_check("A3 同变体复用零树进出（node_added/removed 恰 0）",
		added.is_empty() and removed.is_empty(), "加=%s 摘=%s" % [",".join(added), ",".join(removed)])
	_check("A3 复用件仍 parent==桶A", pb2.get_parent() == bucket_a, "")

	# A4：换变体仍换桶（桶语义零变化）
	added.clear(); removed.clear()
	node_added.connect(on_add)
	node_removed.connect(on_rem)
	host.call("place", pb2, tex_b)
	node_added.disconnect(on_add)
	node_removed.disconnect(on_rem)
	var bucket_b: Node = pb2.get_parent()
	_check("A4 变体变更换桶（parent==桶B≠桶A）", bucket_b != bucket_a and bucket_b != null,
		"parent=%s" % str(bucket_b))
	_check("A4 换桶面树进出=加3摘2（桶B 惰性建+弹根+Visual 子树传播——flushcut a3.3 同口径）",
		added.size() == 3 and removed.size() == 2 and ",".join(added).contains("Visual"),
		"加=%s 摘=%s" % [",".join(added), ",".join(removed)])

	# A5：boost 关=逐位回 unplace 现状（归位池根）
	pg.set("boost_override", 0)
	pool.call("release", pb2)
	_check("A5 boost 关 release 归位池根（unplace 现状逐位）", pb2.get_parent() == pool,
		"parent=%s pool=%s" % [str(pb2.get_parent()), str(pool)])
	_check("A5 关态归还件 visible==false", not (pb2 as CanvasItem).visible, "")
	pg.set("boost_override", 1)

	# A6：池零增长（boost 关归一化后计数——容量/节点总数不变；留桶件单列口径）
	pg.set("boost_override", 0)
	var pn: Node = pool.call("acquire", 0)
	host.call("place", pn, tex_a)
	pool.call("release", pn)
	pg.set("boost_override", 1)
	var cap0: int = int((pool.call("stats") as Dictionary)["capacity"])
	var child0: int = pool.get_child_count()
	for i in range(200):
		var p: Node = pool.call("acquire", 0)
		host.call("place", p, tex_a)
		pool.call("release", p)
	var st: Dictionary = pool.call("stats")
	var parked: int = 0
	var parked_vis: int = 0
	for n in pool.get("_free_list"):
		var nn := n as Node2D
		if nn != null and nn.get_parent() != pool:
			parked += 1
			if nn.visible:
				parked_vis += 1
	_check("A6 200 轮周转后容量不变（无增长）", int(st["capacity"]) == cap0,
		"cap %d→%d" % [cap0, int(st["capacity"])])
	_check("A6 池根子数+留桶空闲数==总节点数（守恒零泄漏——末轮 release 留桶属 lazy 语义）",
		pool.get_child_count() + parked == child0,
		"child %d + parked %d vs %d" % [pool.get_child_count(), parked, child0])
	_check("A6 200 轮周转后运行期实例化==0", int(st["runtime_instantiates"]) == 0,
		"ri=%d" % int(st["runtime_instantiates"]))
	_check("A6 留桶空闲件全部不可见（零绘制）", parked > 0 and parked_vis == 0, "parked=%d 可见=%d" % [parked, parked_vis])
	_check("A6 200 轮周转后污染==0", int(st["pollution"]) == pol0,
		"pol %d→%d" % [pol0, int(st["pollution"])])

	# ── B 组：r202 S⑤ 产品默认 viewport 态行重叠实测 ──
	print("── B：设置行布局（产品默认 viewport 态——无 CANVAS_ITEMS×0.75 归一化）──")
	var sp: Node = gl.get("settings_panel")
	if sp == null:
		_check("B0 settings_panel 在树（boot 后可用）", false, "")
	else:
		sp.call("open")
		await process_frame
		await process_frame
		var rows: Array = [sp.get("_fx_btn"), sp.get("_fps_btn"), sp.get("_perf_mode_btn"),
			sp.get("_boost_btn"), sp.get("_shake_btn"), sp.get("_dmg_btn"),
			sp.get("_show_fps_btn"), sp.get("_diag_log_btn"), sp.get("_diag_len_btn"),
			sp.get("_pos_btn"), sp.get("_codex_reset_btn")]
		var present := true
		for r in rows:
			if r == null:
				present = false
		var y_ok := true
		var depth_max := -999.0
		var depths: Array[String] = []
		if present:
			for i in range(rows.size()):
				var rc: Control = rows[i] as Control
				if absf(rc.get_rect().position.y - (330.0 + 44.0 * i)) > 0.01:
					y_ok = false
				if i > 0:
					var prev: Control = rows[i - 1] as Control
					var d := prev.get_rect().position.y + prev.get_rect().size.y \
						- rc.get_rect().position.y
					depths.append("%.1f" % d)
					depth_max = maxf(depth_max, d)
			var pos_btn: Control = sp.get("_pos_btn") as Control
			var codex_btn: Control = sp.get("_codex_reset_btn") as Control
			var d_last: float = (rows[9] as Control).get_rect().position.y \
				+ (rows[9] as Control).get_rect().size.y \
				- (rows[10] as Control).get_rect().position.y
			print("  读数：pos_btn min=%s h=%s；codex min=%s h=%s；相邻深度[%s] max=%.2f" % [
				str(pos_btn.get_minimum_size()), str(pos_btn.get_rect().size.y),
				str(codex_btn.get_minimum_size()), str(codex_btn.get_rect().size.y),
				" ".join(depths), depth_max])
			_check("B1 产品态 11 行 y=330+44·i 逐位（布局法条）", y_ok, "")
			_check("B2 产品态相邻重叠深度==0（实施员申辩复核：零重叠非伪影）",
				depth_max <= 0.01, "max=%.2f" % depth_max)
			_check("B3 产品态 ◉ 行（PanelPosButton）钮高==标称 44",
				absf((rows[9] as Control).get_rect().size.y - 44.0) <= 0.01,
				"h=%.1f" % (rows[9] as Control).get_rect().size.y)
			sp.call("close")

	# ── 收尾 ──
	pg.set("boost_override", -1)
	pg.set("mode_override", -1)
	pg.set("tier_override", -1)
	pg.call("set_process", true)
	gl.free()
	await process_frame
	RunSave.clear()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _fails.is_empty():
		for f in _fails:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])
	quit(0 if _fail == 0 else 1)

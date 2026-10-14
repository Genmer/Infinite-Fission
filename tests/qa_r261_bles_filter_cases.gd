extends RefCounted
# R261 祝福面板筛选/分页/重叠批 cases（配套口 qa_r261_bles_filter.gd）。
# ①品级筛选页签 ②分页 7 行/页+翻页钮 ③预选跳页 ④页级行缓存 ⑤重叠修（x≥64）
# R262 迁移：筛选键 TraitData.pool → TraitData.rarity（白0/蓝1/紫2/金3）；夹具解锁
# 全池（rarity 0..3）+ pool 改 _blessing_pool() 全池；默认签=当前难度档（open 重置）。

var _pass := 0
var _fail := 0
var _failures: Array[String] = []


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  ok | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("  FAIL | %s %s" % [p_name, p_detail])


func run(p_tree: SceneTree) -> void:
	var gl_script: GDScript = load("res://scripts/loop/game_loop.gd")
	var gl = gl_script.new()
	gl.name = "GameLoopForR261BlesFilter"
	p_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	var waited := 0
	while not gl.boot_ready and waited < 600:
		await p_tree.process_frame
		waited += 1
	var ui = gl.blessing_pick_ui
	_check("boot：菜单就绪", gl.boot_ready and ui != null)

	# 夹具：解锁全池（rarity 0..3 全档——R262 池扩全档口径；快照精确还原。
	# R263：预选用例按价收费——星尘 fixture 预置+快照还原，防余额不足拒预选）
	var codex_snapshot: Dictionary = Meta.codex_traits.duplicate()
	var sd_saved: int = Meta.stardust
	var sdt_saved: int = Meta.stardust_total
	Meta.stardust = 1000
	var unlocked := 0
	for tid_v: Variant in gl.registry.traits.keys():
		var td: TraitData = gl.registry.get_trait(StringName(String(tid_v)))
		if td != null and int(td.rarity) >= 0:
			Meta.codex_traits[String(tid_v)] = true
			unlocked += 1
	var pool: Array[StringName] = gl._blessing_pool()
	_check("夹具：全池解锁 ≥30 项（R263 静态 62 实跑定稿）（实测 %d/%d）" % [unlocked, pool.size()], pool.size() >= 30,
		"pool=%d" % pool.size())
	ui.open(pool, "", 0)
	await p_tree.process_frame

	# ── ① 默认签=蓝（difficulty0→rarity1）：首屏 ≤7 行 + 页数按蓝档子集统计 ──
	var blue_n := 0
	for tid in pool:
		var td_b: TraitData = gl.registry.get_trait(tid)
		if td_b != null and int(td_b.rarity) == 1:
			blue_n += 1
	var rows_p0: int = ui._list_box.get_child_count()
	_check("分页：首屏行数 ≤7（页容量口）", rows_p0 <= 7 and rows_p0 > 0,
		"rows=%d" % rows_p0)
	var pages: int = ui._page_count()
	_check("分页：蓝档子集页数（动态统计 %d 项）" % blue_n, pages == ceili(float(blue_n) / 7.0),
		"pages=%d blue=%d" % [pages, blue_n])
	_check("分页：翻页钮可用（下一页非禁用）", not ui._page_next_btn.disabled)
	_check("分页：上一页禁用（首页边界）", ui._page_prev_btn.disabled)

	# ── ② 翻页：下一页→行变化+页码；回首页同行实例（页缓存复用） ──
	var row0_p0: Node = ui._list_box.get_child(0)
	ui._on_page_next()
	await p_tree.process_frame
	var rows_p1: int = ui._list_box.get_child_count()
	_check("分页：第二页行变（不同实例）+页码 2/%d" % pages,
		ui._page == 1 and ui._list_box.get_child(0) != row0_p0
			and String(ui._page_label.text) == "2/%d" % pages,
		"page=%d label=%s" % [ui._page, ui._page_label.text])
	_check("分页：末页边界（下一页禁用=%s）" % str(pages == 2),
		ui._page_next_btn.disabled == (pages == 2))
	ui._on_page_prev()
	await p_tree.process_frame
	_check("页缓存：翻回首页=同行实例（零重建）",
		ui._list_box.get_child(0) == row0_p0)

	# ── ③ 品级筛选：切蓝档签→行全 rarity1 且行数=池内蓝档数（R262 键 rarity） ──
	ui._on_filter_pick(-1)                        # 先显式回全部签（open 默认蓝签——避开同值早退测不到切换路径）
	await p_tree.process_frame
	ui._on_filter_pick(1)                         # 切蓝档签
	await p_tree.process_frame
	var rows_f: int = ui._list_box.get_child_count()
	var all_blue := true
	for c in ui._list_box.get_children():
		var td_f: TraitData = gl.registry.get_trait(
			StringName(String((c as Button).get_meta(&"trait_id"))))
		if td_f == null or int(td_f.rarity) != 1:
			all_blue = false
	_check("筛选：蓝档签=行全 rarity1（池内 %d 项）" % blue_n,
		rows_f == mini(blue_n, 7) and all_blue,
		"rows=%d expect=%d all_blue=%s" % [rows_f, mini(blue_n, 7), str(all_blue)])
	_check("筛选：切签回第一页+翻页行随新池", ui._page == 0)

	# 切签后旧行释放（基签名变=全弃置）
	var old_row: Node = row0_p0
	ui._on_filter_pick(-1)
	await p_tree.process_frame
	_check("页缓存：基签名变（切签往返）旧行弃置释放", not is_instance_valid(old_row),
		"old_valid=%s" % str(is_instance_valid(old_row)))

	# 空档隐藏：构造无金档子池 open → 金档签（get(3)）隐藏（R262 键 rarity）
	var pool_no_gold: Array[StringName] = []
	for tid in pool:
		var td_e: TraitData = gl.registry.get_trait(tid)
		if td_e != null and int(td_e.rarity) != 3:
			pool_no_gold.append(tid)
	ui.open(pool_no_gold, "", 0)
	await p_tree.process_frame
	var gold_btn: Button = ui._filter_btns.get(3)
	_check("筛选：空档页签隐藏（无金档子池→金签隐藏）", gold_btn != null and not gold_btn.visible,
		"gold_visible=%s" % str(gold_btn != null and gold_btn.visible))
	ui.close()

	# ── ④ 预选跳页：预选蓝档子集尾项（末页）→open 直跳末页+选中在树 ──
	#（R262：last_tid 取蓝档子集尾项——全池尾项 SYN_PIERCE_EVO r2 会触发 M2 跳紫签，
	# 在 pages（蓝子集页数）口径下 _page==pages-1 必红；R263 送武后蓝档 24 条尾项数据驱动）
	var last_tid: StringName = &""
	for tid in pool:
		var td_l: TraitData = gl.registry.get_trait(tid)
		if td_l != null and int(td_l.rarity) == 1:
			last_tid = tid                        # 循环不 break——字典序尾项
	ui.open(pool, String(last_tid), 0)
	await p_tree.process_frame
	var sel_btn: Button = ui._row_by_id(String(last_tid))
	_check("预选跳页：末页项 open 直跳（页 %d/%d）+选中在树" % [ui._page + 1, pages],
		ui._page == pages - 1 and sel_btn != null and sel_btn.button_pressed,
		"page=%d sel=%s" % [ui._page, str(sel_btn != null)])
	ui.close()

	# ── ⑤ 重叠修（评审 H2 收口：icon 钳宽 44+文字 x≥68） ──
	ui.open(pool, "", 0)
	await p_tree.process_frame
	var first_row: Button = ui._list_box.get_child(0) as Button
	var got_x := -1.0
	for l in first_row.find_children("*", "Label", true, false):
		var nl := l as Label
		if nl.position.x < got_x or got_x < 0:
			got_x = nl.position.x
	var icon_w: int = first_row.get_theme_constant("icon_max_width")
	_check("重叠修：文字 x ≥68（实测 %.0f）+ icon 钳宽 44（实测 %d）——章右缘 62 与文字留 6px 缝" % [got_x, icon_w],
		got_x >= 68.0 and icon_w == 44,
		"x=%s icon_w=%d" % [str(got_x), icon_w])

	# ── ⑥ 评审 H1：隐形携带防线——翻页后选中回填+摘要行 ──
	# R262 推演（第三轮 P3 裁决零迁移依据）：AFF_AREA.tres 实查 rarity=1 蓝档
	#（白档 6 项=AFF_ATK_UP/CRIT_RATE/HP_UP/PICKUP/PROJ_SPD/ROF_UP），pool[0]=全池
	# 字典序首位=AFF_AREA 落默认蓝签页 0；:next _on_filter_pick(-1) 切全部签（R263
	# 送武后 62 项页 0）→ _row_by_id(pool[0]) 必中——按下/翻页/摘要/回填链全绿。
	ui._page = 0                                  # ④ 预选跳页残留页码归零（pool[0] 回首页）
	ui._on_filter_pick(-1)                        # open 默认蓝签 → 显式切全部签（R262 起为真切换）
	ui._rebuild_rows()
	await p_tree.process_frame
	var sel0_btn: Button = ui._row_by_id(String(pool[0]))
	if sel0_btn != null:
		sel0_btn.set_pressed_no_signal(true)
		ui._on_row_toggled(true, String(pool[0]))
	ui._on_page_next()
	await p_tree.process_frame
	_check("评审H1：翻页后「已选」摘要行可见（跨页感知）",
		ui._sel_summary.text.contains("已选："),
		"summary=%s" % ui._sel_summary.text)
	ui._on_page_prev()
	await p_tree.process_frame
	var back_btn: Button = ui._row_by_id(String(pool[0]))
	_check("评审H1：翻回所在页=选中态回填（视觉不丢）",
		back_btn != null and back_btn.button_pressed,
		"pressed=%s" % str(back_btn.button_pressed if back_btn != null else false))
	ui._row_by_id(String(pool[0])).set_pressed_no_signal(false)
	ui._on_row_toggled(false, String(pool[0]))

	# ── ⑦ 评审 M1/M2（R262 品级签键）：预选跨档项自动跳签 + 保留档缺席回退 ──
	# M2：预选紫档项重开 → 应自动跳到紫档签（open 重置默认签=蓝，紫项被挡——跳签语义）
	var white_tid: StringName = &""
	for tid in pool:
		var td_a: TraitData = gl.registry.get_trait(tid)
		if td_a != null and int(td_a.rarity) == 0:
			white_tid = tid
			break
	var purple_tid: StringName = &""
	for tid in pool:
		var td_mm: TraitData = gl.registry.get_trait(tid)
		if td_mm != null and int(td_mm.rarity) == 2:
			purple_tid = tid
			break
	if white_tid != &"" and purple_tid != &"":
		ui._on_filter_pick(0)                     # 切白档签（模拟玩家切签路径——open 后默认签重置归蓝）
		ui.close()
		ui.open(pool, String(purple_tid), 0)      # 预选紫档项（被默认蓝签挡住）
		await p_tree.process_frame
		var sel_m2: Button = ui._row_by_id(String(purple_tid))
		_check("评审M2：预选被筛选挡住=自动跳到所在签+选中可见",
			ui._filter_rarity == 2 and sel_m2 != null and sel_m2.button_pressed,
			"filter=%d sel=%s" % [ui._filter_rarity, str(sel_m2 != null)])
	elif white_tid != &"":
		ui.close()
		ui.open(pool, String(white_tid), 0)
		await p_tree.process_frame
		_check("评审M2：池无紫档（回退臂）——预选仍可见", ui._row_by_id(String(white_tid)) != null)
	else:
		_check("评审M2：池无白档项（跳过）", true)
	# M1：保留档签后换无蓝档池（difficulty0 错位触发）→ open 回退全部
	#（R262：open 头重置 _filter_rarity=_tier——直写 _filter_rarity=1 会被重置覆盖，
	# 触发源=池无蓝档×difficulty0 默认蓝签→蓝子集空→M1 回退 -1）
	ui.close()
	var pool_no_blue: Array[StringName] = []
	for tid in pool:
		var td_p: TraitData = gl.registry.get_trait(tid)
		if td_p != null and int(td_p.rarity) != 1:
			pool_no_blue.append(tid)
	ui._filter_rarity = 1
	ui.open(pool_no_blue, "", 0)
	await p_tree.process_frame
	_check("评审M1：保留档在新池缺席=回退「全部」+列表非空",
		ui._filter_rarity == -1 and ui._list_box.get_child_count() > 0,
		"filter=%d rows=%d" % [ui._filter_rarity, ui._list_box.get_child_count()])
	ui.close()

	# 夹具还原（快照精确还原——R262 解锁改全池键；R263 星尘 fixture 还原）
	Meta.codex_traits.clear()
	for k_v: Variant in codex_snapshot.keys():
		Meta.codex_traits[String(k_v)] = true
	Meta.stardust = sd_saved
	Meta.stardust_total = sdt_saved
	Meta._save()
	ui.close()
	gl.free()
	print("验收汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	for f in _failures:
		print("  FAIL | %s" % f)


func fail_count() -> int:
	return _fail

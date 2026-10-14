extends RefCounted
# R261 QA 专项深挖 cases（配套口 qa_r261_probe_deep.gd）。
# 池构成侦察（R263 送武通道后三态滤）：T1（蓝子池）=24
# T2（紫子池）=26 全池=62={白6,蓝24,紫26,金6}
# a 筛选×预选组合  b 筛选+翻页边界  c 页缓存释放完备  d ButtonGroup 跨页
# e 行高/布局回归  f diag 事件新格式  + 主控外补测（首开预选跳页/选中态跨页一致性）
# R262 迁移：筛选键 pool→rarity 品级签；池改全池（t1/t2 探针保留子池臂）；默认签
# =当前难度档（open 重置——「跨 open 保留筛选」前提退役）。

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


func _tid_of(p_row: Button) -> String:
	return String(p_row.get_meta(&"trait_id"))


func _first_of_rarity(p_pool: Array[StringName], p_rarity: int, p_reg: Object) -> String:
	for tid in p_pool:
		var td: TraitData = p_reg.get_trait(tid)
		if td != null and int(td.rarity) == p_rarity:
			return String(tid)
	return ""


func _group_pressed_count(p_group: ButtonGroup) -> int:
	var n := 0
	for b_v: Variant in p_group.get_buttons():
		var b := b_v as Button
		if b != null and is_instance_valid(b) and b.button_pressed:
			n += 1
	return n


func _fresh_ui(p_gl: Object, p_tree: SceneTree, p_name: String) -> BlessingPickUI:
	# 新建 BlessingPickUI（game_loop 同款接线：registry 注入 + add_child）——
	# 用于首开（_rows_sig==""）路径复现（gl.blessing_pick_ui 在前序用例已被 open 过）
	var ui := BlessingPickUI.new()
	ui.name = p_name
	ui.registry = p_gl.registry
	p_tree.get_root().add_child(ui)
	return ui


func _last_diag_ev(p_prefix: String) -> String:
	var lines: Array = DebugStats._diag_ev_lines
	for i in range(lines.size() - 1, -1, -1):
		if String(lines[i]).contains(p_prefix):
			return String(lines[i])
	return ""


func run(p_tree: SceneTree) -> void:
	var gl_script: GDScript = load("res://scripts/loop/game_loop.gd")
	var gl = gl_script.new()
	gl.name = "GameLoopForR261Deep"
	p_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	var waited := 0
	while not gl.boot_ready and waited < 600:
		await p_tree.process_frame
		waited += 1
	var ui: BlessingPickUI = gl.blessing_pick_ui
	_check("boot：菜单就绪", gl.boot_ready and ui != null)

	# 夹具：解锁全档（r0..r3——b 组金签 6 项/白签 6 项/f 组池=62 需要全池口径；
	# t1/t2 子池探针只按 rarity 分档，解锁全档不改变 24/26）；记忆键+星尘快照/还原
	#（R263：预选/挂载按价收费——星尘 fixture 预置，防余额不足拒预选）
	var mem_saved: String = Meta.blessing_trait_id
	var sd_saved: int = Meta.stardust
	var sdt_saved: int = Meta.stardust_total
	Meta.stardust = 1000
	var unlocked_keys: Array[String] = []
	for tid_v: Variant in gl.registry.traits.keys():
		var td_d: TraitData = gl.registry.get_trait(StringName(String(tid_v)))
		if td_d != null:
			var key := String(tid_v)
			if not Meta.codex_traits.has(key):
				unlocked_keys.append(key)
			Meta.codex_traits[key] = true
	var pool_all: Array[StringName] = gl._blessing_pool()
	var t1: Array[StringName] = gl._blessing_pool(1)
	var t2: Array[StringName] = gl._blessing_pool(2)
	# R263：W1 首发三态滤后蓝/紫子池静态值（蓝 21 适配+3 送武=24·紫 21 适配+5 送武=26；
	# 全池 62={白6,蓝24,紫26,金6}；实跑校准）
	_check("夹具：T1=24 T2=26（R263 送武后蓝/紫子池静态值）", t1.size() == 24 and t2.size() == 26,
		"t1=%d t2=%d" % [t1.size(), t2.size()])
	# 预选跳页用锚点：T1 第 8 项（页 2）+ T2 第 8 项（页 2）
	var t1_p2 := String(t1[7])
	var t2_p2 := String(t2[7])

	# ══ 补1：首开（_rows_sig==""）预选跳页 —— 真机最常见路径（跨局记忆→新会话首次出发）══
	var ui_fresh: BlessingPickUI = _fresh_ui(gl, p_tree, "BlesFreshA")
	ui_fresh.open(t1, t1_p2, 0)
	await p_tree.process_frame
	var fresh_btn: Button = ui_fresh._row_by_id(t1_p2)
	_check("补1-首开预选跳页：记忆项在页2 → open 应跳页2（实测页 %d/%d）"
		% [ui_fresh._page + 1, ui_fresh._page_count()],
		ui_fresh._page == 1 and fresh_btn != null and fresh_btn.button_pressed,
		"page=%d sel_btn=%s pressed=%s sel_id_empty=%s"
			% [ui_fresh._page, str(fresh_btn != null), str(fresh_btn != null and fresh_btn.button_pressed),
				str(ui_fresh._selected_id.is_empty())])
	_check("补1-首开预选 armed 语义：跳页失败时 _selected_id 仍 armed（确认仍携带）",
		not ui_fresh._selected_id.is_empty() or ui_fresh._page == 1,
		"sel=%s page=%d" % [ui_fresh._selected_id, ui_fresh._page])

	# ══ 补2：换难度重开（基签名变）预选跳页 ══
	# gl.ui 先以 T1 同签名打开（对齐主控路径），再换 T2 难度重开+T2 记忆项
	ui.open(t1, "", 0)
	await p_tree.process_frame
	ui.open(t2, t2_p2, 1)
	await p_tree.process_frame
	var d2_btn: Button = ui._row_by_id(t2_p2)
	_check("补2-换档重开预选跳页：T1→T2 记忆项在页2 → 应跳页2（实测页 %d/%d）"
		% [ui._page + 1, ui._page_count()],
		ui._page == 1 and d2_btn != null and d2_btn.button_pressed,
		"page=%d sel_btn=%s" % [ui._page, str(d2_btn != null)])
	ui.close()

	# ══ a：筛选×预选组合（预选项不在当前筛选档）══
	# 语义读实现（R262）：open() 每次重置默认签=当前难度档；记忆项在池但被默认签
	# 挡住 → M2 自动跳到所在品级签+页（非静默清空）。
	ui.open(t1, "", 0)
	await p_tree.process_frame
	ui._on_filter_pick(0)                       # 白签（R262 键 rarity——t1 蓝子池无白项=空签；
	await p_tree.process_frame                   # open 重置默认签后此 pick 仅模拟切签路径）
	var mech_id := _first_of_rarity(pool_all, 2, gl.registry)   # 紫档首项 AFF_MULTI（源必须全池——蓝子池 t1 恒空致 M2 不触发）
	ui.close()
	ui.open(pool_all, mech_id, 0)               # 记忆=紫项 + open 默认签=蓝（difficulty0）
	await p_tree.process_frame
	# R261 评审 M2 修轮后语义（R262 键 rarity）：预选在池但被筛选挡住=自动跳到所在签+选中可见（非静默清空）
	_check("a-预选不在筛选档：自动跳到所在签（M2 修轮语义）", ui._filter_rarity == 2,
		"filter=%d" % ui._filter_rarity)
	_check("a-预选不在筛选档：_selected_id 保留（预选生效）",
		ui._selected_id == String(mech_id),
		"sel=%s" % ui._selected_id)
	_check("a-预选不在筛选档：选中行按下可见（无隐形携带）",
		_group_pressed_count(ui._btn_group) == 1)
	# 对照组：记忆项在跳签后紫签子集页 2 → 跳签后跳页+选中（R262 机制=默认签重置+
	# M2 跳签后跳页——「同签名重开」前提退役）。取项口径钉死：紫档签 _filtered 子集
	# 内 index>=7（紫档 26 项 4 页——子集 index 7..25 在页 2+；严禁按 pool_all
	# 全局索引——紫项全局 idx 字面 /7 会错页）。
	var purple_list: Array[StringName] = []
	for tid in pool_all:
		var td_pl: TraitData = gl.registry.get_trait(tid)
		if td_pl != null and int(td_pl.rarity) == 2:
			purple_list.append(tid)
	var purple_idx := -1
	for i in range(purple_list.size()):
		if i >= 7:
			purple_idx = i
			break
	if purple_idx >= 0:
		var purple_p2_id := String(purple_list[purple_idx])
		ui.close()
		ui.open(pool_all, purple_p2_id, 0)     # open 默认蓝签 → M2 跳紫签 → 跳页
		await p_tree.process_frame
		var purple_btn: Button = ui._row_by_id(purple_p2_id)
		_check("a-对照：记忆项在跳签后紫签子集页 2 → 跳签+跳页选中",
			ui._page == purple_idx / 7 and purple_btn != null and purple_btn.button_pressed,
			"page=%d expect=%d btn=%s" % [ui._page, purple_idx / 7, str(purple_btn != null)])
	else:
		_check("a-对照：紫签页 2 项存在（跳过）", true)
	ui.close()

	# ══ b：筛选+翻页边界（R262：池改全池，difficulty1 默认签=紫）══
	var ui_b: BlessingPickUI = _fresh_ui(gl, p_tree, "BlesFreshB")
	ui_b.open(pool_all, "", 1)
	await p_tree.process_frame
	ui_b._on_filter_pick(3)                    # 金签（全池金档 6 项→单页）
	await p_tree.process_frame
	_check("b-单页筛选（金档6项）：翻页钮双禁+页码空",
		ui_b._page_prev_btn.disabled and ui_b._page_next_btn.disabled
			and String(ui_b._page_label.text) == "" and ui_b._list_box.get_child_count() == 6,
		"prev=%s next=%s label=%s rows=%d"
			% [str(ui_b._page_prev_btn.disabled), str(ui_b._page_next_btn.disabled),
				ui_b._page_label.text, ui_b._list_box.get_child_count()])
	ui_b._on_filter_pick(2)                    # 紫签（26 项 4 页）
	await p_tree.process_frame
	_check("b-多页筛选（紫档26项）：页数=4+首页边界（上禁下通）",
		ui_b._page_count() == 4 and ui_b._page == 0
			and ui_b._page_prev_btn.disabled and not ui_b._page_next_btn.disabled
			and String(ui_b._page_label.text) == "1/4",
		"pages=%d page=%d label=%s" % [ui_b._page_count(), ui_b._page, ui_b._page_label.text])
	for _pn in range(3):
		ui_b._on_page_next()
		await p_tree.process_frame
	_check("b-翻至末页：页码 4/4+末页边界（上通下禁）",
		ui_b._page == 3 and String(ui_b._page_label.text) == "4/4"
			and not ui_b._page_prev_btn.disabled and ui_b._page_next_btn.disabled,
		"page=%d label=%s" % [ui_b._page, ui_b._page_label.text])
	ui_b._on_filter_pick(0)                    # 末页切白签（6 项单页）
	await p_tree.process_frame
	_check("b-末页切签：回第一页（白档 6 项单页静默）",
		ui_b._page == 0 and ui_b._list_box.get_child_count() == 6
			and ui_b._page_prev_btn.disabled and ui_b._page_next_btn.disabled
			and String(ui_b._page_label.text) == "",
		"page=%d rows=%d" % [ui_b._page, ui_b._list_box.get_child_count()])
	ui_b._on_filter_pick(2)
	await p_tree.process_frame
	ui_b._on_page_next()
	await p_tree.process_frame
	ui_b._on_filter_pick(-1)                   # 紫签页 2 切全部签
	await p_tree.process_frame
	_check("b-中页切全部签：回第一页", ui_b._page == 0, "page=%d" % ui_b._page)

	# ══ b 补：默认档缺席 → 回退全部+空档签隐藏（R262：直写保留筛选场景退役——
	# open 每次重置默认签；缺席回退=池×难度错位触发：t1 蓝子池×difficulty1 默认紫签）══
	ui_b.close()
	ui_b.open(t1, "", 1)                       # 默认紫签；t1 蓝子池无紫 → M1 缺席回退全部
	await p_tree.process_frame
	var gold_btn_b: Button = ui_b._filter_btns.get(3)
	_check("b补-默认档缺席：t1 无紫 → 回退全部签+金签隐藏+列表 7 行（M1 修轮语义）",
		gold_btn_b != null and not gold_btn_b.visible and ui_b._filter_rarity == -1
			and ui_b._list_box.get_child_count() == 7,
		"vis=%s filter=%d rows=%d" % [str(gold_btn_b.visible), ui_b._filter_rarity,
			ui_b._list_box.get_child_count()])
	ui_b._on_filter_pick(1)                    # 自愈路径：点蓝档签恢复
	await p_tree.process_frame
	_check("b补-自愈：点蓝档签恢复 24 行 4 页（蓝子池 24 项）", ui_b._list_box.get_child_count() == 7
		and ui_b._page_count() == 4,
		"rows=%d pages=%d" % [ui_b._list_box.get_child_count(), ui_b._page_count()])
	ui_b.close()

	# ══ c：页缓存释放完备（切签→切回→翻各页→再切签，旧行全 freed）══
	# R262：池改全池（沿用 t2 则收尾 pick(2) 与 open 默认紫签同值早退不重建→stale>0
	# 必红）；序列按默认签重排：紫签 4 页→金签 1 页→全部 9 页→紫签收尾弃置
	var ui_c: BlessingPickUI = _fresh_ui(gl, p_tree, "BlesFreshC")
	ui_c.open(pool_all, "", 1)                 # 默认签=紫（difficulty1）——紫子集 26 项 4 页
	await p_tree.process_frame
	var collected: Array = []
	var page0_row0: Node = ui_c._list_box.get_child(0)
	for p_idx in range(ui_c._page_count()):    # 默认紫签 2 页逐页翻（收集+回访零重建）
		while ui_c._page < p_idx:
			ui_c._on_page_next()
			await p_tree.process_frame
		for r_v: Variant in ui_c._list_box.get_children():
			collected.append(r_v)
	while ui_c._page > 0:                       # 末页逐页翻回首
		ui_c._on_page_prev()
		await p_tree.process_frame
	_check("c-翻页往返零重建（回访页=同行实例）", ui_c._list_box.get_child(0) == page0_row0)
	ui_c._on_filter_pick(3)                    # 切金签（R263 送武后 6 项 1 页——range 空转）
	await p_tree.process_frame
	for p_idx in range(ui_c._page_count()):
		while ui_c._page < p_idx:
			ui_c._on_page_next()
			await p_tree.process_frame
		for r_v: Variant in ui_c._list_box.get_children():
			collected.append(r_v)
	ui_c._on_filter_pick(-1)                   # 切全部 → 62 项 9 页再翻
	await p_tree.process_frame
	for p_idx in range(ui_c._page_count()):
		while ui_c._page < p_idx:
			ui_c._on_page_next()
			await p_tree.process_frame
		for r_v: Variant in ui_c._list_box.get_children():
			collected.append(r_v)
	ui_c._on_filter_pick(2)                    # 再切紫签（收尾首页 7 行）→ 基签名变 → 全弃置
	await p_tree.process_frame
	var stale := 0
	for r_v: Variant in collected:
		if is_instance_valid(r_v):
			stale += 1
	_check("c-页缓存释放完备：历轮 %d 行全 freed（滞留 %d）" % [collected.size(), stale],
		stale == 0, "stale=%d/%d" % [stale, collected.size()])
	_check("c-弃置后组内无 freed 滞留（组钮数=当页行数 7）",
		ui_c._btn_group.get_buttons().size() == 7,
		"group=%d" % ui_c._btn_group.get_buttons().size())
	ui_c.close()

	# ══ d：ButtonGroup 跨页交互（t1 蓝子池 difficulty0 默认蓝签=子池全部——交互与签键无关）══
	var ui_d: BlessingPickUI = _fresh_ui(gl, p_tree, "BlesFreshD")
	ui_d.open(t1, "", 0)
	await p_tree.process_frame
	var row_a: Button = ui_d._list_box.get_child(0) as Button
	row_a.button_pressed = true                # 页1 选 A
	await p_tree.process_frame
	_check("d-页1选中：_selected_id=A+单按下", ui_d._selected_id == _tid_of(row_a)
		and _group_pressed_count(ui_d._btn_group) == 1)
	ui_d._on_page_next()                       # 翻页2（未再选）
	await p_tree.process_frame
	ui_d._on_page_prev()                       # 翻回页1
	await p_tree.process_frame
	# R261 评审 H1 修轮后语义：翻页往返选中态回填（视觉不丢）+摘要行感知锚
	_check("d-翻页往返（未再选）：旧项选中态回填（视觉不丢——H1 修轮语义）",
		row_a.button_pressed)
	_check("d-翻页往返（未再选）：_selected_id 保持（armed 与视觉一致）",
		ui_d._selected_id == _tid_of(row_a),
		"sel=%s" % ui_d._selected_id)
	var row_b: Button = ui_d._list_box.get_child(0) as Button   # 页2 首行（页2 此刻在树）
	# 注：此刻已翻回页1——先翻去页2 取 B
	ui_d._on_page_next()
	await p_tree.process_frame
	row_b = ui_d._list_box.get_child(0) as Button
	row_b.button_pressed = true                # 页2 选 B（组内单选：A 让位）
	await p_tree.process_frame
	_check("d-跨页改选：_selected_id=B+A 已让位",
		ui_d._selected_id == _tid_of(row_b) and not row_a.button_pressed,
		"sel=%s" % ui_d._selected_id)
	ui_d._on_page_prev()
	await p_tree.process_frame
	_check("d-改选后回页1：旧页项 A 已取消（跨页单选语义）", not row_a.button_pressed)
	ui_d._on_page_next()                       # 再回页2（B 所在页）
	await p_tree.process_frame
	_check("d-重访选中所在页：B 应保持选中态（当前选中的可见反馈）",
		row_b.button_pressed,
		"b_pressed=%s sel=%s" % [str(row_b.button_pressed), ui_d._selected_id])
	_check("d-终态：_selected_id=B（逻辑选中不因翻页丢失）",
		ui_d._selected_id == _tid_of(row_b))
	ui_d.close()

	# ══ e：行高/布局回归（与签键无关零迁移）══
	var ui_e: BlessingPickUI = _fresh_ui(gl, p_tree, "BlesFreshE")
	ui_e.open(t1, "", 0)
	await p_tree.process_frame
	var frow: Button = ui_e._list_box.get_child(0) as Button
	var e_ok1: bool = frow.custom_minimum_size.y >= 64.0
	var name_l: Label = null
	var desc_l: Label = null
	for l_v: Variant in frow.get_children():
		var l := l_v as Label
		if l != null:
			# R263：行尾新增价签 Label（x≈488 右列）——分类加 x 界排除，只认内容列（x<450）
			if l.position.x < 450.0:
				if l.position.y < 30.0:
					name_l = l
				else:
					desc_l = l
	var e_ok2: bool = name_l != null and desc_l != null \
		and name_l.position.y == 10.0 and name_l.position.y + name_l.size.y <= 64.0 \
		and desc_l.position.y == 38.0 and desc_l.position.y + desc_l.size.y <= 64.0 \
		and name_l.position.x >= 64.0 and desc_l.position.x >= 64.0
	_check("e-行 64px 内双行 Label（y10/y38）不溢出且 x≥64",
		e_ok1 and e_ok2,
		"minh=%s name=%s desc=%s" % [str(frow.custom_minimum_size.y),
			str(name_l.position if name_l != null else Vector2.ZERO),
			str(desc_l.position if desc_l != null else Vector2.ZERO)])
	var sub_bottom: float = ui_e._subtitle.position.y + ui_e._subtitle.size.y
	var tab_top: float = 1e9
	var tab_bottom: float = -1e9
	for fk_v: Variant in ui_e._filter_btns.keys():
		var tb: Button = ui_e._filter_btns[fk_v]
		tab_top = minf(tab_top, tb.position.y)
		tab_bottom = maxf(tab_bottom, tb.position.y + tb.size.y)
	var list_top: float = ui_e._list_box.position.y
	_check("e-页签行（y124）与副标题（y92）不叠+不压列表",
		sub_bottom <= tab_top and tab_bottom <= list_top,
		"sub_bottom=%.0f tab_top=%.0f tab_bottom=%.0f list_top=%.0f"
			% [sub_bottom, tab_top, tab_bottom, list_top])
	var list_bottom: float = list_top + 7.0 * 64.0 + 6.0 * 6.0
	var pager_top: float = ui_e._page_prev_btn.position.y
	_check("e-满页列表底（652）不压翻页行（y664）",
		list_bottom <= pager_top, "list_bottom=%.0f pager_top=%.0f" % [list_bottom, pager_top])
	ui_e.close()

	# ══ f：diag 事件新格式（池=筛=页=%d/%d；R262：open 重置默认签——diag 反映默认签构成）══
	var ui_f: BlessingPickUI = _fresh_ui(gl, p_tree, "BlesFreshF")
	ui_f.open(pool_all, "", 1)                 # 默认签=紫（difficulty1）——池 62 筛 26 页 1/4
	await p_tree.process_frame
	ui_f._on_filter_pick(2)                    # 同值早退（默认已是紫签）——diag 保持 open 时快照
	await p_tree.process_frame
	var ev_line := _last_diag_ev("祝福面板可见化")
	var f_ok := ev_line.contains("池=62") and ev_line.contains("筛=26") \
		and ev_line.contains("页=1/4") and ev_line.contains("层=40")
	_check("f-diag 事件：池=62 筛=26 页=1/4 层=40 可读（实跑校准）",
		f_ok, "line=%s" % ev_line)
	ui_f.close()

	# ── 夹具还原 ──
	Meta.blessing_trait_id = mem_saved
	Meta.stardust = sd_saved                     # R263：星尘 fixture 还原
	Meta.stardust_total = sdt_saved
	for key in unlocked_keys:
		Meta.codex_traits.erase(key)
	Meta._save()
	ui.close()
	ui_fresh.free()
	ui_b.free()
	ui_c.free()
	ui_d.free()
	ui_e.free()
	ui_f.free()
	gl.free()
	print("深挖汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	for f in _failures:
		print("  FAIL | %s" % f)


func fail_count() -> int:
	return _fail

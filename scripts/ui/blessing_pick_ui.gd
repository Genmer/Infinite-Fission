# scripts/ui/blessing_pick_ui.gd
# R252 需求② 祝福（开局自选词条）面板：选图/选难度确认后由 GameLoop 侧弹层
#（menu_screen.gd 归 R252 实施员 D 独占——本面板落 GameLoop 层，SublimeConfirmUI
# 弹层先例；GameStatus 保持 MENU 模态，确认/不选后才进 start_run）。
# 骨架照抄 sublime_confirm_ui.gd：全屏 PopPalette.DIM 压暗 + 白卡
# StickerTheme.panel_style(24,4,true) + squash_pop 果冻出场 + 按钮
# focus_mode=FOCUS_NONE（真机异形屏/手柄焦点不抢）+ SafeAreaHelper 三行接入。
# 契约（设计 §2.3 UI 行）：
# · 列表 = 候选池按 id 序（GameLoop._blessing_pool 已过滤+排序；本 UI 零 rng）；
# · R262 品级筛选页签（TraitData.rarity：白0/蓝1/紫2/金3 + 全部）+ 分页 7 行/页
#   （ScrollContainer 退役——触摸拖动被行 Button 吞）；默认签 = 当前难度档
#   （blessing_rarity_tier 映射），每次 open 重置（「跨 open 保留筛选」退役——
#   全档开放后跨档筛选残留易致「列表空了像坏了」）；默认档签池内缺席 → 回退全部；
#   记忆项（Meta.blessing_trait_id）若在池中 → 预选并自动跳到所在签+页
#   （在池但被筛选挡住=跳签非静默丢弃；保留签在新池缺席=回退全部）；
# · 选中态跨页/跨签由「已选」摘要行兜底感知（隐形携带防线——翻页回填按下态）；
# · 按钮「出发」（confirmed(id)——选中项写记忆由 GameLoop 侧完成）/「不选祝福」
#   （dismissed()——不覆盖记忆键，下次仍默认带上）；
# · 图标 TextureFactory.type_icon(1, pool)（TRAIT 类别圆章，按 PoolClass 分形）、
#   取色 PopPalette.rarity_color/rarity_name（档位色/名与卡面同源）。
class_name BlessingPickUI
extends CanvasLayer

const BLES_LAYER := 40                        # R258：面板绘制层（低于首遇卡 50/boot 屏 100，
                                              # 高于全部默认 0 层屏——open 时重申=免疫挂载序）

signal confirmed(p_trait_id: String)            # 「出发」：当前选中项 id（空串=未选直出发，同不选语义）
signal dismissed()                              # 「不选祝福」/防御收口：不覆盖记忆键
signal cleared()                                # R252-QA第1轮 B3：「清除记忆」——永久退出祝福携带（GameLoop 清键）

var registry: DataRegistry = null               # 词条数据源（GameLoop boot 注入——menu_screen 同款）

var _root: Control = null
var _card: Panel = null
var _band: ColorRect = null                   # R260：档位色顶带（open 随档刷新——原 build 期烘焙存量缺陷）
var _title: Label = null                      # R260：同上（标题档位色）
var _subtitle: Label = null
var _list_box: VBoxContainer = null
var _clear_btn: Button = null                   # R252-QA第1轮 B3：「清除记忆」（无记忆时禁用）
var _btn_group: ButtonGroup = ButtonGroup.new()
var _selected_id: String = ""                   # 当前选中词条 id（"" = 未选）
var _pool: Array[StringName] = []               # 本帧候选池（预选校验用）
var _tier: int = 1                              # 档位（rarity 名/色读口参数）
var _rows_sig: String = ""                      # R260：行缓存基签名（池序|档——变则全弃置）
var _filter_rarity: int = -1                    # R262：品级筛选（-1=全部；否则 TraitData.rarity 白0/蓝1/紫2/金3）
var _filtered: Array[StringName] = []           # R261：筛选后池（分页数据源）
var _page: int = 0                              # R261：当前页（0 基）
var _rows_page_cache: Dictionary = {}           # R261：页级行缓存（页码 → Array[Button]）
var _filter_btns: Dictionary = {}               # R262：品级页签钮（rarity 值 → Button；-1=全部）
var _page_prev_btn: Button = null               # R261：翻页钮
var _page_next_btn: Button = null
var _page_label: Label = null
var _sel_summary: Label = null                  # R261 评审 H1：「已选」摘要行（跨页/跨签感知锚）
var _stardust_label: Label = null                # R263：星尘余额行（摘要行与 footer 间空带——消费现场披露）
var _start_wid: StringName = &""                 # R263：附赠标记判定首发上下文（GameLoop 注入；
                                                  # 空=无上下文（测试直开）→ 武器绑定行全标附赠）
const BLES_PAGE_SIZE := 7                       # R261：页容量（真机视口 7 行整——触摸滚动
                                                 # 被行 Button 吞拖动的坑连根拔：去滚动壳改分页）


func _ready() -> void:
	# MENU 态树不暂停（LEVEL_UP 才 tree.paused）——默认 process_mode 足够；
	# 防御收口：面板期任何离 MENU 迁移（E-16 死亡优先级等异常路径）→ 面板即收并按
	# 「不选祝福」上报（GameLoop 清 _blessing_pending 闸，不启动新局）
	_btn_group.allow_unpress = true             # 再点已选行可取消——未选直出发合法（空串 confirmed）
	_build_ui()
	_root.visible = false
	# R195 适配：安全区接入（sublime/pause_overlay 同款三行——守卫外 insets 恒零=零扰动）
	_apply_safe_area()
	if SafeAreaHelper.enabled(get_window()):
		_apply_safe_area_deferred()
	SafeAreaHelper.bind_reread(get_window(), _apply_safe_area)
	EventBus.state_changed.connect(_on_state_changed)


func _apply_safe_area() -> void:
	var ins := SafeAreaHelper.insets(get_window())
	_root.offset_left = ins.position.x
	_root.offset_top = ins.position.y
	_root.offset_right = -ins.size.x
	_root.offset_bottom = -ins.size.y


func _apply_safe_area_deferred() -> void:
	await SafeAreaHelper.read_deferred(get_window())
	_apply_safe_area()


func is_open() -> bool:
	# 测试/GameLoop 观测口（sublime 同款鸭子口）
	return _root != null and _root.visible


func open(p_pool: Array[StringName], p_mem_id: String, p_difficulty: int,
		p_start_wid: StringName = &"") -> void:
	# 开面板（GameLoop._try_open_blessing_pick 唯一入口）：重建候选列表 + 记忆项预选
	# + 果冻出场。幂等：重复 open 只刷内容（模态期二次出发被 _blessing_pending 吞，
	# UI 侧不设防——sublime 同口径）。
	# R261：筛选+分页（真机反馈「只有第一页无法往下翻」——ScrollContainer 触摸
	# 拖动被行 Button 吞=滚不动；改成就面板同款分页 7 行/页+页签，滚动壳连根拔）。
	# R262：筛选键 pool→rarity 品级签；默认签=当前难度档（每次 open 重置——跨 open
	# 保留筛选退役）；默认档签池内缺席回退「全部」。
	# R263：p_start_wid=附赠标记首发上下文（缺省空串兼容旧三参调用）；记忆项余额
	# 不足 → 不预选 + 副标题披露 + 余额行刷新（价签/置灰在行级 _make_row）。
	# 行缓存升页粒度（基签名=池|档|签 变则全弃置，页码键复用——R260 同款口径）。
	# 档位色（顶带/标题/行按下色）随档刷新——原 build 期烘焙 _tier=1 存量缺陷顺修。
	_pool = p_pool.duplicate()                    # 池序由 GameLoop 侧按 id 序保证（本 UI 零 rng 零重排）
	_tier = GameConst.blessing_rarity_tier(p_difficulty)
	_filter_rarity = _tier                        # R262：默认签=当前难度档（每次 open 重置）
	_selected_id = ""
	_start_wid = p_start_wid                      # R263：附赠标记判定上下文（行缓存签名不含——
	                                              # 行构建期直读，池/档/签变即重建，上下文随 open 恒新）
	# R263：记忆项不可负担（余额 < 价签）→ 不预选（防「选中却带不上」）+ 副标题披露。
	var mem_unaffordable := false
	if not p_mem_id.is_empty() and _pool.has(StringName(p_mem_id)):
		var td_mem: TraitData = registry.get_trait(StringName(p_mem_id)) if registry != null else null
		if td_mem != null and Meta.stardust < Meta.blessing_cost(int(td_mem.rarity)):
			mem_unaffordable = true
	# R261 评审 M1（R262 键改 rarity）：保留签在池内缺席（低解锁存档默认档子集为空）
	# → 回退「全部」（否则激活签被隐藏+列表全空=死胡同）；M2：预选判定走全池
	#（记忆项在池但被筛选挡住时自动跳到所在签+页——契约「在池 → 预选」不因视图状态静默失效）
	if _filter_rarity >= 0 and registry != null:
		var cls_present := false
		for tid in _pool:
			var td_c: TraitData = registry.get_trait(tid)
			if td_c != null and int(td_c.rarity) == _filter_rarity:
				cls_present = true
				break
		if not cls_present:
			_filter_rarity = -1
	_apply_filter()
	_rebuild_rows()                              # 签名变时内部 reset _page=0（QA-261-1：跳页须后置）
	# 预选跳签+跳页（QA-261-1：放 _rebuild_rows 之后——签名分支的 _page=0 不再覆盖
	# 跳页；跳签/跳页后再重挂目标页——页缓存命中零建行）
	# R263：不可负担记忆不预选（行级已置灰不可选——预选态会误导「出发必带上」）。
	if not mem_unaffordable and not p_mem_id.is_empty() and _pool.has(StringName(p_mem_id)):
		_selected_id = p_mem_id
		var mem_tid := StringName(p_mem_id)
		var td_m: TraitData = registry.get_trait(mem_tid) if registry != null else null
		if td_m != null and _filter_rarity >= 0 and int(td_m.rarity) != _filter_rarity:
			_filter_rarity = int(td_m.rarity)     # 记忆项被筛选挡住 → 自动跳到所在品级签
			_apply_filter()
			_rebuild_rows()                       # 换签=签名变 reset 页 0+挂新签页
		_page = _filtered.find(mem_tid) / BLES_PAGE_SIZE   # 跳到所在页（预选必可见）
		_rebuild_rows()                           # 重挂目标页（回填选中态在内）
	if _band != null:
		_band.color = PopPalette.rarity_color(_tier)
	if _title != null:
		_title.add_theme_color_override("font_color", PopPalette.rarity_color(_tier))
	_clear_btn.disabled = p_mem_id.is_empty()     # B3：无记忆时「清除记忆」禁用（无可清）
	if not _selected_id.is_empty():
		var btn := _row_by_id(_selected_id)
		if btn != null:
			btn.set_pressed_no_signal(true)
	_subtitle.text = ("难度【%s】· %s级祝福（全档可选）——选定后每次出发默认携带"
		% [GameConst.difficulty_name(p_difficulty), PopPalette.rarity_name(_tier)])
	if mem_unaffordable:
		_subtitle.text += "　※ 记忆祝福余额不足，本局将不携带"   # R263：不可负担披露
	_refresh_filter_tabs()
	_refresh_pager()
	if _stardust_label != null:                  # R263：余额行随开刷新（结算后余额变即新值）
		_stardust_label.text = "◆ 星尘余额 %d｜祝福按品级收费：白%d/蓝%d/紫%d/金%d" \
			% [Meta.stardust, Meta.BLESSING_COST[0], Meta.BLESSING_COST[1],
				Meta.BLESSING_COST[2], Meta.BLESSING_COST[3]]
	# R258：CanvasLayer 绘制序真源=layer 属性（同 0 层才按添加序）——open 时重申
	# layer=40 盖过全部默认 0 层屏（menu/hud/结算/设置），免疫挂载序（vc65 真机日志
	# 定罪：修前面板与菜单同 0 层先挂=菜单整层盖住面板，玩家「点出发没反应」真身）。
	# 挂载序归位（game_loop add 挪 menu 后）为第二重保险。同帧几何入 diag 事件环。
	layer = BLES_LAYER
	_root.visible = true
	StickerTheme.squash_pop(_card)
	DebugStats.event("祝福面板可见化：卡片=%s 层=%d 序位=%d/%d 池=%d 筛=%d 页=%d/%d"
		% [str(Rect2(_card.global_position, _card.size)).replace("(", "[").replace(")", "]"),
			layer, get_index(), get_parent().get_child_count(),
			_pool.size(), _filtered.size(), _page + 1, _page_count()])


func _apply_filter() -> void:
	# R262：品级筛选（TraitData.rarity 白0/蓝1/紫2/金3；-1=全部）
	_filtered.clear()
	for tid in _pool:
		if _filter_rarity < 0:
			_filtered.append(tid)
			continue
		var td: TraitData = registry.get_trait(tid) if registry != null else null
		if td != null and int(td.rarity) == _filter_rarity:
			_filtered.append(tid)
	_page = clampi(_page, 0, maxi(0, _page_count() - 1))


func _page_count() -> int:
	return maxi(1, ceili(float(_filtered.size()) / float(BLES_PAGE_SIZE)))


func _rebuild_rows() -> void:
	# R261 页级行缓存：基签名=池|档|筛选|星尘余额（变则旧行全弃置 free——R259 HIGH-1
	# 同口径；R263 余额入签名：行置灰态随余额变，防结算回账后缓存行残留旧 disabled）；
	# 页码为缓存键（翻页往返零重建）。当前页行挂树，其余页留缓存。
	var base_sig := "%s|%d|%d|%d" % [str(_pool), _tier, _filter_rarity, Meta.stardust]
	if base_sig != _rows_sig:
		_free_page_cache()
		_rows_sig = base_sig
		_page = 0
	for c in _list_box.get_children():
		_list_box.remove_child(c)                 # 当页行 detach 回缓存（不 free）
	var page_rows: Array = _rows_page_cache.get(_page, [])
	if page_rows.is_empty():
		page_rows = []
		for i in range(_page * BLES_PAGE_SIZE, mini((_page + 1) * BLES_PAGE_SIZE, _filtered.size())):
			page_rows.append(_make_row(_filtered[i]))
		_rows_page_cache[_page] = page_rows
	for r_v: Variant in page_rows:
		_list_box.add_child(r_v)
	for b in _btn_group.get_buttons():            # 翻页后选中态全清（跨页单选重置）
		if is_instance_valid(b) and b.get_parent() != null:
			(b as Button).set_pressed_no_signal(false)
	# R261 评审 H1：回填当前选中行按下态——翻页/切签后选中视觉不丢（否则玩家以为
	# 未选而点出发=隐形携带且无法取消）；跨页/跨签不可见由「已选」摘要行兜底感知
	if not _selected_id.is_empty():
		var sel := _row_by_id(_selected_id)
		if sel != null:
			sel.set_pressed_no_signal(true)
	_refresh_sel_summary()


func _refresh_sel_summary() -> void:
	# R261 评审 H1：翻页行下方「已选：×××」摘要——选中项跨页/跨签不可见时的感知锚
	#（再点已选行或翻回其所在页可取消——allow_unpress 口径）
	if _sel_summary == null:
		return
	if _selected_id.is_empty():
		_sel_summary.text = ""
		return
	var name_txt := _selected_id
	if registry != null:
		var td_s: TraitData = registry.get_trait(StringName(_selected_id))
		if td_s != null:
			name_txt = String(td_s.display_name)
	_sel_summary.text = "已选：%s（点「出发」携带 · 再点该行可取消）" % name_txt


func _free_page_cache() -> void:
	# R259 HIGH-1 同口径：缓存行全数释放（含挂树防御 detach）
	for page_v: Variant in _rows_page_cache.values():
		for r_v: Variant in page_v:
			var r: Node = r_v as Node
			if r != null and is_instance_valid(r):
				if r.get_parent() != null:
					r.get_parent().remove_child(r)
				r.free()                          # 同帧清（重建口径——面板重进无残留）
	_rows_page_cache.clear()


func close() -> void:
	# 收面板（confirm/dismiss/防御收口共用；幂等）
	if _root != null:
		_root.visible = false


func confirm() -> void:
	# 「出发」收口：先收卡再发信号（面板期保持 MENU——GameLoop 确认回调里才 start_run）。
	# 重复调用幂等（is_open 假直接返）。
	if not is_open():
		return
	close()
	confirmed.emit(_selected_id)


func dismiss() -> void:
	# 「不选祝福」收口：不携带选中信息（GameLoop 不覆盖记忆键）
	if not is_open():
		return
	close()
	dismissed.emit()


func clear_memory() -> void:
	# R252-QA第1轮 B3：「清除记忆」收口——永久退出祝福携带（GameLoop 侧清记忆键）。
	# 幂等同 confirm（is_open 假直接返）；禁用态（无记忆）按钮点不到，此为程序化护栏。
	if not is_open():
		return
	close()
	cleared.emit()


func selected_id() -> String:
	# 测试观测口（B11 预选态断言）
	return _selected_id


func _on_row_toggled(p_on: bool, p_tid: String) -> void:
	# 行单选（ButtonGroup 单选 + allow_unpress：再点已选中行取消——未选直出发合法）
	if p_on:
		_selected_id = p_tid
	elif _selected_id == p_tid:
		_selected_id = ""
	_refresh_sel_summary()                      # R261 评审 H1：摘要随选实时


func _on_confirm_pressed() -> void:
	confirm()


func _on_dismiss_pressed() -> void:
	dismiss()


func _on_clear_pressed() -> void:
	clear_memory()


func _on_state_changed(p_state: int) -> void:
	# 防御：确认收口链外的任何态迁移（面板期恒 MENU）→ 面板即收 + 按不选上报
	#（confirmed 不发——非玩家出发语义；GameLoop 闸随之解除不误吞后续出发）
	if p_state != GameConst.GameStatus.MENU and is_open():
		close()
		dismissed.emit()


func _row_by_id(p_tid: String) -> Button:
	for c in _list_box.get_children():
		var b := c as Button
		if b != null and String(b.get_meta(&"trait_id")) == p_tid:
			return b
	return null


func _row_gift_weapon(p_td: TraitData) -> StringName:
	# R263 附赠标记判定（单源=MechanicGate.blessing_gift_weapon 解析武器名；本函数只裁
	# 「该行走送武还是挂载」）：送得出 且 不绑定当前首发（required_weapon 含首发 /
	# required_class 匹配首发类别 → 池内为普通项走挂载，不标附赠）。_start_wid 空
	#（测试直开面板无上下文）→ 绑定判定跳过，武器绑定行全标（池三态默认口径）。
	if p_td == null:
		return StringName("")
	var gift_wid := MechanicGate.blessing_gift_weapon(p_td,
		registry.weapons if registry != null else {})
	if gift_wid == StringName("") or registry == null:
		return gift_wid
	if _start_wid == StringName(""):
		return gift_wid                   # 无首发上下文：全标（挂载口 fits 优先兜底真实语义）
	var swd: WeaponData = registry.get_weapon(_start_wid)
	var weapon_req: Variant = p_td.params.get("required_weapon", null)
	var class_req: Variant = p_td.params.get("required_class", null)
	if weapon_req != null:
		if weapon_req is Array:
			for wv in (weapon_req as Array):
				if _start_wid == StringName(String(wv)):
					return StringName("")   # 绑定首发：挂载路径不送武
		elif _start_wid == StringName(String(weapon_req)):
			return StringName("")
	if class_req != null and swd != null and int(swd.form) == GameConst.WeaponForm.MELEE:
		var sclass := "melee"
		if swd.melee is Dictionary:
			sclass = String((swd.melee as Dictionary).get("weapon_class", "melee"))
		if class_req is Array:
			for cv in (class_req as Array):
				if String(cv) == sclass:
					return StringName("")
		elif String(class_req) == sclass:
			return StringName("")
	return gift_wid


func _make_row(p_tid: StringName) -> Button:
	# 候选行（R252-QA第1轮 B1 两行化）：TRAIT 类别圆章（TextureFactory.type_icon(1, pool)）
	# + 第一行词条名（粗）+ 第二行效果描述小字——TraitData.description 与图鉴「祝福」页
	# 同源同字段（menu_screen.gd:1043 同读 td.description）；触控竖屏无 tooltip 可用，
	# 蓝/紫池 26 选 1 仅凭名字不可构建。行高 52→64 = 两行布局触控下限（icon 垂直居中）。
	# 按下取档位色（选中反馈）；FOCUS_NONE 不抢焦点（真机/手柄口径同确认钮）。
	var td: TraitData = null
	if registry != null:
		td = registry.get_trait(p_tid)
	var btn := Button.new()
	btn.name = "BlessRow_" + String(p_tid)
	btn.toggle_mode = true
	btn.button_group = _btn_group
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(0.0, 64.0)
	# R261 评审 H2：icon 钳宽 44（Button.icon 原生尺寸绘制——64 画布章可见缘 63.5，
	# 加 content_margin_left 18=右缘 81.5 压 x64 文字 17px；44+18=62 与 x68 留 6px 缝。
	# menu_screen 三处 icon_max_width 同款先例）
	btn.add_theme_constant_override("icon_max_width", 44)
	btn.icon = TextureFactory.type_icon(1, int(td.pool) if td != null else 8)   # 8=FALLBACK 灰菱（td 缺失兜底——0 是 ADD 绿菱误导）
	btn.set_meta(&"trait_id", String(p_tid))
	btn.toggled.connect(_on_row_toggled.bind(String(p_tid)))
	# 第一行：词条名（text 置空改子 Label 双行布局——Button 单 text 无法两行）。
	# R261 评审 H2：x 52→68 修重叠（icon 钳宽 44+边距 18=右缘 62——68 起笔留 6px 缝）
	# R263 修轮（评审-6）：附赠标记上移名字行行尾（名字实测宽≤98px，行尾余量≈320px
	# 充裕；desc 行 420px 全留给效果文本——原「附赠·」前缀吃描述宽度的挤压解除）。
	var gift_wid := _row_gift_weapon(td)
	var name_text := String(td.display_name) if td != null else String(p_tid)
	if gift_wid != StringName(""):
		var gdata: WeaponData = registry.get_weapon(gift_wid) if registry != null else null
		name_text += "　附赠·%s" % (String(gdata.display_name) if gdata != null else String(gift_wid))
	var name_label := Label.new()
	StickerTheme.label_sticker(name_label, 19, PopPalette.INK, 0, Color.WHITE, true)
	# R263 修轮（QA-1）：Button 子节点 Label 超宽文本+截断组合会同步自增 rect（名字行
	# 同病预防）——clip_text 解耦文本宽与最小尺寸，rect 恒守 420（右缘 488=价签列起点）。
	# 顺序敏感：clip_text 必须先于 text/size 赋值——min 尺寸在 text 赋值瞬间已被撑大，
	# size 会被钳到文本宽且不再回缩（Godot 4.3 只增不减）。
	name_label.clip_text = true
	name_label.text = name_text
	name_label.position = Vector2(68.0, 10.0)
	name_label.size = Vector2(420.0, 24.0)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(name_label)
	# 第二行：效果描述小字（首行截断——多行描述取首行，溢出 Label 裁剪不撑行）。
	# R263 修轮（QA-1）：QA 实测 62 行中 32 行 desc rect 自增至 447~1665px 横穿价签文字
	# 区（左缘≈537）并溢出卡宽 572——clip_text 拒自增，desc 框恒 420（右缘 488），
	# 截断省略号由 OVERRUN_TRIM_ELLIPSIS 在框内完成（附赠段已移名字行，本行纯效果文本）。
	var desc_label := Label.new()
	StickerTheme.label_sticker(desc_label, 13, PopPalette.INK_SOFT)
	# 顺序敏感同上：clip_text 先于 text/size（min 撑大后 size 只增不减）。
	desc_label.clip_text = true
	desc_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	desc_label.text = (String(td.description) if td != null else "").split("\n")[0]
	desc_label.position = Vector2(68.0, 38.0)
	desc_label.size = Vector2(420.0, 18.0)
	desc_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(desc_label)
	# R263 价签：行右缘（x≈548-568）右对齐「-N」，色 = 行品级色（PopPalette.rarity_color
	# 与按下态/卡面同源——价签即档位可视化）。
	var row_cost := Meta.blessing_cost(int(td.rarity)) if td != null else 0
	var price_label := Label.new()
	StickerTheme.label_sticker(price_label, 14,
		PopPalette.rarity_color(int(td.rarity)) if td != null else PopPalette.INK, 0, Color.WHITE, true)
	price_label.text = "-%d" % row_cost
	price_label.position = Vector2(488.0, 22.0)
	price_label.size = Vector2(80.0, 20.0)
	price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	price_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(price_label)
	# R263 余额不足置灰：该行不可点选（记忆项不预选由 open() 副标题披露）。
	# 修轮（评审-2）：置灰须可感知——仅 StyleBox 微变被玩家读作「按钮坏了」；整行
	# modulate 降透明（名字/描述/价签/图标一体变淡=「买不起」语义，一处改动）。
	if td != null:
		btn.disabled = Meta.stardust < row_cost
		if btn.disabled:
			btn.modulate = Color(1.0, 1.0, 1.0, 0.45)
	# R262 品级取色：图标章下的文字按下态用「行自身品级」色（PopPalette.rarity_color
	# 与卡面同源——全档开放后同屏混档，行色随行不再随面板档）
	btn.add_theme_color_override("font_pressed_color",
		PopPalette.rarity_color(int(td.rarity) if td != null else 0))
	btn.add_theme_color_override("font_hover_pressed_color",
		PopPalette.rarity_color(int(td.rarity) if td != null else 0))
	return btn


func _refresh_filter_tabs() -> void:
	# R262：品级页签可见性（池内无该档则藏）+ 激活态。评审 M3：激活高亮走
	# toggle pressed（下沉变色=「正在生效」语义；disabled 灰化=「坏了点不动」反语义）；
	# 评审 M4：可见序重排 x（固定槽位在空档隐藏时中段留 92px 洞=像布局坏了）
	var present: Dictionary = {}
	for tid in _pool:
		var td: TraitData = registry.get_trait(tid) if registry != null else null
		if td != null:
			present[int(td.rarity)] = true
	var x := 24.0
	for pk_v: Variant in _filter_btns.keys():
		var pk := int(pk_v)
		var btn: Button = _filter_btns[pk_v]
		btn.visible = pk < 0 or present.has(pk)
		if btn.visible:
			btn.position.x = x
			x += 96.0
		btn.set_pressed_no_signal(pk == _filter_rarity)   # M3：toggle 高亮（同值早退在回调）


func _refresh_pager() -> void:
	# R261：翻页行状态（页码/边界禁用；单页整行隐藏——灰钮常驻占位观感差）
	var pages := _page_count()
	var multi := pages > 1
	if _page_label != null:
		_page_label.text = "%d/%d" % [_page + 1, pages] if multi else ""
	if _page_prev_btn != null:
		_page_prev_btn.visible = multi
		_page_prev_btn.disabled = _page <= 0
	if _page_next_btn != null:
		_page_next_btn.visible = multi
		_page_next_btn.disabled = _page >= pages - 1


func _on_filter_pick(p_rarity: int) -> void:
	# R262：切品级签=过滤+回第一页+重建（基签名变=全弃置；页缓存重建按需）。
	# 同值早退（M3：toggle 高亮下激活签再点无切换意义——pressed 已视觉回弹）
	if p_rarity == _filter_rarity:
		return
	_filter_rarity = p_rarity
	_apply_filter()
	_rebuild_rows()
	_refresh_filter_tabs()
	_refresh_pager()


func _on_page_prev() -> void:
	if _page > 0:
		_page -= 1
		_rebuild_rows()
		_refresh_pager()


func _on_page_next() -> void:
	if _page < _page_count() - 1:
		_page += 1
		_rebuild_rows()
		_refresh_pager()


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "BlessingPickRoot"
	_root.theme = StickerTheme.theme()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# R254 评审#4：真模态——全屏 STOP 吃穿罩点击（原 IGNORE 穿透：罩下「返回大厅」
	# 可开每日面板并发 start_run 洗每日种子；子控件正常收事件不受影响）
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	# 全屏压暗（藏青半透——菜单画面隐约可见，与暂停/选卡/红卡同观感）
	var dim := ColorRect.new()
	dim.name = "BlessingPickDim"
	dim.color = PopPalette.DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP   # R254 评审#4：卡外点击不穿透到大厅
	_root.add_child(dim)

	# 白卡（贴纸面板：圆角 24 + 藏青描边 + 底部厚投影；整体居中 620×900）
	_card = Panel.new()
	_card.name = "BlessingPickCard"
	_card.add_theme_stylebox_override("panel", StickerTheme.panel_style(24.0, 4, true))
	_card.anchor_left = 0.5
	_card.anchor_right = 0.5
	_card.anchor_top = 0.5
	_card.anchor_bottom = 0.5
	_card.offset_left = -310.0
	_card.offset_right = 310.0
	_card.offset_top = -450.0
	_card.offset_bottom = 450.0
	_card.pivot_offset = _card.size * 0.5
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_card)

	# 档位色顶带（蓝/紫/金随难度档——「祝福档位一眼可辨」视觉锚，红卡 RarityBand 同式）
	_band = ColorRect.new()
	_band.name = "RarityBand"
	_band.color = PopPalette.rarity_color(_tier)
	_band.position = Vector2(20.0, 20.0)
	_band.size = Vector2(580.0, 10.0)
	_band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(_band)

	_title = Label.new()
	StickerTheme.label_sticker(_title, 32, PopPalette.rarity_color(_tier), 0, Color.WHITE, true)
	_title.text = "祝福 · 开局自选"
	_title.position = Vector2(0.0, 44.0)
	_title.size = Vector2(620.0, 42.0)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card.add_child(_title)

	_subtitle = Label.new()
	StickerTheme.label_sticker(_subtitle, 15, PopPalette.INK_SOFT)
	_subtitle.position = Vector2(0.0, 92.0)
	_subtitle.size = Vector2(620.0, 22.0)
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card.add_child(_subtitle)

	# R262：品级筛选页签行（全部+白/蓝/紫/金——用户口径文案；rarity_name
	# 「普通/稀有/史诗/辉煌」保留为副标题正式名，二源并存）。池内空档 open 时隐藏；
	# 激活签禁点=高亮兼防抖。触摸目标 36px。
	var filter_names := {-1: "全部", 0: "白", 1: "蓝", 2: "紫", 3: "金"}
	for fk_v: Variant in filter_names.keys():
		var fbtn := Button.new()
		fbtn.name = "BlesFilter_%d" % int(fk_v)
		fbtn.text = String(filter_names[fk_v])
		fbtn.toggle_mode = true                   # M3：激活高亮=pressed（同值早退防抖在回调）
		fbtn.add_theme_font_size_override("font_size", 14)
		fbtn.add_theme_font_override("font", StickerTheme.font_bold())
		fbtn.add_theme_color_override("font_color",
			PopPalette.rarity_color(clampi(int(fk_v), 0, 3)) if int(fk_v) >= 0 else PopPalette.INK)
		fbtn.position = Vector2(24.0 + int(fk_v + 1) * 96.0, 124.0)
		fbtn.size = Vector2(92.0, 36.0)
		fbtn.focus_mode = Control.FOCUS_NONE
		fbtn.pressed.connect(_on_filter_pick.bind(int(fk_v)))
		fbtn.button_down.connect(func() -> void: StickerTheme.press_punch(fbtn))
		_card.add_child(fbtn)
		_filter_btns[fk_v] = fbtn

	# 候选列表（R261：ScrollContainer 退役——触摸拖动被行 Button 吞=真机滚不动，
	# 改分页 7 行/页+翻页钮（成就面板成熟先例）；VBox 定位区 572×484）
	_list_box = VBoxContainer.new()
	_list_box.name = "BlessingPickList"
	_list_box.position = Vector2(24.0, 168.0)
	_list_box.add_theme_constant_override("separation", 6)
	_list_box.size = Vector2(572.0, 484.0)
	_card.add_child(_list_box)

	# R261：翻页行（上一页/页码/下一页——单页静默）
	_page_prev_btn = Button.new()
	_page_prev_btn.name = "BlesPagePrev"
	_page_prev_btn.text = "◂ 上一页"
	_page_prev_btn.add_theme_font_size_override("font_size", 15)
	_page_prev_btn.add_theme_font_override("font", StickerTheme.font_bold())
	_page_prev_btn.position = Vector2(154.0, 664.0)
	_page_prev_btn.size = Vector2(150.0, 44.0)
	_page_prev_btn.focus_mode = Control.FOCUS_NONE
	_page_prev_btn.pressed.connect(_on_page_prev)
	_card.add_child(_page_prev_btn)
	_page_label = Label.new()
	StickerTheme.label_sticker(_page_label, 16, PopPalette.INK_SOFT)
	_page_label.text = ""
	_page_label.position = Vector2(304.0, 674.0)
	_page_label.size = Vector2(72.0, 24.0)
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card.add_child(_page_label)
	_page_next_btn = Button.new()
	_page_next_btn.name = "BlesPageNext"
	_page_next_btn.text = "下一页 ▸"
	_page_next_btn.add_theme_font_size_override("font_size", 15)
	_page_next_btn.add_theme_font_override("font", StickerTheme.font_bold())
	_page_next_btn.position = Vector2(376.0, 664.0)
	_page_next_btn.size = Vector2(150.0, 44.0)
	_page_next_btn.focus_mode = Control.FOCUS_NONE
	_page_next_btn.pressed.connect(_on_page_next)
	_card.add_child(_page_next_btn)
	# R261 评审 H1：已选摘要行（翻页行底 708 与 footer 762 之间的空带——选中项
	# 跨页/跨签不可见时的感知锚；空选静默）
	_sel_summary = Label.new()
	StickerTheme.label_sticker(_sel_summary, 13, PopPalette.PLAYER)
	_sel_summary.text = ""
	_sel_summary.position = Vector2(24.0, 716.0)
	_sel_summary.size = Vector2(572.0, 20.0)
	_sel_summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card.add_child(_sel_summary)

	# R263：星尘余额行（摘要行 736 与 footer 762 间空带——消费现场「余额/定价」双披露；
	# 文本 open() 刷新，色走 PopPalette.GOLD 暖金与星尘图标同源）
	_stardust_label = Label.new()
	StickerTheme.label_sticker(_stardust_label, 14, PopPalette.GOLD, 0, Color.WHITE, true)
	_stardust_label.text = ""
	_stardust_label.position = Vector2(0.0, 738.0)
	_stardust_label.size = Vector2(620.0, 20.0)
	_stardust_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stardust_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(_stardust_label)

	var footer := Label.new()
	StickerTheme.label_sticker(footer, 14, PopPalette.INK_SOFT)
	footer.text = "开局可选祝福须为图鉴已解锁词条（抽到对应词条卡后解锁）"
	footer.position = Vector2(0.0, 762.0)
	footer.size = Vector2(620.0, 18.0)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card.add_child(footer)

	# 三按钮（R252-QA第1轮 B3：原「出发/不选祝福」双钮扩为三钮等宽——「清除记忆」
	# 提供「不选祝福」之外的永久退出路径；无记忆时禁用。FOCUS_NONE 不抢焦点）
	var go_btn := Button.new()
	go_btn.name = "BlessingGoButton"
	go_btn.text = "出发"
	go_btn.add_theme_font_size_override("font_size", 21)
	go_btn.add_theme_font_override("font", StickerTheme.font_bold())
	go_btn.position = Vector2(24.0, 796.0)
	go_btn.size = Vector2(182.0, 68.0)
	go_btn.pivot_offset = go_btn.size * 0.5
	go_btn.focus_mode = Control.FOCUS_NONE
	go_btn.pressed.connect(_on_confirm_pressed)
	go_btn.button_down.connect(_on_btn_down.bind(go_btn))
	_card.add_child(go_btn)

	var skip_btn := Button.new()
	skip_btn.name = "BlessingSkipButton"
	skip_btn.text = "不选祝福"
	skip_btn.add_theme_font_size_override("font_size", 18)
	skip_btn.position = Vector2(219.0, 796.0)
	skip_btn.size = Vector2(182.0, 68.0)
	skip_btn.pivot_offset = skip_btn.size * 0.5
	skip_btn.focus_mode = Control.FOCUS_NONE
	skip_btn.pressed.connect(_on_dismiss_pressed)
	skip_btn.button_down.connect(_on_btn_down.bind(skip_btn))
	_card.add_child(skip_btn)

	_clear_btn = Button.new()
	_clear_btn.name = "BlessingClearButton"
	_clear_btn.text = "清除记忆"
	_clear_btn.add_theme_font_size_override("font_size", 18)
	_clear_btn.position = Vector2(414.0, 796.0)
	_clear_btn.size = Vector2(182.0, 68.0)
	_clear_btn.pivot_offset = _clear_btn.size * 0.5
	_clear_btn.focus_mode = Control.FOCUS_NONE
	_clear_btn.pressed.connect(_on_clear_pressed)
	_clear_btn.button_down.connect(_on_btn_down.bind(_clear_btn))
	_card.add_child(_clear_btn)


func _on_btn_down(p_btn: Button) -> void:
	# 按压果冻反馈（bind 传钮——回调连信号不用 lambda，sublime 同效）
	StickerTheme.press_punch(p_btn)

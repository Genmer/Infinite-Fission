# tests/runner/r190b_tips_cases.gd
# R190b tips 用例体（由 test_r190b_tips.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖 R191 G2「tips 详情卡」两处用户实测缺陷的行为级验收：
#   A. StickerTheme.theme() 全局 tooltip 条目（TooltipPanel/TooltipLabel——共享组 G1
#      theme.gd 落点：panel_style(10,2,true) 实底白 + 内容边距 12/12/6/8 + INK +
#      20pt + outline 0；引擎 tooltip 样式链经挂主题子树自动继承，工程不引 [gui]）
#   B. 构筑详情卡机制一句行（start_run → hud.build_details_requested.emit() → 每把
#      已持武器区块含 GameConst.weapon_note(该武器 id) 原句逐字相等——文案单源不手抄；
#      布局契约 (58,62) 508×34 / 12pt INK_SOFT / WORD_SMART / head 78→100 条件加高）
#   C. 无武器空态不崩（清槽后经生产路径重开详情卡 → 「暂无武器」引导，不进武器段）
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_test_theme_tooltip_entries()      # A（G1 theme.gd Tooltip 条目——G1 合入后全绿）
	_boot_game_loop()
	_test_details_weapon_note()        # B（详情卡机制句真源逐字 + 布局契约）
	_test_details_empty_state()        # C（无武器空态不崩）
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── A. StickerTheme 全局 tooltip 条目（共享组 G1 theme.gd 落点） ────
func _test_theme_tooltip_entries() -> void:
	print("── StickerTheme 全局 tooltip 条目 ──")
	var t := StickerTheme.theme()
	_check("theme() 注册 TooltipPanel panel 条目", t.has_stylebox("panel", "TooltipPanel"))
	if t.has_stylebox("panel", "TooltipPanel"):
		var sb := t.get_stylebox("panel", "TooltipPanel") as StyleBoxFlat
		_check("TooltipPanel 样式为 StyleBoxFlat", sb != null)
		if sb != null:
			_check("TooltipPanel bg_color == PopPalette.PANEL",
				sb.bg_color == PopPalette.PANEL, str(sb.bg_color))
			_check("TooltipPanel 实底（bg_color.a >= 1.0）", sb.bg_color.a >= 1.0,
				str(sb.bg_color.a))
			_check("TooltipPanel 内容边距 left/right=12",
				sb.content_margin_left == 12.0 and sb.content_margin_right == 12.0,
				"%s/%s" % [str(sb.content_margin_left), str(sb.content_margin_right)])
			_check("TooltipPanel 内容边距 top=6/bottom=8",
				sb.content_margin_top == 6.0 and sb.content_margin_bottom == 8.0,
				"%s/%s" % [str(sb.content_margin_top), str(sb.content_margin_bottom)])
	_check("theme() 注册 TooltipLabel font_color 条目",
		t.has_color("font_color", "TooltipLabel"))
	_check("TooltipLabel font_color == PopPalette.INK",
		t.get_color("font_color", "TooltipLabel") == PopPalette.INK,
		str(t.get_color("font_color", "TooltipLabel")))
	_check("theme() 注册 TooltipLabel font 条目（font() 系统黑体）",
		t.has_font("font", "TooltipLabel"))
	_check("TooltipLabel font_size >= 20",
		t.get_font_size("font_size", "TooltipLabel") >= 20,
		str(t.get_font_size("font_size", "TooltipLabel")))
	_check("TooltipLabel outline_size == 0（对齐 Label 条目 outline 0 口径）",
		t.get_constant("outline_size", "TooltipLabel") == 0,
		str(t.get_constant("outline_size", "TooltipLabel")))


# ── 引导（先例 w5_mirror_cases：main.tscn 实例化 + start_run） ──────
func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	# 测试档卫生（先例 verify_feedback_cases：清角色解锁位防残留往返携带）
	Meta.unlocked_characters = {}
	Meta.character_id = &"sentinel"
	_gl.start_run()
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	var slots: Array = _gl.player.get("weapon_slots")
	_check("Boot：start_run → PLAYING（默认手枪开局）",
		_gl.state == GameConst.GameStatus.PLAYING and slots.size() >= 1
		and slots[0] != null)


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()                          # 局内存档清档（防测试残留污染继续入口）
	if _gl != null:
		_gl.free()
		_gl = null


# ── B. 详情卡机制句（weapon_note 真源逐字 + 布局契约） ──────────────
func _test_details_weapon_note() -> void:
	print("── 详情卡机制句（weapon_note 真源） ──")
	_gl.hud.build_details_requested.emit()
	_check("点击左下角 → PAUSED", _gl.state == GameConst.GameStatus.PAUSED)
	_check("构筑详情卡可见", _gl.pause_overlay.is_details_visible())
	var list: Node = _gl.pause_overlay._details_list
	_check("详情列表存在", list != null and list.get_child_count() >= 2)
	# 武器区块归因：_details_list 直接子节点中 VBoxContainer 即武器区块（槽序——
	# 玩家属性/遗物/通用词条段均为 Panel 直挂，不混入）
	var sections: Array = []
	for c in list.get_children():
		if c is VBoxContainer:
			sections.append(c)
	var slots: Array = _gl.player.get("weapon_slots")
	var held: Array = []
	for w in slots:
		if w is WeaponBase and is_instance_valid(w) \
				and (w as WeaponBase).get("data") != null:
			held.append(w)
	_check("开局已持武器 ≥1（手枪首发）", held.size() >= 1)
	_check("武器区块数 == 已持武器数", sections.size() == held.size(),
		"sections=%d held=%d" % [sections.size(), held.size()])
	var idx := 0
	for w in held:
		var wid := String((w as WeaponBase).get("data").get("id"))
		var note := GameConst.weapon_note(wid)
		if note.is_empty():
			continue                       # 无机制句武器（未知 id 空句护栏）不逐字断言
		var texts: Array[String] = []
		_collect_labels(sections[idx], texts)
		_check("武器 %s 区块含 weapon_note 原句（逐字相等含于区块文本）" % wid,
			_texts_contain(texts, note), str(texts))
		# 布局契约：逐字句所在 Label——(58,62) 508 宽 / WORD_SMART / 12pt INK_SOFT /
		# mouse IGNORE；head 非空句条件加高 78→100（首个区块复核实现细节）。
		# 注：autowrap 行高由引擎按换行行数强制最小值（长句 2 行实测 48>34），
		# 故高断言取「不小于请求行高」而非定值
		var note_label := _find_label_equal(sections[idx], note)
		if idx == 0 and note_label != null:
			_check("机制句行位置 (58,62) 行宽 508（高 ≥34 行自动换行增长）",
				note_label.position == Vector2(58.0, 62.0)
				and note_label.size.x == 508.0 and note_label.size.y >= 34.0,
				"%s/%s" % [str(note_label.position), str(note_label.size)])
			_check("机制句行自动换行 WORD_SMART",
				note_label.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART)
			_check("机制句行 12pt INK_SOFT + mouse IGNORE",
				int(note_label.get_theme_font_size("font_size")) == 12
				and note_label.get_theme_color("font_color") == PopPalette.INK_SOFT
				and note_label.mouse_filter == Control.MOUSE_FILTER_IGNORE,
				"%d/%s" % [int(note_label.get_theme_font_size("font_size")),
					str(note_label.get_theme_color("font_color"))])
			var head_panel: Panel = sections[idx].get_child(0) as Panel
			_check("head 非空句条件加高 78→100",
				head_panel != null
				and head_panel.custom_minimum_size == Vector2(576.0, 100.0),
				str(head_panel.custom_minimum_size) if head_panel != null else "head 缺失")
		idx += 1
	_gl.pause_overlay.resume_requested.emit()
	_check("继续 → PLAYING", _gl.state == GameConst.GameStatus.PLAYING)


# ── C. 无武器空态不崩 ─────────────────────────────────────────────
func _test_details_empty_state() -> void:
	print("── 详情卡无武器空态 ──")
	var slots: Array = _gl.player.get("weapon_slots")
	for i in range(slots.size()):
		var w: Variant = slots[i]
		if w is WeaponBase and is_instance_valid(w):
			slots[i] = null
			(w as Node).free()
	# PLAYING → 生产路径重开详情卡（emit → request_pause → open_details）
	_gl.hud.build_details_requested.emit()
	_check("空态：重开详情卡 → PAUSED", _gl.state == GameConst.GameStatus.PAUSED,
		str(_gl.state))
	_check("空态：详情卡可见（不崩）", _gl.pause_overlay.is_details_visible())
	var texts: Array[String] = []
	_collect_labels(_gl.pause_overlay._details_list, texts)
	_check("空态显示「暂无武器」引导（不进武器段路径）",
		_texts_contain(texts, "暂无武器"), str(texts))
	_gl.pause_overlay.resume_requested.emit()
	_check("空态收尾恢复 PLAYING", _gl.state == GameConst.GameStatus.PLAYING)


# ── 工具 ──────────────────────────────────────────────────────────
func _collect_labels(p_node: Node, p_out: Array[String]) -> void:
	# 递归收集子树全部 Label 文本（详情卡层级：list→section→head/row→label）
	for c in p_node.get_children():
		if c is Label:
			p_out.append((c as Label).text)
		_collect_labels(c, p_out)


func _find_label_equal(p_node: Node, p_text: String) -> Label:
	# 逐字相等定位（机制句行 text == note 原句——详情卡布局契约的锚点）
	for c in p_node.get_children():
		if c is Label and (c as Label).text == p_text:
			return c as Label
		var sub := _find_label_equal(c, p_text)
		if sub != null:
			return sub
	return null


func _texts_contain(p_texts: Array[String], p_needle: String) -> bool:
	for txt in p_texts:
		if txt.find(p_needle) >= 0:
			return true
	return false


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
	else:
		_fail += 1
		_failures.append("%s（%s）" % [p_name, p_detail])

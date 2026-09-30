# tests/runner/rxn_codex_cases.gd
# 图鉴「反应」页用例体（由 test_rxn_codex.gd 入口在 autoload 就绪后运行时加载编译）。
# 断言移植自工作区只读探针 qa_rxn6_codex_probe.gd（B 三源同锁 / C 字型参数 / A 页构建 /
# D 触发真条件；A1 基线随落地翻转为 4 页签）+ 新页行级断言（名称单源 / 副文案含 effect 与
# unlock / 预览五项 override 对齐 DamagePopup._apply_reaction_look / 倍率运行时跟随
# GameConfig.balance.reaction_table）/ 页签显隐互斥 / 无存档键改动。
# R192（docs/design/R192_ELEMENT_MATRIX.md §13.1）：锁「恰 3 反应」断言全部翻动态口径
# （行数==reaction_table 行数、键集合来自枚举；note 闭集 5→7 字段 mult_fmt/sample；
# C5 翻 name/fmt 口径——look.text 键随 visual 批 1 删除；样张 == note.sample 单源；
# 冰草留白标注行走 GameConst 新常量、循环后追加 → 行数口径 = 全枚举 或 全枚举+1）。
# 现役三名/数值锁（coef 2.0/1.2、resist -0.3、cd_rxn 2.0）与存档零写入原文保留。
extends RefCounted

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _menu = null                              # MenuScreen（duck 类型——runtime load 环境零依赖）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	_test_note_single_source()
	_test_three_sources_locked()
	_test_font_params()
	_test_page_build()
	_test_tab_visibility()
	_test_rows_deep()
	_test_multiplier_follows_table()
	_test_no_save_keys()
	_test_reactions_true_conditions()
	_summary()


func fail_count() -> int:
	return _fail


# ── 支撑 ──────────────────────────────────────────────────────────
func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append(p_name)
		print("FAIL | %s | %s" % [p_name, p_detail])


func _summary() -> void:
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  失败项：%s" % f)


func _live_rows(p_list: Node) -> Array:
	# queue_free 已挂未销毁的行不计（qa 探针 _live 同口径；防旧名行挡住新行查找）
	var out: Array = []
	for c in p_list.get_children():
		if not c.is_queued_for_deletion():
			out.append(c)
	return out


func _live_count(p_list: Node) -> int:
	return _live_rows(p_list).size()


class SpyPipeline extends RefCounted:
	# 反应结算桩（qa 探针同款）：只记录 (element, base_atk)，不落伤害
	var calls: Array = []
	func resolve_reaction(p_ctx) -> RefCounted:
		calls.append([int(p_ctx.element), float(p_ctx.base_atk)])
		return null


func _rxn_keys() -> Array:
	# ReactionType 声明序键名（图鉴行建同源——wire T2：行序 = 枚举序；禁硬编码键清单）
	var out: Array = []
	for k in GameConst.ReactionType:
		out.append(String(k))
	return out


# ── 用例 ──────────────────────────────────────────────────────────
func _test_note_single_source() -> void:
	print("── reaction_note 文案单源（GameConst 全键；R192 动态枚举） ──")
	var keys := _rxn_keys()
	var all_ok := true
	var detail := ""
	for k in keys:
		var n: Dictionary = GameConst.reaction_note(k)
		if not (String(n.get("name", "")) != "" and String(n.get("recipe", "")) != ""
				and String(n.get("effect", "")) != "" and String(n.get("unlock", "")) != ""
				and String(n.get("mult_fmt", "")) != "" and String(n.get("sample", "")) != ""
				and (n.get("elements", []) as Array).size() == 2):
			all_ok = false
			detail = k
	_check("reaction_note 全键 name/recipe/effect/unlock/mult_fmt/sample 非空 + elements 配对",
		all_ok, detail)
	_check("reaction_note 字段封闭集（name/recipe/elements/effect/unlock/mult_fmt/sample 恰 7——无存档键来源）",
		GameConst.reaction_note("RXN_FIR_ICE").size() == 7
			and GameConst.reaction_note("RXN_FIR_ICE").has_all(
				["name", "recipe", "elements", "effect", "unlock", "mult_fmt", "sample"]))
	_check("reaction_note 坏 id 空字典（不崩）", GameConst.reaction_note("RXN_BAD").is_empty())
	# 名称与配方口径（真源：碎裂/过载/超导 · 火+冰/火+雷/冰+雷——现役三名逐字锁）
	_check("reaction_note 名称/配方口径",
		String(GameConst.reaction_note("RXN_FIR_ICE")["name"]) == "碎裂"
			and String(GameConst.reaction_note("RXN_FIR_LTG")["name"]) == "过载"
			and String(GameConst.reaction_note("RXN_ICE_LTG")["name"]) == "超导"
			and String(GameConst.reaction_note("RXN_FIR_ICE")["recipe"]) == "火 + 冰"
			and String(GameConst.reaction_note("RXN_FIR_LTG")["recipe"]) == "火 + 雷"
			and String(GameConst.reaction_note("RXN_ICE_LTG")["recipe"]) == "冰 + 雷")
	# 样张单源（wire T1 逐字锁：旧三键 1284 / 976 / 超导二字；新键由 B 组全键非空覆盖）
	_check("reaction_note 旧三键样张单源（碎裂1284 / 过载976 / 超导）",
		String(GameConst.reaction_note("RXN_FIR_ICE")["sample"]) == "1284"
			and String(GameConst.reaction_note("RXN_FIR_LTG")["sample"]) == "976"
			and String(GameConst.reaction_note("RXN_ICE_LTG")["sample"]) == "超导")
	# 效果句含结算语义 + 真条件（无难度门文案；免疫拒附/2s 冷却在句内——R192 全键覆盖）
	var cond_ok := true
	for k in keys:
		var eff := String(GameConst.reaction_note(k)["effect"])
		if not (eff.contains("双槽附着") and eff.contains("2s 冷却")
				and eff.contains("免疫怪拒附着") and not eff.contains("难度")):
			cond_ok = false
	_check("效果句含真条件（双槽/2s CD/免疫拒附）且无难度门文案（全键）", cond_ok)
	# 优先级句（现役三键文本 wire T1 逐字节不变→锁头部相对序：碎裂<过载<超导；
	# R192 扩序保持头部相对位——动态相对断言随句式演化仍成立）
	var eff0 := String(GameConst.reaction_note("RXN_FIR_ICE")["effect"])
	_check("效果句优先级头部相对序（碎裂<过载<超导——扩序不翻头部）",
		eff0.find("碎裂") >= 0 and eff0.find("碎裂") < eff0.find("过载")
			and eff0.find("过载") < eff0.find("超导"))


func _test_three_sources_locked() -> void:
	print("── 三源同锁 + 数值真源（探针 B1-B7 移植；R192 动态口径） ──")
	var rxn_enum: Dictionary = GameConst.ReactionType
	var rt: Dictionary = GameConfig.balance.reaction_table
	_check("B1 [追加保序] ReactionType 字面序锁（碎裂0/过载1/超导2）+ size == reaction_table 行数",
		int(rxn_enum.RXN_FIR_ICE) == 0 and int(rxn_enum.RXN_FIR_LTG) == 1
		and int(rxn_enum.RXN_ICE_LTG) == 2 and rxn_enum.size() == rt.size())
	var table_ok: bool = rt.size() == rxn_enum.size()
	for k in rxn_enum:
		table_ok = table_ok and rt.has(String(k))
	_check("B2 reaction_table 键集 == 枚举成员 id 集（%d 键——页面条目数数据真源）" % rxn_enum.size(),
		table_ok)
	_check("B3 碎裂 coef=2.0（×点燃剩余 DOT 总额）",
		absf(float(rt["RXN_FIR_ICE"]["coef"]) - 2.0) < 0.001)
	_check("B4 过载 coef=1.2 radius=90（120%ATK 爆炸）",
		absf(float(rt["RXN_FIR_LTG"]["coef"]) - 1.2) < 0.001
		and absf(float(rt["RXN_FIR_LTG"]["radius"]) - 90.0) < 0.001)
	_check("B5 超导 resist_delta=-0.3 duration=6s",
		absf(float(rt["RXN_ICE_LTG"]["resist_delta"]) + 0.3) < 0.001
		and absf(float(rt["RXN_ICE_LTG"]["duration"]) - 6.0) < 0.001)
	_check("B6 cd_rxn=2.0（条件文案：同反应 2s 内不重复触发）",
		absf(float(GameConfig.balance.cd_rxn) - 2.0) < 0.001)
	var looks: Dictionary = DamagePopup.REACTION_LOOKS
	var look_ok: bool = looks.size() == rxn_enum.size()
	for v in rxn_enum.values():
		look_ok = look_ok and looks.has(int(v))
	_check("B7 REACTION_LOOKS 键集 == 枚举值集（%d 项——字体预览条目数同锁）" % rxn_enum.size(),
		look_ok)
	var note_ok := true
	for k in rxn_enum:
		note_ok = note_ok and not GameConst.reaction_note(String(k)).is_empty()
	_check("B8 reaction_note 可枚举键集 == 枚举成员集（四源双射套件侧守望；坏 id 才空）", note_ok)


func _test_font_params() -> void:
	print("── R186 反应字型参数（探针 C1-C9 移植） ──")
	var looks: Dictionary = DamagePopup.REACTION_LOOKS
	_check("C1 反应字号 54 = roundi(30×1.8)",
		int(DamagePopup.FONT_SIZE_REACTION) == 54
		and int(DamagePopup.FONT_SIZE_REACTION) == roundi(int(DamagePopup.FONT_SIZE) * 1.8))
	_check("C2 反应描边 12px", int(DamagePopup.OUTLINE_PX_REACTION) == 12)
	_check("C3 三反应字型 variant = 0/1/2",
		int(looks[0]["variant"]) == 0 and int(looks[1]["variant"]) == 1
		and int(looks[2]["variant"]) == 2)
	_check("C4 填充/描边双色 = PopPalette.RXN_* 单源",
		looks[0]["fill"] == PopPalette.RXN_FILL_SHATTER and looks[0]["outline"] == PopPalette.RXN_LINE_SHATTER
		and looks[1]["fill"] == PopPalette.RXN_FILL_OVERLOAD and looks[1]["outline"] == PopPalette.RXN_LINE_OVERLOAD
		and looks[2]["fill"] == PopPalette.RXN_FILL_SUPER and looks[2]["outline"] == PopPalette.RXN_LINE_SUPER)
	_check("C5 [R192 翻转] LOOKS 无 text 键；name 单源 REACTION_NAMES；fmt 碎裂/过载=dmg、超导=pct",
		not looks[0].has("text") and not looks[1].has("text") and not looks[2].has("text")
		and String(looks[0]["name"]) == "碎裂"
		and String(looks[0]["name"]) == String(GameConst.REACTION_NAMES.get(
			int(GameConst.ReactionType.RXN_FIR_ICE), ""))
		and String(looks[1]["name"]) == "过载"
		and String(looks[2]["name"]) == "超导"
		and String(looks[2]["name"]) == String(GameConst.REACTION_NAMES.get(
			int(GameConst.ReactionType.RXN_ICE_LTG), ""))
		and String(looks[0]["fmt"]) == "dmg" and String(looks[1]["fmt"]) == "dmg"
		and String(looks[2]["fmt"]) == "pct")
	var f0 = StickerTheme.font_reaction(0)
	var f1 = StickerTheme.font_reaction(1)
	var f2 = StickerTheme.font_reaction(2)
	_check("C6 三字型字重/斜体：0=900直立 1=900斜体 2=700斜体",
		int(f0.font_weight) == 900 and not bool(f0.font_italic)
		and int(f1.font_weight) == 900 and bool(f1.font_italic)
		and int(f2.font_weight) == 700 and bool(f2.font_italic))
	_check("C7 三字型惰性缓存同实例（重复调用同对象）",
		StickerTheme.font_reaction(0) == f0 and StickerTheme.font_reaction(1) == f1
		and StickerTheme.font_reaction(2) == f2)
	_check("C8 字型链 Arial Black 打头 + CJK 兜底",
		String(f0.font_names[0]) == "Arial Black" and int(f0.font_names.size()) > 1)
	_check("C9 非法 variant 钳 0（§5 契约）",
		StickerTheme.font_reaction(-1) == f0 and StickerTheme.font_reaction(3) == f0)


func _test_page_build() -> void:
	print("── 页构建：4 页签 + 反应页 3 行（探针 A 组移植，A1 基线翻转） ──")
	var gl = GameLoop.new()
	gl.name = "GameLoopForRxnCodex"
	tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	_check("A0 Boot：GameLoop 就绪 + registry 已注入 MenuScreen",
		gl.boot_ready and gl.menu_screen.registry != null)
	_menu = gl.menu_screen
	var tab_keys: Array = _menu._codex_tabs.keys()
	_check("A1 [翻转基线] 图鉴页签恰 4 枚 = 怪物/武器/词条/反应",
		tab_keys.size() == 4 and tab_keys.has("怪物") and tab_keys.has("武器")
		and tab_keys.has("词条") and tab_keys.has("反应"))
	_check("A1b 页签几何：宽 126 · 「反应」末沿 486+126=612（右距 36 不变）",
		(_menu._codex_tabs["反应"] as Button).size.x == 126.0
		and (_menu._codex_tabs["反应"] as Button).position.x == 486.0
		and (_menu._codex_tabs["怪物"] as Button).size.x == 126.0)
	_menu._on_lobby_pressed("codex")
	_check("A2 图鉴面板打开且怪物页条目 >0",
		_menu._panel_root.visible and _live_count(_menu._panel_list) > 0)
	_menu._on_codex_tab("武器")
	_check("A3 武器页条目 = registry 武器数（%d）" % _menu.registry.weapons.size(),
		_live_count(_menu._panel_list) == _menu.registry.weapons.size())
	_menu._on_codex_tab("词条")
	_check("A4 词条页条目 = registry 词条数（%d）" % _menu.registry.traits.size(),
		_live_count(_menu._panel_list) == _menu.registry.traits.size())
	_menu._on_codex_tab("反应")
	var live5 := _live_count(_menu._panel_list)
	_check("A5 「反应」页签重建出全枚举条目（ReactionType 序；冰草标注行至多 +1）",
		live5 == GameConst.ReactionType.size()
		or live5 == GameConst.ReactionType.size() + 1, "live=%d" % live5)
	gl.free()
	_menu = null


func _test_tab_visibility() -> void:
	print("── 页签显隐互斥（图鉴 4 页签 vs 成就页签/翻页） ──")
	var gl = GameLoop.new()
	gl.name = "GameLoopForRxnCodexVis"
	tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	var menu = gl.menu_screen
	menu._on_lobby_pressed("ach")
	var codex_hidden := true
	for kind: String in menu._codex_tabs:
		if (menu._codex_tabs[kind] as Button).visible:
			codex_hidden = false
	var ach_shown: bool = menu._ach_tabs.size() == 4
	for kind: String in menu._ach_tabs:
		if not (menu._ach_tabs[kind] as Button).visible:
			ach_shown = false
	_check("切成就：图鉴 4 页签全部隐藏 + 成就 4 页签显示 + 翻页显示",
		codex_hidden and ach_shown and (menu._ach_prev_btn as Button).visible
		and (menu._ach_next_btn as Button).visible)
	menu._on_lobby_pressed("codex")
	var codex_shown := true
	for kind: String in menu._codex_tabs:
		if not (menu._codex_tabs[kind] as Button).visible:
			codex_shown = false
	var ach_hidden := true
	for kind: String in menu._ach_tabs:
		if (menu._ach_tabs[kind] as Button).visible:
			ach_hidden = false
	_check("切图鉴：图鉴 4 页签全部显示（:462 字典遍历自动继承）+ 成就页签/翻页隐藏",
		codex_shown and ach_hidden and not (menu._ach_prev_btn as Button).visible
		and not (menu._ach_page_label as Label).visible)
	menu._on_panel_close()
	gl.free()


func _test_rows_deep() -> void:
	print("── 行级断言：名称单源 / 副文案 / 预览五项 override / 样张（R192 表驱动全键） ──")
	var gl = GameLoop.new()
	gl.name = "GameLoopForRxnCodexRows"
	tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	var menu = gl.menu_screen
	menu._on_lobby_pressed("codex")
	menu._on_codex_tab("反应")
	var keys := _rxn_keys()
	var n_rxn: int = GameConst.ReactionType.size()
	var rows := _live_rows(menu._panel_list)
	_check("D0 反应页行数 == 枚举全键（冰草标注行至多 +1）",
		rows.size() == n_rxn or rows.size() == n_rxn + 1,
		"live=%d enum=%d" % [rows.size(), n_rxn])
	var fills := [PopPalette.RXN_FILL_SHATTER, PopPalette.RXN_FILL_OVERLOAD, PopPalette.RXN_FILL_SUPER]
	var lines := [PopPalette.RXN_LINE_SHATTER, PopPalette.RXN_LINE_OVERLOAD, PopPalette.RXN_LINE_SUPER]
	# 活行按构建序定位（枚举序添加）——不按行名匹配：同帧重建时旧 queue_free 行
	# 仍占名，add_child 撞名会改写新行名为 @Panel@N（行内子节点名不受影响）
	var all_ok := rows.size() >= n_rxn
	var detail := "" if rows.size() >= n_rxn else "live=%d" % rows.size()
	for i in range(mini(rows.size(), n_rxn)):
		var row: Control = rows[i]
		var rid: String = keys[i]
		var note: Dictionary = GameConst.reaction_note(rid)
		var name_l: Label = row.get_node_or_null("RxnName") as Label
		var desc_l: Label = row.get_node_or_null("RxnDesc") as Label
		var unlock_l: Label = row.get_node_or_null("RxnUnlock") as Label
		var mult_l: Label = row.get_node_or_null("RxnMult") as Label
		var prev: Label = row.get_node_or_null("RxnPreview") as Label
		if name_l == null or desc_l == null or unlock_l == null or mult_l == null or prev == null:
			all_ok = false
			detail = rid + " 行内标签缺失"
			continue
		# 名称 = reaction_note 单源；副文案区包含 effect 与 unlock 字段文本（不手抄）
		if name_l.text != String(note["name"]) or not desc_l.text.contains(String(note["effect"])) \
				or not unlock_l.text.contains(String(note["unlock"])) or mult_l.text.is_empty():
			all_ok = false
			detail = rid + " 文案不同源"
			continue
		# 预览五项 override（R186 规格读法同 fx_quality_cases：get_theme_* 命中 override 优先）
		var look: Dictionary = DamagePopup.REACTION_LOOKS[int(GameConst.ReactionType.get(rid))]
		if prev.get_theme_font_size("font_size") != DamagePopup.FONT_SIZE_REACTION \
				or prev.get_theme_constant("outline_size") != DamagePopup.OUTLINE_PX_REACTION \
				or prev.get_theme_color("font_color") != (look["fill"] as Color) \
				or prev.get_theme_color("font_outline_color") != (look["outline"] as Color) \
				or prev.get_theme_font("font") != StickerTheme.font_reaction(int(look["variant"])):
			all_ok = false
			detail = rid + " 预览参数不符"
			continue
		# 样张 == 实机同源组合（R192 收口2 用户口径「反应名+数字（包括图鉴）」）：dmg 型 =
		# 反应名+note.sample 数值段；pct/stat 型 = 反应名+DamagePopup.reaction_stat_text
		# 读表统计段（与跳字同一函数，防两处文案漂移）；无统计段反应（感电/扩散族）只显名。
		var num_seg := String(note["sample"])
		if String(look["fmt"]) != "dmg":
			num_seg = DamagePopup.reaction_stat_text(int(GameConst.ReactionType.get(rid)))
		var want_txt := String(look["name"]) + num_seg
		var sample := prev.text
		if sample != want_txt:
			all_ok = false
			detail = rid + " 样张 != 实机组合（want=%s got=%s）" % [want_txt, sample]
	_check("行级：名称单源 + 副文案含 effect/unlock + 预览五项参数 + 样张==实机组合（%d 行全过）" % n_rxn,
		all_ok, detail)
	# 预览双色/字型逐行对位：旧三键（枚举序恰为前三位 0/1/2——追加保序）对位 RXN_* 常量；
	# 新键行由 look 表自值覆盖（五项 override 已含 fill/outline/variant 自洽）
	var per_ok := true
	var per_detail := ""
	for i in range(mini(rows.size(), 3)):
		var prev: Label = rows[i].get_node_or_null("RxnPreview") as Label
		if prev == null:
			per_ok = false
			per_detail = keys[i] + " 无预览"
			continue
		if prev.get_theme_color("font_color") != fills[i] \
				or prev.get_theme_color("font_outline_color") != lines[i] \
				or prev.get_theme_font("font") != StickerTheme.font_reaction(i):
			per_ok = false
			per_detail = keys[i] + " 双色/字型错行"
	_check("行级：预览双色 RXN_* 与字型 0/1/2 逐行对位（碎裂/过载/超导）", per_ok, per_detail)
	# R191 收口 low 回归：条件句估宽 417~441px 超 400px 格 → autowrap 折行兜底；
	# 文案区右缘不越 414（预览区 420 起）——几何契约锁死防回退（全键表驱动）
	var geo_ok := true
	var geo_detail := ""
	for i in range(mini(rows.size(), n_rxn)):
		var dl: Label = rows[i].get_node_or_null("RxnDesc") as Label
		if dl == null or dl.autowrap_mode != TextServer.AUTOWRAP_WORD_SMART 				or dl.position.x + dl.size.x > 414.0:
			geo_ok = false
			geo_detail = keys[i] + " autowrap 关或右缘越 414"
	_check("行级：效果句 autowrap 开 + 右缘 ≤414px（不压预览区）", geo_ok, geo_detail)
	gl.free()


func _test_multiplier_follows_table() -> void:
	print("── 倍率运行时读表（禁硬编码：置 3.5 → 行文含 3.5 → 还原 2.0 → 复原） ──")
	var gl = GameLoop.new()
	gl.name = "GameLoopForRxnCodexMult"
	tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	var menu = gl.menu_screen
	var rt: Dictionary = GameConfig.balance.reaction_table
	var coef0 := float(rt["RXN_FIR_ICE"]["coef"])
	rt["RXN_FIR_ICE"]["coef"] = 3.5
	menu._on_lobby_pressed("codex")
	menu._on_codex_tab("反应")
	var rows := _live_rows(menu._panel_list)
	var mult_l: Label = null
	if rows.size() >= GameConst.ReactionType.size():
		mult_l = rows[0].get_node_or_null("RxnMult") as Label   # 行序 0 = RXN_FIR_ICE（枚举序首行不变）
	_check("倍率跟随表值：coef=3.5 → 碎裂行倍率文本含 3.5",
		mult_l != null and mult_l.text.contains("3.5"),
		"txt=%s" % (mult_l.text if mult_l != null else "-"))
	rt["RXN_FIR_ICE"]["coef"] = coef0                # 还原（防进程内数值表污染）
	menu._on_codex_tab("反应")
	rows = _live_rows(menu._panel_list)
	mult_l = null
	if rows.size() >= GameConst.ReactionType.size():
		mult_l = rows[0].get_node_or_null("RxnMult") as Label
	_check("还原 coef=2.0 后倍率复原（含 2.0 不含 3.5）",
		mult_l != null and mult_l.text.contains("2.0") and not mult_l.text.contains("3.5"),
		"txt=%s" % (mult_l.text if mult_l != null else "-"))
	menu._on_panel_close()
	gl.free()


func _test_no_save_keys() -> void:
	print("── 无存档层改动（Meta 四 codex_* 字段名不变；反应页零写入） ──")
	var gl = GameLoop.new()
	gl.name = "GameLoopForRxnCodexSave"
	tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	var menu = gl.menu_screen
	var snap0 := [Meta.codex_kills.size(), Meta.codex_first_met.size(),
		Meta.codex_weapons.size(), Meta.codex_traits.size(),
		Meta.achievements_done.size()]
	menu._on_lobby_pressed("codex")
	menu._on_codex_tab("反应")
	menu._on_codex_tab("怪物")
	var snap1 := [Meta.codex_kills.size(), Meta.codex_first_met.size(),
		Meta.codex_weapons.size(), Meta.codex_traits.size(),
		Meta.achievements_done.size()]
	_check("反应页开合前后 Meta codex_* / achievements_done 集合 size 不变（零写入）",
		snap0 == snap1, "before=%s after=%s" % [snap0, snap1])
	menu._on_panel_close()
	gl.free()


func _test_reactions_true_conditions() -> void:
	print("── 反应触发真条件（探针 D1-D4 移植；页面条件文案与此同源口径） ──")
	var sys = load("res://scripts/combat/elemental/elemental_system.gd").new()
	tree.get_root().add_child(sys)
	sys.pipeline = SpyPipeline.new()
	# 真实 Enemy 实例（不入树 → _ready 不跑；DamageContext.target 为 Enemy 类型强引用，
	# 桩敌会在 ctx 构造处报类型错——qa_rxn4_gate_probe.gd 即此坑，用真 Enemy 规避）
	var enemy = load("res://scripts/entities/enemy/enemy.gd").new()
	enemy.uid = 601
	tree.get_root().add_child(enemy)
	sys.register_host(enemy)
	# D1 只有单元素 → 不触发（条件 = 双槽均 >0）
	sys.apply_attach(enemy, 1, 30.0, {"snapshot": 100.0})   # Element.FIR
	sys.detect_reactions()
	var st = enemy.get("elemental")
	_check("D1 单槽附着不触发（双元素共存才反应）",
		sys.pipeline.calls.is_empty() and st.reaction_cd.is_empty())
	# D2 火+电 → 过载触发（1.2×快照100=120），双槽清零
	sys.apply_attach(enemy, 3, 30.0, {"snapshot": 100.0})   # Element.LTG
	sys.detect_reactions()
	_check("D2 火+电 = 过载（RXN_FIR_LTG，1.2×快照）+ 双槽清零",
		not sys.pipeline.calls.is_empty() and int(sys.pipeline.calls[0][0]) == 1
		and absf(float(sys.pipeline.calls[0][1]) - 120.0) < 0.001
		and float(st.gauges[1]) == 0.0 and float(st.gauges[3]) == 0.0)
	# D3 cd 内复检不触发（唯一节流门 = cd_rxn 2s；无难度/波次门）
	sys.pipeline.calls.clear()
	sys.apply_attach(enemy, 3, 30.0, {"snapshot": 100.0})
	sys.apply_attach(enemy, 1, 30.0, {"snapshot": 100.0})
	sys.detect_reactions()
	_check("D3 cd_rxn=2s 内复检不重复触发（无难度门/波次门）",
		sys.pipeline.calls.is_empty())
	# D4 优先级：三元素全附 → 一帧一反应且按 RXN_ORDER 碎裂优先
	var enemy2 = load("res://scripts/entities/enemy/enemy.gd").new()
	enemy2.uid = 602
	tree.get_root().add_child(enemy2)
	sys.register_host(enemy2)
	sys.apply_attach(enemy2, 1, 30.0, {"snapshot": 100.0})  # FIR
	sys.apply_attach(enemy2, 2, 30.0, {"snapshot": 100.0})  # ICE
	sys.apply_attach(enemy2, 3, 30.0, {"snapshot": 100.0})  # LTG
	sys.detect_reactions()
	var st2 = enemy2.get("elemental")
	_check("D4 三元素共存 → 碎裂（RXN_FIR_ICE=0）优先且一帧一反应（仅 cd[0] 落闸）",
		float(st2.reaction_cd.get(0, 0.0)) > 0.0 and float(st2.reaction_cd.get(1, 0.0)) == 0.0
		and float(st2.reaction_cd.get(2, 0.0)) == 0.0)
	sys.queue_free()

# tests/runner/test_r230_k4_hud_quant_cases.gd
# R230 K4「HUD Label 配色语义角色量化」验收用例体（由 test_r230_k4_hud_quant.gd 入口
# 运行时加载；骨架照 r229_fx_quantize_cases 既有 -cases 结构）。
# 覆盖（刀面 acceptance 逐条）：
#   ① 色板契约：LabelRole==7 角色；label_color 越界钳制（-1→INK / 99→WHITE，rarity_color
#      同式防呆）；角色值逐位等于 LABEL_ROLE_COLORS。
#   ② 语义色保全（v2 硬性子项）：
#      a. 7 色两两互异（21 对）；
#      b. 明度序严格递增（Rec.709 计量：INK<ENEMY<PLAYER<SOFT<SHOCK<GOLD<WHITE）；
#      c. 保真子集：正文墨/弱化灰蓝/品质金/我方蓝/警示红/暗底白六值与 PopPalette 单源
#         逐位相等（品质金 GOLD==XP 同值在案）；
#      d. 保留复核（R230 主控裁定）：镜面 toast 冰青 lerp / R187 读数浅紫 lerp 两处
#         按 R230 复核**保留原值**（F9 门禁证伪「逐件独立配色」前提，量化无 dc 收益
#         不值可见配色变更）——断言两 lerp 值仍不在量化色板（未混入单源）+ 色相族保持。
#   ③ grep 零残留直配（hud.gd 源级）：Label.new 恰 30 处；label_color 调用恰 36 处
#      （28 sticker 站点 + 4 动态写点各 2 角色）；每处 label_sticker / font_color override
#      调用（含跨行，窗口扫描）经 label_color 或命中保留白名单（镜面/R187 两站 lerp）；
#      theme.gd 色板机制块在位。
#      R241 有意契约迁移（原 29/33/29+2/3）：skill_auto_cast 自动施放按钮入面——
#      +1 Label.new（SkillAutoCast 文案）+1 sticker 站点 +1 动态写点（开=金/关=灰蓝
#      双角色，_sync_skill_auto_visual 全走 label_color——刀面精神不破）。
#   ④ 运行时行为（真 HUD 实例）：全子树 Label font_color override ∈ 色板∪2 保留 lerp 色；
#      语义钉（Boss 横幅=警示红 / HP=正文墨 / 金币=品质金 / 悬停卡=暗底白 / R187=柔电紫）；
#      动态切换（AUTO 开关 墨/灰蓝、复活横幅 金/警示红）两端均∈色板；四类临时 toast
#      （镜面/里程碑/刷新/成就）落点角色正确且全树复扫零直配漏网。
# 环境钉：auto_select_on 快照还原（set_setting 落 headless 测试隔离档，套件纪律同 r198）；
#   HUD 直建直 free（不经 GameLoop——配色面无需战斗数值源）。
extends RefCounted

const HUD_SRC := "res://scripts/ui/hud.gd"
const THEME_SRC := "res://scripts/ui/theme.gd"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _hud: HUD = null
var _auto_prev: bool = false


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(2304004)
	_auto_prev = bool(Meta.settings("auto_select_on"))
	_test_palette_contract()
	_test_semantic_preservation()
	_test_source_no_direct_coloring()
	_test_runtime_hud_labels()
	_teardown()
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
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _summary() -> void:
	print("────────────────────────────────────────")
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])


func _teardown() -> void:
	if _hud != null:
		_hud.free()
		_hud = null
	Meta.set_setting("auto_select_on", _auto_prev)   # 快照还原（防跨套件污染）


func _lum(p_c: Color) -> float:
	# Rec.709 相对亮度（明度序计量）
	return 0.2126 * p_c.r + 0.7152 * p_c.g + 0.0722 * p_c.b


func _read_src(p_path: String) -> String:
	var fa := FileAccess.open(p_path, FileAccess.READ)
	if fa == null:
		return ""
	var s := fa.get_as_text()
	fa.close()
	return s


func _lines_with(p_lines: Array, p_needle: String) -> Array:
	var out: Array = []
	for i in p_lines.size():
		if p_needle in p_lines[i]:
			out.append(i)
	return out


func _window_has(p_lines: Array, p_idx: int, p_span: int, p_needle: String) -> bool:
	# 跨行调用窗口扫描（GDScript 风格续行：调用头行 + span 行内找 needle）
	for k in range(p_idx, mini(p_idx + p_span + 1, p_lines.size())):
		if p_needle in p_lines[k]:
			return true
	return false


func _in_palette(p_c: Color) -> bool:
	for role_color: Color in StickerTheme.LABEL_ROLE_COLORS:
		if role_color == p_c:
			return true
	return false


func _walk_labels(p_node: Node, p_out: Array) -> void:
	for c in p_node.get_children():
		if c is Label:
			p_out.append(c)
		_walk_labels(c, p_out)


# ── ① 色板契约 ────────────────────────────────────────────────────
func _test_palette_contract() -> void:
	print("── ① 色板契约 ──")
	_check("① LabelRole==7 角色（墨/灰蓝/金/蓝/紫/红/白）",
		StickerTheme.LabelRole.size() == 7
			and StickerTheme.LABEL_ROLE_COLORS.size() == 7)
	_check("① 越界钳制：label_color(-1)==INK 档 / label_color(99)==WHITE 档（防呆）",
		StickerTheme.label_color(-1) == StickerTheme.LABEL_ROLE_COLORS[0]
			and StickerTheme.label_color(99) == StickerTheme.LABEL_ROLE_COLORS[6])
	var ok := true
	for r in range(7):
		if StickerTheme.label_color(r) != StickerTheme.LABEL_ROLE_COLORS[r]:
			ok = false
	_check("① 角色取色：label_color(r) 逐位等于表值（7 角色遍历）", ok)


# ── ② 语义色保全 ──────────────────────────────────────────────────
func _test_semantic_preservation() -> void:
	print("── ② 语义色保全（互异 + 明度序 + 保真 + 自由色清除） ──")
	var cols: Array[Color] = StickerTheme.LABEL_ROLE_COLORS
	# a. 两两互异（21 对）
	var distinct := true
	var dup := ""
	for i in range(cols.size()):
		for j in range(i + 1, cols.size()):
			if cols[i] == cols[j]:
				distinct = false
				dup = "角色 %d == 角色 %d" % [i, j]
	_check("②a 语义角色 7 色两两互异（品质金/警示红/我方蓝不被量化抹平的结构前提）",
		distinct, dup)
	# b. 明度序严格递增（墨 < 警示红 < 我方蓝 < 灰蓝 < 紫 < 金 < 白）
	var order := [0, 5, 3, 1, 4, 2, 6]               # INK, ENEMY, PLAYER, SOFT, SHOCK, GOLD, WHITE
	var mono := true
	var mono_bad := ""
	for k in range(order.size() - 1):
		var lo := _lum(cols[order[k]])
		var hi := _lum(cols[order[k + 1]])
		if lo >= hi:
			mono = false
			mono_bad = "角色 %d（%.4f）≥ 角色 %d（%.4f）" % [order[k], lo, order[k + 1], hi]
	_check("②b 明度序保持：INK<ENEMY<PLAYER<SOFT<SHOCK<GOLD<WHITE 严格递增（Rec.709）",
		mono, mono_bad)
	# c. 保真子集：六值与 PopPalette 单源逐位相等（原色零改动）
	var preserved := cols[0] == PopPalette.INK and cols[1] == PopPalette.INK_SOFT \
		and cols[2] == PopPalette.GOLD and cols[3] == PopPalette.PLAYER \
		and cols[5] == PopPalette.ENEMY and cols[6] == Color.WHITE
	_check("②c 保真子集：正文墨/弱化灰蓝/品质金/我方蓝/警示红/暗底白 == PopPalette 单源值",
		preserved)
	_check("②c 附：品质金 GOLD==XP 同值（金币 Label 收敛入口值逐位不变）",
		PopPalette.GOLD == PopPalette.XP)
	# d. 自由色清除：两处 lerp 自由色不在色板 + 落点角色色相族保持
	var lerp_blue := PopPalette.PLAYER.lerp(Color.WHITE, 0.62)     # 旧镜面 toast 冰青
	var lerp_purple := PopPalette.SHOCK.lerp(Color.WHITE, 0.25)    # 旧 R187 读数浅紫
	var gone := not _in_palette(lerp_blue) and not _in_palette(lerp_purple)
	_check("②d 保留复核：冰青/浅紫两处 lerp 值不在量化色板（保留原值，未混入单源）", gone)
	var hue_ok := (lerp_blue.b > lerp_blue.r and lerp_blue.b > lerp_blue.g
		and cols[3].b > cols[3].r and cols[3].b > cols[3].g)
	var purple_ok := (lerp_purple.r > lerp_purple.g and lerp_purple.b > lerp_purple.g
		and cols[4].r > cols[4].g and cols[4].b > cols[4].g)
	_check("②d 色相保全：蓝族落点 PLAYER 仍蓝主（b 通道最大）", hue_ok,
		"lerp=%s player=%s" % [str(lerp_blue), str(cols[3])])
	_check("②d 色相保全：紫族落点 SHOCK 仍紫族（r/b 双高于 g）", purple_ok,
		"lerp=%s shock=%s" % [str(lerp_purple), str(cols[4])])


# ── ③ grep 零残留直配 ─────────────────────────────────────────────
func _test_source_no_direct_coloring() -> void:
	print("── ③ hud.gd 源级零残留直配 ──")
	var src := _read_src(HUD_SRC)
	_check("③ 前置：hud.gd 可读", src != "")
	if src == "":
		return
	var lines := src.split("\n")
	var label_news := _lines_with(lines, "Label.new()")
	_check("③ Label.new 恰 30 处（刀面全覆盖口径；R241 +SkillAutoCast）", label_news.size() == 30,
		"count=%d" % label_news.size())
	var lc_calls := _lines_with(lines, "label_color(StickerTheme.LabelRole")
	var lc_total := 0
	for i in lc_calls:
		lc_total += lines[i].count("label_color(StickerTheme.LabelRole")
	_check("③ label_color 调用恰 36 处（28 sticker 站点 + 4 动态写点各 2 角色；镜面/R187 两站保留 lerp 原色；R241 +自动施放站）",
		lc_total == 36, "count=%d" % lc_total)
	# 每处 label_sticker 调用（含跨行 2 行窗）都经 label_color 或命中保留白名单
	# （R230 主控复核：镜面 toast 冰青 / R187 读数浅紫两站保留原 lerp——F9 门禁证伪
	#  「逐件独立配色」前提后收回收敛，见 hud.gd:647 注释）
	var kept_lerp := ["PopPalette.PLAYER.lerp(Color.WHITE, 0.62)",
		"PopPalette.SHOCK.lerp(Color.WHITE, 0.25)"]
	var sticker_lines := _lines_with(lines, "label_sticker(")
	var sticker_ok := true
	var sticker_bad := ""
	for i in sticker_lines:
		var routed := _window_has(lines, i, 2, "label_color(")
		for k in kept_lerp:
			routed = routed or _window_has(lines, i, 2, k)
		if not routed:
			sticker_ok = false
			sticker_bad = "行 %d：%s" % [i + 1, str(lines[i]).strip_edges()]
	_check("③ 30 处 label_sticker：28 走 label_color + 2 保留 lerp 原色（复核白名单；R241 +1 站）",
		sticker_ok and sticker_lines.size() == 30, sticker_bad)
	# 每处 font_color override（跨行 2 行窗）都经 label_color
	var override_lines := _lines_with(lines, "add_theme_color_override(\"font_color\"")
	var override_ok := true
	var override_bad := ""
	for i in override_lines:
		if not _window_has(lines, i, 2, "label_color("):
			override_ok = false
			override_bad = "行 %d：%s" % [i + 1, str(lines[i]).strip_edges()]
	_check("③ 4 处动态 font_color override 全走 label_color（金/墨↔灰蓝/金↔红/金↔灰角色切换；R241 +自动施放）",
		override_ok and override_lines.size() == 4, override_bad)
	# lerp 自由色在 Label 配色上下文仅存白名单 2 处（其余站点窗口内不得出现 lerp(；
	# 面板 StyleBox 配色不在 K4 刀面——_shield_fill_style.bg_color 等非 Label 路径不收敛）
	var lerp_in_label := false
	var lerp_bad := ""
	var lerp_kept := 0
	for i: int in sticker_lines + override_lines:
		if _window_has(lines, i, 2, ".lerp("):
			var kept := false
			for k in kept_lerp:
				kept = kept or _window_has(lines, i, 2, k)
			if not kept:
				lerp_in_label = true
				lerp_bad = "行 %d" % str(i + 1).to_int()
			else:
				lerp_kept += 1
	_check("③ lerp 仅存白名单 2 处（镜面冰青/R187 浅紫按 R230 复核保留原值）",
		not lerp_in_label and lerp_kept == 2, "%s kept=%d" % [lerp_bad, lerp_kept])
	# theme.gd 机制块在位
	var tsrc := _read_src(THEME_SRC)
	_check("③ theme.gd 色板机制块在位（LABEL_ROLE_COLORS + label_color 单源口）",
		tsrc.contains("const LABEL_ROLE_COLORS: Array[Color]")
			and tsrc.contains("static func label_color(")
			and tsrc.contains("enum LabelRole"))


# ── ④ 运行时行为（真 HUD 实例） ───────────────────────────────────
func _role_color(p_role: int) -> Color:
	return StickerTheme.LABEL_ROLE_COLORS[p_role]


func _preserved_color(p_c: Color) -> bool:
	# R230 复核保留的两处 lerp 原色（hud.gd 镜面 toast / R187 读数——见 ③ 白名单）
	return p_c.is_equal_approx(PopPalette.PLAYER.lerp(Color.WHITE, 0.62)) \
		or p_c.is_equal_approx(PopPalette.SHOCK.lerp(Color.WHITE, 0.25))


func _assert_labels_in_palette(p_label: String) -> void:
	var labels: Array = []
	_walk_labels(_hud, labels)
	var bad: Array[String] = []
	for l in labels:
		if not (l as Label).has_theme_color_override("font_color"):
			continue                              # 无 override 的 Label（非贴纸装配）不入断言面
		var c := (l as Label).get_theme_color("font_color")
		if not _in_palette(c) and not _preserved_color(c):
			bad.append("%s=%s" % [l.name, str(c)])
	_check("④ %s：全树 %d 枚 Label font_color override ∈ 色板∪2 保留 lerp 色（漏网直配=%d）"
		% [p_label, labels.size(), bad.size()], bad.is_empty(), str(bad))


func _label_color_of(p_node_name: String) -> Color:
	var labels: Array = []
	_walk_labels(_hud, labels)
	for l in labels:
		if (l as Label).name == p_node_name:
			return (l as Label).get_theme_color("font_color")
	return Color(-1.0, -1.0, -1.0)


func _test_runtime_hud_labels() -> void:
	print("── ④ 运行时真 HUD 配色面 ──")
	_hud = HUD.new()
	_hud.name = "R230K4HudUnderTest"
	tree.root.add_child(_hud)                     # _ready → _build_ui（配色装配面）
	_assert_labels_in_palette("静态构建态")
	# 语义钉：警示红/正文墨/品质金/暗底白/柔电紫（R31/R38/R200 敏感面保真运行时证）
	_check("④ 语义钉：Boss 横幅==警示红（警示色硬保全）",
		_label_color_of("BossBanner") == PopPalette.ENEMY)
	_check("④ 语义钉：HP 文本==正文墨（正文硬保全）",
		_label_color_of("HpText") == PopPalette.INK)
	_check("④ 语义钉：复活徽标==品质金（品质色硬保全；==XP 同值，金币 Label 同角色）",
		_label_color_of("ReviveBadge") == PopPalette.GOLD)
	_check("④ 语义钉：悬停说明卡==暗底白（WHITE 角色；无显式名——私有成员直读）",
		_hud._hover_label != null
			and _hud._hover_label.get_theme_color("font_color") == Color.WHITE)
	_check("④ 语义钉：R187 读数==浅紫 lerp 原色（R230 复核保留，非色板收敛）",
		_label_color_of("R187Readout") == PopPalette.SHOCK.lerp(Color.WHITE, 0.25))
	# 动态切换 A：AUTO 开关 墨↔灰蓝（两端∈色板）
	Meta.set_setting("auto_select_on", true)
	_hud._sync_auto_visual()
	var on_col := _label_color_of("AutoToggleText")
	Meta.set_setting("auto_select_on", false)
	_hud._sync_auto_visual()
	var off_col := _label_color_of("AutoToggleText")
	_check("④ 动态切换：AUTO 开=正文墨 / 关=弱化灰蓝（互异且均∈色板）",
		on_col == _role_color(StickerTheme.LabelRole.INK)
			and off_col == _role_color(StickerTheme.LabelRole.SOFT),
		"on=%s off=%s" % [str(on_col), str(off_col)])
	# 动态切换 B：复活横幅 金↔警示红（两端∈色板）
	_hud._on_revive_burst(Vector2.ZERO, 2)
	var gold_col := _label_color_of("ReviveBanner")
	_hud._on_revive_burst(Vector2.ZERO, 0)
	var warn_col := _label_color_of("ReviveBanner")
	_check("④ 动态切换：复活横幅 有量=品质金 / 耗尽=警示红（互异且均∈色板）",
		gold_col == _role_color(StickerTheme.LabelRole.GOLD)
			and warn_col == _role_color(StickerTheme.LabelRole.ENEMY),
		"gold=%s warn=%s" % [str(gold_col), str(warn_col)])
	# 四类临时 toast：落点角色正确（镜面=蓝 / 里程碑=金 / 刷新=蓝 / 成就=金）
	_hud._on_mirror_formed_toast("镜面承接了测试")
	_hud._on_trait_milestone_toast(&"r230_test", "测试词条", 1.6)
	_hud._on_reroll_toast(1)
	_hud._ach_toast_pending.append(&"r230_test_ach")
	_hud._flush_achievement_toast()
	_assert_labels_in_palette("临时 toast 态")

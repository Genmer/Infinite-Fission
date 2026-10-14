extends RefCounted
# R260 QA 专项② cases（配套口 qa_r260_qa_rows.gd）——祝福行缓存边角。
# 夹具口径：不预设具体 id（数据侧 rarity 归属会漂——AFF_CRIT_RATE 实为 rarity=0
# 曾致误判），按 _blessing_pool 同款过滤动态挑 2 个 tier-1 词条解锁；池断言全部
# 基于快照（对本地档既有解锁鲁棒）。收口用 close()（零信号零 Meta 记忆写）。
# R262 差异：_blessing_pool 新增第五条件（首发适配门）——夹具候选须另行过门
#（_blessing_fits_start_weapon），否则净档下过门蓝档前二 [AFF_AREA, AFF_CDR] 中的
# AFF_CDR（required_forms=[1,2,3]）被门滤出 → pool_a=1 项 → R1 FAIL+R5 pool_a[1]
# 越界空引用崩套件；净档过门蓝档 17 条前二=[AFF_AREA, AFF_CRIT_DMG]。

var _pass := 0
var _fail := 0
var _failures: Array[String] = []
var _fixtures: Array[StringName] = []               # 本套件解锁的夹具（收尾精确还原）


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  ok | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("  FAIL | %s %s" % [p_name, p_detail])


func _tier1_candidates(gl) -> Array[StringName]:
	# 与 game_loop._blessing_pool(1) 同款过滤（tier=1 / 非阈值 / 无前置）。
	# R262 差异披露：真池另有第五条件（首发适配门 _blessing_fits_start_weapon——
	# required_weapon/required_forms/required_class/excluded_weapons/
	# requires_projectile/requires_weapon_keys 六键静态判定）本函数不查——候选域
	# 比真池蓝档多 9 条（AFF_CDR/AFF_RANGE/MEC_BULLET_PARRY 等 forms/class 门项）；
	# 夹具选择须在 run() 内补过门（否则净档 pool_a=1 项致 R1/R5 红）。
	var out: Array[StringName] = []
	var keys: Array[String] = []
	for tid_v: Variant in gl.registry.traits.keys():
		keys.append(String(tid_v))
	keys.sort()
	for key: String in keys:
		var tid := StringName(key)
		var td: TraitData = gl.registry.get_trait(tid)
		if td == null or int(td.rarity) != 1:
			continue
		if bool(td.params.get("threshold_only", false)):
			continue
		if String(td.params.get("requires_trait", "")) != "":
			continue
		out.append(tid)
	return out


func _row_ids(bles) -> Array[String]:
	var out: Array[String] = []
	for c in bles._list_box.get_children():
		out.append(String((c as Button).get_meta(&"trait_id")))
	return out


func _group_none_pressed(bles) -> bool:
	# 组内无任何按下态（遍历实体钮——规避 freed 实例 ==null 判等陷阱）
	for b_v: Variant in bles._btn_group.get_buttons():
		if (b_v as Button).button_pressed:
			return false
	return true


func run(p_tree: SceneTree) -> void:
	var gl_script: GDScript = load("res://scripts/loop/game_loop.gd")
	var gl = gl_script.new()
	gl.name = "GameLoopForR260QARows"
	p_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	var waited := 0
	while not gl.boot_ready and waited < 600:
		await p_tree.process_frame
		waited += 1
	var menu = gl.menu_screen
	var bles = gl.blessing_pick_ui
	_check("R0 boot 就绪", menu != null and gl.boot_ready and bles != null)

	# ── R1 池序确定性：两次 _blessing_pool 同档调用逐位相等 + id 字典序 ──
	# 夹具：优先挑「未解锁」的 tier-1 候选两个（解锁后池≥2；对本地档鲁棒）
	# R262：候选先过首发适配门（与真池第五条件同口径——净档过门蓝档 17 条，
	# 前二=[AFF_AREA, AFF_CRIT_DMG]，pool_a≥2 恢复）
	var swid: StringName = gl._starting_weapon_id(Meta.character_id)
	var swd: WeaponData = gl.registry.get_weapon(swid)
	var sform := int(swd.form) if swd != null else -1
	var sclass := "melee"
	if swd != null and swd.melee is Dictionary:
		sclass = String((swd.melee as Dictionary).get("weapon_class", "melee"))
	var cands: Array[StringName] = []
	for tid_raw: StringName in _tier1_candidates(gl):
		var td_c: TraitData = gl.registry.get_trait(tid_raw)
		if td_c != null and gl._blessing_fits_start_weapon(td_c, swd, sform, sclass):
			cands.append(tid_raw)
	for tid: StringName in cands:
		if _fixtures.size() >= 2:
			break
		if not Meta.is_trait_unlocked(tid):
			_fixtures.append(tid)
	for tid: StringName in cands:                    # 兜底：全解锁时用已解锁候选补足
		if _fixtures.size() >= 2:
			break
		if not _fixtures.has(tid):
			_fixtures.append(tid)
	for tid: StringName in _fixtures:
		Meta.codex_traits[String(tid)] = true
	var pool_a: Array[StringName] = gl._blessing_pool(1)
	var pool_b: Array[StringName] = gl._blessing_pool(1)
	var keys: Array[String] = []
	for t in pool_a:
		keys.append(String(t))
	var keys_sorted: Array[String] = keys.duplicate()
	keys_sorted.sort()
	_check("R1 池序确定：两次调用相等（%d 项，夹具 %s）且 id 字典序" % [pool_a.size(),
			str(_fixtures.map(func(t: StringName) -> String: return String(t)))],
		pool_a.size() >= 2 and pool_a == pool_b and keys == keys_sorted)

	# ── R2 首开建行（R261 分页口径：当页行数=mini(7,池)/行序=当页子序列/组钮数=当页行数） ──
	bles.open(pool_a, "", 0)
	var ids0: Array[String] = _row_ids(bles)
	var pool_str: Array[String] = []
	for t in pool_a:
		pool_str.append(String(t))
	var page_n := mini(7, pool_a.size())
	var page_expect: Array[String] = []
	for k in page_n:
		page_expect.append(pool_str[k])
	_check("R2 首开建行：当页行数=%d 行序随池 组钮数=%d" % [bles._list_box.get_child_count(),
			bles._btn_group.get_buttons().size()],
		ids0 == page_expect and bles._list_box.get_child_count() == page_n
		and bles._btn_group.get_buttons().size() == page_n)

	# ── R3 同池同档重开：零重建（同行实例）+ 组钮数稳定 + 无选中 ──
	var row_first_a: Node = bles._list_box.get_child(0)
	var row_last_a: Node = bles._list_box.get_child(bles._list_box.get_child_count() - 1)
	bles.close()
	bles.open(pool_a, "", 0)
	var row_first_b: Node = bles._list_box.get_child(0)
	var row_last_b: Node = bles._list_box.get_child(bles._list_box.get_child_count() - 1)
	_check("R3 同池同档重开=同行实例零重建+选中全清",
		row_first_b == row_first_a and row_last_b == row_last_a
			and bles._btn_group.get_buttons().size() == mini(7, pool_a.size())
			and bles.selected_id() == "" and _group_none_pressed(bles))

	# ── R4 复用路径预选重施加：带记忆重开=选中态恢复 ──
	bles.close()
	bles.open(pool_a, String(pool_a[0]), 0)
	var pressed_btn = bles._btn_group.get_pressed_button()
	var pressed_meta: String = String(pressed_btn.get_meta(&"trait_id")) if pressed_btn != null else ""
	_check("R4 复用路径预选：selected=%s 按下行=%s" % [bles.selected_id(), pressed_meta],
		bles.selected_id() == String(pool_a[0]) and pressed_meta == String(pool_a[0]))

	# ── R5 手动选中→无记忆重开=全清（toggled 链+复用清位） ──
	bles.close()
	bles.open(pool_a, "", 0)
	var btn2: Button = bles._row_by_id(String(pool_a[1]))
	btn2.button_pressed = true                       # toggled 链：_selected_id 随动
	var manual_sel: String = bles.selected_id()
	bles.close()
	bles.open(pool_a, "", 0)
	_check("R5 手动选中后无记忆重开=选中清空",
		manual_sel == String(pool_a[1]) and bles.selected_id() == "" and _group_none_pressed(bles))

	# ── R6 同池不同序：签名含序=重建（行随新序）+旧行释放 ──
	var pool_rev: Array[StringName] = pool_a.duplicate()
	pool_rev.reverse()
	var old_first: Node = bles._list_box.get_child(0)
	bles.close()
	bles.open(pool_rev, "", 0)
	var new_first: Node = bles._list_box.get_child(0)
	var ids_rev: Array[String] = _row_ids(bles)
	var pool_rev_str: Array[String] = []
	for t in pool_rev:
		pool_rev_str.append(String(t))
	_check("R6 同池不同序=重建+行随新序+旧行释放",
		new_first != old_first and not is_instance_valid(old_first)
			and ids_rev == pool_rev_str.slice(0, mini(7, pool_rev_str.size())),   # R261 分页口径：当页子序列
		"row0_new=%s old_valid=%s" % [str(new_first != old_first), str(is_instance_valid(old_first))])

	# ── R7 池扩（图鉴解锁新词条）：重建+新行数+ButtonGroup 无残留（freed 不滞留组） ──
	# R262 披露：候选域仍蓝档（已过 _blessing_fits_start_weapon），选择条件=「pool_a
	# 外且过门」——全解锁档下「pool_a 外且过门的蓝档候选」恒为空集（26 蓝档=池内
	# 17+门外 9 全被门滤）→ R7 恒走 skip 臂，池扩断言覆盖率归零；由 qa_r262 T1 全池
	# 断言补覆盖（不扩域改全池口径——避免牵动下方行数断言与 pool_a 的关系）。
	var extra_id: StringName = &""
	for tid: StringName in cands:
		if not pool_a.has(tid):
			extra_id = tid
			break
	if extra_id != &"":
		Meta.codex_traits[String(extra_id)] = true
		var pool_grow: Array[StringName] = gl._blessing_pool(1)
		bles.close()
		bles.open(pool_grow, "", 0)
		var group_all_valid := true
		for b_v: Variant in bles._btn_group.get_buttons():
			if not is_instance_valid(b_v as Object):
				group_all_valid = false
		# R261 分页口径：行数/组钮数=当页容量 mini(7,池)（池 ≤7 时退化为全池=原口径）
		var page_n7 := mini(7, pool_grow.size())
		_check("R7 池扩（+%s）=重建+当页行数=%d+组钮数=当页（freed 旧钮不滞留组）" % [String(extra_id),
				bles._list_box.get_child_count()],
			pool_grow.has(extra_id) and pool_grow.size() == pool_a.size() + 1
			and bles._list_box.get_child_count() == page_n7
			and bles._btn_group.get_buttons().size() == page_n7 and group_all_valid)
		Meta.codex_traits.erase(String(extra_id))
	else:
		print("  skip | R7 池扩：tier-1 候选已全在池，无可追加词条（跳过）")

	# ── R8 档变（难度 0→2）：重建+顶带/标题随档+行按下色随「行自身品级」（R262）+副题难度名 ──
	# R262：行按下色真源改行自身 rarity（pool_a 全 r1 → 期望 rarity_color(1)——
	# 不随面板档变金）；band/title 档色真源仍=面板档（_tier=3 金）零迁移。
	var tier3_expect: Color = PopPalette.rarity_color(3)
	var row_r1_expect: Color = PopPalette.rarity_color(1)
	var row_t1: Node = bles._list_box.get_child(0)
	bles.close()
	bles.open(pool_a, "", 2)                          # 同池不同档——签名含档=重建
	var row_t3: Node = bles._list_box.get_child(0)
	var band_ok: bool = bles._band.color.is_equal_approx(tier3_expect)
	var title_ok: bool = (bles._title.get_theme_color("font_color")).is_equal_approx(tier3_expect)
	var press_ok: bool = ((row_t3 as Button).get_theme_color("font_pressed_color")).is_equal_approx(row_r1_expect)
	var sub_ok: bool = String(bles._subtitle.text).find(GameConst.difficulty_name(2)) >= 0
	_check("R8 档变=重建+band/title 随档+行按下色随行自身品级（R262）+副题难度名",
		row_t3 != row_t1 and not is_instance_valid(row_t1)
		and band_ok and title_ok and press_ok and sub_ok,
		"rebuild=%s band=%s title=%s press=%s sub=%s" % [str(row_t3 != row_t1
				and not is_instance_valid(row_t1)), str(band_ok), str(title_ok), str(press_ok), str(sub_ok)])

	# ── R9 重建前有按下行：池缩重建后组内无残留按下（freed 钮不滞留组按下态） ──
	var btn_press: Button = bles._row_by_id(String(pool_a[0]))
	btn_press.button_pressed = true
	var pool_shrink: Array[StringName] = [StringName(String(pool_a[0]))]
	bles.close()
	bles.open(pool_shrink, "", 0)
	_check("R9 池缩重建=组按下态清（freed 行不滞留）+行数随池",
		_group_none_pressed(bles) and bles._list_box.get_child_count() == 1
		and bles._btn_group.get_buttons().size() == 1)
	bles.close()

	# 夹具还原（只清本套件解锁的键——不清本地档既有解锁）
	for tid: StringName in _fixtures:
		Meta.codex_traits.erase(String(tid))
	Meta._save()
	gl.free()
	print("专项②汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	for f in _failures:
		print("  FAIL | %s" % f)


func fail_count() -> int:
	return _fail

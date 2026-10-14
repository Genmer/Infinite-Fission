# R262b 修复批验收用例体（qa_r262c_fixes 入口 load）
extends RefCounted

var _tree: SceneTree = null
var _fails: int = 0
var _passes: int = 0

const GL_SRC := "res://scripts/loop/game_loop.gd"
const ENEMY_SRC := "res://scripts/entities/enemy/enemy.gd"
const ORBIT_SRC := "res://scripts/combat/weapon/melee/orbit_field.gd"
const MENU_SRC := "res://scripts/ui/menu_screen.gd"
const DBGSRC := "res://autoload/debug_stats.gd"
const CLOUD_SRC := "res://scripts/ui/cloud_backdrop.gd"
const KNOCK_TRES := "res://resources/traits/MEC_KNOCK.tres"


func _check(p_name: String, p_ok: bool, p_detail: String = "") -> void:
	if p_ok:
		_passes += 1
		print("PASS | " + p_name)
	else:
		_fails += 1
		print("FAIL | " + p_name + ("" if p_detail.is_empty() else "  [got: " + p_detail + "]"))


func run_all(p_tree: SceneTree) -> int:
	_tree = p_tree
	_test_quantize_anchors()
	_test_panel_gen_cache()
	_test_save_rarity_roundtrip()
	_test_static_anchors()
	_test_validator_no_handler_ef()
	_test_codex_th_filter()
	print("R262c 汇总：PASS %d / FAIL %d（共 %d 项）" % [_passes, _fails, _passes + _fails])
	return _fails


# ── H1/M6：敌状态件族与 orbit_field 量化收口（写点全过 ElementalFxLayer._qa） ──
func _test_quantize_anchors() -> void:
	print("── H1/M6 量化收口 ──")
	var e_src := FileAccess.get_file_as_string(ENEMY_SRC)
	var e_n: int = e_src.count("_qa_a(")
	_check("H1 enemy 状态件族 α 写点过量化的本地 _qa_a（火苗/冰环/精英珠 count==4=定义+3 写点）",
		e_n == 4, "count=%d" % e_n)
	var o_src := FileAccess.get_file_as_string(ORBIT_SRC)
	var o_n: int = o_src.count("ElementalFxLayer._qa(")
	_check("M6 orbit_field 辉光/闪环 α 写点过 _qa（count==2）", o_n == 2, "count=%d" % o_n)
	_check("H1 火苗色相插值 3 档量化（源码锚 roundi(cyc * 0.7 * 3.0)）",
		e_src.count("roundi(cyc * 0.7 * 3.0)") == 1)
	var ok_q := true
	for i in range(20):
		var a := 0.45 + 0.4 * sin(float(i) * 2.1)
		var q: float = ElementalFxLayer._qa(a)
		if not is_equal_approx(q * 4.0, float(roundi(q * 4.0))):
			ok_q = false
			break
	_check("H1 _qa 输出恒 0.25 步进档（20 样本）", ok_q)


# ── M3：aggregate_panel 世代缓存（命中同值/写面失效重算） ─────────────────
func _mk_gl(p_name: String):
	var gl = GameLoop.new()
	gl.name = p_name
	_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	return gl


func _test_panel_gen_cache() -> void:
	print("── M3 面板聚合世代缓存 ──")
	var gl = _mk_gl("R262cM3")
	var stack: TraitStack = gl.player.weapon_slots[0].trait_stack
	var tdata: TraitData = gl.registry.get_trait(&"AFF_ATK_UP")
	var t0: TraitData = tdata.duplicate()
	t0.value = 0.10
	var t1: TraitData = tdata.duplicate()
	t1.value = 0.25
	t1.rarity = 3
	stack.attach(t0)
	stack.attach(t1)
	var gen0: int = int(stack.runtime_generation)
	var sum_a: Dictionary = stack.aggregate_panel()
	var sum_b: Dictionary = stack.aggregate_panel()
	var base_val: float = float(sum_a.get(tdata.pool_id, -1.0))
	_check("M3 混合品级逐层全额（0.10+0.25=0.35）",
		sum_a.size() > 0 and is_equal_approx(base_val, 0.35),
		"v=%s" % str(base_val))
	_check("M3 同代两次聚合逐值一致（缓存命中口径）", sum_a == sum_b)
	stack.attach(t0)
	var gen1: int = int(stack.runtime_generation)
	var sum_c: Dictionary = stack.aggregate_panel()
	_check("M3 attach（ADD append 不 bump 世代）→面板缓存直失重算（0.45）",
		is_equal_approx(float(sum_c.get(tdata.pool_id, -1.0)), 0.45),
		"gen %d→%d v=%s" % [gen0, gen1, str(sum_c.get(tdata.pool_id, -1.0))])
	gl.free()


# ── M1+S2：存档快照补品级（lv/lr/dv/dr）+ 恢复逐位一致 + 质变重触发 ─────────
func _test_save_rarity_roundtrip() -> void:
	print("── M1 存档品级往返（+S2 质变重触发） ──")
	var gl = _mk_gl("R262cM1")
	var weapon = gl.player.weapon_slots[0]
	# 里程碑大关门（第 4 关起）查询 Meta.run_map_id——boot 默认首图 idx=0 门关；
	# 置空=无局全开口径（MechanicGate.map_index 注释），质变可触发
	Meta.set_run_map(&"")
	# MECH 挂载走消费端 attach_trait（MECH 无满层质变——vm 恒 1，S2 质变对象是 ADD 池）
	var shield_base: TraitData = gl.registry.get_trait(&"MEC_SHIELD")
	var shield_white: TraitData = shield_base.duplicate()
	var shield_gold: TraitData = shield_base.duplicate()
	shield_gold.value = shield_base.value * 2.6        # 金档 scale（RARITY_VALUE_SCALE[3]）
	shield_gold.rarity = 3
	var ok1: bool = bool(weapon.call("attach_trait", shield_white))
	var ok2: bool = bool(weapon.call("attach_trait", shield_gold))
	_check("M1 前置：双护盾挂载回执（白+金）", ok1 and ok2)
	var stack: TraitStack = weapon.trait_stack
	# ADD 逐层品级走消费端三层（第 3 层=stack_max 达满触发质变 ×1.6，S2 断言对象）
	var aff: TraitData = gl.registry.get_trait(&"AFF_ATK_UP")
	var aff_w: TraitData = aff.duplicate()
	aff_w.value = 0.10
	var aff_g: TraitData = aff.duplicate()
	aff_g.value = 0.25
	aff_g.rarity = 3
	var ok3: bool = bool(weapon.call("attach_trait", aff_w))
	var ok4: bool = bool(weapon.call("attach_trait", aff_g))
	var ok5: bool = bool(weapon.call("attach_trait", aff_w.duplicate()))
	_check("M1 前置：AFF 三层挂载回执（白+金+白）", ok3 and ok4 and ok5)
	var aff_mounted = null
	var shield_mounted = null
	for m_v: Variant in stack.traits:
		if String(m_v.data.id) == "MEC_SHIELD":
			shield_mounted = m_v
		elif String(m_v.data.id) == "AFF_ATK_UP":
			aff_mounted = m_v
	var vm_before: float = float(aff_mounted.value_mult)
	_check("M1 前置：ADD 满层质变 value_mult 触发（stack_max=3×1.6）",
		is_equal_approx(vm_before, 1.6), "vm=%s" % str(vm_before))
	var data: Dictionary = gl.call("serialize_run")
	var weapons_arr: Array = data.get("weapons", [])
	var traits_arr: Array = (weapons_arr[0] as Dictionary).get("traits", [])
	var e_shield: Dictionary = {}
	var e_aff: Dictionary = {}
	for t_v: Variant in traits_arr:
		var te: Dictionary = t_v
		if String(te.get("id", "")) == "MEC_SHIELD":
			e_shield = te
		elif String(te.get("id", "")) == "AFF_ATK_UP":
			e_aff = te
	_check("M1 快照四键齐（lv/lr/dv/dr 两词条皆落）",
		not e_shield.is_empty() and not e_aff.is_empty()
		and e_shield.has("dv") and e_shield.has("dr")
		and e_aff.has("lv") and e_aff.has("lr"),
		"shield=%s aff=%s" % [str(e_shield.keys()), str(e_aff.keys())])
	_check("M1 MECH 快照 dv=金值 dr=金（取优定义真源）",
		is_equal_approx(float(e_shield.get("dv", 0.0)), shield_gold.value)
		and int(e_shield.get("dr", -1)) == 3,
		"dv=%s" % str(e_shield.get("dv")))
	_check("M1 ADD 快照 lv=[0.10,0.25,0.10] lr=[0,3,0]",
		(e_aff.get("lv", []) as Array) == ([0.10, 0.25, 0.10] as Array)
		and (e_aff.get("lr", []) as Array) == ([0, 3, 0] as Array),
		"lv=%s lr=%s" % [str(e_aff.get("lv")), str(e_aff.get("lr"))])
	# 恢复：_restore_run_state 自清槽重建（queue_free 旧+add_weapon 新）
	gl.call("_restore_run_state", data)
	var new_stack: TraitStack = gl.player.weapon_slots[0].trait_stack
	var rs = null
	var ra = null
	for m_v: Variant in new_stack.traits:
		if String(m_v.data.id) == "MEC_SHIELD":
			rs = m_v
		elif String(m_v.data.id) == "AFF_ATK_UP":
			ra = m_v
	_check("M1+S2 恢复：MEC_SHIELD dv 回放（金档定义选中）",
		rs != null and is_equal_approx(float(rs.data.value), shield_gold.value),
		"dv=%s" % (str(rs.data.value) if rs != null else "null"))
	_check("M1+S2 恢复：ADD 质变 value_mult 重触发（=MILESTONE 1.6）",
		ra != null and is_equal_approx(float(ra.value_mult), 1.6),
		"vm=%s" % (str(ra.value_mult) if ra != null else "null"))
	_check("M1 恢复：ADD 逐层 lv/lr 与存档逐位一致",
		ra != null and (ra.layer_values as Array) == ([0.10, 0.25, 0.10] as Array)
		and (ra.layer_rarities as Array) == ([0, 3, 0] as Array),
		"lv=%s" % (str(ra.layer_values) if ra != null else "null"))
	gl.free()
	RunSave.clear()


# ── 源码锚组：M2/M4/M5/L1/L3/L5/L13/L17 ─────────────────────────────────
func _test_static_anchors() -> void:
	print("── 源码锚组 ──")
	var menu_src := FileAccess.get_file_as_string(MENU_SRC)
	_check("M2 图鉴泵还账（skip 帧成员+skip_frames_for 消费）",
		menu_src.count("_codex_pump_skip_frames") >= 3
		and menu_src.count("CardDescPrewarm.skip_frames_for(frame_us, 4000)") == 1)
	var dbg := FileAccess.get_file_as_string(DBGSRC)
	var seg0: int = dbg.find("func _process(")
	var seg1: int = dbg.find("R205：真机诊断日志")
	_check("M4 _process 不再调 frame_report（诊断税移除——调用条件行已删）",
		seg0 >= 0 and seg1 > seg0
		and dbg.substr(seg0, seg1 - seg0).count("FRAME_REPORT_INTERVAL ==") == 0
		and dbg.substr(seg0, seg1 - seg0).count("R262b M4") == 1)
	var cloud := FileAccess.get_file_as_string(CLOUD_SRC)
	_check("M5 CloudBackdrop PAUSABLE 门（暂停期停漂移）",
		cloud.count("PROCESS_MODE_PAUSABLE") == 1)
	var gl_src := FileAccess.get_file_as_string(GL_SRC)
	_check("L1 连杀跳字旧 tween kill（_combo_tween 引用+kill）",
		gl_src.count("_combo_tween.kill()") == 1 and gl_src.count("var _combo_tween: Tween") == 1)
	_check("L3 boss_summons 键缓冲（免每帧 keys()）",
		gl_src.count("for key in _boss_summons.keys()") == 0
		and gl_src.count("_boss_summon_keys") >= 3)
	_check("L5 tex 泵门换 codex 谓词（图鉴面板豁免）",
		gl_src.count("not menu_screen.codex_pump_paused()") == 1)
	var knock := FileAccess.get_file_as_string(KNOCK_TRES)
	_check("L13 MEC_KNOCK 文案去「子弹」（近战落点披露）",
		knock.count("子弹击退力") == 0 and knock.count("击退力 +60") == 1)
	var relic_src := FileAccess.get_file_as_string("res://scripts/loop/relic_handler.gd")
	var card_src := FileAccess.get_file_as_string("res://scripts/cards/card_generator.gd")
	_check("L17 回响/诅咒失败出声（横幅+计数）",
		relic_src.count("relic_echo_rejected") == 1
		and card_src.count("curse_attach_rejected") == 1)


# ── L11+L16：validator 无处理器 EF 拦截+域文案 ───────────────────────────
func _test_validator_no_handler_ef() -> void:
	print("── L11/L16 validator ──")
	var v = load("res://scripts/core/data/data_validator.gd").new()
	var bad: TraitData = TraitData.new()
	bad.id = &"T_BAD_EF"
	bad.display_name = "坏卡"
	bad.effect_id = &"EF_CHOIR"                        # 无处理器 EF
	bad.pool = GameConst.PoolClass.MECH
	bad.params = {"threshold_only": false}
	var errs: Array = v.call("validate_trait", bad)
	var hit := false
	for e_v: Variant in errs:
		var msg: String = String((e_v as Dictionary).get("message", ""))
		if msg.count("无内置处理器") > 0:
			hit = true
	_check("L11 无处理器 EF×非阈值=启动期拦截", hit, "errs=%s" % str(errs))
	bad.params = {"threshold_only": true}
	var errs2: Array = v.call("validate_trait", bad)
	var hit2 := true
	for e_v: Variant in errs2:
		var msg2: String = String((e_v as Dictionary).get("message", ""))
		if msg2.count("无内置处理器") > 0:
			hit2 = false
	_check("L11 threshold_only 词条声明六 EF 放行（TH_* 零行为变化）", hit2)
	var vsrc := FileAccess.get_file_as_string("res://scripts/core/data/data_validator.gd")
	_check("L16 域文案 0~8 已退役", vsrc.count("枚举（0~8）") == 0)


# ── L14：图鉴祝福页行源滤 TH_* ──────────────────────────────────────────
func _test_codex_th_filter() -> void:
	print("── L14 图鉴滤 TH_* ──")
	var gl = _mk_gl("R262cL14")
	var menu = gl.menu_screen
	var th_count := 0
	var all_count: int = gl.registry.traits.size()
	for tid_v: Variant in gl.registry.traits.keys():
		var td: TraitData = gl.registry.get_trait(tid_v)
		if td != null and bool(td.params.get("threshold_only", false)):
			th_count += 1
	var page_rows := 0
	for i in range(all_count + 2):
		if menu.call("_make_codex_entry_row", "祝福", i) == null:
			page_rows = i
			break
	_check("L14 祝福页行源剔除 TH_*（行数=%d=全量 %d−阈值 %d）" % [page_rows, all_count, th_count],
		th_count > 0 and page_rows == all_count - th_count,
		"rows=%d all=%d th=%d" % [page_rows, all_count, th_count])
	gl.free()

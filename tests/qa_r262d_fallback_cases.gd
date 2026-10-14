# R262d 应急强化批验收用例体（qa_r262d_fallback 入口 load）
# 用户裁定三件套：①不同品级 buff 数值不一致（RARITY_VALUE_SCALE 缩放）②攻击力全局
# （player.add_fallback_atk 全武器累计，不再挂单武器栈）③衰减口径修正（R226 起每层
# 全额——decay_delta=0.85 遗留键非机制，用户「衰减到一定程度不变」已被全额超额满足）
extends RefCounted

var _tree: SceneTree = null
var _fails: int = 0
var _passes: int = 0
var _intro_last: String = ""

const PLAYER_SRC := "res://scripts/entities/player/player.gd"
const CG_SRC := "res://scripts/cards/card_generator.gd"
const SHOP_SRC := "res://scripts/ui/shop_ui.gd"
const EXPECTED := [0.05, 0.07, 0.095, 0.13]


func _check(p_name: String, p_ok: bool, p_detail: String = "") -> void:
	if p_ok:
		_passes += 1
		print("PASS | " + p_name)
	else:
		_fails += 1
		print("FAIL | " + p_name + ("" if p_detail.is_empty() else "  [got: " + p_detail + "]"))


func run_all(p_tree: SceneTree) -> int:
	_tree = p_tree
	_test_tier_scaling()
	_test_direct_grant()
	_test_overflow_conversion()
	_test_all_weapons_effect()
	_test_resonance_coexist()
	_test_save_roundtrip_and_migration()
	_test_shop_evergreen()
	_test_decay_lock()
	print("R262d 汇总：PASS %d / FAIL %d（共 %d 项）" % [_passes, _fails, _passes + _fails])
	return _fails


func _mk_gl(p_name: String):
	var gl = GameLoop.new()
	gl.name = p_name
	_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	return gl


# ── A：品级定标四档（×RARITY_VALUE_SCALE[1.0,1.4,1.9,2.6]） ─────────────
func _test_tier_scaling() -> void:
	print("── A 品级定标 ──")
	var cg := CardGenerator.new()
	var ok_vals := true
	var names: Array[String] = []
	for r in range(4):
		var card: Dictionary = cg.call("_fallback_stat_card", r)
		var data: TraitData = card.get("data")
		names.append(String(card.get("display_name", "")))
		if not is_equal_approx(float(data.value), EXPECTED[r]):
			ok_vals = false
	_check("A1 四档数值 5%/7%/9.5%/13%（×RARITY_VALUE_SCALE）", ok_vals,
		"names=%s" % str(names))
	var c0: Dictionary = cg.call("_fallback_stat_card", 0)
	var c3: Dictionary = cg.call("_fallback_stat_card", 3)
	_check("A2 卡面品级字（白无后缀 / 金·金+全武器口径）",
		not c0.get("display_name", "").contains("·") \
			and c3.get("display_name", "").contains("·金") \
			and c3.get("display_name", "").contains("全武器"),
		"w=%s g=%s" % [c0.get("display_name", ""), c3.get("display_name", "")])
	_check("A3 rarity 字段回填（构造参数透传）",
		int((c3.get("data") as TraitData).rarity) == 3 and int(c0.get("rarity", -1)) == 0)


# ── B：FALLBACK 卡直选走全局（不挂武器栈） ─────────────────────────────
func _test_direct_grant() -> void:
	print("── B 直选全局授予 ──")
	var gl = _mk_gl("R262dB")
	var player = gl.player
	var stack: TraitStack = player.weapon_slots[0].trait_stack
	var before: float = float(player.get("run_fallback_atk_pct"))
	var card: Dictionary = gl.card_generator.call("_fallback_stat_card", 0)
	gl.card_generator.apply_choice(card, player)
	var after: float = float(player.get("run_fallback_atk_pct"))
	_check("B1 直选白卡 +5% 入全局累计", is_equal_approx(after - before, 0.05),
		"Δ=%f" % (after - before))
	var has_stack_entry := false
	for m_v: Variant in stack.traits:
		if String(m_v.data.id) == "FALLBACK_ATK":
			has_stack_entry = true
	_check("B2 武器栈无 FALLBACK_ATK 条目（通道改全局）", not has_stack_entry)
	# 每层全额口径锁（用户「每层衰减」裁定——实际 R226 起无衰减，锁行为防回退）
	gl.card_generator.apply_choice(gl.card_generator.call("_fallback_stat_card", 0), player)
	var after2: float = float(player.get("run_fallback_atk_pct"))
	_check("B3 第二层全额（0.05×2=0.10——无衰减口径锁）",
		is_equal_approx(after2 - before, 0.10), "total Δ=%f" % (after2 - before))
	gl.queue_free()


# ── C：满员转化链（品级横幅+全局数值） ────────────────────────────────
func _test_overflow_conversion() -> void:
	print("── C 满员转化 ──")
	var gl = _mk_gl("R262dC")
	var player = gl.player
	var weapon = player.weapon_slots[0]
	# 填满 12 种类帽（运行期唯一 id——构造宽度帽 MAX_TRAITS=12）
	for i in range(TraitStack.MAX_TRAITS):
		var filler := TraitData.new()
		filler.id = StringName("R262D_FILL_%d" % i)
		filler.display_name = "填充%d" % i
		filler.pool = GameConst.PoolClass.ADD
		filler.pool_id = &"add_hp"
		filler.effect_id = &"EF_STAT"
		filler.value = 1.0
		filler.stack_max = 99
		if not weapon.trait_stack.attach(filler):
			_check("C 前置：填满 12 种类", false, "i=%d" % i)
			gl.queue_free()
			return
	_check("C 前置：填满 12 种类", weapon.trait_stack.size() == TraitStack.MAX_TRAITS)
	var victim: TraitData = (gl.registry.get_trait(&"AFF_ATK_UP") as TraitData).duplicate()
	victim.value = 0.25
	victim.rarity = 2                              # 紫卡被转
	var before: float = float(player.get("run_fallback_atk_pct"))
	_intro_last = ""
	var cb := func(t: String) -> void: _intro_last = t
	EventBus.mechanics_intro.connect(cb)
	gl.card_generator.apply_choice({
		"kind": CardGenerator.CardKind.TRAIT, "id": &"AFF_ATK_UP", "rarity": 2,
		"data": victim, "display_name": victim.display_name,
		"description": victim.description,
	}, player)
	EventBus.mechanics_intro.disconnect(cb)
	var after: float = float(player.get("run_fallback_atk_pct"))
	_check("C1 紫卡转化 +9.5% 入全局（品级缩放透传）",
		is_equal_approx(after - before, 0.095), "Δ=%f" % (after - before))
	_check("C2 横幅品级+数值+全局口径（「紫」「+9.5%」「全武器」）",
		_intro_last.contains("紫") and _intro_last.contains("+9.5%") \
			and _intro_last.contains("全武器"), "banner=%s" % _intro_last)
	var victim_g: TraitData = (gl.registry.get_trait(&"AFF_ATK_UP") as TraitData).duplicate()
	victim_g.value = 0.25
	victim_g.rarity = 3                              # 金卡被转
	var before_g: float = float(player.get("run_fallback_atk_pct"))
	gl.card_generator.apply_choice({
		"kind": CardGenerator.CardKind.TRAIT, "id": &"AFF_ATK_UP", "rarity": 3,
		"data": victim_g, "display_name": victim_g.display_name,
		"description": victim_g.description,
	}, player)
	_check("C3 金卡转化 +13% 入全局（三档再验一档）",
		is_equal_approx(float(player.get("run_fallback_atk_pct")) - before_g, 0.13),
		"Δ=%f" % (float(player.get("run_fallback_atk_pct")) - before_g))
	gl.queue_free()


# ── D：全武器生效（两把武器 base_atk 同步提升） ────────────────────────
func _test_all_weapons_effect() -> void:
	print("── D 全武器生效 ──")
	var gl = _mk_gl("R262dD")
	var player = gl.player
	player.unlocked_slots = maxi(int(player.unlocked_slots), 2)   # 解锁副槽（防 add_weapon 拒）
	if player.weapon_slots[1] == null:
		player.add_weapon(player.weapon_slots[0].data)
	var w0 = player.weapon_slots[0]
	var w1 = player.weapon_slots[1]
	var a0: float = float(w0.call("build_panel_snapshot").get("base_atk", -1.0))
	var a1: float = float(w1.call("build_panel_snapshot").get("base_atk", -1.0))
	player.call("add_fallback_atk", 0.10)
	var b0: float = float(w0.call("build_panel_snapshot").get("base_atk", -1.0))
	var b1: float = float(w1.call("build_panel_snapshot").get("base_atk", -1.0))
	_check("D1 主武器 base_atk +10%（全局注入）", is_equal_approx(b0, a0 * 1.10),
		"a=%f b=%f" % [a0, b0])
	_check("D2 副武器 base_atk 同步 +10%（对比单武器旧制）", is_equal_approx(b1, a1 * 1.10),
		"a=%f b=%f" % [a1, b1])
	_check("D3 meta_atk_pct 注入含 fallback 成分（等式）",
		is_equal_approx(float(w0.meta_atk_pct),
			Meta.atk_pct() + float(player.character_atk_pct) + 0.10),
		"meta=%f" % float(w0.meta_atk_pct))
	gl.queue_free()


# ── E：本命共鸣重写共存（_apply_resonance 不冲掉 fallback） ─────────────
func _test_resonance_coexist() -> void:
	print("── E 本命共鸣共存 ──")
	var gl = _mk_gl("R262dE")
	var player = gl.player
	player.call("add_fallback_atk", 0.10)
	var w0 = player.weapon_slots[0]
	var meta_before: float = float(w0.meta_atk_pct)
	player.call("_apply_resonance", -1)             # 静默重推（本命/非本命两态注入）
	var meta_after: float = float(w0.meta_atk_pct)
	_check("E1 共鸣重推后 fallback 成分保持（R262d 注入点三处同式）",
		is_equal_approx(meta_after, meta_before),
		"before=%f after=%f" % [meta_before, meta_after])
	# 新武器注入即含（add_weapon 注入点）
	player.unlocked_slots = maxi(int(player.unlocked_slots), 3)   # 解锁第三槽（防拒建）
	var w2 = player.add_weapon(player.weapon_slots[0].data)
	var ok_new := w2 != null and is_equal_approx(float(w2.meta_atk_pct),
		Meta.atk_pct() + float(player.character_atk_pct) + 0.10)
	_check("E2 新建武器注入即含 fallback（add_weapon 注入点）", ok_new,
		"meta=%f" % (float(w2.meta_atk_pct) if w2 != null else -1.0))
	gl.queue_free()


# ── F：存档往返 + 旧档武器栈词条迁移 ──────────────────────────────────
func _test_save_roundtrip_and_migration() -> void:
	print("── F 存档往返/旧档迁移 ──")
	var gl = _mk_gl("R262dF")
	var player = gl.player
	player.call("add_fallback_atk", 0.07)
	var snap: Dictionary = gl.call("serialize_run")
	_check("F1 serialize_run 顶层 fallback_atk 键保真（0.07）",
		is_equal_approx(float(snap.get("fallback_atk", -1.0)), 0.07),
		"v=%s" % str(snap.get("fallback_atk", -1.0)))
	# 旧档（vc71 前挂武器栈时代）迁移：武器栈 FALLBACK_ATK lv 两层 + 顶层键 0.05
	var old_snap: Dictionary = {
		"map_id": String(gl.current_map_id),
		"difficulty": 0,
		"character": String(player.character_id),
		"fallback_atk": 0.05,
		"weapons": [{
			"id": String(player.weapon_slots[0].data.id),
			"level": 1,
			"traits": [{
				"id": "FALLBACK_ATK", "layers": 2,
				"lv": [0.05, 0.07], "lr": [0, 1], "dv": 0.05, "dr": 0,
			}],
		}],
	}
	gl.call("_restore_run_state", old_snap)
	var migrated: float = float(player.get("run_fallback_atk_pct"))
	_check("F2 旧档词条迁移（顶层 0.05 + lv 两层 0.12 = 0.17）",
		is_equal_approx(migrated, 0.17), "v=%f" % migrated)
	var stack_after: TraitStack = player.weapon_slots[0].trait_stack
	var has_old := false
	for m_v: Variant in stack_after.traits:
		if String(m_v.data.id) == "FALLBACK_ATK":
			has_old = true
	_check("F3 旧档词条不再挂武器栈（迁移语义）", not has_old)
	gl.queue_free()


# ── G：黑市常青货（无宿主恒真货） ────────────────────────────────────
func _test_shop_evergreen() -> void:
	print("── G 黑市常青货 ──")
	var gl = _mk_gl("R262dG")
	var shop = gl.shop_ui
	shop.set("_player", gl.player)                 # boot 期未注入局内玩家——夹具补（与局内开店同源）
	var ware: Dictionary = {
		"kind": "trait", "rarity": 0, "evergreen": true,
		"data": null, "base": 25.0, "mult": 1.0,
	}
	var stocked: bool = bool(shop.call("_ware_stocked", ware))
	_check("G1 evergreen 行无 target 恒真货（_ware_stocked 特判）", stocked)
	var s_src := FileAccess.get_file_as_string(SHOP_SRC)
	var fn_start: int = s_src.find("func _append_evergreen_fallback")
	var fn_end: int = s_src.find("\nfunc ", fn_start + 10)
	var fn_body := s_src.substr(fn_start, fn_end - fn_start)
	_check("G2 常青货函数段内无挂载谓词/宿主类型探测（host 链退役）",
		fn_body.count("_can_mount_trait") == 0 and fn_body.count("WeaponBase") == 0)
	gl.queue_free()


# ── H：衰减口径锁（源码锚——decay_delta 为遗留键非机制） ────────────────
func _test_decay_lock() -> void:
	print("── H 衰减口径锁 ──")
	var cg_src := FileAccess.get_file_as_string(CG_SRC)
	_check("H1 _fallback_stat_card 注释声明遗留键口径（「遗留记账键」锚）",
		cg_src.count("遗留记账键") >= 1)
	var p_src := FileAccess.get_file_as_string(PLAYER_SRC)
	var n_inject: int = p_src.count("+ run_fallback_atk_pct")
	_check("H2 player 三注入点全含 fallback 成分（add_weapon/动态注入/共鸣重写 count==3）",
		n_inject == 3, "count=%d" % n_inject)

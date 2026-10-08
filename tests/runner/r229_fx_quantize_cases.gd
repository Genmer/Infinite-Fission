# tests/runner/r229_fx_quantize_cases.gd
# R229「特效层渐隐 alpha 量化（4 档）——sprite 族共享贴图合批」验收用例体
# （由 test_r229_fx_quantize.gd 入口加载；骨架照 r198_element_fx_cases 既有 -cases 结构）。
# 覆盖（刀面 acceptance 逐条）：
#   ① _qa 四分档契约（Q_ALPHA_STEPS==4 + 逐界值/越界钳制）+ 逐族事件触发
#      （elemental_dot_fired / reaction_triggered(RXN_FIR_ICE) / shield_blocked /
#      beam_impact / burn_devour_proc / kill_blast / skill_cast）→ tick 至两个中间相位
#      → 族内全部 live sprite modulate.a ∈ {0, 0.25, 0.5, 0.75, 1.0}；
#      blast fire 的 rgb 三通道各 ∈ 四分档；电花族（:583 写点）随 chain_lightning 附验；
#      不碰清单钉：_tick_bolts（Line2D 族）保持连续渐隐（刀面③）。
#   ② 合批前置验：6 连发反应环（shatter + rxn 双族各 6 件同时 live ≥3）时
#      distinct modulate.a ≤2（同量化档可合并——R216/R217 断批定律反用）；
#      反证面：同相位差的连续（未量化）alpha 逐件唯一（distinct≥3）→ 量化后坍缩。
#   ③ 寿命自清不变：逐族触发 → life 尽 → visible=false（r198 既有断言面保持）；
#      无 alpha==0 仍 visible 的滞留件（滞留判定=left==0 后仍在树可见——量化尾段
#      a_cont<0.125 落 0 档的瞬态可见 ≤12.5% 寿命且 life 尽即隐，非滞留）；
#      全局清场：tick 30s 后特效层子树零可见件。
# 环境钉：fx_quality=2（低档 DOT/爆族整体关→族不可测——Meta 落盘值跨套件残留，
# fx_quality_cases.gd:47 同款先例，结尾还原）；Enemy.fullload_override=0（r207 覆写口
# 先例——满载门强制关，DOT 族不静默；headless 桌面口径本就 false，双保险）。
extends RefCounted

const DT_STAGGER := 0.004     # ② 连发微相位差（6 件总散布 0.02s → 连续 alpha 散布 <0.25 ⇒ 量化后必 ≤2 档）

# 族名前缀（层直接子件；BeamImpact/BurnDevour 为 Node2D 根组，子件 Flash/Spark*/Flame*）
const FAM_DOT := ["DotSpark", "DotGlow"]
const FAM_REACTION := ["ShatterRing", "RxnRing"]
const FAM_SHIELD := ["CyanRipple"]
const FAM_BEAM := ["BeamImpact"]
const FAM_DEVOUR := ["BurnDevour"]
const FAM_BLAST := ["BlastFlash", "BlastFire", "BlastRing", "BlastSmoke"]
const FAM_SKILL := ["SkillRing"]
const FAM_ZAP := ["ZapBit"]
const _SUBITEMS := ["Flash", "Spark", "Flame"]

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _layer: ElementalFxLayer = null
var _fxq_prev: int = 2
var _fullload_prev: int = -1


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(2291004)
	_fxq_prev = int(Meta.settings("fx_quality"))
	Meta.set_setting("fx_quality", 2)
	_fullload_prev = Enemy.fullload_override
	Enemy.fullload_override = 0
	_layer = ElementalFxLayer.new()
	_layer.name = "R229FxLayer"
	tree.get_root().add_child(_layer)           # _ready 预建全部池 + 订阅表现层广播
	_test_qa_contract()
	_test_family_grid_dot()                     # ① elemental_dot_fired → DotSpark×4 + DotGlow
	_test_family_grid_reaction()                # ① reaction_triggered(RXN_FIR_ICE) → ShatterRing + RxnRing
	_test_family_grid_shield()                  # ① shield_blocked → CyanRipple
	_test_family_grid_beam()                    # ① beam_impact → BeamImpact root/Flash/Spark×3
	_test_family_grid_devour()                  # ① burn_devour_proc → BurnDevour root/Flash/Flame×4
	_test_family_grid_blast()                   # ① kill_blast → Blast*（fire rgb 三通道四分档）
	_test_family_grid_skill()                   # ① skill_cast → SkillRing
	_test_bolt_family_not_quantized()           # ①附 不碰清单：_tick_bolts 连续渐隐（+电花族量化附验）
	_test_batch_collapse_rings()                # ② 6 连发反应环 distinct ≤2
	_test_life_self_clean()                     # ③ 寿命自清 + 零滞留 + 全局清场
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


func _teardown() -> void:
	if _layer != null:
		_layer.free()                           # 非池化临时件（表现层宿主直 free——r198 ⑨ 先例）
		_layer = null
	Enemy.fullload_override = _fullload_prev
	Meta.set_setting("fx_quality", _fxq_prev)   # 还原现场（防污染其他套件——fx_quality 先例）


func _flush() -> void:
	_layer.tick(30.0)                           # 全族 life 尽 → 全隐（用例间清场）


func _on_grid(p_a: float) -> bool:
	# 四分档判定：a∈[0,1] 且 a×4 为整数（量化值均为 2 的幂次分母——精确二进制表示）
	if p_a < -0.0001 or p_a > 1.0001:
		return false
	var q := p_a * 4.0
	return absf(q - roundf(q)) < 0.01


func _live_items(p_prefixes: Array) -> Array:
	# 族内 live 件（is_visible_in_tree——Node2D 根组门控自然生效）；根组下钻收 Flash/Spark/Flame
	var out: Array = []
	_walk_family(_layer, p_prefixes, out)
	return out


func _walk_family(p_node: Node, p_prefixes: Array, p_out: Array) -> void:
	for c in p_node.get_children():
		var hit := false
		for px in p_prefixes:
			if String(c.name).begins_with(String(px)):
				hit = true
				break
		if hit and c is CanvasItem:
			if (c as CanvasItem).is_visible_in_tree():
				p_out.append(c)
				_walk_family(c, _SUBITEMS, p_out)
		elif not hit:
			_walk_family(c, p_prefixes, p_out)


func _live_alphas(p_prefixes: Array) -> Array:
	var out: Array = []
	for it: CanvasItem in _live_items(p_prefixes):
		out.append(it.modulate.a)
	return out


func _distinct(p_vals: Array) -> int:
	var seen: Array = []
	for v in p_vals:
		var dup := false
		for s in seen:
			if absf(float(v) - float(s)) < 0.0001:
				dup = true
				break
		if not dup:
			seen.append(float(v))
	return seen.size()


func _assert_grid(p_prefixes: Array, p_label: String, p_expect: int) -> void:
	var items: Array = _live_items(p_prefixes)
	var bad: Array = []
	for it: CanvasItem in items:
		if not _on_grid(it.modulate.a):
			bad.append("%s.a=%.4f" % [it.name, it.modulate.a])
	_check("%s：live %d 件全部 modulate.a∈四分档" % [p_label, p_expect],
		items.size() == p_expect and bad.is_empty(),
		"live=%d 期望=%d 违例=%s" % [items.size(), p_expect, str(bad)])


func _find(p_name: String) -> CanvasItem:
	for c in _layer.get_children():
		if String(c.name) == p_name:
			return c as CanvasItem
	return null


# ── ① _qa 契约 ────────────────────────────────────────────────────
func _test_qa_contract() -> void:
	print("── ① _qa 四分档契约 ──")
	_check("① Q_ALPHA_STEPS==4（四分档 {0, 0.25, 0.5, 0.75, 1.0}）",
		ElementalFxLayer.Q_ALPHA_STEPS == 4)
	# roundi(clamp(a,0,1)*4)/4 逐界值：0.125/0.375/0.625/0.875 为换档界（含越界钳制）
	var q_cases := {
		-0.3: 0.0, 0.0: 0.0, 0.124: 0.0, 0.126: 0.25, 0.3: 0.25, 0.37: 0.25,
		0.38: 0.5, 0.5: 0.5, 0.62: 0.5, 0.63: 0.75, 0.7: 0.75, 0.87: 0.75,
		0.88: 1.0, 1.0: 1.0, 1.7: 1.0,
	}
	var ok := true
	var bad := ""
	for k in q_cases:
		var got := ElementalFxLayer._qa(float(k))
		if absf(got - float(q_cases[k])) > 0.0001:
			ok = false
			bad = "%s→%s（期望 %s）" % [str(k), str(got), str(q_cases[k])]
			break
	_check("① _qa 契约：roundi(clamp(a,0,1)*4)/4 逐界值（含越界钳制到 [0,1]）", ok, bad)


# ── ① 逐族中相位四分档 ────────────────────────────────────────────
func _test_family_grid_dot() -> void:
	print("── ① dot 族（elemental_dot_fired → 火星+光晕） ──")
	_flush()
	EventBus.emit_elemental_dot_fired(Vector2(360.0, 600.0))
	_layer.tick(0.06)
	_assert_grid(FAM_DOT, "① dot 族 相位A（0.06s：DotSpark×4+DotGlow×1）", 5)
	_layer.tick(0.12)
	_assert_grid(FAM_DOT, "① dot 族 相位B（0.18s：glow 寿命尽自隐，仅火星×4 在册）", 4)


func _test_family_grid_reaction() -> void:
	print("── ① 反应族（reaction_triggered RXN_FIR_ICE → 碎裂主环+窄橙内环） ──")
	_flush()
	EventBus.emit_reaction_triggered(GameConst.ReactionType.RXN_FIR_ICE,
		Vector2(300.0, 500.0), 900001)
	_layer.tick(0.10)
	_assert_grid(FAM_REACTION, "① 反应族 相位A（0.10s：ShatterRing+RxnRing）", 2)
	_layer.tick(0.06)
	_assert_grid(FAM_REACTION, "① 反应族 相位B（0.16s 中后段）", 2)


func _test_family_grid_shield() -> void:
	print("── ① 涟漪族（shield_blocked → 青色大涟漪） ──")
	_flush()
	EventBus.emit_shield_blocked(Vector2(340.0, 620.0))
	_layer.tick(0.10)
	_assert_grid(FAM_SHIELD, "① 涟漪族 相位A（0.10s）", 1)
	_layer.tick(0.06)
	_assert_grid(FAM_SHIELD, "① 涟漪族 相位B（0.16s 中后段）", 1)


func _test_family_grid_beam() -> void:
	print("── ① 迸裂族（beam_impact → root+星闪+束色火花×3） ──")
	_flush()
	EventBus.emit_beam_impact(Vector2(320.0, 480.0), Vector2.RIGHT)
	_layer.tick(0.08)
	_assert_grid(FAM_BEAM, "① 迸裂族 相位A（0.08s 中相位：root+Flash+Spark×3）", 5)
	_layer.tick(0.04)
	_assert_grid(FAM_BEAM, "① 迸裂族 相位B（0.12s 中后段）", 5)


func _test_family_grid_devour() -> void:
	print("── ① 吞噬族（burn_devour_proc → root+星闪+火苗×4） ──")
	_flush()
	EventBus.emit_burn_devour_proc(Vector2(340.0, 520.0))
	_layer.tick(0.15)
	_assert_grid(FAM_DEVOUR, "① 吞噬族 相位A（0.15s 中相位：root+Flash+Flame×4）", 6)
	_layer.tick(0.06)
	_assert_grid(FAM_DEVOUR, "① 吞噬族 相位B（0.21s 中后段）", 6)


func _test_family_grid_blast() -> void:
	print("── ① 爆族（kill_blast → 白闪/火球/冲击环/烟尘四层） ──")
	_flush()
	EventBus.emit_kill_blast(Vector2(360.0, 640.0), 110.0)
	_layer.tick(0.25)
	# t=0.5：flash 已过 0.3 快闪窗自隐 → live=fire+ring+smoke 三件（自隐门本身即寿命分段）
	_assert_grid(FAM_BLAST, "① 爆族 相位A（t=0.5：fire+ring+smoke）", 3)
	var fire := _find("BlastFire0")
	_check("① 爆族 fire.rgb 三通道各∈四分档（通道色 lerp 逐通道量化）",
		fire != null and _on_grid(fire.modulate.r) and _on_grid(fire.modulate.g)
		and _on_grid(fire.modulate.b),
		"rgb=%s" % (str(fire.modulate) if fire != null else "-"))
	_layer.tick(0.10)
	_assert_grid(FAM_BLAST, "① 爆族 相位B（t=0.7 后段）", 3)
	_check("① 爆族 fire.rgb 三通道四分档（相位B 复验）",
		fire != null and _on_grid(fire.modulate.r) and _on_grid(fire.modulate.g)
		and _on_grid(fire.modulate.b),
		"rgb=%s" % (str(fire.modulate) if fire != null else "-"))


func _test_family_grid_skill() -> void:
	print("── ① 技能金环族（skill_cast） ──")
	_flush()
	EventBus.emit_skill_cast(Vector2(360.0, 640.0), "r229")
	_layer.tick(0.20)
	_assert_grid(FAM_SKILL, "① 技能金环族 相位A（0.20s 中相位）", 1)
	_layer.tick(0.10)
	_assert_grid(FAM_SKILL, "① 技能金环族 相位B（0.30s 后段）", 1)


# ── ①附 不碰清单钉 + 电花族量化附验 ────────────────────────────────
func _test_bolt_family_not_quantized() -> void:
	print("── ①附 _tick_bolts 不量化钉（Line2D 族）+ 电花族（:583 写点）附验 ──")
	_flush()
	EventBus.emit_chain_lightning(Vector2(100.0, 300.0), Vector2(300.0, 320.0))
	_layer.tick(0.048)
	var bolt := _find("ChainBolt0")
	var a1 := bolt.modulate.a if bolt != null else -1.0
	_assert_grid(FAM_ZAP, "①附 电花族（chain_lightning 落点×3，相位A）", 3)
	_layer.tick(0.05)
	var a2 := bolt.modulate.a if bolt != null else -1.0
	_assert_grid(FAM_ZAP, "①附 电花族 相位B（0.098s 后段，非整档连续值入档）", 3)
	_check("①附 不碰清单：_tick_bolts root 连续渐隐（两相位均非四分档且值在变）",
		bolt != null and bolt.is_visible_in_tree()
		and not _on_grid(a1) and not _on_grid(a2) and absf(a2 - a1) > 0.001,
		"a1=%.4f a2=%.4f" % [a1, a2])


# ── ② 合批前置验：6 连发反应环 distinct ≤2 ────────────────────────
func _test_batch_collapse_rings() -> void:
	print("── ② 6 连发反应环（微相位差）distinct modulate.a ≤2 ──")
	_flush()
	for i in range(6):
		EventBus.emit_reaction_triggered(GameConst.ReactionType.RXN_FIR_ICE,
			Vector2(300.0 + 20.0 * i, 500.0), 910000 + i)
		if i < 5:
			_layer.tick(DT_STAGGER)             # 微相位差（总散布 0.02s < 0.25 档宽×life）
	_layer.tick(0.10)
	var shatter := _live_alphas(["ShatterRing"])
	var rxn := _live_alphas(["RxnRing"])
	_check("② 同族同时 live≥3 件：shatter 6 / rxn 6（6 连发全在册）",
		shatter.size() == 6 and rxn.size() == 6,
		"shatter=%d rxn=%d" % [shatter.size(), rxn.size()])
	_check("② 合批前置验：shatter 族 distinct modulate.a ≤2（同量化档可合并）",
		_distinct(shatter) <= 2,
		"distinct=%d vals=%s" % [_distinct(shatter), str(shatter)])
	_check("② 合批前置验：rxn 内环族 distinct modulate.a ≤2（同量化档可合并）",
		_distinct(rxn) <= 2,
		"distinct=%d vals=%s" % [_distinct(rxn), str(rxn)])
	# 反证面：同相位差的连续（未量化）alpha 逐件唯一——量化前 6 件=6 个独立 modulate
	# （逐件独立 dc，R216/R217 断批定律），量化后坍缩（R216/R217 反用）
	var cont: Array = []
	for i in range(6):
		var age := DT_STAGGER * float(5 - i) + 0.10
		cont.append(1.0 - age / 0.22)           # rxn 内环 life=0.22（_spawn_reaction_ring 调用实参）
	_check("② 坍缩证明：连续 alpha 逐件唯一（distinct≥3）→ 量化后 ≤2",
		_distinct(cont) >= 3 and _distinct(rxn) <= 2,
		"连续 distinct=%d 量化 distinct=%d" % [_distinct(cont), _distinct(rxn)])


# ── ③ 寿命自清 + 零滞留 + 全局清场 ─────────────────────────────────
func _decay_clean(p_label: String, p_fire: Callable, p_prefixes: Array, p_pools: Array) -> void:
	_flush()
	p_fire.call()
	_layer.tick(0.001)
	var live_n := _live_items(p_prefixes).size()
	_layer.tick(30.0)
	var vis := _live_items(p_prefixes).size()   # life 尽 → 全隐 → 0
	var lingering := 0                          # 滞留=left==0 后仍在树可见（is_visible_in_tree 含根组门控）
	var live_left := 0
	for pool in p_pools:
		for slot: Dictionary in pool:
			if float(slot["left"]) > 0.0:
				live_left += 1
			for k: String in ["sprite", "root", "flash", "fire", "ring", "smoke"]:
				if slot.has(k) and (slot[k] as CanvasItem).is_visible_in_tree():
					lingering += 1
	_check("③ %s：触发即 live → 寿命尽 visible=false 且零滞留（left==0 ⇒ 不可见）" % p_label,
		live_n > 0 and vis == 0 and lingering == 0 and live_left == 0,
		"live=%d 尽后可见=%d 滞留=%d 挂账=%d" % [live_n, vis, lingering, live_left])


func _test_life_self_clean() -> void:
	print("── ③ 寿命自清（逐族 life 尽 → visible=false）──")
	_decay_clean("dot 族（sparks+glows）",
		Callable(EventBus, "emit_elemental_dot_fired").bind(Vector2(360.0, 600.0)),
		FAM_DOT, [_layer._sparks, _layer._glows])
	_decay_clean("反应族（shatter+rxn）",
		Callable(EventBus, "emit_reaction_triggered").bind(
			GameConst.ReactionType.RXN_FIR_ICE, Vector2(300.0, 500.0), 920001),
		FAM_REACTION, [_layer._rings, _layer._rxn_rings])
	_decay_clean("涟漪族",
		Callable(EventBus, "emit_shield_blocked").bind(Vector2(340.0, 620.0)),
		FAM_SHIELD, [_layer._ripples])
	_decay_clean("迸裂族",
		Callable(EventBus, "emit_beam_impact").bind(Vector2(320.0, 480.0), Vector2.RIGHT),
		FAM_BEAM, [_layer._impacts])
	_decay_clean("吞噬族",
		Callable(EventBus, "emit_burn_devour_proc").bind(Vector2(340.0, 520.0)),
		FAM_DEVOUR, [_layer._devours])
	_decay_clean("爆族（四层）",
		Callable(EventBus, "emit_kill_blast").bind(Vector2(360.0, 640.0), 110.0),
		FAM_BLAST, [_layer._blasts])
	_decay_clean("技能金环族",
		Callable(EventBus, "emit_skill_cast").bind(Vector2(360.0, 640.0), "r229"),
		FAM_SKILL, [_layer._skill_rings])
	var stray := 0
	for c in _layer.get_children():
		if c is CanvasItem and (c as CanvasItem).is_visible_in_tree():
			stray += 1
	_check("③ 全局清场：tick 30s 后特效层子树零可见件（无 alpha==0 仍 visible 滞留件）",
		stray == 0, "stray=%d" % stray)

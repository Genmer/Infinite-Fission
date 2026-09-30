# probe_buff5_matrix.gd（buff-5 只读体检探针：激化臂免疫门 / 激化→冰系条件乘区 / 绽放×检测同帧幂等碰撞）
# 跑法：tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s probe_buff5_matrix.gd
# 视角：元素反应×词条交互。零游戏类编译期引用（-s 入口先于 autoload 注册）。
# 探针自检修正（v2）：immune_mask 须在 register_host 前置（register 时快照入状态，
# elemental_system.gd:108）；TraitContext.target 须显式设（SynergyRules._target_state_active
# 读 tctx.target）；FIR 满槽即清槽触发——蒸发候选需部分附着（<100）。
extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"

var _pass: int = 0
var _fail: int = 0


func _initialize() -> void:
	_run()


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		print("FAIL | %s | %s" % [p_name, p_detail])


func _mk_enemy(gl: Node, p_id: StringName, p_pos: Vector2, p_mask: int = 0) -> Node:
	var pool: Node = gl.pools[&"enemy"]
	var e: Node = pool.acquire()
	var d: Resource = load("res://scripts/core/data/resources/enemy_data.gd").new()
	d.id = p_id
	d.hp_base = 100000.0
	d.spd_base = 0.0
	d.hitbox_r = 14.0
	e.spawn(d, 1, 0)
	e.position = p_pos
	e.set("immune_mask", p_mask)                # 先置位再注册（register_host 快照）
	gl.elemental.register_host(e)
	return e


func _run() -> void:
	print("══ 激化免疫门 × 冰系条件乘区 × 绽放同帧幂等 探针 ══")
	await process_frame
	await process_frame
	var eb: Node = root.get_node("EventBus")
	var gl: Node = load(MAIN_SCENE).instantiate()
	root.add_child(gl)
	gl.state = GameConst.GameStatus.MENU
	gl.start_run()

	# ── A. 激化臂 × IMMUNE_CHILL（对照：冻结臂同免疫位整段跳过） ──
	var ea := _mk_enemy(gl, &"E_PROBE_QA", Vector2(300.0, 100.0), GameConst.IMMUNE_CHILL)
	gl.elemental.apply_attach(ea, GameConst.Element.LTG, 30.0)
	gl.elemental.apply_attach(ea, GameConst.Element.DEN, 30.0)
	gl.elemental.detect_reactions()
	var sta: Variant = ea.elemental
	_check("A0 前置：免疫位入状态（state.immune_mask=&%d）" % int(sta.immune_mask),
		(sta.immune_mask & GameConst.IMMUNE_CHILL) != 0)
	_check("A1 激化：IMMUNE_CHILL 怪被写易伤（vuln_timer=%.1f；冻结/冰附着同位均整段跳过）"
		% float(sta.vuln_timer), float(sta.vuln_timer) > 0.0)
	_check("A2 激化：双槽已清（反应通道正常消费）",
		float(sta.gauges[GameConst.Element.LTG]) == 0.0
		and float(sta.gauges[GameConst.Element.DEN]) == 0.0)

	var eb2 := _mk_enemy(gl, &"E_PROBE_QB", Vector2(700.0, 100.0), GameConst.IMMUNE_CHILL)
	gl.elemental.apply_attach(eb2, GameConst.Element.ICE, 30.0)
	gl.elemental.apply_attach(eb2, GameConst.Element.HYD, 30.0)
	gl.elemental.detect_reactions()
	var stb: Variant = eb2.elemental
	_check("B1 冻结对照：IMMUNE_CHILL 怪三写整段跳过（vuln_timer=%.1f==0）"
		% float(stb.vuln_timer), float(stb.vuln_timer) == 0.0)

	# ── C. 激化易伤 → SYN_FROST_EXEC「对寒滞/冻结目标」条件乘区误激活 ──
	var w: Node = gl.player.weapon_slots[0]
	var t: Resource = gl.registry.get_trait(&"SYN_FROST_EXEC")
	var attached: bool = bool(w.attach_trait(t))
	_check("C0 前置：SYN_FROST_EXEC 挂载", attached)
	var ctrl_dummy := _mk_enemy(gl, &"E_PROBE_QC", Vector2(-300.0, 100.0))
	var ctrl := _resolve_on(gl, w, ctrl_dummy)
	var boosted := _resolve_on(gl, w, ea)       # ea = 激化态（仅易伤，无寒滞/冻结）
	_check("C1 对照：无状态目标 ≈100（%.1f）" % ctrl, absf(ctrl - 100.0) < 0.8, "%.1f" % ctrl)
	_check("C2 激化目标吃「对寒滞/冻结×1.5」乘区（%.1f）——卡面语义与判定漂移" % boosted,
		absf(boosted - 150.0) < 1.0, "%.1f" % boosted)

	# ── D. 绽放到期爆发 × 帧末检测 同帧同目标幂等碰撞（管线缓存吞掉第二反应） ──
	var ed := _mk_enemy(gl, &"E_PROBE_BLOOM", Vector2(300.0, 900.0))
	gl.elemental.apply_attach(ed, GameConst.Element.HYD, 100.0, {"snapshot": 100.0})
	gl.elemental.apply_attach(ed, GameConst.Element.DEN, 100.0, {"snapshot": 100.0})
	gl.elemental.detect_reactions()             # 绽放挂账（双槽清、cd 2s 起）
	var std_: Variant = ed.elemental
	var armed: bool = bool(std_.bloom_active)
	# 帐窗内再附 FIR（部分 30，不满槽）+ HYD（新元素满槽存续）——蒸发候选成立
	gl.elemental.apply_attach(ed, GameConst.Element.FIR, 30.0, {"snapshot": 100.0})
	gl.elemental.apply_attach(ed, GameConst.Element.HYD, 100.0, {"snapshot": 100.0})
	var hp0 := float(ed.hp)
	var rxn_seen: Array = []
	var cb := func(rxn: int, _pos: Vector2, _uid: int) -> void:
		rxn_seen.append(rxn)
	eb.reaction_triggered.connect(cb)
	var dupe0 := int(gl.pipeline.stats()["dropped_dupe"])
	gl.elemental.tick(0.8)                      # 绽放到期爆发（uid_reaction 落账本帧）
	gl.elemental.detect_reactions()             # 同帧检测 → 蒸发候选（game_loop.gd:217-218 同序）
	var dupe1 := int(gl.pipeline.stats()["dropped_dupe"])
	var hp1 := float(ed.hp)
	eb.reaction_triggered.disconnect(cb)
	_check("D0 前置：绽放已挂账 + FIR(%.0f)/HYD(%.0f) 已附着（armed=%s）"
		% [float(std_.gauges[GameConst.Element.FIR]),
		float(std_.gauges[GameConst.Element.HYD]), str(armed)],
		armed and float(std_.gauges[GameConst.Element.FIR]) > 0.0
		and float(std_.gauges[GameConst.Element.HYD]) > 0.0)
	_check("D1 同帧仅 1 次反应广播（rxn_seen=%s；蒸发被吞则无 FIR_HYD 第二发）"
		% str(rxn_seen),
		rxn_seen == [GameConst.ReactionType.RXN_HYD_DEN])
	_check("D2 管线幂等 dropped_dupe +1（蒸发结算被缓存短路）", dupe1 - dupe0 == 1,
		"Δ=%d" % (dupe1 - dupe0))
	_check("D3 蒸发伤害丢失：hp 只掉绽放一段（Δhp=%.1f，健康口径 ≈300）" % (hp0 - hp1),
		absf((hp0 - hp1) - 150.0) < 1.0, "Δhp=%.1f" % (hp0 - hp1))

	load("res://scripts/meta/run_save.gd").clear()
	gl.free()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	quit(1 if _fail > 0 else 0)


func _resolve_on(p_gl: Node, p_w: Node, p_target: Node) -> float:
	var ctx: Variant = p_w.build_damage_context(p_target)
	ctx.base_atk = 100.0
	ctx.crit_chance = 0.0
	ctx.mult_pools.clear()
	var tctx: Variant = load("res://scripts/combat/trait/trait_context.gd").new()
	tctx.event = GameConst.TraitEvent.ON_HIT
	tctx.weapon = p_w
	tctx.damage_ctx = ctx
	tctx.target = p_target
	if p_w.trait_stack != null:
		for pool in p_w.trait_stack.collect_mult_pools(tctx):
			ctx.mult_pools.append(pool)
	var result: Variant = p_gl.pipeline.call(&"resolve", ctx)
	return float(result.final_value)

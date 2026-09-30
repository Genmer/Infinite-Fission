# tests/runner/test_r199_g6.gd
# R199 G6 元素与技能通道组自测入口（SceneTree 脚本：godot --headless --path <工程>
#   -s tests/runner/test_r199_g6.gd）
# 覆盖（真源 docs/design/R199_RELEASE_SWEEP.md §G6）：
#   D07 玻璃大炮「全部伤害 +40%」全通道落地：DOT 跳伤 / 感电连锁 / 元素反应 /
#       角色技能毒沼绽放 四通道 ×1.4（无遗物基线 vs 激活后）；
#   D14 毒系技能无元素通道：毒沼绽放 / 毒云领域对火免疫敌（E4_volatile elem_immune=2）
#       正常结算（immune=false 且 final>0 且 element==KIN）——原 FIR 通道恒 0 伤回归守卫；
#   F17 燎原传火独立通道：burn_spread_ignited 恰 1 发 + reaction_triggered 零发 +
#       Meta._run_reactions 零虚增 + 图鉴 reaction_seen 零新点亮；
#   H01 毒云特效剩余时长语义：每跳不再重置 left / 结束广播 poison_cloud_end 即入渐隐 /
#       player.gd 云到期（与换角清口）发结束信号。
# 结构说明（同 pkg0~pkg5 / probe_buff5_lianyuan）：-s 脚本模式下入口脚本编译早于
# autoload 全局名注册——入口零游戏类编译期引用（全 Variant 鸭子；唯一常量引用
# GameConst 纯常量脚本），防依赖链提前编译失败。headless 走 Meta 隔离档，收尾清 RunSave。
extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"
const FX_PATH := "res://scripts/gamefeel/elemental_fx_layer.gd"
const ENEMY_PATH := "res://scripts/entities/enemy/enemy.gd"

var _pass: int = 0
var _fail: int = 0


func _initialize() -> void:
	_run()


func _check(p_what: String, p_ok: bool, p_detail: String = "") -> void:
	if p_ok:
		_pass += 1
		print("PASS | %s" % p_what)
	else:
		_fail += 1
		print("FAIL | %s  %s" % [p_what, p_detail])


func _run() -> void:
	print("══════════ R199 G6 元素与技能通道组自测 ══════════")
	await process_frame
	await process_frame
	var eb: Node = root.get_node("EventBus")
	var meta: Node = root.get_node("Meta")
	var gl: Node = (load(MAIN_SCENE) as PackedScene).instantiate()
	gl.name = "GameLoopProbeG6"
	root.add_child(gl)
	gl.state = GameConst.GameStatus.MENU
	gl.start_run()
	var EnemyC: GDScript = load(ENEMY_PATH)

	# ── 敌构造助手（厚血 dummy；register_host 挂元素状态容器） ──
	var mk_enemy := func(p_eid: String, p_pos: Vector2) -> Node2D:
		var e: Node2D = EnemyC.new()
		gl.add_child(e)
		e.spawn(gl.registry.get_enemy(p_eid), 1, 0)
		e.max_hp = 1000000.0
		e.hp = 1000000.0
		e.global_position = p_pos
		gl.elemental.register_host(e)
		return e

	# ── 结算捕获助手（同步块 connect→call→disconnect，零跨帧噪声） ──
	var capture_settle := func(p_call: Callable) -> Array:
		var rows: Array = []
		var cb := func(r: Variant) -> void: rows.append(r)
		eb.damage_resolved.connect(cb)
		p_call.call()
		eb.damage_resolved.disconnect(cb)
		return rows

	var dot_setup := func(p_e: Node2D) -> void:
		var st: Variant = p_e.get("elemental")
		st.burn_layers = 1
		st.burn_dot_ratio = 0.15
		st.burn_snapshot_atk = 4.0
		st.burn_timer = 3.0
		st.burn_tick = 0.5
		st.dot_tick_left = 0.0

	# ══ 阶段 A：无遗物基线 ══
	var e_a1: Node2D = mk_enemy.call(&"E1_grunt", Vector2(300.0, 500.0))
	dot_setup.call(e_a1)
	var dot_rows0: Array = capture_settle.call(func() -> void:
		gl.elemental._dot_tick(e_a1, e_a1.get("elemental")))
	var e_a2: Node2D = mk_enemy.call(&"E1_grunt", Vector2(300.0, 560.0))
	var chain_rows0: Array = capture_settle.call(func() -> void:
		gl.elemental._settle_chain_jump(e_a2, 10.0))
	var e_a3: Node2D = mk_enemy.call(&"E1_grunt", Vector2(300.0, 620.0))
	var rxn_rows0: Array = capture_settle.call(func() -> void:
		gl.elemental._settle_reaction(e_a3, 20.0, 1.5, GameConst.ReactionType.RXN_FIR_HYD))
	var e_a4: Node2D = mk_enemy.call(&"E1_grunt", Vector2(360.0, 500.0))
	gl.enemy_grid.rebuild(_typed([e_a4]))
	gl.player.set("character_id", &"mank")
	var nova_rows0: Array = capture_settle.call(func() -> void:
		gl.player._skill_poison_nova())

	# ══ 阶段 B：激活玻璃大炮（REL_EF_GLASS bonus=0.4）══
	var activated: bool = gl.relic_handler.activate(&"REL_GLASS_CANNON")
	_check("D07 前置：REL_GLASS_CANNON 激活成功", activated)

	var e_b1: Node2D = mk_enemy.call(&"E1_grunt", Vector2(300.0, 500.0))
	dot_setup.call(e_b1)
	var dot_rows1: Array = capture_settle.call(func() -> void:
		gl.elemental._dot_tick(e_b1, e_b1.get("elemental")))
	var e_b2: Node2D = mk_enemy.call(&"E1_grunt", Vector2(300.0, 560.0))
	var chain_rows1: Array = capture_settle.call(func() -> void:
		gl.elemental._settle_chain_jump(e_b2, 10.0))
	var e_b3: Node2D = mk_enemy.call(&"E1_grunt", Vector2(300.0, 620.0))
	var rxn_rows1: Array = capture_settle.call(func() -> void:
		gl.elemental._settle_reaction(e_b3, 20.0, 1.5, GameConst.ReactionType.RXN_FIR_HYD))
	var e_b4: Node2D = mk_enemy.call(&"E1_grunt", Vector2(360.0, 500.0))
	gl.enemy_grid.rebuild(_typed([e_b4]))
	var nova_rows1: Array = capture_settle.call(func() -> void:
		gl.player._skill_poison_nova())

	_check("D07·DOT：基线结算恰 1 笔", dot_rows0.size() == 1 and dot_rows1.size() == 1,
		"%d/%d" % [dot_rows0.size(), dot_rows1.size()])
	if dot_rows0.size() == 1 and dot_rows1.size() == 1:
		var v0 := float(dot_rows0[0].final_value)
		var v1 := float(dot_rows1[0].final_value)
		_check("D07·DOT：燃烧跳伤 ×玻璃大炮 ≈1.4（%s→%s）" % [String.num(v0, 2), String.num(v1, 2)],
			v0 > 0.0 and absf(v1 - v0 * 1.4) <= v0 * 0.01,
			"ratio=%s" % String.num(v1 / maxf(v0, 0.001), 4))
		_check("D07·DOT：结果乘区明细含 glass_dmg（mult_product≈1.4）",
			absf(float(dot_rows1[0].mult_product) - 1.4) <= 0.001,
			"mult=%s" % String.num(float(dot_rows1[0].mult_product), 4))
	_check("D07·连锁：基线结算恰 1 笔", chain_rows0.size() == 1 and chain_rows1.size() == 1,
		"%d/%d" % [chain_rows0.size(), chain_rows1.size()])
	if chain_rows0.size() == 1 and chain_rows1.size() == 1:
		var c0 := float(chain_rows0[0].final_value)
		var c1 := float(chain_rows1[0].final_value)
		_check("D07·连锁：感电跳伤 ×玻璃大炮 ≈1.4（%s→%s）" % [String.num(c0, 2), String.num(c1, 2)],
			c0 > 0.0 and absf(c1 - c0 * 1.4) <= c0 * 0.01,
			"ratio=%s" % String.num(c1 / maxf(c0, 0.001), 4))
	_check("D07·反应：基线结算恰 1 笔", rxn_rows0.size() == 1 and rxn_rows1.size() == 1,
		"%d/%d" % [rxn_rows0.size(), rxn_rows1.size()])
	if rxn_rows0.size() == 1 and rxn_rows1.size() == 1:
		var r0 := float(rxn_rows0[0].final_value)
		var r1 := float(rxn_rows1[0].final_value)
		_check("D07·反应：蒸发结算 ×玻璃大炮 ≈1.4（%s→%s）" % [String.num(r0, 2), String.num(r1, 2)],
			r0 > 0.0 and absf(r1 - r0 * 1.4) <= r0 * 0.01,
			"ratio=%s" % String.num(r1 / maxf(r0, 0.001), 4))
	_check("D07·毒沼绽放：全屏结算恰 1 笔（grid 单敌）",
		nova_rows0.size() == 1 and nova_rows1.size() == 1,
		"%d/%d" % [nova_rows0.size(), nova_rows1.size()])
	if nova_rows0.size() == 1 and nova_rows1.size() == 1:
		var n0 := float(nova_rows0[0].final_value)
		var n1 := float(nova_rows1[0].final_value)
		_check("D07·毒沼绽放：150%% 攻击 ×玻璃大炮 ≈1.4（%s→%s）" % [String.num(n0, 2), String.num(n1, 2)],
			n0 > 0.0 and absf(n1 - n0 * 1.4) <= n0 * 0.01,
			"ratio=%s" % String.num(n1 / maxf(n0, 0.001), 4))

	# ══ 阶段 C：D14 毒系技能 vs 火免疫敌（E4_volatile elem_immune=2）══
	var e_fir1: Node2D = mk_enemy.call(&"E4_volatile", Vector2(360.0, 500.0))
	gl.enemy_grid.rebuild(_typed([e_fir1]))
	gl.player.set("character_id", &"mank")
	var nova_fir: Array = capture_settle.call(func() -> void:
		gl.player._skill_poison_nova())
	var nova_ok := nova_fir.size() >= 1
	if nova_ok:
		for r: Variant in nova_fir:
			if bool(r.immune) or float(r.final_value) <= 0.0 \
					or int(r.element) != GameConst.Element.KIN:
				nova_ok = false
	_check("D14·毒沼绽放：火免疫敌正常结算（immune=false / >0 / KIN 通道）",
		nova_fir.size() >= 1 and nova_ok,
		"rows=%d first.immune=%s first.final=%s first.element=%s" % [nova_fir.size(),
		str(nova_fir[0].immune) if nova_fir.size() > 0 else "-",
		String.num(float(nova_fir[0].final_value), 2) if nova_fir.size() > 0 else "-",
		str(nova_fir[0].element) if nova_fir.size() > 0 else "-"])

	var e_fir2: Node2D = mk_enemy.call(&"E4_volatile", Vector2(360.0, 500.0))
	e_fir2.global_position = (gl.player.global_position as Vector2) + Vector2(40.0, 0.0)
	gl.enemy_grid.rebuild(_typed([e_fir2]))
	gl.player.set("character_id", &"vera")
	var cloud_fir: Array = capture_settle.call(func() -> void:
		gl.player._skill_poison_cloud())
	var cloud_ok := cloud_fir.size() >= 1
	if cloud_ok:
		for r: Variant in cloud_fir:
			if bool(r.immune) or float(r.final_value) <= 0.0 \
					or int(r.element) != GameConst.Element.KIN:
				cloud_ok = false
	_check("D14·毒云领域：火免疫敌首跳正常结算（immune=false / >0 / KIN 通道）",
		cloud_fir.size() >= 1 and cloud_ok,
		"rows=%d first.immune=%s first.final=%s first.element=%s" % [cloud_fir.size(),
		str(cloud_fir[0].immune) if cloud_fir.size() > 0 else "-",
		String.num(float(cloud_fir[0].final_value), 2) if cloud_fir.size() > 0 else "-",
		str(cloud_fir[0].element) if cloud_fir.size() > 0 else "-"])
	gl.player.set("_poison_cloud_left", 0.0)      # 收口毒云（防后续帧再跳）
	gl.player.set("_poison_cloud_tick_left", 0.0)

	# ══ 阶段 D：F17 燎原传火独立通道 ══
	var e_s1: Node2D = mk_enemy.call(&"E1_grunt", Vector2(300.0, 700.0))
	var st_s1: Variant = e_s1.get("elemental")
	st_s1.burn_layers = 3
	st_s1.burn_timer = 3.0
	st_s1.burn_snapshot_atk = 10.0
	st_s1.burn_tick = 0.5
	st_s1.burn_spread_radius = 150.0
	var e_s2: Node2D = mk_enemy.call(&"E1_grunt", Vector2(360.0, 700.0))
	gl.enemy_grid.rebuild(_typed([e_s1, e_s2]))
	var spread_pos: Array = []
	var fake_rxn: Array = []
	var cb_spread := func(p_pos: Vector2) -> void: spread_pos.append(p_pos)
	var cb_rxn := func(_rxn: int, _pos: Vector2, _uid: int) -> void: fake_rxn.append(_rxn)
	eb.burn_spread_ignited.connect(cb_spread)
	eb.reaction_triggered.connect(cb_rxn)
	var rxn_cnt_before := int(meta.get("_run_reactions"))
	var seen_before: bool = meta.is_reaction_seen(&"RXN_FIR_ICE")
	gl.elemental._on_enemy_killed_spread_burn(e_s1)
	eb.burn_spread_ignited.disconnect(cb_spread)
	eb.reaction_triggered.disconnect(cb_rxn)
	_check("F17 前置：传火本体生效（邻居满槽点燃）",
		e_s2.get("elemental") != null and float(e_s2.get("elemental").burn_timer) > 0.0)
	_check("F17：传火走独立通道 burn_spread_ignited 恰 1 发（原点位置）",
		spread_pos.size() == 1 and (spread_pos[0] as Vector2).distance_to(e_s1.global_position) < 1.0,
		"spread=%s" % str(spread_pos))
	_check("F17：reaction_triggered 零误发（不再冒用 RXN_FIR_ICE）", fake_rxn.is_empty(),
		"fake=%s" % str(fake_rxn))
	_check("F17：Meta._run_reactions 零虚增",
		int(meta.get("_run_reactions")) == rxn_cnt_before,
		"%d→%d" % [rxn_cnt_before, int(meta.get("_run_reactions"))])
	_check("F17：图鉴 reaction_seen 零新点亮",
		meta.is_reaction_seen(&"RXN_FIR_ICE") == seen_before,
		"before=%s after=%s" % [str(seen_before),
		str(meta.is_reaction_seen(&"RXN_FIR_ICE"))])

	# ══ 阶段 E：H01 毒云特效剩余时长语义 ══
	var fx: Node2D = (load(FX_PATH) as GDScript).new()
	var dt := 0.05
	var drive := func(p_seconds: float, p_state: Dictionary) -> void:
		var t: float = p_state["t"]
		var tick_left: float = p_state["tick_left"]
		var target := t + p_seconds
		while t < target - 1e-6:
			tick_left -= dt
			if tick_left <= 0.0:
				tick_left += 0.5
				fx._on_poison_cloud_tick(Vector2.ZERO, 300.0)
			fx._tick_poison(dt)
			t += dt
		p_state["t"] = t
		p_state["tick_left"] = tick_left
	var sim := {"t": 0.0, "tick_left": 0.0}
	fx._on_poison_cloud_cast(Vector2.ZERO, 300.0)
	drive.call(3.0, sim)
	var left3 := float(fx.get("_poison")["left"])
	_check("H01：毒云进行中 left 剩余时长衰减（3s 处 ≈3.0，旧口径 ≈5.5+）",
		left3 > 2.8 and left3 < 3.2, "left=%.2f" % left3)
	drive.call(3.0, sim)
	var end_left := float(fx.get("_poison")["left"])
	fx._tick_poison(dt)                           # 尾差一帧：dt 累计和略小于 6.0 时残留亚帧量
	_check("H01：技能 6s 到期特效同步自清（left≈0 / 尾帧后 inactive）",
		end_left < 0.2 and not bool(fx.get("_poison")["active"]),
		"left=%.2f active=%s" % [end_left, str(bool(fx.get("_poison")["active"]))])
	# 结束广播 → 即入渐隐（中途结束场景）
	fx._on_poison_cloud_cast(Vector2.ZERO, 300.0)
	sim = {"t": 0.0, "tick_left": 0.0}
	drive.call(2.0, sim)
	eb.poison_cloud_end.connect(fx._on_poison_cloud_end)
	eb.emit_poison_cloud_end()
	eb.poison_cloud_end.disconnect(fx._on_poison_cloud_end)
	var left_end := float(fx.get("_poison")["left"])
	_check("H01：poison_cloud_end 即入渐隐窗（left 钳 ≤1.5）", left_end <= 1.5 + 1e-6,
		"left=%.2f" % left_end)
	drive.call(1.6, sim)
	_check("H01：结束广播后 1.6s 特效自清", not bool(fx.get("_poison")["active"]))
	fx.free()
	# player.gd 云到期发结束信号（tick 路径）
	var end_fired: Array = []
	var cb_end := func() -> void: end_fired.append(true)
	eb.poison_cloud_end.connect(cb_end)
	gl.player.set("_poison_cloud_left", 0.01)
	gl.player.set("_poison_cloud_tick_left", 9.9)   # 屏蔽同帧结算跳（首跳路径阶段 C 已验）
	gl.player.tick(0.02, Vector2.ZERO)
	_check("H01：player 云到期 tick 发 poison_cloud_end 恰 1 次", end_fired.size() == 1,
		"fired=%d" % end_fired.size())
	# 换角/重开清口路径（_reset_skill_temp_state）
	gl.player.set("_poison_cloud_left", 3.0)
	gl.player._reset_skill_temp_state()
	_check("H01：_reset_skill_temp_state 清毒云发 poison_cloud_end", end_fired.size() == 2,
		"fired=%d" % end_fired.size())
	eb.poison_cloud_end.disconnect(cb_end)

	# ── 收尾 ──
	for e in [e_a1, e_a2, e_a3, e_a4, e_b1, e_b2, e_b3, e_b4, e_fir1, e_fir2, e_s1, e_s2]:
		if e != null and is_instance_valid(e):
			e.queue_free()
	load("res://scripts/meta/run_save.gd").clear()
	gl.free()
	var total := _pass + _fail
	print("R199-G6 汇总：%d/%d 通过" % [_pass, total])
	quit(0 if _fail == 0 else 1)


func _typed(p_arr: Array) -> Array[Node2D]:
	var out: Array[Node2D] = []
	for e: Variant in p_arr:
		out.append(e as Node2D)
	return out

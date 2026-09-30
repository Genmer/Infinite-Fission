# probe_buff5_lianyuan.gd（buff-5 只读体检探针：燎原传火 × R192 反应计数/图鉴污染复核）
# 跑法：tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s probe_buff5_lianyuan.gd
# 视角：元素反应×词条交互——ELE_IGNITE 层2「燎原」词条（burn_spread_radius>0）的传火
# 广播 reaction_triggered(RXN_FIR_ICE)（elemental_system.gd:590），而 Meta 消费口
# （meta_manager.gd:728-740）不滤——复核：反应成就计数 _run_reactions 与图鉴
# reaction_seen 是否被「非反应事件」污染。headless 走 meta_save_test.cfg（隔离档）。
# 纪律：-s 入口脚本编译期先于 autoload 注册——本文件零游戏类编译期引用
#（全 Variant 鸭子；唯一类型引用 GameConst 为纯常量脚本），防依赖链提前编译失败。
extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══ 燎原传火 × R192 反应计数/图鉴 探针 ══")
	await process_frame
	await process_frame
	var eb: Node = root.get_node("EventBus")
	var meta: Node = root.get_node("Meta")
	var scene: PackedScene = load(MAIN_SCENE)
	var gl: Node = scene.instantiate()
	gl.name = "GameLoopProbe"
	root.add_child(gl)
	gl.state = GameConst.GameStatus.MENU
	gl.start_run()

	var rxn_events: Array = []
	var cb := func(rxn: int, _pos: Vector2, _uid: int) -> void:
		rxn_events.append(rxn)
	eb.reaction_triggered.connect(cb)

	var cnt_before := int(meta._run_reactions)
	var seen_before: bool = meta.is_reaction_seen(&"RXN_FIR_ICE")

	# 两只 dummy 敌：e1 燃烧中 + 燎原半径（ELE_IGNITE 2 层形态），e2 = 半径内邻居
	var pool: Node = gl.pools[&"enemy"]
	var e1: Node = pool.acquire()
	var d1: Resource = load("res://scripts/core/data/resources/enemy_data.gd").new()
	d1.id = &"E_PROBE_A"
	d1.hp_base = 100000.0
	d1.spd_base = 0.0
	d1.hitbox_r = 14.0
	e1.spawn(d1, 1, 0)
	e1.position = Vector2(300.0, 500.0)
	gl.elemental.register_host(e1)
	var e2: Node = pool.acquire()
	var d2: Resource = load("res://scripts/core/data/resources/enemy_data.gd").new()
	d2.id = &"E_PROBE_B"
	d2.hp_base = 100000.0
	d2.spd_base = 0.0
	d2.hitbox_r = 14.0
	e2.spawn(d2, 1, 0)
	e2.position = Vector2(360.0, 500.0)
	gl.elemental.register_host(e2)
	var arr: Array[Node2D] = [e1, e2]
	gl.enemy_grid.rebuild(arr)

	var st1: Variant = e1.elemental
	st1.burn_layers = 3
	st1.burn_timer = 3.0
	st1.burn_snapshot_atk = 10.0
	st1.burn_tick = 0.5
	st1.burn_spread_radius = 150.0
	var had_ice: bool = float(st1.gauges[GameConst.Element.ICE]) > 0.0
	var cd_before: int = int(st1.reaction_cd.size())

	# 生产路径同款入口（verify_feedback_cases.gd:2696 同口径直调；该函数生产由
	# EventBus.enemy_killed 驱动——elemental_system.gd:100 订阅）
	gl.elemental._on_enemy_killed_spread_burn(e1)
	await process_frame

	var cnt_after := int(meta._run_reactions)
	var seen_after: bool = meta.is_reaction_seen(&"RXN_FIR_ICE")

	print("PROBE | 传火本体：邻居被点燃（e2.burn_timer>0） = %s（%.1f）"
		% [str(float(e2.elemental.burn_timer) > 0.0), float(e2.elemental.burn_timer)])
	print("PROBE | 前置：目标无冰元素（无碎裂可能） = %s" % str(not had_ice))
	print("PROBE | reaction_triggered 广播：rxn_events=%s" % str(rxn_events))
	print("PROBE | 真反应通道未走：e1.reaction_cd.size() 前后 = %d → %d（含 RXN_FIR_ICE=%s）"
		% [cd_before, int(st1.reaction_cd.size()),
		str(st1.reaction_cd.has(GameConst.ReactionType.RXN_FIR_ICE))])
	print("PROBE | Meta._run_reactions：before=%d after=%d（Δ=%d）"
		% [cnt_before, cnt_after, cnt_after - cnt_before])
	print("PROBE | 图鉴碎裂「已触发」：before=%s after=%s"
		% [str(seen_before), str(seen_after)])

	if float(e2.elemental.burn_timer) > 0.0:
		print("P1 | PASS | 燎原传火本体生效（层2词条行为正常）")
	else:
		print("P1 | FAIL | 燎原传火未生效——探针形态有误，后续结论作废")
	if rxn_events == [GameConst.ReactionType.RXN_FIR_ICE] and not had_ice \
			and not st1.reaction_cd.has(GameConst.ReactionType.RXN_FIR_ICE):
		print("P2 | PASS | 传火广播了 RXN_FIR_ICE（碎裂）而真反应通道未走——伪反应事件实锤")
	else:
		print("P2 | INFO | 传火未广播伪反应事件（rxn_events=%s）" % str(rxn_events))
	if cnt_after > cnt_before:
		print("P3 | PASS | Meta._run_reactions 被传火虚增 +%d——反应成就计数污染实锤"
			% (cnt_after - cnt_before))
	else:
		print("P3 | INFO | 计数未受传火影响")
	if seen_after and not seen_before:
		print("P4 | PASS | 图鉴「碎裂已触发」被传火假点亮（写 codex/reaction_seen 存档键）")
	elif seen_before:
		print("P4 | INFO | before 已 seen（测试档残留，P4 本轮不可判）")
	else:
		print("P4 | INFO | 图鉴未被点亮")

	eb.reaction_triggered.disconnect(cb)
	load("res://scripts/meta/run_save.gd").clear()
	gl.free()
	quit(0)

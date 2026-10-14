# tests/qa_r253_probe_banner.gd — QA 探针（只读，不改产品代码）
# 目的：实证 r238 ④c 红的横幅覆盖时序——复刻「栈满 12 种类后选 MEC_SHIELD 词条卡」
# 序列，记录 mechanics_intro 通道上的两条横幅先后序（词条栏已满 vs 新祝福已解锁）。
# 注：autoload 名（EventBus/PerfGovernor）经 get_node 取——-s 入口脚本编译期不可见。
extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"

var _banners: Array[String] = []


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══ QA probe: r238 ④c banner overwrite order ══")
	var main: Node = load(MAIN_SCENE).instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	var gl: GameLoop = null
	for c in root.get_children():
		if c is GameLoop:
			gl = c
			break
	if gl == null:
		print("PROBE-FAIL no GameLoop")
		quit(1)
		return
	gl.state = GameConst.GameStatus.MENU
	var perf: Node = root.get_node_or_null("/root/PerfGovernor")
	if perf != null:
		perf.call(&"set_process", false)
	GameLoop.SIM_30HZ_ENABLED = false
	GameLoop.sim30_override = -1
	var bus: Node = root.get_node("/root/EventBus")
	var spy := func(t: String) -> void:
		_banners.append(t)
	bus.connect(&"mechanics_intro", spy)
	# 前置：W1 装备 + 栈填 12 种类 ADD 词条（帽满）——仿 r238 ④ 组夹具
	var p := gl.player
	var w1: WeaponBase = p.weapon_slots[0]
	var filled := 0
	for tid_v: Variant in gl.registry.traits.keys():
		var tid := StringName(String(tid_v))
		var td: TraitData = gl.registry.get_trait(tid)
		if td == null or int(td.pool) != GameConst.PoolClass.ADD:
			continue
		if w1.attach_trait(td.duplicate() as TraitData):
			filled += 1
		if filled >= 12:
			break
	print("prefill kinds=%d (need 12)" % filled)
	_banners.clear()
	var card: Dictionary = gl.card_generator._make_trait_card(&"MEC_SHIELD", 1, w1)
	gl.card_generator.apply_choice(card, p)
	for i in range(_banners.size()):
		print("banner[%d] = %s" % [i, _banners[i]])
	var has_full_note: bool = false
	var has_bless_note: bool = false
	for b in _banners:
		if b.contains("词条栏已满"):
			has_full_note = true
		if b.contains("新祝福已解锁"):
			has_bless_note = true
	var overwrite: bool = _banners.size() >= 2 and _banners[_banners.size() - 1].contains("新祝福已解锁")
	print("RESULT: full_note=%s bless_note=%s bless_last=%s → %s" % [str(has_full_note),
		str(has_bless_note), str(overwrite),
		"词条栏已满横幅被祝福解锁播报覆盖（④c 根因实证）" if overwrite else "无覆盖"])
	bus.disconnect(&"mechanics_intro", spy)
	quit(0)

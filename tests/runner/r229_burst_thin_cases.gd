# tests/runner/r229_burst_thin_cases.gd
# R229 粒子满载门收口用例体（入口 test_r229_burst_thin.gd 运行时 load——-s 编译期
# 禁引工程类名纪律）。验收锚（acceptance 逐点）：
# ① 门开态（burst_thin_override=-3 + PerfGovernor.tier_override=2 + mode_override=0）：
#    8 次 EventBus.damage_resolved(is_crit) → burst_requests +2（CRIT 1/4）；
#    8 次 on_enemy_killed（普通敌）→ +2（1/4）；精英 8 次 → +4（1/2，刀面③）；
#    8 次 reaction_triggered → +4（1/2）；Boss tag 击杀 → 1/1（全保留）。
# ② 负向锚（零扰动）：无任何注入的桌面 headless 缺省下同序列 → 8/8/8/1；
#    burst_thin_override=-2（用户否决档）注入态（含 tier/mode 注入同置）→ 同样全过。
# ③ 顿帧/震屏/色差路径零触碰：门开态被采样砍掉的爆闪事件，顿帧/色差照发；
#    Boss 击杀顿帧（120ms）与爆闪全保留。
# ④ 既有语义零扰动：R213 满载门（非 CRIT）源级锚不动；mobile 中档 1/2 隔次
#    （_thin_burst_tick 共享计数器）门关时逐位保持；particle_director 遥测不动。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const N := 8                                   # 采样窗口（8 次/段——1/4→2、1/2→4 确定窗）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


class TagNode extends Node2D:
	# on_enemy_killed 最小桩：tags 属性 + global_position（不入树——不触发死亡归还管线）
	var tags: int = 0


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	PerfGovernor.set_process(false)             # 引擎侧停走——tier 真值不被采样漂移（r223 先例）
	# fx_quality 显式钉高档 2（feel_cases 先例：headless 档位存 user://meta_save_test.cfg
	# 跨套件残留 0/1 会让中档隔次计数器混入负向锚——8/8/8/1 口径要求高档零采样）
	Meta.set_setting("fx_quality", 2)
	_gl.state = GameConst.GameStatus.MENU       # 静止环境（真武器零开火零自然事件）
	_test_1_gate_sentinel_mapping()
	_test_2_thin_on_sampling()
	_test_3_negative_default()
	_test_4_negative_veto()
	_test_5_feel_paths_zero_touch()
	_test_6_midtier_alternate_untouched()
	_test_7_source_anchors()
	await _cleanup()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s（%s）" % [p_name, p_detail])
		print("  FAIL | %s（%s）" % [p_name, p_detail])


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R229GameLoopUnderTest"
	tree.get_root().add_child(_gl)              # _ready → boot（game_feel.setup + 粒子注入完成）


# ── 夹具 ──────────────────────────────────────────────────────────

func _gf() -> GameFeelDirector:
	return _gl.game_feel


func _bursts() -> int:
	return _gf().particles.burst_requests


func _thinned() -> int:
	return DebugStats.get_counter(&"burst_thinned")


func _mk_crit_result(p_seq: int) -> DamageResult:
	var r := DamageResult.new()
	r.final_value = 3.0
	r.is_crit = true
	r.feel_level = GameConst.FeelLevel.CRIT
	r.target_uid = 929000 + p_seq
	r.pos = Vector2(300.0, 600.0)
	r.popup_style = GameConst.PopupStyle.NORMAL
	return r


func _emit_crits(p_n: int) -> int:
	# EventBus.damage_resolved 真派发（验收①字面口径——全订阅链在环）
	var b0 := _bursts()
	for i in p_n:
		EventBus.damage_resolved.emit(_mk_crit_result(i))
	return _bursts() - b0


func _kill_bursts(p_tags: int, p_n: int) -> int:
	# on_enemy_killed 直调（不入树桩——不触发 spawner 归还/XP/彩纸等旁路订阅）
	var b0 := _bursts()
	var stub := TagNode.new()
	stub.tags = p_tags
	stub.position = Vector2(300.0, 600.0)
	for i in p_n:
		_gf().on_enemy_killed(stub)
	stub.free()
	return _bursts() - b0


func _rxn_bursts(p_n: int) -> int:
	var b0 := _bursts()
	for i in p_n:
		_gf().on_reaction_triggered(GameConst.ReactionType.RXN_FIR_ICE,
			Vector2(300.0, 600.0), 929500 + i)
	return _bursts() - b0


func _reset_injections() -> void:
	GameFeelDirector.burst_thin_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.tier = 3


# ── ① 哨兵四档 + 三重门映射（直读 _burst_thin_on——r223 ⑦ 同构） ──

func _test_1_gate_sentinel_mapping() -> void:
	print("── ① 哨兵四档 + 三重门映射 ──")
	_reset_injections()
	_check("①缺省 -1（真值门）：headless 非 mobile → 恒关（桌面零扰动前提）",
		GameFeelDirector._burst_thin_on() == false,
		"on=%s" % str(GameFeelDirector._burst_thin_on()))
	GameFeelDirector.burst_thin_override = -2
	_check("①-2 用户否决档 → 恒关（压过 tier/mode 注入）",
		GameFeelDirector._burst_thin_on() == false,
		"on=%s" % str(GameFeelDirector._burst_thin_on()))
	GameFeelDirector.burst_thin_override = 1
	_check("①1 强制开 → 恒开（探针档）",
		GameFeelDirector._burst_thin_on() == true,
		"on=%s" % str(GameFeelDirector._burst_thin_on()))
	GameFeelDirector.burst_thin_override = -3
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 3
	_check("①-3 模拟 mobile：tier3 → 关（高档不动）",
		not GameFeelDirector._burst_thin_on(), "")
	PerfGovernor.tier_override = 2
	_check("①-3 模拟 mobile：帧率优先 ∧ tier2 → 开",
		GameFeelDirector._burst_thin_on() == true, "")
	PerfGovernor.tier_override = 1
	_check("①-3 模拟 mobile：tier1 → 开（tier≤2 同门）",
		GameFeelDirector._burst_thin_on() == true, "")
	PerfGovernor.mode_override = 1
	_check("①-3 模拟 mobile：特效优先（mode=1）→ 关",
		not GameFeelDirector._burst_thin_on(), "")
	PerfGovernor.mode_override = -1
	_check("①-3 + 真值模式回读（headless 缺省帧率优先）∧ tier1 → 开",
		GameFeelDirector._burst_thin_on() == true, "")
	# 真值路径 OS 门密封：override=-1 时即使 tier/mode 注入（模拟深载档）桌面也关
	GameFeelDirector.burst_thin_override = -1
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	_check("①真值路径 OS 门密封：-1 ∧ tier2 ∧ 帧率优先 → headless 仍关",
		not GameFeelDirector._burst_thin_on(), "")
	_reset_injections()


# ── ② 门开态三路采样（验收①：2/2/4/4 + Boss 1/1） ─────────────────

func _test_2_thin_on_sampling() -> void:
	print("── ② 门开态三路采样（-3 + tier_override=2 + mode_override=0） ──")
	GameFeelDirector.burst_thin_override = -3
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	_check("②前置：注入态门开读数", GameFeelDirector._burst_thin_on() == true, "")
	var t0 := _thinned()
	var crit_n := _emit_crits(N)
	_check("②8 次 EventBus.damage_resolved(is_crit) → burst_requests +2（CRIT 1/4）",
		crit_n == 2, "+%d（期望 2）" % crit_n)
	var kill_n := _kill_bursts(0, N)
	_check("②8 次 on_enemy_killed（普通敌）→ +2（KILL 1/4）",
		kill_n == 2, "+%d（期望 2）" % kill_n)
	var elite_n := _kill_bursts(GameConst.TAG_ELITE, N)
	_check("②8 次精英击杀 → +4（KILL 1/2——刀面③采样档）",
		elite_n == 4, "+%d（期望 4）" % elite_n)
	var rxn_n := _rxn_bursts(N)
	_check("②8 次 reaction_triggered → +4（反应 1/2）",
		rxn_n == 4, "+%d（期望 4）" % rxn_n)
	var boss_b0 := _bursts()
	var boss_stub := TagNode.new()
	boss_stub.tags = GameConst.TAG_BOSS
	_gf().on_enemy_killed(boss_stub)
	boss_stub.free()
	_check("②Boss tag 击杀 → 1/1（全保留）",
		_bursts() - boss_b0 == 1, "+%d（期望 1）" % (_bursts() - boss_b0))
	var thinned_delta := _thinned() - t0
	_check("②burst_thinned 判读口计数（6+6+4+4+0=20）",
		thinned_delta == 20, "+%d（期望 20）" % thinned_delta)
	_reset_injections()


# ── ③ 负向锚 A：无注入桌面缺省 8/8/8/1（零扰动） ───────────────────

func _test_3_negative_default() -> void:
	print("── ③ 负向锚：无任何注入桌面 headless 缺省 ──")
	_reset_injections()
	_check("③前置：缺省门关读数", not GameFeelDirector._burst_thin_on(), "")
	var t0 := _thinned()
	var crit_n := _emit_crits(N)
	var kill_n := _kill_bursts(0, N)
	var rxn_n := _rxn_bursts(N)
	var boss_b0 := _bursts()
	var boss_stub := TagNode.new()
	boss_stub.tags = GameConst.TAG_BOSS
	_gf().on_enemy_killed(boss_stub)
	boss_stub.free()
	var boss_n := _bursts() - boss_b0
	_check("③同序列全通过（8/8/8/1——桌面缺省零扰动）",
		crit_n == 8 and kill_n == 8 and rxn_n == 8 and boss_n == 1,
		"crit+%d kill+%d rxn+%d boss+%d（期望 8/8/8/1）" % [crit_n, kill_n, rxn_n, boss_n])
	_check("③零削减计数（burst_thinned 不增）", _thinned() == t0,
		"+%d（期望 0）" % (_thinned() - t0))


# ── ④ 负向锚 B：-2 用户否决档注入态（含 tier/mode 同置） ───────────

func _test_4_negative_veto() -> void:
	print("── ④ 负向锚：burst_thin_override=-2（用户否决档）注入态 ──")
	# 最强形态：否决档与「模拟 mobile 深载」注入同置——-2 必须压过 tier/mode 分支
	GameFeelDirector.burst_thin_override = -2
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	_check("④前置：-2 + tier2 + 帧率优先 → 门关（否决压过模拟 mobile）",
		not GameFeelDirector._burst_thin_on(), "")
	var t0 := _thinned()
	var crit_n := _emit_crits(N)
	var kill_n := _kill_bursts(0, N)
	var rxn_n := _rxn_bursts(N)
	var boss_b0 := _bursts()
	var boss_stub := TagNode.new()
	boss_stub.tags = GameConst.TAG_BOSS
	_gf().on_enemy_killed(boss_stub)
	boss_stub.free()
	var boss_n := _bursts() - boss_b0
	_check("④否决档同序列全通过（8/8/8/1）",
		crit_n == 8 and kill_n == 8 and rxn_n == 8 and boss_n == 1,
		"crit+%d kill+%d rxn+%d boss+%d（期望 8/8/8/1）" % [crit_n, kill_n, rxn_n, boss_n])
	_check("④否决档零削减计数", _thinned() == t0,
		"+%d（期望 0）" % (_thinned() - t0))
	_reset_injections()


# ── ⑤ 顿帧/震屏/色差零触碰（门只砍粒子，反馈层照发） ────────────────

func _test_5_feel_paths_zero_touch() -> void:
	print("── ⑤ 顿帧/色差零触碰（被采样砍掉的爆闪事件反馈照发） ──")
	GameFeelDirector.burst_thin_override = -3
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	# CRIT 路：连续两次恰一发被 1/4 砍（任意相位连续 2 窗内恰 1 过）——顿帧/色差照发。
	# 隔离 R188 密集场自动关（_crit_stop_dense：②-④ 段已累计 24 条 CRIT 顿帧申请且
	# 池预热敌在树 live_count=128 ≥40 → dense 吃掉顿帧——与本刀无关，清滚动窗聚焦 R229）
	(_gf().get("_crit_stop_times") as Array).clear()
	_gf().hit_stop_left = 0.0
	var b0 := _bursts()
	_gf().on_damage_resolved(_mk_crit_result(90))
	_gf().on_damage_resolved(_mk_crit_result(91))
	var crit_two := _bursts() - b0
	_check("⑤门开 CRIT 连发 2 → 爆闪恰 1（1/4 采样相位确定）",
		crit_two == 1, "+%d（期望 1）" % crit_two)
	_check("⑤被砍 CRIT 顿帧照发（hit_stop_left > 0——采样只砍粒子）",
		_gf().hit_stop_left > 0.0, "left=%.3f" % _gf().hit_stop_left)
	_check("⑤被砍 CRIT 色差照发（current_ca_intensity > 0）",
		_gf().current_ca_intensity > 0.0, "ca=%.5f" % _gf().current_ca_intensity)
	# 反应路：连续两次恰一发被 1/2 砍——CATALYST 顿帧照发
	_gf().hit_stop_left = 0.0
	var b1 := _bursts()
	_gf().on_reaction_triggered(GameConst.ReactionType.RXN_FIR_ICE, Vector2.ZERO, 929600)
	_gf().on_reaction_triggered(GameConst.ReactionType.RXN_FIR_ICE, Vector2.ZERO, 929601)
	var rxn_two := _bursts() - b1
	_check("⑤门开反应连发 2 → 爆闪恰 1（1/2 采样）",
		rxn_two == 1, "+%d（期望 1）" % rxn_two)
	_check("⑤被砍反应顿帧照发（CATALYST 50ms）",
		_gf().hit_stop_left > 0.0, "left=%.3f" % _gf().hit_stop_left)
	# 精英击杀路：连续两次恰一发被 1/2 砍——CRIT 档顿帧照发
	_gf().hit_stop_left = 0.0
	var b2 := _bursts()
	var elite_stub := TagNode.new()
	elite_stub.tags = GameConst.TAG_ELITE
	_gf().on_enemy_killed(elite_stub)
	_gf().on_enemy_killed(elite_stub)
	elite_stub.free()
	var elite_two := _bursts() - b2
	_check("⑤门开精英连杀 2 → 爆闪恰 1（1/2 采样）",
		elite_two == 1, "+%d（期望 1）" % elite_two)
	_check("⑤被砍精英击杀顿帧照发（CRIT 档）",
		_gf().hit_stop_left > 0.0, "left=%.3f" % _gf().hit_stop_left)
	# Boss 路：全保留——120ms 顿帧与爆闪同发
	_gf().hit_stop_left = 0.0
	var b3 := _bursts()
	var boss_stub := TagNode.new()
	boss_stub.tags = GameConst.TAG_BOSS
	_gf().on_enemy_killed(boss_stub)
	boss_stub.free()
	_check("⑤Boss 击杀爆闪全保留（+1）", _bursts() - b3 == 1,
		"+%d（期望 1）" % (_bursts() - b3))
	_check("⑤Boss 击杀 120ms 顿帧照发（on_boss_death_feel 零触碰）",
		_gf().hit_stop_left >= 0.119, "left=%.3f" % _gf().hit_stop_left)
	_reset_injections()


# ── ⑥ 既有 mobile 中档 1/2 隔次语义零扰动（门关时逐位保持） ─────────

func _test_6_midtier_alternate_untouched() -> void:
	print("── ⑥ 门关时中档 1/2 隔次（_thin_burst_tick）逐位保持 ──")
	_reset_injections()
	Meta.set_setting("fx_quality", 1)           # 中档：隔次削减（CRIT/普命中共享计数器）
	var r := DamageResult.new()
	r.final_value = 3.0
	r.target_uid = 929700
	r.pos = Vector2(300.0, 600.0)
	r.feel_level = GameConst.FeelLevel.CRIT
	r.is_crit = true
	var b0 := _bursts()
	for i in N:
		r.target_uid = 929700 + i
		_gf().on_damage_resolved(r)
	var crit_n := _bursts() - b0
	r.is_crit = false
	r.feel_level = GameConst.FeelLevel.HIT
	for i in N:
		r.target_uid = 929800 + i
		_gf().on_damage_resolved(r)
	var hit_n := _bursts() - b0 - crit_n
	_check("⑥中档门关：CRIT 8 次 → +4（旧 1/2 隔次逐位不变）",
		crit_n == 4, "+%d（期望 4）" % crit_n)
	_check("⑥中档门关：普命中 8 次 → +4（旧 1/2 隔次逐位不变）",
		hit_n == 4, "+%d（期望 4）" % hit_n)
	Meta.set_setting("fx_quality", 2)           # 档位回出厂高档（r213 teardown 同口径）


# ── ⑦ 源级锚：冻结面不动 ─────────────────────────────────────────

func _test_7_source_anchors() -> void:
	print("── ⑦ 源级锚（R213 满载门 / 遥测 / Boss 保留结构） ──")
	var gf := FileAccess.open("res://scripts/gamefeel/game_feel_director.gd", FileAccess.READ)
	var gf_src := gf.get_as_text() if gf != null else ""
	gf.close()
	_check("⑦R213 满载门源级锚不动（非 CRIT 普命中 return 逐字保持）",
		gf_src.contains("fullload_dim() and not p_result.is_crit"),
		"缺 R213 B1 门锚")
	_check("⑦R229 门在顿帧/震屏/色差之后（调用点序——采样只砍粒子）",
		gf_src.find("if p_result.is_crit and _burst_thin_on():") > gf_src.find("add_trauma_for_level(level)"),
		"门序错位")
	_check("⑦Boss tag 保留结构在位（TAG_BOSS 例外分支）",
		gf_src.contains("(tags & GameConst.TAG_BOSS) == 0"),
		"缺 Boss 保留锚")
	var pd := FileAccess.open("res://scripts/gamefeel/particle_director.gd", FileAccess.READ)
	var pd_src := pd.get_as_text() if pd != null else ""
	pd.close()
	_check("⑦particle_director 遥测不动（burst_requests/dropped_requests 双计数在位）",
		pd_src.contains("burst_requests += 1") and pd_src.contains("dropped_requests += 1"),
		"遥测锚缺失")


func _cleanup() -> void:
	_reset_injections()
	PerfGovernor.transitions = 0
	PerfGovernor._ema_inject = -1.0
	PerfGovernor._test_reset()
	PerfGovernor.set_process(true)
	Meta.set_setting("fx_quality", 2)
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null
	await tree.process_frame

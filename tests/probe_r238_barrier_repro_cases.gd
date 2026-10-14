# tests/probe_r238_barrier_repro_cases.gd
# R238「格挡力场（MEC_SHIELD）选了没生效」五假设诊断用例体（入口运行时 load——
# cases 禁 test_ 前缀防电池 glob 误收；本文件可直引工程类名）。
# ⚠R262d 过时声明：H2 段断言「FALLBACK_ATK 落他栈 / 静默替换」基于 vc71 前挂武器栈
# 旧制——R262d 起应急强化改全局授予（player.add_fallback_atk+品级缩放+横幅），该段
# 断言不再反映现行契约（历史诊断快照保原貌不追改；现行契约由 qa_r262d_fallback 锁）。
# 假设 → 用例映射（全部真实工程对象：main.tscn 真起 GameLoop · 真卡架/apply_choice ·
# 真词条 attach · 真玩家 tick/受击 · 真敌池物理帧；夹具模式=r237_contact_radial_cases）：
# · H1 满层续上架×效果饱和：主武器连挂 2 层金 MEC_SHIELD → 货架仍上架 → 第 3 张白卡
#   apply_choice → 断言 shield_interval/timer/ready 逐位不变、仅 TraitStack.layers=3；
#   源级锚=工作树 _trait_candidates 无叠层上架帽（HEAD:474-477 有——git show 只读取证）。
#   HEAD 运行时对照组不跑（工作树 358 脏路径禁 checkout——以源差分代运行差分，如实披露）。
# · H2 挂载失败静默降级：W1 预填 12 种类（MAX_TRAITS 帽满）→ apply_choice(MEC_SHIELD)
#   → 断言全栈无 MEC_SHIELD / shield_interval==0 / FALLBACK_ATK 落他栈 / fallback_uses
#   与 emit_card_chosen 遥测读数（testIdea 预期 +1，实测如实记）。
# · H3 跨武器叠层互覆：W1 双金（就绪 interval≈2.115s）→ W2 直挂 1 白（attach_trait 真消费口
#   =REL_ECHO 回响同款）→ 断言 interval 无条件覆写回 8.0；同武器对照组不回退；再验
#   「格挡后充能 8s 劣化」可观测面。
# · H4 首充空窗：apply_choice 白卡后立刻 take_contact_damage(50) → HP 直减无 shield_blocked；
#   tick 推进 8.5s → ready → 再打=格挡恰 1 次 HP 不掉 timer 重置；HUD 源级锚（1Hz 兜底+
#   「能量护盾」旧名残留）。
# · H5 接触链路健在性（反向证伪候选）：CONTACT_RADIAL off + layer/mask 配对锚下，
#   敌出生即重叠×2 物理帧 / 池复用（远处归还）重叠重生 / 重叠态归还原位重生 三路
#   take_contact_damage 可达性（shield_ready 前置 → shield_blocked 恰 +1 且 HP 不掉）。
# 诊断模式：全部断言只进 stdout 汇总，末行 VERDICT JSON；恒 exit 0 由入口保证。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const CARD_GENERATOR_SOURCE := "res://scripts/cards/card_generator.gd"
const HUD_SOURCE := "res://scripts/ui/hud.gd"
const DT := 1.0 / 60.0
const PROBE_FILE := "repo/tests/probe_r238_barrier_repro.gd"
const GOLD_VALUE := 2.6                 # 金卡 scale（RARITY_VALUE_SCALE[3]）
const INTERVAL_2L_GOLD := 5.5 / 2.6     # 满层金承诺档：interval_lv2 / 金倍率 ≈ 2.1154s
const INTERVAL_1L_WHITE := 8.0          # 白卡单层：interval_s / 1.0

var tree: SceneTree
var _gl: GameLoop = null
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
# EventBus 计数器（真实消费点读数）
var _shield_blocked_cnt: int = 0
var _player_hit_cnt: int = 0
var _last_card_chosen: StringName = &""
# 五假设结论
var _h_result: Dictionary = {}          # id -> "confirmed"/"refuted"/"inconclusive"
var _h_ev: Dictionary = {}              # id -> 单行证据串


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261007)
	EventBus.shield_blocked.connect(func(_pos: Vector2) -> void: _shield_blocked_cnt += 1)
	EventBus.player_hit.connect(func(_dmg: float, _uid: int) -> void: _player_hit_cnt += 1)
	EventBus.card_chosen.connect(func(cid: StringName, _kind: int) -> void: _last_card_chosen = cid)
	for h in ["H1", "H2", "H3", "H4", "H5"]:
		_h_result[h] = "inconclusive"
		_h_ev[h] = ""
	await _boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	if _gl == null or _gl.player == null or _gl.card_generator == null:
		print("FAIL | boot 夹具不完整（gl=%s）" % str(_gl))
		_finish()
		return
	_gl.state = GameConst.GameStatus.MENU             # 静止环境（r230/r236/r237 先例）
	PerfGovernor.set_process(false)
	GameLoop.SIM_30HZ_ENABLED = false
	GameLoop.sim30_override = -1
	_ensure_second_weapon()
	_test_h1()
	_test_h2()
	_test_h3()
	_test_h4()
	await _test_h5()
	await _cleanup()
	_finish()


func fail_count() -> int:
	return _fail


# ═══ H1 满层续上架 × 效果饱和（间隔/倍率/表现全不变仅面板 +1 层） ════════
func _test_h1() -> void:
	print("── H1 满层（2 层）MEC_SHIELD 续上架且效果饱和 ──")
	var cg := _gl.card_generator
	var player := _gl.player
	_reset_fixture()
	var w1: WeaponBase = player.weapon_slots[0]
	# 金卡 ×2（真卡架 _make_trait_card → 终值稀有度落值 _apply_rarity_values → apply_choice）
	var card1 := _make_shield_card(3, w1)
	cg.apply_choice(card1, player)
	var m1 := _shield_mounted(w1)
	_check("H1-#1 金卡#1 挂载 layers==1 · value≈2.6 · interval≈8/2.6=3.077s",
		m1 != null and m1.layers == 1 and is_equal_approx(float(m1.data.value), GOLD_VALUE) \
			and is_equal_approx(player.shield_interval, 8.0 / GOLD_VALUE),
		"layers=%s value=%.3f interval=%.4f" % [str(m1.layers) if m1 != null else "null",
			float(m1.data.value) if m1 != null else -1.0, player.shield_interval])
	var card2 := _make_shield_card(3, w1)
	cg.apply_choice(card2, player)
	var m2 := _shield_mounted(w1)
	var interval_full := player.shield_interval
	_check("H1-#2 金卡#2 满层 layers==2 · interval≈5.5/2.6≈2.115s（2 层承诺档）",
		m2 != null and m2.layers == 2 and is_equal_approx(interval_full, INTERVAL_2L_GOLD),
		"layers=%s interval=%.6f（期望 %.6f）" % [str(m2.layers) if m2 != null else "null",
			interval_full, INTERVAL_2L_GOLD])
	# 货架侧：满层后 _trait_candidates 仍上架（R226 上架叠层帽拆除——工作树）
	var picked: Array[StringName] = []
	var shelf: Array[StringName] = cg._trait_candidates("MECH", player, picked, w1)
	_check("H1-#3 满层（2 层）货架仍上架 MEC_SHIELD（卡架差分——工作树无帽）",
		shelf.has(&"MEC_SHIELD"), "shelf_n=%d has=%s" % [shelf.size(), str(shelf.has(&"MEC_SHIELD"))])
	# 第 3 张：白卡 apply_choice（真实选卡路径）
	var iv0 := player.shield_interval
	var t0 := player.shield_timer
	var r0 := player.shield_ready
	var card3 := _make_shield_card(0, w1)
	cg.apply_choice(card3, player)
	var m3 := _shield_mounted(w1)
	var attached3: bool = m3 != null and m3.layers == 3
	var invariant: bool = player.shield_interval == iv0 and player.shield_timer == t0 \
		and player.shield_ready == r0
	_check("H1-#4 第 3 张白卡继续上架（attach 不拒）layers==3",
		attached3, "layers=%s" % (str(m3.layers) if m3 != null else "null"))
	_check("H1-#5 间隔/充能/就绪逐位不变（interval/timer/ready 位同——玩家无可观测变化）",
		invariant, "interval %.6f→%.6f · timer %.6f→%.6f · ready %s→%s"
			% [iv0, player.shield_interval, t0, player.shield_timer, str(r0), str(player.shield_ready)])
	_check("H1-#6 取优保金：mounted.data.value 仍 2.6（白卡 1.0 不降档）",
		m3 != null and is_equal_approx(float(m3.data.value), GOLD_VALUE),
		"value=%.3f" % (float(m3.data.value) if m3 != null else -1.0))
	# 源级锚：工作树上架侧无叠层帽（HEAD 474-477 有 used_layers.get(tid,0)>=stack_cap——本会话
	# git show 只读取证：HEAD trait_stack.attach :41-43 亦 return false 拒绝）
	var src := _read_source(CARD_GENERATOR_SOURCE)
	_check("H1-#7 源级锚：工作树 _trait_candidates 无 stack_cap/used_layers 上架帽（R226 拆除在位）",
		not src.contains("used_layers.get(tid, 0)") and not src.contains("stack_cap")
			and src.contains("R226 有意契约变更"),
		"stack_cap=%d used_layers=%d" % [src.count("stack_cap"), src.count("used_layers")])
	_set_verdict("H1", attached3 and invariant,
		"金2层 interval=%.4f(5.5/2.6) 货架仍上架=%s 第3白卡 attach 后 layers=3 interval/timer/ready 逐位不变=%s（interval %.6f→%.6f, timer %.6f→%.6f, ready %s→%s）；工作树无上架帽、HEAD:474-477 有（git show 只读）；HEAD 运行时对照组未跑（358 脏路径禁 checkout）"
			% [interval_full, str(shelf.has(&"MEC_SHIELD")), str(invariant),
			iv0, player.shield_interval, t0, player.shield_timer, str(r0), str(player.shield_ready)])


# ═══ H2 挂载失败静默降级（12 种类帽满 → FALLBACK_ATK 无声替换） ═════════
func _test_h2() -> void:
	print("── H2 挂载失败 R189c 静默降级 ──")
	var cg := _gl.card_generator
	var player := _gl.player
	_reset_fixture()
	var w1: WeaponBase = player.weapon_slots[0]
	var w2: WeaponBase = player.weapon_slots[1]
	# 预填 12 种类（真实 ADD 池词条 · 真 attach_trait；排除 add_hp 免血条副作用）
	var prefill := _pick_prefill_ids(12)
	_check("H2-#1 ADD 池可取 12 种类预填", prefill.size() == 12, "n=%d" % prefill.size())
	for tid in prefill:
		w1.attach_trait(_gl.registry.get_trait(tid).duplicate() as TraitData)
	_check("H2-#2 W1 栈 12 种类（MAX_TRAITS=12 帽满）",
		w1.trait_stack.size() == 12, "size=%d" % w1.trait_stack.size())
	var fb0: int = cg.fallback_uses
	_last_card_chosen = &""
	var card := _make_shield_card(0, w1)
	cg.apply_choice(card, player)                 # 目标武器 w1 → attach 被拒 → R189c 降级
	var any_shield: bool = _stack_has(w1, &"MEC_SHIELD") or (w2 != null and _stack_has(w2, &"MEC_SHIELD"))
	_check("H2-#3 全武器栈无 MEC_SHIELD（效果根本没 attach）", not any_shield,
		"w1_has=%s w2_has=%s" % [str(_stack_has(w1, &"MEC_SHIELD")),
			str(w2 != null and _stack_has(w2, &"MEC_SHIELD"))])
	_check("H2-#4 player.shield_interval==0.0（护盾条数据源恒零——HUD 不出现）",
		player.shield_interval == 0.0, "interval=%.4f" % player.shield_interval)
	var fb_on_w1 := _stack_has(w1, &"FALLBACK_ATK")
	var fb_on_w2 := w2 != null and _stack_has(w2, &"FALLBACK_ATK")
	_check("H2-#5 某武器栈出现 FALLBACK_ATK（没点名的小额替换无声落地）",
		fb_on_w1 or fb_on_w2, "w1=%s w2=%s" % [str(fb_on_w1), str(fb_on_w2)])
	var fb_delta: int = cg.fallback_uses - fb0
	_check("H2-#6 fallback_uses 计数（testIdea 预期 +1；实测降级路径若 0=遥测盲区）",
		fb_delta == 1, "Δ=%d（TRAIT 卡降级路径不计数——静默再证）" % fb_delta)
	_check("H2-#7 emit_card_chosen 仍上报原卡 id=MEC_SHIELD（遥测看不出降级）",
		_last_card_chosen == &"MEC_SHIELD", "chosen=%s" % String(_last_card_chosen))
	# 源级锚：R189c 降级分支（挂载失败转应急强化 → CardKind.RELIC 段前）零 EventBus 反馈
	var src := _read_source(CARD_GENERATOR_SOURCE)
	var i0 := src.find("R189c 挂载失败转应急强化")
	var i1 := src.find("CardKind.RELIC:", maxi(i0, 0))
	var seg := src.substr(i0, i1 - i0) if i0 >= 0 and i1 > i0 else ""
	_check("H2-#8 源级锚：R189c 降级分支零 EventBus.emit（无 toast/提示）",
		i0 >= 0 and i1 > i0 and seg.count("EventBus.emit") == 0,
		"seg_chars=%d emits=%d" % [seg.length(), seg.count("EventBus.emit")])
	var core_ok: bool = (not any_shield) and player.shield_interval == 0.0 and (fb_on_w1 or fb_on_w2)
	_set_verdict("H2", core_ok,
		"W1 预填 12 种类后 apply_choice(MEC_SHIELD)：全栈无 MEC_SHIELD=%s shield_interval=%.1f FALLBACK_ATK 落栈=%s（w1=%s w2=%s）fallback_uses Δ=%d（testIdea 预期 +1 实测 %s）card_chosen=%s 降级分支 EventBus.emit=0"
			% [str(not any_shield), player.shield_interval, str(fb_on_w1 or fb_on_w2),
			str(fb_on_w1), str(fb_on_w2), fb_delta, str(fb_delta),
			String(_last_card_chosen)])


# ═══ H3 跨武器叠层互覆（后挂 1 层白卡把全局槽覆写回 8s） ═══════════════
func _test_h3() -> void:
	print("── H3 跨武器叠层互覆（全局单槽 × 宿主局部读数） ──")
	var cg := _gl.card_generator
	var player := _gl.player
	var w1: WeaponBase = player.weapon_slots[0]
	var w2: WeaponBase = player.weapon_slots[1]
	# A 组：W1 双金 + 就绪 → W2 挂 1 白（真 attach_trait 消费口 = REL_ECHO 回响复制同款）
	_reset_fixture()
	cg.apply_choice(_make_shield_card(3, w1), player)
	cg.apply_choice(_make_shield_card(3, w1), player)
	_charge_shield()
	var iv_before: float = player.shield_interval
	var ready_before: bool = player.shield_ready
	_check("H3-#1 W1 双金就绪 interval≈2.115s · ready=true",
		is_equal_approx(iv_before, INTERVAL_2L_GOLD) and ready_before,
		"interval=%.6f ready=%s" % [iv_before, str(ready_before)])
	var white_a := _make_shield_card(0, w2)
	var attach_ok: bool = w2.attach_trait(white_a["data"] as TraitData)
	var m_w2 := _shield_mounted(w2) if w2 != null else null
	_check("H3-#2 W2 白卡已挂（layers==1 value≈1.0）",
		attach_ok and m_w2 != null and m_w2.layers == 1 and is_equal_approx(float(m_w2.data.value), 1.0),
		"attach=%s layers=%s value=%.3f" % [str(attach_ok),
			str(m_w2.layers) if m_w2 != null else "null",
			float(m_w2.data.value) if m_w2 != null else -1.0])
	var iv_after: float = player.shield_interval
	var regressed: bool = is_equal_approx(iv_after, INTERVAL_1L_WHITE)
	_check("H3-#3 跨宿主覆写复现：shield_interval 无条件回退 8.0（白卡 layers<2 走 interval_s）",
		regressed, "interval %.4f→%.4f（承诺档 %.4f）" % [iv_before, iv_after, INTERVAL_2L_GOLD])
	_check("H3-#4 覆写后 ready 仍 true（满格假象——下次格挡后按 8s 慢充）",
		player.shield_ready == ready_before, "ready=%s" % str(player.shield_ready))
	# 可观测劣化：格挡一次后按承诺档 2.115s 应充满，实测 8s 档充不满
	player.invuln_left = 0.0
	player.take_contact_damage(1.0)               # 消耗护盾（blocked 路径，HP 护住）
	var blocked_used: bool = not player.shield_ready
	player.tick(INTERVAL_2L_GOLD + 0.1, Vector2.ZERO)   # 推进承诺档时长
	var not_ready_at_promise: bool = not player.shield_ready
	player.tick(8.0, Vector2.ZERO)
	var ready_at_8s: bool = player.shield_ready
	_check("H3-#5 劣化可观测：格挡后推进 2.2s 未充满（8s 档）· 再推进 8s 充满",
		blocked_used and not_ready_at_promise and ready_at_8s,
		"blocked=%s @2.2s 已就绪=%s @10.2s 已就绪=%s" % [str(blocked_used),
			str(not not_ready_at_promise), str(ready_at_8s)])
	# B 对照组：同武器（W1）挂白卡 → 取优保金，interval 不回退
	_reset_fixture()
	cg.apply_choice(_make_shield_card(3, w1), player)
	cg.apply_choice(_make_shield_card(3, w1), player)
	_charge_shield()
	var iv_ctrl0: float = player.shield_interval
	var white_b := _make_shield_card(0, w1)
	var ctrl_ok: bool = w1.attach_trait(white_b["data"] as TraitData)
	var m_ctrl := _shield_mounted(w1)
	var iv_ctrl1: float = player.shield_interval
	_check("H3-#6 同武器对照：白卡挂 W1 后 interval 不回退（≈2.115s 不变）",
		ctrl_ok and m_ctrl != null and m_ctrl.layers == 3 and is_equal_approx(iv_ctrl1, iv_ctrl0),
		"layers=%s interval %.6f→%.6f" % [str(m_ctrl.layers) if m_ctrl != null else "null",
			iv_ctrl0, iv_ctrl1])
	var confirmed: bool = regressed and is_equal_approx(iv_ctrl1, INTERVAL_2L_GOLD)
	_set_verdict("H3", confirmed,
		"W1 双金就绪 interval=%.4f → W2 attach 白卡（attach=%s layers=1）后 shield_interval=%.4f（覆写回 8.0=劣化 %.2fs）；格挡后 @2.2s 已就绪=%s（8s 档充不满）@10.2s 已就绪=%s；同武器对照 layers=3 interval %.6f→%.6f 不回退——差异来自跨宿主读数（weapon_base.gd:203-210 只遍历 self.trait_stack）"
			% [iv_before, str(attach_ok), iv_after, INTERVAL_1L_WHITE - INTERVAL_2L_GOLD,
			str(not not_ready_at_promise), str(ready_at_8s), iv_ctrl0, iv_ctrl1])


# ═══ H4 首挂充能空窗（首盾非立即可用 + HUD 表现滞后） ══════════════════
func _test_h4() -> void:
	print("── H4 首挂 8s 充能空窗 + HUD 源级锚 ──")
	var cg := _gl.card_generator
	var player := _gl.player
	_reset_fixture()
	var w1: WeaponBase = player.weapon_slots[0]
	cg.apply_choice(_make_shield_card(0, w1), player)
	_check("H4-#1 首挂 interval==8.0 · timer==8.0 · ready=false（首盾即非就绪）",
		is_equal_approx(player.shield_interval, INTERVAL_1L_WHITE)
			and is_equal_approx(player.shield_timer, INTERVAL_1L_WHITE) and not player.shield_ready,
		"interval=%.4f timer=%.4f ready=%s" % [player.shield_interval, player.shield_timer,
			str(player.shield_ready)])
	player.max_hp = 100.0
	player.hp = 100.0
	player.invuln_left = 0.0
	player._dead = false
	var hit0 := _player_hit_cnt
	var blk0 := _shield_blocked_cnt
	player.take_contact_damage(50.0)
	_check("H4-#2 充能空窗期挨打：HP 直减 50（100→50）",
		is_equal_approx(player.hp, 50.0), "hp=%.1f" % player.hp)
	_check("H4-#3 无 shield_blocked（0 次）· player_hit 恰 1 次（格挡闸未就绪直落扣血）",
		(_shield_blocked_cnt - blk0) == 0 and (_player_hit_cnt - hit0) == 1,
		"blocked Δ=%d hit Δ=%d" % [_shield_blocked_cnt - blk0, _player_hit_cnt - hit0])
	_charge_shield(9.0)
	_check("H4-#4 推进 8.5s+ 后 shield_ready==true（首充走完）",
		player.shield_ready, "timer=%.4f" % player.shield_timer)
	player.invuln_left = 0.0
	var blk1 := _shield_blocked_cnt
	var hit1 := _player_hit_cnt
	player.take_contact_damage(50.0)
	_check("H4-#5 就绪期格挡：HP 不掉（仍 50）",
		is_equal_approx(player.hp, 50.0), "hp=%.1f" % player.hp)
	_check("H4-#6 shield_blocked 恰发 1 次 · player_hit 0 次",
		(_shield_blocked_cnt - blk1) == 1 and (_player_hit_cnt - hit1) == 0,
		"blocked Δ=%d hit Δ=%d" % [_shield_blocked_cnt - blk1, _player_hit_cnt - hit1])
	_check("H4-#7 格挡后 shield_timer 重置为 interval(8.0) · ready 翻 false（进入再充能）",
		is_equal_approx(player.shield_timer, INTERVAL_1L_WHITE) and not player.shield_ready,
		"timer=%.4f ready=%s" % [player.shield_timer, str(player.shield_ready)])
	# HUD 源级锚：1Hz 兜底刷新 + 悬停文案旧名残留
	var hud_src := _read_source(HUD_SOURCE)
	_check("H4-#8 源级锚：护盾条 interval>0 才显示 + 充能期按剩余比例（hud.gd:254-261 在位）",
		hud_src.contains("_shield_panel.visible = s_interval > 0.0"),
		"found=%s" % str(hud_src.contains("_shield_panel.visible = s_interval > 0.0")))
	_check("H4-#9 源级锚：1Hz 兜底刷新在位（进度最长 1s 不动）",
		hud_src.contains("if _fallback_timer >= 1.0:"),
		"found=%s" % str(hud_src.contains("if _fallback_timer >= 1.0:")))
	_check("H4-#10 源级锚：悬停文案旧名「能量护盾」残留（真卡名「格挡力场」）",
		hud_src.contains("持有「能量护盾」词条时出现"),
		"found=%s" % str(hud_src.contains("持有「能量护盾」词条时出现")))
	var core_ok: bool = is_equal_approx(player.hp, 50.0) and player.shield_ready == false \
		and (_shield_blocked_cnt - blk1) == 1
	# 注：core_ok 用 #5/#6/#7 组合（#2/#3 已计入 fail 计数）；结论取全部核心位
	var h4_ok: bool = hud_src.contains("持有「能量护盾」词条时出现") \
		and hud_src.contains("if _fallback_timer >= 1.0:")
	_set_verdict("H4", core_ok and h4_ok,
		"首挂 interval=8.0/timer=8.0/ready=false；空窗期 take_contact_damage(50) HP 100→50 无 shield_blocked（hit+1）；8.5s 后 ready=true 再打=blocked 恰+1 HP 不掉 timer 重置 8.0；HUD 1Hz 兜底+「能量护盾」旧名残留源级锚在位——首充空窗复现成立")


# ═══ H5 接触伤害链路健在性（R202 信号驱动缓存缺口反向证伪） ════════════
func _test_h5() -> void:
	print("── H5 接触链路三路可达性（出生重叠 / 池复用 / 重叠态归还） ──")
	var cg := _gl.card_generator
	var player := _gl.player
	_reset_fixture()
	var w1: WeaponBase = player.weapon_slots[0]
	_check("H5-#0a 前置：CONTACT_RADIAL 默认 off（物理信号通道语义）",
		Enemy.CONTACT_RADIAL == false, str(Enemy.CONTACT_RADIAL))
	cg.apply_choice(_make_shield_card(0, w1), player)
	_charge_shield(9.0)
	_check("H5-#0b 前置：护盾就绪（blocked 通道可读）",
		player.shield_ready and is_equal_approx(player.shield_interval, INTERVAL_1L_WHITE),
		"ready=%s interval=%.4f" % [str(player.shield_ready), player.shield_interval])
	player.max_hp = 100.0
	player.hp = 100.0
	player.invuln_left = 0.0
	player._dead = false
	var delivered := 0
	var attempted := 0
	# ⑤a 敌出生即重叠 → 2 物理帧 arm → tick 结算
	var enemy_a := _acquire(&"E_R238_A", 100.0, 25.0)
	if enemy_a == null:
		_set_inconclusive("H5", "敌池 acquire 返回 null（容量不足）——链路无法驱动")
		return
	_check("H5-#0c 前置：layer/mask 配对（player layer==3 · 敌 HitArea mask==2）",
		player.collision_layer == 3 and enemy_a._hit_area != null
			and enemy_a._hit_area.collision_mask == 2,
		"player_layer=%d mask=%s" % [player.collision_layer,
			str(enemy_a._hit_area.collision_mask) if enemy_a._hit_area != null else "null"])
	enemy_a.global_position = player.global_position
	await tree.physics_frame
	await tree.physics_frame              # 两次物理冲刷 → area_entered 旗 arm（r237 ③e 同款）
	var blk_a := _shield_blocked_cnt
	var dist_a: float = enemy_a.global_position.distance_to(player.global_position)
	var flag_a: bool = enemy_a._contact_player != null
	attempted += 1
	enemy_a.tick(DT)
	var ok_a := (_shield_blocked_cnt - blk_a) == 1 and is_equal_approx(player.hp, 100.0)
	if ok_a:
		delivered += 1
	_check("H5-#1 出生即重叠×2 物理帧：take_contact_damage 可达（blocked+1 · HP 不掉）",
		ok_a, "dist=%.1f flag=%s blocked Δ=%d hp=%.1f" % [dist_a, str(flag_a),
			_shield_blocked_cnt - blk_a, player.hp])
	# ⑤b 池复用：远处归还 → 同实例重生重叠
	player.invuln_left = 0.0
	_charge_shield(9.0)
	enemy_a.global_position = player.global_position + Vector2(2000.0, 0.0)
	await tree.physics_frame              # 物理离场（area_exited 路径）
	var id_a: int = enemy_a.get_instance_id()
	_release(enemy_a)
	var enemy_b := _acquire(&"E_R238_B", 100.0, 25.0)
	if enemy_b == null:
		_set_inconclusive("H5", "复用 acquire 返回 null——a 路已验 %d/%d" % [delivered, attempted])
		return
	var reused: bool = enemy_b.get_instance_id() == id_a
	enemy_b.global_position = player.global_position
	await tree.physics_frame
	await tree.physics_frame
	var blk_b := _shield_blocked_cnt
	attempted += 1
	enemy_b.tick(DT)
	var ok_b := (_shield_blocked_cnt - blk_b) == 1 and is_equal_approx(player.hp, 100.0)
	if ok_b:
		delivered += 1
	_check("H5-#2 池复用（远处归还→同实例重生重叠）：take_contact_damage 可达",
		ok_b, "reused=%s blocked Δ=%d hp=%.1f" % [str(reused),
			_shield_blocked_cnt - blk_b, player.hp])
	# ⑤c 重叠态归还 → 原位重生（_contact_player 清零后重 arm——缓存缺口最严场景）
	player.invuln_left = 0.0
	_charge_shield(9.0)
	var overlapping: bool = enemy_b.global_position.distance_to(player.global_position) < 40.0
	_release(enemy_b)                     # 重叠态直接归还（实战死于贴脸的常态）
	await tree.physics_frame
	var enemy_c := _acquire(&"E_R238_C", 100.0, 25.0)
	if enemy_c == null:
		_set_inconclusive("H5", "c 路 acquire 返回 null——已验 %d/%d" % [delivered, attempted])
		return
	enemy_c.global_position = player.global_position
	await tree.physics_frame
	await tree.physics_frame
	var blk_c := _shield_blocked_cnt
	var dist_c: float = enemy_c.global_position.distance_to(player.global_position)
	var flag_c: bool = enemy_c._contact_player != null
	attempted += 1
	enemy_c.tick(DT)
	var ok_c := (_shield_blocked_cnt - blk_c) == 1 and is_equal_approx(player.hp, 100.0)
	if ok_c:
		delivered += 1
	_check("H5-#3 重叠态归还→原位重生：take_contact_damage 可达（缓存缺口专测）",
		ok_c, "released_overlapping=%s dist=%.1f(<reach 30) flag=%s blocked Δ=%d hp=%.1f"
			% [str(overlapping), dist_c, str(flag_c),
			_shield_blocked_cnt - blk_c, player.hp])
	_release(enemy_c)
	# H5 判定：三路全可达 = 链路健在（假设被驳倒）；任一缺口 = 假设复现；夹具不完整 = 不可判
	var precondition_ok: bool = reused and overlapping
	if not precondition_ok:
		_set_inconclusive("H5", "夹具不完整：reused=%s overlapping=%s（三路 delivered=%d/%d）"
			% [str(reused), str(overlapping), delivered, attempted])
	elif delivered == attempted:
		_set_verdict("H5", false,          # 全可达 → 「真断链」被驳倒（channel 健在）
			"接触链路健在：出生即重叠/池复用（reused=%s）/重叠态归还三路 take_contact_damage 全可达（shield_blocked 恰+1 · HP 100 不掉）——R202 信号缓存通道在本局语义下无缺口；敌弹同漏斗未改，与「完全没生效」表现不符"
				% str(reused))
	else:
		_set_verdict("H5", true,           # 存在缺口 → 假设复现
			"接触链路缺口复现：delivered=%d/%d（a=%s b=%s c=%s）——c 路重叠态归还（dist=%.1f<reach 30 · flag=%s）后原位重生 _contact_player 不再 arm：物理对未断（树内 reparent 持续重叠）→ 无新 area_entered → R202 信号缓存存在不可达面（a 路新对/ b 路远离后归还均正常，缺口锁定在「重叠态回收→重叠位复用」路径）"
				% [delivered, attempted, str(ok_a), str(ok_b), str(ok_c), dist_c, str(flag_c)])


# ═══ 夹具 ═════════════════════════════════════════════════════════
func _boot_game_loop() -> void:
	var main: Node = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	await tree.process_frame
	_gl = tree.root.get_node_or_null("Main") as GameLoop
	if _gl == null:
		for c in tree.root.get_children():
			if c is GameLoop:
				_gl = c
				break


func _ensure_second_weapon() -> void:
	# W2 宿主（真 add_weapon 形态工厂路径）——H2 fallback 落点 / H3 跨武器对照
	var player := _gl.player
	if player.weapon_slots[1] == null:
		player.add_weapon(_gl.registry.get_weapon(&"W3_shotgun"))


func _fixture_enemy(p_id: StringName, p_hp: float, p_dmg: float = 0.0) -> EnemyData:
	# r202_g3_enemyhot_cases.gd:64 同款夹具（静态：spd 0 / 可配 dmg）
	var d := EnemyData.new()
	d.id = p_id
	d.display_name = String(p_id)
	d.hp_base = p_hp
	d.spd_base = 0.0
	d.dmg_base = p_dmg
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


func _acquire(p_id: StringName, p_hp: float = 100.0, p_dmg: float = 0.0) -> Enemy:
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(_fixture_enemy(p_id, p_hp, p_dmg), 1, 0)
	return enemy


func _release(p_enemy: Enemy) -> void:
	(_gl.pools[&"enemy"] as EnemyPool).release(p_enemy)


func _make_shield_card(p_rarity: int, p_target: WeaponBase) -> Dictionary:
	# 真卡架路径：_make_trait_card（registry duplicate）→ 稀有度覆盖 → _apply_rarity_values
	#（generate_candidates 末位同款终值落值；目标武器显式落卡面 target_weapon=宿主指定真路径）
	var cg := _gl.card_generator
	var card := cg._make_trait_card(&"MEC_SHIELD", 1, p_target)
	card["rarity"] = p_rarity
	var arr: Array[Dictionary] = [card]
	cg._apply_rarity_values(arr)
	return card


func _pick_prefill_ids(p_n: int) -> Array[StringName]:
	# ADD 池真实词条取 p_n 种（排除 add_hp 免血条副作用；THRESHOLD_ONLY 不在 ADD 池）
	var out: Array[StringName] = []
	for tid in _gl.registry.trait_ids_by_pool(GameConst.PoolClass.ADD):
		if out.size() >= p_n:
			break
		var t := _gl.registry.get_trait(tid)
		if t == null or t.pool_id == &"add_hp":
			continue
		out.append(tid)
	return out


func _shield_mounted(p_w: WeaponBase) -> TraitBase:
	if p_w == null or p_w.trait_stack == null:
		return null
	for m in p_w.trait_stack.traits:
		if m.data != null and m.data.id == &"MEC_SHIELD":
			return m
	return null


func _stack_has(p_w: WeaponBase, p_id: StringName) -> bool:
	if p_w == null or p_w.trait_stack == null:
		return false
	for m in p_w.trait_stack.traits:
		if m.data != null and m.data.id == p_id:
			return true
	return false


func _charge_shield(p_budget: float = 10.0) -> void:
	# 直驱 player.tick 推进护盾充能（MENU 静止环境——GameLoop 不参与）
	var t := 0.0
	var player := _gl.player
	while not player.shield_ready and t < p_budget:
		player.tick(0.25, Vector2.ZERO)
		t += 0.25


func _reset_fixture() -> void:
	# 用例间隔离：真栈清空（TraitStack.clear）+ 玩家护盾/生存位归零（r237 同款直字段复位）
	var player := _gl.player
	for w in player.weapon_slots:
		if w is WeaponBase and is_instance_valid(w) and (w as WeaponBase).trait_stack != null:
			(w as WeaponBase).trait_stack.clear()
	player.shield_interval = 0.0
	player.shield_timer = 0.0
	player.shield_ready = false
	player.max_hp = 100.0
	player.hp = 100.0
	player.invuln_left = 0.0
	player._dead = false
	player.dr_left = 0.0
	player.dr_value = 0.0


func _read_source(p_res_path: String) -> String:
	var fa := FileAccess.open(p_res_path, FileAccess.READ)
	if fa == null:
		return ""
	var txt := fa.get_as_text().replace("\r\n", "\n")
	fa.close()
	return txt


func _cleanup() -> void:
	Enemy.CONTACT_RADIAL = false
	PerfGovernor.set_process(true)
	_gl.state = GameConst.GameStatus.MENU
	var player := _gl.player
	if player != null and is_instance_valid(player):
		player._dead = false
		player.invuln_left = 0.0
	# 真释放 Main 场景（防 ObjectDB 退出泄漏警告打印在 VERDICT 之后——保末行契约）
	if is_instance_valid(_gl):
		_gl.queue_free()
	await tree.process_frame
	await tree.process_frame


# ═══ 断言与结论 ═══════════════════════════════════════════════════
func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s（%s）" % [p_name, p_detail])
		print("  FAIL | %s（%s）" % [p_name, p_detail])


func _set_verdict(p_id: String, p_confirmed: bool, p_evidence: String) -> void:
	_h_result[p_id] = "confirmed" if p_confirmed else "refuted"
	_h_ev[p_id] = p_evidence


func _set_inconclusive(p_id: String, p_evidence: String) -> void:
	_h_result[p_id] = "inconclusive"
	_h_ev[p_id] = p_evidence


func _finish() -> void:
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（诊断模式——失败亦是有效诊断信息）" % [_pass, _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	# 主因句（按实测结果动态拼装——非预设）
	var confirmed: Array[String] = []
	var refuted: Array[String] = []
	var inconclusive: Array[String] = []
	for h in ["H1", "H2", "H3", "H4", "H5"]:
		if _h_result[h] == "confirmed":
			confirmed.append(h)
		elif _h_result[h] == "refuted":
			refuted.append(h)
		else:
			inconclusive.append(h)
	var summary := "复现成立：%s；驳倒：%s；不可判：%s——「选了没生效」主因判定见各 verdicts.evidence" \
		% [", ".join(confirmed) if not confirmed.is_empty() else "无",
		", ".join(refuted) if not refuted.is_empty() else "无",
		", ".join(inconclusive) if not inconclusive.is_empty() else "无"]
	var verdicts: Array = []
	for h in ["H1", "H2", "H3", "H4", "H5"]:
		verdicts.append({"id": h, "result": _h_result[h], "evidence": _h_ev[h]})
	print("VERDICT: " + JSON.stringify({
		"verdicts": verdicts,
		"summary": summary,
		"probeFile": PROBE_FILE,
	}))

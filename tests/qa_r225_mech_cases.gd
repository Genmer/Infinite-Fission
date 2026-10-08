# tests/qa_r225_mech_cases.gd
# R225 把关注（机制正确性镜头）用例体（入口 qa_r225_mech.gd 运行时 load——两文件铁律）。
# 夹具=test_r225_separation_cases 同款（池化敌直驱管线、真武器零开火 MENU 态、同步段
# 零 await）+ r225_popup_cases 同款（DamagePopup 直建 add_child 不经池）。覆盖面见入口头注。
# 纪律：锁机制契约而非实现细节；披露锚 = 显式命名「披露」钉当前行为，产品码修复后须
# 同步更新锚与对应 Finding（G7*-G9* 披露类门同思路）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GAME_LOOP_SRC := "res://scripts/loop/game_loop.gd"
const DT := 1.0 / 120.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _released: Array[Enemy] = []
var _popups: Array[DamagePopup] = []


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42250)
	await _test_1_drop_sentinel_vs_reaction_channel()
	_test_2_override_switch_pending_flush()
	_cleanup_pipeline()
	_test_3_bitmap_gate_flip_symmetry()
	_test_4_bitmap_digits_and_counter()
	_teardown_popups()
	_test_5_shardcap_flag_anchor()
	await tree.process_frame                 # GameLoop queue_free 冲刷（防退出泄漏告警噪声）
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


# ── 管线夹具（test_r225_separation_cases 同款） ────────────────────

func _boot_game_loop() -> bool:
	var main: Node = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	_gl = tree.root.get_node_or_null("Main") as GameLoop
	if _gl == null:
		for c in tree.root.get_children():
			if c is GameLoop:
				_gl = c
				break
	return _gl != null


func _fixture_enemy(p_id: StringName, p_hp: float) -> EnemyData:
	var d := EnemyData.new()
	d.id = p_id
	d.display_name = String(p_id)
	d.hp_base = p_hp
	d.spd_base = 0.0
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


func _spawn_enemy(p_id: StringName, p_hp: float = 100000.0) -> Enemy:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	e.spawn(_fixture_enemy(p_id, p_hp), 1, 0)
	e._fade_left = 0.0
	e.modulate.a = 1.0
	_released.append(e)
	return e


func _mk_ctx(p_source: int, p_target: Enemy, p_base: float, p_frame: int) -> DamageContext:
	var ctx := DamageContext.make()
	ctx.source_uid = p_source
	ctx.target_uid = p_target.uid
	ctx.target = p_target
	ctx.frame_stamp = p_frame
	ctx.base_atk = p_base
	ctx.crit_chance = 0.0
	ctx.crit_mult = 2.0
	ctx.pos = p_target.global_position
	return ctx


func _stat(p_key: String) -> int:
	return int((_gl.pipeline.call(&"stats") as Dictionary).get(p_key, 0))


func _fifo_size() -> int:
	return (_gl.pipeline.get(&"_pending_fifo") as Array).size()


# ── ① -4 全弃哨兵 × 反应通道（G3 盲区计数实证） ────────────────────

func _test_1_drop_sentinel_vs_reaction_channel() -> void:
	print("── ① -4 哨兵 × 反应通道共存 ──")
	if not _boot_game_loop():
		_check("①boot 主场景", false, "GameLoop 未就位")
		return
	await tree.process_frame
	await tree.process_frame
	PerfGovernor.set_process(false)          # 引擎侧停走——直驱管线（确定性）
	_gl.state = GameConst.GameStatus.MENU    # 真武器零开火
	var e := _spawn_enemy(&"E_QA225_RXN")
	var hp0 := e.hp
	DamagePipeline.settle_budget_override = -4
	_gl.pipeline.call(&"begin_frame", 3100)
	var set0 := _stat("settles")
	var drop0 := _stat("separate_drop")
	# 对照：主结算链 -4 全弃（契约照旧）
	var r_main := _gl.pipeline.call(&"resolve", _mk_ctx(9100, e, 10.0, 3100)) as DamageResult
	_check("①对照：主链 -4 全弃（占位 · separate_drop+1 · 零真结算）",
		r_main != null and r_main.deferred_merge and r_main.final_value == 0.0
			and _stat("separate_drop") == drop0 + 1 and _stat("settles") == set0,
		"drop=%d settles=%d" % [_stat("separate_drop") - drop0, _stat("settles") - set0])
	# 盲区实证：反应通道在 -4 下真结算（resolve_reaction 无 -4 闸——damage_pipeline.gd
	# :126-172 无哨兵检查。R225 把关修轮：reaction_settles 已入探针 PIPE_KEYS 并入 G3
	# 零判据（probe_r225_separation_cases.gd）——测量盲区已收口；产品侧豁免仍系有意设计）
	var rxn0 := _stat("reaction_settles")
	var ctx := _mk_ctx(9101, e, 0.0, 3100)
	ctx.element = GameConst.ReactionType.RXN_FIR_ICE   # 反应通道专用：element 承载中性 ID
	var r_rxn := _gl.pipeline.call(&"resolve_reaction", 100.0, 0.5, ctx) as DamageResult
	_check("①盲区实证：-4 下反应真结算（非占位 · final>0 · 落血 · reaction_settles+1）",
		r_rxn != null and not r_rxn.deferred_merge and r_rxn.final_value > 0.0
			and e.hp < hp0 and _stat("reaction_settles") == rxn0 + 1
			and _stat("settles") == set0 and _stat("separate_drop") == drop0 + 1,
		"final=%.1f hp=%.1f rxn=%d" % [r_rxn.final_value if r_rxn != null else -1.0,
			e.hp, _stat("reaction_settles") - rxn0])
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -1


# ── ② -4 × R223 预算切换边（≥0 残留积压在 -4 下被真冲刷） ──────────

func _test_2_override_switch_pending_flush() -> void:
	print("── ② -4 × R223 预算切换边 ──")
	var e := _spawn_enemy(&"E_QA225_FIFO")
	var hp0 := e.hp
	# 前置：override=2 强制帽——3 发提交 2 真结算（预算逐发扣）+ 1 顺延积压
	DamagePipeline.settle_budget_override = 2
	var set0 := _stat("settles")
	var def0 := _stat("settle_deferred")
	_gl.pipeline.call(&"begin_frame", 3200)
	_gl.pipeline.call(&"resolve", _mk_ctx(9201, e, 10.0, 3200))
	_gl.pipeline.call(&"resolve", _mk_ctx(9202, e, 10.0, 3200))
	_gl.pipeline.call(&"resolve", _mk_ctx(9203, e, 10.0, 3200))
	_check("②前置：帽 2 下 2 真结算 + 1 顺延（FIFO=1）",
		_stat("settles") == set0 + 2 and _stat("settle_deferred") == def0 + 1
			and _fifo_size() == 1,
		"settles+%d def+%d fifo=%d" % [_stat("settles") - set0,
			_stat("settle_deferred") - def0, _fifo_size()])
	# 切换边：≥0 → -4，begin_frame 触发 _drain_pending_budget——cap=0 走
	# _flush_all_pending（damage_pipeline.gd:398-403）：残留积压真冲刷而非弃档
	var flush0 := _stat("settle_flush")
	DamagePipeline.settle_budget_override = -4
	_gl.pipeline.call(&"begin_frame", 3201)
	_check("②切换边实证：-4 不拦既有积压——begin_frame 真冲刷（settles+1 · flush+1 · FIFO 清空）",
		_stat("settles") == set0 + 3 and _stat("settle_flush") == flush0 + 1
			and _fifo_size() == 0,
		"settles+%d flush+%d fifo=%d" % [_stat("settles") - set0,
			_stat("settle_flush") - flush0, _fifo_size()])
	_check("②冲刷落血（顺延伤害照常入账）", e.hp <= hp0 - 30.0, "hp=%.1f（期望 ≤%.1f）"
		% [e.hp, hp0 - 30.0])
	_gl.pipeline.call(&"end_frame")
	# 负对照：纯净 -4 帧序无幻影冲刷（探针 -2 前置冲刷帧后 G3 窗口干净的前提）
	var flush1 := _stat("settle_flush")
	DamagePipeline.settle_budget_override = -4
	_gl.pipeline.call(&"begin_frame", 3300)
	_gl.pipeline.call(&"resolve", _mk_ctx(9301, e, 10.0, 3300))
	_gl.pipeline.call(&"end_frame")
	_gl.pipeline.call(&"begin_frame", 3301)
	_gl.pipeline.call(&"end_frame")
	_check("②负对照：纯净 -4 帧序零冲刷零积压（flush 不增 · FIFO=0）",
		_stat("settle_flush") == flush1 and _fifo_size() == 0, "")
	DamagePipeline.settle_budget_override = -1


func _cleanup_pipeline() -> void:
	DamagePipeline.settle_budget_override = -1
	PerfGovernor.set_process(true)
	tree.paused = false
	if _gl != null:
		var pool := _gl.pools[&"enemy"] as EnemyPool
		for e in _released:
			if is_instance_valid(e) and not e.dead:
				pool.release(e)
		_gl.queue_free()
		_gl = null
		# queue_free 延迟到帧末——位图段不依赖 GameLoop，后续段同步跑无需等待
	_released.clear()


# ── 跳字位图夹具（r225_popup_cases 同款） ──────────────────────────

func _new_popup() -> DamagePopup:
	# 直建实例（池化实体直测先例 r221_fixreg ⑥：new + add_child，不经池不二次 release）
	var popup := DamagePopup.new()
	tree.root.add_child(popup)
	_popups.append(popup)
	return popup


func _decode(p_popup: DamagePopup) -> String:
	var out := ""
	for sp in p_popup._glyph_sprites:
		if not sp.visible:
			continue
		var cx := int(floor(sp.region_rect.position.x / float(PopupGlyphAtlas.CELL)))
		var cy := int(floor(sp.region_rect.position.y / float(PopupGlyphAtlas.CELL)))
		out += String.chr(PopupGlyphAtlas.glyph_code_at(cy * PopupGlyphAtlas.COLS + cx))
	return out


# ── ③ 位图门翻转双向行为（产品可达方向=硬门；反向=披露锚） ──────────

func _test_3_bitmap_gate_flip_symmetry() -> void:
	print("── ③ 位图门翻转双向行为 ──")
	PopupGlyphAtlas.build_all()              # 图集就绪（headless CPU 侧烤，先例 r225_popup）
	# 产品可达方向：Label→bitmap（boot 预热未完开局=Label，图集就绪后位图臂接管）
	DamagePopup.bitmap_override = 0          # _ready 期门关 → Label 装配（产品桌面态同构）
	var p1 := _new_popup()
	p1.show_popup(Vector2(100, 100), 12345.0, GameConst.PopupStyle.NORMAL)
	_check("③基线：门关起字走 Label（text=12345 · sprite 零）",
		p1._label != null and p1._label.text == "12345" and _decode(p1) == "", "")
	DamagePopup.bitmap_override = 1          # 图集就绪——门翻开（产品 mobile 预热完成同构）
	p1.merge(6.0)
	p1.tick(DT)
	var decoded := _decode(p1)
	_check("③硬门（产品可达）：Label→bitmap 翻转后位图臂接管（序列=12351 · Label 退位）",
		decoded == "12351" and p1._label != null and not p1._label.visible,
		"decode=%s label_visible=%s" % [decoded, str(p1._label.visible if p1._label != null else false)])
	# 反向翻转（bitmap→Label）：当前仅 bitmap_override 测试覆写口可达（产品门单调：
	# 平台/图集就绪均单向）。非反应 Label 分支无对称复位（damage_popup.gd:499-529
	# 不触 _label.visible / 不隐 sprite）→ 文字隐身 + 位图残显旧值。
	DamagePopup.bitmap_override = 0
	p1.merge(2.0)
	p1.tick(DT)
	_check("③披露锚（现状钉）：bitmap→Label 翻转缺对称退位——Label 仍隐身（text 已新）",
		p1._label != null and not p1._label.visible and p1._label.text == "12353",
		"label_visible=%s text=%s（修复对称复位后本锚须同步更新）"
			% [str(p1._label.visible), p1._label.text])
	_check("③披露锚（现状钉）：位图 sprite 残显旧值 12351（未随 Label 分支退位）",
		_decode(p1) == "12351", "decode=%s" % _decode(p1))
	DamagePopup.bitmap_override = -1
	_popups.erase(p1)                        # 先 erase 后 free（TypedArray 擦 freed 实例报错）
	p1.free()


# ── ④ 位图大数/零值字形 + R212 观测口照走 ──────────────────────────

func _test_4_bitmap_digits_and_counter() -> void:
	print("── ④ 位图字形边界 + 观测口 ──")
	DamagePopup.bitmap_override = 1          # 图集已就绪（③ 烤毕）
	var p2 := _new_popup()                   # _ready 期门开 → 零 Label（结构契约）
	_check("④结构：门开实例零 Label 节点（_label==null）", p2._label == null, "")
	var calls0 := DamagePopup.refresh_label_calls
	p2.show_popup(Vector2(200, 200), 0.0, GameConst.PopupStyle.NORMAL)
	p2.tick(DT)
	_check("④零值：0 → 恰 1 字形「0」", _decode(p2) == "0", "decode=%s" % _decode(p2))
	p2.merge(1234567.0)                      # 大数：str(int) 无科学计数无千分位
	p2.tick(DT)
	_check("④大数：1234567 → 恰 7 字形顺序正确", _decode(p2) == "1234567",
		"decode=%s" % _decode(p2))
	var p3 := _new_popup()
	p3.show_popup(Vector2(300, 300), 999999.0, GameConst.PopupStyle.XP)
	p3.tick(DT)
	_check("④XP 臂：999999 → 6 字形（非直击样式走数字臂）", _decode(p3) == "999999",
		"decode=%s" % _decode(p3))
	_check("④R212 观测口：refresh_label_calls 位图臂照走（Δ≥3）",
		DamagePopup.refresh_label_calls - calls0 >= 3,
		"Δ=%d" % (DamagePopup.refresh_label_calls - calls0))
	DamagePopup.bitmap_override = -1


func _teardown_popups() -> void:
	for p in _popups:
		if is_instance_valid(p):
			p.free()
	_popups.clear()
	DamagePopup.bitmap_override = -1
	DamagePopup.defer_first_layout = -1


# ── ⑤ 碎片单帽 flag 死分支源级锚（披露） ──────────────────────────

func _test_5_shardcap_flag_anchor() -> void:
	print("── ⑤ 单帽 flag 源级锚 ──")
	var src := FileAccess.get_file_as_string(GAME_LOOP_SRC)
	# 披露锚：_fullload_absorb_open 只置 true 从不复位（全仓 grep 同证）→
	# _tick_magnetized_shards 内 `if not _fullload_absorb_open` 兜底开帽为死分支——
	# 注释承诺的「未经理序入口兜底」不由该检查兑现（当前 ⑦ 三调用点 :441/:518/:520
	# 均有前置开帽 :366/:513，无行为影响；未来新增 ⑦ 调用路径将读到上一帧陈旧余量）。
	_check("⑤披露锚（现状钉）：flag 无复位点 + 兜底分支在位（修复时序须同步更新本锚）",
		src.contains("_fullload_absorb_open = true")
			and not src.contains("_fullload_absorb_open = false")
			and src.contains("if not _fullload_absorb_open:"),
		"修复兜底/复位时序后须同步更新本锚与 Finding")
	_check("⑤共享帽三读点在位（②预留/②扣减/⑦扣减——shardcap ⑤ 的互补锚）",
		src.contains("_fullload_absorb_left - reserved")
			and src.contains("_fullload_absorb_left -= 1   # R225 刀a：扣共享预算（② 份额）")
			and src.contains("_fullload_absorb_left -= 1   # R225 刀a：扣共享预算（⑦ 份额）"), "")

# tests/runner/r202_popup_throttle_cases.gd
# R202 伤害数字节流用例体（由 test_r202_popup_throttle.gd 入口在 autoload 就绪后运行时加载编译）。
# 命名注记：r202_perf_cases.gd 已被 G4「帧率显示」套件占用——本组用独立名防覆盖别组工作。
# 覆盖（消费端两态口径，落点 popup_manager.gd / damage_popup.gd——不动管线广播契约）：
#   · 层1 同目标存活即并入（恒生效，主节流）：合并窗过期后 popup 仍活 → 并入续命不新起；
#     激光节拍口径（8 结算/s × 32 目标 × 8 拍）收敛为每目标 1 张滚字、数值累计不丢
#   · 层1 CRIT 升格（主控裁定）：incoming CRIT 并入 NORMAL 宿主 → 原地升样式 + 重判
#     tier（基准 provider）+ element 随新跳刷新；CRIT 宿主不被 NORMAL 降级
#   · merge 签名硬约束：单参默认路径零语义变化（宿主 REACTION 不升格 / element 不改写）
#   · 层2 满池全局单例 1/8 采样（仅 bucket0 直击 NORMAL 新起）：满池 16 发 2 显 14 丢、
#     active 恒==cap、确定性重放同结果；CRIT / REACTION 必显绕过；未满池全显 N=1
#   · 入口缓存：damage_numbers_on / fx_quality 经 settings_changed 订阅即时生效
#   · tick 等值跳过写点回归：alpha/position/scale 曲线值逐位不变（只跳过重复写）
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_test_layer1_alive_merge()
	_test_layer1_laser_cadence()
	_test_layer1_crit_upgrade()
	_test_layer1_element_refresh()
	_test_merge_default_path()
	_test_layer2_sampling()
	_test_settings_cache()
	_test_tick_write_skip()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R202ThrottleGameLoopUnderTest"
	tree.get_root().add_child(_gl)


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	Meta.set_setting("fx_quality", 2)             # 复位出厂档（防污染其他套件）
	Meta.set_setting("damage_numbers_on", true)
	if _gl != null:
		_gl.free()
		_gl = null


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


# ── 层1：同目标存活即并入（窗过期不强制新起） ────────────────────────
func _test_layer1_alive_merge() -> void:
	print("── R202 层1 存活并入 ──")
	var pm: PopupManager = _gl.popup_manager
	var numbers_prev: bool = bool(Meta.settings("damage_numbers_on"))
	var provider_prev: Callable = pm.baseline_provider
	var quality_prev: int = int(Meta.settings("fx_quality"))
	Meta.set_setting("damage_numbers_on", true)
	Meta.set_setting("fx_quality", 2)             # 高档（窗 0.12s / cap 80）
	pm.baseline_provider = Callable()             # 量级档关闭（本段只锁合并语义）
	pm.tick(10.0)
	pm.clear_all()
	var r := DamageResult.new()
	r.final_value = 6.0
	r.target_uid = 5101
	r.pos = Vector2(100.0, 200.0)
	r.popup_style = GameConst.PopupStyle.NORMAL
	pm.on_damage_resolved(r)
	_check("层1 前置：首跳起字（active=1）", pm.active_popups == 1)
	# 窗过期（0.2s > 0.12s 高档窗）且 popup 仍活（<0.6s）——旧口径此处强制新起第 2 张
	pm.tick(0.2)
	var r2 := DamageResult.new()
	r2.final_value = 4.0
	r2.target_uid = 5101
	r2.pos = Vector2(100.0, 200.0)
	r2.popup_style = GameConst.PopupStyle.NORMAL
	pm.on_damage_resolved(r2)
	_check("层1：窗过期同目标存活即并入（active 仍 1 / 值累计 6+4）",
		pm.active_popups == 1
			and absf((pm._active_list[0] as DamagePopup).merged_value - 10.0) <= 0.001)
	# 恒生效：多次跨窗并入（0.12s 窗结构在激光 0.125s 节拍下失效的修复本体）
	pm.tick(0.2)
	var r3 := DamageResult.new()
	r3.final_value = 5.0
	r3.target_uid = 5101
	r3.pos = Vector2(100.0, 200.0)
	r3.popup_style = GameConst.PopupStyle.NORMAL
	pm.on_damage_resolved(r3)
	_check("层1：再跨窗并入仍续命（active 仍 1 / 值累计 15）",
		pm.active_popups == 1
			and absf((pm._active_list[0] as DamagePopup).merged_value - 15.0) <= 0.001)
	# 边界：popup 退役后同 uid 新起从零滚动（注册表活到 popup 退役为止，不跨代累计）
	pm.tick(10.0)
	_check("层1 边界：popup 到期归还（active=0）", pm.active_popups == 0)
	var r4 := DamageResult.new()
	r4.final_value = 5.0
	r4.target_uid = 5101
	r4.pos = Vector2(100.0, 200.0)
	r4.popup_style = GameConst.PopupStyle.NORMAL
	pm.on_damage_resolved(r4)
	var r5 := DamageResult.new()
	r5.final_value = 3.0
	r5.target_uid = 5101
	r5.pos = Vector2(100.0, 200.0)
	r5.popup_style = GameConst.PopupStyle.NORMAL
	pm.on_damage_resolved(r5)
	_check("层1 边界：退役后新起从零滚动（新值 5+3=8，非跨代 23）",
		pm.active_popups == 1
			and absf((pm._active_list[0] as DamagePopup).merged_value - 8.0) <= 0.001)
	pm.tick(10.0)
	Meta.set_setting("fx_quality", quality_prev)
	pm.baseline_provider = provider_prev
	Meta.set_setting("damage_numbers_on", numbers_prev)


# ── 层1：激光节拍口径（8 结算/s × 32 目标——每目标收敛 1 张滚字） ────
func _test_layer1_laser_cadence() -> void:
	print("── R202 层1 激光节拍收敛 ──")
	var pm: PopupManager = _gl.popup_manager
	var pool: PopupPool = _gl.pools[&"popup"]
	pool.prewarm(GameConfig.get_pool_capacity(&"popup"))
	var numbers_prev: bool = bool(Meta.settings("damage_numbers_on"))
	var provider_prev: Callable = pm.baseline_provider
	Meta.set_setting("damage_numbers_on", true)
	pm.baseline_provider = Callable()
	pm.tick(10.0)
	pm.clear_all()
	var hits0: int = int(pool.stats()["hits"])
	# 激光同构节拍：每拍 0.125s（1/8s 结算率）× 8 拍 × 32 目标；每 4 跳掺 1 CRIT
	# （probe_r202_popup 同款混合）——0.125s > 0.12s 高档窗，旧口径每拍窗过期强制新起
	for round_i in range(8):
		for e in range(32):
			var r := DamageResult.new()
			r.final_value = 10.0
			r.target_uid = 6000 + e
			r.pos = Vector2(100.0 + (e % 8) * 60.0, 300.0 + (e / 8) * 60.0)
			r.popup_style = GameConst.PopupStyle.CRIT if (round_i + e) % 4 == 0 \
				else GameConst.PopupStyle.NORMAL
			r.element = GameConst.Element.KIN
			pm.on_damage_resolved(r)
		pm.tick(0.125)
	var new_pops: int = int(pool.stats()["hits"]) - hits0
	_check("层1 激光口径：256 结算跳 → 新起恰 32（每目标 1 张滚字；probe 基线旧口径 624/816）",
		new_pops == 32 and pm.active_popups == 32,
		"new=%d active=%d" % [new_pops, pm.active_popups])
	var crit_hosts := 0
	var value_ok := true
	for p: DamagePopup in pm._active_list:
		if p.style == GameConst.PopupStyle.CRIT:
			crit_hosts += 1
		if absf(p.merged_value - 80.0) > 0.001:    # 8 拍 × 10/跳 全累计
			value_ok = false
	_check("层1 激光口径：数值累计不丢（每滚字 8×10=80）+ CRIT 并入升格在册",
		value_ok and crit_hosts > 0, "crit_hosts=%d" % crit_hosts)
	pm.tick(10.0)
	pm.baseline_provider = provider_prev
	Meta.set_setting("damage_numbers_on", numbers_prev)


# ── 层1：CRIT 升格（样式/tier 重判/不降级） ─────────────────────────
func _test_layer1_crit_upgrade() -> void:
	print("── R202 层1 CRIT 升格 ──")
	var pm: PopupManager = _gl.popup_manager
	var numbers_prev: bool = bool(Meta.settings("damage_numbers_on"))
	var provider_prev: Callable = pm.baseline_provider
	Meta.set_setting("damage_numbers_on", true)
	pm.tick(10.0)
	pm.clear_all()
	# ① 样式升格（tier 关闭）：NORMAL 宿主吃 CRIT 并入 → 原地升样式不新起
	pm.baseline_provider = Callable()
	var r := DamageResult.new()
	r.final_value = 5.0
	r.target_uid = 5201
	r.pos = Vector2(100.0, 200.0)
	r.popup_style = GameConst.PopupStyle.NORMAL
	pm.on_damage_resolved(r)
	var host: DamagePopup = pm._active_list[0]
	var rc := DamageResult.new()
	rc.final_value = 5.0
	rc.target_uid = 5201
	rc.pos = Vector2(100.0, 200.0)
	rc.popup_style = GameConst.PopupStyle.CRIT
	pm.on_damage_resolved(rc)
	pm.tick(DT)                                    # 合并置脏 → tick 一次刷新（R189）
	_check("CRIT 升格：宿主原地升 CRIT（同实例 / active 不涨 / 值累计 / 40px 字号）",
		pm.active_popups == 1 and pm._active_list[0] == host
			and host.style == GameConst.PopupStyle.CRIT
			and absf(host.merged_value - 10.0) <= 0.001
			and host._label.get_theme_font_size("font_size") == DamagePopup.FONT_SIZE_CRIT)
	# ② CRIT 宿主不被后续 NORMAL 降级（升格单向）
	var rn := DamageResult.new()
	rn.final_value = 5.0
	rn.target_uid = 5201
	rn.pos = Vector2(100.0, 200.0)
	rn.popup_style = GameConst.PopupStyle.NORMAL
	pm.on_damage_resolved(rn)
	_check("CRIT 升格单向：CRIT 宿主吃 NORMAL 并入不降级", host.style == GameConst.PopupStyle.CRIT)
	pm.tick(10.0)
	# ③ tier 重判（基准 provider=10：3+77=80 → 8× 金档）：升格时按累计值重判量级档
	pm.baseline_provider = func() -> float: return 10.0
	var r2 := DamageResult.new()
	r2.final_value = 3.0
	r2.target_uid = 5202
	r2.pos = Vector2(100.0, 200.0)
	r2.popup_style = GameConst.PopupStyle.NORMAL
	pm.on_damage_resolved(r2)
	_check("CRIT 升格前置：小值白档起字（tier 0）",
		(pm._active_list[0] as DamagePopup).tier == 0)
	var rc2 := DamageResult.new()
	rc2.final_value = 77.0
	rc2.target_uid = 5202
	rc2.pos = Vector2(100.0, 200.0)
	rc2.popup_style = GameConst.PopupStyle.CRIT
	pm.on_damage_resolved(rc2)
	var host2: DamagePopup = pm._active_list[0]
	pm.tick(DT)
	_check("CRIT 升格 tier 重判：并入累计 80=8×基准 → 金档（tier 3 / 40×1.6=64px）",
		host2.style == GameConst.PopupStyle.CRIT and host2.tier == 3
			and host2._label.get_theme_font_size("font_size")
				== roundi(DamagePopup.FONT_SIZE_CRIT * 1.6))
	pm.tick(10.0)
	pm.baseline_provider = provider_prev
	Meta.set_setting("damage_numbers_on", numbers_prev)


# ── 层1：element 刷新（异元素连击颜色随最新命中） ───────────────────
func _test_layer1_element_refresh() -> void:
	print("── R202 层1 element 刷新 ──")
	var pm: PopupManager = _gl.popup_manager
	var numbers_prev: bool = bool(Meta.settings("damage_numbers_on"))
	var provider_prev: Callable = pm.baseline_provider
	Meta.set_setting("damage_numbers_on", true)
	pm.baseline_provider = Callable()
	pm.tick(10.0)
	pm.clear_all()
	# 直击宿主：FIR 首跳 → HYD 并入 → element/配色随新跳
	var r := DamageResult.new()
	r.final_value = 3.0
	r.target_uid = 5301
	r.pos = Vector2(100.0, 200.0)
	r.popup_style = GameConst.PopupStyle.NORMAL
	r.element = GameConst.Element.FIR
	pm.on_damage_resolved(r)
	var host: DamagePopup = pm._active_list[0]
	_check("element 前置：FIR 首跳橙字",
		host._label.self_modulate == PopPalette.ELEMENT_COLORS[GameConst.Element.FIR])
	var r2 := DamageResult.new()
	r2.final_value = 3.0
	r2.target_uid = 5301
	r2.pos = Vector2(100.0, 200.0)
	r2.popup_style = GameConst.PopupStyle.NORMAL
	r2.element = GameConst.Element.HYD
	pm.on_damage_resolved(r2)
	pm.tick(DT)
	_check("element 刷新：异元素并入颜色随新元素（FIR→HYD，不停在第跳）",
		host.element == GameConst.Element.HYD
			and host._label.self_modulate == PopPalette.ELEMENT_COLORS[GameConst.Element.HYD])
	pm.tick(10.0)
	# REACTION 宿主：element=ReactionType 真源——manager 路径并入不改写（异反应同名累计）
	pm._rxn_frame_stamp = -1
	var rr := DamageResult.new()
	rr.final_value = 20.0
	rr.target_uid = 5302
	rr.pos = Vector2(100.0, 200.0)
	rr.popup_style = GameConst.PopupStyle.REACTION
	rr.element = GameConst.ReactionType.RXN_FIR_HYD
	pm.on_damage_resolved(rr)
	var rhost: DamagePopup = pm._active_list[-1]
	pm._rxn_frame_stamp = -1
	var rr2 := DamageResult.new()
	rr2.final_value = 5.0
	rr2.target_uid = 5302
	rr2.pos = Vector2(100.0, 200.0)
	rr2.popup_style = GameConst.PopupStyle.REACTION
	rr2.element = GameConst.ReactionType.RXN_FIR_ICE
	pm.on_damage_resolved(rr2)
	pm.tick(DT)
	_check("element 改写边界：REACTION 宿主 element（=ReactionType）不被并入改写",
		rhost.element == GameConst.ReactionType.RXN_FIR_HYD and rhost._label.text == "蒸发25",
		"elem=%d text=%s" % [rhost.element, rhost._label.text])
	pm.tick(10.0)
	pm.baseline_provider = provider_prev
	Meta.set_setting("damage_numbers_on", numbers_prev)


# ── merge 签名硬约束：单参默认路径零语义变化 ────────────────────────
func _test_merge_default_path() -> void:
	print("── R202 merge 默认路径（签名硬约束） ──")
	var pm: PopupManager = _gl.popup_manager
	var numbers_prev: bool = bool(Meta.settings("damage_numbers_on"))
	var provider_prev: Callable = pm.baseline_provider
	Meta.set_setting("damage_numbers_on", true)
	pm.baseline_provider = Callable()
	pm.tick(10.0)
	pm.clear_all()
	pm._rxn_frame_stamp = -1
	var rr := DamageResult.new()
	rr.final_value = 20.0
	rr.target_uid = 5401
	rr.pos = Vector2(100.0, 200.0)
	rr.popup_style = GameConst.PopupStyle.REACTION
	rr.element = GameConst.ReactionType.RXN_FIR_HYD
	pm.on_damage_resolved(rr)
	var host: DamagePopup = pm._active_list[-1]
	# 全仓测试唯一直调形态：p0.merge(34.0)（单 float 实参——r192_element_cases:727 同构）
	host.merge(34.0)
	pm.tick(DT)
	_check("merge 默认路径：单参调用零语义变化（样式/element 不动，文本=名+累计值纯函数）",
		host.style == GameConst.PopupStyle.REACTION
			and host.element == GameConst.ReactionType.RXN_FIR_HYD
			and host._label.text == "蒸发54", "text=%s" % host._label.text)
	pm.tick(10.0)
	pm.baseline_provider = provider_prev
	Meta.set_setting("damage_numbers_on", numbers_prev)


# ── 层2：满池全局单例 1/8 采样（仅 bucket0 直击 NORMAL 新起） ────────
func _test_layer2_sampling() -> void:
	print("── R202 层2 满池采样 ──")
	var pm: PopupManager = _gl.popup_manager
	var pool: PopupPool = _gl.pools[&"popup"]
	pool.prewarm(GameConfig.get_pool_capacity(&"popup"))
	var numbers_prev: bool = bool(Meta.settings("damage_numbers_on"))
	var provider_prev: Callable = pm.baseline_provider
	var quality_prev: int = int(Meta.settings("fx_quality"))
	Meta.set_setting("damage_numbers_on", true)
	Meta.set_setting("fx_quality", 2)             # cap 80（任意起点连续 16 计数恰 2 个 8 倍数）
	pm.baseline_provider = Callable()
	pm.tick(10.0)
	pm.clear_all()
	# 前置：未满池全显（perf 保底循环同口径 TARGET 40 < 80 → N=1 零行为变化）
	for i in range(40):
		var r := DamageResult.new()
		r.final_value = 25.0
		r.target_uid = 8000 + i
		r.pos = Vector2(60.0 + float(i % 20) * 30.0, 60.0 + float(i / 20) * 30.0)
		r.popup_style = GameConst.PopupStyle.NORMAL
		pm.on_damage_resolved(r)
	_check("层2 未满池：全显 N=1（40 目标 40 条，0 丢弃）",
		pm.active_popups == 40 and pm.dropped_count() == 0)
	pm.tick(10.0)
	pm.clear_all()
	# 满池：填 80（全显）→ 16 发 NORMAL 新起尝试 → 恰 2 显 14 丢、active 恒==cap
	for i in range(80):
		var r := DamageResult.new()
		r.final_value = 1.0
		r.target_uid = 8100 + i
		r.pos = Vector2(10.0 + float(i), 10.0)
		r.popup_style = GameConst.PopupStyle.NORMAL
		pm.on_damage_resolved(r)
	_check("层2 前置：满池 80/80", pm.active_popups == 80)
	var hits0: int = int(pool.stats()["hits"])
	var dropped0: int = pm.dropped_count()
	for i in range(16):
		var r := DamageResult.new()
		r.final_value = 1.0
		r.target_uid = 8200 + i
		r.pos = Vector2(10.0, 10.0)
		r.popup_style = GameConst.PopupStyle.NORMAL
		pm.on_damage_resolved(r)
	_check("层2 满池采样：16 发 NORMAL 2 显 14 丢（确定性 mod 1/8）/ active 恒==cap",
		pm.active_popups == 80 and pm.dropped_count() == dropped0 + 14
			and int(pool.stats()["hits"]) - hits0 == 2,
		"active=%d drops=%d new=%d" % [pm.active_popups, pm.dropped_count() - dropped0,
			int(pool.stats()["hits"]) - hits0])
	# 确定性重放：再 16 发同结果（禁随机——同序列同输出）
	var dropped1: int = pm.dropped_count()
	var hits1: int = int(pool.stats()["hits"])
	for i in range(16):
		var r := DamageResult.new()
		r.final_value = 1.0
		r.target_uid = 8300 + i
		r.pos = Vector2(10.0, 10.0)
		r.popup_style = GameConst.PopupStyle.NORMAL
		pm.on_damage_resolved(r)
	_check("层2 确定性：同序列重放同结果（再 16 发再 2 显 14 丢）",
		pm.active_popups == 80 and pm.dropped_count() == dropped1 + 14
			and int(pool.stats()["hits"]) - hits1 == 2)
	# CRIT 必显：满池绕过采样（不丢、挤最老非反应槽、在册）
	var dropped2: int = pm.dropped_count()
	var rc := DamageResult.new()
	rc.final_value = 1.0
	rc.target_uid = 8400
	rc.pos = Vector2(10.0, 10.0)
	rc.popup_style = GameConst.PopupStyle.CRIT
	pm.on_damage_resolved(rc)
	var crit_seen := false
	for p: DamagePopup in pm._active_list:
		if p.style == GameConst.PopupStyle.CRIT:
			crit_seen = true
	_check("层2 CRIT 必显：满池绕过采样（active 恒 80 / 不丢 / 在册）",
		pm.active_popups == 80 and pm.dropped_count() == dropped2 and crit_seen)
	# REACTION 必显：满池走既有挤占（R4b 口径不回归）
	var dropped3: int = pm.dropped_count()
	pm._rxn_frame_stamp = -1
	var rr := DamageResult.new()
	rr.final_value = 9.0
	rr.target_uid = 8401
	rr.pos = Vector2(300.0, 400.0)
	rr.popup_style = GameConst.PopupStyle.REACTION
	rr.element = GameConst.ReactionType.RXN_FIR_ICE
	pm.on_damage_resolved(rr)
	var rxn_seen := false
	for p: DamagePopup in pm._active_list:
		if p.style == GameConst.PopupStyle.REACTION:
			rxn_seen = true
	_check("层2 REACTION 必显：满池走既有挤占（active 恒 80 / 不丢 / 在册）",
		pm.active_popups == 80 and pm.dropped_count() == dropped3 and rxn_seen)
	pm.tick(10.0)
	_check("层2 清场归还", pm.active_popups == 0)
	Meta.set_setting("fx_quality", quality_prev)
	pm.baseline_provider = provider_prev
	Meta.set_setting("damage_numbers_on", numbers_prev)


# ── 入口缓存：settings_changed 订阅即时生效 ─────────────────────────
func _test_settings_cache() -> void:
	print("── R202 入口缓存 ──")
	var pm: PopupManager = _gl.popup_manager
	var numbers_prev: bool = bool(Meta.settings("damage_numbers_on"))
	var quality_prev: int = int(Meta.settings("fx_quality"))
	pm.tick(10.0)
	pm.clear_all()
	# damage_numbers_on：写口（发信号）→ 缓存即时翻转
	Meta.set_setting("damage_numbers_on", false)
	var r := DamageResult.new()
	r.final_value = 10.0
	r.target_uid = 5501
	r.pos = Vector2(100.0, 100.0)
	r.popup_style = GameConst.PopupStyle.NORMAL
	pm.on_damage_resolved(r)
	_check("入口缓存：伤害数字关 → 跳字入口短路（0 活跃）", pm.active_popups == 0)
	Meta.set_setting("damage_numbers_on", true)
	pm.on_damage_resolved(r)
	_check("入口缓存：伤害数字开 → 跳字恢复（写口信号即时刷缓存）", pm.active_popups == 1)
	pm.tick(10.0)
	# fx_quality：写口 → cap 即时档位化（0=低 → 20；若缓存失效仍按 80 → 30 条全显红）
	Meta.set_setting("fx_quality", 0)
	for i in range(30):
		var rr := DamageResult.new()
		rr.final_value = 5.0
		rr.target_uid = 5600 + i
		rr.pos = Vector2(360.0, 400.0)
		rr.popup_style = GameConst.PopupStyle.NORMAL
		pm.on_damage_resolved(rr)
	_check("入口缓存：fx_quality 写口即时档位化（低档 30 目标封顶 20）",
		pm.active_popups == 20, "active=%d" % pm.active_popups)
	pm.tick(10.0)
	Meta.set_setting("fx_quality", quality_prev)
	Meta.set_setting("damage_numbers_on", numbers_prev)


# ── tick 等值跳过写点回归（曲线值逐位不变，只跳过重复写） ────────────
func _test_tick_write_skip() -> void:
	print("── R202 tick 等值跳过写点 ──")
	var pool: PopupPool = _gl.pools[&"popup"]
	var fxo_prev: float = float(Meta.settings("fx_opacity"))
	Meta.set_setting("fx_opacity", 1.0)           # 曲线断言按全透明度口径
	var popup: DamagePopup = pool.acquire() as DamagePopup
	popup.show_popup(Vector2(100.0, 100.0), 10.0, GameConst.PopupStyle.NORMAL)
	# 第 1 拍 t=0.2：上浮 42×0.2=8.4 / alpha 1−t²=0.96→量化 1.0 / 弹跳期内 scale≠ONE
	#（R230 K1：根 alpha 四分档量化后曲线值=量化档值，位移/弹跳曲线零变化）
	popup.tick(0.12)
	_check("tick 曲线①：t=0.2 位移/透明度（等值跳过不改曲线值；R230 K1 量化档 0.96→1.0）",
		absf(popup.position.y - 91.6) <= 0.001 and absf(popup.modulate.a - 1.0) <= 0.001
			and absf(popup.position.x - 100.0) <= 0.001,
		"pos=%s a=%.4f" % [str(popup.position), popup.modulate.a])
	_check("tick 曲线①：弹跳期 scale 过冲（≠ONE，写点未误跳）",
		popup.scale != Vector2.ONE, "scale=%s" % str(popup.scale))
	# 第 2 拍弹跳尾微收敛；第 3 拍 t=0.6：scale==ONE（收敛后等值跳过路径，值不漂）
	popup.tick(0.12)
	popup.tick(0.12)
	_check("tick 曲线②：t=0.6 位移/透明度/scale==ONE（收敛后等值跳过，值不漂；R230 K1 量化档 0.64→0.75）",
		absf(popup.position.y - 74.8) <= 0.001 and absf(popup.modulate.a - 0.75) <= 0.001
			and popup.scale == Vector2.ONE,
		"pos=%s a=%.4f scale=%s" % [str(popup.position), popup.modulate.a, str(popup.scale)])
	pool.release(popup)
	Meta.set_setting("fx_opacity", fxo_prev)

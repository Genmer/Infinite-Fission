# tests/qa_r255_perf_flow_body.gd
# R255 局中大流程用例体（入口运行时加载——autoload 全局名可用）。
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"
const WAVE_TRANSITIONS_TARGET := 10      # 自然波次推进采样数（含 w10 Boss 波抵达帧）
const FLOW_FRAMES_CAP := 24000           # 波次推进段帧帽（200s @120Hz）

var tree: SceneTree
var _gl: GameLoop = null
var _fails: int = 0


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	await _boot()
	if _fails > 0:
		return
	_flow_start_run()
	_flow_wave_transitions()
	_flow_card_open_close()
	_flow_victory_settle()
	_flow_death_settle()
	_teardown()


func fail_count() -> int:
	return _fails


func _boot() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	tree.get_root().add_child(_gl)
	var waited := 0
	while not _gl.boot_ready and waited < 600:
		await tree.process_frame
		waited += 1
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[flow] Boot 失败")
		_fails += 1


func _t(p_cb: Callable) -> int:
	var us0 := int(Time.get_ticks_usec())
	p_cb.call()
	return int(Time.get_ticks_usec()) - us0


func _median(p_arr: Array) -> float:
	if p_arr.is_empty():
		return -1.0
	var s := p_arr.duplicate()
	s.sort()
	return float(s[s.size() / 2]) / 1000.0


# ── ① 进局 ────────────────────────────────────────────────────────
func _flow_start_run() -> void:
	var us := _t(func() -> void: _gl.start_run())
	_gl.stage_probe_enabled = true
	print("[flow] start_run（MENU→PLAYING 全程，含 PopupGlyphAtlas 补烤一次性）：%.2f ms" % (float(us) / 1000.0))
	for i in range(240):
		_gl._physics_process(DT)          # 开局 2s 稳态（首波入场/横幅）


# ── ② 波次切换（自然推进帧采样） ──────────────────────────────────
func _flow_wave_transitions() -> void:
	print("── [flow] 波次切换（自然推进；敌 hp 每帧压 0.5 加速清波） ──")
	var last_wave: int = _gl.wave_director.current_wave
	var got := 0
	var boss_seen := false
	var frame_i := 0
	var victory_frame_ms := -1.0
	var victory_stage := {}
	while got < WAVE_TRANSITIONS_TARGET and frame_i < FLOW_FRAMES_CAP:
		for e in _gl.spawner.active:
			if e != null and is_instance_valid(e):
				e.set(&"hp", 0.5)          # 探针侧实例改动：加速清波（不改产品码）
		_gl.player.invuln_left = 1.0
		# 探针侧实例改动：清 xp 防升级风暴（加速清波产生的海量经验会连环弹卡，
		# state 长期停在 LEVEL_UP 把波次推进卡死——首版实测 w5 后卡 24000 帧）。
		# 波次切换帧的读数不受影响（xp 吸收在 ② 段，量级 µs 级）。
		_gl.player.set(&"xp", 0.0)
		_gl.player.set(&"xp_need", 1.0e9)
		_exit_modals()
		var t0 := Time.get_ticks_usec()
		_gl._physics_process(DT)
		var fus := Time.get_ticks_usec() - t0
		if _gl.state == GameConst.GameStatus.GAME_OVER:
			# 草原图 final_wave=10：w10 Boss 清版 → _on_wave_cleared_victory → 2.2s 窗
			# → show_victory → GAME_OVER（本探针加速清波下自然发生——真路径结算帧）
			victory_frame_ms = float(fus) / 1000.0
			victory_stage = _copy_stage()
			print("[flow] 胜利结算帧（wave_cleared→victory 窗到点→show_victory→GAME_OVER）：%.3f ms｜段=%s" % [
				victory_frame_ms, str(victory_stage)])
			break
		if _gl.wave_director.current_wave != last_wave:
			var to_w := _gl.wave_director.current_wave
			print("[flow] 波次 w%d→w%d：全帧 %.3f ms｜wave 段 %.3f ms｜敌 %d｜card_open %d µs" % [
				last_wave, to_w, float(fus) / 1000.0,
				float(int(_gl.stage_probe_us.get(&"wave", 0))) / 1000.0,
				_gl.spawner.active_count(),
				int(_gl.stage_probe_us.get(&"card_open", 0))])
			last_wave = to_w
			got += 1
			if to_w >= 10:
				boss_seen = true
		frame_i += 1
	if got == 0:
		print("[flow] 波次推进未捕获（帧帽内无切换）")
		_fails += 1
	print("[flow] 采样 %d 次切换｜含 Boss 波(≥w10)：%s" % [got, str(boss_seen)])


# ── ③ 升级选卡开合 ────────────────────────────────────────────────
func _flow_card_open_close() -> void:
	print("── [flow] 升级选卡开合（直调 _open_card_flow / choose / reroll，5 次中位） ──")
	var opens: Array = []
	var chooses: Array = []
	var rerolls: Array = []
	if _gl.state == GameConst.GameStatus.GAME_OVER:
		_flow_restart()                     # 草原 w10 胜利后 GAME_OVER → 重开进 PLAYING 再采样
	for i in range(5):
		if _gl.state != GameConst.GameStatus.PLAYING:
			print("[flow] 状态非 PLAYING（%d）——选卡采样中止于第 %d 轮" % [_gl.state, i])
			break
		_gl.player.level += 1
		var us_open := _t(func() -> void: _gl._open_card_flow(_gl.player.level))
		opens.append(us_open)
		if i == 0 and _gl.card_select_ui.is_open:
			var us_rr := _t(func() -> void: _gl._on_card_reroll())
			rerolls.append(us_rr)
		if _gl.card_select_ui.is_open:
			var us_ch := _t(func() -> void: _gl.card_select_ui.choose(0))
			chooses.append(us_ch)
		# choose 后回 PLAYING；若连升队列卡 LEVEL_UP，消化几帧
		for f in range(24):
			if _gl.state == GameConst.GameStatus.PLAYING:
				break
			_exit_modals()
			_gl._physics_process(DT)
	print("[flow] 开卡 _open_card_flow：%d 次中位 %.2f ms（样本 %s µs）" % [
		opens.size(), _median(opens), str(opens)])
	print("[flow] 选卡合卡 choose(0)：%d 次中位 %.2f ms（样本 %s µs）" % [
		chooses.size(), _median(chooses), str(chooses)])
	print("[flow] 换一批 _on_card_reroll：%d 次中位 %.2f ms（样本 %s µs）" % [
		rerolls.size(), _median(rerolls), str(rerolls)])


# ── ④ 胜利结算 ────────────────────────────────────────────────────
func _flow_victory_settle() -> void:
	print("── [flow] 胜利结算（_on_wave_cleared_victory → 2.2s 收尾窗 → show_victory） ──")
	if _gl.state != GameConst.GameStatus.PLAYING:
		print("[flow] 起始态非 PLAYING（%d）——胜利结算跳过" % _gl.state)
		return
	var final_wave: int = _gl.wave_director.wave_table.final_wave if _gl.wave_director.wave_table != null else 20
	_t(func() -> void: _gl._on_wave_cleared_victory(final_wave))
	var settle_frame_ms := -1.0
	var settle_stage := {}
	var frames := 0
	while _gl.state == GameConst.GameStatus.PLAYING and frames < 600:
		var t0 := Time.get_ticks_usec()
		_gl._physics_process(DT)
		var fus := Time.get_ticks_usec() - t0
		if float(fus) / 1000.0 > settle_frame_ms:
			settle_frame_ms = float(fus) / 1000.0
			settle_stage = _copy_stage()
		_exit_modals()
		frames += 1
	print("[flow] 胜利结算：状态=%d（20=GAME_OVER）｜收尾窗最差帧 %.3f ms｜段=%s" % [
		_gl.state, settle_frame_ms, str(settle_stage)])


# ── ⑤ 重开 ────────────────────────────────────────────────────────
func _flow_restart() -> float:
	if _gl.state != GameConst.GameStatus.GAME_OVER:
		print("[flow] 状态非 GAME_OVER（%d）——restart 采样跳过" % _gl.state)
		return -1.0
	var us := _t(func() -> void: _gl.restart_run())
	print("[flow] restart_run（GAME_OVER→PLAYING 全程）：%.2f ms" % (float(us) / 1000.0))
	return float(us) / 1000.0


# ── ⑥ 死亡结算 ────────────────────────────────────────────────────
func _flow_death_settle() -> void:
	if _gl.state != GameConst.GameStatus.PLAYING:
		print("[flow] 状态非 PLAYING（%d）——死亡结算跳过" % _gl.state)
		return
	var us := _t(func() -> void: EventBus.player_died.emit())
	for i in range(8):
		_gl._physics_process(DT)
	print("[flow] 死亡结算 player_died→_on_player_died→GAME_OVER+败画面：%.2f ms（状态=%d）" % [
		float(us) / 1000.0, _gl.state])


func _exit_modals() -> void:
	# 探针侧模态退出：波表 SHOP 波开 shop_ui（自动出击窗仅挂机模式驱动——首版实测
	# w5 商店波把 state 卡 LEVEL_UP 24000 帧）/ 红卡大屏同型。
	if _gl.state != GameConst.GameStatus.LEVEL_UP:
		return
	if _gl.card_select_ui != null and _gl.card_select_ui.is_open:
		_gl.card_select_ui.choose(0)
	elif _gl.shop_ui != null and _gl.shop_ui.is_shop_visible():
		_gl.shop_ui.close()
	elif _gl.get(&"sublime_confirm_ui") != null \
			and (_gl.get(&"sublime_confirm_ui") as Object).has_method(&"is_open") \
			and bool((_gl.get(&"sublime_confirm_ui") as Object).call(&"is_open")):
		(_gl.get(&"sublime_confirm_ui") as Object).call(&"confirm")


func _copy_stage() -> Dictionary:
	var out := {}
	for k in _gl.stage_probe_us:
		out[String(k)] = int(_gl.stage_probe_us[k])
	return out


func _teardown() -> void:
	tree.paused = false
	if _gl != null:
		_gl.free()
		_gl = null

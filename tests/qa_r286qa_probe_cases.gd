# tests/qa_r286qa_probe_cases.gd（R286 QA 独立探针用例体——入口运行时加载）
# 探查面（任务书 a-e）：
#   p1/p2 (d) 键名无碰撞：MENU 行与 PLAYING 行各九键子串恰出现一次；结µs/死µs 不冲突。
#   p3 (a) 非 PLAYING 态（MENU）段窗和恒 0（直驱 _physics_process 不累计）。
#   p4 (a) 段窗和量纲自洽：段和µs vs 同窗步µs 逐表对账（移/火子集键是否双计——结构疑点
#          game_loop.gd:877 循环遍历全键含 player_mv/player_wp，而 debug_stats 既有两处
#          段和（物理减项 :375 / 余值 :485）均显式跳过该两子集键）。
#   p5 (b) 五桶 1Hz 生命周期：读不复位 / 1Hz 行单次消费后复位 / 采样门推离=零消费
#          （deeprepro G1 手动读桶不双跑的前提）。
#   p6 (a) 复位口幂等 + 离场后不复活。
#   p7 (c) S9 隔离：进程内整跑 qa_r271_deeprepro_cases 后全部短路 static 复位出厂态。
# 纪律：不写 Meta._settings（零盘污染）；1Hz 采样窗经 _diag_last_ms 推界防中途复位。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DEEPREPRO_CASES := "res://tests/qa_r271_deeprepro_cases.gd"
const NINE_KEYS: Array[String] = [" 命µs", " 提µs", " 灭µs", " 回µs", " ipµs",
	" 段和µs", " 弹段µs", " 网段µs", " 敌段µs"]

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: Node = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261017)
	await _boot()
	_p1_menu_line_keys()
	_p3_menu_no_accum()
	await _p2_playing_line_keys()
	_p4_dimension_audit()
	_p5_bucket_lifecycle()
	_p6_reset_idempotent()
	await _p7_s9_isolation()
	_teardown()


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


func _gate_push() -> void:
	DebugStats._diag_last_ms = Time.get_ticks_msec() + 10000000


func _boot() -> void:
	print("── boot（main.tscn 真链 → MENU） ──")
	var main: Node = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	_gl = tree.root.get_node_or_null("Main")
	if _gl == null:
		for c in tree.root.get_children():
			if c != null and c.has_method("diag_counts"):
				_gl = c
				break
	_gl.state = GameConst.GameStatus.MENU
	await tree.process_frame
	await tree.process_frame


# ── p1 (d)：MENU 行键碰撞 ───────────────────────────────────────────

func _count_keys(p_line: String) -> Dictionary:
	var out: Dictionary = {}
	for k in NINE_KEYS:
		out[k] = p_line.count(k)
	out[" 死µs"] = p_line.count(" 死µs")
	out[" 结µs"] = p_line.count(" 结µs")
	return out


func _p1_menu_line_keys() -> void:
	print("── p1 键名无碰撞（MENU 行，gl 在场全键上墙） ──")
	DebugStats._diag_last_ms = Time.get_ticks_msec()
	var line := DebugStats._diag_format_line(_gl, Time.get_ticks_msec())
	var counts := _count_keys(line)
	var all_once := true
	var bad := ""
	for k in counts:
		if int(counts[k]) != 1:
			all_once = false
			bad += "%s×%d " % [k, int(counts[k])]
	_check("p1 MENU 行：九键+死µs+结µs 各恰出现一次", all_once, bad + "|" + line.right(150))
	var rx := RegEx.new()
	rx.compile(" 段和µs(\\d+)")
	var m := rx.search(line)
	_check("p1 MENU 行：段和µs=0（非 PLAYING 窗不累计）",
		m != null and m.get_string(1) == "0", line.right(120))


# ── p3 (a)：MENU 直驱不累计 ─────────────────────────────────────────

func _win_sums() -> Array:
	return [int(_gl.get("_stage_win_sum_us")), int(_gl.get("_stage_win_proj_us")),
		int(_gl.get("_stage_win_grid_us")), int(_gl.get("_stage_win_enemy_us"))]


func _p3_menu_no_accum() -> void:
	print("── p3 非 PLAYING 态（MENU）段窗和恒 0 ──")
	_gate_push()
	_gl.stage_probe_enabled = true
	_gl.diag_reset_stage_win_sums()
	for i in range(30):
		_gl._physics_process(1.0 / 60.0)
	var s := _win_sums()
	_check("p3 MENU 直驱 30 步：四累计器恒 0", s[0] == 0 and s[1] == 0 and s[2] == 0 and s[3] == 0,
		"和/弹/网/敌=%d/%d/%d/%d" % [s[0], s[1], s[2], s[3]])
	_gl.stage_probe_enabled = false


# ── p2 (d)：PLAYING 行键碰撞 ────────────────────────────────────────

func _p2_playing_line_keys() -> void:
	print("── p2 键名无碰撞（PLAYING 行，段窗和>0 态） ──")
	_gate_push()
	if not _gl.start_run():
		_check("p2 start_run 进场", false, "start_run 失败")
		return
	var gatling: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	if gatling != null:
		gatling.level = 3
	_gl.stage_probe_enabled = true
	for i in range(30):
		_gl._physics_process(1.0 / 60.0)
	DebugStats._diag_last_ms = Time.get_ticks_msec()
	var line := DebugStats._diag_format_line(_gl, Time.get_ticks_msec())
	var counts := _count_keys(line)
	var all_once := true
	var bad := ""
	for k in counts:
		if int(counts[k]) != 1:
			all_once = false
			bad += "%s×%d " % [k, int(counts[k])]
	_check("p2 PLAYING 行：九键+死µs+结µs 各恰出现一次", all_once, bad + "|" + line.right(150))
	var rx := RegEx.new()
	rx.compile(" 段和µs(\\d+)")
	var m := rx.search(line)
	_check("p2 PLAYING 行：段和µs>0（窗内有真读数）",
		m != null and int(m.get_string(1)) > 0, line.right(130))


# ── p4 (a)：段窗和量纲对账（双计定谳） ──────────────────────────────

func _table_full_sum(p_tbl: Dictionary) -> int:
	var s := 0
	for k in p_tbl:
		s += int(p_tbl[k])
	return s


func _table_mvwp(p_tbl: Dictionary) -> int:
	return int(p_tbl.get(&"player_mv", 0)) + int(p_tbl.get(&"player_wp", 0))


func _p4_dimension_audit() -> void:
	print("── p4 段窗和 vs 同窗步µs 逐表对账（同步块直驱——引擎步零穿插） ──")
	# 同步块：复位秒窗累计器 → 1 次预热步（产 table_w）→ 复位段窗和 → 120 步测量，逐步
	# 快照整表（全键和 T、移+火 M）。窗语义：步入口累计上一完整步表 ⇒ 段窗和 = table_w +
	# Σ table_1..119；步µs 窗 = step_w + Σ step_1..120。他键=全函数−去子集段和 ⇒ 整表
	# T_x = step_x + M_x − 尾巴 glue（尾巴=other 计点→步出口间 µs 级）⇒ 恒等式：
	#   段和 − 步µs窗 = (M_w + ΣM_1..119) − step_120 − 尾巴
	DebugStats._diag_reset_window_acc()
	_gl.diag_reset_stage_win_sums()
	_gl.stage_probe_enabled = true
	_gl._physics_process(1.0 / 60.0)                     # 预热步 w：产 table_w
	var tbl_w: Dictionary = (_gl.get("stage_probe_us") as Dictionary).duplicate()
	var t_w := _table_full_sum(tbl_w)
	var m_w := _table_mvwp(tbl_w)
	_gl.diag_reset_stage_win_sums()                      # 段窗和归零（表保留=table_w）
	var t_sum := 0
	var m_sum := 0
	var steps := 120
	var t_last := 0
	var m_last := 0
	for i in range(steps):
		_gl._physics_process(1.0 / 60.0)
		var tbl: Dictionary = (_gl.get("stage_probe_us") as Dictionary).duplicate()
		if i < steps - 1:                                # 末表不进窗（下一帧入口才累计）
			t_sum += _table_full_sum(tbl)
			m_sum += _table_mvwp(tbl)
		else:
			t_last = _table_full_sum(tbl)
			m_last = _table_mvwp(tbl)
	var sums := int(_gl.get("_stage_win_sum_us"))
	var step_total := int(DebugStats._diag_step_us)
	var mvwp_component := m_w + m_sum
	var step_last_approx := t_last - m_last              # T_120 = step_120 + M_120 − 尾 ⇒ 步近似
	var resid := (sums - step_total) - (mvwp_component - step_last_approx)
	_check("p4a PLAYING 120 步：段和µs（窗累计）> 0", sums > 0,
		"sums=%d step_total=%d mvwp分量=%d" % [sums, step_total, mvwp_component])
	_check("p4b 段和µs ≤ 同窗步µs（量纲自洽——移/火子集不双计）", sums <= step_total,
		"段和µs=%d 步µs=%d 差=%+d（%.1f%%）——差>0 即移/火子集双计证据（结构：game_loop.gd:877 全键遍历）"
			% [sums, step_total, sums - step_total,
				100.0 * float(sums - step_total) / float(maxi(step_total, 1))])
	# R286 修轮重校（主会话随 D1 修复同步）：段和已剔除 移/火 子集键——旧恒等式
	#（差值恰=+移火）系双计期签名作废；修复后 步µs−段和 ≈ 末步表（未入窗）+帧内探针
	# 间隙胶水，断有界带（0 ≤ 差 ≤ 末步全量+末移火+3000µs 胶水容差）。
	var gap_post := step_total - sums
	_check("p4c 差额有界=末步表+胶水容差（修复后恒等式——移/火已剔除，|超出|≤3000µs）",
		gap_post >= 0 and gap_post <= t_last + m_last + 3000,
		"(步µs−段和)=%d 末步全量+末移火=%d 容差=3000（tw=%d mw=%d t1..119=%d m1..119=%d t120=%d m120=%d）"
			% [gap_post, t_last + m_last, t_w, m_w, t_sum, m_sum, t_last, m_last])
	_gl.stage_probe_enabled = false
	_gl.diag_reset_stage_win_sums()


# ── p5 (b)：五桶 1Hz 生命周期 ───────────────────────────────────────

func _p5_bucket_lifecycle() -> void:
	print("── p5 五桶生命周期（读/消费/门推离） ──")
	# b1 读不复位（R269 语义：复位统一 _diag_reset_window_acc）
	DebugStats._diag_reset_window_acc()
	DebugStats.bucket_begin(&"hit_collect")
	OS.delay_msec(2)
	DebugStats.bucket_end(&"hit_collect")
	var v1 := int(DebugStats.diag_bucket_window_us(&"hit_collect"))
	var v2 := int(DebugStats.diag_bucket_window_us(&"hit_collect"))
	_check("p5b1 读取不复位（两次读同值 ≥2000µs）", v1 == v2 and v1 >= 2000, "v1=%d v2=%d" % [v1, v2])
	DebugStats._diag_reset_window_acc()
	_check("p5b1 _diag_reset_window_acc 后归零", int(DebugStats.diag_bucket_window_us(&"hit_collect")) == 0, "")
	# b2 1Hz 行单次消费（gate 到期 → 行取值 → 桶复位 → 段窗和复位）
	DebugStats._diag_last_ms = Time.get_ticks_msec() - 2000
	DebugStats._diag_reset_window_acc()
	DebugStats.bucket_begin(&"hit_collect")
	OS.delay_msec(2)
	DebugStats.bucket_end(&"hit_collect")
	var inject := int(DebugStats.diag_bucket_window_us(&"hit_collect"))
	_gl.stage_probe_enabled = true
	for i in range(3):
		_gl._physics_process(1.0 / 60.0)
	var pre_sums := int(_gl.get("_stage_win_sum_us"))
	var lines_before := DebugStats._diag_lines.size()
	DebugStats._diag_maybe_sample()
	var rx := RegEx.new()
	rx.compile(" 命µs(\\d+)")
	var m := rx.search(String(DebugStats._diag_lines[DebugStats._diag_lines.size() - 1]))
	_check("p5b2 1Hz 行含注入值（命µs=注入读数，单次消费）",
		DebugStats._diag_lines.size() == lines_before + 1 and m != null and int(m.get_string(1)) == inject,
		"inject=%d 行值=%s 行数+%d" % [inject, m.get_string(1) if m != null else "?",
			DebugStats._diag_lines.size() - lines_before])
	_check("p5b2 消费后桶归零 ∧ 段窗和同步复位",
		int(DebugStats.diag_bucket_window_us(&"hit_collect")) == 0 and int(_gl.get("_stage_win_sum_us")) == 0,
		"桶=%d 段和=%d（pre=%d inject=%d）" % [int(DebugStats.diag_bucket_window_us(&"hit_collect")),
			int(_gl.get("_stage_win_sum_us")), pre_sums, inject])
	# b3 采样门推离=零消费（deeprepro G1 前提：手动读桶期间 1Hz 不复位不拼行）
	_gate_push()
	DebugStats._diag_reset_window_acc()
	DebugStats.bucket_begin(&"hit_collect")
	OS.delay_msec(2)
	DebugStats.bucket_end(&"hit_collect")
	var v3 := int(DebugStats.diag_bucket_window_us(&"hit_collect"))
	for i in range(4):
		_gl._physics_process(1.0 / 60.0)
	var s3 := int(_gl.get("_stage_win_sum_us"))
	var lines_b3 := DebugStats._diag_lines.size()
	DebugStats._diag_maybe_sample()
	_check("p5b3 门推离期 _diag_maybe_sample 零消费（桶/段窗和/行数均不变——deeprepro 前提）",
		int(DebugStats.diag_bucket_window_us(&"hit_collect")) == v3
			and int(_gl.get("_stage_win_sum_us")) == s3
			and DebugStats._diag_lines.size() == lines_b3,
		"桶 %d→%d 段和 %d→%d 行数 %d→%d" % [v3, int(DebugStats.diag_bucket_window_us(&"hit_collect")),
			s3, int(_gl.get("_stage_win_sum_us")), lines_b3, DebugStats._diag_lines.size()])
	_gl.stage_probe_enabled = false


# ── p6 (a)：复位口幂等 + 离场不复活 ─────────────────────────────────

func _p6_reset_idempotent() -> void:
	print("── p6 复位口幂等 ──")
	var s := _win_sums()
	_check("p6 前置：p5b3 驱动后段窗和 > 0", s[0] > 0, "和=%d" % s[0])
	_gl.diag_reset_stage_win_sums()
	var s1 := _win_sums()
	_gl.diag_reset_stage_win_sums()
	var s2 := _win_sums()
	_check("p6 复位幂等（两次调用四累计器均 0）",
		s1[0] == 0 and s1[1] == 0 and s1[2] == 0 and s1[3] == 0
			and s2[0] == 0 and s2[1] == 0 and s2[2] == 0 and s2[3] == 0,
		"一call=%d/%d/%d/%d 二call=%d/%d/%d/%d" % [s1[0], s1[1], s1[2], s1[3], s2[0], s2[1], s2[2], s2[3]])
	_gl.state = GameConst.GameStatus.MENU
	_gl.stage_probe_enabled = true
	for i in range(5):
		_gl._physics_process(1.0 / 60.0)
	var s3 := _win_sums()
	_check("p6 离场 PLAYING 后 MENU 步不复活累计", s3[0] == 0 and s3[1] == 0 and s3[2] == 0 and s3[3] == 0,
		"和/弹/网/敌=%d/%d/%d/%d" % [s3[0], s3[1], s3[2], s3[3]])
	_gl.stage_probe_enabled = false


# ── p7 (c)：S9 隔离（进程内整跑 deeprepro 后 statics） ──────────────

func _p7_s9_isolation() -> void:
	print("── p7 S9 隔离（进程内整跑 qa_r271_deeprepro_cases → 末态 statics） ──")
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null
	await tree.process_frame
	await tree.process_frame
	var dr_script: GDScript = load(DEEPREPRO_CASES)
	if dr_script == null or not dr_script.can_instantiate():
		_check("p7 deeprepro 用例体加载", false, str(dr_script))
		return
	var dr = dr_script.new()
	await dr.run(tree, false)
	var dr_fail := int(dr.fail_count())
	_check("p7 进程内 deeprepro 复跑全绿（对照独立跑 22/22）", dr_fail == 0, "FAIL=%d" % dr_fail)
	_check("p7 跑完整个 deeprepro 后 shortcircuit_proj_stage 复位 false",
		not GameLoop.shortcircuit_proj_stage, "值=%s" % str(GameLoop.shortcircuit_proj_stage))
	var all_factory := not ProjectileBase.shortcircuit_tick \
		and not TexBucketHost.shortcircuit_place and not TexBucketHost.shortcircuit_sync \
		and not PopupManager.shortcircuit_spawn and not GameLoop.shortcircuit_ip_pass \
		and GameLoop.grid_hit_override == -1 and GameLoop.death_flush_override == -1
	_check("p7 其余短路注入口同复位出厂（tick/place/sync/spawn/ip/override=-1）", all_factory,
		"tick=%s place=%s sync=%s spawn=%s ip=%s g=%d d=%d" % [ProjectileBase.shortcircuit_tick,
			TexBucketHost.shortcircuit_place, TexBucketHost.shortcircuit_sync,
			PopupManager.shortcircuit_spawn, GameLoop.shortcircuit_ip_pass,
			GameLoop.grid_hit_override, GameLoop.death_flush_override])


func _teardown() -> void:
	tree.paused = false
	RunSave.clear()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])

# tests/_qa1_r232_settleus_probe.gd
# R232 QA1 专项探针（验收点 5：结µs 键端到端）——非电池资产（_ 前缀，禁 test_ 前缀）。
# 跑法：godot --headless --path <工程> -s res://tests/_qa1_r232_settleus_probe.gd
# 口径：真实主循环跑最小战斗态 → ① pipeline.settle_us_total()>0（damage_pipeline 计时
# 窗在跑）→ ② diag_counts["settle_us_per"] 键在场（game_loop 秒差分出口）→ ③ 战斗秒内
# _diag_format_line 实际行含「结µsN」且 N>0（debug_stats 行尾键活值）→ ③b DebugStats
# 环内 1Hz 自然采样行含「结µs」段。纪律：-s 入口零工程类名直引，运行时 load/call。
extends SceneTree

var _fail: int = 0


func _initialize() -> void:
	_run()


func _run() -> void:
	print("════ R232 QA1 结µs 端到端探针 ════")
	await process_frame
	await process_frame
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var gl: Node = root.get_node_or_null("Main")
	if gl == null:
		for c in root.get_children():
			if c.get_script() != null:
				gl = c
				break
	if gl == null:
		print("FAIL | 主循环未找到")
		quit(1)
		return
	gl.set("state", 2)                                     # GameConst.GameStatus.PLAYING
	var player: Node2D = gl.get("player")
	player.set("xp_need", 1.0e12)
	player.set("max_hp", 1.0e12)
	player.set("hp", 1.0e12)
	player.global_position = Vector2(360.0, 1050.0)
	var registry = gl.get("registry")
	var gatling = player.call("add_weapon", registry.call("get_weapon", &"W2_gatling"))
	print("  夹具：W2_gatling 挂载=%s" % str(gatling != null))
	var epool = gl.get("pools").get(&"enemy")
	var spawner = gl.get("spawner")
	_spawn_wave(epool, spawner, gl, 16, 30.0)
	# 真实主循环跑 4.5s（第一战斗窗）
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 4500:
		await process_frame
	var pipeline = gl.get("pipeline")
	var us_total: int = int(pipeline.call("settle_us_total"))
	var settles: int = int(pipeline.call("stats").get("settles", 0))
	print("  ① pipeline.settle_us_total=%d µs · settles=%d" % [us_total, settles])
	_chk("① 计时窗在跑（settle_us_total>0 且 settles>0）", us_total > 0 and settles > 0)
	# 第二战斗窗：补一波低血敌 → 1.3s 内必有 1Hz 采样落战斗秒 → 立即格式化行读活值
	_spawn_wave(epool, spawner, gl, 24, 20.0)
	await create_timer(1.3).timeout
	var dbg = root.get_node_or_null("DebugStats")
	var line: String = String(dbg.call("_diag_format_line", gl, Time.get_ticks_msec()))
	print("  ③ 战斗秒格式化行（尾段）：%s" % line.right(140))
	var tok := ""
	var j := line.find("结µs")
	if j >= 0:
		var k := j + 3
		while k < line.length() and line.unicode_at(k) >= 48 and line.unicode_at(k) <= 57:
			k += 1
		tok = line.substr(j, k - j)
	_chk("③ 行文本含「结µsN」段且战斗秒 N>0（N=%s）" % (tok.substr(3) if tok != "" else "?"),
		tok != "" and int(tok.substr(3)) > 0)
	var c2: Dictionary = gl.call("diag_counts")
	print("  ② diag_counts.settle_us_per 键在场=%s（次拉值 %d）" % [str(c2.has(&"settle_us_per")), int(c2.get(&"settle_us_per", -1))])
	_chk("② 差分出口可读（settle_us_per 键在场且 ≥0）", c2.has(&"settle_us_per") and int(c2.get(&"settle_us_per", -1)) >= 0)
	# DebugStats 环内自然采样行（1Hz 采样器真实落行证据）
	var ring = dbg.get("_diag_lines")
	var found := false
	var nonzero := false
	if ring != null:
		for l in ring:
			var s := String(l)
			if s.find("结µs") >= 0:
				found = true
				if _tail_num(s) > 0:
					nonzero = true
					print("  ③b 环内战斗采样行（尾段）：%s" % s.right(140))
	_chk("③b DebugStats 环内存在含「结µs」的 1Hz 自然采样行（战斗秒活值>0）", found and nonzero)
	print("────────────────────────")
	print("QA1 结µs 探针：FAIL %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _tail_num(p_line: String) -> int:
	var j := p_line.rfind("结µs")
	if j < 0:
		return -1
	var k := j + 3
	while k < p_line.length() and p_line.unicode_at(k) >= 48 and p_line.unicode_at(k) <= 57:
		k += 1
	return int(p_line.substr(j + 3, k - j - 3))


func _spawn_wave(p_epool, p_spawner, p_gl, p_n: int, p_hp: float) -> void:
	var data_script: GDScript = load("res://scripts/core/data/resources/enemy_data.gd")
	for i in range(p_n):
		var e: Node2D = p_epool.call("acquire")
		var d: Resource = data_script.new()
		d.set("id", &"E_QA1_SETTLEUS")
		d.set("display_name", "QA1_SETTLEUS")
		d.set("hp_base", p_hp)
		d.set("spd_base", 0.0)
		d.set("dmg_base", 0.0)
		d.set("exp_base", 1.0)
		d.set("hitbox_r", 14.0)
		d.set("resist", [0.0, 0.0, 0.0, 0.0])
		e.call("spawn", d, 1, 0)
		e.set("_fade_left", 0.0)
		e.global_position = Vector2(120.0 + 40.0 * (i % 8), 300.0 + 55.0 * (i / 8))
		p_spawner.get("active").append(e)
	p_gl.get("enemy_grid").call("rebuild", p_spawner.get("active"))


func _chk(p_name: String, p_cond: bool) -> void:
	if p_cond:
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		print("  FAIL | %s" % p_name)

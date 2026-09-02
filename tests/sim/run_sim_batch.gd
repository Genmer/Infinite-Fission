# tests/sim/run_sim_batch.gd
# v1.5.0 TTK 复校跑批入口（两段式，pkg14 模式：-s 脚本只做引导，用例体运行时 load——
# autoload 未注册期不触发 sim 类编译）：
#   godot --headless --path <工程> -s tests/sim/run_sim_batch.gd --mode=<mode>
# 模式（OS.get_cmdline_user_args 消费，缺省 cell）：
#   cell   —— 单格自检：T1|w1|E1（K1 手工验证口径，~0.6s 量级 72/(24×5.5)）
#   smoke  —— 缩减批 18 格：T1/T4/T7b × w1/10/40 × E1/E6_ns（K2 核对）
#   full   —— 全批 360 行 + detect 五点 + CSV（K4/K5）
#   p50    —— P50 侧写 270 行（5 seed × T1/T2/T3，只记录）
#   align  —— 对齐门 61 条（pkg1/pkg3/pkg11/pkg12 冻结锚点逐位对账）
extends SceneTree


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · v1.5.0 TTK 复校跑批（A14） ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats）
	await process_frame
	await process_frame
	var mode := _arg("mode", "cell")
	var t0 := Time.get_ticks_usec()
	var ok := true
	match mode:
		"cell":
			ok = _mode_cell()
		"smoke":
			ok = _mode_smoke()
		"full":
			ok = _mode_full()
		"p50":
			ok = _mode_p50()
		"align":
			ok = _mode_align()
		_:
			push_error("[run_sim_batch] 未知 mode：%s" % mode)
			quit(1)
			return
	print("── 耗时 %.1fs ──" % (float(Time.get_ticks_usec() - t0) / 1000000.0))
	quit(0 if ok else 1)


func _mode_cell() -> bool:
	# K1 手工验证：T1|w1|E1 期望 ~0.6s 量级（72/(24×5.5)=0.545s 理想值）
	var env: Object = (load("res://tests/sim/sim_env.gd") as GDScript).build(42)
	var weapons: Array = (load("res://tests/sim/sim_template.gd") as GDScript) \
		.build(env, "T1", 1)
	var r: Dictionary = (load("res://tests/sim/sim_engine.gd") as GDScript) \
		.run_cell(env, weapons, 1, "E1", 42)
	print("T1|w1|E1 → %s" % str(r))
	var ok: bool = int(r["ttk_frames"]) > 0 and float(r["t_clear_est"]) < 0.9
	print("K1 自检：%s" % ("PASS" if ok else "FAIL"))
	env.dispose()
	return ok


func _mode_smoke() -> bool:
	# K2 缩减批核对：18 格全 NTK 之外的格子有值 + 模板全装配无 assert
	var rows: Array = (load("res://tests/sim/sim_batch.gd") as GDScript).run_smoke()
	var ntk := 0
	for row in rows:
		var tag := "%s|%d|%s" % [row["template"], row["wave"], row["kind"]]
		var ttk := int(row["ttk_frames"])
		print("  %s → ttk=%d%s t=%.2fs dps=%.0f hits=%d crit=%d" % [tag, ttk,
			("(盾破@%d)" % int(row["shield_break_frames"]))
				if int(row["shield_break_frames"]) > 0 else "",
			float(row["t_clear_est"]), float(row["dps"]),
			int(row["n_hits"]), int(row["n_crit"])])
		if ttk < 0:
			ntk += 1
	print("smoke：%d 格（NTK %d）" % [rows.size(), ntk])
	return rows.size() == 18


func _mode_full() -> bool:
	var report: Dictionary = (load("res://tests/sim/sim_batch.gd") as GDScript).run_all()
	var p50: Array = (load("res://tests/sim/sim_batch.gd") as GDScript).run_p50_side()
	var csv_dir: String = (load("res://tests/sim/sim_batch.gd") as GDScript) \
		.write_csv(report["rows"], p50, report["detect"])
	print((load("res://tests/sim/sim_batch.gd") as GDScript).emit_tables(report))
	print("CSV 目录：%s（truncated=%s 耗时 %.1fs）" % [csv_dir,
		str(report["truncated"]), float(report["elapsed_s"])])
	return not bool(report["truncated"])


func _mode_p50() -> bool:
	var p50: Array = (load("res://tests/sim/sim_batch.gd") as GDScript).run_p50_side()
	var ntk := 0
	for row in p50:
		if int(row["ttk_frames"]) < 0:
			ntk += 1
	print("p50：%d 行（NTK %d，只记录）" % [p50.size(), ntk])
	return p50.size() == 270


func _mode_align() -> bool:
	# K3 对齐门：pkg1/pkg3/pkg11/pkg12 冻结锚点逐位对账（配额 22/20/6/8）
	var env: Object = (load("res://tests/sim/sim_env.gd") as GDScript).build(42)
	var result: Dictionary = (load("res://tests/sim/sim_align.gd") as GDScript).run(env)
	env.dispose()
	print("对齐门：pkg1 %d/%d · pkg3 %d/%d · pkg11 %d/%d · pkg12 %d/%d（配额 22/20/6/8）" % [
		int(result["pkg1"]["pass"]), int(result["pkg1"]["total"]),
		int(result["pkg3"]["pass"]), int(result["pkg3"]["total"]),
		int(result["pkg11"]["pass"]), int(result["pkg11"]["total"]),
		int(result["pkg12"]["pass"]), int(result["pkg12"]["total"])])
	for f in result["failures"]:
		print("  FAIL %s" % f)
	print("对齐门：%s（双跑自检含内）" % ("PASS" if bool(result["quotas_ok"])
		and (result["failures"] as Array).is_empty() else "FAIL"))
	return bool(result["quotas_ok"]) and (result["failures"] as Array).is_empty()


func _arg(p_key: String, p_default: String) -> String:
	# 兼容两种传参形态：-- --mode=x（user_args）与 --mode=x（引擎参数尾随，忽略未知键）
	var needle := "--%s=" % p_key
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if s.begins_with(needle):
			return s.substr(needle.length())
	for a in OS.get_cmdline_args():
		var s := String(a)
		if s.begins_with(needle):
			return s.substr(needle.length())
	return p_default

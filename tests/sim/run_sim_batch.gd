# tests/sim/run_sim_batch.gd
# v1.5.0 TTK 复校跑批入口（两段式，pkg14 模式：-s 脚本只做引导，用例体运行时 load——
# autoload 未注册期不触发 sim 类编译）：
#   godot --headless --path <工程> -s tests/sim/run_sim_batch.gd --mode=<mode>
# 模式（OS.get_cmdline_user_args 消费，缺省 cell；K2/K3/K4 扩展 smoke/full/p50/align）：
#   cell   —— 单格自检：T1|w1|E1（K1 手工验证口径，~0.6s 量级 72/(24×5.5)）
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


func _arg(p_key: String, p_default: String) -> String:
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if s.begins_with("--%s=" % p_key):
			return s.substr(String("--%s=" % p_key).length())
	return p_default

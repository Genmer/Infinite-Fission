# tests/sim/sim_batch.gd
# v1.5.0 TTK 复校工装（A14）：跑批编排 + CSV 落盘 + 五点判定（纯静态）。
# · run_all()：8 模板 × 9 波 × 5 敌种 = 360 行（seed 42；每模板独立 SimEnv）；
#   墙钟 ≤300s（超时截断留痕 truncated=true）。
# · run_smoke()：T1/T4/T7b × w1/10/40 × E1/E6_ns = 18 格缩减批。
# · run_p50_side()：5 seed × {T1,T2,T3} × 全波 × E1/E6_ns = 270 行（只记录不判定）。
# · detect(rows)：五点判定（A14 §5 冻结）——
#   ① 小怪中心带：全 E1 网格 TTK P50，锚 1.2s，DRIFT[1.08,1.32]（±10%），RED[0.60,1.80]（±50%）
#   ② Boss 锚：T3|10|E6_ns，锚 32s，DRIFT[28.8,35.2]，RED[16,64]，NTK 单列
#   ③ 漂移斜率：逐模板 (TTK(40)/TTK(1))^(1/39)−1（E1 口径）；(1+s)^30 > 1.10 → RED（30 波红线），
#      > 1.05 → DRIFT，其余 OK；任一臂 NTK → NTK
#   ④ 构筑方差：逐波 E1 跨 8 模板 TTK P95/P5，取波间 P50；≤1.39 OK / ≤1.50 DRIFT / >1.50 RED
#   ⑤ 赐福增幅：w30（n=29）E1 口径 DPS 增幅 vs T1——T7a 锚 +29% / T7b 锚 +116%（atk×0.04×29）；
#      相对偏差 ≤10% OK / ≤25% DRIFT / >25% RED；基格 NTK → NTK
# · write_csv()：user://sim_batch/<ts>/cells.csv + p50.csv + detect.json（CSV/scratch 一律 user://）。
# · clean_user_out()：跑批前自动清 user://sim_batch。
class_name SimBatch
extends RefCounted

const WAVES: Array[int] = [1, 5, 10, 15, 20, 25, 30, 35, 40]
const KINDS: Array[String] = ["E1", "E5", "E5_ns", "E6", "E6_ns"]
const P50_SEEDS: Array[int] = [42, 137, 7, 999, 20260901]
const P50_TEMPLATES: Array[String] = ["T1", "T2", "T3"]
const P50_KINDS: Array[String] = ["E1", "E6_ns"]
const BASE_SEED := 42
const WALL_CLOCK_CAP_MS := 300000             # ≤300s 墙钟（超时截断留痕）
const OUT_ROOT := "user://sim_batch"

# ── 跑批 ──────────────────────────────────────────────────────────
static func run_all() -> Dictionary:
	clean_user_out()
	var rows: Array[Dictionary] = []
	var t0 := Time.get_ticks_usec()
	var truncated := false
	for tid in SimTemplate.IDS:
		var env := SimEnv.build(BASE_SEED)
		for w in WAVES:
			var weapons := SimTemplate.build(env, tid, w)
			for kind in KINDS:
				var r := SimEngine.run_cell(env, weapons, w, kind, BASE_SEED)
				rows.append(_row(tid, w, kind, BASE_SEED, r))
			if Time.get_ticks_usec() - t0 > WALL_CLOCK_CAP_MS * 1000:
				truncated = true
				break
		env.dispose()
		if truncated:
			break
	var elapsed := float(Time.get_ticks_usec() - t0) / 1000000.0
	var det := detect(rows)
	return {"rows": rows, "detect": det, "truncated": truncated, "elapsed_s": elapsed}


static func run_smoke() -> Array[Dictionary]:
	# 缩减批 18 格：T1/T4/T7b × w1/10/40 × E1/E6_ns（模板×波×敌种正交抽查）
	var tids: Array[String] = ["T1", "T4", "T7b"]
	var waves: Array[int] = [1, 10, 40]
	var kinds: Array[String] = ["E1", "E6_ns"]
	var rows: Array[Dictionary] = []
	for tid in tids:
		var env := SimEnv.build(BASE_SEED)
		for w in waves:
			var weapons := SimTemplate.build(env, tid, w)
			for kind in kinds:
				var r := SimEngine.run_cell(env, weapons, w, kind, BASE_SEED)
				rows.append(_row(tid, w, kind, BASE_SEED, r))
		env.dispose()
	return rows


static func run_p50_side() -> Array[Dictionary]:
	# P50 侧写 270 行（只记录；detect 不消费——A14 §5 附表数据）
	var rows: Array[Dictionary] = []
	for seed in P50_SEEDS:
		for tid in P50_TEMPLATES:
			var env := SimEnv.build(seed)
			for w in WAVES:
				var weapons := SimTemplate.build(env, tid, w)
				for kind in P50_KINDS:
					var r := SimEngine.run_cell(env, weapons, w, kind, seed)
					rows.append(_row(tid, w, kind, seed, r))
			env.dispose()
	return rows


# ── 五点判定 ──────────────────────────────────────────────────────
static func detect(p_rows: Array[Dictionary]) -> Dictionary:
	var small: Array[float] = []
	for row in p_rows:
		if String(row["kind"]) == "E1" and int(row["ttk_frames"]) >= 0:
			small.append(float(row["t_clear_est"]))
	return {
		"p1_small_center": _p1_small(small),
		"p2_boss_anchor": _p2_boss(p_rows),
		"p3_drift_slope": _p3_slope(p_rows),
		"p4_build_variance": _p4_variance(p_rows),
		"p5_blessing_amp": _p5_amp(p_rows),
	}


static func _p1_small(p_small: Array[float]) -> Dictionary:
	# ① 锚 1.2s：P50 ∈ [1.08,1.32] OK / (0.60,1.80) DRIFT / 其余 RED；空网格 NTK
	if p_small.is_empty():
		return {"point": "p1", "verdict": "NTK", "p50_s": -1.0}
	var v := _percentile(p_small, 0.5)
	return {"point": "p1", "verdict": _band3(v, 1.2, 0.10, 0.50), "p50_s": v,
		"n_cells": p_small.size()}


static func _p2_boss(p_rows: Array[Dictionary]) -> Dictionary:
	# ② 锚 32s：T3|10|E6_ns ∈ [28.8,35.2] OK / [16,64] DRIFT / 其余 RED；NTK 单列
	var v := -1.0
	for row in p_rows:
		if String(row["template"]) == "T3" and int(row["wave"]) == 10 \
				and String(row["kind"]) == "E6_ns":
			v = float(row["t_clear_est"])
			break
	if v < 0.0:
		return {"point": "p2", "verdict": "NTK", "ttk_s": v}
	if v >= 28.8 and v <= 35.2:
		return {"point": "p2", "verdict": "OK", "ttk_s": v}
	if v >= 16.0 and v <= 64.0:
		return {"point": "p2", "verdict": "DRIFT", "ttk_s": v}
	return {"point": "p2", "verdict": "RED", "ttk_s": v}


static func _p3_slope(p_rows: Array[Dictionary]) -> Dictionary:
	# ③ 逐模板 (TTK40/TTK1)^(1/39)−1；(1+s)^30 > 1.10 RED / > 1.05 DRIFT / 其余 OK
	var per: Array[Dictionary] = []
	var worst := "OK"
	for tid in SimTemplate.IDS:
		var t1 := _ttk_of(p_rows, tid, 1, "E1")
		var t40 := _ttk_of(p_rows, tid, 40, "E1")
		if t1 < 0.0 or t40 < 0.0:
			per.append({"template": tid, "verdict": "NTK", "slope": -1.0})
			worst = _worse(worst, "NTK")
			continue
		var s := pow(t40 / maxf(t1, SimEngine.DT), 1.0 / 39.0) - 1.0
		var v := "OK"
		if pow(1.0 + s, 30.0) > 1.10:
			v = "RED"
		elif pow(1.0 + s, 30.0) > 1.05:
			v = "DRIFT"
		per.append({"template": tid, "verdict": v, "slope": s})
		worst = _worse(worst, v)
	return {"point": "p3", "verdict": worst, "per_template": per}


static func _p4_variance(p_rows: Array[Dictionary]) -> Dictionary:
	# ④ 逐波 E1 跨 8 模板 TTK P95/P5 → 波间 P50；≤1.39 OK / ≤1.50 DRIFT / >1.50 RED
	var ratios: Array[float] = []
	for w in WAVES:
		var ttks: Array[float] = []
		for tid in SimTemplate.IDS:
			var t := _ttk_of(p_rows, tid, w, "E1")
			if t >= 0.0:
				ttks.append(t)
		if ttks.size() < 2:
			continue
		var p95 := _percentile(ttks, 0.95)
		var p5 := _percentile(ttks, 0.05)
		if p5 > 0.0:
			ratios.append(p95 / p5)
		elif p95 > 0.0:
			ratios.append(p95 / SimEngine.DT)   # 即杀格入样：P5=0 → 以 DT 为底（方差上限口径）
	if ratios.is_empty():
		return {"point": "p4", "verdict": "NTK", "d_p50": -1.0}
	var d := _percentile(ratios, 0.5)
	var v := "OK"
	if d > 1.50:
		v = "RED"
	elif d > 1.39:
		v = "DRIFT"
	return {"point": "p4", "verdict": v, "d_p50": d, "d_max": ratios.max(),
		"n_waves": ratios.size()}


static func _p5_amp(p_rows: Array[Dictionary]) -> Dictionary:
	# ⑤ w30 E1 DPS 增幅 vs T1：T7a 锚 +29%（n29×0.04×0.25）/ T7b 锚 +116%（n29×0.04）；
	# 相对偏差 ≤10% OK / ≤25% DRIFT / >25% RED
	var out := {"point": "p5"}
	var worst := "OK"
	for entry in [["T7a", 0.29], ["T7b", 1.16]]:
		var base := _dps_of(p_rows, "T1", 30, "E1")
		var amp := _dps_of(p_rows, entry[0], 30, "E1")
		var anchor := float(entry[1])
		if base <= 0.0 or amp <= 0.0:
			out[entry[0]] = {"verdict": "NTK", "anchor": anchor, "measured": -1.0}
			worst = _worse(worst, "NTK")
			continue
		var m := amp / base - 1.0
		var rel := absf(m - anchor) / maxf(anchor, 0.0001)
		var v := "OK"
		if rel > 0.25:
			v = "RED"
		elif rel > 0.10:
			v = "DRIFT"
		out[entry[0]] = {"verdict": v, "anchor": anchor, "measured": m,
			"rel_dev": rel}
		worst = _worse(worst, v)
	out["verdict"] = worst
	return out


# ── CSV / 报表 ────────────────────────────────────────────────────
static func write_csv(p_cells: Array[Dictionary], p_p50: Array[Dictionary],
		p_detect: Dictionary) -> String:
	# user://sim_batch/<ts>/cells.csv + p50.csv + detect.json（返回目录）
	var ts := Time.get_datetime_string_from_system().replace(":", "").replace("-", "")
	var dir := OUT_ROOT + "/" + ts
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	_write_csv_file(dir + "/cells.csv", p_cells)
	_write_csv_file(dir + "/p50.csv", p_p50)
	var jf := FileAccess.open(dir + "/detect.json", FileAccess.WRITE)
	if jf != null:
		jf.store_string(JSON.stringify(p_detect, "  "))
		jf.close()
	return dir


static func emit_tables(p_report: Dictionary) -> String:
	# A14 粘贴用 markdown：网格速览（E1/E6_ns 双列 TTK s）+ 五点判定表
	var rows: Array[Dictionary] = p_report["rows"]
	var det: Dictionary = p_report["detect"]
	var out := "## A14 跑批网格速览（seed 42；TTK 单位 s；NTK=超 120s 帽）\n\n"
	out += "| 模板 | 波 | E1 | E6_ns |\n|---|---|---|---|\n"
	for tid in SimTemplate.IDS:
		for w in WAVES:
			var e1 := _fmt_ttk(_ttk_of(rows, tid, w, "E1"))
			var e6 := _fmt_ttk(_ttk_of(rows, tid, w, "E6_ns"))
			out += "| %s | %d | %s | %s |\n" % [tid, w, e1, e6]
	out += "\n## A14 五点判定\n\n"
	out += "| 点 | 判定 | 明细 |\n|---|---|---|\n"
	for key in ["p1_small_center", "p2_boss_anchor", "p3_drift_slope",
			"p4_build_variance", "p5_blessing_amp"]:
		out += "| %s | %s | %s |\n" % [key, str(det[key].get("verdict", "-")),
			_compact(det[key])]
	return out


static func clean_user_out() -> void:
	# 跑批前自动清（user://sim_batch 整目录——CSV/scratch 不留残档）
	var global := ProjectSettings.globalize_path(OUT_ROOT)
	if DirAccess.dir_exists_absolute(global):
		_delete_dir_recursive(global)


# ── 内部 ──────────────────────────────────────────────────────────
static func _row(p_tid: String, p_wave: int, p_kind: String, p_seed: int,
		p_r: Dictionary) -> Dictionary:
	return {
		"template": p_tid, "wave": p_wave, "kind": p_kind, "seed": p_seed,
		"ttk_frames": int(p_r["ttk_frames"]),
		"shield_break_frames": int(p_r["shield_break_frames"]),
		"hp_total": float(p_r["hp_total"]),
		"dps": float(p_r["dps"]),
		"t_clear_est": float(p_r["t_clear_est"]),
		"n_hits": int(p_r["n_hits"]),
		"n_crit": int(p_r["n_crit"]),
	}


static func _ttk_of(p_rows: Array[Dictionary], p_tid: String, p_wave: int,
		p_kind: String) -> float:
	for row in p_rows:
		if String(row["template"]) == p_tid and int(row["wave"]) == p_wave \
				and String(row["kind"]) == p_kind:
			return float(row["t_clear_est"])
	return -1.0


static func _dps_of(p_rows: Array[Dictionary], p_tid: String, p_wave: int,
		p_kind: String) -> float:
	for row in p_rows:
		if String(row["template"]) == p_tid and int(row["wave"]) == p_wave \
				and String(row["kind"]) == p_kind:
			return float(row["dps"])
	return -1.0


static func _band3(p_v: float, p_anchor: float, p_drift_rel: float,
		p_red_rel: float) -> String:
	# 锚相对带宽三档（①⑤ 共用口径）
	var rel := absf(p_v - p_anchor) / maxf(p_anchor, 0.0001)
	if rel <= p_drift_rel:
		return "OK"
	if rel <= p_red_rel:
		return "DRIFT"
	return "RED"


static func _percentile(p_values: Array[float], p_p: float) -> float:
	var sorted := p_values.duplicate()
	sorted.sort()
	if sorted.is_empty():
		return -1.0
	var idx := clampi(int(round(p_p * float(sorted.size() - 1))), 0, sorted.size() - 1)
	return float(sorted[idx])


static func _worse(p_a: String, p_b: String) -> String:
	# 判定劣化序：OK < DRIFT < RED < NTK（NTK 只出现在数据缺失，单列不覆盖 RED）
	const ORDER := {"OK": 0, "DRIFT": 1, "RED": 2, "NTK": 3}
	return p_a if int(ORDER.get(p_a, 0)) >= int(ORDER.get(p_b, 0)) else p_b


static func _fmt_ttk(p_t: float) -> String:
	if p_t < 0.0:
		return "NTK"
	return "%.2f" % p_t


static func _compact(p_d: Dictionary) -> String:
	var parts: Array[String] = []
	for key in p_d:
		if key == "point" or key == "verdict":
			continue
		var v: Variant = p_d[key]
		if v is float:
			parts.append("%s=%.3f" % [key, v])
		elif v is int:
			parts.append("%s=%d" % [key, v])
		elif v is Array:
			parts.append("%s=%d项" % [key, (v as Array).size()])
	return " ".join(parts)


static func _write_csv_file(p_path: String, p_rows: Array[Dictionary]) -> void:
	var f := FileAccess.open(p_path, FileAccess.WRITE)
	if f == null or p_rows.is_empty():
		return
	var header := ""
	for key in p_rows[0]:
		header += ("," if header != "" else "") + String(key)
	f.store_line(header)
	for row in p_rows:
		var line := ""
		for key in p_rows[0]:
			line += ("," if line != "" else "") + str(row[key])
		f.store_line(line)
	f.close()


static func _delete_dir_recursive(p_path: String) -> void:
	var dir := DirAccess.open(p_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := p_path + "/" + name
		if dir.current_is_dir():
			_delete_dir_recursive(full)
		else:
			DirAccess.remove_absolute(full)
		name = dir.get_next()
	DirAccess.remove_absolute(p_path)

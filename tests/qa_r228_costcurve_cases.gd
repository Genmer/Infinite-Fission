# tests/qa_r228_costcurve_cases.gd
# QA-R228 用例体：N=100/400/800 共享纹理 Sprite2D × 五臂，量化「每 canvas item 引擎每帧成本」。
# 五臂（同 N 同纹理同铺位，仅状态差）：
#   visible —— 可见静止（在树，visible=true）
#   hidden  —— visible=false 静止（在树；假说①：隐藏后树位/通知是否仍吃钱）
#   offtree —— 已创建+挂共享纹理但【不入树】（对象存活对照；预期≈0，验证「不在树=零成本」）
#   moving  —— 可见 + 每帧 position 三角抖动（transform 更新路径全开）
#   calc    —— 可见静止 + 同款抖动数学写入 PackedVector2Array（GDScript 数学地板；
#              moving−calc ≈ 引擎侧每帧 transform 更新净成本，剔除脚本算术本身）
# 口径（如实登记）：
# · headless（DisplayServer=headless，栅格化 dummy）——测的是引擎侧每帧成本
#   （树位/通知/RenderingServer 簿记/变换传播），【不含】真机渲染提交、顶点批次、
#   GPU 光栅与填充。若 dummy 渲染器短路 viewport 绘制，visible 臂读数≈hidden——
#   这本身就是假说①的证据，结论如实解读，不外推到真机渲染侧。
# · physics_ticks_per_second 运行期钉 60（任务口径；工程默认 120 已登记）。
#   headless 帧率不限速 → 物理 tick 按真实时间稀疏混入个别帧；帧级先 sort 取中位
#   过滤混入帧，轮间再 sort 取中位（≥5 轮，本探针 7 轮）。
# · 【坑（首轮实测踩中）】4.3 headless 默认 low_processor_usage_mode=on +
#   sleep_usec 默认 6900 → 每帧睡满 6.9ms（≈145fps 垫帧），五臂读数全被垫成
#   恒 6900µs、µs 级差全灭。探针运行期 OS.low_processor_usage_mode=false 关之
#   （探针侧口径设置，非产品码改动；r202 先例测的是 tick 切片不受此坑，本探针
#   环帧差口径必关）。
# · 每配置 7 轮 ×（30 预热 + 240 测量帧）；计时=Time.get_ticks_usec 跨
#   await process_frame 环帧差（覆盖 上一帧渲染提交→事件→物理→节点process→信号回
#   一次完整主循环）；轮外层交错（每轮扫全臂全 N，抗时间漂移）。
# · 每 arm 对 (n, 轮中位之中位) 三点最小二乘斜率 → µs/百个（一次项=每 item 边际成本，
#   截距=地板开销，斜率法天然消地板）。
# 输出契约：COST arm n med_us/mean_us；COSTFIT 斜率/每百µs/r2；DERIVED 三差；
#   EXTRA o2500→1250 外推；末行 QA_R228_RESULT {json}。
extends RefCounted

const NS: Array[int] = [100, 400, 800]
const ARMS: Array[String] = ["visible", "hidden", "offtree", "moving", "calc"]
const ROUNDS := 7
const WARMUP_FRAMES := 30
const MEASURE_FRAMES := 240
const TEX_SIZE := 8

var tree: SceneTree
var _fails: int = 0
var _root: Node2D = null
var _tex: ImageTexture = null
var _parent: Node2D = null
var _sprites: Array[Sprite2D] = []
var _base_pos := PackedVector2Array()
var _calc_buf := PackedVector2Array()
var _node_count_base := -1
var _round_meds: Dictionary = {}
var _round_means: Dictionary = {}


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	Engine.physics_ticks_per_second = 60
	# headless 垫帧陷阱（见头部口径注释）：关低功耗垫帧，否则测到的是 6900µs 睡眠周期
	OS.low_processor_usage_mode = false
	OS.low_processor_usage_mode_sleep_usec = 0
	seed(228)
	_root = Node2D.new()
	_root.name = "QA_R228_Root"
	tree.get_root().add_child(_root)
	_node_count_base = tree.get_node_count()
	var img := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 0.75, 0.2, 1.0))
	_tex = ImageTexture.create_from_image(img)
	print("环境：display=%s os=%s engine=%s physics_tps=%d headless_feature=%s" % [
		DisplayServer.get_name(), OS.get_name(),
		str(Engine.get_version_info().get("string", "?")),
		Engine.physics_ticks_per_second, str(OS.has_feature("headless"))])
	print("树节点基线=%d（root+autoloads；本探针不引工程类）" % _node_count_base)
	print("口径：物理钉 60；low_processor_usage_mode=%s sleep_usec=%d（关垫帧）；轮=%d（外层交错） 预热=%d 测量=%d 帧 ns=%s" % [
		str(OS.low_processor_usage_mode), OS.low_processor_usage_mode_sleep_usec,
		ROUNDS, WARMUP_FRAMES, MEASURE_FRAMES, str(NS)])
	var wall0 := Time.get_ticks_usec()
	for r in range(ROUNDS):
		for arm in ARMS:
			for n in NS:
				await _measure_one(arm, n, r)
		print("── 第 %d/%d 轮完成（累计 %.1fs）──" % [r + 1, ROUNDS, float(Time.get_ticks_usec() - wall0) / 1000000.0])
	_summarize()
	_teardown()


func fail_count() -> int:
	return _fails


# ── 单配置单轮：setup → 预热 → 测量 → 记录 ─────────────────────────
func _measure_one(arm: String, n: int, _round_idx: int) -> void:
	_setup_arm(arm, n)
	_check_arm_state(arm, n)
	var probe0 := Vector2.ZERO
	if _sprites.size() > 0:
		probe0 = _sprites[0].position
	var phys0 := Engine.get_physics_frames()
	var deltas: Array[int] = []
	var total_us := 0
	var last_us := Time.get_ticks_usec()
	for i in range(WARMUP_FRAMES):
		_tick(arm, i)
		await tree.process_frame
		last_us = Time.get_ticks_usec()
	for i in range(MEASURE_FRAMES):
		_tick(arm, WARMUP_FRAMES + i)
		await tree.process_frame
		var now_us := Time.get_ticks_usec()
		var d := now_us - last_us
		deltas.append(d)
		total_us += d
		last_us = now_us
	var phys_ticks := Engine.get_physics_frames() - phys0
	if deltas.size() != MEASURE_FRAMES:
		_fails += 1
		print("FAIL | 采样数不符 arm=%s n=%d got=%d" % [arm, n, deltas.size()])
	if arm == "moving" and _sprites.size() > 0 and _sprites[0].position == probe0:
		_fails += 1
		print("FAIL | moving 抖动未生效（首件位置未变）n=%d" % n)
	var med_us := _median_i(deltas)
	var mean_us := float(total_us) / float(MEASURE_FRAMES)
	var key := "%s|%d" % [arm, n]
	if not _round_meds.has(key):
		_round_meds[key] = []
		_round_means[key] = []
	(_round_meds[key] as Array).append(med_us)
	(_round_means[key] as Array).append(mean_us)
	# 逐轮行（前两轮打点观察稳定性，之后静默防刷屏；完整数据在汇总）
	# rs_setup=RenderingServer 上帧 frame_setup CPU 时间（headless/dummy 下应为 0——
	# 渲染提交流水线被短路与否的直接证据，留档解读 visible 臂口径用）
	if _round_idx < 2:
		print("  ROUND arm=%s n=%d med=%.1fus mean=%.1fus phys_ticks=%d rs_setup_us=%d" % [
			arm, n, med_us, mean_us, phys_ticks,
			RenderingServer.get_frame_setup_time_cpu()])
	_teardown_arm()


# ── 夹具：共享纹理 Sprite2D，五态 ──────────────────────────────────
func _setup_arm(arm: String, n: int) -> void:
	_teardown_arm()
	_sprites = []
	_base_pos = PackedVector2Array()
	_calc_buf = PackedVector2Array()
	_calc_buf.resize(n)
	if arm != "offtree":
		_parent = Node2D.new()
		_parent.name = "QA_R228_Parent"
		_root.add_child(_parent)
	for i in range(n):
		var s := Sprite2D.new()
		s.texture = _tex
		s.centered = false
		var pos := Vector2(8.0 + float(i % 40) * 17.0, 8.0 + float(i / 40) * 17.0)
		s.position = pos
		s.visible = (arm != "hidden")
		_base_pos.append(pos)
		if arm == "offtree":
			_sprites.append(s)   # 对象+纹理存活，但不入树（对照）
		else:
			_parent.add_child(s)
			_sprites.append(s)


func _teardown_arm() -> void:
	if _parent != null and is_instance_valid(_parent):
		_parent.free()      # 子 Sprite 一并释放
	_parent = null
	for s in _sprites:
		if s != null and is_instance_valid(s):
			s.free()        # 仅 offtree 件会走到（树内件已随父释放失效）
	_sprites = []


func _check_arm_state(arm: String, n: int) -> void:
	if _sprites.size() != n:
		_fails += 1
		print("FAIL | 夹具数不符 arm=%s n=%d got=%d" % [arm, n, _sprites.size()])
		return
	var got := tree.get_node_count()
	var expect := _node_count_base
	if arm != "offtree":
		expect += 1 + n
	if got != expect:
		_fails += 1
		print("FAIL | 树节点数不符 arm=%s n=%d got=%d expect=%d（offtree 应=基线）" % [
			arm, n, got, expect])
	if _sprites[0].texture == null:
		_fails += 1
		print("FAIL | 共享纹理未挂 arm=%s" % arm)
	var vis_expect := (arm != "hidden")
	if arm != "offtree" and _sprites[0].is_visible_in_tree() != vis_expect:
		_fails += 1
		print("FAIL | 可见性与臂不符 arm=%s" % arm)


# ── 每帧动作：moving=真写 transform；calc=同数学写本地数组（地板） ──
func _tick(arm: String, frame: int) -> void:
	if arm == "moving":
		var f := float(frame)
		for i in _sprites.size():
			var b: Vector2 = _base_pos[i]
			_sprites[i].position = Vector2(
				b.x + sin(f * 0.317 + float(i) * 0.731) * 2.0,
				b.y + cos(f * 0.271 + float(i) * 0.913) * 2.0)
	elif arm == "calc":
		var f2 := float(frame)
		for i in _sprites.size():
			var b2: Vector2 = _base_pos[i]
			_calc_buf[i] = Vector2(
				b2.x + sin(f2 * 0.317 + float(i) * 0.731) * 2.0,
				b2.y + cos(f2 * 0.271 + float(i) * 0.913) * 2.0)
	# visible/hidden/offtree：无每帧动作（测的是纯驻留成本）


# ── 统计：中位数（先 sort）+ 均值 + 三点最小二乘 ────────────────────
func _median_i(vals: Array) -> float:
	if vals.is_empty():
		return 0.0
	var s := vals.duplicate()
	s.sort()
	var m := s.size() / 2
	if s.size() % 2 == 1:
		return float(s[m])
	return (float(s[m - 1]) + float(s[m])) * 0.5


func _median_f(vals: Array) -> float:
	if vals.is_empty():
		return 0.0
	var s := vals.duplicate()
	s.sort()
	var m := s.size() / 2
	if s.size() % 2 == 1:
		return float(s[m])
	return (float(s[m - 1]) + float(s[m])) * 0.5


func _mean_f(vals: Array) -> float:
	if vals.is_empty():
		return 0.0
	var t := 0.0
	for v in vals:
		t += float(v)
	return t / float(vals.size())


func _lsq(pts: Array) -> Dictionary:
	var cnt := pts.size()
	if cnt < 2:
		return {"slope": 0.0, "r2": 0.0}
	var sx := 0.0
	var sy := 0.0
	var sxx := 0.0
	var sxy := 0.0
	var syy := 0.0
	for p in pts:
		var x := float(p[0])
		var y := float(p[1])
		sx += x
		sy += y
		sxx += x * x
		sxy += x * y
		syy += y * y
	var mx := sx / float(cnt)
	var my := sy / float(cnt)
	var cov := sxy / float(cnt) - mx * my
	var varx := sxx / float(cnt) - mx * mx
	var vary := syy / float(cnt) - my * my
	if varx <= 0.0:
		return {"slope": 0.0, "r2": 0.0}
	var slope := cov / varx
	var r2 := 0.0
	if vary > 0.0:
		r2 = (cov * cov) / (varx * vary)
	return {"slope": slope, "r2": clampf(r2, 0.0, 1.0)}


# ── 汇总：COST/COSTFIT/DERIVED/EXTRA + 结果 JSON ───────────────────
func _summarize() -> void:
	var med_of_meds: Dictionary = {}
	for arm in ARMS:
		for n in NS:
			var key := "%s|%d" % [arm, n]
			var meds: Array = _round_meds.get(key, [])
			var means: Array = _round_means.get(key, [])
			med_of_meds[key] = _median_f(meds)
			print("COST arm=%s n=%d med_us=%.1f mean_us=%.1f rounds=%d" % [
				arm, n, float(med_of_meds[key]), _mean_f(means), meds.size()])
	var per100: Dictionary = {}
	for arm in ARMS:
		var pts: Array = []
		for n in NS:
			pts.append([float(n), float(med_of_meds["%s|%d" % [arm, n]])])
		var fit := _lsq(pts)
		per100[arm] = float(fit["slope"]) * 100.0
		print("COSTFIT arm=%s slope_us_per_item=%.6f per100_us=%.3f r2=%.4f" % [
			arm, float(fit["slope"]), float(per100[arm]), float(fit["r2"])])
	var hidden_tree_cost := float(per100["hidden"]) - float(per100["offtree"])
	var visible_extra := float(per100["visible"]) - float(per100["hidden"])
	var moving_extra := float(per100["moving"]) - float(per100["calc"])
	print("DERIVED hidden_tree_cost_per100_us=%.3f（hidden−offtree：隐藏后仍付的树位成本，假说①）" % hidden_tree_cost)
	print("DERIVED visible_extra_per100_us=%.3f（visible−hidden：可见性额外成本）" % visible_extra)
	print("DERIVED moving_extra_per100_us=%.3f（moving−calc：每帧 transform 更新引擎净成本，假说③）" % moving_extra)
	var removed_items := 1250
	var save_static_ms := float(removed_items) * (float(per100["visible"]) / 100.0) / 1000.0
	var save_hidden_ms := float(removed_items) * (float(per100["hidden"]) / 100.0) / 1000.0
	var save_move_ms := float(removed_items) * (moving_extra / 100.0) / 1000.0
	print("EXTRA o2500→1250（−1250 项，桌面 headless 引擎侧口径，不含渲染提交/GPU/填充）：")
	print("EXTRA   若砍的是静止可见项 ≈%.3f ms/帧；砍已隐藏项 ≈%.3f ms/帧；砍每帧移动项另计 transform ≈%.3f ms/帧" % [
		save_static_ms, save_hidden_ms, save_move_ms])
	var extra_str := "静止可见−1250项≈%.3fms/帧；已隐藏项−1250≈%.3fms/帧；每帧移动项另加≈%.3fms/帧（引擎侧/桌面headless口径，不含渲染提交与GPU，真机不可直接换算）" % [
		save_static_ms, save_hidden_ms, save_move_ms]
	var result := {
		"visibleUsPer100": float(per100["visible"]),
		"hiddenUsPer100": float(per100["hidden"]),
		"freedUsPer100": float(per100["offtree"]),
		"movingExtraUsPer100": moving_extra,
		"extrapolatedMsPerFrame": extra_str,
	}
	print("QA_R228_RESULT " + JSON.stringify(result))


func _teardown() -> void:
	_teardown_arm()
	if _root != null and is_instance_valid(_root):
		_root.free()
	_root = null
	if _tex != null and is_instance_valid(_tex):
		_tex = null

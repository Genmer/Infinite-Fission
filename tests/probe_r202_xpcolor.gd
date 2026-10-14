# tests/probe_r202_xpcolor.gd
# R202 侦查探针（非测试——勿用 test_ 前缀，防电池 glob 收录）：
# 「经验掉落颜色还是统一黄色（R196 四色分档真机不生效）」逐环实测：
#   ① 掉落注入链：真实击杀（Enemy 池件 spawn → _on_died → EventBus.enemy_killed
#      → GameLoop._on_enemy_killed_drop_xp → _spawn_xp_shard → XpShard.activate）后
#      shard.value / _baseline / _tier / modulate 是否按 R196 到位；
#   ② 分档比较：value/baseline 真实比值（普通 / 精英(exp×8) / Boss 三类敌 × w5 / w10），
#      对照设计锚（docs/design/R196_GROWTH_FIXES.md:146：杂兵1×白 / 精英4×绿 / Boss≈200×七彩，
#      基线应为杂兵锚 exp_base=3 而非死者自身 exp_base）；
#   ③ _sync_visual 后续覆盖：activate 后 tick 全程（Burst/Rest/Sink/Bob/超时回归 homing）
#      modulate 采样——档色是否被后续代码抹掉；
#   ④ 合并珠：merge_value 后重分档；
#   ⑤ 最终渲染色：星星贴图（TextureFactory.star 预染 PopPalette.XP 柠檬黄）星心像素
#      × modulate = 玩家实际看到的颜色，对比 R196 前统一黄（贴图 × 白）。
# 工程约束：-s 主脚本编译早于 autoload 注册——GameLoop/Enemy 经运行期实例取（main.tscn
# instantiate + 池 acquire），顶层禁直引依赖 autoload 的 class_name；GameConst 纯常量可直引。
# 跑法：tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/probe_r202_xpcolor.gd
extends SceneTree

const DT := 1.0 / 60.0
const MAIN_SCENE := "res://scenes/main.tscn"
const WAVE_A := 5                          # early_xp_boost 生效波段（×1.25，until_wave=6）
const WAVE_B := 10                         # early 过期波段（×1.0）
const GRUNT_EXP_BASE := 3.0                # 设计锚杂兵基线（E1_grunt.tres exp_base）

var _gl: Node = null
var _infl: float = 1.085                   # exp_inflation_per_wave（boot 后读真值覆盖）


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ R202 经验四色探针（真实击杀链 → 碎片档位/颜色实测） ══════════")
	await process_frame
	await process_frame                    # autoload 就绪
	_boot()
	await process_frame
	await process_frame                    # GameLoop _ready 组装落定
	var cases: Array = [
		["A|E1_grunt  w%d  普通" % WAVE_A, &"E1_grunt", WAVE_A, 0],
		["B|E2_runner w%d  精英(exp×8)" % WAVE_A, &"E2_runner", WAVE_A, 1],
		["C|E5_elite  w%d  精英(exp×8)" % WAVE_A, &"E5_elite", WAVE_A, 1],
		["D|E6_boss1  w%d  Boss" % WAVE_A, &"E6_boss1", WAVE_A, 2],
		["E|E1_grunt  w%d  普通" % WAVE_B, &"E1_grunt", WAVE_B, 0],
	]
	var grunt_shard: Node = null
	for c in cases:
		var shard := _case_kill(String(c[0]), c[1], int(c[2]), int(c[3]))
		if grunt_shard == null:
			grunt_shard = shard            # 留给 ③ 稳定性追踪（普通杂兵碎片）
			_probe_tick_stability(grunt_shard)   # 先于 B/C/D 击杀（Boss/精英死会 force_magnet 全场碎片）
	_probe_green_synthetic()
	_probe_merge()
	print("══════════ 探针结束 ══════════")
	quit(0)


func _boot() -> void:
	# r196_growth_cases 同款归一 + 组装（-s 下 duck 调用）
	var win: Window = get_root()
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	win.size = Vector2i(540, 960)
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate()
	_gl.name = "R202XpColorProbeLoop"
	get_root().add_child(_gl)
	_gl.set("state", GameConst.GameStatus.MENU)   # 冻结波次刷怪（用例自管夹具敌）
	_gl.call("start_run")
	var player: Node2D = _gl.get("player")
	player.set("max_hp", 1000000.0)
	player.set("hp", 1000000.0)
	player.global_position = Vector2(360.0, 1150.0)   # 远离掉落点（防磁吸干扰观察）
	var bal: Object = get_root().get_node("/root/GameConfig").get("balance")
	if bal != null:
		_infl = float(bal.get("exp_inflation_per_wave"))
	var mt: Node = get_root().get_node_or_null("/root/Meta")
	if mt != null:
		mt.call("set_setting", "shake_on", false)
	print("ENV| inflation=%.3f early(w%d)×%.2f relic_xp_mult×%.2f 玩家位=(360, 1150)" % [
		_infl, WAVE_A, float(_gl.call("_early_xp_mult")),
		float(_gl.get("relic_handler").xp_mult())])


func _case_kill(p_label: String, p_id: StringName, p_wave: int, p_tags: int) -> Node:
	# 真实击杀链：池件敌 → spawn(缩放 exp_value) → _on_died → 全订户派发（掉落侧先行）
	var ed: Resource = _gl.get("registry").get_enemy(p_id)
	if ed == null:
		print("CASE %s：注册表无 %s —— 跳过" % [p_label, String(p_id)])
		return null
	var pool: Node = _gl.get("pools")[&"enemy"]
	var enemy: Node = pool.acquire()
	enemy.call("spawn", ed, p_wave, p_tags)
	enemy.global_position = Vector2(200.0, 300.0)
	var exp_value := float(enemy.get("exp_value"))
	var exp_base := float(ed.get("exp_base"))
	var midas := float(_gl.get("relic_handler").xp_mult())
	var early := float(_gl.call("_early_xp_mult"))
	# 波次同步（真实局：敌出生波 = 击杀时 wave_director.current_wave；掉落侧基线读后者）
	_gl.get("wave_director").set("current_wave", p_wave)
	early = float(_gl.call("_early_xp_mult"))
	enemy.call("_on_died")                 # 真实死亡链（EventBus.enemy_killed → 掉落+池归还）
	var shards: Array = _gl.get("active_shards")
	var shard: Node = shards.back() if not shards.is_empty() else null
	if shard == null:
		print("CASE %s：击杀未产出碎片（链路断！）" % p_label)
		return null
	var v := float(shard.get("value"))
	var b := float(shard.get("_baseline"))
	var tier := int(shard.get("_tier"))
	var spr: CanvasItem = shard.get("_sprite")
	var ratio := v / b if b > 0.0 else -1.0
	var anchor_b := GRUNT_EXP_BASE * pow(_infl, float(maxi(p_wave - 1, 0)))
	var design_tier := int(shard.call("xp_tier_of", v, anchor_b))
	print("CASE %s" % p_label)
	print("  ①敌侧 exp_value=%.2f（exp_base=%.1f×通胀^%d×e_exp）→ 掉落 value=%.2f（×点金%.2f×early%.2f）" % [
		exp_value, exp_base, maxi(p_wave - 1, 0), v, midas, early])
	print("  ②碎片 baseline=%.2f（死者自身 exp_base=%.1f×通胀^%d）→ ratio=%.3f → 档=%d（%s）" % [
		b, exp_base, maxi(p_wave - 1, 0), ratio, tier, _tier_name(tier)])
	print("  ②设计锚基线=%.2f（杂兵3.0×通胀^%d）→ 若按设计口径档=%d（%s）" % [
		anchor_b, maxi(p_wave - 1, 0), design_tier, _tier_name(design_tier)])
	print("  ③activate 后 modulate=#%s（档色单源 PopPalette.XP_TIER_COLORS）" % [
		(spr.get("modulate") as Color).to_html(false)])
	_final_render(p_label, shard)
	return shard


func _final_render(p_label: String, p_shard: Node) -> void:
	# ⑤ 最终渲染色 = 贴图预染黄 × modulate（Godot modulate 为乘法）
	var spr: CanvasItem = p_shard.get("_sprite")
	var tex: Texture2D = spr.get("texture")
	var img: Image = tex.get_image()
	var px := img.get_pixel(22, 22)         # 星心填充像素（SDF body=1 处）
	var mod: Color = spr.get("modulate")
	var final_c := Color(
		clampf(px.r * mod.r, 0.0, 1.0),
		clampf(px.g * mod.g, 0.0, 1.0),
		clampf(px.b * mod.b, 0.0, 1.0))
	print("  ⑤星心像素=#%s × modulate → 玩家所见 #%s（R196 前统一黄=#%s → ΔR%d ΔG%d ΔB%d）" % [
		px.to_html(false), final_c.to_html(false), px.to_html(false),
		int(round((final_c.r - px.r) * 255.0)),
		int(round((final_c.g - px.g) * 255.0)),
		int(round((final_c.b - px.b) * 255.0))])


func _probe_tick_stability(p_shard: Node) -> void:
	# ③ tick 期覆盖检查：真实驱动 _gl._tick_xp_shards，0.5s 一采样直到吸收
	print("── ③ tick 全程 modulate 轨迹（碎片A 杂兵白档；玩家远→磁吸不触发） ──")
	var frame := 0
	var t := 0.0
	var phase_names: Array[String] = ["Burst", "Rest", "Sink", "Bob"]
	while t < 8.0 and is_instance_valid(p_shard):
		_gl.call("_tick_xp_shards", DT)
		frame += 1
		t = float(frame) * DT
		if frame % 30 == 0:
			var spr: CanvasItem = p_shard.get("_sprite")
			var phase := int(p_shard.get("_phase"))
			var ph := phase_names[phase] if phase >= 0 and phase < phase_names.size() else "?"
			if bool(p_shard.get("_homing")):
				ph = "Homing"
			var in_active: Array = _gl.get("active_shards")
			var alive := in_active.has(p_shard)
			print("  t=%.1fs phase=%-6s 吸收=%s modulate=#%s" % [
				t, ph, str(not alive), (spr.get("modulate") as Color).to_html(false)])
			if not alive:
				print("  （已吸收：gain_xp 入账，碎片归还池——轨迹止）")
				break


func _probe_green_synthetic() -> void:
	# ③补：合成绿档碎片（ratio=4）走全行为段，验证绿档在 tick/回归全程不被抹色
	print("── ③补 合成绿档（value20/baseline5 ratio=4 → 应绿档）全轨迹 ──")
	_gl.call("_spawn_xp_shard", Vector2(150.0, 300.0), 20.0, 5.0)
	var shards: Array = _gl.get("active_shards")
	var shard: Node = shards.back()
	if shard == null:
		print("  合成失败（池空？）")
		return
	var spr: CanvasItem = shard.get("_sprite")
	print("  出生 tier=%d modulate=#%s（值20≥15 → 2s 即回归）" % [
		int(shard.get("_tier")), (spr.get("modulate") as Color).to_html(false)])
	var frame := 0
	var t := 0.0
	while t < 6.0 and is_instance_valid(shard):
		_gl.call("_tick_xp_shards", DT)
		frame += 1
		t = float(frame) * DT
		if frame % 20 == 0:
			var in_active: Array = _gl.get("active_shards")
			if not in_active.has(shard):
				print("  t=%.2fs 已吸收（回归飞行 gain_xp）——绿档全程未被抹色" % t)
				break
			print("  t=%.2fs homing=%s modulate=#%s" % [
				t, str(bool(shard.get("_homing"))), (spr.get("modulate") as Color).to_html(false)])


func _probe_merge() -> void:
	# ④ 合并珠：merge_value 累面值、基线取 max → 重分档；⑤ 池复用残留检查
	print("── ④ 合并珠 merge_value 重分档 + 池复用残留 ──")
	_gl.call("_spawn_xp_shard", Vector2(100.0, 250.0), 4.0, 4.0)
	var shards: Array = _gl.get("active_shards")
	var shard: Node = shards.back()
	if shard == null:
		print("  合成失败")
		return
	var spr: CanvasItem = shard.get("_sprite")
	print("  初始 value=4/baseline=4 → tier=%d（%s）modulate=#%s" % [
		int(shard.get("_tier")), _tier_name(int(shard.get("_tier"))),
		(spr.get("modulate") as Color).to_html(false)])
	shard.call("merge_value", 30.0, 4.0)   # → 34/4 = 8.5 → 金档
	print("  merge+30 → value=%.0f tier=%d（%s）modulate=#%s" % [
		float(shard.get("value")), int(shard.get("_tier")),
		_tier_name(int(shard.get("_tier"))), (spr.get("modulate") as Color).to_html(false)])
	shard.call("merge_value", 60.0, 4.0)   # → 94/4 = 23.5 → 七彩档
	print("  merge+60 → value=%.0f tier=%d（%s，from_hsv 起始 #ffffff）" % [
		float(shard.get("value")), int(shard.get("_tier")), _tier_name(int(shard.get("_tier")))])
	# 池复用残留：上方碎片若被吸收归还（modulate 清白），新取碎片应着自身档色
	_gl.call("_spawn_xp_shard", Vector2(120.0, 260.0), 5.0, 5.0)
	var shard2: Node = (_gl.get("active_shards") as Array).back()
	var spr2: CanvasItem = shard2.get("_sprite")
	print("  池复用新碎片（value5/baseline5 ratio1 → 白档）modulate=#%s（残留=非 fff1b8 即污染）" % [
		(spr2.get("modulate") as Color).to_html(false)])


func _tier_name(p_tier: int) -> String:
	var names: Array[String] = ["白", "绿", "金", "七彩"]
	var hexes: Array[String] = ["#fff1b8", "#2ed573", "#ffc93c", "from_hsv"]
	if p_tier >= 0 and p_tier < names.size():
		return "%s %s" % [names[p_tier], hexes[p_tier]]
	return "越界%d" % p_tier

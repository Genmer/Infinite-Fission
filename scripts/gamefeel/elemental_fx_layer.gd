# scripts/gamefeel/elemental_fx_layer.gd
# 方向 C 元素签名特效层（用户反馈 2026-08-29「能不能做出闪电、灼烧等特效」→ 引擎能力证明）：
# 世界空间一次性表现件宿主，GameLoop ⑦ feel 阶段 raw 通道驱动 tick（暂停/顿帧自然冻结）。
# · 感电连锁主锯齿闪电（签名特效）：订阅 EventBus.chain_lightning（源敌→被链敌），
#   粗白芯 + 葡萄紫辉外层双层折线，全程 0.12s、逐段抖动（顶点池轮换）+ 中点闪光。
# · 碎裂橙色冲击小环：订阅 EventBus.reaction_triggered（rxn==RXN_FIR_ICE，管线广播）。
# · 点燃 DOT 火星小喷：订阅 EventBus.elemental_dot_fired（每跳结算瞬间 3 粒上飘火星）。
# 全部对象 _ready 预建轮换复用（0 运行期实例化）；折线顶点预生成池轮换；共享贴图、
# 无 shader、零数值副作用（纯表现层，订阅事件只读位置）。
class_name ElementalFxLayer
extends Node2D

const BOLT_COUNT := 8                         # 连锁闪电并发池（轮换复用）
const BOLT_LIFE := 0.12                       # 主闪电全程时长 s（任务口径）
const BOLT_PATTERNS := 10                     # 预生成抖动系数组数（轮换）
const BOLT_SEGMENTS := 6                      # 折线段数（顶点 = 段数 + 1）
const SPARK_COUNT := 24                       # DOT 火星并发池（30+ 敌叠加预算封顶口径）
const SPARK_LIFE := 0.32                      # 火星存活时长 s
const RING_COUNT := 6                         # 碎裂冲击环并发池
const RING_LIFE := 0.26                       # 冲击环时长 s
const RING_R0 := 14.0                         # 冲击环起始半径 px
const RING_R1 := 62.0                         # 冲击环结束半径 px
const RIPPLE_COUNT := 12                      # 青色涟漪并发池（护盾格挡 / 弧斩消弹共用）
const RIPPLE_LIFE := 0.24                     # 涟漪时长 s
const ZAP_COUNT := 12                         # 电花碎屑并发池（闪电落点迸溅——用户反馈「是个球」）
const ZAP_LIFE := 0.2                         # 电花碎屑时长 s
const GLOW_COUNT := 8                         # DOT 橙光晕并发池（点燃跳伤瞬间体周闪光）
const GLOW_LIFE := 0.18                       # 橙光晕时长 s

var _bolts: Array[Dictionary] = []            # [{root, core, glow, flash, left}]（池条目）
var _bolt_idx: int = 0
var _bolt_patterns: Array[PackedFloat32Array] = []   # 预生成垂直抖动系数池（轮换）
var _pattern_idx: int = 0
var _sparks: Array[Dictionary] = []           # [{sprite, vel, left}]
var _spark_idx: int = 0
var _rings: Array[Dictionary] = []            # [{sprite, left}]
var _ring_idx: int = 0
var _ripples: Array[Dictionary] = []          # [{sprite, left, r0, r1}]（青色涟漪池）
var _ripple_idx: int = 0
var _zaps: Array[Dictionary] = []             # [{sprite, vel, rot_vel, left}]（电花碎屑池）
var _zap_idx: int = 0
var _glows: Array[Dictionary] = []            # [{sprite, left}]（DOT 橙光晕池）
var _glow_idx: int = 0


func _ready() -> void:
	# 预建全部表现件（池化轮换，运行期零实例化）+ 订阅表现层专用广播（本类 extends Node ✓）
	z_index = 5                                  # 世界层最上（敌/玩家/弹同 z=0 树序层之上）/ HUD（CanvasLayer）之下
	_build_bolts()
	_build_sparks()
	_build_rings()
	_build_ripples()
	_build_zaps()
	_build_glows()
	EventBus.chain_lightning.connect(_on_chain_lightning)
	EventBus.elemental_dot_fired.connect(_on_dot_fired)
	EventBus.reaction_triggered.connect(_on_reaction_triggered)
	EventBus.shield_blocked.connect(_on_shield_blocked)
	EventBus.bullet_nullified.connect(_on_bullet_nullified)


func tick(p_raw_delta: float) -> void:
	# GameLoop ⑦ feel 阶段驱动（raw 通道）；非战斗状态不被驱动 → 表现件自然冻结
	_tick_bolts(p_raw_delta)
	_tick_sparks(p_raw_delta)
	_tick_rings(p_raw_delta)
	_tick_ripples(p_raw_delta)
	_tick_zaps(p_raw_delta)
	_tick_glows(p_raw_delta)


# ── 感电连锁主锯齿闪电（签名特效） ────────────────────────────────
func _build_bolts() -> void:
	for i in range(BOLT_COUNT):
		var root := Node2D.new()
		root.name = "ChainBolt%d" % i
		root.visible = false
		var glow := Line2D.new()
		glow.name = "Glow"
		glow.width = 15.0
		glow.default_color = Color(PopPalette.SHOCK.r, PopPalette.SHOCK.g, PopPalette.SHOCK.b, 0.55)
		glow.joint_mode = Line2D.LINE_JOINT_ROUND
		glow.begin_cap_mode = Line2D.LINE_CAP_ROUND
		glow.end_cap_mode = Line2D.LINE_CAP_ROUND
		root.add_child(glow)
		var core := Line2D.new()
		core.name = "Core"
		core.width = 6.0
		core.default_color = Color.WHITE
		core.joint_mode = Line2D.LINE_JOINT_ROUND
		core.begin_cap_mode = Line2D.LINE_CAP_ROUND
		core.end_cap_mode = Line2D.LINE_CAP_ROUND
		root.add_child(core)
		var flash := Sprite2D.new()
		flash.name = "Flash"
		# 星形爆闪（用户反馈「感电是个球」→ soft_dot 球换四角星 + 起始小尺寸速缩）
		flash.texture = TextureFactory.star(48, Color.WHITE)
		flash.modulate = Color(1.0, 1.0, 1.0, 0.9)
		flash.visible = true
		root.add_child(flash)
		add_child(root)
		_bolts.append({"root": root, "core": core, "glow": glow, "flash": flash,
			"left": 0.0})


func _on_chain_lightning(p_from: Vector2, p_to: Vector2) -> void:
	# 取池内下一道闪电（轮换）：定位源敌 → 重铺双层折线 + 中点星闪 + 落点电花迸溅；
	# 终点存 meta（生命期逐帧重铺折线复用，零额外分配）
	var bolt: Dictionary = _bolts[_bolt_idx % BOLT_COUNT]
	_bolt_idx += 1
	var root: Node2D = bolt["root"]
	var local_to: Vector2 = p_to - p_from
	root.position = p_from
	root.rotation = 0.0
	root.set_meta(&"bolt_to", local_to)
	root.visible = true
	root.modulate.a = 1.0
	_layout_bolt(bolt, local_to, 1.0)
	bolt["left"] = BOLT_LIFE
	for i in range(3):
		_fire_zap(p_to)


func _layout_bolt(p_bolt: Dictionary, p_local_to: Vector2, p_amp: float) -> void:
	# 双层折线铺点（白芯 + 紫辉同形）：沿线插值 + 预生成垂直抖动系数 × 包络 × 段长
	var patterns := _get_bolt_patterns()
	var offsets: PackedFloat32Array = patterns[_pattern_idx % patterns.size()]
	_pattern_idx += 1
	var pts := PackedVector2Array()
	var perp := Vector2(p_local_to.y, -p_local_to.x).normalized()
	if perp == Vector2.ZERO:
		perp = Vector2.UP
	for i in range(BOLT_SEGMENTS + 1):
		var t := float(i) / float(BOLT_SEGMENTS)
		var amp := 0.0 if i == 0 or i == BOLT_SEGMENTS \
			else offsets[i % offsets.size()] * p_amp * p_local_to.length() * 0.16
		pts.append(p_local_to * t + perp * amp)
	var core: Line2D = p_bolt["core"]
	var glow: Line2D = p_bolt["glow"]
	core.points = pts
	glow.points = pts
	var flash: Sprite2D = p_bolt["flash"]
	flash.position = p_local_to * 0.5
	flash.scale = Vector2.ONE * clampf(p_local_to.length() / 260.0, 0.35, 0.75)


func _tick_bolts(p_raw_delta: float) -> void:
	for bolt: Dictionary in _bolts:
		var left := float(bolt["left"])
		if left <= 0.0:
			continue
		left = maxf(left - p_raw_delta, 0.0)
		bolt["left"] = left
		var root: Node2D = bolt["root"]
		if left <= 0.0:
			root.visible = false
			continue
		var progress := 1.0 - left / BOLT_LIFE
		# 逐段抖动：生命期每帧轮换预生成顶点池重铺折线，包络 0→1→0 + 尾段淡出
		var local_to: Vector2 = root.get_meta(&"bolt_to") as Vector2
		_layout_bolt(bolt, local_to, maxf(sin(progress * PI), 0.35))
		root.modulate.a = clampf(1.15 - progress * 0.9, 0.25, 1.0)
		# 中点星闪随生命期收缩旋转（爆裂感，替代原「球」观感）
		var flash: Sprite2D = bolt["flash"]
		flash.rotation += p_raw_delta * 14.0
		flash.scale = flash.scale * maxf(1.0 - progress * 5.0 * p_raw_delta, 0.1)


func _get_bolt_patterns() -> Array[PackedFloat32Array]:
	# 预生成抖动系数池（10 组 × 中段 4 系数，[-1,1] 混合锯齿形；轮换零运行期生成）
	if _bolt_patterns.is_empty():
		for i in range(BOLT_PATTERNS):
			var arr := PackedFloat32Array()
			for j in range(4):
				var ph := TAU * (float(i) * 0.37 + float(j) * 0.61)
				arr.append(sin(ph) * (0.55 + 0.45 * sin(ph * 2.3)))
			_bolt_patterns.append(arr)
	return _bolt_patterns


# ── 点燃 DOT 火星（每跳结算瞬间小喷） ─────────────────────────────
func _build_sparks() -> void:
	for i in range(SPARK_COUNT):
		var sp := Sprite2D.new()
		sp.name = "DotSpark%d" % i
		sp.texture = TextureFactory.flame_bit()
		sp.visible = false
		add_child(sp)
		_sparks.append({"sprite": sp, "vel": Vector2.ZERO, "left": 0.0})


func _on_dot_fired(p_pos: Vector2) -> void:
	# 跳伤瞬间：橙光晕一闪 + 4 粒放大火星上飘（用户反馈「燃烧特效没看见」→ 加量）
	var glow: Dictionary = _glows[_glow_idx % GLOW_COUNT]
	_glow_idx += 1
	var gs: Sprite2D = glow["sprite"]
	gs.position = p_pos
	gs.visible = true
	glow["left"] = GLOW_LIFE
	gs.scale = Vector2.ONE * 0.5
	gs.modulate.a = 0.5
	for i in range(4):
		var spark: Dictionary = _sparks[_spark_idx % SPARK_COUNT]
		_spark_idx += 1
		var sp: Sprite2D = spark["sprite"]
		sp.position = p_pos + Vector2(randf_range(-7.0, 7.0), randf_range(-5.0, 3.0))
		sp.visible = true
		sp.scale = Vector2.ONE * randf_range(0.85, 1.4)
		spark["vel"] = Vector2(randf_range(-80.0, 80.0), randf_range(-210.0, -120.0))
		spark["left"] = SPARK_LIFE


func _tick_sparks(p_raw_delta: float) -> void:
	for spark: Dictionary in _sparks:
		var left := float(spark["left"])
		if left <= 0.0:
			continue
		left = maxf(left - p_raw_delta, 0.0)
		spark["left"] = left
		var sp: Sprite2D = spark["sprite"]
		if left <= 0.0:
			sp.visible = false
			continue
		var vel: Vector2 = spark["vel"]
		vel.y += 320.0 * p_raw_delta             # 火星上抛后回落（重力）
		spark["vel"] = vel
		sp.position += vel * p_raw_delta
		sp.modulate.a = clampf(left / SPARK_LIFE * 1.3, 0.0, 1.0)


# ── 碎裂橙色冲击小环（RXN_FIR_ICE 结算瞬间） ──────────────────────
func _build_rings() -> void:
	for i in range(RING_COUNT):
		var ring := Sprite2D.new()
		ring.name = "ShatterRing%d" % i
		ring.texture = TextureFactory.ring_tex(
			PopPalette.ENEMY.lerp(PopPalette.XP, 0.55), 48, 4.0)   # 派生橙（与点燃火苗同源）
		ring.visible = false
		add_child(ring)
		_rings.append({"sprite": ring, "left": 0.0})


func _on_reaction_triggered(p_rxn: int, p_pos: Vector2, _p_target_uid: int) -> void:
	# 仅碎裂（融化）画橙色冲击环；过载/超导由 GameFeel CATALYST 档承担（职责不重叠）
	if p_rxn != GameConst.ReactionType.RXN_FIR_ICE:
		return
	var ring: Dictionary = _rings[_ring_idx % RING_COUNT]
	_ring_idx += 1
	var sp: Sprite2D = ring["sprite"]
	sp.position = p_pos
	sp.visible = true
	ring["left"] = RING_LIFE
	_layout_ring(ring, 0.0)


func _layout_ring(p_ring: Dictionary, p_progress: float) -> void:
	var sp: Sprite2D = p_ring["sprite"]
	var r: float = lerpf(RING_R0, RING_R1, p_progress)
	sp.scale = Vector2.ONE * (r / 19.0)          # 贴图环半径 19px 口径
	sp.modulate.a = clampf(1.0 - p_progress, 0.0, 1.0) * 0.95


# ── 青色涟漪（护盾格挡 / 弧斩消弹——2026-08-29 用户反馈「格挡要看得见」） ──
func _build_ripples() -> void:
	var cyan := PopPalette.PLAYER.lerp(Color.WHITE, 0.18)
	for i in range(RIPPLE_COUNT):
		var sp := Sprite2D.new()
		sp.name = "CyanRipple%d" % i
		sp.texture = TextureFactory.ring_tex(cyan, 48, 4.0)
		sp.visible = false
		add_child(sp)
		_ripples.append({"sprite": sp, "left": 0.0, "r0": 8.0, "r1": 30.0})


func _on_shield_blocked(p_pos: Vector2) -> void:
	# 格挡力场挡下伤害：大涟漪（与 Player._shield_ring 脉冲同源互补）
	_fire_ripple(p_pos, 16.0, 56.0)


func _on_bullet_nullified(p_pos: Vector2) -> void:
	# 弧斩消弹（W9 NULLIFIED 路径）：小涟漪
	_fire_ripple(p_pos, 6.0, 24.0)


func _fire_ripple(p_pos: Vector2, p_r0: float, p_r1: float) -> void:
	var ripple: Dictionary = _ripples[_ripple_idx % RIPPLE_COUNT]
	_ripple_idx += 1
	var sp: Sprite2D = ripple["sprite"]
	sp.position = p_pos
	sp.visible = true
	ripple["left"] = RIPPLE_LIFE
	ripple["r0"] = p_r0
	ripple["r1"] = p_r1
	_layout_ripple(ripple, 0.0)


func _layout_ripple(p_ripple: Dictionary, p_progress: float) -> void:
	var sp: Sprite2D = p_ripple["sprite"]
	var r: float = lerpf(float(p_ripple["r0"]), float(p_ripple["r1"]), p_progress)
	sp.scale = Vector2.ONE * (r / 19.0)
	sp.modulate.a = clampf(1.0 - p_progress, 0.0, 1.0) * 0.85


func _tick_ripples(p_raw_delta: float) -> void:
	for ripple: Dictionary in _ripples:
		var left := float(ripple["left"])
		if left <= 0.0:
			continue
		left = maxf(left - p_raw_delta, 0.0)
		ripple["left"] = left
		var sp: Sprite2D = ripple["sprite"]
		if left <= 0.0:
			sp.visible = false
			continue
		_layout_ripple(ripple, 1.0 - left / RIPPLE_LIFE)


func _tick_rings(p_raw_delta: float) -> void:
	for ring: Dictionary in _rings:
		var left := float(ring["left"])
		if left <= 0.0:
			continue
		left = maxf(left - p_raw_delta, 0.0)
		ring["left"] = left
		var sp: Sprite2D = ring["sprite"]
		if left <= 0.0:
			sp.visible = false
			continue
		_layout_ring(ring, 1.0 - left / RING_LIFE)


# ── 电花碎屑（闪电落点迸溅——用户反馈「感电是个球」的去球化配套） ──
func _build_zaps() -> void:
	var zap_col := PopPalette.SHOCK.lerp(Color.WHITE, 0.4)
	for i in range(ZAP_COUNT):
		var sp := Sprite2D.new()
		sp.name = "ZapBit%d" % i
		sp.texture = TextureFactory.confetti_piece(0)   # 细长小矩形（电花碎屑观感）
		sp.modulate = zap_col
		sp.visible = false
		add_child(sp)
		_zaps.append({"sprite": sp, "vel": Vector2.ZERO, "rot_vel": 0.0, "left": 0.0})


func _fire_zap(p_pos: Vector2) -> void:
	var zap: Dictionary = _zaps[_zap_idx % ZAP_COUNT]
	_zap_idx += 1
	var sp: Sprite2D = zap["sprite"]
	var ang := randf() * TAU
	sp.position = p_pos
	sp.rotation = ang
	sp.visible = true
	sp.scale = Vector2.ONE * randf_range(0.7, 1.2)
	zap["vel"] = Vector2.from_angle(ang) * randf_range(130.0, 260.0)
	zap["rot_vel"] = randf_range(-14.0, 14.0)
	zap["left"] = ZAP_LIFE


func _tick_zaps(p_raw_delta: float) -> void:
	for zap: Dictionary in _zaps:
		var left := float(zap["left"])
		if left <= 0.0:
			continue
		left = maxf(left - p_raw_delta, 0.0)
		zap["left"] = left
		var sp: Sprite2D = zap["sprite"]
		if left <= 0.0:
			sp.visible = false
			continue
		var vel: Vector2 = zap["vel"]
		vel *= maxf(1.0 - 6.0 * p_raw_delta, 0.0)   # 快出快停（迸溅阻尼）
		zap["vel"] = vel
		sp.position += vel * p_raw_delta
		sp.rotation += float(zap["rot_vel"]) * p_raw_delta
		sp.modulate.a = clampf(left / ZAP_LIFE * 1.4, 0.0, 1.0)


# ── DOT 橙光晕（点燃跳伤瞬间体周一闪） ───────────────────────────
func _build_glows() -> void:
	for i in range(GLOW_COUNT):
		var sp := Sprite2D.new()
		sp.name = "DotGlow%d" % i
		sp.texture = TextureFactory.soft_dot(64)
		sp.modulate = Color(PopPalette.ENEMY.lerp(PopPalette.XP, 0.55), 0.5)
		sp.visible = false
		add_child(sp)
		_glows.append({"sprite": sp, "left": 0.0})


func _tick_glows(p_raw_delta: float) -> void:
	for glow: Dictionary in _glows:
		var left := float(glow["left"])
		if left <= 0.0:
			continue
		left = maxf(left - p_raw_delta, 0.0)
		glow["left"] = left
		var sp: Sprite2D = glow["sprite"]
		if left <= 0.0:
			sp.visible = false
			continue
		var t := 1.0 - left / GLOW_LIFE
		sp.scale = Vector2.ONE * lerpf(0.5, 1.15, t)   # 扩散
		sp.modulate.a = 0.5 * (1.0 - t)                # 渐隐

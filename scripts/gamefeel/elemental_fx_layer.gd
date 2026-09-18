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
const IMPACT_COUNT := 10                      # 光束命中迸裂并发池（脉冲激光每跳，用户反馈 2026-08-31）
const IMPACT_LIFE := 0.16                     # 迸裂星闪时长 s
const IMPACT_SPARKS := 3                      # 每次迸裂迸溅火花数（束色圆珠）
const DEVOUR_COUNT := 10                      # 烈焰吞噬内聚并发池（burn_dmg 乘区生效，2026-09-13）
const DEVOUR_LIFE := 0.3                      # 吞噬内聚时长 s
const DEVOUR_SPARKS := 4                      # 每次内卷火苗数（外圈 → 命中点）
const DEVOUR_R0 := 26.0                       # 火苗起始半径 px
const DEVOUR_CD := 0.09                       # 全局节流（激光每跳同源多触发的观感上限）
const KNOCKTEXT_COUNT := 8                    # 击退小字并发池（R7：强击退提示）
const KNOCKTEXT_LIFE := 0.55                  # 击退小字时长 s
const KNOCKTEXT_CD := 0.12                    # 击退小字全局节流（多目标同帧去 spam）

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
var _impacts: Array[Dictionary] = []          # [{flash, sparks[], vels[], left}]（光束命中迸裂池）
var _impact_idx: int = 0
var _devours: Array[Dictionary] = []          # [{flash, sparks[], vels[], left}]（吞噬内聚池）
var _devour_idx: int = 0
var _devour_cd: float = 0.0                   # 吞噬特效全局节流计时
var _ktexts: Array[Dictionary] = []           # [{label, vel_y, left}]（击退小字池）
var _ktext_idx: int = 0
var _ktext_cd: float = 0.0                    # 击退小字节流
var _poison := {"active": false, "center": Vector2.ZERO, "radius": 300.0,
	"left": 0.0, "dur": 6.0, "anim": 0.0}     # 毒云领域持续表现（R10）
var _blasts: Array[Dictionary] = []           # 爆炸层池（R35 火箭筒级：[{flash,fire,ring,smoke, left, r1}]）
var _blast_idx: int = 0
var _skill_rings: Array[Dictionary] = []      # 技能施放金环槽池（R19）
var _skill_ring_idx: int = 0
var _rxn_rings: Array[Dictionary] = []        # 反应专属环槽池（R22：过载双环/超导雾环）
var _rxn_ring_idx: int = 0


func _ready() -> void:
	# 预建全部表现件（池化轮换，运行期零实例化）+ 订阅表现层专用广播（本类 extends Node ✓）
	z_index = 5                                  # 世界层最上（敌/玩家/弹同 z=0 树序层之上）/ HUD（CanvasLayer）之下
	_build_bolts()
	_build_sparks()
	_build_rings()
	_build_ripples()
	_build_zaps()
	_build_glows()
	_build_impacts()
	_build_devours()
	_build_knocktexts()
	EventBus.chain_lightning.connect(_on_chain_lightning)
	EventBus.knockback_hit.connect(_on_knockback_hit)
	EventBus.poison_cloud_cast.connect(_on_poison_cloud_cast)
	EventBus.poison_cloud_tick.connect(_on_poison_cloud_tick)
	EventBus.kill_blast.connect(_on_kill_blast)
	EventBus.skill_cast.connect(_on_skill_cast)   # R19：角色技能施放金环
	EventBus.elemental_dot_fired.connect(_on_dot_fired)
	EventBus.reaction_triggered.connect(_on_reaction_triggered)
	EventBus.shield_blocked.connect(_on_shield_blocked)
	EventBus.bullet_nullified.connect(_on_bullet_nullified)
	EventBus.beam_impact.connect(_on_beam_impact)
	EventBus.burn_devour_proc.connect(_on_burn_devour)

func tick(p_raw_delta: float) -> void:
	# GameLoop ⑦ feel 阶段驱动（raw 通道）；非战斗状态不被驱动 → 表现件自然冻结
	_tick_bolts(p_raw_delta)
	_tick_sparks(p_raw_delta)
	_tick_rings(p_raw_delta)
	_tick_ripples(p_raw_delta)
	_tick_zaps(p_raw_delta)
	_tick_glows(p_raw_delta)
	_tick_impacts(p_raw_delta)
	_tick_devours(p_raw_delta)
	_tick_knocktexts(p_raw_delta)
	_tick_poison(p_raw_delta)
	_tick_blasts(p_raw_delta)
	_tick_skill_rings(p_raw_delta)
	_tick_rxn_rings(p_raw_delta)


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
	# R22 反应专属特效补全（此前仅碎裂有橙环）：
	# · 碎裂 FIR+ICE：橙色冲击环（既有）
	# · 过载 FIR+LTG：紫橙双环冲击（火橙外环 + 雷紫内环）
	# · 超导 ICE+LTG：冰紫雾环慢扩散（全抗削减的减益光环读感）
	match p_rxn:
		GameConst.ReactionType.RXN_FIR_ICE:
			var ring: Dictionary = _rings[_ring_idx % RING_COUNT]
			_ring_idx += 1
			var sp: Sprite2D = ring["sprite"]
			sp.position = p_pos
			sp.visible = true
			ring["left"] = RING_LIFE
			_layout_ring(ring, 0.0)
		GameConst.ReactionType.RXN_FIR_LTG:
			_spawn_reaction_ring(p_pos, Color(1.0, 0.55, 0.2, 1.0), 0.38, 2.6)
			_spawn_reaction_ring(p_pos, PopPalette.SHOCK, 0.3, 1.6)
		GameConst.ReactionType.RXN_ICE_LTG:
			_spawn_reaction_ring(p_pos, PopPalette.PLAYER.lerp(Color.WHITE, 0.4), 0.55, 3.0)
			_spawn_reaction_ring(p_pos, PopPalette.SHOCK, 0.45, 2.0)


func _spawn_reaction_ring(p_pos: Vector2, p_color: Color, p_life: float, p_scale: float) -> void:
	# 反应环槽池（白环贴图 + modulate 上色——零贴图重建）；扩散 + 淡出
	if _rxn_rings.is_empty():
		for i in range(6):
			var sp := Sprite2D.new()
			sp.name = "RxnRing%d" % i
			sp.texture = TextureFactory.ring_tex(Color.WHITE, 48, 4.0)
			sp.visible = false
			add_child(sp)
			_rxn_rings.append({"sprite": sp, "left": 0.0, "life": 0.3, "scale": 2.0})
	var slot: Dictionary = _rxn_rings[_rxn_ring_idx % _rxn_rings.size()]
	_rxn_ring_idx += 1
	var sp: Sprite2D = slot["sprite"]
	sp.position = p_pos
	sp.modulate = p_color
	sp.visible = true
	sp.scale = Vector2.ONE * 0.3
	sp.modulate.a = 1.0
	slot["left"] = p_life
	slot["life"] = p_life
	slot["scale"] = p_scale


func _tick_rxn_rings(p_raw_delta: float) -> void:
	for slot: Dictionary in _rxn_rings:
		var left := float(slot["left"])
		if left <= 0.0:
			continue
		left = maxf(left - p_raw_delta, 0.0)
		slot["left"] = left
		var sp: Sprite2D = slot["sprite"]
		if left <= 0.0:
			sp.visible = false
			continue
		var t := 1.0 - left / float(slot["life"])
		sp.scale = Vector2.ONE * lerpf(0.3, float(slot["scale"]), t)
		sp.modulate.a = 1.0 - t


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


# ── 光束命中迸裂（脉冲激光每跳结算：星闪 + 束色火花迸溅） ──────────
func _build_impacts() -> void:
	# 预建池：每槽 = 四角星闪 ×1 + 圆珠火花 ×3（贴图共享，运行期零实例化）
	for i in range(IMPACT_COUNT):
		var root := Node2D.new()
		root.name = "BeamImpact%d" % i
		root.visible = false
		var flash := Sprite2D.new()
		flash.name = "Flash"
		flash.texture = TextureFactory.star(44, PopPalette.PLAYER.lerp(Color.WHITE, 0.55))
		flash.modulate = Color(1.0, 1.0, 1.0, 0.95)
		root.add_child(flash)
		var sparks: Array[Sprite2D] = []
		for j in range(IMPACT_SPARKS):
			var sp := Sprite2D.new()
			sp.name = "Spark%d" % j
			sp.texture = TextureFactory.bead(PopPalette.PLAYER, 24, false)
			sp.modulate = Color(1.0, 1.0, 1.0, 0.9)
			root.add_child(sp)
			sparks.append(sp)
		add_child(root)
		_impacts.append({"root": root, "flash": flash, "sparks": sparks,
			"vels": PackedVector2Array(), "left": 0.0})


func _on_beam_impact(p_pos: Vector2, p_dir: Vector2) -> void:
	# 取池内下一槽（轮换）：星闪原地爆散（旋转 + 快缩）+ 火花朝束反向半球迸溅（快出快停）
	var impact: Dictionary = _impacts[_impact_idx % IMPACT_COUNT]
	_impact_idx += 1
	var root: Node2D = impact["root"]
	root.position = p_pos
	root.rotation = p_dir.angle()                   # 星闪沿束向（迸裂方向读感）
	root.visible = true
	root.modulate.a = 1.0
	var flash: Sprite2D = impact["flash"]
	flash.rotation = randf() * TAU
	flash.scale = Vector2.ONE * randf_range(0.85, 1.15)
	var vels := PackedVector2Array()
	var sparks: Array = impact["sparks"]
	for j in range(sparks.size()):
		var sp: Sprite2D = sparks[j]
		sp.position = Vector2.ZERO
		sp.scale = Vector2.ONE * randf_range(0.55, 0.85)
		sp.visible = true
		# 迸溅向：束反向 ±70° 扇区（打在目标表面弹开的观感）
		var ang := (-p_dir).angle() + randf_range(-1.2, 1.2)
		vels.append(Vector2.from_angle(ang) * randf_range(120.0, 240.0))
	impact["vels"] = vels
	impact["left"] = IMPACT_LIFE


func _tick_impacts(p_raw_delta: float) -> void:
	for impact: Dictionary in _impacts:
		var left := float(impact["left"])
		if left <= 0.0:
			continue
		left = maxf(left - p_raw_delta, 0.0)
		impact["left"] = left
		var root: Node2D = impact["root"]
		if left <= 0.0:
			root.visible = false
			continue
		var progress := 1.0 - left / IMPACT_LIFE
		var flash: Sprite2D = impact["flash"]
		flash.rotation += p_raw_delta * 18.0
		flash.scale = flash.scale * maxf(1.0 - progress * 5.0 * p_raw_delta, 0.1)
		var sparks: Array = impact["sparks"]
		var vels: PackedVector2Array = impact["vels"]
		for j in range(sparks.size()):
			var sp: Sprite2D = sparks[j]
			if not sp.visible:
				continue
			var vel: Vector2 = vels[j]
			vel *= maxf(1.0 - 7.0 * p_raw_delta, 0.0)
			vels[j] = vel
			sp.position += vel * p_raw_delta
			sp.modulate.a = clampf(left / IMPACT_LIFE * 1.4, 0.0, 1.0)
		root.modulate.a = clampf(1.2 - progress, 0.0, 1.0)


# ── 烈焰吞噬内聚（burn_dmg 乘区生效：外圈火苗向命中点旋入——2026-09-13 用户反馈） ──
func _build_devours() -> void:
	# 预建池：每槽 = 橙色四角星闪 ×1 + 火苗 ×4（由外圈向命中点内卷，与点燃火星同源贴图）
	for i in range(DEVOUR_COUNT):
		var root := Node2D.new()
		root.name = "BurnDevour%d" % i
		root.visible = false
		var flash := Sprite2D.new()
		flash.name = "Flash"
		flash.texture = TextureFactory.star(46, PopPalette.ENEMY.lerp(PopPalette.XP, 0.55))
		flash.modulate = Color(1.0, 1.0, 1.0, 0.9)
		root.add_child(flash)
		var sparks: Array[Sprite2D] = []
		for j in range(DEVOUR_SPARKS):
			var sp := Sprite2D.new()
			sp.name = "Flame%d" % j
			sp.texture = TextureFactory.flame_bit()
			root.add_child(sp)
			sparks.append(sp)
		add_child(root)
		_devours.append({"root": root, "flash": flash, "sparks": sparks,
			"vels": PackedVector2Array(), "left": 0.0})


func _on_burn_devour(p_pos: Vector2) -> void:
	# 取池内下一槽（轮换）+ 全局节流：星闪原地放大渐隐 + 火苗切向内卷（吞噬观感）
	if _devour_cd > 0.0:
		return
	_devour_cd = DEVOUR_CD
	var dv: Dictionary = _devours[_devour_idx % DEVOUR_COUNT]
	_devour_idx += 1
	var root: Node2D = dv["root"]
	root.position = p_pos
	root.visible = true
	root.modulate.a = 1.0
	var flash: Sprite2D = dv["flash"]
	flash.rotation = randf() * TAU
	flash.scale = Vector2.ONE * 0.7
	var sparks: Array = dv["sparks"]
	var vels := PackedVector2Array()
	for j in range(sparks.size()):
		var sp: Sprite2D = sparks[j]
		var ang := TAU * float(j) / float(sparks.size()) + randf_range(-0.3, 0.3)
		var dir := Vector2.from_angle(ang)
		sp.position = dir * DEVOUR_R0 * randf_range(0.85, 1.15)
		sp.scale = Vector2.ONE * randf_range(0.8, 1.2)
		sp.visible = true
		# 内卷速度：指向中心为主 + 0.35 切向（旋入）；稍快于 R0/LIFE 保证贴到中心才熄
		vels.append((-dir + Vector2.from_angle(ang + PI * 0.5) * 0.35).normalized()
			* (DEVOUR_R0 / DEVOUR_LIFE * 1.15))
	dv["vels"] = vels
	dv["left"] = DEVOUR_LIFE


func _tick_devours(p_raw_delta: float) -> void:
	_devour_cd = maxf(_devour_cd - p_raw_delta, 0.0)
	for dv: Dictionary in _devours:
		var left := float(dv["left"])
		if left <= 0.0:
			continue
		left = maxf(left - p_raw_delta, 0.0)
		dv["left"] = left
		var root: Node2D = dv["root"]
		if left <= 0.0:
			root.visible = false
			continue
		var progress := 1.0 - left / DEVOUR_LIFE
		var flash: Sprite2D = dv["flash"]
		flash.rotation += p_raw_delta * 16.0
		flash.scale = Vector2.ONE * lerpf(0.7, 1.3, progress)   # 中心星闪放大 = 汲取聚拢
		flash.modulate.a = 0.9 * (1.0 - progress)
		var sparks: Array = dv["sparks"]
		var vels: PackedVector2Array = dv["vels"]
		for j in range(sparks.size()):
			var sp: Sprite2D = sparks[j]
			if not sp.visible:
				continue
			sp.position += vels[j] * p_raw_delta
			sp.scale = sp.scale * maxf(1.0 - 2.5 * p_raw_delta, 0.25)   # 卷入即缩（被吞）
			sp.modulate.a = clampf(left / DEVOUR_LIFE * 1.5, 0.0, 1.0)


# ── 击退小字（强击退生效提示——R7 用户反馈「击退小字蹦出来」） ──────────
func _build_knocktexts() -> void:
	for i in range(KNOCKTEXT_COUNT):
		var lb := Label.new()
		lb.name = "KnockText%d" % i
		StickerTheme.label_sticker(lb, 15, PopPalette.ENEMY, 3, Color.WHITE, true)
		lb.text = "击退!"
		lb.visible = false
		lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(lb)
		_ktexts.append({"label": lb, "left": 0.0})


func _on_knockback_hit(p_pos: Vector2) -> void:
	if _ktext_cd > 0.0:
		return
	_ktext_cd = KNOCKTEXT_CD
	var slot: Dictionary = _ktexts[_ktext_idx % KNOCKTEXT_COUNT]
	_ktext_idx += 1
	var lb: Label = slot["label"]
	lb.position = p_pos + Vector2(randf_range(-10.0, 10.0), -30.0)
	lb.visible = true
	lb.modulate.a = 1.0
	slot["left"] = KNOCKTEXT_LIFE


func _tick_knocktexts(p_raw_delta: float) -> void:
	_ktext_cd = maxf(_ktext_cd - p_raw_delta, 0.0)
	for slot: Dictionary in _ktexts:
		var left := float(slot["left"])
		if left <= 0.0:
			continue
		left = maxf(left - p_raw_delta, 0.0)
		slot["left"] = left
		var lb: Label = slot["label"]
		if left <= 0.0:
			lb.visible = false
			continue
		lb.position.y -= 46.0 * p_raw_delta          # 上飘
		lb.modulate.a = clampf(left / KNOCKTEXT_LIFE * 1.5, 0.0, 1.0)


# ── 毒云领域持续表现（薇拉技能——R10 用户反馈「只有白色掉血没特效」） ────
func _on_poison_cloud_cast(p_pos: Vector2, p_radius: float) -> void:
	_poison["active"] = true
	_poison["center"] = p_pos
	_poison["radius"] = p_radius
	_poison["left"] = 6.0
	_poison["dur"] = 6.0
	_poison["anim"] = 0.0
	queue_redraw()


func _on_poison_cloud_tick(p_pos: Vector2, p_radius: float) -> void:
	# 每跳刷新中心（跟随玩家）+ 归位时长
	_poison["active"] = true
	_poison["center"] = p_pos
	_poison["radius"] = p_radius
	_poison["left"] = 6.0
	queue_redraw()


func _tick_poison(p_raw_delta: float) -> void:
	if not bool(_poison["active"]):
		return
	_poison["left"] = maxf(float(_poison["left"]) - p_raw_delta, 0.0)
	_poison["anim"] = float(_poison["anim"]) + p_raw_delta
	if float(_poison["left"]) <= 0.0:
		_poison["active"] = false
	queue_redraw()


func _draw() -> void:
	# 毒圈：半透绿盘 + 双层呼吸描边 + 8 颗毒泡（相位漂移）；末 1.5s 渐隐
	if not bool(_poison["active"]):
		return
	var center: Vector2 = _poison["center"]
	var radius: float = float(_poison["radius"])
	var left: float = float(_poison["left"])
	var dur: float = float(_poison["dur"])
	var anim: float = float(_poison["anim"])
	var fade := clampf(left / minf(1.5, dur), 0.0, 1.0)
	var pulse := 1.0 + 0.03 * sin(anim * 5.2)
	# 毒盘
	draw_circle(center, radius * pulse, Color(0.36, 0.85, 0.35, 0.14 * fade))
	draw_circle(center, radius * 0.82 * pulse, Color(0.30, 0.78, 0.30, 0.10 * fade))
	# 双层呼吸描边
	draw_arc(center, radius * pulse, 0, TAU, 64, Color(0.45, 0.95, 0.4, 0.75 * fade), 3.5)
	draw_arc(center, radius * 0.82 * pulse, 0, TAU, 48, Color(0.55, 1.0, 0.45, 0.4 * fade), 2.0)
	# 毒泡（8 颗，相位漂移 + 呼吸）
	for i in range(8):
		var ang := TAU * float(i) / 8.0 + anim * (0.35 + 0.05 * float(i % 3))
		var rr := radius * (0.45 + 0.4 * (0.5 + 0.5 * sin(anim * 1.7 + float(i) * 1.3)))
		var pos := center + Vector2(cos(ang), sin(ang)) * rr
		draw_circle(pos, 7.0 + 3.0 * sin(anim * 4.0 + float(i)), Color(0.5, 1.0, 0.42, 0.5 * fade))


# ── 死亡新星爆炸环（击杀爆炸结算瞬间——R13 用户反馈「加个特效」） ──────
func _on_skill_cast(p_pos: Vector2, _p_character_id: String) -> void:
	# R19 技能施放金环（金外圈+白内芯双层贴图同一槽推进，0.4s——「技能开了」一眼可读）
	if _skill_rings.is_empty():
		for i in range(4):
			var sp := Sprite2D.new()
			sp.name = "SkillRing%d" % i
			sp.texture = TextureFactory.ring_tex(Color(1.0, 0.85, 0.3, 1.0), 48, 4.5)
			sp.visible = false
			add_child(sp)
			_skill_rings.append({"sprite": sp, "left": 0.0})
	var slot2: Dictionary = _skill_rings[_skill_ring_idx % _skill_rings.size()]
	_skill_ring_idx += 1
	var sp2: Sprite2D = slot2["sprite"]
	sp2.position = p_pos
	sp2.visible = true
	sp2.scale = Vector2.ONE * 0.3
	sp2.modulate.a = 1.0
	slot2["left"] = 0.4


func _on_kill_blast(p_pos: Vector2, p_radius: float) -> void:
	# R35 火箭筒级四层爆（用户反馈「没有那种用火箭筒的效果」）：白核闪光 + 橙红火球
	# + 双重冲击波环 + 烟尘余辉；复用通道（死亡新星/Blink/击杀迸裂）同享升级
	if _blasts.is_empty():
		for i in range(6):
			var flash := Sprite2D.new()
			flash.name = "BlastFlash%d" % i
			flash.texture = TextureFactory.soft_dot(64)
			flash.visible = false
			add_child(flash)
			var fire := Sprite2D.new()
			fire.name = "BlastFire%d" % i
			fire.texture = TextureFactory.soft_dot(64)
			fire.visible = false
			add_child(fire)
			var ring := Sprite2D.new()
			ring.name = "BlastRing%d" % i
			ring.texture = TextureFactory.ring_tex(Color(1.0, 0.62, 0.22, 1.0), 48, 5.0)
			ring.visible = false
			add_child(ring)
			var smoke := Sprite2D.new()
			smoke.name = "BlastSmoke%d" % i
			smoke.texture = TextureFactory.soft_dot(64)
			smoke.visible = false
			add_child(smoke)
			_blasts.append({"flash": flash, "fire": fire, "ring": ring, "smoke": smoke,
				"left": 0.0, "r1": 70.0})
	var slot: Dictionary = _blasts[_blast_idx % _blasts.size()]
	_blast_idx += 1
	var r1: float = maxf(p_radius, 40.0) * 1.25
	slot["left"] = 0.5
	slot["r1"] = r1
	for key: String in ["flash", "fire", "ring", "smoke"]:
		var sp: Sprite2D = slot[key]
		sp.position = p_pos
		sp.visible = true
		sp.modulate.a = 1.0
	(slot["flash"] as Sprite2D).scale = Vector2.ONE * (r1 * 0.35 / 32.0)
	(slot["fire"] as Sprite2D).scale = Vector2.ONE * (r1 * 0.25 / 32.0)
	(slot["ring"] as Sprite2D).scale = Vector2.ONE * 0.3
	(slot["smoke"] as Sprite2D).scale = Vector2.ONE * (r1 * 0.5 / 32.0)
	(slot["fire"] as Sprite2D).modulate = Color(1.0, 0.55, 0.18, 1.0)
	(slot["flash"] as Sprite2D).modulate = Color(1.0, 0.97, 0.88, 1.0)
	(slot["smoke"] as Sprite2D).modulate = Color(0.45, 0.38, 0.34, 0.55)


func _tick_skill_rings(p_raw_delta: float) -> void:
	# 技能施放金环推进（扩散 + 淡出；槽池轮换）
	for slot: Dictionary in _skill_rings:
		var left := float(slot["left"])
		if left <= 0.0:
			continue
		left = maxf(left - p_raw_delta, 0.0)
		slot["left"] = left
		var sp: Sprite2D = slot["sprite"]
		if left <= 0.0:
			sp.visible = false
			continue
		var t := 1.0 - left / 0.4
		sp.scale = Vector2.ONE * lerpf(0.3, 2.6, t)
		sp.modulate.a = 1.0 - t


func _tick_blasts(p_raw_delta: float) -> void:
	# R35 四层推进：闪光 0→0.15s 白核快闪即散 / 火球 0→0.5s 主导膨胀由橙转暗 /
	# 冲击环 0.05s 起追到 1.1×r1 / 烟尘 0.1s 起慢散上浮（半透明灰橙）
	for slot: Dictionary in _blasts:
		var left := float(slot["left"])
		if left <= 0.0:
			continue
		left = maxf(left - p_raw_delta, 0.0)
		slot["left"] = left
		if left <= 0.0:
			for key: String in ["flash", "fire", "ring", "smoke"]:
				(slot[key] as Sprite2D).visible = false
			continue
		var t := 1.0 - left / 0.5
		var r1: float = float(slot["r1"])
		var flash: Sprite2D = slot["flash"]
		if t < 0.3:
			flash.modulate.a = 1.0 - t / 0.3
			flash.scale = Vector2.ONE * flash.scale.x * (1.0 + p_raw_delta * 6.0)
		else:
			flash.visible = false
		var fire: Sprite2D = slot["fire"]
		var ft := clampf(t / 0.75, 0.0, 1.0)
		fire.scale = Vector2.ONE * lerpf(r1 * 0.25 / 32.0, r1 * 0.78 / 32.0, ft)
		fire.modulate = Color(1.0, lerpf(0.55, 0.30, ft), lerpf(0.18, 0.10, ft), 1.0 - ft * 0.9)
		var ring: Sprite2D = slot["ring"]
		if t > 0.08:
			var rt := clampf((t - 0.08) / 0.92, 0.0, 1.0)
			ring.scale = Vector2.ONE * lerpf(0.3, r1 * 1.12 / 19.0, rt)
			ring.modulate.a = 0.95 * (1.0 - rt)
		else:
			ring.modulate.a = 0.0
		var smoke: Sprite2D = slot["smoke"]
		if t > 0.18:
			var st := clampf((t - 0.18) / 0.82, 0.0, 1.0)
			smoke.position.y -= p_raw_delta * 26.0
			smoke.scale = Vector2.ONE * lerpf(r1 * 0.5 / 32.0, r1 * 0.95 / 32.0, st)
			smoke.modulate.a = 0.5 * (1.0 - st)
		else:
			smoke.modulate.a = 0.0

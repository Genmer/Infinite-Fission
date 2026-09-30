# scripts/combat/weapon/mirror_image.gd
# R187 W5「万镜回廊」镜面实体（棱镜组）：镜面 = 永久会话态的 WeaponBase（register_mirror
# 类型化入册契约 + 玩家侧鸭子驱动 tick/refresh_fire_interval 双兼容）。
# · 白板语义（与共享侧 make_mirror_image 单源口径同契——内壳经该口构造，ELE 反应乘区
#   永不注册，只继承元素色）：源 WeaponData+等级开火、词条栈 = 棱镜自身栈 copy_full
#   （拷贝源=棱镜——源武器词条零拷贝，「一张棱镜卡 = N 镜生效」）。
# · 结构：外层 MirrorImage 持节拍/预算/奏鸣与词条栈身份；内壳（形态类实例）只当发射
#   行为壳（冷却恒满闸不发拍——节拍归镜面管；激光束重定向/力场公转/词条冷却照走）。
# · 强度：meta_atk_pct = (1+源 meta) × mirror_ratio − 1 → 镜面面板 = 源面板 × ratio
#   × 棱镜栈增益（add_entries 走面板快照，栈已换拷贝源）。
# · MEC_MIRROR_TEMPO「镜面奏鸣」：仅镜面攻速 +15%/层（本体不加成）——镜面自持节拍
#   冷却额外推进。
# · 发射预算：镜面组 ≤600 发/s（MirrorWeapon 滚动窗 Keeper 逐拍问询）——超预算该拍
#   静默跳过 + mirror_budget_skipped 计数，节拍冷却保持不倒退（预算恢复即恢复连射）。
# · 会话态：无 10s 到期、不在 _summon_copies、_reset_skill_temp_state 不清（验收 2
#   反向断言）；读档/波首按武器槽序+固定哈希确定性重推导指向（存档层冻结零新增键）。
class_name MirrorImage
extends WeaponBase

const TINT := Color(0.82, 0.92, 1.0)           # 镜面染色：银白/冰青（禁金色调性——读感区分裁定）
const EDGE := Color(0.55, 0.85, 1.0, 0.95)     # 镜像描边（冰青——与本体读感区分）
const DIAMOND_R := 13.0                        # 棱形镜子标记半径（镜面军团视觉锚）
const RING_RADIUS := 54.0                      # 镜面环绕棱镜的编队半径
const TEMPO_PER_LAYER := 0.15                  # 镜面奏鸣每层攻速（×2 帽 = 词条 stack_max 数据侧）
const SHELL_CADENCE_HOLD := 3600.0             # 内壳不发拍闸（节拍归镜面自持层）

var prism: WeaponBase = null                   # 拷贝源（MirrorWeapon——栈/强度/预算真源）
var source_weapon: WeaponBase = null           # 指向的源武器（会话态弱引用——is_instance_valid 守卫）
var inner: WeaponBase = null                   # 发射行为壳（make_mirror_image 产物——源 data+等级开火）
var mirror_ratio: float = 0.4                  # 强度（mirror_ratio，TH_MIRROR_CHOIR 加成后）
var fired_shots_total: float = 0.0             # 预算审计计口（发射预算压力读数）
var _tempo_mult: float = 1.0                   # 镜面奏鸣合成倍率（仅镜面）


func setup_mirror(p_prism: WeaponBase, p_source: WeaponBase, p_ratio: float,
		p_slot: int) -> bool:
	# 镜面构造：白板口径 = 内壳走共享侧 make_mirror_image 单源构造（源 data+等级开火、
	# 栈=棱镜栈 copy_full、ELE 零注册、镜面旗标），外层沿用同 data/栈的身份外壳。
	# p_slot = 镜位序（环绕编队确定性角位）。
	prism = p_prism
	source_weapon = p_source
	if prism == null or not is_instance_valid(prism) or prism.player == null \
			or p_source == null or not is_instance_valid(p_source) or p_source.data == null:
		return false
	var deps_v: Variant = prism.get("deps_pkg")
	if not (deps_v is Dictionary):
		return false                             # 注入包缺失（未走 MirrorWeapon 装配）→ 拒构
	var player_ref: Node2D = prism.player
	inner = player_ref.call(&"make_mirror_image", p_source, prism)
	if inner == null:
		return false
	add_child(inner)
	# 外层身份壳（WeaponBase 契约字段——面板/索敌/节拍读口与内壳同源同值）
	setup(p_source.data, player_ref, deps_v)
	level = p_source.level
	meta_atk_pct = float(inner.meta_atk_pct)
	trait_stack = inner.trait_stack            # 同一栈实例（镜面身份唯一——逐层一致断言口）
	# 镜面旗标（鸭子协议——读感/断言口与共享侧 marking 同款）
	set("is_mirror_image", true)
	set("mirror_source_id", p_source.data.id)
	set("copy_tint", TINT)
	position = Vector2.from_angle(TAU * float(p_slot) / 6.0) * RING_RADIUS
	apply_state(p_ratio)
	queue_redraw()
	return true


func apply_state(p_ratio: float) -> void:
	# 强度/等级/栈随镜首同步（白板语义：棱镜挂卡即全镜生效；源武器升级即镜面跟随）。
	# ELE 反应乘区永不注册（只继承元素色——内壳 _shot_element 读自身栈=棱镜栈副本）。
	mirror_ratio = p_ratio
	if inner == null or not is_instance_valid(inner):
		return
	if source_weapon != null and is_instance_valid(source_weapon):
		inner.level = source_weapon.level
		level = source_weapon.level
		var src_meta := float(source_weapon.meta_atk_pct)
		var scaled := (1.0 + src_meta) * mirror_ratio - 1.0   # 镜面面板 = 源面板 × ratio
		inner.meta_atk_pct = scaled
		meta_atk_pct = scaled
	if prism != null and is_instance_valid(prism) and prism.trait_stack != null:
		var stack := prism.trait_stack.copy_full()
		inner.trait_stack = stack
		trait_stack = stack                      # 拷贝源=棱镜自身栈（copy_full 逐层品级）
	_tempo_mult = _read_tempo_mult()
	# R191 面板缓存失效：换栈/重铺强度后 _panel_cache 若不失效，build_panel_snapshot
	# 返回旧栈聚合（失效点此前仅 setup/质变/挂卡/升级四处，apply_state 漏网——
	# 棱镜挂 crit 类卡后镜面面板仍报旧值的缺陷修复）
	if inner != null and is_instance_valid(inner):
		inner._invalidate_panel()
	_invalidate_panel()


func tick(p_game_delta: float) -> void:
	# 镜面拍（玩家侧 _mirror_images 同拍驱动；全量覆写 WeaponBase.tick——
	# 预算闸 → 内壳常驻行为推进 → 镜面自持节拍开火 → 奏鸣加速 → 发射计费）
	if inner == null or not is_instance_valid(inner) \
			or prism == null or not is_instance_valid(prism):
		return
	_sync_source_drift()
	if prism.has_method(&"budget_available") and not bool(prism.call(&"budget_available")):
		# 超预算该拍静默跳过：节拍冷却保持不倒退（预算窗恢复即恢复连射）；
		# 内壳常驻行为/词条触发冷却照走（inner.tick 携带词条冷却推进——不哑火计时）
		_hold_shell_cadence()
		inner.tick(p_game_delta)
		DebugStats.count(&"mirror_budget_skipped")
		return
	_hold_shell_cadence()
	inner.tick(p_game_delta)                     # 激光束重定向/力场公转/枪口闪光衰减/词条冷却
	if cooldown_left > 0.0:
		cooldown_left = maxf(cooldown_left - p_game_delta, 0.0)
		if _tempo_mult > 1.0:
			# MEC_MIRROR_TEMPO：仅镜面攻速——冷却额外推进 ×(mult−1)
			cooldown_left = maxf(cooldown_left - p_game_delta * (_tempo_mult - 1.0), 0.0)
	elif has_target_now():                       # R33 无敌不开火门（继承口径：敌现即射）
		var shots := _estimate_shots()
		if try_fire():
			cooldown_left = _fire_interval()
			_last_interval = cooldown_left
			fired_shots_total += shots
			if prism.has_method(&"budget_spend"):
				prism.call(&"budget_spend", shots)


func try_fire() -> bool:
	# 开火入口 = 内壳形态行为（弹道散射锥/激光常驻束/自导寻的/近战力场场判定全保真）
	if inner == null or not is_instance_valid(inner):
		return false
	return inner.try_fire()


func _fire_interval() -> float:
	# 镜面节拍 = 源武器节拍终值（内壳自算：弹道 rof 钳 30 / 其余 cd×(1−CDR)——
	# AFF_ROF_UP/AFF_CDR 随栈副本传导；玩家侧射速乘区在内壳 _player_rof_mult 消费）
	if inner == null or not is_instance_valid(inner):
		return 1.0
	return maxf(inner._fire_interval(), 0.01)


func refresh_fire_interval() -> void:
	# 攻速传导鸭子口（player.refresh_weapon_intervals 扩扫——AFF_ROF_UP/AFF_CDR/
	# 过载咆哮等增益启停即时缩放镜面倒计时，R29 迟到减CD 同式）
	if data == null:
		return
	var new_interval := _fire_interval()
	if _last_interval <= 0.0 or is_equal_approx(new_interval, _last_interval):
		_last_interval = new_interval
		return
	if cooldown_left > 0.0 and new_interval < _last_interval:
		cooldown_left = minf(cooldown_left * new_interval / _last_interval, new_interval)
	_last_interval = new_interval


func source_id() -> StringName:
	# 指向源 id（指向轴断言口；源已失效 → 空串）
	if source_weapon != null and is_instance_valid(source_weapon) and source_weapon.data != null:
		return source_weapon.data.id
	return &""


func is_dormant() -> bool:
	# 休眠镜位（激光镜帽挤出且无非激光候选可替——静默降级为锚束标记）
	return inner == null or not is_instance_valid(inner)


# ── 内部 ──────────────────────────────────────────────────────────
func _hold_shell_cadence() -> void:
	# 内壳不发拍闸（WeaponBase.tick 的 try_fire 分支被大冷却恒封——发射行为只经
	# 镜面自持节拍直调内壳 try_fire， relic 计费口径与「直调通道不计费」一致）
	if inner != null and is_instance_valid(inner):
		inner.cooldown_left = maxf(inner.cooldown_left, SHELL_CADENCE_HOLD)


func _read_tempo_mult() -> float:
	# MEC_MIRROR_TEMPO 层数直读（自身栈=棱镜栈副本——「全灌镜子」专精分叉；
	# 本体 MirrorWeapon 不消费该词条故仅镜面加速）。
	# R199 F03：每层攻速改读挂载条目 data.value（品质缩放沿 card_generator value×scale
	# 链路——金卡 0.39 与卡面一致）；旧 TEMPO_PER_LAYER(0.15) 常数使金卡与白卡无差别。
	# value≤0（桩夹具零声明）回落旧常数，存量断言零位移。
	var mult := 1.0
	if trait_stack == null:
		return mult
	for tb in trait_stack.traits:
		if tb.data != null and tb.data.id == &"MEC_MIRROR_TEMPO":
			var per_layer := float(tb.data.value)
			if per_layer <= 0.0:
				per_layer = TEMPO_PER_LAYER
			mult += per_layer * float(tb.layers)
			break
	return mult


func _sync_source_drift() -> void:
	# 源武器升级漂移跟随（源等级变化不改组合签名——轻量逐拍校验，漂移才整状态重铺）
	if source_weapon != null and is_instance_valid(source_weapon) \
			and inner != null and is_instance_valid(inner) \
			and inner.level != source_weapon.level:
		apply_state(mirror_ratio)


func _estimate_shots() -> float:
	# 单拍发射数估计（预算计费口径：弹道=丸数、自导=1+子弹头、激光≈1 束/拍、近战场 1）
	if data == null:
		return 1.0
	match data.form:
		GameConst.WeaponForm.BALLISTIC:
			var extra := 0.0
			if trait_stack != null:
				extra = float(trait_stack.aggregate_panel().get("add_pellets", 0.0))
			return maxf(get_stat(&"pellets") + extra, 1.0)
		GameConst.WeaponForm.HOMING:
			var sub := 1.0
			if data.homing.has("sub_count"):
				sub += float(data.homing.get("sub_count", 0.0))
			return sub
		_:
			return 1.0


func _draw() -> void:
	# 棱形镜子标记（银白/冰青——镜像描边读感；常驻无金色剪影）
	draw_colored_polygon(_diamond(DIAMOND_R), Color(TINT.r, TINT.g, TINT.b, 0.28))
	draw_polyline(_diamond(DIAMOND_R), EDGE, 1.6, true)
	draw_polyline(_diamond(DIAMOND_R * 0.55), Color(EDGE.r, EDGE.g, EDGE.b, 0.55), 1.0, true)


func _diamond(p_r: float) -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(0, -p_r), Vector2(p_r * 0.72, 0), Vector2(0, p_r), Vector2(-p_r * 0.72, 0),
	])

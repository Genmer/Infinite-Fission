# scripts/entities/player/pickup.gd
# M-02 XpShard（架构 §1.4/§2.12）：经验碎片（Node2D，池化实体——XPPool 模板）。
# R220 刀10：根节点 Area2D → Node2D（原根挂物理 space 却无 shape 无消费者——磁吸/
# 拾取全走 tick 距离判定 :184-186/:299-302，零行为差；物理 space 每 step 省 160 个
# 无消费者 area 的注册/变换同步/pair，R219 方案 R5）。
# 掉落链路（集成包 B.1；AC-16.1）：Enemy 死亡 → GameLoop 掉落侧 spawn → 玩家磁吸半径内
# 自动飞向玩家（Q-13：120px + pickup_pct 词条加成经 Player.pickup_radius 读取）→
# 吸收距离内 gain_xp（升级仲裁 E-16 由 GameLoop 承担）→ 调用方归还池。
# 数值真源：掉落值 = Enemy.exp_value（波次通胀已在 Enemy.spawn 缩放）× 遗物点金手倍率
#（REL_MIDAS +20%，A3 §5——GameLoop 掉落侧折算，碎片值即最终入账值，数值守恒）。
# 满池合并（架构 §5.1 XPPool 行：合并为大面值碎片）：merge_value 由 GameLoop 调用。
# 面值分档（R208 五档）：档=面值/基线比（基线=exp_base×通胀^(w-1)，掉落侧算好传入）：
# <2.5 白 <5 蓝 <12 紫 <40 金 ≥40 七彩——阈值/公式单源本表，色源 PopPalette.XP_TIER_COLORS
#（白/蓝/紫/金 _sync_visual 一次性着色；七彩 _tick_visual_anim 尾部色相回环）。
# R211 亮度重构：星体贴图改白色填充（缓存键 star_44_ffffff），档色 + 档内透明度全走
# modulate 乘法——旧柠檬黄底 ffc93c × 紫档 b06ef7 = b0573a 赭石棕（棕星根因）一并消除，
# 全档更亮；透明度按经验量 50%（档底）→ 100%（档顶）线性渐进（xp_tier_alpha 单源）。
# R216 刀①（vc23 桶遥测定案：桶恒 1+2 而 dc 342→1045——碎片同贴图但每片 modulate 唯一
# =全员断批，死亡堆数百片=dc 大头）：档色/档内透明度改**烤进贴图变体**（4 档 × 3 级
# 量化 alpha + 彩档 6 色相步进，star() 缓存键含填充色自动分键），modulate 恒白、亮度
# 表现（回归亮闪/巡航提亮）改缩放通道（transform 不 break 批）+ XP 池挂 TexBucketHost
# （贴图定档落同贴图桶，树序交错不再断批）。口径变更：档内 alpha 连续渐进 → 3 级量化
# （0.5/0.75/1.0，帧率优先）；彩档色相连续回环 → 6 步进（步周期 0.476s，六色回环保
# 持可辨）；回归亮闪亮度乘法 → 缩放脉冲；巡航 ×1.15 提亮去除（bob 保持）。
#
# 拾取链路重做（用户实测反馈 2026-08-29 裁定：玩家活动区=下半屏，敌死掉落全屏分布，
# 上半屏碎片永远捡不到 → 四段行为）：
#   ① 出生弹跳散开（activate 期一次性水平散射 + 原地果冻弹跳表现）
#   ② 下漂：落定 1s 后缓慢下沉 80px/s（带左右轻摆），直到进入下半屏活动带（y>55% 屏高）
#   ③ 活动带内原地果冻 bob
#   ④ 超时 8s 未拾取：亮一下 → 全屏追踪玩家（加速飞、无视距离）——任何位置经验必可回收
# 磁吸口径不变：任意阶段进入 120px（Q-13）即转磁吸飞行（优先级最高）。
# 编排说明：tick(game_delta) 由 GameLoop 帧序②（玩家/拾取阶段）驱动——不自跑
# _physics_process（池 _prepare_for_pool 亦会关闭）；拾取判定用距离（拾取量少，免物理回调）。
class_name XpShard
extends Node2D

var value: float = 0.0                        # 面值（已含点金手倍率；gain_xp 直收入账）
var _baseline: float = 0.0                    # R196 分档基线（exp_base×通胀^(w-1)；0=未定→恒白档）
var _tier: int = 0                            # R196 当前档位缓存（R208 五档：0 白 1 蓝 2 紫 3 金 4 七彩；_sync_visual 刷新）

var _magnet: bool = false                     # 已进入磁吸半径（加速飞向玩家）
var _sprite: Sprite2D = null
var _player_cache: Node2D = null

# 下漂/回归行为（用户裁定 2026-08-29；磁吸 120 与 MAGNET_SPEED 手感口径不变）
const PHASE_BURST := 0                        # 出生弹跳（0.25s 表现）
const PHASE_REST := 1                         # 落定等待（至 1.0s）
const PHASE_SINK := 2                         # 缓慢下沉（进入活动带为止）
const PHASE_BOB := 3                          # 活动带内果冻 bob
const BURST_TIME := 0.25                      # 出生弹跳时长 s
const REST_TIME := 1.0                        # 落定后等待时长 s（阶段②起点）
const SINK_SPEED := 80.0                      # 下沉速度 px/s
const SINK_BAND := 0.55                       # 下半屏活动带 y 阈值（屏高比例）
const SWAY_AMP := 26.0                        # 下沉左右摆幅度 px/s
const RETURN_TIME := 4.5                      # 超时回归阈值 s（8s 太久——大怪掉的大珠「不消失」观感，缩到 4.5s）
const HOMING_SPEED_INIT := 240.0              # 追踪初速 px/s
const HOMING_ACCEL := 620.0                   # 追踪加速度 px/s²
const HOMING_SPEED_MAX := 760.0               # 追踪速度上限 px/s
const HOMING_FLASH_TIME := 0.3                # 回归前亮一下时长 s
const ABSORB_DISTANCE := 24.0                 # 吸收判定距离 px（玩家 hitbox 16 + 碎片半径 ~6 + 余量）
const MAGNET_SPEED := 1040.0                  # 磁吸飞行速度 px/s（R214 双驱动修复补偿：原 520
                                               # ×帧序②⑦双 tick 实效 1040——修为⑦单驱动后 ×2
                                               # 补偿，τ=1 时单帧位移恒等；顿帧期（τ<1，旧②段
                                               # 吃顿帧缩放、⑦段恒 raw）磁吸片不再被减速=瞬态演出差异）
const TEX_SIZE := 44                          # 星星贴图画布边长（TextureFactory 口径）
# R208 五色递进（用户口径「白-蓝-紫-金-彩 递进出现」）：旧四档切分与敌表数值分布
# 错位——29 种怪 ratio 挤在 1~6.7（绿档内）而 [8,200) 金带几乎无原生怪（用户实测
# 「上来就是金色」= 精英 e_exp 倍率与碎片合并恰落旧金线）。五档重切 + game_loop 基线
# 随波轻衰减（0.982^w）→ 同怪越往后掉色越高，颜色随进程递进展开。
const XP_TIER_THRESHOLDS: Array[float] = [2.5, 5.0, 12.0, 40.0]  # 面值/基线比：<2.5 白 <5 蓝 <12 紫 <40 金 ≥40 彩
const XP_TIER_RAINBOW := 4                    # 七彩档（超末档；色相回环，占位色不被直读）

var _phase: int = PHASE_BURST                 # 行为阶段（见常量块）
var _age: float = 0.0                         # 存活时长 s（超时回归判据）
var _anim_t: float = 0.0                      # 表现时钟（bob/弹跳相位）
var _homing: bool = false                     # 超时全屏追踪态
var _homing_speed: float = HOMING_SPEED_INIT
var _homing_flash: float = 0.0                # 回归亮一下剩余
var _value_scale: float = 1.0                 # 面值缩放（bob 动画的乘算基准）
var _rainbow_step: int = -1                   # R216：彩档当前色相步进 0~5（-1=非彩档）
var bucket_host: Node = null                  # R216 刀①：XP 池 TexBucketHost 注入（掉落侧
                                               # _spawn_xp_shard 赋值；null=老测试直连池零行为）
# R233 T6（决策3.1 插值层）：渲染插值双缓冲——global_position 定性为「显示缓存」，模拟
# 真位以 _ip_curr 为准（game_loop 恢复/快照遍历维护时序）。_ip_prev=N-1 步末位。
# activate 尾部置位 prev=curr=出生位（散射落点定型后——防池上家残位飞入 + 中途 spawn
# 无跳变）；release 不清（下任 activate 重置覆盖，设计 3.4）。
var _ip_prev: Vector2 = Vector2.ZERO
var _ip_curr: Vector2 = Vector2.ZERO


func _ready() -> void:
	# 池化实例化期组装渲染（代码组装为主；.tscn 仅做容器）
	_sprite = Sprite2D.new()
	_sprite.name = "Visual"
	_sprite.centered = true
	# R211 白体贴图：档色/透明度全走 modulate 乘法——旧柠檬黄底（PopPalette.XP ffc93c）
	# 预染进贴图后经 modulate 逐通道相乘，紫档 b06ef7 × ffc93c = b0573a 赭石棕（棕星
	# 根因，蓝档同理压成暗绿）；白底 × 档色 = 档色原样，全体提亮。新缓存键 star_44_ffffff，
	# 其他 star() 调用者（hud 默认黄/投射物）互不影响。
	_sprite.texture = TextureFactory.star(TEX_SIZE, Color.WHITE)
	add_child(_sprite)
	visible = false                            # 池内不可见（activate 后可见）


func activate(p_value: float, p_baseline: float = 0.0) -> void:
	# 池取出后统一初始化（掉落侧：GameLoop._spawn_xp_shard 已设置 position）。
	# 出生散射在本函数一次性完成（落点即定——tick 期位置只按下沉/追踪推进，口径可测）。
	# R196：p_baseline 可选参（旧调用零破坏）——0 → 恒白档（降级不崩）
	value = maxf(p_value, 0.0)
	_baseline = maxf(p_baseline, 0.0)
	_magnet = false
	_player_cache = null
	_phase = PHASE_BURST
	_age = 0.0
	_anim_t = 0.0
	_homing = false
	_homing_speed = HOMING_SPEED_INIT
	_homing_flash = 0.0
	# 出生随机水平散射（±26px；纯表现散开，Y 不动——不改变掉落行分布）
	global_position.x = clampf(global_position.x + randf_range(-26.0, 26.0), 12.0, 708.0)
	_ip_prev = global_position                 # R233 T6：插值缓冲置出生位（prev=curr=散射落点
	_ip_curr = global_position                 # ——中途 spawn 无跳变；池上家残位防飞入）
	visible = true
	_sync_visual()


func is_magnet() -> bool:
	return _magnet


func ready_to_absorb() -> bool:
	# R214 吸收分帧帽判据（GameLoop._tick_magnetized_shards 帽满冻结用；纯读不位移）：
	# 磁吸/回归态且已在吸收圈内（<=ABSORB_DISTANCE——tick 即吸收+gain_xp 的临界）
	if not _magnet and not _homing:
		return false
	var player := _player()
	if player == null:
		return false
	return global_position.distance_to(player.global_position) <= ABSORB_DISTANCE


func force_magnet() -> void:
	# 波次清空全屏回收（R7）：任何阶段直接转磁吸飞行——碎片任何情况下波末必回收
	_magnet = true


func merge_value(p_extra: float, p_baseline: float = 0.0) -> void:
	# 满池合并为大面值碎片（数值守恒，架构 §5.1；不重置磁吸/阶段态）。
	# R196：基线取双方 max 后随 _sync_visual 重分档（可选参，旧调用零破坏）
	value += maxf(p_extra, 0.0)
	_baseline = maxf(_baseline, maxf(p_baseline, 0.0))
	_sync_visual()


static func xp_tier_of(p_value: float, p_baseline: float) -> int:
	# R196 分档真源（R208 五档化）：面值/基线比 <2.5 白 <5 蓝 <12 紫 <40 金 ≥40 七彩
	# （阈值单源 XP_TIER_THRESHOLDS）；基线≤0 → 恒白档（降级不崩——旧调用/无通胀数据
	# 路径安全）
	if p_baseline <= 0.0:
		return 0
	var ratio := p_value / p_baseline
	for i in XP_TIER_THRESHOLDS.size():
		if ratio < XP_TIER_THRESHOLDS[i]:
			return i
	return XP_TIER_THRESHOLDS.size()


static func xp_tier_alpha(p_value: float, p_baseline: float) -> float:
	# R211 档内透明度真源：50%（档底）→ 100%（档顶）按档内位置线性渐进；顶档按
	# value/顶阈值封顶 1.0（ratio≥40 即满，不再上探）。阈值单源 XP_TIER_THRESHOLDS
	#（与 xp_tier_of 同表）；基线≤0 → 恒 0.5（降级不崩——与白档降级同口径）。
	# 档区间 [lo, hi)：lo = thresholds[tier-1]（tier 0 时 0），hi = thresholds[tier]。
	if p_baseline <= 0.0:
		return 0.5
	var ratio := p_value / p_baseline
	if ratio >= XP_TIER_THRESHOLDS[XP_TIER_THRESHOLDS.size() - 1]:
		return 1.0
	var tier := xp_tier_of(p_value, p_baseline)
	var lo := XP_TIER_THRESHOLDS[tier - 1] if tier > 0 else 0.0
	var hi := XP_TIER_THRESHOLDS[tier]
	return 0.5 + 0.5 * clampf((ratio - lo) / (hi - lo), 0.0, 1.0)


func tick(p_game_delta: float) -> bool:
	# 磁吸/下漂/追踪推进；返回 true = 已吸收（调用方负责池归还）。无玩家引用 → 原地等待。
	if value <= 0.0:
		return true                            # 零面值碎片直接回收（防御）
	var player := _player()
	_age += p_game_delta
	_anim_t += p_game_delta
	_tick_visual_anim(p_game_delta)
	if player == null:
		return false
	var d := global_position.distance_to(player.global_position)
	# 磁吸优先（任意阶段；Q-13 半径口径不变）
	if not _magnet and d <= _pickup_radius(player):
		_magnet = true
	if _magnet:
		if d <= ABSORB_DISTANCE:
			player.gain_xp(value)              # 经验入账（升级仲裁 E-16 在 GameLoop）
			return true
		global_position = global_position.move_toward(player.global_position,
			MAGNET_SPEED * p_game_delta)
		return false
	# 超时回归（用户裁定：任何位置的经验最终都能捡到）：亮一下 → 全屏加速追踪。
	# R7：大面值碎片（Boss/精英大珠，≥15）2s 即回归——用户反馈「大怪碎片残留不消失」
	var return_time := RETURN_TIME if value < 15.0 else 2.0
	if not _homing and _age >= return_time:
		_homing = true
		_homing_flash = HOMING_FLASH_TIME
		_homing_speed = HOMING_SPEED_INIT
	if _homing:
		if _homing_flash > 0.0:
			_homing_flash = maxf(_homing_flash - p_game_delta, 0.0)
		_homing_speed = minf(_homing_speed + HOMING_ACCEL * p_game_delta, HOMING_SPEED_MAX)
		global_position = global_position.move_toward(player.global_position,
			_homing_speed * p_game_delta)
		if d <= ABSORB_DISTANCE:
			player.gain_xp(value)
			return true
		return false
	# ①→②→③：出生弹跳 → 落定 1s → 下沉至下半屏活动带 → 原地 bob
	match _phase:
		PHASE_BURST:
			if _age >= BURST_TIME:
				_phase = PHASE_REST
		PHASE_REST:
			if _age >= REST_TIME:
				_phase = PHASE_BOB if _in_sink_band() else PHASE_SINK
		PHASE_SINK:
			global_position.y += SINK_SPEED * p_game_delta
			global_position.x = clampf(
				global_position.x + sin(_age * 3.1) * SWAY_AMP * p_game_delta, 12.0, 708.0)
			if _in_sink_band():
				_phase = PHASE_BOB
		PHASE_BOB:
			pass                               # 原地果冻 bob（纯表现，_tick_visual_anim）
	return false


# ── 池归还清零契约（E-04/E-05） ───────────────────────────────────
func _reset_state() -> void:
	value = 0.0
	_baseline = 0.0                             # R196 分档基线随池归还清零
	_tier = 0
	_magnet = false
	_player_cache = null
	_phase = PHASE_BURST
	_age = 0.0
	_anim_t = 0.0
	_homing = false
	_homing_speed = HOMING_SPEED_INIT
	_homing_flash = 0.0
	_value_scale = 1.0
	_rainbow_step = -1                      # R216：彩档步进随池归还清残留
	if _sprite != null:
		_sprite.modulate = Color.WHITE
		_sprite.scale = Vector2.ONE
		_sprite.position = Vector2.ZERO
		_sprite.rotation = 0.0


# ── 内部 ──────────────────────────────────────────────────────────
func _in_sink_band() -> bool:
	# 下半屏活动带判定（y > 55% 屏高；res 真源 GameConfig.balance.res_logic）
	var h := 1280.0
	if GameConfig.balance != null:
		h = float(GameConfig.balance.res_logic.y)
	return global_position.y > h * SINK_BAND


func _tick_visual_anim(_p_game_delta: float) -> void:
	# 纯表现（不触碰 global_position）：出生弹跳 / 下沉左右倾摆 / 果冻 bob / 回归亮起
	if _sprite == null:
		return
	var f := 1.0
	if _phase == PHASE_BURST:
		# 出生弹跳：1.35 → 1 弹性回落
		var bt := clampf(_age / BURST_TIME, 0.0, 1.0)
		f = 1.0 + 0.35 * (1.0 - bt) * cos(bt * PI * 2.2)
	elif _homing:
		# R216 刀①：回归亮闪/巡航提亮改缩放通道（原亮度乘法 modulate 逐片唯一=断批；
		# transform 不 break 批——亮闪脉冲 0.45 峰值补偿亮度乘法移除的「亮一下」读感）
		if _homing_flash > 0.0:
			var ft := _homing_flash / HOMING_FLASH_TIME
			f = 1.0 + 0.45 * ft
		else:
			f = 1.0 + 0.08 * sin(_anim_t * 18.0)
	elif _phase == PHASE_SINK:
		# 下漂：轻微左右倾摆（旋转）+ 微 bob
		_sprite.rotation = sin(_anim_t * 3.1) * 0.14
		f = 1.0 + 0.05 * sin(_anim_t * 5.2)
	else:
		# 落定 bob：果冻呼吸（下漂/活动带内同享基调）
		_sprite.rotation = 0.0
		f = 1.0 + 0.09 * sin(_anim_t * 5.2)
	_sprite.scale = Vector2(_value_scale * f, _value_scale * (2.0 - f))
	# R196 七彩档色相回环（R208 五档：仅彩档 tier 4；白/蓝/紫/金档维持 _sync_visual
	# 烤色贴图不重刷）。R216 刀①：逐帧 HSV modulate → 6 色相步进换贴图（同变体合批；
	# 步周期 1/(0.35×6)≈0.476s，换贴图随换桶；modulate 恒白不被本路径触碰）。
	if _tier >= XP_TIER_RAINBOW:
		var step := clampi(int(fmod(_anim_t * 0.35, 1.0) * 6.0), 0, 5)
		if step != _rainbow_step:
			_rainbow_step = step
			_sprite.texture = TextureFactory.star(TEX_SIZE, _baked_tier_color())
			_place_in_bucket()


func _pickup_radius(p_player: Node2D) -> float:
	# 玩家磁吸半径（Q-13：120px；pickup_pct 词条加成在 Player.pickup_radius 落地）
	var r: Variant = p_player.get("pickup_radius")
	return float(r) if r != null else 120.0


func _player() -> Node2D:
	# 玩家引用缓存（组查找——与 Enemy/ProjectileBase 同口径）
	if _player_cache == null or not is_instance_valid(_player_cache):
		_player_cache = null
		var tree := get_tree()
		if tree != null:
			_player_cache = tree.get_first_node_in_group(&"player") as Node2D
	return _player_cache


func _sync_visual() -> void:
	# 星星面值越大越醒目（0.9×~1.5× 等比；方向 C 口径）。
	# R216 刀①：档色 + 档内 alpha **烤进贴图变体**（TextureFactory.star 缓存键含填充色，
	# 4 档×3 量化 alpha + 彩档 6 色相步进自动分键）——modulate 恒白 → 同变体碎片同贴图
	# 2D 合批（vc23 桶遥测：每片 modulate 唯一=全员断批）。merge 爬档经本函数自动换
	# 贴图换桶；彩档 _anim_t 起步相位在此定初值（后续 _tick_visual_anim 步进接管）。
	if _sprite == null:
		return
	_value_scale = 0.9 + clampf(value / 30.0, 0.0, 0.6)
	_sprite.scale = Vector2(_value_scale, _value_scale)
	_tier = xp_tier_of(value, _baseline)
	if _tier >= XP_TIER_RAINBOW:
		_rainbow_step = clampi(int(fmod(_anim_t * 0.35, 1.0) * 6.0), 0, 5)
	else:
		_rainbow_step = -1
	_sprite.texture = TextureFactory.star(TEX_SIZE, _baked_tier_color())
	_sprite.modulate = Color.WHITE
	_place_in_bucket()


func _baked_tier_color() -> Color:
	# R216 刀①：变体贴图填充色真源——非彩档=档色 rgb × 量化档内 alpha（0.5/0.75/1.0
	# 三级：xp_tier_alpha 连续值 [0.5,1.0] 按 1/3 带宽取整）；彩档=6 色相步进之一
	#（alpha 恒 1.0——顶档 xp_tier_alpha 封顶=无量化损失）。
	if _tier >= XP_TIER_RAINBOW:
		return Color.from_hsv(fmod(float(clampi(_rainbow_step, 0, 5)) / 6.0, 1.0), 0.7, 1.0)
	var c := PopPalette.xp_tier_color(_tier)
	c.a = 0.5 + 0.25 * clampi(int((xp_tier_alpha(value, _baseline) - 0.5) * 6.0), 0, 2)
	return c


func _place_in_bucket() -> void:
	# R216 刀①：贴图变体定档后落同贴图桶（换贴图自动换桶——merge 爬档/彩档步进均经
	# 本口）。host null（老测试直连池）零操作。桶为原点无变换，local position 语义恒等。
	if bucket_host != null and _sprite != null and _sprite.texture != null:
		bucket_host.place(self, _sprite.texture)

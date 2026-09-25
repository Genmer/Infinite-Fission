# scripts/entities/player/player.gd
# M-02 Player（架构 §2.12）：Area2D 命中盒（低频，Q-15 例外通道）+ 磁吸拾取区（120px）。
# 操作：相对拖动（Q-3）——_unhandled_input 采样拖动向量，tick 应用 + 活动区钳制（下 40% 屏，E-15）。
# 受击：简化路径（Q-16）——无敌帧 contact_tick=0.6s 判定 → 直接扣 HP → 事件，不入 M-12。
# 编排说明（§2.17）：tick(game_delta, move_delta) 由 GameLoop ② 驱动；
# move_delta 非零 = GameLoop 显式投递（E-15 输入采样）；零向量 = 玩家消费自身 _unhandled_input 采样。
class_name Player
extends Area2D

# 初始 HP 真源 = cfg player_base_hp=60（用户实测反馈 2026-08-29 裁定回注，原 100 被围
# 数分钟不死无张力；贴脸 4.5s 死、E1 一次磨血 16.7%、E4 爆炸 33%、Boss 接触 33~58%
# ——「杂兵磨血、精英/Boss 杀人」梯度成立，且 REL_HARVEST 0.4% 回血不致被满血钳死）。
var max_hp: float = 60.0                       # 声明值与 cfg 同口径（_ready 覆读 cfg 真源）
var hp: float = 60.0
var move_speed: float = 280.0                 # 移速（相对拖动 1:1 口径下的调试/键盘备用参数）
var pickup_radius: float = 120.0
var gold: int = 0                             # 金币（击杀 gold_drop 掉账；战地黑市货币，M7）
var _difficulty: int = 0                      # R73 难度档镜像（GameLoop 开局注入；经验乘区源）
var reroll_charges: int = 2                   # 选卡刷新次数（换一批；开局 2 + 局外养成，2026-08-31 用户反馈）
var _last_move_dir: Vector2 = Vector2.UP      # 最近移动方向（游侠闪现取向）
var revives_left: int = 0                     # 应急协议剩余复活（局外养成，每局重置）
var map_xp_mult: float = 1.0                  # 地图词缀·经验倍率（GameLoop.start_run 注入）              # Q-13 磁吸半径（pickup_pct 词条加成属包 3 常驻词条）
var map_gold_mult: float = 1.0                # 地图祝福·金币倍率（GameLoop 金币掉账消费；词缀二期）
var hazard_slow_left: float = 0.0             # 冰锁圈外部减速剩余 s（R18 P2 frost flavor）
var hazard_slow_mult: float = 1.0             # 拖动映射系数（0.65 = 减速 35%，到期还原 1.0）
var map_rof_mult: float = 1.0                 # 地图祝福·射速倍率（WeaponBase._fire_interval 消费；词缀二期）
var map_wave_heal_pct: float = 0.0            # 地图祝福·每波回血比 max_hp（GameLoop wave_cleared 消费；词缀二期）
# 角色系统（用户反馈「不同的角色有不同的技能」）：选择经 Meta 持久化，开局 set_character 应用
var character_id: StringName = &"sentinel"
var character_atk_pct: float = 0.0            # 角色攻击修正（武器面板经 meta_atk_pct 合成）
var rof_mult: float = 1.0                     # 过载咆哮射速倍率（WeaponBase._fire_interval 消费）
var comp_rof_mult: float = 1.0                # 无技能角色 CDR 折算·全武器射速乘区（改造者·枢契约；refresh_skill_cd 真源，有技能角色恒 1.0）
var skill_cd_relic_mult := 1.0                   # R80 遗物技能冷却乘区（时之沙 ×0.8；refresh 常驻消费）
var skill_cd_base: float = 30.0
var skill_cd_left: float = 0.0
var skill_active_left: float = 0.0            # 增益型技能剩余时长（过载）
var _skill_shield_left: float = 0.0           # 紧急护盾剩余（表现走护盾泡）
var _skill_fx_left: float = 0.0               # 技能演出剩余 s（R19：HUD 时长条 + 玩家光环）
var _skill_fx_max: float = 0.0                # 演出总长（ratio 分母）
# 毒云领域（毒系学者·薇拉，P2 数值真源）：以玩家为中心 300px、持续 6s；每 0.5s 对域内敌
# 结算 8% 主武器 ATK 毒伤 + 减速 20%。直结算通道（不动管线/不挂元素状态——走 AOE_SECONDARY
# 幂等键，同构 mank 毒沼绽放先例；减速走 Enemy.ext_slow 外部乘区，与元素冰缓正交）
var _poison_cloud_left: float = 0.0           # 毒云剩余（game_delta 通道）
var _poison_cloud_tick_left: float = 0.0      # 下一跳倒计时
# 召唤僚机（召唤师·诺亚，R183 用户重定义数值真源）：随机复制 2 把当前已装备武器
#（同数据/同等级/词条栈全量拷贝——含逐层品级数值），持续 10s 到期回收；
# 两架护航舰（R93 视觉）随行 + 复制武器进悬浮环金色染色参战。副本不占真实槽位
#（独立 _summon_copies 数组——选卡目标/存档序列化/词条叠层判据均不受污染）
var _summon_left: float = 0.0                 # 僚机剩余（game_delta 通道）
var _summon_drones: Array[Node2D] = []        # R93 护航舰（编队侧翼跟随的视觉件）
var _summon_copies: Array[WeaponBase] = []    # R183 复制武器（tick 驱动 + 悬浮环展示）
# R187 W5 万镜回廊：镜面独立数组（永久会话态——不占武器槽、永不进 _summon_copies、
# 不随 _reset_skill_temp_state 清空；读档/波首按武器槽序+固定哈希确定性重推导指向，
# 存档层冻结零新增键）。实体类（MirrorImage）归棱镜组 mirror_image.gd——本侧按
# WeaponBase 鸭子协议驱动（tick/refresh_fire_interval/is_instance_valid 三守卫）。
var _mirror_images: Array = []
var _mirror_locked: bool = false              # MEC_MIRROR_LOCK 挂载态（挂卡后波首不重掷——确定性出口兜底）
var invuln_left: float = 0.0                  # 受击无敌帧（contact_tick=0.6s 口径）
var _revive_protect_left: float = 0.0         # 复活保护青弧剩余 s（E2 r2；只由 _try_revive 置位，respawn/restore 显式清零）
var _revive_protect_max: float = 0.0          # 青弧总长（ratio 分母；演出态不入快照——continue 局由 restore 清零）
var weapon_slots: Array[WeaponBase] = []      # ≤7（集成包 B.8 第二批收紧：pkg2 用例已迁移 WeaponBase 真件）
var orbit_avatars: WeaponOrbitAvatars = null  # 武器悬浮层（R25：发射口对齐化身）
var unlocked_slots: int = 2                   # 开局 = 难度默认 2/3/3；w7→3 / Boss1→4 / Boss2 或 w21→5 / Boss3 或 w31→6（R183）
var slot_bonus: int = 0                       # R185 金卡解锁计数（帽内提前解锁数，不抬高有效帽）
var level: int = 1
var xp: float = 0.0
var xp_need: float = 14.0                     # 14 × lv^1.4
var hitbox_radius: float = 16.0               # 命中盒半径（敌弹距离判定口径）

var _dead: bool = false
var _drag_accum: Vector2 = Vector2.ZERO       # 相对拖动采样累计（E-15）
var input_enabled: bool = true                 # 输入使能（暂停恢复 0.5s 防误触宽限期——GameLoop 驱动）
# 格挡力场（MEC_SHIELD 玩家侧接线，A3 §4.4：每 interval_s 生成护盾格挡 1 次接触伤害，
# 2 层 → 5.5s；shield_interval<=0 = 未持有。charge 就绪 → 力场环可见；格挡瞬间脉冲扩散）
var shield_interval: float = 0.0
var shield_timer: float = 0.0                  # 充能剩余（就绪后停走；HUD 护盾条数据源）
var shield_ready: bool = false
var _shield_pulse_left: float = 0.0            # 格挡扩散脉冲剩余（表现层）
var _pickup_area: Area2D = null
var _pickup_shape: CollisionShape2D = null
var _hit_shape: CollisionShape2D = null
var _sprite: Sprite2D = null
var _flame_l: Sprite2D = null                  # 左引擎喷焰（移动时点亮 + 抖动）
var _flame_r: Sprite2D = null                  # 右引擎喷焰（与左反相抖动）
var _flash: Sprite2D = null                    # 受击白闪剪影（叠在机体上方）
var _shield_ring: Sprite2D = null              # 格挡力场环（就绪可见 + 格挡脉冲——A3 §4.4 MEC_SHIELD）
var _flash_left: float = 0.0
var _punch_left: float = 0.0                   # 受击 squash punch 剩余
var _tilt: float = 0.0                         # 移动倾斜（横移 bank）
var _anim_t: float = 0.0                       # 帧内动画时钟（喷焰抖动/无敌闪烁/hover）
var _visual_scale: float = 1.0                 # 机体基础缩放（hitbox 口径换算）
var _deps: Dictionary = {}                     # setup 注入位（pipeline/pools/grid/registry——包 3/4 接线）

const MAX_SLOTS := GameConst.MAX_WEAPON_SLOTS   # 槽位数组上限（真源 GameConst；难度帽 5/6/6 恒在其内）
const RESPAWN_INVULN_S := 1.5                 # 重开无敌帧 s（B_spec 无数值 → 主控裁定，见 respawn 注释）
const REVIVE_INVULN_S := 3.0                  # 复活无敌帧 s（E2 r2：2.0→3.0，对齐哨兵 3.0 无敌档不新增档位）
const REVIVE_CLEAR_RADIUS := 260.0            # 复活清弹缓冲半径 px（E2 r2；与旧 kill_blast r=260 同口径）
const REVIVE_CLEAR_CAP := 24                  # 复活清弹上限（与 _skill_stomp 消弹同帽——公平性缓冲而非清场权）
const SHIP_TEX_R := 38.0                       # 机体贴图本体半径 px（TextureFactory.ship 96 画布）
const VISUAL_MULT := 1.35                      # 视觉半径 / 命中盒（弹幕游戏惯例：盒小于形）
const FLASH_TIME := 0.18                       # 受击白闪时长
const PUNCH_TIME := 0.24                       # 受击 squash punch 时长
const HOVER_AMP := 2.6                         # hover 待机浮动幅度 px（用户反馈：主角机体活起来）
const HOVER_PERIOD := 2.6                      # hover 周期 rad/s 基频
const POD_L := Vector2(-20.0, 34.0)            # 左引擎舱喷口（贴图坐标——随 _visual_scale 缩放）
const POD_R := Vector2(20.0, 34.0)             # 右引擎舱喷口
const SHIELD_PULSE_TIME := 0.32                # 格挡脉冲扩散时长 s（表现层）
const SHIELD_RING_R := 46.0                    # 力场环贴图基准半径 px（TextureFactory.shield_bubble）
# ── P2 角色技能参数（数值真源：META_ROADMAP §5.10 角色扩展 ×2） ──
const POISON_CLOUD_RADIUS := 300.0             # 毒云半径 px
const POISON_CLOUD_DURATION := 6.0             # 毒云持续 s
const POISON_CLOUD_TICK := 0.5                 # 结算节拍 s（域内敌每 0.5s 一跳）
const POISON_CLOUD_ATK_PCT := 0.08             # 每跳伤害 = 8% 主武器 ATK（毒伤，直结算）
const POISON_CLOUD_SLOW := 0.20                # 减速 20%（ext_slow 乘区 0.8）
const POISON_SLOW_REFRESH := 0.6               # 减速刷新窗 s（>结算节拍，防 120Hz 边界闪烁）
const SUMMON_COPIES := 2                      # 僚机数（= 复制武器数；用户口径「相当于临时复制俩武器」）
const SUMMON_DURATION := 10.0                  # 僚机持续 s


func _ready() -> void:
	# 组注册（敌/敌弹经组查找缓存玩家引用）+ 命中盒/拾取区/贴纸渲染组装（代码组装为主）
	add_to_group(&"player")
	_hit_shape = CollisionShape2D.new()
	_hit_shape.name = "HitShape"
	var hit_circle := CircleShape2D.new()
	hit_circle.radius = hitbox_radius
	_hit_shape.shape = hit_circle
	add_child(_hit_shape)
	_pickup_area = Area2D.new()
	_pickup_area.name = "PickupArea"
	_pickup_shape = CollisionShape2D.new()
	_pickup_shape.name = "PickupShape"
	var pickup_circle := CircleShape2D.new()
	pickup_circle.radius = pickup_radius
	_pickup_shape.shape = pickup_circle
	_pickup_area.add_child(_pickup_shape)
	add_child(_pickup_area)
	# 方向 C「哨兵-9」拦截机（用户试玩反馈 2026-08-29 重设计）：三角翼小机甲战机
	#（贴纸厚描边 + 座舱机器人驾驶员）+ 双引擎青蓝喷焰 + hover 待机浮动
	_visual_scale = hitbox_radius * VISUAL_MULT / SHIP_TEX_R
	_flame_l = Sprite2D.new()
	_flame_l.name = "FlameL"
	_flame_l.texture = TextureFactory.engine_flame()
	_flame_l.position = POD_L * _visual_scale
	_flame_l.visible = false
	add_child(_flame_l)
	_flame_r = Sprite2D.new()
	_flame_r.name = "FlameR"
	_flame_r.texture = TextureFactory.engine_flame()
	_flame_r.position = POD_R * _visual_scale
	_flame_r.visible = false
	add_child(_flame_r)
	# R25 武器悬浮层（用户点名「所有武器悬浮在主角身边，多武器动态绕主角排列」）
	orbit_avatars = WeaponOrbitAvatars.new()
	orbit_avatars.name = "WeaponOrbitAvatars"
	add_child(orbit_avatars)
	_sprite = Sprite2D.new()
	_sprite.name = "Visual"
	_sprite.centered = true
	_sprite.texture = TextureFactory.ship()
	_sprite.scale = Vector2(_visual_scale, _visual_scale)
	add_child(_sprite)
	_flash = Sprite2D.new()
	_flash.name = "Flash"
	_flash.texture = TextureFactory.ship(true)
	_flash.scale = Vector2(_visual_scale, _visual_scale)
	_flash.visible = false
	add_child(_flash)
	# 格挡力场环（MEC_SHIELD 就绪时显示；叠在机体上方，半透青蓝泡泡——挡住才「现形」的力场感）
	_shield_ring = Sprite2D.new()
	_shield_ring.name = "ShieldRing"
	_shield_ring.texture = TextureFactory.shield_bubble()
	_shield_ring.scale = Vector2.ONE * (_visual_scale * SHIELD_RING_R / 24.0)
	_shield_ring.visible = false
	add_child(_shield_ring)
	weapon_slots.resize(MAX_SLOTS)
	EventBus.slot_unlocked.connect(_on_slot_unlocked_event)
	var bal := GameConfig.balance
	if bal != null:
		# 初始 HP 真源 = cfg player_base_hp（60；张力调校值已回注真源，消除双轨）
		max_hp = GameConfig.get_constant(&"player_base_hp", 60.0)
		hp = max_hp
		pickup_radius = bal.pickup_radius
		xp_need = _xp_need_for(level)


func setup(p_deps: Dictionary) -> void:
	# 注入 pipeline/pools/grid/registry（包 3/4 接线；当前仅存档，武器实例由 equip 装载）
	_deps = p_deps


func tick(p_game_delta: float, p_move_delta: Vector2) -> void:
	# 相对拖动移动 + 边界钳制 + 无敌帧推进 + 武器自动开火调度
	if _dead:
		return
	if invuln_left > 0.0:
		invuln_left -= p_game_delta
		if invuln_left < 0.0:
			invuln_left = 0.0
	# 角色技能节拍（冷却 + 增益型剩余）
	if skill_cd_left > 0.0:
		skill_cd_left = maxf(skill_cd_left - p_game_delta, 0.0)
	if _skill_fx_left > 0.0:
		_skill_fx_left = maxf(_skill_fx_left - p_game_delta, 0.0)
		queue_redraw()                            # 光环呼吸/倒数弧重绘
	# 复活保护青弧倒数（E2 r2）：块内进入即刷（含归零当帧——归零后 _draw 守卫不再绘制，
	# 本帧重绘抹掉最后画面防整圈残影）；跨局清口见 clear_revive_protect
	if _revive_protect_left > 0.0:
		_revive_protect_left = maxf(_revive_protect_left - p_game_delta, 0.0)
		queue_redraw()
	if skill_active_left > 0.0:
		skill_active_left = maxf(skill_active_left - p_game_delta, 0.0)
		if skill_active_left <= 0.0:
			rof_mult = 1.0
			refresh_weapon_intervals()   # R29：过载到期登记新基准（节拍变长不回罚）
	# 毒云领域节拍（薇拉：剩余推进 + 0.5s 一跳域内结算/减速刷新）
	if _poison_cloud_left > 0.0:
		_poison_cloud_left = maxf(_poison_cloud_left - p_game_delta, 0.0)
		_poison_cloud_tick_left -= p_game_delta
		if _poison_cloud_tick_left <= 0.0:
			_poison_cloud_tick_left += POISON_CLOUD_TICK
			_poison_cloud_pulse()
			EventBus.emit_poison_cloud_tick(global_position, POISON_CLOUD_RADIUS)   # R10 毒圈持续表现
	# 僚机到期还原（诺亚：复制武器回收 + 护航舰离场）
	if _summon_left > 0.0:
		_summon_left = maxf(_summon_left - p_game_delta, 0.0)
		if _summon_left <= 0.0:
			_summon_restore()
	# 格挡力场充能（MEC_SHIELD：非就绪期走表，充满置位；未持有词条时 interval=0 短路）
	if shield_interval > 0.0 and not shield_ready:
		shield_timer = maxf(shield_timer - p_game_delta, 0.0)
		if shield_timer <= 0.0:
			shield_ready = true
	var total := p_move_delta
	if total == Vector2.ZERO:
		total = _drag_accum if input_enabled else Vector2.ZERO   # 宽限期吞掉自采样拖动（防误触）
	_drag_accum = Vector2.ZERO
	if total != Vector2.ZERO:
		_last_move_dir = total.normalized()
	# 冰锁圈外部减速（R18 P2 frost flavor：拖动映射 ×mult，到期还原——Boss 文档 §5.2）
	if hazard_slow_left > 0.0:
		hazard_slow_left = maxf(hazard_slow_left - p_game_delta, 0.0)
		if hazard_slow_left <= 0.0:
			hazard_slow_mult = 1.0
		total *= hazard_slow_mult
	global_position += total
	_clamp_to_playfield()
	# 武器自动开火调度（每帧 tick；集成包 B.8 第二批收紧：weapon_slots 已收窄 WeaponBase——直调）
	for weapon in weapon_slots:
		if weapon != null:
			weapon.tick(p_game_delta)
	# R183 僚机复制武器同拍驱动（副本不在 weapon_slots——独立数组，到期回收）
	for copy in _summon_copies:
		if copy != null:
			copy.tick(p_game_delta)
	# R187 W5 镜面军团同拍驱动（永久会话态——无 10s 到期，只在回收口/重开清空；
	# 镜面实体按鸭子协议驱动——WeaponBase 子类或自备 tick() 的 Node2D 均可）
	for mirror in _mirror_images:
		if mirror != null and is_instance_valid(mirror) and mirror.has_method(&"tick"):
			mirror.call(&"tick", p_game_delta)
	_tick_visual(p_game_delta, total)


func _unhandled_input(p_event: InputEvent) -> void:
	# 输入抽象：相对拖动采样（Q-3；E-15 单指针锁定由 GameLoop 输入层承担，本层累计拖动向量）
	if p_event is InputEventScreenDrag:
		_drag_accum += (p_event as InputEventScreenDrag).relative
	elif p_event is InputEventMouseMotion:
		var mm := p_event as InputEventMouseMotion
		if (mm.button_mask & MOUSE_BUTTON_LEFT) != 0:
			_drag_accum += mm.relative


func _draw() -> void:
	# R19 技能演出光环（效果持续可视化——「不知道效果何时结束」终解）：
	# 金色呼吸外环 + 剩余时长倒数弧（12 点方向顺时针收拢，归零即效果结束）
	if _skill_fx_left > 0.0 and _skill_fx_max > 0.0:
		var ratio := clampf(_skill_fx_left / _skill_fx_max, 0.0, 1.0)
		var pulse := 0.5 + 0.5 * sin(_skill_fx_left * 9.0)
		draw_circle(Vector2.ZERO, 36.0, Color(1.0, 0.85, 0.3, 0.05 + 0.05 * pulse))
		draw_arc(Vector2.ZERO, 36.0, 0.0, TAU, 44, Color(1.0, 0.85, 0.3, 0.28), 2.0, true)
		draw_arc(Vector2.ZERO, 36.0, -PI * 0.5, -PI * 0.5 + TAU * ratio, 44,
			Color(1.0, 0.9, 0.45, 0.95), 4.0, true)
	# E2 r2 复活保护青弧（独立字段生命周期：_try_revive 置位 → tick 衰减 → respawn/
	# _restore 显式清零；全部绘制含淡底环置于 left>0 守卫内——不画恒显底环，归零当帧
	# 重绘即整弧消失、跨局不残留）。半径 42px 与金弧 36px 错开（复活+技能同屏可读）
	if _revive_protect_left > 0.0 and _revive_protect_max > 0.0:
		var rv_ratio := clampf(_revive_protect_left / _revive_protect_max, 0.0, 1.0)
		draw_circle(Vector2.ZERO, 42.0, Color(0.45, 0.95, 1.0, 0.06))
		draw_arc(Vector2.ZERO, 42.0, 0.0, TAU, 44, Color(0.45, 0.95, 1.0, 0.24), 2.0, true)
		draw_arc(Vector2.ZERO, 42.0, -PI * 0.5, -PI * 0.5 + TAU * rv_ratio, 44,
			Color(0.45, 0.95, 1.0, 0.95), 4.0, true)


func take_contact_damage(p_dmg: float) -> void:
	# ★ 简化路径（Q-16）：无敌帧判定 → 格挡力场 → 直接扣 HP → player_hit 事件（不入 M-12）
	if _dead or invuln_left > 0.0:
		return
	# 格挡力场优先（A3 §4.4 MEC_SHIELD：就绪的护盾吞掉这次接触伤害并进入再充能）
	if shield_ready:
		shield_ready = false
		shield_timer = shield_interval
		_shield_pulse_left = SHIELD_PULSE_TIME
		invuln_left = GameConfig.balance.contact_tick if GameConfig.balance != null else 0.6
		EventBus.emit_shield_blocked(global_position)
		return
	var dmg := maxf(p_dmg, 0.0)
	hp -= dmg
	invuln_left = GameConfig.balance.contact_tick if GameConfig.balance != null else 0.6
	_flash_left = FLASH_TIME                     # 方向 C：受击变白弹回
	_punch_left = PUNCH_TIME
	EventBus.emit_player_hit(dmg, 0)
	if hp <= 0.0:
		if _try_revive():
			return                             # 复活成功：满血 + 无敌，不掉死亡仲裁
		hp = 0.0
		_on_died()


func apply_max_hp_up(p_amount: float) -> void:
	# AFF_HP_UP 消费点（A3 §4.2：max_hp +25/层，可叠 4 层）：上限增量与当前血等量回补
	#（主控裁定 2026-08-29——买血条即时爽感）；负值（诅咒对称口径）双向钳制不越界。
	max_hp += p_amount
	hp = minf(hp + p_amount, max_hp)


func apply_shield_trait(p_layers: int, p_params: Dictionary, p_charge_mult: float = 1.0) -> void:
	# MEC_SHIELD 消费点（A3 §4.4）：每 interval_s 生成护盾格挡 1 次接触伤害；
	# 2 层 → interval_lv2(5.5s)。重复挂载/层变化即刷新间隔；首个护盾需走完一次充能。
	# R69 品质梯分化：p_charge_mult = 词条 value（白 1.0 → 蓝/紫/金 1.4/1.9/2.6），
	# 充能间隔 = 基准 / 倍率（8s → 5.7/4.2/3.1s）——旧实现 value 死数字、四品质同速
	var base: float = float(p_params.get(
		"interval_lv2", p_params.get("interval_s", 8.0))) if p_layers >= 2 \
		else float(p_params.get("interval_s", 8.0))
	shield_interval = maxf(base / maxf(p_charge_mult, 0.05), 0.5)
	if not shield_ready and shield_timer <= 0.0:
		shield_timer = shield_interval


func equip_weapon(p_weapon: WeaponBase) -> bool:
	# 装入武器实例（集成包 B.8 第二批收紧：签名收窄 WeaponBase——pkg2 用例已迁移真件武器）
	if p_weapon == null:
		return false
	for i in range(weapon_slots.size()):
		if weapon_slots[i] == null:
			if i >= unlocked_slots:
				return false                 # 槽未解锁
			weapon_slots[i] = p_weapon
			if p_weapon.get_parent() == null:
				add_child(p_weapon)
			return true
	return false                             # 无空槽


func add_weapon(p_data: WeaponData) -> WeaponBase:
	# 形态工厂（架构 §2.12）：槽位检查 → 实例化（按 form 分派）→ setup → 装槽挂载。
	# 无可用槽 / 未知形态 → 返回 null（不实例化，调用方按 null 降级）。
	if p_data == null:
		return null
	var slot := _first_available_slot()
	if slot < 0:
		return null                          # 无空槽（或槽未解锁）
	var weapon := _instantiate_weapon(p_data)
	if weapon == null:
		return null
	weapon.setup(p_data, self, _deps)        # 注入包：pipeline/pools/grid/laser_pool/elemental
	weapon.meta_atk_pct = Meta.atk_pct() + character_atk_pct   # 局外养成 + 角色修正（M8/角色系统）
	weapon_slots[slot] = weapon
	if weapon.get_parent() == null:
		add_child(weapon)
	# G8 新武器首获横幅：图鉴首遇同源（Meta 持久标记，一次不打扰）
	var note := GameConst.weapon_note(String(p_data.id))
	if not note.is_empty() and Meta.mark_first_met(StringName("W_" + String(p_data.id))):
		EventBus.emit_mechanics_intro("【新武器】%s：%s" % [p_data.display_name, note])
	return weapon


# ── 内部 ──────────────────────────────────────────────────────────
func _first_available_slot() -> int:
	# 首个已解锁空槽索引（无 → -1；与 equip_weapon 遍历口径一致）
	for i in range(weapon_slots.size()):
		if weapon_slots[i] == null:
			if i >= unlocked_slots:
				return -1                    # 槽未解锁（槽序即解锁序）
			return i
	return -1


func _instantiate_weapon(p_data: WeaponData) -> WeaponBase:
	# 形态分派（WeaponForm：BALLISTIC/LASER/HOMING/MELEE → 对应武器子类）
	# R187 W5 万镜回廊：棱镜本体 = MirrorWeapon（镜面军团编排层，继承 LaserWeapon
	# 锚束通道；生产接线——仲裁 dwfq-a3b78ef6-1 批准，棱镜组补线 1 行）
	match p_data.form:
		GameConst.WeaponForm.BALLISTIC:
			return BallisticWeapon.new()
		GameConst.WeaponForm.LASER:
			return MirrorWeapon.new() if String(p_data.id) == "W5_prism" \
				else LaserWeapon.new()
		GameConst.WeaponForm.HOMING:
			return HomingWeapon.new()
		GameConst.WeaponForm.MELEE:
			return OrbitWeapon.new()
	return null                              # 未知形态（WeaponData 校验已封 {0,1,2,3}）


func slot_cap_total() -> int:
	# R185 有效槽位帽 = 难度帽（5/6/6）；金卡只提前解锁帽内槽位、不再 +1 扩容
	#（用户口径「本来5个位置2解锁3锁，+1后应3解锁2锁」——总位数恒定）
	return mini(GameConst.difficulty_slot_cap(_difficulty), MAX_SLOTS)


func unlock_slot(p_slot: int) -> bool:
	# 槽位解锁（幂等；事件由 WaveDirector/集成侧派发；R185 金卡同走 slot_unlocked 事件）。
	# R183：波浪里程碑解锁被难度帽截断（普通帽 5——里程碑链最高到 6 由难度决定）
	if p_slot > unlocked_slots and p_slot <= slot_cap_total():
		unlocked_slots = p_slot
		return true
	return false


func grant_slot_bonus() -> bool:
	# R88 金卡「武器槽+1」→ R185 语义：提前解锁帽内下一槽（不越帽）；
	# 帽内已满 = 无槽可解，拒绝（卡池侧 <slot_cap_total 门同步断供）
	if unlocked_slots >= slot_cap_total():
		return false
	EventBus.emit_mechanics_intro("✦ 武器槽 %d 解锁（金卡）" % (unlocked_slots + 1))
	unlocked_slots += 1
	slot_bonus += 1                              # 统计口径：本局金卡解锁数（不参与帽）
	return true


func set_character(p_id: StringName) -> void:
	# 应用角色（大厅选人 → GameLoop.start_run/respawn 调用；含局外养成加成——M8）
	# 解锁守卫：未通关解锁链的角色回落哨兵（存档迁移/异常输入防御）
	if not Meta.is_character_unlocked(p_id):
		p_id = &"sentinel"
	character_id = p_id
	var def := CharacterTable.get_character(p_id)
	max_hp = float(def.get("hp", 60.0)) + Meta.hp_bonus()
	hp = max_hp
	pickup_radius = 120.0 * (1.0 + Meta.magnet_pct())
	gold = 30 + Meta.start_gold()                # 开局资金（养成·初始资金，M8 二期）
	reroll_charges = 2 + Meta.reroll_bonus()     # 刷新次数（基础 2 + 养成·预案推演，选卡刷新机制）
	revives_left = Meta.revive_charges()         # 应急协议（每局重置）
	character_atk_pct = float(def.get("atk_pct", 0.0))
	apply_character_visual()
	comp_rof_mult = 1.0                          # CDR 折算乘区随角色复位（无技能角色由 refresh_skill_cd 立即重算）
	refresh_skill_cd()
	skill_cd_left = 0.0
	rof_mult = 1.0
	refresh_pickup_radius()
	_reset_skill_temp_state()                    # 换角色即时清临时态（毒云/僚机还原）
	# 攻击修正动态注入（真修：武器面板若只在实例化期定格，大厅买养成/选角后开局不生效）
	for w in weapon_slots:
		if is_instance_valid(w) and w is WeaponBase:   # freed 实例上评估 is 会报脚本错——判序 valid 在前
			(w as WeaponBase).meta_atk_pct = Meta.atk_pct() + character_atk_pct
			(w as WeaponBase).call(&"_invalidate_panel")


func apply_character_visual() -> void:
	# 舰体随角色着色（R13 用户反馈「选了新角色战斗中还是默认飞船」）——
	# 贴图共享、modulate 区分（低成本角色辨识）；受击闪白走 _apply_flash 临时覆盖不冲突
	var tints := {
		&"sentinel": Color(1.0, 1.0, 1.0), &"veles": Color(1.0, 0.72, 0.72),
		&"bulwark": Color(0.72, 0.84, 1.0), &"ranger": Color(0.66, 1.0, 0.92),
		&"zero": Color(0.85, 0.72, 1.0), &"mank": Color(0.66, 1.0, 0.55),
		&"vera": Color(0.72, 1.0, 0.72), &"noah": Color(1.0, 0.93, 0.62),
		&"fission": Color(0.75, 0.82, 0.95), &"echo": Color(0.94, 0.62, 1.0),
	}
	var tint: Color = tints.get(character_id, Color.WHITE)
	if _sprite != null:
		_sprite.modulate = tint
	if _flash != null and float(_flash.modulate.a) <= 0.0:
		_flash.modulate = tint


func _weapon_pool_sum(p_pool: StringName) -> float:
	# 跨武器聚合某 ADD 池合计（玩家侧词条的消费口：AFF_PICKUP 磁吸 / AFF_SKILL_HASTE 技能急速）
	var total := 0.0
	for w in weapon_slots:
		if w == null or not is_instance_valid(w):
			continue
		var stack: Variant = w.get("trait_stack")
		if stack == null:
			continue
		var agg: Dictionary = stack.call(&"aggregate_panel")
		total += float(agg.get(p_pool, 0.0))
	return total


func refresh_pickup_radius() -> void:
	# 磁吸半径 = 基准 ×(1 + 养成磁吸 + AFF_PICKUP 词条池)（2026-09-13 死卡接线；挂卡后重算）
	var bal := GameConfig.balance
	var base := bal.pickup_radius if bal != null else 120.0
	pickup_radius = base * (1.0 + Meta.magnet_pct()
		+ clampf(_weapon_pool_sum(&"add_pickup"), 0.0, 2.0))
	if _pickup_shape != null and _pickup_shape.shape is CircleShape2D:
		(_pickup_shape.shape as CircleShape2D).radius = pickup_radius   # 磁吸判定圈同步


func skill_haste_pct() -> float:
	# 技能急速最终加成（构筑详情展示口，R70 用户反馈「详情没写最终加成多少」）：
	# 跨武器 add_skillcdr 池合计，与 refresh_skill_cd 消费同 clamp（上限 -60%）
	return clampf(_weapon_pool_sum(&"add_skillcdr"), 0.0, 0.6)


func refresh_skill_cd() -> void:
	# 技能冷却基线 = 角色 cd ×(1 − 养成CDR) ×(1 − 技能急速池)
	#（AFF_SKILL_HASTE 2026-09-13 重做接线；挂卡后由 GameLoop 触发重算）
	# R29 迟到减CD（用户反馈）：技能急速到手时**已在倒计时**的技能CD按新旧基线比例
	# 立刻缩短——不再等本次冷却自然走完；基线变长不回罚（同武器侧口径）。
	var base := float(CharacterTable.get_character(character_id).get("cd", 120.0))
	var new_base := base * (1.0 - Meta.skill_cdr_pct()) \
		* (1.0 - clampf(_weapon_pool_sum(&"add_skillcdr"), 0.0, 0.6)) * skill_cd_relic_mult
	if skill_cd_base > 0.0 and new_base > 0.0 and skill_cd_left > 0.0 \
			and new_base < skill_cd_base and not is_equal_approx(new_base, skill_cd_base):
		skill_cd_left = clampf(skill_cd_left * new_base / skill_cd_base, 0.0, new_base)
	skill_cd_base = new_base
	# 无技能角色（改造者·枢）CDR 折算：养成CDR / 技能急速池 / 时之沙无法作用于不存在的
	# 技能——按 0.5 折算率转成全武器射速乘区（封顶 +30%）；有技能角色恒 1.0（不与过载/
	# 双生回响等技能射速窗双通道叠算）。折算变化即时刷新武器节拍（R29 先例 :486）
	var comp := 1.0 if has_skill() \
		else 1.0 + minf((1.0 - new_base / maxf(base, 0.01)) * 0.5, 0.30)
	if not is_equal_approx(comp, comp_rof_mult):
		comp_rof_mult = comp
		refresh_weapon_intervals()


func refresh_weapon_intervals() -> void:
	# R29 迟到减CD：角色侧射速增益变化（过载咆哮启停 / 地图祝福·狂热）时同步全部
	# 武器节拍——增益开启的瞬间武器已在倒计时的冷却立刻按比例缩短（立刻见效）
	for w in weapon_slots:
		if w != null and is_instance_valid(w) and w is WeaponBase:
			(w as WeaponBase).refresh_fire_interval()
	for copy in _summon_copies:               # R183 副本同口径（持续期内增益启停同样即时见效）
		if copy != null and is_instance_valid(copy):
			copy.refresh_fire_interval()
	for mirror in _mirror_images:             # R187 W5 攻速传导：AFF_ROF_UP/AFF_CDR 挂棱镜即全体镜面生效
		if mirror != null and is_instance_valid(mirror) and mirror.has_method(&"refresh_fire_interval"):
			mirror.call(&"refresh_fire_interval")


func _skill_time_stop() -> void:
	# 时滞力场（演算者·零·终极控场）：全场敌人静止 2.5s——直写 freeze_timer
	#（角色终极无视免疫位；仅定身，不清血——数值零副作用）
	var grid: Variant = _deps.get("enemy_grid")
	if grid == null:
		return
	for e in (grid as SpaceGrid).query_circle(global_position, 4096.0):
		if e == null or bool(e.get("dead")):
			continue
		var st: Variant = e.get("elemental")
		if st is ElementalState:
			(st as ElementalState).freeze_timer = 2.5   # 冻结计时器在元素状态容器（真修）
	DebugStats.count(&"time_stop")


func _skill_poison_nova() -> void:
	# 毒沼绽放（腐化者·莽·终极毒核）：全屏敌人结算 150% 主武器攻击（AOE_SECONDARY 通道）
	var grid: Variant = _deps.get("enemy_grid")
	var pipeline: Variant = _deps.get("pipeline")
	var w0: Variant = weapon_slots[0] if weapon_slots.size() > 0 else null
	if grid == null or w0 == null:
		return
	var base := float((w0 as WeaponBase).build_panel_snapshot().get("base_atk", 0.0)) * 1.5
	var settled := 0
	for e in (grid as SpaceGrid).query_circle(global_position, 4096.0):
		if e == null or bool(e.get("dead")):
			continue
		var ctx := DamageContext.make()
		ctx.source_uid = int(get_instance_id())   # 玩家侧 nova 幂等键（Player 无 uid 字段）
		ctx.target = e
		ctx.target_uid = int(e.get("uid"))
		ctx.frame_stamp = GameConfig.frame_stamp
		ctx.base_atk = base
		ctx.element = GameConst.Element.FIR
		ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
		ctx.crit_chance = 0.0
		ctx.pos = (e as Node2D).global_position
		if pipeline != null and (pipeline as Object).has_method(&"resolve"):
			pipeline.call(&"resolve", ctx)
			settled += 1
	if settled > 0:
		DebugStats.count(&"poison_nova")


func weapon_muzzle_global(p_weapon: WeaponBase) -> Vector2:
	# R25 发射口对齐（用户点名「发射口和对应武器对不上」禁令）：子弹出膛点 =
	# 该武器悬浮化身的当前位置；化身不可用 → 回退武器本体位（玩家中心）
	if orbit_avatars != null and is_instance_valid(orbit_avatars):
		var pos: Variant = orbit_avatars.avatar_global(p_weapon)
		if pos != null:
			var size := Vector2(720.0, 1280.0)
			if GameConfig.balance != null:
				size = Vector2(GameConfig.balance.res_logic)
			return (pos as Vector2).clamp(Vector2.ONE * 12.0, size - Vector2.ONE * 12.0)
	return p_weapon.global_position


func _clamp_to_playfield_pos(p_pos: Vector2) -> Vector2:
	var size: Vector2 = Vector2(720.0, 1280.0)
	if GameConfig.balance != null:
		size = Vector2(GameConfig.balance.res_logic)
	return Vector2(clampf(p_pos.x, 24.0, size.x - 24.0), clampf(p_pos.y, 24.0, size.y - 24.0))


func has_skill() -> bool:
	# 玩家侧「有无主动技能」读口（HUD 技能键置灰 / activate_skill 早退共用）：
	# 真源 = CharacterTable 条目 no_skill 键（无技能角色如改造者·枢置 true——
	# 8 旧角色无此键 → 恒 true，零回归）。CharacterTable 若落地 static has_skill
	# 则同源同语义，两读口不冲突
	return not bool(CharacterTable.get_character(character_id).get("no_skill", false))


func skill_ready() -> bool:
	return skill_cd_left <= 0.0 and not _dead


func _reset_skill_temp_state() -> void:
	# 技能临时态收口（换角色/重开共用）：毒云清零 + 僚机到期还原（武器可能已被重开清场
	# 回收——_summon_restore 内有 is_instance_valid 守卫）。
	# ★R187 刻意不含镜面：_mirror_images 是永久会话态（验收 2 反向断言——本函数执行后
	# _summon_copies 空而 _mirror_images 原样）；镜面回收只在 clear_mirrors（重开/换局）。
	_poison_cloud_left = 0.0
	_poison_cloud_tick_left = 0.0
	_summon_restore()


func activate_skill() -> bool:
	# 角色主动技能（HUD 技能键调用；冷却中 false）
	if not skill_ready():
		return false
	if not has_skill():
		return false               # 无技能角色（改造者·枢契约）：不置 CD、不发 skill_cast、不计数
	skill_cd_left = skill_cd_base
	match character_id:
		&"sentinel":
			invuln_left = maxf(invuln_left, 3.0)
			_skill_shield_left = 3.0
		&"veles":
			rof_mult = 2.0
			skill_active_left = 4.0
			refresh_weapon_intervals()   # R29：过载开启瞬间武器倒计时立刻按新节拍缩短
		&"bulwark":
			_skill_stomp()
		&"ranger":
			var dir := _last_move_dir if _last_move_dir != Vector2.ZERO else Vector2.UP
			global_position = _clamp_to_playfield_pos(global_position + dir * 260.0)
			invuln_left = maxf(invuln_left, 1.0)
		&"zero":
			_skill_time_stop()
		&"mank":
			_skill_poison_nova()
		&"vera":
			_skill_poison_cloud()
		&"noah":
			_skill_summon_orbs()
		&"echo":
			rof_mult = 1.5                        # 双生回响：5s 全武器射速 +50%（复用 veles 射速窗通道）
			skill_active_left = 5.0
			refresh_weapon_intervals()            # 开启瞬间武器倒计时立刻按新节拍缩短（R29 同款）
	var fx_dur := _skill_fx_duration()
	_skill_fx_left = fx_dur
	_skill_fx_max = fx_dur
	EventBus.emit_skill_cast(global_position, String(character_id))   # 施放金环爆发（表现层）
	DebugStats.count(&"skill_used")
	return true


func _skill_fx_duration() -> float:
	# 技能演出时长（R19：增益型 = 效果持续时间，瞬发型 = 0.8s 施放闪光——
	# 「效果何时结束」一眼可读：HUD 时长条 + 玩家光环同步倒数）
	match character_id:
		&"sentinel":
			return 3.0
		&"veles":
			return 4.0
		&"vera":
			return POISON_CLOUD_DURATION
		&"noah":
			return SUMMON_DURATION
		&"echo":
			return 5.0                            # 双生回响增益窗（HUD 时长条 + 金弧同步倒数）
	return 0.8


func skill_active_ratio() -> float:
	# 技能效果剩余比例 0~1（HUD 时长条消费；瞬发型 0.8s 施放闪光共用通道）
	if _skill_fx_max <= 0.0:
		return 0.0
	return clampf(_skill_fx_left / _skill_fx_max, 0.0, 1.0)


func _skill_poison_cloud() -> void:
	# 毒云领域（毒系学者·薇拉）：以玩家为中心 300px 持续 6s，域内敌每 0.5s 受 8% 主武器
	# ATK 毒伤 + 减速 20%。★ 直结算通道（方案裁定，注释真源）：每跳独立 DamageContext 走
	# 管线 resolve（AOE_SECONDARY 幂等键——同构 mank 毒沼绽放先例），不挂 ElementalState
	# 附着（不动元素管线）；减速走 Enemy.ext_slow 外部乘区（与元素冰缓正交、到期自动还原）。
	_poison_cloud_left = POISON_CLOUD_DURATION
	EventBus.emit_poison_cloud_cast(global_position, POISON_CLOUD_RADIUS)   # R10 毒云特效
	_poison_cloud_tick_left = 0.0               # 首跳即刻生效（挂场即有反馈）
	_poison_cloud_pulse()


func _poison_cloud_pulse() -> void:
	# 毒云单跳：网格圆查询 → 刷新减速窗 + 逐敌结算毒伤（域外敌由 ext_slow_left 到期自愈）
	var grid: Variant = _deps.get("enemy_grid")
	var pipeline: Variant = _deps.get("pipeline")
	var w0: Variant = weapon_slots[0] if weapon_slots.size() > 0 else null
	if grid == null:
		return
	var base := 0.0
	if is_instance_valid(w0) and w0 is WeaponBase:
		base = float((w0 as WeaponBase).build_panel_snapshot().get("base_atk", 0.0))
	for e in (grid as SpaceGrid).query_circle(global_position, POISON_CLOUD_RADIUS):
		if e == null or bool(e.get("dead")):
			continue
		e.set("ext_slow_mult", 1.0 - POISON_CLOUD_SLOW)
		e.set("ext_slow_left", POISON_SLOW_REFRESH)
		if base <= 0.0 or pipeline == null or not (pipeline as Object).has_method(&"resolve"):
			continue
		var ctx := DamageContext.make()
		ctx.source_uid = int(get_instance_id())  # 玩家侧幂等键（Player 无 uid 字段——mank 同口径）
		ctx.target = e
		ctx.target_uid = int(e.get("uid"))
		ctx.frame_stamp = GameConfig.frame_stamp
		ctx.base_atk = base * POISON_CLOUD_ATK_PCT
		ctx.element = GameConst.Element.FIR      # 毒伤元素口径沿 mank 毒沼绽放先例（FIR 通道）
		ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
		ctx.crit_chance = 0.0                    # 领域 DoT 不暴击（稳定期望口径）
		ctx.pos = (e as Node2D).global_position
		pipeline.call(&"resolve", ctx)
	DebugStats.count(&"poison_cloud_pulse")


func _skill_summon_orbs() -> void:
	# 召唤僚机（召唤师·诺亚，R183 用户重定义）：随机复制 2 把当前已装备武器——
	# 同数据/同等级/词条栈全量拷贝（含逐层品级数值与质变乘区），持续 10s；
	# 相当于临时多出两把武器在打（用户原话口径）。无武器可复制（异常防御）→
	# 仅 R93 护航舰随行。副本不占真实槽位（_summon_copies 独立数组——
	# 选卡目标/存档序列化/词条叠层判据均不受污染），悬浮环金色染色参战。
	_spawn_fallback_drones()
	var pool: Array[WeaponBase] = []
	for w in weapon_slots:
		# R187 R183 互斥裁定：复制池排除 W5_prism——「临时件永不产出永久件」
		#（镜面在 _mirror_images 独立数组，本就不可复制；双保险防未来槽位化回潮）
		if w != null and is_instance_valid(w) and w.data != null \
				and String(w.data.id) != "W5_prism":
			pool.append(w)
	if pool.is_empty():
		_summon_left = SUMMON_DURATION         # 仅护航舰（正常局恒有手枪，防御路径）
		DebugStats.count(&"summon_drones_fallback")
		return
	for i in range(SUMMON_COPIES):
		var copy := _make_weapon_copy(pool[randi() % pool.size()])
		if copy != null:
			_summon_copies.append(copy)
	_summon_left = SUMMON_DURATION
	DebugStats.count(&"summon_orbs")
	# R183 复制播报（评审：弹幕里读不出「金了哪两个」）：施放即横幅点名复制的武器
	if not _summon_copies.is_empty():
		var names: Array[String] = []
		for c in _summon_copies:
			if c != null and c.data != null:
				names.append(String(c.data.display_name))
		if names.size() == 2 and names[0] == names[1]:
			EventBus.emit_mechanics_intro("召唤僚机：复制了 %s ×2" % names[0])
		elif not names.is_empty():
			EventBus.emit_mechanics_intro("召唤僚机：复制了 %s" % " + ".join(names))


func _make_weapon_copy(p_src: WeaponBase) -> WeaponBase:
	# 武器副本构造（R183）：同 WeaponData / 同等级 / 同局外养成修正；词条栈走
	# copy_full（比 copy_runtime 多拷逐层品级数值——R12c 混合品级 ADD 池不回落基准值）。
	# R187 复制体折减裁定表（R187 设计文档 §一「R183 区分总裁定」统一表，逐武器落点）：
	# · W1 手枪：同 lane 几何参数（copy_full 同数据默认成立）+ 独立弹幕态计时器
	#   （武器侧读 is_summon_copy 分桶计时）+ 金色染色
	# · W4 激光：副本 sub_beams 强制 0——只出主束 + 灰染
	# · W6 微导：副本 volley_eff=1（齐射折减单发）
	# · W7 集束：副本 sub_eff=min(sub,3)（集束子弹折减）
	# · W8 环绕：蓄能池以目标 uid 全局单例（enemy.charge_stacks——复制体只加速蓄能、
	#   永不复制引爆当量，本侧零折减字段）+ BASE 单环阵 + 相位偏移 45°（化身层读）
	# 折减字段统一鸭子协议 set()（武器组未落地字段静默无操作——跨组接线零冲突）
	var copy := _instantiate_weapon(p_src.data)
	if copy == null:
		return null
	copy.setup(p_src.data, self, _deps)
	copy.level = p_src.level
	copy.meta_atk_pct = p_src.meta_atk_pct
	if p_src.trait_stack != null:
		copy.trait_stack = p_src.trait_stack.copy_full()
		# ELE 反应强化副本重注册（attach_trait 副作用不随栈拷贝——按 uid 独立注册；
		# R187 对照：W5 镜面走 make_mirror_image 单源口径，不在此注册）
		var sys: Variant = _deps.get("elemental")
		if sys is ElementalSystem:
			for mounted in copy.trait_stack.traits:
				if mounted.data != null and mounted.data.pool == GameConst.PoolClass.ELEM \
						and mounted.data.params.has("reaction_mult"):
					(sys as ElementalSystem).register_reaction_mult(copy.uid,
						maxf(float(mounted.data.value),
							float(mounted.data.params.get("reaction_mult", 1.8))))
	_apply_copy_ruling(copy, String(p_src.data.id))
	add_child(copy)
	return copy


func _apply_copy_ruling(p_copy: WeaponBase, p_src_id: String) -> void:
	# R183 复制体折减裁定表（R187 设计文档 §一「R183 区分总裁定」统一表）——
	# 与各组已落地消费口对齐：
	# · W4 激光：sub_beams_override=0（LaserWeapon 已落地类型化字段——复制体只出主束）
	#   + copy_tint=true（束色灰染 flag）
	# · W6/W7 自导：HomingWeapon 自检 _summon_copies 数组内部折减（volley_eff=1 /
	#   sub_eff=min(sub,3)），本侧零字段——副本身份由数组权威判定
	# · W8 环绕：蓄能池目标 uid 单例（enemy.charge_stacks 敌侧通道——复制体只加速
	#   蓄能、引爆当量不复制），BASE 阵/相位偏移由 W8 组读副本身份自处理
	# · W1 手枪：同 lane 参数（copy_full 同数据默认成立）+ 独立弹幕态计时（武器侧
	#   自检）；染色统一在化身层（weapon_orbit_avatars 按 src id 染——金/灰/钢蓝/橙红）
	if p_src_id == "W4_pulse_beam":
		p_copy.set("sub_beams_override", 0)      # 复制体只出主束（验收：并发束==1）
		p_copy.set("copy_tint", true)            # 灰染 flag（LaserWeapon 类型化 bool）（W8 等）


# ── R187 W5 万镜回廊：镜面军团共享侧容器/API（实体类归棱镜组） ──────────
func make_mirror_image(p_source: WeaponBase, p_prism: WeaponBase) -> WeaponBase:
	# 镜面构造（白板语义硬约束）：数据/等级/养成修正 = 源武器（沿用其出厂面板开火）、
	# 词条栈 = 棱镜自身栈 copy_full（拷贝源=棱镜——源武器词条零拷贝，「一张棱镜卡
	# =N 镜生效」）。★ELE 单源裁定：镜面只继承元素色、不注册反应乘区（对照 R183
	# 逐副本注册先例——永久件逐镜注册=×4.7^N 雪球，验收 4「注册源数==1」锁死）。
	# 返回未挂树的镜面实例（入场/重掷编排归棱镜组；玩家侧只供容器与驱动）。
	if p_source == null or not is_instance_valid(p_source) or p_source.data == null:
		return null
	var mirror := _instantiate_weapon(p_source.data)
	if mirror == null:
		return null
	mirror.setup(p_source.data, self, _deps)
	mirror.level = p_source.level
	mirror.meta_atk_pct = p_source.meta_atk_pct
	if p_prism != null and is_instance_valid(p_prism) and p_prism.trait_stack != null:
		mirror.trait_stack = p_prism.trait_stack.copy_full()   # 白板：拷贝源=棱镜自身栈
	# 镜面标记（鸭子协议——镜面实体侧字段缺失时静默无操作）：
	mirror.set("is_mirror_image", true)
	mirror.set("mirror_source_id", p_source.data.id)
	mirror.set("copy_tint", Color(0.82, 0.92, 1.0))   # 银白/冰青（禁金色调性——读感区分裁定）
	return mirror


func register_mirror(p_mirror: WeaponBase, p_cap: int = 5) -> bool:
	# 镜面入册（棱镜组入场调用）：绝对帽 5（等级 3 + MEC_MIRROR_SPLIT 2）——
	# 超帽拒绝 + mirror_rejected 计数（验收「再挂钳制在 5」）。
	if p_mirror == null or not is_instance_valid(p_mirror):
		return false
	if _mirror_images.size() >= maxi(p_cap, 0):
		DebugStats.count(&"mirror_rejected")
		return false
	_mirror_images.append(p_mirror)
	if p_mirror.get_parent() == null:
		add_child(p_mirror)
	return true


func mirror_count() -> int:
	# 在场镜数（HUD 镜面 ×N 角标数据源 + 验收断言口）
	return _mirror_images.size()


func mirror_capacity(p_prism: WeaponBase) -> int:
	# 镜数容量 = W5 laser 段 mirrors_count_levels 等级值 + MEC_MIRROR_SPLIT 词条层数，
	# 钳 [0,5]（绝对帽；prism_pointer/指向重掷消费同源）
	if p_prism == null or not is_instance_valid(p_prism) or p_prism.data == null:
		return 0
	var seg_v: Variant = p_prism.data.get("laser")
	if not (seg_v is Dictionary):
		return 0
	var seg: Dictionary = seg_v
	var base := 0
	var levels: Variant = seg.get("mirrors_count_levels", null)
	if levels is Array and not (levels as Array).is_empty():
		var idx := clampi(int(p_prism.get("level")) - 1, 0, (levels as Array).size() - 1)
		base = int((levels as Array)[idx])
	# MEC_MIRROR_SPLIT 层数直读挂载表（计数键口径：不走 add 池、豁免质变 ×1.6）；
	# §2.2.3 品质梯 value 取整 × 层数（白 +1/层 / 蓝 +2/层——卡面口径与消费端一致）
	var tstack: Variant = p_prism.get("trait_stack")
	if tstack != null and tstack.get("traits") != null:
		for tb: Variant in (tstack.get("traits") as Array):
			var td: Variant = tb.get("data")
			if td != null and StringName(str(td.get("id"))) == &"MEC_MIRROR_SPLIT":
				var tv: Variant = td.get("value")
				var per_layer := maxi(int(round(float(tv if tv != null else 1.0))), 1)
				base += per_layer * int(tb.get("layers"))
	return clampi(base, 0, 5)


func set_mirror_locked(p_locked: bool) -> void:
	# MEC_MIRROR_LOCK 挂/卸卡回调（MECH 词条消费口）：锁定后波首/读档不重掷指向
	_mirror_locked = p_locked


func deterministic_source_pick(p_mirror_index: int) -> WeaponBase:
	# 读档/波首确定性重推导（存档层冻结口径：镜面为会话态，指向按「武器槽序 +
	# 固定哈希(武器 id)」重推导——同种子逐局一致，LOCK 卡为构筑漂移的确定性出口）。
	# 排除空槽与 W5 自身；池空返回 null（镜面侧静默降级为锚束标记）。
	var pool: Array[WeaponBase] = []
	for w in weapon_slots:
		if w != null and is_instance_valid(w) and w.data != null \
				and String(w.data.id) != "W5_prism":
			pool.append(w)
	if pool.is_empty():
		return null
	var h := hash(String(pool[p_mirror_index % pool.size()].data.id)) \
		+ p_mirror_index * 2654435761                     # 固定哈希(武器 id)+槽序盐
	return pool[absi(h) % pool.size()]


func clear_mirrors() -> void:
	# 镜面回收（重开/换局收口——注意：不进 _reset_skill_temp_state，验收 2 锁定
	# 「_summon_copies 空而 _mirror_images 原样」的永久件语义）
	for mirror in _mirror_images:
		if mirror != null and is_instance_valid(mirror):
			mirror.queue_free()
	_mirror_images.clear()


func _summon_restore() -> void:
	# 僚机到期还原（R183）：复制武器回收 + 护航舰离场；换角色/重开共用收口
	_summon_left = 0.0
	for drone in _summon_drones:               # R93 护航舰到期回收
		if drone != null and is_instance_valid(drone):
			drone.queue_free()
	_summon_drones.clear()
	for copy in _summon_copies:                # R183 复制武器回收（环绕副本的力场随宿主 free）
		if copy != null and is_instance_valid(copy):
			var sys: Variant = _deps.get("elemental")
			if sys is ElementalSystem:         # 反应乘区注销（P1：不注销则全表连乘滚雪球）
				(sys as ElementalSystem).unregister_reaction_mult(copy.uid)
			copy.queue_free()
	_summon_copies.clear()


func _skill_stomp() -> void:
	# 震荡践踏：220px 内敌人击退 + 260px 内敌方弹清除（复用 NULLIFIED 统一收束）
	var grid: Variant = _deps.get("enemy_grid")
	if grid != null:
		for e in (grid as SpaceGrid).query_circle(global_position, 220.0):
			if e == null or bool(e.get("dead")):
				continue
			if e.has_method(&"knockback"):
				e.call(&"knockback", ((e as Node2D).global_position - global_position).normalized() * 280.0)
	var bgrid: Variant = _deps.get("enemy_bullet_grid")
	if bgrid != null:
		var cleared := 0
		for b in (bgrid as SpaceGrid).query_circle(global_position, 260.0):
			if b is ProjectileBase and (b as ProjectileBase).team == 1:
				EventBus.emit_bullet_nullified((b as Node2D).global_position)
				(b as ProjectileBase).nullify()
				cleared += 1
			if cleared >= 24:
				break


func gain_xp(p_amount: float) -> void:
	# 经验/等级：xp_gained → 升级（多级连升逐次广播，弹卡排队由 GameLoop 仲裁 E-16）
	# 升级回满血（用户反馈 2026-08-29「升级还是回满血吧」：升级即奖励，血条拉满解压）
	# 经验倍率合成：养成萃取 × 地图祝福 × AFF_XP_GAIN 词条池（R9：跨武器聚合，掉落吸收时实时求值）
	var amount := maxf(p_amount, 0.0) * (1.0 + Meta.xp_pct()) * map_xp_mult 		* (1.0 + clampf(_weapon_pool_sum(&"add_xp"), 0.0, 2.0)) 		* GameConst.difficulty_reward_mult(_difficulty)   # R73 难度风险回报（E1）
	xp += amount
	EventBus.emit_xp_gained(amount)
	while xp >= xp_need:
		xp -= xp_need
		level += 1
		xp_need = _xp_need_for(level)
		hp = max_hp
		EventBus.emit_level_up(level)


func set_difficulty(p_d: int) -> void:
	# R73：GameLoop 开局/续档注入（经验合成式消费；金币乘区在 GameLoop 掉账侧用 _difficulty）
	_difficulty = clampi(p_d, 0, 2)


func difficulty_reward_mult() -> float:
	# R73 详情展示口（构筑详情「经验获取」行含难度加成）
	return GameConst.difficulty_reward_mult(_difficulty)


func gold_find_pct() -> float:
	# 金币寻获率（R5.12-P1 AFF_GOLD 点金：金币掉率与掉量 ×(1+Σ)，掉落侧两处乘区——
	# GameLoop._on_enemy_killed_drop_xp 消费；同 map_gold_mult 叠乘口径）
	return clampf(_weapon_pool_sum(&"add_gold"), 0.0, 3.0)


func xp_gain_pct() -> float:
	# 经验加成总增量（R18 构筑详情展示口；与 gain_xp 合成式同源）：
	# 养成萃取 × 地图祝福经验 × 词条池（AFF_XP_GAIN 经验萃取）合成增量
	return (1.0 + Meta.xp_pct()) * map_xp_mult \
		* (1.0 + clampf(_weapon_pool_sum(&"add_xp"), 0.0, 2.0)) - 1.0


func gold_gain_pct() -> float:
	# 金币加成总增量（R18 构筑详情展示口）：点金词条池 × 地图祝福金币
	return (1.0 + gold_find_pct()) * map_gold_mult - 1.0


func apply_hazard_slow(p_mult: float, p_duration: float) -> void:
	# 冰锁圈减速应用（HazardPool frost 调用；刷新式——多圈叠加取最长持续时间）
	hazard_slow_mult = clampf(p_mult, 0.2, 1.0)
	hazard_slow_left = maxf(hazard_slow_left, p_duration)


func respawn() -> void:
	# 重开复活（GameLoop.restart_run → _reset_run_state 调用；集成包修复：死亡短路
	# _dead 属一次性 E-16 仲裁标志，必须随局重置——否则重开后 take_contact_damage 永久无效）
	# 重生无敌 1.5s（B_spec 无重生无敌数值 → 主控裁定；重开保护——防残留/新刷弹幕
	# 重生首帧秒杀，配合 GameLoop._reset_run_state 战场清场序，审查 Fix 1）
	_dead = false
	hp = max_hp
	level = 1
	xp = 0.0
	xp_need = _xp_need_for(1)
	unlocked_slots = GameConst.difficulty_slot_default(_difficulty)   # R183 开局默认 2/3/3
	slot_bonus = 0                              # R88 金卡解锁计数随局清零
	invuln_left = RESPAWN_INVULN_S
	clear_revive_protect()                       # E2 r2：青弧跨局清零（复活 3s 内重开/回菜单不得残留）
	# 格挡力场复位（词条随武器重建重挂；interval 清零防上局残留——挂载时再置位）
	shield_interval = 0.0
	shield_timer = 0.0
	shield_ready = false
	_shield_pulse_left = 0.0
	_drag_accum = Vector2.ZERO
	skill_cd_left = 0.0
	skill_active_left = 0.0
	rof_mult = 1.0
	_reset_skill_temp_state()                   # 临时态（毒云/僚机）还原——set_character 内再收口
	clear_mirrors()                             # R187 镜面为会话态：重开随武器重建全清（不进临时态收口）
	_mirror_locked = false                      # MEC_MIRROR_LOCK 挂载态随局重置（词条随武器重建重挂）
	set_character(Meta.character_id)          # 重开按当前角色+养成重置（M8/角色系统）
	_flash_left = 0.0                            # 表现态复位（方向 C）
	_punch_left = 0.0
	_tilt = 0.0
	modulate.a = 1.0
	if _sprite != null:
		_sprite.scale = Vector2(_visual_scale, _visual_scale)
		_sprite.rotation = 0.0


func get_hp_pct() -> float:
	# 背水协议条件（SYN_LOWHP_FURY ctx）
	if max_hp <= 0.0:
		return 0.0
	return hp / max_hp


func _on_died() -> void:
	# 死亡事件（E-16 优先级最高——GameLoop 仲裁；只派发一次）
	if _dead:
		return
	_dead = true
	EventBus.emit_player_died()


func _try_revive() -> bool:
	# 应急协议/难度附赠复活：满血复活 + 无敌 3.0s（E2 r2：REVIVE_INVULN_S，每局次数 =
	# 养成等级 + 难度附赠）。演出走 revive_burst 专用通道（白闪/横幅/音效由订阅方
	# GameFeelDirector/HUD/GameLoop 消费）——不再复用 kill_blast（与敌死亡/Blink 爆同款
	# 橙红爆，无复活视觉身份）与 mechanics_intro（与波次 toast 共用唯一 Label 同帧互顶）。
	# 次数耗尽先行 return：0 命致死绝不闪复活 UI，正常走死亡仲裁 → 结算屏。
	if revives_left <= 0:
		return false
	revives_left -= 1
	hp = max_hp
	invuln_left = REVIVE_INVULN_S
	_revive_protect_left = REVIVE_INVULN_S       # 青弧倒数置位（唯一写点；哨兵 3s 技能无敌不触发——独立字段）
	_revive_protect_max = REVIVE_INVULN_S
	queue_redraw()
	_revive_clear_bullets()                      # 260px 内至多 24 颗敌弹清弹缓冲（_skill_stomp 同帽）
	EventBus.emit_revive_burst(global_position, revives_left)   # charges_left = 扣减后余量
	var tree := get_tree()
	if tree != null:
		var feel := tree.get_first_node_in_group(&"game_feel")
		if feel != null and feel.has_method(&"on_boss_death_feel"):
			feel.call(&"on_boss_death_feel")   # 120ms 顿帧 + trauma 1.0 + 色差（BOSS_DEATH 档复用，保留）
	return true


func _revive_clear_bullets() -> void:
	# 复活清弹缓冲（E2 r2）：260px 内 team==1 敌弹至多清除 24 颗——零伤害、不击退敌人，
	# 纯公平性缓冲而非清场权（防「免死+免费清场」循环，与 hp=1 类遗物复活通道叠加尤甚；
	# 与 _skill_stomp 消弹同帽先例一致，第 25 颗起保留）。每颗走既有 bullet_nullified
	# 涟漪。依赖敌弹网格为最新帧序（enemy_bullet_grid 仅帧序④重建——调用方保证）。
	var bgrid: Variant = _deps.get("enemy_bullet_grid")
	if bgrid == null:
		return
	var cleared := 0
	for b in (bgrid as SpaceGrid).query_circle(global_position, REVIVE_CLEAR_RADIUS):
		if b is ProjectileBase and (b as ProjectileBase).team == 1:
			EventBus.emit_bullet_nullified((b as Node2D).global_position)
			(b as ProjectileBase).nullify()
			cleared += 1
		if cleared >= REVIVE_CLEAR_CAP:
			break


func clear_revive_protect() -> void:
	# 复活青弧跨局收口（E2 r2 复审 M1）：清零双字段 + 重绘抹弧。respawn() 必调；
	# GameLoop._restore_run_state（continue 局）同步调用——保护演出态不入快照
	_revive_protect_left = 0.0
	_revive_protect_max = 0.0
	queue_redraw()


func _on_slot_unlocked_event(p_slot: int) -> void:
	unlock_slot(p_slot)


func _clamp_to_playfield() -> void:
	# E-15：位置钳制活动区（下 40% 屏）
	var size := Vector2(720.0, 1280.0)
	if GameConfig.balance != null:
		size = Vector2(GameConfig.balance.res_logic)
	global_position.x = clampf(global_position.x, hitbox_radius, size.x - hitbox_radius)
	global_position.y = clampf(global_position.y, size.y * 0.6, size.y - hitbox_radius)


func _xp_need_for(p_level: int) -> float:
	# 14 × lv^1.4（balance.xp_curve 真源；lv → lv+1 升级所需）
	var base := 14.0
	var power := 1.4
	if GameConfig.balance != null:
		base = float(GameConfig.balance.xp_curve.get("base", 14.0))
		power = float(GameConfig.balance.xp_curve.get("power", 1.4))
	return base * pow(float(maxi(p_level, 1)), power)


# ── 方向 C 表现层（贴纸机体：倾斜 / 双引擎喷焰 / hover 浮动 / 受击白闪弹回 / 无敌闪烁） ──
func _tick_visual(p_game_delta: float, p_move: Vector2) -> void:
	# 纯表现（game_delta 通道——顿帧自然冻结）；不触碰数值与碰撞
	_anim_t += p_game_delta
	# hover 待机浮动（正弦 bob——机体「悬停感」，叠加在倾斜/挤压之上）
	var hover_y := sin(_anim_t * HOVER_PERIOD) * HOVER_AMP
	_sprite.position = Vector2(0.0, hover_y)
	# 移动倾斜（横移 bank）+ 移动拉伸
	var target_tilt := clampf(-p_move.x * 0.05, -0.38, 0.38)
	_tilt += (target_tilt - _tilt) * minf(p_game_delta * 16.0, 1.0)
	var moving := p_move.length_squared() > 0.01
	var squash := minf(p_move.length() * 0.012, 0.18)
	var punch := 1.0
	if _punch_left > 0.0:
		_punch_left = maxf(_punch_left - p_game_delta, 0.0)
		var bt := 1.0 - _punch_left / PUNCH_TIME
		punch = 1.0 + 0.34 * exp(-5.0 * bt) * sin(bt * 20.0)
	_sprite.rotation = _tilt
	_sprite.scale = Vector2(_visual_scale * (1.0 - squash) * punch,
		_visual_scale * (1.0 + squash) / punch)
	# 双引擎喷焰：移动时点亮 + 左右反相频闪抖动（随倾斜旋转 + hover 同步浮动）
	_flame_l.visible = moving and not _dead
	_flame_r.visible = _flame_l.visible
	if _flame_l.visible:
		var hover_off := Vector2(0.0, hover_y)
		_flame_l.rotation = _tilt
		_flame_r.rotation = _tilt
		_flame_l.position = (POD_L * _visual_scale).rotated(_tilt) + hover_off
		_flame_r.position = (POD_R * _visual_scale).rotated(_tilt) + hover_off
		var flick_l := 0.9 + 0.25 * sin(_anim_t * 42.0)
		var flick_r := 0.9 + 0.25 * sin(_anim_t * 42.0 + PI)
		_flame_l.scale = Vector2(_visual_scale * flick_l, _visual_scale * (1.7 - flick_l * 0.55))
		_flame_r.scale = Vector2(_visual_scale * flick_r, _visual_scale * (1.7 - flick_r * 0.55))
	# 受击白闪剪影
	if _flash_left > 0.0:
		_flash_left = maxf(_flash_left - p_game_delta, 0.0)
		_flash.visible = true
		_flash.rotation = _tilt
		_flash.position = _sprite.position
		_flash.modulate.a = clampf(_flash_left / FLASH_TIME, 0.0, 1.0)
	else:
		_flash.visible = false
	# 无敌帧闪烁（半透呼吸）
	modulate.a = 0.62 + 0.38 * sin(_anim_t * 26.0) if invuln_left > 0.0 else 1.0
	# 格挡力场环（MEC_SHIELD）：就绪=青蓝泡泡呼吸；充能=隐藏；格挡=扩散脉冲淡出
	if _shield_ring != null:
		if _shield_pulse_left > 0.0:
			_shield_pulse_left = maxf(_shield_pulse_left - p_game_delta, 0.0)
			var bt := 1.0 - _shield_pulse_left / SHIELD_PULSE_TIME
			_shield_ring.visible = true
			_shield_ring.rotation = 0.0
			_shield_ring.position = _sprite.position
			_shield_ring.scale = Vector2.ONE * (_visual_scale * SHIELD_RING_R / 24.0
				* (1.0 + 0.55 * bt))
			_shield_ring.modulate.a = (1.0 - bt) * 0.9
		elif _skill_shield_left > 0.0:
			_skill_shield_left = maxf(_skill_shield_left - p_game_delta, 0.0)
			_shield_ring.visible = true
			_shield_ring.rotation = _anim_t * 2.4
			_shield_ring.position = _sprite.position
			_shield_ring.scale = Vector2.ONE * (_visual_scale * SHIELD_RING_R / 24.0
				* (1.0 + 0.06 * sin(_anim_t * 9.0)))
			_shield_ring.modulate.a = 0.55 + 0.2 * sin(_anim_t * 8.0)
		elif shield_interval > 0.0 and shield_ready:
			_shield_ring.visible = true
			_shield_ring.rotation = _anim_t * 0.9
			_shield_ring.position = _sprite.position
			_shield_ring.scale = Vector2.ONE * (_visual_scale * SHIELD_RING_R / 24.0
				* (1.0 + 0.045 * sin(_anim_t * 5.2)))
			_shield_ring.modulate.a = 0.5 + 0.14 * sin(_anim_t * 5.2)
		else:
			_shield_ring.visible = false


func _spawn_fallback_drones() -> void:
	# R93 护航舰：两架编队侧翼跟随 + 低强度伴随火力（12% 主武器 ATK——僚机定位=
	# 伴随输出，不抢复制武器戏），到期前 1.5s 闪烁预警，寿命尽自回收。
	# R183 起随技能常态生成（复制武器为主输出，舰体为「僚机在场」的视觉锚点）
	for i in range(SUMMON_COPIES):
		var drone := SummonDrone.new()
		drone.name = "NoahDrone%d" % i
		drone.side = 1 if i % 2 == 0 else -1
		add_child(drone)
		_summon_drones.append(drone)


class SummonDrone:
	# R93 真护航僚机（用户「所谓僚机就是临时环绕力场？」）：舰形贴图编队侧翼跟随
	# + 主动开火（弹道池真弹，伤害 12% 主武器 ATK）——不再是环绕接触珠。
	# 到期前 1.5s 闪烁预警，寿命尽自回收。
	extends Node2D

	var side := 1                                # 编队侧（1 右 / -1 左）
	var _fire_left := 0.0
	var _life_left := 10.0
	var _sprite: Sprite2D = null

	func _ready() -> void:
		z_index = 20
		_sprite = Sprite2D.new()
		_sprite.texture = TextureFactory.ship(true)   # 剪影舰体（金色染色=僚机识别）
		_sprite.modulate = PopPalette.GOLD
		_sprite.scale = Vector2(0.4, 0.4)
		add_child(_sprite)

	func _process(p_delta: float) -> void:
		var host := get_parent()
		if host == null or not is_instance_valid(host):
			return
		_life_left -= p_delta
		if _life_left <= 0.0:
			queue_free()
			return
		# 编队位：侧翼 ±74px / 前突 44px + 微浮动——平滑跟随（非环绕）
		var t_now := Time.get_ticks_msec() * 0.001
		var target: Vector2 = Vector2(side * 74.0, -44.0 + sin(t_now * 2.2 + side) * 7.0)
		position = position.lerp(target, minf(p_delta * 6.0, 1.0))
		# 到期预警闪烁（末 1.5s）
		if _life_left < 1.5:
			_sprite.modulate.a = 0.4 + 0.6 * absf(sin(_life_left * 14.0))
		# 开火：0.55s 一发，最近敌 ≤340px
		_fire_left -= p_delta
		if _fire_left > 0.0:
			return
		_fire_left = 0.55
		_fire_at_nearest(host)

	func _fire_at_nearest(p_host: Node2D) -> void:
		var deps: Variant = p_host.get("_deps")
		var grid: Variant = deps.get("enemy_grid") if deps is Dictionary else null
		var pool: Variant = deps.get("projectile_pool") if deps is Dictionary else null
		var pipeline: Variant = deps.get("pipeline") if deps is Dictionary else null
		if grid == null or pool == null or pipeline == null:
			return
		var world_pos: Vector2 = p_host.global_position + position
		var target: Node2D = grid.call(&"query_nearest", world_pos, 340.0, null)
		if target == null or bool(target.get("dead")):
			return
		# 弹伤 = 12% 主武器 ATK（僚机定位=伴随输出，不抢主武器戏）
		var slots: Array = p_host.get("weapon_slots")
		var w0: Variant = slots[0] if slots.size() > 0 else null
		var base := 10.0
		if w0 != null and w0 is WeaponBase and is_instance_valid(w0):
			base = float((w0 as WeaponBase).build_panel_snapshot().get("base_atk", 10.0))
		var dir := (target.global_position - world_pos).normalized()
		var proj: ProjectileBase = pool.call(&"acquire")
		if proj == null:
			return
		proj.spawn({
			"position": world_pos, "velocity": dir * 560.0,
			"lifetime": 1.2, "range": 400.0, "pierce": 1, "bounces": 0,
			"hitbox_radius": 7.0, "element": GameConst.Element.KIN, "attach_value": 0.0,
			"generation": 0, "weapon_uid": int(p_host.get_instance_id()),
			"panel_snapshot": {"base_atk": base * 0.12},
			"trait_stack": null, "team": 0,
		})
		proj.damage_pipeline = pipeline                  # 武器侧 _inject_projectile_deps 同口径
		proj.enemy_grid = grid
		proj.pool = pool
		# 朝向敌向（剪影画布朝上）
		_sprite.rotation = dir.angle() + PI * 0.5

# scripts/entities/crystal/crystal.gd
# v1.3.0 元素水晶（A12 R2）：非池化静态场上的可击破元素源（同屏至多 1 颗——Crystal.active）。
# · 出现：WaveDirector.wave>=8 且非 Boss 波 40% roll（seed 1001）→ GameLoop 组装挂载。
# · 击破：玩家弹碰撞（_check_crystal_hit）→ shatter 按弹元素五分支——
#   FIR 全体 AOE（90px ×0.8 面板）/ ICE·WAT 半径附着（100px ×50 快照通道）/
#   LTG 雷击连锁（3 目标/跳，base = 当跳伤害 ?? 面板）/ KIN 弱 AOE（90px ×0.4 面板）；
#   结算尾 dissolve（波末 wave_cleared / 清场 _clear_battlefield 亦消散，GAME_OVER 不清）。
class_name Crystal
extends Node2D

const HIT_RADIUS := 26.0                       # 弹-晶碰撞半径（弹 effective_radius + 本值）
const FIR_RADIUS := 90.0                       # FIR 臂 AOE 半径
const FIR_RATIO := 0.8                         # FIR 臂面板倍率
const ICE_RADIUS := 100.0                      # ICE 臂附着半径
const ICE_ATTACH := 50.0                       # ICE 臂附着值
const WAT_RADIUS := 100.0                      # WAT 臂附着半径
const WAT_ATTACH := 50.0                       # WAT 臂附着值
const KIN_RADIUS := 90.0                       # KIN 臂 AOE 半径
const KIN_RATIO := 0.4                         # KIN 臂面板倍率

static var active: Crystal = null              # 同屏唯一水晶引用（projectile 碰撞查询口）

var uid: int = 0                               # GameConst.next_uid()（弹侧帧聚合去重键）
var alive: bool = false                        # 生命周期存活标志（shatter/碰撞守卫）
var elemental: ElementalSystem = null          # 注入（ICE/WAT 附着 / LTG 连锁通道）
var enemy_grid: SpaceGrid = null               # 注入（附着圆查询）


func _ready() -> void:
	z_index = 3                                   # 敌（2）上 / 玩家（6）下的占位层级


func activate(p_elemental: ElementalSystem, p_grid: SpaceGrid) -> void:
	# 挂载激活（GameLoop._on_crystal_spawn_requested 组装后调用）
	uid = GameConst.next_uid()
	elemental = p_elemental
	enemy_grid = p_grid
	alive = true
	active = self
	queue_redraw()


func dissolve() -> void:
	# 消散（击破尾/波末/清场统一出口）：active 摘除 + queue_free（非池化，无归还）
	if active == self:
		active = null
	alive = false
	queue_free()


func shatter(p_proj: ProjectileBase) -> void:
	# 击破结算（弹元素五分支；面板真源 = 来源弹 panel_snapshot.base_atk）：
	# 结算尾无条件 dissolve——弹不耗穿透不回收继续飞（_check_crystal_hit 契约）
	if not alive:
		return
	var panel_atk := float(p_proj.panel_snapshot.get("base_atk", 0.0))
	match p_proj.element:
		GameConst.Element.FIR:
			# 火晶：全体爆炸 AOE（90px ×0.8 面板，HIT_IS_AOE_SECONDARY；武器缺失跳过）
			var weapon := _weapon_of(p_proj)
			if weapon != null:
				weapon.settle_aoe(global_position, FIR_RADIUS, panel_atk * FIR_RATIO, true)
		GameConst.Element.ICE:
			_radial_apply_attach(GameConst.Element.ICE, ICE_RADIUS, ICE_ATTACH, panel_atk)
		GameConst.Element.WAT:
			_radial_apply_attach(GameConst.Element.WAT, WAT_RADIUS, WAT_ATTACH, panel_atk)
		GameConst.Element.LTG:
			# 雷晶：雷击连锁（base = 当跳结算伤害 ?? 面板；每跳 3 目标）
			var base := panel_atk
			if p_proj.last_hit_damage > 0.0:
				base = p_proj.last_hit_damage
			if elemental != null:
				elemental.shock_chain_from_crystal(self, base)
		GameConst.Element.KIN:
			# 动能晶：弱 AOE（90px ×0.4 面板；武器缺失跳过）
			var weapon_kin := _weapon_of(p_proj)
			if weapon_kin != null:
				weapon_kin.settle_aoe(global_position, KIN_RADIUS, panel_atk * KIN_RATIO, true)
	DebugStats.count(&"crystal_shatter")
	dissolve()


# ── 内部 ──────────────────────────────────────────────────────────
func _weapon_of(p_proj: ProjectileBase) -> WeaponBase:
	# 来源武器引用守卫（飞行中武器可能被移除——失效按无武器处理，镜像弹侧 ctx.weapon 口径）
	if p_proj.weapon_ref != null and is_instance_valid(p_proj.weapon_ref):
		return p_proj.weapon_ref
	return null


func _radial_apply_attach(p_element: int, p_radius: float, p_value: float,
		p_snapshot: float) -> void:
	# ICE/WAT 臂：圆查询逐敌附着（镜像 ElementalSystem._spread_reaction 几何口径：
	# 网格保守超集 → 窄相收窄 radius + 目标 hitbox_r；dead 跳过；经 apply_attach 入口
	# ——芯片/共鸣乘区在系统侧统一生效；p_info 携带面板快照供剧变基数）
	if enemy_grid == null or elemental == null:
		return
	var candidates: Array[Node2D] = []
	candidates.append_array(enemy_grid.query_circle(global_position, p_radius))
	for cand in candidates:
		if cand == null or bool(cand.get("dead")):
			continue
		var hr: Variant = cand.get("hitbox_r")
		var reach := p_radius + (float(hr) if hr != null else 0.0)
		if (cand as Node2D).global_position.distance_to(global_position) > reach:
			continue
		elemental.apply_attach(cand, p_element, p_value, {"snapshot": p_snapshot})


func _draw() -> void:
	# 程序化占位渲染（紫水晶 + 白核）
	draw_circle(Vector2.ZERO, HIT_RADIUS, Color(0.66, 0.42, 1.0, 0.92))
	draw_circle(Vector2.ZERO, 8.0, Color.WHITE)


func _exit_tree() -> void:
	# 兜底：未经 dissolve 的移除路径（重开 free 链）也摘除静态引用
	if active == self:
		active = null

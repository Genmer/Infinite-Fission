# scripts/loop/achievement_tracker.gd
# v1.4.0 AchievementTracker（A13 Meta 二期）：成就判定器（Node；对齐 relic/chip handler 模式：
# 注入 + reset_run）。判定只读战斗事实 → MetaStore.unlock_achievement 仲裁（幂等真源在 store）。
# · ★ 本地信号 achievement_unlocked 非 EventBus（零新总线信号纪律）——GameLoop presentation
#   段订阅跳字，外部不感知。
# · 判定站点五处：
#   ① Boss 三档 enemy_killed（四层守卫：is Enemy → data null → TAG_BOSS 位 → data.id 三档
#     精确匹配——杀 boss3 不回溯解锁 boss1/boss2）
#   ② 波次三档 wave_started（≥10/20/30；高档触发幂等覆盖低档）
#   ③ 芯片 on_chip_equipped（同主属性 ≥2 → ach_chip_set / 已装备 ≥6 → ach_chip_full）
#   ④ 武器 on_weapon_slots_changed（有效 WeaponBase ≥5 → ach_weapons5；rebuild_registries 尾）
#   ⑤ 结算 on_run_settled（累计击杀 ≥1000 → ach_kills1000；GameLoop._settle_run 在
#     record_run 之后、取新解锁清单之前调用）
# · ★ setup 内 enemy_killed/wave_started 订阅必须先于 EnemySpawner 入树与掉落侧连接
# （铁律 6：连接序 = 派发序——Boss 击杀读 tags/data.id 必须先于 spawner 死亡归还清零）。
class_name AchievementTracker
extends Node

signal achievement_unlocked(p_id: StringName, p_title: String)   # 本地信号（非总线）

# Boss 三档精确匹配表（id 序 = 成就档序；真源 = resources/enemies/E6_boss*.tres）
const BOSS_IDS: Array[StringName] = [&"E6_boss1", &"E6_boss2", &"E6_boss3"]
const BOSS_ACH_IDS: Array[StringName] = [&"ach_boss1", &"ach_boss2", &"ach_boss3"]

var meta_store: MetaStore = null               # 注入（unlock 仲裁 + 幂等去重真源）
var _new_unlocks: Array[StringName] = []       # 本局新解锁（结算屏清单；reset_run 随局清零）


func setup(p_meta_store: MetaStore) -> void:
	# Boot 注入（GameLoop._boot_build_actors：meta_store 载档后、xp 掉落订阅前——★订阅
	# 先于掉落侧与 spawner 入树，铁律 6）
	meta_store = p_meta_store
	EventBus.enemy_killed.connect(_on_enemy_killed)
	EventBus.wave_started.connect(_on_wave_started)


func reset_run() -> void:
	# 本局新解锁清单清零（GameLoop._reset_run_state 调用；已解锁成就持久在 MetaStore 不清）
	_new_unlocks.clear()


func on_chip_equipped(p_max_main_count: int, p_equipped_size: int) -> void:
	# 芯片成就（ChipHandler.equip 成功尾消费）：主属性同键 ≥2 → 套装协同 / 已装备 ≥6 → 满配武装
	if p_max_main_count >= 2:
		_try_unlock(&"ach_chip_set")
	if p_equipped_size >= 6:
		_try_unlock(&"ach_chip_full")


func on_weapon_slots_changed(p_filled: int) -> void:
	# 武器成就（ElementalSystem.rebuild_registries 尾消费）：有效 WeaponBase ≥5 → 全副武装
	if p_filled >= 5:
		_try_unlock(&"ach_weapons5")


func on_run_settled(p_total_kills: int, p_defer_save: bool = false) -> void:
	# 击杀成就（GameLoop._settle_run 消费）：累计击杀 ≥1000 → 千锤百炼
	# v1.5.0（K7）：p_defer_save 双写盘合并——true 时解锁仅入内存，落盘由结算期
	# GameLoop 显式 save() 单点承担（默认 false = 既有行为恒等，其余调用点零改动）
	if p_total_kills >= 1000:
		_try_unlock(&"ach_kills1000", p_defer_save)


func new_unlock_titles() -> Array[String]:
	# 本局新解锁标题清单（GameOverScreen.set_new_achievements 消费；表驱动非缓存文案）
	var out: Array[String] = []
	for id in _new_unlocks:
		out.append(_title_of(id))
	return out


# ── 内部 ──────────────────────────────────────────────────────────
func _on_enemy_killed(p_enemy: Node2D) -> void:
	# Boss 三档（四层守卫；tags/data 读取依赖连接序 = 派发序——本订阅先于 spawner 归还清零）
	if not (p_enemy is Enemy):
		return
	var enemy := p_enemy as Enemy
	if enemy.data == null:
		return
	if (enemy.tags & GameConst.TAG_BOSS) == 0:
		return
	var idx := BOSS_IDS.find(enemy.data.id)
	if idx >= 0:
		_try_unlock(BOSS_ACH_IDS[idx])


func _on_wave_started(p_wave: int) -> void:
	# 波次三档（≥10/20/30；_try_unlock 幂等，已解锁短路）
	if p_wave >= 30:
		_try_unlock(&"ach_wave30")
	if p_wave >= 20:
		_try_unlock(&"ach_wave20")
	if p_wave >= 10:
		_try_unlock(&"ach_wave10")


func _try_unlock(p_id: StringName, p_defer_save: bool = false) -> void:
	# 解锁仲裁：meta_store 缺失 → 忽略（降级）；已解锁 → 幂等短路；首解 → 入清单 +
	# 本地信号 + 遥测。v1.5.0（K7）：p_defer_save 透传 MetaStore（双写盘合并，默认 false）
	if meta_store == null:
		return
	if meta_store.has_achievement(p_id):
		return
	if not meta_store.unlock_achievement(p_id, p_defer_save):
		return
	_new_unlocks.append(p_id)
	achievement_unlocked.emit(p_id, _title_of(p_id))
	DebugStats.count(&"achievement_unlocked")


func _title_of(p_id: StringName) -> String:
	# ACHIEVEMENTS 封闭表 title 提取（未知 id → ""）
	var entry: Variant = MetaStore.ACHIEVEMENTS.get(p_id)
	if entry is Dictionary:
		return String((entry as Dictionary).get("title", ""))
	return ""

# scripts/core/game_const.gd
# M-19 附庸：全局枚举/位标志/共享常量。纯静态容器，禁止持有运行时状态。
# （唯一例外：next_uid() 的分配器计数——架构 §2.0 点名的全局递增 UID 分配器。）
class_name GameConst
extends RefCounted

enum Element { KIN, FIR, ICE, LTG }                       # 伤害/附着元素
enum PoolClass { ADD, MULT, LOCAL, MECH, ELEM }           # 词条池归类（B_spec §2.5）
enum TraitEvent { ON_SPAWN, ON_TICK, ON_HIT, ON_PIERCE, ON_BOUNCE, ON_EXPIRE }  # 六大生命周期
enum WeaponForm { BALLISTIC, LASER, HOMING, MELEE }       # 武器四形态
enum EnemyBehavior { CHASE, RANGED, DASHER, ORBIT, SENTRY }  # M1 只实现 CHASE/RANGED
enum GameStatus { BOOT, MENU, PLAYING, PAUSED, LEVEL_UP, GAME_OVER, SHOP }   # v0.6.0 尾部追加 SHOP（值 6，零重编号；A4 §1）
enum RecycleReason { EXPIRED, PIERCE_DEPLETED, BOUNCE_DEPLETED, NULLIFIED, FORCED }  # 回收五路径
enum PopupStyle { NORMAL, CRIT, REACTION, DOT, HEAL, XP }
enum FeelLevel { HIT, CRIT, CATALYST, BOSS_DEATH }        # GameFeel 分级（Q-12）
enum ReactionType { RXN_FIR_ICE, RXN_FIR_LTG, RXN_ICE_LTG }  # 碎裂/过载/超导（中性 ID）
enum TargetStrategy { NEAREST, FOREMOST, LOWEST_HP, LOCKED }  # 武器目标策略
enum ConditionId {                                        # 乘区条件封闭枚举（§三.5）
	TARGET_FROZEN, TARGET_BURNING, TARGET_SHOCKED, AFTER_BOUNCE,
	PIERCE_INDEX_GE, PLAYER_HP_BELOW, WAVE_FIRST_HIT, TARGET_TAG_IN,
	NONE,
}

# DamageContext.hit_flags 位标志
const HIT_IS_BOUNCE := 1            # 本次命中发生在反弹之后
const HIT_AFTER_PIERCE := 2         # 穿透序数 ≥2 的命中
const HIT_IS_SPLIT_CHILD := 4       # 分裂子代
const HIT_IS_REACTION := 8          # 元素反应独立结算（不掷暴击）
const HIT_IS_DOT := 16              # DOT 跳伤（不掷暴击）
const HIT_IS_AOE_SECONDARY := 32    # 爆炸溅射次级目标
const HIT_NO_CRIT := 24             # 掩码：HIT_IS_REACTION | HIT_IS_DOT

# Enemy tags / immune_mask 位标志
const TAG_ELITE := 1
const TAG_BOSS := 2
const IMMUNE_FREEZE := 1            # 定身免疫（Boss 默认置位，F-17）
const IMMUNE_CHILL := 2
const IMMUNE_BURN := 4
const IMMUNE_SHOCK := 8

# UID 位宽（§4.1 幂等键位拼接约束：UID < 2^20，帧号 < 2^24）
const UID_MAX := 0xFFFFF            # 2^20 − 1

# 分配器计数（静态；单主线程访问，无需线程安全）
static var _uid_counter: int = 0


static func next_uid() -> int:
	# 全局递增实例 UID（投射物/武器/词条实例幂等键组成部分）；线程安全性不需要（单主线程）。
	# 超出 20bit 位宽时回绕（§4.1：分配器层面钳制）。
	_uid_counter += 1
	if _uid_counter > UID_MAX:
		_uid_counter = 1
	return _uid_counter

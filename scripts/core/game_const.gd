# scripts/core/game_const.gd
# M-19 附庸：全局枚举/位标志/共享常量。纯静态容器，禁止持有运行时状态。
# （唯一例外：next_uid() 的分配器计数——架构 §2.0 点名的全局递增 UID 分配器。）
class_name GameConst
extends RefCounted

enum Element { KIN, FIR, ICE, LTG }                       # 伤害/附着元素
enum PoolClass { ADD, MULT, LOCAL, MECH, ELEM }           # 词条池归类（B_spec §2.5）
enum TraitEvent { ON_SPAWN, ON_TICK, ON_HIT, ON_PIERCE, ON_BOUNCE, ON_EXPIRE }  # 六大生命周期
enum WeaponForm { BALLISTIC, LASER, HOMING, MELEE }       # 武器四形态
enum EnemyBehavior { CHASE, RANGED, DASHER, ORBIT, SENTRY, BLINK }  # M1：CHASE/RANGED；BLINK R16 起支持（ENEMY_PATTERNS_BASIC §3.3）
enum GameStatus { BOOT, MENU, PLAYING, PAUSED, LEVEL_UP, GAME_OVER }
enum RecycleReason { EXPIRED, PIERCE_DEPLETED, BOUNCE_DEPLETED, NULLIFIED, FORCED }  # 回收五路径

# ── R72 难度三档（用户大活「新增困难和地狱」：复用关卡，普通=现行口径） ──────────
enum Difficulty { NORMAL = 0, HARD = 1, HELL = 2 }


static func difficulty_hp_mult(p_d: int) -> float:
	# 敌 HP 乘区：困难 ×3、地狱 ×9（困难基础上再 ×3——用户口径「最基础的数值」）
	return [1.0, 3.0, 9.0][clampi(p_d, 0, 2)]


static func difficulty_dmg_mult(p_d: int) -> float:
	# 敌接触伤害乘区：同 HP 口径（×3 / ×9）
	return [1.0, 3.0, 9.0][clampi(p_d, 0, 2)]


static func difficulty_reward_mult(p_d: int) -> float:
	# R73 风险回报（E1）：困难 ×1.5 / 地狱 ×2.5——金币与经验共用（高风险高回报闭环）
	return [1.0, 1.5, 2.5][clampi(p_d, 0, 2)]


static func difficulty_revives(p_d: int) -> int:
	# 开局附赠复活次数：普通 0（原口径）/ 困难 1 / 地狱 3（用户裁定）
	return [0, 1, 3][clampi(p_d, 0, 2)]


static func difficulty_dual_pick(p_d: int, p_roll: float) -> bool:
	# 升级双选卡判定：地狱 100%（每次）/ 困难 5%（p_roll = [0,1) 随机数，测试可注入）
	return p_d == Difficulty.HELL or (p_d == Difficulty.HARD and p_roll < 0.05)


static func enemy_attack_note(p_enemy_id: String) -> String:
	# E5/R72 新形态机制一句话（图鉴行 + 首遇提示条共用；空 = 旧怪不提示）
	match p_enemy_id:
		"E25_phase_bomber":
			return "闪现到你身边自爆——落地红圈就是走位窗"
		"E26_shield_lancer":
			return "正面盾面减伤 85%——绕到侧面或背后打"
		"E27_warden_orb":
			return "符文环亮起时弹开你的子弹——等冷却窗口"
		"E28_hexcaster":
			return "在你脚下施放法术圈——读条结束前移开"
		"E29_longbowhawk":
			return "高速箭矢带预判——别走直线"
		"E30_hellfire_revenant":
			return "大范围闪现自爆——引信更短，快速脱离"
		_:
			return ""


static func difficulty_name(p_d: int) -> String:
	return ["普通", "困难", "地狱"][clampi(p_d, 0, 2)]


static func difficulty_desc(p_d: int) -> String:
	# 选难度行副文案（图鉴口径同源）
	match clampi(p_d, 0, 2):
		Difficulty.HARD:
			return "敌 HP/攻击 ×3 · 复活 +1 · 升级 5% 概率成对抉择"
		Difficulty.HELL:
			return "敌 HP/攻击 ×9 · 复活 +3 · 每次升级成对抉择（2 列 6 卡选同行两张）"
		_:
			return "现行口径 · 无附赠复活"
enum PopupStyle { NORMAL, CRIT, REACTION, DOT, HEAL, XP, IMMUNE }   # IMMUNE：R22 元素免疫跳字
enum FeelLevel { HIT, CRIT, CATALYST, BOSS_DEATH }        # GameFeel 分级（Q-12）
enum ReactionType { RXN_FIR_ICE, RXN_FIR_LTG, RXN_ICE_LTG }  # 碎裂/过载/超导（中性 ID）
enum TargetStrategy { NEAREST, FOREMOST, LOWEST_HP, LOCKED }  # 武器目标策略
enum ConditionId {                                        # 乘区条件封闭枚举（§三.5）
	TARGET_FROZEN, TARGET_BURNING, TARGET_SHOCKED, AFTER_BOUNCE,
	PIERCE_INDEX_GE, PLAYER_HP_BELOW, WAVE_FIRST_HIT, TARGET_TAG_IN,
	TARGET_HP_BELOW, PLAYER_HP_ABOVE,               # R72：处决线 / 满血壁垒
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
const TAG_FINAL_BOSS := 4      # 最终 Boss（地图最终波巨 Boss——1/3 屏，用户反馈）
const ELEM_IMMUNE_FIR := 2          # 元素伤害免疫位（R22 P1：bit = 1 << Element）
const ELEM_IMMUNE_ICE := 4          #   FIR=2 / ICE=4 / LTG=8——KIN 无位 = 物理恒有效保底
const ELEM_IMMUNE_LTG := 8
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

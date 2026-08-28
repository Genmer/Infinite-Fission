# scripts/core/data/resources/weapon_level_stats.gd
# §三.1 WeaponLevelStats（升级表嵌套项；表驱动优先于公式，F2 唯一真源）
class_name WeaponLevelStats
extends Resource

@export var base_atk: float = 10.0      # >0（负攻 → 剔除宿主，AC-13.2）
@export var rof: float = 5.0            # (0, 30]（cap_rof 双护栏；负射速 → 剔除宿主，AC-13.2）
@export var cd: float = 0.0             # LASER/HOMING/MELEE 形态：>0
@export var pierce: int = 1             # ≥0
@export var pellets: int = 1            # ≥1
@export var note: String = ""

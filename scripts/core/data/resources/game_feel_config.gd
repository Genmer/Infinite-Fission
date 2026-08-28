# scripts/core/data/resources/game_feel_config.gd
# §三.7 GameFeelConfig（顿帧/震屏/色差分级；数值按 B_spec §1 / Q-12/Q-13 裁定）
class_name GameFeelConfig
extends Resource

# 恰好 4 项（FeelLevel 索引：HIT/CRIT/CATALYST/BOSS_DEATH）；每项 ∈ [0, 200]
@export var hit_stop_ms: Array[int] = [0, 30, 50, 120]
@export_range(0.001, 1.0) var hit_stop_scale: float = 0.05   # (0, 1)
@export var hit_stop_merge_ms: int = 30                      # >0（合并窗口，AC-15.2）
# 4 项（FeelLevel 索引）；每项 ∈ [0, 1]
@export var shake_trauma: Array[float] = [0.15, 0.4, 0.5, 1.0]
@export_range(0.1, 32.0) var shake_max_offset_px: float = 8.0    # (0, 32]（Q-12 上限）
@export_range(0.1, 8.0) var shake_max_rot_deg: float = 1.5       # (0, 8]
@export_range(0.01, 2.0) var shake_decay_s: float = 0.4          # (0, 2]
@export var ca_base_intensity: float = 0.004                 # >0（Q-12 色差起跳）
@export_range(0.01, 1.0) var ca_decay_s: float = 0.15        # (0, 1]
# 4 项（分级放大）
@export var ca_level_mult: Array[float] = [1.0, 2.0, 4.0, 6.0]
@export var particle_max_emitters: int = 64                  # >0（AC-15.5）
# 值 ∈ [1, 5]（优先级裁剪：KILL > CRIT > HIT > AMBIENT）
@export var particle_priorities: Dictionary = {"KILL": 4, "CRIT": 3, "HIT": 2, "AMBIENT": 1}
# §5.4 预留位：色差 shader 降级关闭开关（渲染超预算时降级）
@export var ca_enabled: bool = true

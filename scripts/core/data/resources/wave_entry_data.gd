# scripts/core/data/resources/wave_entry_data.gd
# §三.6 WaveEntryData（波次嵌套项）
class_name WaveEntryData
extends Resource

@export var index: int = 0                          # >0（1~30 唯一连续）
# 每项 {enemy_id, count}；enemy_id 悬空 → 剔除该敌条目 + 告警（AC-13.3）
@export var composition: Array[Dictionary] = []
@export var tp_override: float = 0.0                # ≤0 = 用公式
@export var window: float = 0.0                     # >0
# SHOP / UNLOCK_SLOT / BOSS 等事件标记
@export var events: Array[StringName] = []

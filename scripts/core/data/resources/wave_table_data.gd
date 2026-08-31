# scripts/core/data/resources/wave_table_data.gd
# §三.6 WaveTableData（波次表；30 波 + 无尽参数）
class_name WaveTableData
extends Resource

@export var id: StringName = &"main"                # 非空
# 每项 index 唯一连续（1~30）；缺失波 → 剔除该波 + 回退公式生成（降级不崩溃）
@export var entries: Array[WaveEntryData] = []
# 无尽段条目（分图无尽延伸 P1，2026-08-31）：final_wave 之后的递进波，index 从 final_wave+1
# 起连续（Boss 逢 5）。独立分表存储——validator 契约锁定 entries.index ∈ [1,30]、既有验收
# 断言锁定 entries.size()（30/20），不得并入 entries（零回归纪律）。查波顺序：
# entries 主体段 → endless_entries 无尽段 → 均缺失 → 无尽公式回退（WaveDirector._table_entry）
@export var endless_entries: Array[WaveEntryData] = []
# 无尽模式参数（A3 §2.6）
@export var endless: Dictionary = {
	"tp_base": 110.0, "tp_growth": 1.03, "window_base": 30.0, "window_slope": 0.2,
	"window_cap": 40.0, "elite_mod": 4, "boss_mod": 10,
}
# 表缺失波的回退真源（TP = 14 + 3.2w；A3 §1.4）
@export var tp_formula: Dictionary = {
	"base": 14.0, "slope": 3.2, "jitter": 0.1, "elite_wave_mult": 1.25,
}

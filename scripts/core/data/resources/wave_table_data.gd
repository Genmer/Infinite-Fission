# scripts/core/data/resources/wave_table_data.gd
# §三.6 WaveTableData（波次表；30 波 + 无尽参数）
class_name WaveTableData
extends Resource

@export var id: StringName = &"main"                # 非空
# 每项 index 唯一连续（1~30）；缺失波 → 剔除该波 + 回退公式生成（降级不崩溃）
@export var entries: Array[WaveEntryData] = []
# 无尽模式参数（A3 §2.6）
@export var endless: Dictionary = {
	"tp_base": 110.0, "tp_growth": 1.03, "window_base": 30.0, "window_slope": 0.2,
	"window_cap": 40.0, "elite_mod": 4, "boss_mod": 10,
}
# 表缺失波的回退真源（TP = 14 + 3.2w；A3 §1.4）
@export var tp_formula: Dictionary = {
	"base": 14.0, "slope": 3.2, "jitter": 0.1, "elite_wave_mult": 1.25,
}

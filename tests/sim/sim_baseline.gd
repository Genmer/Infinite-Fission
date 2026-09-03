# tests/sim/sim_baseline.gd
# v1.5.0 TTK 复校工装（A14）：锚点基线（P12 锚点固化消费）。
# · FRAME_BASELINE：{"T1|1|E1": 帧 int}——K8 实测冻结（12 格 seed 42 逐格双跑一致后写入；
#   ★ 只实测冻结不手填）。NTK 格冻结 -1。
# · ANCHOR_CELLS 12 格：T1|1|E1 / T1|40|E1 / T2|10|E1 / T3|10|E6_ns / T4|10|E1 / T5|10|E1 /
#   T6|20|E1 / T7a|10|E1 / T7b|10|E1 / T1|10|E5 / T2|20|E6 / T4|30|E6_ns。
class_name SimBaseline
extends RefCounted

# K8 实测冻结（seed 42；ttk_frames；-1 = NTK）。改任一格 → 必须整批复跑重冻结。
static var FRAME_BASELINE: Dictionary = {
	"T1|1|E1": 46, "T1|40|E1": 5405, "T2|10|E1": 22, "T3|10|E6_ns": 4324,
	"T4|10|E1": 23, "T5|10|E1": 0, "T6|20|E1": 110, "T7a|10|E1": 132,
	"T7b|10|E1": 92, "T1|10|E5": 943, "T2|20|E6": -1, "T4|30|E6_ns": -1,
}   # K8 实测冻结（seed 42；基线=新鲜 env 校验语境：T3|E6_ns 与 T1|E5 两格按 P12 校验语境重冻结（批跑 CSV 4323/965 系模板 env 波序历史语境，差 1/22 帧——A14 §0 口径限制）；-1=NTK）


# 锚点格清单（12 格；FRAME_BASELINE 冻结键域 = 本表）
static var ANCHOR_CELLS: Array[String] = [
	"T1|1|E1", "T1|40|E1", "T2|10|E1", "T3|10|E6_ns", "T4|10|E1", "T5|10|E1",
	"T6|20|E1", "T7a|10|E1", "T7b|10|E1", "T1|10|E5", "T2|20|E6", "T4|30|E6_ns",
]


static func key(p_template: String, p_wave: int, p_kind: String) -> String:
	return "%s|%d|%s" % [p_template, p_wave, p_kind]

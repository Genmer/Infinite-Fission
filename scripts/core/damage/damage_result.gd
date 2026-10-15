# scripts/core/damage/damage_result.gd
# 跳字/遥测/GameFeel 共源（B_spec M-12 契约）
class_name DamageResult
extends RefCounted

var final_value: float = 0.0
var is_crit: bool = false
var killed: bool = false
var element: int = 0
var immune: bool = false                      # 元素免疫命中（R22 P1：伤害归零 +「免疫」跳字）
var source_uid: int = 0
var target_uid: int = 0
var frame_stamp: int = 0
var pos: Vector2 = Vector2.ZERO               # 跳字位置
var panel_snapshot: float = 0.0               # S（面板段终值；反应/DOT 快照源）
var mult_product: float = 1.0                 # 钳制后乘区段
var local_product: float = 1.0
var target_factor: float = 1.0                # (1−r) × 状态修正
var pool_breakdown: Dictionary = {}           # pool_id -> agg（乘区明细，M2 HUD 峰值统计）
var feel_level: int = 0                       # GameConst.FeelLevel（HIT/CRIT/CATALYST）
var popup_style: int = 0                      # GameConst.PopupStyle
var target_tags: int = 0                      # 目标实体 tags 快照 (TAG_BOSS/TAG_ELITE，供跳字分簇判定)
var audit: DamageAudit = null
var deferred_merge: bool = false              # R223 刀R：预算顺延占位结果（final=0/不落血/
                                              # 不入派发队；真实伤害并入后续冲刷结算——调用方
                                              # 穿透/节拍照常消费，同「无管线防御」零值先例）

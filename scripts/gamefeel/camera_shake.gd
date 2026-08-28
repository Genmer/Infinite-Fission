# scripts/gamefeel/camera_shake.gd
# M-15 CameraShake（架构 §2.14）：trauma 模型震屏（纯计算，无 Camera2D 依赖——偏移量
# 由 GameLoop/表现层应用到相机；headless 可测）。
# 数值真源：GameFeelConfig（data/gamefeel/game_feel_config.tres，pkg0 锁定
# shake_max_offset_px=8 / shake_max_rot_deg=1.5 / shake_decay_s=0.4；B_spec Q-12 裁定）。
# trauma ∈ [0,1]，偏移 = trauma² 映射（GDC 标准 trauma 模型，AC-15.3）。
class_name CameraShake
extends RefCounted

var trauma: float = 0.0                       # 0~1（trauma² 映射偏移）
var max_offset: Vector2 = Vector2(8.0, 8.0)   # 上限 px（setup 注入 config）
var max_rot_deg: float = 1.5                  # 上限角度（setup 注入 config）
var decay_s: float = 0.4                      # 衰减时长 s（0.4s 内衰减到 0，AC-15.3）

var _noise_t: float = 0.0                     # 噪声相位（raw 通道推进；高频抖动观感）


func setup(p_max_offset_px: float, p_max_rot_deg: float, p_decay_s: float) -> void:
	# 数值注入（GameFeelConfig 快照）
	max_offset = Vector2(p_max_offset_px, p_max_offset_px)
	max_rot_deg = p_max_rot_deg
	decay_s = maxf(p_decay_s, 0.01)


func add(p_amount: float) -> void:
	# 叠加输入，clamp 1.0（分级 trauma 由 GameFeelDirector 按 config 档位传入）
	trauma = clampf(trauma + maxf(p_amount, 0.0), 0.0, 1.0)


func offset_and_rotation() -> Vector3:
	# 输出 (offset: Vector2, rot: float) 打包 Vector3(x, y, rot_deg)：trauma² 噪声映射，
	# 上限 8px + 1.5°（Q-12）；trauma=0 → 全零（无开销路径）
	if trauma <= 0.0:
		return Vector3.ZERO
	var amp := trauma * trauma
	var ox := maxf(minf(_noise(_noise_t * 31.7), 1.0), -1.0) * amp * max_offset.x
	var oy := maxf(minf(_noise(_noise_t * 27.3 + 13.1), 1.0), -1.0) * amp * max_offset.y
	var rot := maxf(minf(_noise(_noise_t * 23.9 + 41.7), 1.0), -1.0) * amp * deg_to_rad(max_rot_deg)
	return Vector3(ox, oy, rot)


func tick(p_raw_delta: float) -> void:
	# 0.4s 线性衰减到 0（AC-15.3）；raw 通道（顿帧期间震屏照常衰减，Q-14）
	_noise_t += p_raw_delta
	if trauma > 0.0:
		trauma = maxf(trauma - p_raw_delta / decay_s, 0.0)


func _noise(p_x: float) -> float:
	# 轻量伪噪声（sin 叠加；程序化占位，无需 RandomNumberGenerator 状态）
	return sin(p_x * 12.9898) * 0.5 + sin(p_x * 4.898 + 1.7) * 0.5

# scripts/ui/cloud_backdrop.gd
# 方向 C「晴空糖果」全局氛围：淡云背景（3 层大圆/胶囊云缓动漂移，程序化）。
# 白云贴图共享 TextureFactory 缓存；每层仅位置漂移 + 轻微浮动（_process，视觉层零逻辑依赖）。
# 兼任默认清屏色设置（淡云蓝白 #EEF3FF）。不加重 shader——亮底风格靠形状与动效。
class_name CloudBackdrop
extends Node2D

# 漂移层配置：[云数, 缩放范围, 漂移速度 px/s, 透明度, y 带（占屏比）]
const LAYERS := [
	{"count": 4, "scale": Vector2(2.6, 4.2), "speed": 9.0, "alpha": 0.30, "y_band": Vector2(0.04, 0.9)},
	{"count": 5, "scale": Vector2(1.4, 2.2), "speed": 16.0, "alpha": 0.42, "y_band": Vector2(0.03, 0.95)},
	{"count": 4, "scale": Vector2(0.8, 1.3), "speed": 26.0, "alpha": 0.5, "y_band": Vector2(0.02, 0.98)},
]
const SCREEN := Vector2(720.0, 1280.0)
const WRAP_MARGIN := 240.0                    # 云宽余量（出屏回绕）

var _drifts: Array[Dictionary] = []           # {node: Sprite2D, speed: float, phase: float, base_y: float}
var _elapsed: float = 0.0
var base_z: int = -20                         # 世界底层（玩家 z6 之下）；菜单内复用时置 0（盖住底色）


func _ready() -> void:
	z_index = base_z
	RenderingServer.set_default_clear_color(PopPalette.BG)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260828                          # 确定性铺云（观感稳定，不涉玩法 RNG）
	for li in range(LAYERS.size()):
		var cfg: Dictionary = LAYERS[li]
		for i in range(int(cfg["count"])):
			var sprite := Sprite2D.new()
			sprite.name = "Cloud_%d_%d" % [li, i]
			sprite.texture = TextureFactory.cloud()
			sprite.modulate = Color(1.0, 1.0, 1.0, float(cfg["alpha"]))
			var band: Vector2 = cfg["y_band"]
			sprite.position = Vector2(
				rng.randf_range(-WRAP_MARGIN, SCREEN.x + WRAP_MARGIN),
				SCREEN.y * rng.randf_range(band.x, band.y))
			var s: float = rng.randf_range(cfg["scale"].x, cfg["scale"].y)
			sprite.scale = Vector2(s, s)
			if rng.randf() < 0.5:
				sprite.flip_h = true              # 翻面去重复感
			add_child(sprite)
			_drifts.append({
				"node": sprite,
				"speed": float(cfg["speed"]) * rng.randf_range(0.8, 1.25),
				"phase": rng.randf_range(0.0, TAU),
				"base_y": sprite.position.y,
			})


func _process(p_delta: float) -> void:
	# 缓动漂移：横向匀速 + 纵向正弦浮动（视觉层；顿帧/暂停期间照常，Q-14 同口径）
	_elapsed += p_delta
	for drift: Dictionary in _drifts:
		var sprite: Sprite2D = drift["node"]
		sprite.position.x += float(drift["speed"]) * p_delta
		sprite.position.y = float(drift["base_y"]) + sin(_elapsed * 0.7 + float(drift["phase"])) * 6.0
		if sprite.position.x > SCREEN.x + WRAP_MARGIN:
			sprite.position.x = -WRAP_MARGIN

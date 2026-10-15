# tests/qa_r272_unpoison.gd
# 一次性盘档清毒脚本（R272 批实锤：套件 cleanup 只清内存键未落盘，盘档
# perf_boost=1 残留毒倒同批后跑套件——r214 三红/qa_r269 a1 红）。跑法同套件。
# 定位（R272 评审#8）：**应急工具**——常态防线=套件 cleanup 快照还原+落盘
# （qa_r272_enemylazy_cases._cleanup 已内置，qa_r269 同款），本口仅排查/救急用，
# 非例行步骤。毒签名口径：**盘档值==1** 才是真毒（boost_mode 开）；「键存在」
# 不算——Meta._ready 的 _boost_pad_defaults 每进程往内存垫 perf_boost=0（headless，
# 设计口径不落盘），检测内存键会把垫值误报成毒。清毒即清盘档键并 _save() 落盘。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引，Meta 经 /root 运行时取。
extends SceneTree


func _initialize() -> void:
	await process_frame
	await process_frame
	var meta: Node = get_root().get_node_or_null("Meta")
	if meta == null:
		print("UNPOISON | Meta autoload 未注册——非工程态运行，无盘档可清")
		quit(0)
		return
	var settings: Dictionary = meta.get("_settings")
	var poisoned: bool = int(settings.get("perf_boost", 0)) == 1
	if poisoned:
		settings.erase("perf_boost")
		meta.call(&"_save")
	print("UNPOISON | 盘档 perf_boost 真毒（值==1）=%s → %s" % [str(poisoned),
		"已清除并落盘" if poisoned else "盘净无需清"])
	quit(0)

extends RefCounted
# 一次性诊断体：只读本地档现状（不动任何状态）


func run(p_tree: SceneTree) -> void:
	var ids: Array[String] = []
	for k: Variant in Meta.codex_traits.keys():
		ids.append(String(k))
	ids.sort()
	print("本地档 codex_traits=%s blessing_trait=%s" % [str(ids), String(Meta.blessing_trait())])

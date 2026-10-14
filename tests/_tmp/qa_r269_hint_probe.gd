# tests/_tmp/qa_r269_hint_probe.gd
# R269 修2 QA 探针 v2：hint 四行几何精查（修正 theme 项名 font_size；size 归因；
# 与代码外新建对照 label 隔离量测单行高）。
extends SceneTree

func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ QA 探针 v2：R269 修2 hint 四行几何精查 ══════════")
	await process_frame
	await process_frame
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var gl: Node = null
	for c in root.get_children():
		if c != null and c.has_method("diag_counts"):
			gl = c
			break
	await process_frame
	await process_frame
	var sp: Node = gl.get("settings_panel")
	sp.call("open")
	await process_frame
	await process_frame
	var card: Node = sp.get("_card")
	var hint: Label = null
	var close_btn: Control = null
	for kid in card.get_children():
		var l := kid as Label
		if l != null and String(l.text).begins_with("设置即存"):
			hint = l
		if String(kid.name) == "SettingsCloseButton":
			close_btn = kid as Control
	if hint == null or close_btn == null:
		print("FAIL | 控件未找到")
		quit(1)
		return
	# ── 面板内实测 ──
	var fsize: int = hint.get_theme_font_size("font_size")
	var font: Font = hint.get_theme_font("font")
	var line_h: float = font.get_height(fsize)
	var need: Vector2 = hint.get_minimum_size()
	var lines: int = hint.get_line_count()
	print("[面板内] override=%s  effective_size=%d  font.get_height(%d)=%.2f" % [
		str(hint.has_theme_font_size_override("font_size")), fsize, fsize, line_h])
	print("[面板内] 行数=%d  get_minimum_size=%s  （min.y/行数=%.2f）" % [lines, str(need), need.y / float(maxi(lines, 1))])
	print("[面板内] hint.position=%s  hint.size=%s  valign=%d（0=顶）" % [str(hint.position), str(hint.size), hint.vertical_alignment])
	var text_bottom: float = hint.position.y + need.y
	print("[面板内] 文本块底=%.2f  关闭钮顶=%.2f 钮底=%.2f 侵入=%.2fpx" % [
		text_bottom, close_btn.position.y, close_btn.position.y + close_btn.size.y, text_bottom - close_btn.position.y])
	# ── 隔离对照：同参数新建 label（挂卡外），验证 size 是否被面板内逻辑改动 ──
	var ctrl := Label.new()
	var theme_lib: GDScript = load("res://scripts/ui/theme.gd")
	theme_lib.call("label_sticker", ctrl, 11, Color(1, 1, 1, 1))
	ctrl.text = "行一\n行二\n行三\n行四"
	(card as Node).add_child(ctrl)
	ctrl.position = Vector2(0.0, -200.0)
	ctrl.size = Vector2(620.0, 52.0)
	print("[对照] 新建(4行@11) size赋值52后实读=%s  min=%s  get_height=%s" % [
		str(ctrl.size), str(ctrl.get_minimum_size()), str(font.get_height(11))])
	ctrl.free()
	print("判定：文本底 %.2f %s 关闭钮顶 %.2f" % [text_bottom, "<=" if text_bottom <= close_btn.position.y else ">", close_btn.position.y])
	quit(0)

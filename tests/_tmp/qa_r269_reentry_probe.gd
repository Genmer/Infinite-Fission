# tests/_tmp/qa_r269_reentry_probe.gd
# R269 QA 抽查探针：bucket_begin/bucket_end 深度计数可重入语义（嵌套采集不串桶）。
# 覆盖设计 §3.6「同键嵌套=深度计数可重入（外层 span 全含内层工作，只记外层=正确归因，
# 内层吸收不双计）」——qa_r269_bucketprobe 未含显式重入断言，本探针独立补面。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；运行期经 /root/DebugStats 取实例。
extends SceneTree

var _pass: int = 0
var _fail: int = 0


func _initialize() -> void:
	_run()


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		print("  FAIL | %s（%s）" % [p_name, p_detail])


func _run() -> void:
	print("══════════ QA 探针：R269 桶可重入语义（深度计数） ══════════")
	await process_frame
	var ds: Node = root.get_node_or_null("/root/DebugStats")
	if ds == null:
		print("FAIL | DebugStats autoload 未就绪")
		quit(1)
		return
	ds._diag_reset_window_acc()
	# 桶字典清零后静态累计器同步清（_diag_bucket_us 为 static——经实例 clear 同一存储）
	# A. 同键嵌套：内层收口不入账（吸收），外层收口一次入账
	ds.bucket_begin(&"t1")
	ds.bucket_begin(&"t1")
	OS.delay_msec(20)
	ds.bucket_end(&"t1")
	_check("A1 同键嵌套：内层 end 后不入账（窗口仍 0——内层吸收不双计）",
		int(ds.diag_bucket_window_us(&"t1")) == 0,
		"win=%d" % int(ds.diag_bucket_window_us(&"t1")))
	ds.bucket_end(&"t1")
	_check("A2 同键嵌套：外层 end 后一次入账（win>0）",
		int(ds.diag_bucket_window_us(&"t1")) > 0,
		"win=%d" % int(ds.diag_bucket_window_us(&"t1")))
	# B. 三层嵌套：中间层也不入账
	ds._diag_reset_window_acc()
	ds.bucket_begin(&"t2")
	ds.bucket_begin(&"t2")
	ds.bucket_begin(&"t2")
	OS.delay_msec(20)
	ds.bucket_end(&"t2")
	ds.bucket_end(&"t2")
	_check("B1 三层嵌套：内两层 end 后窗口仍 0",
		int(ds.diag_bucket_window_us(&"t2")) == 0, "")
	ds.bucket_end(&"t2")
	_check("B2 三层嵌套：最外层 end 后入账一次",
		int(ds.diag_bucket_window_us(&"t2")) > 0, "")
	# C. 跨键隔离：t3/t4 并发开桶互不串
	ds._diag_reset_window_acc()
	ds.bucket_begin(&"t3")
	ds.bucket_begin(&"t4")
	OS.delay_msec(20)
	ds.bucket_end(&"t4")
	_check("C1 跨键隔离：t4 先收 → t4>0 而 t3 仍在飞未入账",
		int(ds.diag_bucket_window_us(&"t4")) > 0
			and int(ds.diag_bucket_window_us(&"t3")) == 0,
		"t3=%d t4=%d" % [int(ds.diag_bucket_window_us(&"t3")), int(ds.diag_bucket_window_us(&"t4"))])
	ds.bucket_end(&"t3")
	_check("C2 跨键隔离：t3 后收独立入账",
		int(ds.diag_bucket_window_us(&"t3")) > 0, "")
	# D. 无 begin 的裸 end：防脏直返（不崩溃/不入账/不产生负深度）
	var before: int = int(ds.diag_bucket_window_us(&"t5"))
	ds.bucket_end(&"t5")
	ds.bucket_end(&"t5")
	_check("D1 裸 end×2 不崩溃不入账（win 不变）",
		int(ds.diag_bucket_window_us(&"t5")) == before, "")
	# E. 嵌套收净后新一轮 begin 干净起点（无残留深度阻塞入账）
	ds._diag_reset_window_acc()
	ds.bucket_begin(&"t6")
	OS.delay_msec(20)
	ds.bucket_end(&"t6")
	_check("E1 嵌套轮回后新 begin/end 正常入账（深度清零无残留）",
		int(ds.diag_bucket_window_us(&"t6")) > 0, "")
	# F. 秒窗复位不清在飞 begin：迟收样本入新窗
	ds._diag_reset_window_acc()
	ds.bucket_begin(&"t7")
	ds._diag_reset_window_acc()
	OS.delay_msec(20)
	ds.bucket_end(&"t7")
	_check("F1 复位不清在飞 span：迟收样本入新窗（win>0）",
		int(ds.diag_bucket_window_us(&"t7")) > 0, "")
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])
	quit(1 if _fail > 0 else 0)

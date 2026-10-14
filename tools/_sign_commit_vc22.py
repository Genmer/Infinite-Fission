# R214 应急签名提交：Godot 导出成功但导出内签名受 C 盘 ENOSPC 阻塞（java.io.tmpdir）。
# 用手动 apksigner 签名产物（同 keystore/参数）替代导出内签名，其余完全复用
# export_apk_versioned 的 bump/gate/回滚契约。
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import export_apk_versioned as ev

SIGNED = Path("E:/Code/Agent/Infinite-Fission/android_export/tmp/vc22_signed.apk")

orig_text = ev.PRESETS.read_text(encoding="utf-8")
orig_proj = ev.PROJECT_GODOT.read_text(encoding="utf-8")
committed = False
try:
    text, code, name = ev.bump_version(orig_text)
    ev.PRESETS.write_text(text, encoding="utf-8")
    ev.PROJECT_GODOT.write_text(ev.write_project_version(orig_proj, name, code), encoding="utf-8")
    print(f"版本已迭代（导出期临时态）：versionCode={code} versionName={name}")
    out_apk = ev.OUT_DIR / f"InfiniteFission_v{name}_vc{code}.apk"
    assert code == 22 and name == "0.1.21", f"版本不符预期 vc22: {code} {name}"
    shutil.copyfile(SIGNED, out_apk)
    if not ev.gate(out_apk, code, name):
        sys.exit(1)
    committed = True
    print("签名提交完成：committed")
    sys.exit(0)
finally:
    if not committed:
        ev.PRESETS.write_text(orig_text, encoding="utf-8")
        ev.PROJECT_GODOT.write_text(orig_proj, encoding="utf-8")
        print("版本号已回滚")

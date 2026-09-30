# -*- coding: utf-8 -*-
"""R194 起的 APK 交付导出器：文件名带版本号 + 版本每交付迭代 + Defender 竞态重试 + 三重门禁。

用法（repo/tools 下，cwd 无关）：
  python export_apk_versioned.py            # 按当前 preset 版本导出并门禁
  python export_apk_versioned.py --bump     # 先迭代版本（code+1、name 第三位+1）再导出

产物：android_export/out/InfiniteFission_v<versionName>_vc<versionCode>.apk（+ .idsig）
门禁：清单 screenOrientation==1 / apksigner verify / arm64-v8a 独占 / 无 export_presets.cfg
     / assets/data/*.cfg 在包 / 24~48MiB / 清单版本==文件名版本。
约定（FEEDBACK_TRACKER 二be #5）：每交付一包，版本号严格迭代一次（--bump 手动触发）；
版本号永不再用 0.1.0（R193/R194 早期包已占用，无法区分）。
R198 工具-bump（含 r195-7）：--bump 的版本写盘降级为「导出期临时态」——导出+门禁全绿
才提交；工具链缺失 / 导出失败（Defender 4 次重试均败）/ Ctrl+C / 门禁红统一按读盘
快照回滚，失败 run 不消费版本号（重试不二跳：下次 --bump 重取同号，产物文件名相同
直接覆盖旧产物，.idsig 同名同覆写）。Defender 重试环不动（4 次重试共用临时态版本，
presets 每 run 写一次/回滚一次，不进重试内层）。
"""
import os
import re
import shutil
import subprocess
import sys
import time
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
WS = REPO.parent
AX = WS / "android_export"
GODOT = AX / "Godot_v4.3-stable_win64.exe"
AAPT2 = AX / "android-sdk" / "build-tools" / "34.0.0" / "aapt2.exe"
APKSIGNER_JAR = AX / "android-sdk" / "build-tools" / "34.0.0" / "lib" / "apksigner.jar"
JAVA = Path(r"E:/Code/Env/jdk17/bin/java.exe")
PRESETS = REPO / "export_presets.cfg"
OUT_DIR = AX / "out"
LOG = OUT_DIR / "export_versioned.log"
TMP_GLOB = "tmpexport-unaligned.*.apk"
TRIES = 4
RETRY_GAP_S = 12

# R198 工具-a12-emoji（含 r196-2）：A12 轻量镜像依赖 zstd 解包（模块缺失时 A12 子集记
# FAIL，对齐 export_artifact_gate.py A6「锚点缺失=FAIL」硬锚先例，禁 WARN 跳过）
try:
    import compression.zstd as _zstd
except ImportError:                                # Python<3.14 等无 zstd 标准库环境
    _zstd = None
# A12 探针正则（与 export_artifact_gate.py 同源口径）：F0 9F [80-BF]{2} =
# U+1F000–U+1FFFF 全 emoji 块；F0 A0+ 半边在 float32 Variant 载荷有纯二进制假阳
# （F0 B6 B6 B6 ×370 实测），首版不纳入必红断言——全量断言组在 export_artifact_gate.py
RE_EMOJI_F09F = re.compile(rb"\xf0\x9f[\x80-\xbf]{2}")


def read_version(text: str):
    m_code = re.search(r"^version/code=(\d+)", text, re.M)
    m_name = re.search(r'^version/name="([^"]+)"', text, re.M)
    if not m_code or not m_name:
        raise SystemExit("export_presets.cfg 缺 version/code 或 version/name")
    return int(m_code.group(1)), m_name.group(1)


def bump_version(text: str):
    code, name = read_version(text)
    parts = name.split(".")
    parts[-1] = str(int(parts[-1]) + 1)
    new_name = ".".join(parts)
    text = re.sub(r"^version/code=\d+", f"version/code={code + 1}", text, count=1, flags=re.M)
    text = re.sub(r'^version/name="[^"]+"', f'version/name="{new_name}"', text, count=1, flags=re.M)
    return text, code + 1, new_name


def run(cmd, **kw):
    return subprocess.run([str(c) for c in cmd], capture_output=True, text=True, **kw)


def count_repo_gd_scripts() -> int:
    """repo 非测试 .gd 计数（R196 A10 对账基线；排除 tests/.godot/.zcode，与
    export_artifact_gate.py 同口径）。"""
    n = 0
    for root, dirs, files in os.walk(REPO):
        rel = os.path.relpath(root, REPO)
        parts = [] if rel == "." else rel.split(os.sep)
        if "tests" in parts:
            dirs[:] = []
            continue
        dirs[:] = [d for d in dirs if d not in (".godot", ".zcode", "tests")]
        n += sum(1 for f in files if f.endswith(".gd"))
    return n


def export_with_retry(out_apk: Path) -> bool:
    for attempt in range(1, TRIES + 1):
        for stale in OUT_DIR.parent.glob(f"editor_data/cache/{TMP_GLOB}"):
            stale.unlink(missing_ok=True)  # Defender 瞬时锁竞态：清残留再战
        if attempt > 1:
            time.sleep(RETRY_GAP_S)
        with open(LOG, "a", encoding="utf-8", errors="replace") as lf:
            lf.write(f"\n=== attempt {attempt} ===\n")
            r = run([GODOT, "--headless", "--path", REPO, "--export-release",
                     "Android", out_apk], timeout=900)
            lf.write((r.stdout or "") + "\n[stderr]\n" + (r.stderr or ""))
        print(f"导出第 {attempt} 次尝试：exit={r.returncode}")
        if r.returncode == 0:
            return True
    return False


def gate(out_apk: Path, code: int, name: str) -> bool:
    checks = []
    ok = True

    def check(label: str, passed: bool, detail: str = "") -> None:
        nonlocal ok
        checks.append((label, passed, detail))
        ok = ok and passed

    a = run([AAPT2, "dump", "xmltree", "--file", "AndroidManifest.xml", out_apk])
    m = re.search(r"screenOrientation\(0x0101001e\)=(\d+)", a.stdout)
    check("清单竖屏 screenOrientation=1", bool(m) and m.group(1) == "1",
          m.group(0) if m else "无该属性行")
    m_vc = re.search(r"versionCode\(0x0101021b\)=(\d+)", a.stdout)
    check("清单 versionCode==文件名 vc", bool(m_vc) and int(m_vc.group(1)) == code,
          m_vc.group(0) if m_vc else "无")
    m_vn = re.search(r'versionName\(0x0101021c\)="([^"]+)"', a.stdout)
    check("清单 versionName==文件名 v", bool(m_vn) and m_vn.group(1) == name,
          m_vn.group(0) if m_vn else "无")
    g = run([AAPT2, "dump", "badging", out_apk])
    check("badging 无 landscape", "landscape" not in g.stdout)

    s = run([JAVA, "-jar", APKSIGNER_JAR, "verify", out_apk])
    check("apksigner verify", s.returncode == 0, (s.stdout or s.stderr).strip()[:120])

    size = out_apk.stat().st_size
    check("体积 24~48MiB", 24 * 1024 * 1024 <= size <= 48 * 1024 * 1024, f"{size}B")
    with zipfile.ZipFile(out_apk) as z:
        names = z.namelist()
        abis = {n.split("/")[1] for n in names if n.startswith("lib/")}
        check("abis==arm64-v8a", abis == {"arm64-v8a"}, str(sorted(abis)))
        check("无 export_presets.cfg 泄露", not any("export_presets" in n for n in names))
        check("assets/data/manifest.cfg 在包", "assets/data/manifest.cfg" in names)
        check("assets/data/balance/global_constants.cfg 在包",
              "assets/data/balance/global_constants.cfg" in names)
        # R196 轻量子集（apk_menu_no_icons 定案 T10；全量 A8~A11 在 export_artifact_gate.py）
        gated = ["assets/scripts/ui/%s.gdc" % s for s in
                 ("texture_factory", "menu_screen", "hud", "theme", "palette")]
        missing_gated = [g for g in gated if g not in names]
        check("五生成链 .gdc 在包（A8 子集）", not missing_gated,
              "缺失=%s" % missing_gated if missing_gated else "在包=5/5")
        n_gdc = sum(1 for n in names if n.endswith(".gdc"))
        n_repo = count_repo_gd_scripts()
        check(".gdc 计数==repo 非测试 .gd 计数（A10 子集）", n_gdc == n_repo,
              "包内=%d repo=%d" % (n_gdc, n_repo))
        # R198 轻量子集（工具-a12-emoji，含 r196-2；全量 A12 断言组在
        # export_artifact_gate.py）：只扫五生成链 .gdc——解压完整性（头第 3 个 uint32
        # 声明解压尺寸==实长）+ 零 emoji 四字节组（F0 9F 半边，U+1F000–U+1FFFF）
        if _zstd is None:
            check("五生成链 .gdc 解包零 emoji（A12 子集）", False,
                  "compression.zstd 模块缺失（硬 FAIL，禁 WARN 跳过）")
        else:
            bad_chain = []
            for g in gated:
                raw = z.read(g)
                frame_at = raw.find(b"\x28\xb5\x2f\xfd")
                if frame_at < 0:
                    bad_chain.append(g + ":无zstd帧")
                    continue
                try:
                    data = _zstd.decompress(raw[frame_at:])
                except Exception as exc:            # 帧损坏/截断
                    bad_chain.append("%s:解压失败(%s)" % (g, exc))
                    continue
                declared = int.from_bytes(raw[8:12], "little")
                if declared != len(data):
                    bad_chain.append("%s:声明%d≠实长%d" % (g, declared, len(data)))
                elif RE_EMOJI_F09F.search(data):
                    bad_chain.append(g + ":emoji命中")
            check("五生成链 .gdc 解包零 emoji（A12 子集）", not bad_chain,
                  "违规=%s" % bad_chain if bad_chain else "在包=5/5 全净")

    print("── 门禁 ──")
    for label, passed, detail in checks:
        print(f"  {'PASS' if passed else 'FAIL'}  {label}" + (f"（{detail}）" if detail and not passed else ""))
    print(f"汇总：{'%d' % len(checks)} 项中 {sum(1 for _, p, _ in checks if p)} 过；包={out_apk}")
    return ok


def main() -> int:
    # R198 工具-bump（含 r195-7）：读盘快照 + try/finally 快照回滚式提交——
    # --bump 写盘只是导出期临时态，export_with_retry 成功且 gate() 全绿才 committed=True；
    # 其余任何失败路径（:155 工具链缺失 SystemExit / 导出 4 次均败 / Ctrl+C /
    # 门禁红）在 finally 按 orig_text 逐字节回滚，版本号不烧号（重试不二跳）。
    orig_text = PRESETS.read_text(encoding="utf-8")
    text = orig_text
    committed = False
    try:
        if "--bump" in sys.argv:
            text, code, name = bump_version(text)
            # 导出期临时态：失败由 finally 回滚快照（R198 工具-bump）
            PRESETS.write_text(text, encoding="utf-8")
            print(f"版本已迭代（导出期临时态，门禁全绿前可回滚）：versionCode={code} versionName={name}")
        else:
            code, name = read_version(text)
            print(f"当前版本：versionCode={code} versionName={name}")
        out_apk = OUT_DIR / f"InfiniteFission_v{name}_vc{code}.apk"
        if not all(p.exists() for p in (GODOT, AAPT2, APKSIGNER_JAR, JAVA)):
            missing = [p for p in (GODOT, AAPT2, APKSIGNER_JAR, JAVA) if not p.exists()]
            raise SystemExit(f"工具链缺失：{missing}")
        if not export_with_retry(out_apk):
            print(f"汇总：导出 {TRIES} 次均失败，日志={LOG}")
            return 1
        if not gate(out_apk, code, name):
            return 1
        committed = True                            # 导出+门禁全绿：版本号正式提交
        return 0
    finally:
        if "--bump" in sys.argv and not committed:
            PRESETS.write_text(orig_text, encoding="utf-8")
            print("版本号已回滚，下次 --bump 重取同号")


if __name__ == "__main__":
    sys.exit(main())

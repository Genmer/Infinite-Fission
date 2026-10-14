# -*- coding: utf-8 -*-
"""R194 导出产物门禁（组1·移动配置持有；组6 T5 复用同脚本对旧/新包双跑留痕）。

用法:
    python tools/export_artifact_gate.py <apk路径> [--template 模板apk] [--aapt2 aapt2路径]

断言集（任一 FAIL → exit 1）:
  ZIP 级:
    A1 三份 data .cfg 在包（spawn RC1：all_resources 只收 Resource，
       include_filter="*.cfg" 缺位则 registry 静默空表——bug#4 根因链头）
    A2 ABI 独占 arm64-v8a（lib/ 条目集合 == {"arm64-v8a"}）
    A3 assets/tests/ 条目 == 0（headless 测试电池不进包，exclude_filter="tests/*"）
    A4 包内零 disc1_wave_probe 条目（根目录草探针不得漏进包，裁定 #6）
    A5 包体 25165824 ≤ size ≤ 50331648（24~48 MiB 带宽）
    A6 成品 res/mipmap/icon.png sha256 ≠ 模板同路径哈希（launcher_icons 接线生效，
       旧包/模板同为 Godot 默认图标 cc19ae61…）
    A7 包内零 export_presets.cfg 条目（R194 修复环：include_filter 通配 *.cfg 曾把
       根级预设——含 release keystore 路径/用户名/密码——打包为 assets/export_presets.cfg）
    A8 五生成链 .gdc 在包（R196：texture_factory/menu_screen/hud/theme/palette——
       程序贴纸生成链缺一即 APK「只有字」类回归，apk_menu_no_icons 定案 T10）
    A9 启动器 3+1 张贴图 .import 在包 + .ctex 计数锚定 4（icon_192/icon_bg_432/
       icon_fg_432 + design_sheet；新增导入资源须同步抬锚）
    A10 包内 .gdc 计数 == repo 非测试 .gd 计数（导出完整性对账——脚本漏导/多导即红；
       基线动态统计 repo 侧，当前 99）
    A11 .gd.remap 与 .gdc 按 assets/ 词干一一对应（remap 缺失 → 启动期脚本加载崩）
    A12 零 emoji 字节探针（R198 工具-a12-emoji，含 r196-2）：assets/**/*.gdc 全量
       zstd 解包（完整性=头第 3 个 uint32 声明解压尺寸==实长）后正则
       b"\xf0\x9f[\x80-\xbf]{2}"（U+1F000–U+1FFFF 全 emoji 块）命中数必须 0；
       compression.zstd 模块缺失 → A12 记 FAIL（对齐 A6「模板缺失=FAIL」硬锚先例，
       禁 WARN 跳过）。P1 源码扫描盲区 tools/gen_music.gd（打包为
       assets/tools/gen_music.gdc）由本断言字节级全量扫描天然补齐
  清单级（aapt2 可用时；不可用打印 WARN 跳过——四步门禁第②步另跑全量断言）:
    B1 activity screenOrientation(0x0101001e)=1（锚定式，宽松 .* 版已实证假通过，禁用）
    B2 badging landscape 行计数 == 0
    B3 基线不回退：configChanges(0x0101001f)=0x00001ff0 且 resizeableActivity(0x010104f6)=true
"""
import argparse
import hashlib
import os
import re
import subprocess
import sys
import zipfile

# R198 工具-a12-emoji（含 r196-2）：A12 零 emoji 字节探针依赖 zstd 解包 .gdc。
# 模块缺失不跳过——对齐 A6「模板缺失=FAIL」硬锚先例，A12 直接记 FAIL（禁 WARN）。
try:
    import compression.zstd as _zstd
except ImportError:                                # Python<3.14 等无 zstd 标准库环境
    _zstd = None

# A12 探针正则：F0 9F [80-BF]{2} = U+1F000–U+1FFFF 全 emoji 块（UTF-8 四字节组首半边）。
# 首版只硬断言 F0 9F 半边——已覆盖历史案发码位段：💎U+1F48E / 🔒U+1F512 / 🏆U+1F3C6
# 及 U+1FA70+ 全部；F0 A0+ 半边（U+20000+）在 float32 Variant 载荷有纯二进制假阳
# （绿包实测 F0 B6 B6 B6 ×370 命中），无护栏上下文不纳入必红断言（R198 定案口径留证）。
RE_EMOJI_F09F = re.compile(rb"\xf0\x9f[\x80-\xbf]{2}")
ZSTD_FRAME_MAGIC = b"\x28\xb5\x2f\xfd"
GDC_HEADER_DECLARED_SIZE_AT = 8   # 「GDSC」+uint32 version=100+uint32 解压尺寸+zstd 帧

SIZE_MIN = 25165824  # 24 MiB
SIZE_MAX = 50331648  # 48 MiB

REQUIRED_CFGS = [
    "assets/data/manifest.cfg",
    "assets/data/balance/global_constants.cfg",
    "assets/data/version.cfg",
]
ICON_ENTRY = "res/mipmap/icon.png"

# R196 新增锚点（apk_menu_no_icons 定案 T10：纯新增，不放宽既有 A1~A7/B1~B3）
# A8 五生成链 .gdc（TextureFactory 程序贴纸链 + 菜单/HUD/主题/调色）
GATED_GDC_CHAIN = [
    "assets/scripts/ui/texture_factory.gdc",
    "assets/scripts/ui/menu_screen.gdc",
    "assets/scripts/ui/hud.gdc",
    "assets/scripts/ui/theme.gdc",
    "assets/scripts/ui/palette.gdc",
]
# A9 启动器贴图 3+1 张（.import 在包 + .ctex 计数基线；全仓被导入贴图现值恰 4 张）
LAUNCHER_IMPORTS = [
    "assets/assets/icons/icon_192.png.import",
    "assets/assets/icons/icon_bg_432.png.import",
    "assets/assets/icons/icon_fg_432.png.import",
    "assets/design_sheet.png.import",
]
LAUNCHER_CTEX_COUNT = 4

# 锚定式正则（aapt2 dump xmltree 实测行格式，行尾精确值——禁宽松 .* 版；
# re.M 必带：对整段 stdout 检索，$ 须按"行尾"语义）
RE_ORIENTATION = re.compile(r"screenOrientation\(0x0101001e\)=1$", re.M)
RE_CONFIG_CHANGES = re.compile(r"configChanges\(0x0101001f\)=0x00001ff0$", re.M)
RE_RESIZEABLE = re.compile(r"resizeableActivity\(0x010104f6\)=true$", re.M)

# 脚本位于 <工作区>/repo/tools/，android_export/ 在工作区根（上两级）
WORKSPACE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_TEMPLATE = os.path.join(
    WORKSPACE, "android_export", "editor_data", "export_templates",
    "4.3.stable", "android_release.apk")
DEFAULT_AAPT2 = os.path.join(
    WORKSPACE, "android_export", "android-sdk", "build-tools",
    "34.0.0", "aapt2.exe")


def count_repo_gd_scripts():
    """repo 非测试 .gd 计数（A10 对账基线；排除 tests/.godot/.zcode）。"""
    repo = os.path.join(WORKSPACE, "repo")
    n = 0
    for root, dirs, files in os.walk(repo):
        rel = os.path.relpath(root, repo)
        parts = [] if rel == "." else rel.split(os.sep)
        if "tests" in parts:
            dirs[:] = []
            continue
        dirs[:] = [d for d in dirs if d not in (".godot", ".zcode", "tests")]
        n += sum(1 for f in files if f.endswith(".gd"))
    return n


def check_zip(apk, template_path):
    """A1~A12：ZIP 级断言（B 级清单断言在 check_manifest）。返回 [(名称, 是否通过, 明细)]。"""
    results = []
    size = os.path.getsize(apk)
    ok_size = SIZE_MIN <= size <= SIZE_MAX
    results.append(("A5 包体带宽 24~48MiB", ok_size, "size=%d (band [%d,%d])" % (size, SIZE_MIN, SIZE_MAX)))

    with zipfile.ZipFile(apk) as z:
        names = set(z.namelist())

        missing = [p for p in REQUIRED_CFGS if p not in names]
        results.append((
            "A1 三份 data .cfg 在包",
            not missing,
            "在包=%d/3" % (len(REQUIRED_CFGS) - len(missing)) + ("；缺失=%s" % missing if missing else ""),
        ))

        abis = set()
        for n in names:
            if n.startswith("lib/"):
                parts = n.split("/")
                if len(parts) >= 2 and parts[1]:
                    abis.add(parts[1])
        results.append((
            "A2 ABI 独占 arm64-v8a",
            abis == {"arm64-v8a"},
            "abis=%s" % sorted(abis),
        ))

        tests_entries = [n for n in names if n.startswith("assets/tests/")]
        results.append(("A3 assets/tests/ 条目==0", not tests_entries,
                        "命中=%s" % tests_entries[:5] if tests_entries else "命中=0"))

        probes = [n for n in names if "disc1_wave_probe" in n]
        results.append(("A4 包内零 disc1_wave_probe 条目", not probes,
                        "命中=%s" % probes[:5] if probes else "命中=0"))

        leaked_presets = [n for n in names if n.endswith("/export_presets.cfg")
                          or n == "export_presets.cfg"]
        results.append(("A7 包内零 export_presets.cfg 条目", not leaked_presets,
                        "命中=%s" % leaked_presets if leaked_presets else "命中=0"))

        # ── R196 增量（apk_menu_no_icons 定案 T10；纯新增，不放宽既有断言） ──
        missing_gdc = [p for p in GATED_GDC_CHAIN if p not in names]
        results.append((
            "A8 五生成链 .gdc 在包",
            not missing_gdc,
            "在包=%d/%d" % (len(GATED_GDC_CHAIN) - len(missing_gdc), len(GATED_GDC_CHAIN))
            + ("；缺失=%s" % missing_gdc if missing_gdc else ""),
        ))

        missing_imp = [p for p in LAUNCHER_IMPORTS if p not in names]
        n_ctex = sum(1 for n in names if n.endswith(".ctex"))
        ok_a9 = not missing_imp and n_ctex == LAUNCHER_CTEX_COUNT
        detail_a9 = "import 在包=%d/%d ctex=%d（基线 %d）" % (
            len(LAUNCHER_IMPORTS) - len(missing_imp), len(LAUNCHER_IMPORTS),
            n_ctex, LAUNCHER_CTEX_COUNT)
        if missing_imp:
            detail_a9 += "；缺失=%s" % missing_imp
        results.append(("A9 启动器 3+1 张 .ctex+.import 在包", ok_a9, detail_a9))

        n_gdc = sum(1 for n in names if n.endswith(".gdc"))
        n_repo_gd = count_repo_gd_scripts()
        results.append(("A10 .gdc 计数==repo 非测试 .gd 计数", n_gdc == n_repo_gd,
                        "包内=%d repo=%d" % (n_gdc, n_repo_gd)))

        gdc_stems = {n[:-4] for n in names if n.endswith(".gdc")}
        remap_stems = {n[:-9] for n in names if n.endswith(".gd.remap")}
        only_gdc = sorted(gdc_stems - remap_stems)
        only_remap = sorted(remap_stems - gdc_stems)
        detail_a11 = "gdc=%d remap=%d" % (len(gdc_stems), len(remap_stems))
        if only_gdc:
            detail_a11 += "；仅gdc=%s" % only_gdc[:3]
        if only_remap:
            detail_a11 += "；仅remap=%s" % only_remap[:3]
        results.append(("A11 .gd.remap↔.gdc 词干一一对应",
                        not only_gdc and not only_remap, detail_a11))

        # ── R198 增量（工具-a12-emoji，含 r196-2）：A12 零 emoji 字节探针 ──
        # .gdc 容器格式（绿包 99/99 实证）：「GDSC」magic + uint32 version=100 +
        # uint32 解压尺寸 + 标准 zstd 帧（0x28 0xB5 0x2F 0xFD）。断言两段：
        # ①完整性：头第 3 个 uint32（偏移 8 的声明解压尺寸）== zstd.decompress 实长；
        # ②零 emoji：解压字节流 RE_EMOJI_F09F 命中数必须 0。
        # 副产物收益：P1 源码扫描盲区 tools/gen_music.gd（打包为
        # assets/tools/gen_music.gdc）由本断言字节级全量扫描天然补齐。
        gdc_all = sorted(n for n in names
                         if n.startswith("assets/") and n.endswith(".gdc"))
        if _zstd is None:
            results.append(("A12 .gdc 全量解包零 emoji（F0 9F 半边）", False,
                            "compression.zstd 模块缺失（对齐 A6 硬锚先例，禁 WARN 跳过）"))
        else:
            bad_integrity = []
            bad_emoji = []
            for n in gdc_all:
                raw = z.read(n)
                frame_at = raw.find(ZSTD_FRAME_MAGIC)
                if frame_at < 0:
                    bad_integrity.append("%s:无zstd帧" % n)
                    continue
                declared = int.from_bytes(
                    raw[GDC_HEADER_DECLARED_SIZE_AT:GDC_HEADER_DECLARED_SIZE_AT + 4],
                    "little")
                try:
                    data = _zstd.decompress(raw[frame_at:])
                except Exception as exc:            # 帧损坏/截断（恶意/漏导态）
                    bad_integrity.append("%s:解压失败(%s)" % (n, exc))
                    continue
                if declared != len(data):
                    bad_integrity.append("%s:声明%d≠实长%d" % (n, declared, len(data)))
                    continue
                if RE_EMOJI_F09F.search(data):
                    bad_emoji.append(n)
            ok_a12 = not bad_integrity and not bad_emoji
            detail_a12 = "解包+扫描=%d/%d" % (len(gdc_all) - len(bad_integrity), len(gdc_all))
            if bad_integrity:
                detail_a12 += "；完整性违规=%s" % bad_integrity[:3]
            if bad_emoji:
                detail_a12 += "；emoji 命中=%s" % bad_emoji[:3]
            results.append(("A12 .gdc 全量解包零 emoji（F0 9F 半边）", ok_a12, detail_a12))

        # A6 图标哈希 ≠ 模板（模板缺失时本检查按 FAIL 处理——模板是门禁锚点，必须在场）
        try:
            with open(template_path, "rb") as f:
                pass
            have_template = True
        except OSError:
            have_template = False
        if not have_template:
            results.append(("A6 图标哈希≠模板", False, "模板缺失: %s" % template_path))
        elif ICON_ENTRY not in names:
            results.append(("A6 图标哈希≠模板", False, "成品缺条目 %s（图标未入包）" % ICON_ENTRY))
        else:
            artifact_sha = hashlib.sha256(z.read(ICON_ENTRY)).hexdigest()
            with zipfile.ZipFile(template_path) as tz:
                template_sha = hashlib.sha256(tz.read(ICON_ENTRY)).hexdigest()
            results.append((
                "A6 图标哈希≠模板",
                artifact_sha != template_sha,
                "artifact=%s… template=%s… %s" % (
                    artifact_sha[:12], template_sha[:12],
                    "(== 模板默认图标，launcher_icons 未生效)" if artifact_sha == template_sha else "(已换新图标)"),
            ))
    return results


def check_manifest(apk, aapt2):
    """B1~B3：清单朝向 + 基线（aapt2）。返回 [(名称, 是否通过, 明细)]；aapt2 不可用返回空。"""
    if not os.path.isfile(aapt2):
        print("WARN: aapt2 不可用（%s），清单级断言跳过——四步门禁第②步须另跑" % aapt2)
        return []
    results = []
    tree = subprocess.run(
        [aapt2, "dump", "xmltree", "--file", "AndroidManifest.xml", apk],
        capture_output=True, text=True)
    if tree.returncode != 0:
        return [("B0 xmltree 可解", False, tree.stderr.strip()[:200])]
    results.append(("B0 xmltree 可解", True, "exit=0"))

    results.append(("B1 screenOrientation=1（锚定）",
                    bool(RE_ORIENTATION.search(tree.stdout)), "锚定正则 %r" % RE_ORIENTATION.pattern))
    results.append(("B3a 基线 configChanges=0x00001ff0",
                    bool(RE_CONFIG_CHANGES.search(tree.stdout)), "G4 基线比对"))
    results.append(("B3b 基线 resizeableActivity=true",
                    bool(RE_RESIZEABLE.search(tree.stdout)), "G4 基线比对"))

    badging = subprocess.run([aapt2, "dump", "badging", apk],
                             capture_output=True, text=True)
    n_land = sum(1 for line in (badging.stdout or "").splitlines()
                 if "landscape" in line.lower())
    results.append(("B2 badging landscape 计数==0", n_land == 0, "计数=%d" % n_land))
    return results


def main():
    ap = argparse.ArgumentParser(description="R194 导出产物门禁")
    ap.add_argument("apk", help="待检 APK 路径")
    ap.add_argument("--template", default=DEFAULT_TEMPLATE, help="模板 APK（图标哈希基准）")
    ap.add_argument("--aapt2", default=os.environ.get("AAPT2", DEFAULT_AAPT2), help="aapt2 路径")
    args = ap.parse_args()

    if not os.path.isfile(args.apk):
        print("FAIL: APK 不存在: %s" % args.apk)
        return 1

    results = check_zip(args.apk, args.template) + check_manifest(args.apk, args.aapt2)
    n_fail = 0
    for name, ok, detail in results:
        print("%s  %s  %s" % ("PASS" if ok else "FAIL", name, detail))
        if not ok:
            n_fail += 1
    print("== 门禁结论: %s（%d 项断言，%d FAIL）==" % (
        "GREEN" if n_fail == 0 else "RED", len(results), n_fail))
    return 0 if n_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

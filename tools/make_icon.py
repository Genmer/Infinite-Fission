# -*- coding: utf-8 -*-
"""R194 启动器图标生成（PIL 12.3.0）——tools/ 一次性工具，可重跑（确定性输出）。

出三图至 repo/assets/icons/（与 export_presets.cfg launcher_icons 三键接线）：
  icon_192.png    主图标 192×192：藏青底 + 白玩家圆 + 轨道蓝点（完整构图）
  icon_fg_432.png 自适应前景 432×432（透明底，内容全部落在中心 264px 安全区内）
  icon_bg_432.png 自适应背景 432×432（藏青纯色，可带轻微径向明暗）

构图母题 = 游戏 logo 语义：主角白圆居中，武器化身沿轨道环绕（Player.weapon
orbit avatars）。4× 超采样绘制后降采样抗锯齿。
"""
import hashlib
import math
import os

from PIL import Image, ImageDraw

# 与 export 方案定案一致：藏青(50,81,107)底
NAVY = (50, 81, 107)
NAVY_DEEP = (38, 63, 86)          # 边缘径向渐变深端
ORBIT_BLUE = (96, 156, 216)       # 轨道蓝点主色
ORBIT_BLUE_CORE = (168, 208, 240)  # 蓝点高光芯
WHITE = (244, 248, 252)
RING_LINE = (82, 118, 152)        # 轨道细线（弱）

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "icons")
SS = 4  # 超采样倍数


def _lerp(a, b, t):
    return int(round(a + (b - a) * t))


def _bg_base(size):
    """藏青底 + 中心微亮径向渐变（SS 超采样坐标系）。"""
    img = Image.new("RGB", (size, size), NAVY)
    px = img.load()
    c = (size - 1) / 2.0
    max_r = c * 1.5
    for y in range(size):
        for x in range(size):
            d = math.hypot(x - c, y - c) / max_r
            if d < 1.0:
                t = 1.0 - d
                px[x, y] = (
                    _lerp(NAVY_DEEP[0], NAVY[0], t),
                    _lerp(NAVY_DEEP[1], NAVY[1], t),
                    _lerp(NAVY_DEEP[2], NAVY[2], t),
                )
    return img


def _draw_motif(draw, c, player_r, orbit_r, dot_r, ring_w):
    """共享构图：轨道细线 + 5 枚轨道蓝点 + 中心白玩家圆。所有半径由调用方给定。"""
    # 轨道细线
    draw.ellipse(
        (c - orbit_r, c - orbit_r, c + orbit_r, c + orbit_r),
        outline=RING_LINE, width=ring_w,
    )
    # 5 枚轨道蓝点（起点 -90° 置顶，顺时针均布）
    for i in range(5):
        ang = math.radians(-90 + i * 72)
        x = c + orbit_r * math.cos(ang)
        y = c + orbit_r * math.sin(ang)
        draw.ellipse(
            (x - dot_r, y - dot_r, x + dot_r, y + dot_r),
            fill=ORBIT_BLUE,
        )
        # 高光芯（偏左上）
        hx = x - dot_r * 0.28
        hy = y - dot_r * 0.28
        hr = dot_r * 0.42
        draw.ellipse((hx - hr, hy - hr, hx + hr, hy + hr), fill=ORBIT_BLUE_CORE)
    # 中心白玩家圆 + 内芯藏青小圆（舰体读感）
    draw.ellipse((c - player_r, c - player_r, c + player_r, c + player_r), fill=WHITE)
    core = player_r * 0.34
    draw.ellipse((c - core, c - core, c + core, c + core), fill=NAVY)


def make_main_192():
    """192×192 主图标：完整构图（藏青底铺满 + 母题）。"""
    size = 192 * SS
    img = _bg_base(size).convert("RGB")
    draw = ImageDraw.Draw(img)
    c = size / 2.0
    _draw_motif(
        draw, c,
        player_r=30 * SS, orbit_r=64 * SS, dot_r=11 * SS, ring_w=2 * SS,
    )
    return img.resize((192, 192), Image.LANCZOS)


def make_fg_432():
    """432×432 自适应前景：透明底，母题整体缩进中心 264px 安全区（半径 132px）。"""
    size = 432 * SS
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    c = size / 2.0
    # 安全区半径 132px（432×66/108）；最长触达 = orbit_r + dot_r ≤ 132
    _draw_motif(
        draw, c,
        player_r=40 * SS, orbit_r=86 * SS, dot_r=15 * SS, ring_w=2 * SS,
    )
    out = img.resize((432, 432), Image.LANCZOS)
    # 校验：非透明像素必须全部落在中心 264px 安全区内
    alpha = out.split()[3]
    bbox = alpha.getbbox()
    assert bbox is not None, "前景图内容为空"
    assert bbox[0] >= (432 - 264) / 2 and bbox[1] >= (432 - 264) / 2 \
        and bbox[2] <= (432 + 264) / 2 and bbox[3] <= (432 + 264) / 2, \
        "前景内容越出 264px 安全区: %s" % (bbox,)
    return out


def make_bg_432():
    """432×432 自适应背景：藏青径向渐变纯底（无前景语义内容）。"""
    size = 432 * SS
    img = _bg_base(size)
    return img.resize((432, 432), Image.LANCZOS)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    jobs = (
        ("icon_192.png", make_main_192()),
        ("icon_fg_432.png", make_fg_432()),
        ("icon_bg_432.png", make_bg_432()),
    )
    for name, img in jobs:
        path = os.path.join(OUT_DIR, name)
        img.save(path, "PNG")
        h = hashlib.sha256(open(path, "rb").read()).hexdigest()
        print("%s  %dx%d  sha256=%s" % (name, img.width, img.height, h))


if __name__ == "__main__":
    main()

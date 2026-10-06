#!/usr/bin/env python3
"""生成黑胶唱片 App 图标（.iconset → .icns）

用纯几何绘制：黑胶盘 + 同心纹路 + 中央红色标签 + 高光弧。
macOS 26 起推荐 1024 单图，但为兼容 13.0 用传统 iconset 全尺寸。
"""
import os
import struct
import sys
import zlib
import math

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources")


def write_png(path, width, height, pixels):
    """pixels: bytearray RGBA, 长度 width*height*4"""
    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)  # filter type 0
        raw += pixels[y * stride:(y + 1) * stride]

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def blend(dst, i, r, g, b, a):
    """alpha 合成到 dst RGBA"""
    if a >= 255:
        dst[i] = r; dst[i + 1] = g; dst[i + 2] = b; dst[i + 3] = 255
        return
    if a <= 0:
        return
    ia = dst[i + 3]
    na = a + ia * (255 - a) // 255
    if na == 0:
        return
    for k, nc in enumerate((r, g, b)):
        dc = dst[i + k]
        dst[i + k] = (nc * a + dc * ia * (255 - a) // 255) // na
    dst[i + 3] = na


def render(size, supersample=3):
    """渲染一张 size×size 的黑胶图标，返回 RGBA bytearray"""
    S = size * supersample
    cx = cy = S / 2.0
    R = S * 0.455          # 唱片半径

    # 画布预填充：透明（macOS 会自己加圆角遮罩，但留些透明边更好看）
    buf = bytearray(S * S * 4)

    label_r = R * 0.345    # 中央标签半径
    hole_r = R * 0.045     # 中心孔

    for y in range(S):
        dy = y - cy
        for x in range(S):
            dx = x - cx
            d = math.hypot(dx, dy)
            i = (y * S + x) * 4
            if d > R:
                continue

            t = d / R          # 0 中心 → 1 边缘

            if d < hole_r:
                # 中心孔：透明
                continue
            elif d < label_r:
                # 中央标签：深红到橙红渐变，带轻微光照
                k = d / label_r
                r = int(196 - 46 * k)
                g = int(42 + 30 * k)
                b = int(38 + 8 * k)
                # 左上高光
                hl = max(0.0, 1.0 - math.hypot(dx + R * 0.10, dy + R * 0.12) / (R * 0.30))
                r = min(255, r + int(48 * hl))
                g = min(255, g + int(30 * hl))
                b = min(255, b + int(26 * hl))
                blend(buf, i, r, g, b, 255)
            else:
                # 黑色盘面 + 同心纹路（用 sin 模拟沟槽）
                groove = math.sin((d - label_r) / (R - label_r) * math.pi * 26.0)
                base = 26 + groove * 7
                r = base * 0.97
                g = base
                b = base * 1.10

                # 左上大面积高光（模拟光泽）
                gl = max(0.0, 1.0 - math.hypot(dx + R * 0.34, dy + R * 0.38) / (R * 0.78))
                gl = gl ** 2
                r += 96 * gl
                g += 100 * gl
                b += 112 * gl

                # 右下反光弧
                rl = max(0.0, 1.0 - abs(math.hypot(dx - R * 0.42, dy + R * 0.44) - R * 0.50) / (R * 0.26))
                rl = rl ** 3
                r += 40 * rl
                g += 44 * rl
                b += 54 * rl

                # 边缘暗角
                edge = max(0.0, (t - 0.86) / 0.14)
                r *= (1 - 0.55 * edge)
                g *= (1 - 0.55 * edge)
                b *= (1 - 0.55 * edge)

                # 盘缘高光环
                rim = max(0.0, 1.0 - abs(d - R * 0.965) / (R * 0.028))
                r += 46 * rim
                g += 50 * rim
                b += 58 * rim

                blend(buf, i, int(max(0, min(255, r))),
                      int(max(0, min(255, g))),
                      int(max(0, min(255, b))), 255)

    # 降采样（box filter）
    if supersample == 1:
        return buf
    out = bytearray(size * size * 4)
    n = supersample * supersample
    for y in range(size):
        for x in range(size):
            r = g = b = a = 0
            for sy in range(supersample):
                for sx in range(supersample):
                    j = ((y * supersample + sy) * S + (x * supersample + sx)) * 4
                    pa = buf[j + 3]
                    r += buf[j] * pa
                    g += buf[j + 1] * pa
                    b += buf[j + 2] * pa
                    a += pa
            i = (y * size + x) * 4
            if a > 0:
                out[i] = r // a
                out[i + 1] = g // a
                out[i + 2] = b // a
                out[i + 3] = a // n
    return out


SIZES = [16, 32, 64, 128, 256, 512, 1024]
ICONS = {
    "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
}


def main():
    set_dir = os.path.join(OUT_DIR, "AppIcon.iconset")
    os.makedirs(set_dir, exist_ok=True)
    cache = {}
    for name, sz in ICONS.items():
        if sz not in cache:
            sys.stdout.write("  渲染 %dx%d … " % (sz, sz))
            sys.stdout.flush()
            cache[sz] = render(sz, supersample=3 if sz <= 512 else 2)
            print("ok")
        write_png(os.path.join(set_dir, name), sz, sz, cache[sz])
    icns = os.path.join(OUT_DIR, "AppIcon.icns")
    if os.path.exists(icns):
        os.remove(icns)
    os.system('iconutil -c icns "%s" -o "%s"' % (set_dir, icns))
    print("✓ %s  (%.0f KB)" % (icns, os.path.getsize(icns) / 1024))


if __name__ == "__main__":
    main()

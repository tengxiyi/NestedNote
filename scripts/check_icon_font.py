# SPDX-License-Identifier: AGPL-3.0-or-later
# 校验 release 产物里的图标字体是否包含界面上用到的**全部**图标。
#
# 用法（仓库根目录）：
#   python scripts/check_icon_font.py
#
# ## 为什么需要这道检查
#
# Flutter 在 release 构建时会对图标字体做 **tree-shaking**：只保留它
# **静态识别到**的 IconData 字形，其余删掉。被删掉的图标不会报错、
# 不会崩溃、测试也全过——只是**渲染成空白**。
#
# 而它对下面这类写法的识别是不可靠的：
#
#     const List<IconData> kIcons = <IconData>[Icons.folder, Icons.folder_open];
#     IconData iconFor(int depth) => kIcons[depth];   # 按下标动态取
#
# 本项目实际踩到：笔记本树按层级用三个文件夹图标（folder / folder_open /
# folder_outlined），release 包里**只有第三档的字形活了下来**
# （字体从 8667 个码点被裁到 26 个），于是第 1、2 层的文件夹图标整片消失。
# 而 Debug 构建完全正常，Widget 测试也全过——测试用的是完整字体。
#
# 也就是说：这个 bug **只有把包打出来、真正看一眼才发现得了**。
# 既然它逃得过所有既有检查，就必须专门为它加一道。
#
# ## 与 --no-tree-shake-icons 的关系
#
# justfile 的 app-build 已经带了 --no-tree-shake-icons（治本）。
# 本脚本是**独立验证**：不假设构建参数写对了，而是直接查产物里的字体。
# 万一将来有人改掉那个参数，这里会立刻失败。
#
# ## 为什么用 Python 而不是 PowerShell
#
# 第一版是 .ps1，但 PowerShell 对 "函数返回 HashSet" 的处理会
# 把集合拆成管道输出，导致码点集合丢失（实测解析出 0 个码点）。
# 字体表解析需要精确的二进制处理，Python 在这里明显更合适。

from __future__ import annotations

import re
import struct
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# 与 package-windows.ps1 保持一致
RELEASE_DIR = (
    REPO_ROOT / "client" / "apps" / "flutter" / "build" / "windows" / "x64" / "runner" / "Release"
)
ICONS_DART = REPO_ROOT / "client" / "apps" / "flutter" / "lib" / "app" / "icons.dart"


def read_codepoints(font_path: Path) -> set[int]:
    """读出 OTF/TTF 里 cmap 表覆盖的码点。

    只处理 format 4 与 format 12 —— Material Icons 用的是这两种，
    也是 Windows 上会遇到的格式。
    """
    data = font_path.read_bytes()
    num_tables = struct.unpack(">H", data[4:6])[0]

    cmap_offset = None
    for i in range(num_tables):
        off = 12 + i * 16
        if data[off : off + 4] == b"cmap":
            cmap_offset = struct.unpack(">I", data[off + 8 : off + 12])[0]
            break
    if cmap_offset is None:
        raise SystemExit(f"字体里没有 cmap 表：{font_path}")

    subtable_count = struct.unpack(">H", data[cmap_offset + 2 : cmap_offset + 4])[0]
    codepoints: set[int] = set()

    for i in range(subtable_count):
        rec = cmap_offset + 4 + i * 8
        sub = cmap_offset + struct.unpack(">I", data[rec + 4 : rec + 8])[0]
        fmt = struct.unpack(">H", data[sub : sub + 2])[0]

        if fmt == 4:
            seg_x2 = struct.unpack(">H", data[sub + 6 : sub + 8])[0]
            seg = seg_x2 // 2
            ends = struct.unpack(f">{seg}H", data[sub + 14 : sub + 14 + seg_x2])
            starts_off = sub + 14 + seg_x2 + 2
            starts = struct.unpack(f">{seg}H", data[starts_off : starts_off + seg_x2])
            for start, end in zip(starts, ends):
                if start == 0xFFFF and end == 0xFFFF:
                    continue
                codepoints.update(range(start, min(end, 0xFFFF) + 1))

        elif fmt == 12:
            n_groups = struct.unpack(">I", data[sub + 12 : sub + 16])[0]
            for g in range(n_groups):
                go = sub + 16 + g * 12
                start, end, _ = struct.unpack(">III", data[go : go + 12])
                codepoints.update(range(start, end + 1))

    return codepoints


def sdk_icons_path() -> Path:
    """定位 Flutter SDK 的 material/icons.dart。"""
    import shutil

    flutter = shutil.which("flutter")
    candidates: list[Path] = []
    if flutter:
        # <flutter>/bin/flutter  →  <flutter>/packages/...
        candidates.append(Path(flutter).resolve().parent.parent)
    candidates += [
        Path(r"C:\src\flutter"),
        Path.home() / "flutter",
        Path("/usr/local/flutter"),
        Path("/opt/flutter"),
    ]
    for root in candidates:
        candidate = root / "packages" / "flutter" / "lib" / "src" / "material" / "icons.dart"
        if candidate.is_file():
            return candidate
    raise SystemExit("找不到 Flutter SDK 的 material/icons.dart；请确保 flutter 在 PATH 上。")


def main() -> int:
    font_path = RELEASE_DIR / "data" / "flutter_assets" / "fonts" / "MaterialIcons-Regular.otf"
    if not font_path.is_file():
        raise SystemExit(
            f"找不到图标字体：{font_path}\n先运行 flutter build windows --release --no-tree-shake-icons。"
        )
    if not ICONS_DART.is_file():
        raise SystemExit(f"找不到图标定义文件：{ICONS_DART}")

    # 代码里用到的图标：以 icons.dart 为唯一来源扫描
    app_text = ICONS_DART.read_text(encoding="utf-8")
    used_names = set(re.findall(r"IconData\s+\w+\s*=\s*Icons\.(\w+)", app_text))
    if not used_names:
        raise SystemExit("没有从 icons.dart 解析出任何图标；正则或文件结构可能变了。")

    sdk_text = sdk_icons_path().read_text(encoding="utf-8")
    sdk_map = {
        name: int(cp, 16)
        for name, cp in re.findall(
            r"static const IconData (\w+) = IconData\((0x[0-9a-fA-F]+)", sdk_text
        )
    }

    used: dict[str, int] = {}
    unknown: list[str] = []
    for name in sorted(used_names):
        if name in sdk_map:
            used[name] = sdk_map[name]
        else:
            unknown.append(name)
    if unknown:
        raise SystemExit(
            "以下图标在 Flutter SDK 里找不到（名字拼错或该版本没有）：\n  "
            + "\n  ".join(f"Icons.{n}" for n in unknown)
        )

    font_codepoints = read_codepoints(font_path)

    print("== 校验 release 产物里的图标字体 ==")
    print(f"字体：{font_path}")
    print(f"      {len(font_codepoints)} 个码点，{font_path.stat().st_size / 1024:,.0f} KB")
    print(f"代码用到 {len(used)} 个图标")
    print()

    missing = [(n, c) for n, c in sorted(used.items()) if c not in font_codepoints]
    if missing:
        print("失败：以下图标在 release 字体里没有字形，界面上会渲染成空白。")
        print()
        for name, cp in missing:
            print(f"  Icons.{name}  (0x{cp:x})")
        print()
        print("原因：Flutter 的图标 tree-shaking 删掉了这些字形。")
        print("修法：构建时加 --no-tree-shake-icons（justfile 的 app-build 已带）。")
        return 1

    print(f"OK：全部 {len(used)} 个图标都有字形。")
    return 0


if __name__ == "__main__":
    sys.exit(main())

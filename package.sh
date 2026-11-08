#!/bin/bash
#
# 把 dist/Grabi.app 打包成可分发的 DMG、PKG 安装器与 ZIP。
#
#   ./package.sh
#
# 产物：
#   dist/Grabi-<版本>.dmg   带「拖到 Applications」引导
#   dist/Grabi-<版本>.pkg   标准 macOS 安装器
#   dist/Grabi-<版本>.zip   保留签名与扩展属性，适合直接发给别人
#
set -euo pipefail

APP_NAME="Grabi"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/dist/$APP_NAME.app"

if [[ ! -d "$APP" ]]; then
    echo "找不到 $APP，先跑 ./build.sh release" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 1.0.0)"
DMG="$ROOT/dist/$APP_NAME-$VERSION.dmg"
PKG="$ROOT/dist/$APP_NAME-$VERSION.pkg"
ZIP="$ROOT/dist/$APP_NAME-$VERSION.zip"

echo "==> 检查签名"
if ! codesign --verify --deep "$APP" 2>/dev/null; then
    echo "    签名校验失败，打包出来的 app 在别的机器上会打不开" >&2
    exit 1
fi
# 用 -dvvv：-dv 不输出证书链（Authority 行）
IDENTITY="$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
echo "    ${IDENTITY:-ad-hoc（未使用证书）}"
DISTRIBUTABLE=0
if [[ "$IDENTITY" == Developer\ ID\ Application:* ]]; then
    DISTRIBUTABLE=1
fi

# 默认快捷键从**要打包的那个 app** 里问，不抄第二份：
# 说明里从前是手写的，改了出厂默认就会发一份教错键位的说明书。
DEFAULTS="$("$APP/Contents/MacOS/$APP_NAME" --default-hotkeys 2>/dev/null || true)"
CAPTURE_KEY="$(printf '%s' "$DEFAULTS" | awk -F'\t' 'NR==1{print $1}')"
if [[ -z "$CAPTURE_KEY" ]]; then
    echo "拿不到出厂默认快捷键（--default-hotkeys 没吐值），不发一份教错键位的说明" >&2
    exit 1
fi
# 变量一律加花括号：后面紧跟的是全角空格（多字节），在非 UTF-8 的 locale 下
# 不加大括号时 bash 会把它的字节当成变量名的一部分，`set -u` 直接报
# "CAPTURE_KEY�: unbound variable"。本机交互 shell 是 UTF-8 时不复现，
# 但 CI / 别的 locale 下打包会当场失败。
echo "    出厂快捷键：截图 ${CAPTURE_KEY}"

echo "==> 组装 DMG 内容"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/使用说明.txt" <<EOF
Grabi 安装说明
================

1. 把 Grabi 拖到右侧的 Applications 文件夹
2. 首次打开会请求「屏幕录制」权限，请勾选允许
   （路径：系统设置 › 隐私与安全性 › 屏幕与系统音频录制）
3. 授权后需要重启一次 Grabi 才生效 —— 软件检测到授权通过时会主动提醒你，
   也可以手动完全退出再重新打开

首次打开提示
------------
$(
if [[ "$DISTRIBUTABLE" == "1" ]]; then
    printf '%s\n' "本安装包已使用 Developer ID 签名并提交 Apple 公证，正常双击即可打开。"
else
    printf '%s\n' "本安装包目前使用 Apple Development 证书签名，仅适合本机/内部测试。" \
                  "其他 Mac 首次打开时，请右键 Grabi.app →「打开」→ 再确认一次。" \
                  "正式对外发布需要 Developer ID Application 证书并完成 Apple 公证。"
fi
)

截图怎么用
----------
按 $CAPTURE_KEY 进入截图模式，此时不用选模式：

  · 鼠标移到某个窗口上  → 高亮该窗口，单击即截
  · 鼠标移到桌面/空隙   → 高亮整屏，单击即截
  · 按住并拖动          → 自由框选区域
  · 按住 ⇧ 拖动         → 锁正方形
  · 按住 ⌥ 拖动         → 从中心向外扩
  · 空格                → 强制切到整屏
  · Esc                 → 取消

截完之后，预览面板直接浮在你刚框选的位置上：
  · 复制图片            → 存进剪贴板并给一条「已复制」回执，预览保持打开
  · 保存 / 回车         → 存成文件并关闭预览，右下角给一条「已保存」回执
  · Esc / ⌘W / 点别处   → 关掉面板，不存文件、也不动剪贴板
  · 识别文字            → 识别后切换工具栏；可「复制选中」划选部分，或用
                           「复制全文」复制整页识别结果
  · 拖图片空白处        → 挪动预览位置
  · 滚轮                → 调整预览大小（只改观看倍率，不改截图内容）
  · 拖边框上的圆点手柄   → 重新框选范围（按新范围从整屏原图重新裁切）
  · 右键图片            → 复制图片 / 保存 / 丢弃（存过之后多出打开 / 在访达中显示 / 复制路径）
  · 丢弃                → 不存；已存过的那份移到废纸篓，不是永久删除，可以找回

截图既不自动存文件、也不自动进剪贴板。工具栏里有「保存」和「复制图片」两个明确出口：
复制完成后预览保持打开，方便继续选字或标注；保存完成后预览关闭，并给一条带文件名的提示。

重要：请始终运行「应用程序」文件夹里的那一份。
后台自启动只认标准应用目录，放在别处的副本系统不会自动拉起。

默认快捷键（新机器上的出厂值；菜单栏 › 设置… › 快捷键 可以改）
  截图（窗口 / 区域 / 全屏）   $CAPTURE_KEY

截图默认存到 ~/Pictures/Grabi/
菜单栏图标 › 设置… 可以改保存路径、格式、识别语言和快捷键。
EOF

echo "==> 文档对账（README 那张快捷键表要跟着出厂默认走）"
if [[ -f "$ROOT/README.md" ]]; then
    if ! grep -qF -- "$CAPTURE_KEY" "$ROOT/README.md"; then
        echo "    README 里找不到 $CAPTURE_KEY —— 出厂默认改了，那张表得一起改" >&2
        exit 1
    fi
    echo "    README 认得 $CAPTURE_KEY ✓"
else
    echo "    △ 找不到 README.md，这一项没对账" >&2
fi

# DMG 的窗口尺寸、图标位置、背景图三处坐标必须一致：
#   tools/make-dmg-background.swift 里的注释和下面 AppleScript 里的 position。
# 改一个就要改另一个，否则箭头会指偏。
DMG_W=660
DMG_H=520
DMG_BG="$ROOT/packaging/dmg/background.png"

echo "==> 生成 DMG（拖进 Applications 的安装窗口）"
rm -f "$DMG"

mkdir -p "$(dirname "$DMG_BG")"
if [[ ! -f "$DMG_BG" || "$ROOT/tools/make-dmg-background.swift" -nt "$DMG_BG" ]]; then
    echo "    绘制安装窗口背景"
    swift "$ROOT/tools/make-dmg-background.swift" "$DMG_BG" "$DMG_W" "$DMG_H" 2 >/dev/null
fi

DMG_WORK="$(mktemp -d -t grabi-dmg)"
RW_DMG="$DMG_WORK/$APP_NAME-$VERSION-rw.dmg"
DMG_DEV=""

detach_dmg() {
    [[ -n "$DMG_DEV" ]] || return 0
    hdiutil detach "$DMG_DEV" >/dev/null 2>&1 \
        || hdiutil detach "$DMG_DEV" -force >/dev/null 2>&1 \
        || true
    DMG_DEV=""
}
trap 'detach_dmg; rm -rf "$STAGE" "$DMG_WORK"' EXIT

# 先做一份可写的中间镜像，挂载后让 Finder 把图标位置和背景写进 .DS_Store，
# 拆掉之后再压成只读 UDZO —— 这是 Finder 布局能保存下来的唯一办法。
hdiutil create -volname "$APP_NAME $VERSION" \
               -srcfolder "$STAGE" \
               -ov -format UDRW \
               "$RW_DMG" >/dev/null

MOUNT_OUTPUT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)"
DMG_DEV="$(printf '%s\n' "$MOUNT_OUTPUT" | head -1 | awk '{print $1}')"
MOUNT_DIR="$(printf '%s\n' "$MOUNT_OUTPUT" | grep -o '/Volumes/.*' | head -1)"
if [[ -z "$DMG_DEV" || -z "$MOUNT_DIR" ]]; then
    echo "    挂载中间镜像失败：$MOUNT_OUTPUT" >&2
    exit 1
fi

mkdir -p "$MOUNT_DIR/.background"
cp "$DMG_BG" "$MOUNT_DIR/.background/background.png"

LAYOUT_OK=0
if osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Finder"
    tell disk "$APP_NAME $VERSION"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 140, $((200 + DMG_W)), $((140 + DMG_H))}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 12
        set background picture of opts to file ".background:background.png"
        set position of item "$APP_NAME.app" of container window to {168, 176}
        set position of item "Applications" of container window to {492, 176}
        set position of item "使用说明.txt" of container window to {330, 352}
        close
        open
        update without registering applications
        delay 2
        tell container window
            set statusbar visible to false
            set the bounds to {200, 140, $((200 + DMG_W - 10)), $((140 + DMG_H - 10))}
        end tell
        delay 1
        tell container window
            set the bounds to {200, 140, $((200 + DMG_W)), $((140 + DMG_H))}
        end tell
        delay 2
    end tell
end tell
APPLESCRIPT
then
    [[ -f "$MOUNT_DIR/.DS_Store" ]] && LAYOUT_OK=1
fi

# 和 create-dmg 一样收个尾：文件系统事件日志留在镜像里没意义，
# 权限也别给成谁都写得进去。
chmod -Rf go-w "$MOUNT_DIR" >/dev/null 2>&1 || true
rm -rf "$MOUNT_DIR/.fseventsd"
sync
detach_dmg

if [[ "$LAYOUT_OK" == "1" ]]; then
    if ! HDIUTIL_OUT="$(hdiutil convert "$RW_DMG" -format UDZO \
                                        -imagekey zlib-level=9 \
                                        -o "$DMG" 2>&1)"; then
        echo "$HDIUTIL_OUT" >&2
        exit 1
    fi
else
    # 没有 Finder 自动化权限的机器（CI、无人值守构建）走这条路：
    # 少一张背景图和图标排队，但「拖到 Applications」本身仍然成立。
    echo "    ⚠︎ 没能写入 Finder 布局（通常是缺自动化权限），改用朴素 DMG" >&2
    # hdiutil 在 macOS 26+ 会提示改用 diskutil image create，
    # 但 hdiutil 是各版本都可靠的选择。把 deprecation 噪音收掉，只在真失败时打印。
    if ! HDIUTIL_OUT="$(hdiutil create -volname "$APP_NAME $VERSION" \
                                       -srcfolder "$STAGE" \
                                       -ov -format UDZO \
                                       "$DMG" 2>&1)"; then
        echo "$HDIUTIL_OUT" >&2
        exit 1
    fi
fi

rm -rf "$DMG_WORK"
DMG_WORK=""

echo "==> 生成 ZIP"
rm -f "$ZIP"
# ditto 才会保留 app bundle 的签名与扩展属性，zip 命令会破坏签名
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> 生成 PKG 安装器"
INSTALLER_WORK="$(mktemp -d -t grabi-installer)"
trap 'rm -rf "$STAGE" "$INSTALLER_WORK"' EXIT
INSTALLER_RES="$INSTALLER_WORK/resources"
mkdir -p "$INSTALLER_RES"
cp -R "$ROOT/packaging/installer/resources/." "$INSTALLER_RES/"
cp "$ROOT/LICENSE" "$INSTALLER_RES/license.txt"
sed "s/@VERSION@/$VERSION/g" \
    "$ROOT/packaging/installer/distribution.xml" \
    > "$INSTALLER_WORK/distribution.xml"

pkgbuild --component "$APP" \
         --install-location "/Applications" \
         --identifier "com.momoxiao.grabi.installer" \
         --version "$VERSION" \
         --scripts "$ROOT/packaging/installer/scripts" \
         "$INSTALLER_WORK/Grabi-component.pkg"

UNSIGNED_PKG="$INSTALLER_WORK/$APP_NAME-$VERSION-unsigned.pkg"
productbuild --distribution "$INSTALLER_WORK/distribution.xml" \
             --resources "$INSTALLER_RES" \
             --package-path "$INSTALLER_WORK" \
             "$UNSIGNED_PKG"

rm -f "$PKG"
INSTALLER_IDENTITY="$(security find-identity -v -p basic 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Installer:[^"]*\)"/\1/p' | head -1)"
INSTALLER_SIGNED=0
if [[ -n "$INSTALLER_IDENTITY" ]]; then
    echo "==> 签名 PKG 安装器 ($INSTALLER_IDENTITY)"
    productsign --sign "$INSTALLER_IDENTITY" "$UNSIGNED_PKG" "$PKG"
    INSTALLER_SIGNED=1
else
    echo "    未找到 Developer ID Installer 证书，保留未签名 PKG（可手动打开安装）"
    cp "$UNSIGNED_PKG" "$PKG"
fi

if ! pkgutil --payload-files "$PKG" >/dev/null 2>&1; then
    echo "    PKG 结构校验失败" >&2
    exit 1
fi
echo "    安装目标：/Applications/$APP_NAME.app"

if [[ "$DISTRIBUTABLE" == "1" ]]; then
    NOTARY_PROFILE="${GRABI_NOTARY_PROFILE:-grabi-notary}"
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "==> 提交 Apple 公证 ($NOTARY_PROFILE)"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
        xcrun stapler validate "$DMG"
        # ZIP 是给不想用 DMG 的人准备的；公证通过后重新封一次，把票据带上。
        rm -f "$ZIP"
        ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
        if [[ "$INSTALLER_SIGNED" == "1" ]]; then
            echo "==> 提交 PKG 安装器公证 ($NOTARY_PROFILE)"
            xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
            xcrun stapler staple "$PKG"
            xcrun stapler validate "$PKG"
        fi
    else
        echo "==> 未找到公证凭据配置：$NOTARY_PROFILE" >&2
        echo "    仍会打包，但外部用户下载后可能被 Gatekeeper 拦住。" >&2
    fi
fi

echo
echo "==> 完成"
ls -lh "$DMG" "$PKG" "$ZIP" | awk '{printf "    %-56s %s\n", $NF, $5}'
echo
if [[ "$DISTRIBUTABLE" == "1" ]]; then
    echo "发布签名：Developer ID；如已配置 $NOTARY_PROFILE，将自动完成公证与 stapling。"
else
    echo "提醒：当前是 Apple Development 签名，产物仅供本机/内部测试。"
    echo "     要发给别人并让系统直接放行，应用需要 Developer ID Application，"
    echo "     PKG 需要 Developer ID Installer，并完成 Apple 公证。"
fi

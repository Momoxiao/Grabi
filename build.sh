#!/bin/bash
#
# Grabi 一键构建：编译 → 组装 .app → 签名 →（可选）装到标准应用目录
#
#   ./build.sh                     # release 构建
#   ./build.sh release run         # 构建完启动
#   ./build.sh release install     # 构建 + 装到 ~/Applications（自启动/保活需要）
#   ./build.sh debug               # 带符号的调试构建
#
set -euo pipefail

APP_NAME="Grabi"
BUNDLE_ID="com.momoxiao.grabi"
PREVIOUS_APP_NAMES=("LiteShot" "Shutterbox")
PREVIOUS_BUNDLE_IDS=("com.momoxiao.liteshot" "com.momoxiao.shutterbox")
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-release}"
ACTION="${2:-}"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

# 安装位置：优先跟随用户已有的安装（有人习惯放 /Applications），
# 都没有时才用 ~/Applications。两个位置都满足 SMAppService 的约束。
#
# 注意绝不能两份并存：系统对同一个 bundle id 只会认一份，另一份会变成
# "打开是旧版本" 的困惑源。
INSTALLED=""
for candidate in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
    if [[ -d "$candidate" ]]; then INSTALLED="$candidate"; break; fi
done
if [[ -z "$INSTALLED" && "$ACTION" == "install" ]]; then
    INSTALLED="$HOME/Applications/$APP_NAME.app"
fi

if [[ "$CONFIG" != "release" && "$CONFIG" != "debug" ]]; then
    echo "用法: ./build.sh [release|debug] [run|install]" >&2
    exit 1
fi

# 品牌改名后的一次性迁移：旧名称不再保留。
# 旧副本沿用旧 bundle id，若不清理会与 Grabi 并存，并且旧版仍可能被后台项拉起。
if [[ "$ACTION" == "install" ]]; then
    for previous_name in "${PREVIOUS_APP_NAMES[@]}"; do
        if pgrep -x "$previous_name" >/dev/null 2>&1; then
            osascript -e "tell application \"$previous_name\" to quit" >/dev/null 2>&1 \
                || pkill -x "$previous_name" || true
        fi
        for old in "/Applications/$previous_name.app" "$HOME/Applications/$previous_name.app"; do
            if [[ -d "$old" ]]; then
                echo "==> 清理旧版本 $old"
                rm -rf "$old"
            fi
        done
    done
    for previous_id in "${PREVIOUS_BUNDLE_IDS[@]}"; do
        launchctl bootout "gui/$(id -u)/$previous_id" >/dev/null 2>&1 || true
        launchctl bootout "gui/$(id -u)/$previous_id.keepalive" >/dev/null 2>&1 || true
        rm -f "$HOME/Library/LaunchAgents/$previous_id.plist"
    done
fi

# ── 编译 ────────────────────────────────────────────────────────────────
echo "==> 编译 (${CONFIG})"
BUILD_LOG="$(mktemp -t grabi-build)"
if ! swift build -c "$CONFIG" --package-path "$ROOT" >"$BUILD_LOG" 2>&1; then
    # 部分受限环境（CI、沙箱）里 sandbox-exec 不可用，SwiftPM 编译 manifest 会失败
    echo "    常规构建未成功，改用 --disable-sandbox 重试"
    if ! swift build -c "$CONFIG" --disable-sandbox --package-path "$ROOT"; then
        echo "----- 构建日志 -----" >&2
        cat "$BUILD_LOG" >&2
        rm -f "$BUILD_LOG"
        exit 1
    fi
fi
rm -f "$BUILD_LOG"

BIN_DIR="$(swift build -c "$CONFIG" --disable-sandbox --package-path "$ROOT" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
[[ -f "$BIN" ]] || { echo "找不到编译产物: $BIN" >&2; exit 1; }

# ── 组装 ────────────────────────────────────────────────────────────────
echo "==> 组装 $APP_NAME.app"
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "    检测到正在运行，先退出"
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 \
        || pkill -x "$APP_NAME" || true
    sleep 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/AppInfo.plist" "$APP/Contents/Info.plist"
# 应用图标（重新生成：./tools/make-icon.sh）
# 语言声明：没有 .lproj 的 bundle，AppKit 自带控件（查找条、右键菜单、拼写面板）
# 会一律按 CFBundleDevelopmentRegion 说话 —— 中文机器上看着没问题，但英文用户也会
# 被硬塞一套中文边栏。放上 zh-Hans.lproj / en.lproj，它才按**用户**的语言选。
for lproj in "$ROOT"/Resources/*.lproj; do
    [[ -d "$lproj" ]] && cp -R "$lproj" "$APP/Contents/Resources/"
done

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
# 保活 agent 必须放在 bundle 内，SMAppService.agent(plistName:) 只认这个位置
cp "$ROOT/Resources/KeepAliveAgent.plist" \
   "$APP/Contents/Library/LaunchAgents/com.momoxiao.grabi.keepalive.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ── 签名 ────────────────────────────────────────────────────────────────
#
# 选哪一种签名，直接决定「屏幕录制权限会不会反复失效」：
#
#   ad-hoc（codesign -s -）：
#     designated requirement 里包含 cdhash，**每次重新编译系统都会把它当成
#     全新的 app**，TCC 授权记录随之作废 —— 表现就是"明明授权过，还一直要权限"。
#
#   开发者证书（Apple Development / Developer ID）：
#     requirement 只绑定证书身份，不含 cdhash。重编译后授权依旧有效。
#
SIGN_IDENTITY="${GRABI_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application:[^"]*\)"/\1/p' | head -1)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:[^"]*\)"/\1/p' | head -1)"
fi

SIGN_STAMP="$ROOT/.build/.last-sign-identity"
LAST_SIGN="$(cat "$SIGN_STAMP" 2>/dev/null || true)"

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> 签名 (${SIGN_IDENTITY})"
    codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP" 2>&1 | sed 's/^/    /'
else
    echo "==> 签名（ad-hoc —— 注意：重新编译后需要重新授予屏幕录制权限）"
    codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP" 2>&1 | sed 's/^/    /'
fi
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /' || true

# ── 验收：跑**包里那一份**，不是 build 目录里的裸二进制 ──────────────────
#
# 裸二进制没有 bundle，AppKit 自带控件（查找条 / 右键菜单 / 拼写面板）读不到
# CFBundleLocalizations，一律按开发区域说话 —— 于是离屏渲染出来的查找条是英文
# "Find / Done / Replace"，而用户装的那份其实是中文。拿那种图看过一遍界面，
# 就会得出"界面语言没跟着系统走"这种错结论（这一条正是这么发现的）。
#
# 更要紧的是：发布闸门该验**发出去的那个东西**。两套自检都带退出码，
# 没过就不往下同步安装目录 —— 别把没验过的包推到 /Applications。
echo "==> 验收（bundle 内）"
VERIFY_DIR="$(mktemp -d -t grabi-verify)"
if ! "$APP/Contents/MacOS/$APP_NAME" --logic-selftest >"$VERIFY_DIR/logic.log" 2>&1; then
    echo "----- bundle 内 --logic-selftest 没过 -----" >&2
    grep -E "✗|结论" "$VERIFY_DIR/logic.log" | tail -30 >&2
    echo "    完整日志：$VERIFY_DIR/logic.log" >&2
    exit 1
fi
if ! "$APP/Contents/MacOS/$APP_NAME" --ui-render "$VERIFY_DIR/ui" >"$VERIFY_DIR/ui.log" 2>&1; then
    echo "----- bundle 内 --ui-render 没过 -----" >&2
    grep -E "✗|结论" "$VERIFY_DIR/ui.log" | tail -30 >&2
    echo "    渲染图留在 $VERIFY_DIR/ui" >&2
    exit 1
fi
# 只回显这三行：语言那一条是"包内才验得出"的东西，结论行是两套餐的账
# （`|| true` 是必须的：脚本开头开了 pipefail，而这只是段回显，
#   一行没匹配上不该让整个发布构建失败）
grep -E "bundle 声明|查找条文案|^结论：" "$VERIFY_DIR/logic.log" "$VERIFY_DIR/ui.log" \
    | sed 's/^[^:]*://' | sed 's/^/    /' || true
rm -rf "$VERIFY_DIR"

# 签名身份变了，旧的 TCC 记录一定对不上，留着只会让系统设置里
# "显示已勾选但实际无效"。清掉，让用户干净地授权一次。
if [[ "$LAST_SIGN" != "$SIGN_IDENTITY" ]]; then
    echo "==> 签名身份变化，清除旧的屏幕录制授权记录"
    if /usr/bin/tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null; then
        echo "    已清除。下次启动 Grabi 需要重新授予一次屏幕录制权限。"
    else
        echo "    清除失败（受限环境），如遇权限异常请手动执行："
        echo "      tccutil reset ScreenCapture $BUNDLE_ID"
    fi
    mkdir -p "$(dirname "$SIGN_STAMP")"
    printf '%s' "$SIGN_IDENTITY" > "$SIGN_STAMP"
fi

# ── 安装到标准应用目录 ──────────────────────────────────────────────────
#
# SMAppService 登记的进程带一条 launch constraint，要求可执行文件位于
# /Applications 或 ~/Applications。放在项目目录里系统会拒绝启动它
# （SIGKILL / Launch Constraint Violation，job state = spawn failed）。
if [[ -n "$INSTALLED" ]]; then
    echo "==> 同步到 $INSTALLED"
    mkdir -p "$(dirname "$INSTALLED")"
    rm -rf "$INSTALLED"
    cp -R "$APP" "$INSTALLED"
    # 二进制变了，后台项登记的签名也失效了，重新登记一次
    "$INSTALLED/Contents/MacOS/$APP_NAME" --agent refresh 2>&1 | sed 's/^/    /' || true
    echo "    已安装: $INSTALLED"

    # 清掉另一个位置的副本，避免"打开的是旧版本"
    for other in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
        if [[ "$other" != "$INSTALLED" && -d "$other" ]]; then
            echo "    清除重复副本: $other"
            rm -rf "$other"
        fi
    done
else
    echo "==> 刷新后台项登记（若曾开启自启动）"
    "$APP/Contents/MacOS/$APP_NAME" --agent refresh 2>&1 | sed 's/^/    /' || true
fi

echo "==> 完成: $APP"
echo
if [[ -n "$INSTALLED" ]]; then
    echo "日常请运行已安装的那一份（后台自启动只认标准应用目录）："
    echo "    open \"$INSTALLED\""
else
    echo "建议装到标准应用目录，同时启用自启动与保活："
    echo "    ./build.sh release install"
fi
echo "首次启动会请求「屏幕录制」权限，勾选允许即可。"
echo "用开发者证书签名后，这个授权不会再因为重新编译而失效。"

if [[ "$ACTION" == "run" ]]; then
    echo
    echo "==> 启动"
    if [[ -n "$INSTALLED" ]]; then open "$INSTALLED"; else open "$APP"; fi
fi

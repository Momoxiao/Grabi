# Grabi 产品宣传视频

47 秒、1920×1080、30fps 的产品宣传片，配音轨（AAC）。

## 产物

| 文件 | 说明 |
|---|---|
| `grabi-promo.mp4` | 成片，H.264 + AAC，约 6 MB，已带 faststart |
| `poster.jpg` | 开场封面帧 |
| `poster-ui.jpg` | 截图流程主视觉帧 |

## 分镜

| 时间 | 场景 |
|---|---|
| 0:00–0:03 | 品牌开场：图标 + Grabi + 三个定位标签 |
| 0:03–0:07 | 痛点：截一张图的五步流水线 → 一次按键收掉 |
| 0:07–0:11 | 全局热键 ⌃⌥A + 菜单栏常驻 |
| 0:11–0:16 | 一个键三种截法（窗口 / 区域 / 全屏） |
| 0:16–0:21 | 框选 → 尺寸角标 → 就地工具栏 → 结果角标 |
| 0:21–0:25 | 就地标注：矩形 / 椭圆 / 箭头 + 调色与线宽 |
| 0:25–0:29 | OCR 点选文字块、拖选复制 |
| 0:29–0:34 | 识别结果面板、自动复制 |
| 0:34–0:39 | 编辑最近一张截图，不用重截 |
| 0:39–0:43 | 资源占用 27 MB / 270–430 ms |
| 0:43–0:47 | 收尾：一个快捷键，从截图到粘贴 |

## 素材来源

界面素材全部来自产品自己的离屏渲染，不是重画的示意图：

```bash
./dist/Grabi.app/Contents/MacOS/Grabi --ui-render /tmp/grabi-ui
```

用到的是 `toolbar-*.png`、`toast*.png`、`editor.png`、`settings-*.png`、
`status-icon-normal.png`，以及 `Resources/AppIcon.icns` 导出的图标。
演示用的桌面和文档窗口是按截图界面同一套配色手搭的模拟场景。

## 重新生成

```bash
cd promo
node render.cjs --out frames     # 逐帧渲染，1410 帧，约 5 分钟
    ffmpeg -y -framerate 30 -i frames/%05d.png -i score.wav \
  -filter_complex "[0:v]format=yuv420p[v];[1:a]afade=t=out:st=45.5:d=1.5[a]" \
  -map "[v]" -map "[a]" -c:v libx264 -preset slow -crf 17 \
  -pix_fmt yuv420p -movflags +faststart -c:a aac -b:a 192k \
  -shortest grabi-promo.mp4
```

`index.html` 是全部画面与动画的唯一来源：每个分镜是一个 `<section class="scene">`，
时间轴在 JS 顶部的 `SCENES` / `CAPTIONS` 两张表里，改完直接重跑 `render.cjs` 即可。
渲染走 Playwright + 系统 Chrome，逐帧确定性输出（不用录制，所以每一帧都对齐）。

配乐 `score.wav` 由 `audio.py` 纯合成（和弦垫 + 每拍脉冲 + 场景转换的 riser），
没有用任何外部音源，重跑 `python3 audio.py` 即可换一版。

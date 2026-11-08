import AppKit

// 强引用持有，避免 NSApplication.delegate(weak) 让控制器被回收。
enum Bootstrap {
    static let controller = AppController()
}

// MARK: - 命令行自检分支
//
// 这些分支在启动 UI 之前就退出，所以可以安全地在没有图形界面的场景下验证链路。
// 先建 NSApplication 实例（不 run），Carbon 的事件分发器需要它才能注册热键。

/// 真实分派出去的参数清单。
///
/// 放在 `enum` 里而不是 main.swift 的顶层 `let`：自检分支在顶层代码跑到那一行
/// 之前就已经 `exit()` 了，从别的文件（`--logic-selftest` 要对账这张表）读那个
/// 全局常量拿到的是**没初始化过的内存** —— 实测直接 SIGSEGV，而且 stdout 还在
/// 缓冲区里，连崩在哪一行都看不出来。类型上的 `static let` 是懒初始化，没这个坑。
enum CLI {
    static let knownFlags: Set<String> = [
        "--ocr", "--shot", "--ui-preview", "--ui-render", "--logic-selftest",
        "--ocr-selftest", "--ocr-quality", "--ocr-bench", "--livetext-selftest",
        "--agent", "--diagnose", "--default-hotkeys", "--help"
    ]
}

let arguments = Array(CommandLine.arguments.dropFirst())
let isCLIMode = arguments.contains { $0.hasPrefix("--") }

/// 用法清单。`--help` 和"未知参数"两处共用一份，省得它们各自腐烂。
///
/// 写成函数而不是常量：热键那两行必须**从设置里读**。手写的第一版把 ⌃⌥S
/// 抄成了 ⌃S —— 清单一旦和真实默认值分家，它比没有清单更坏。
/// `internal` 而不是 private：`--logic-selftest` 要拿这张清单和真实分派的那批
/// 参数对账（手抄的清单已经错过两次，见 Diagnostics 里那一组断言）。
func usageText() -> String {
    let settings = SettingsStore.shared
    func row(_ key: HotKeySpec, _ what: String) -> String {
        "  \(key.displayString.padding(toLength: 6, withPad: " ", startingAt: 0))\(what)"
    }
    return """
    Grabi —— macOS 菜单栏截图 + 文字识别（无 Dock 图标）

    全局热键（取自当前设置，可在设置窗口里改）：
    \(row(settings.hotKeyCapture, "截图：面板上「保存」存盘、「复制图片」进剪贴板（移动选窗口 / 整屏，拖动选区域）"))

    自检与诊断（都不需要图形界面就能跑）：
      --diagnose             环境、权限、显示器、配置、热键注册检测（读不到跨进程占用）
      --logic-selftest       纯逻辑自检：坐标 / 裁剪 / 窗口位置 / 文件名模板 / 失败反馈
      --ui-render [目录]     离屏渲染界面组件，深浅两套外观各画一遍 + 数值断言
      --ui-preview [文件]    把预览面板真摆到屏幕上再自拍（需要显示器 + 录屏权限）
      --shot                 立刻截一张全屏并落盘，打印分辨率与耗时
      --ocr <图片>           识别一张已有图片里的文字
      --ocr-selftest         自绘中英文图再识别回来（不需要截图权限）
      --ocr-quality          识别质量基准
      --ocr-bench            识别耗时基准
      --livetext-selftest    Live Text 环境探测
      --agent <status|…>     自启动各通道的原始状态
      --default-hotkeys      出厂默认截图快捷键（打包脚本写进「使用说明」用）
      --help                 就是这张清单（热键那两行从当前设置读，不手抄）

    图形界面没起来时先看这两条：--diagnose（权限/显示器）、--logic-selftest（截图裁得对不对）
    自检那几档（--ui-render / --logic-selftest / --ocr-selftest 等）是无头的：
    不开窗口、不占菜单栏、不抢焦点，跑起来不会盖到你正在做的事情上。
    """
}

/// 这些分支只往 stdout 报数，不该在屏幕上出现任何东西：窗口不上屏、菜单栏不留图标。
/// （`--diagnose` 不在里面：它可能要替用户打开系统设置，那是用户当场要的事。）
let headlessFlags: [String] = ["--ui-render", "--ui-preview", "--logic-selftest",
                               "--ocr-selftest", "--ocr-quality", "--ocr-bench",
                               "--livetext-selftest", "--shot", "--ocr", "--help"]

if isCLIMode {
    _ = NSApplication.shared
    Headless.active = headlessFlags.contains { arguments.contains($0) }
    NSApp.setActivationPolicy(Headless.active ? .prohibited : .accessory)
}

if let index = arguments.firstIndex(of: "--ocr") {
    let path = arguments.indices.contains(index + 1) ? arguments[index + 1] : ""
    guard !path.isEmpty else {
        print("用法: Grabi --ocr <图片路径>")
        exit(1)
    }
    Diagnostics.runOCR(path: path)
}

if arguments.contains("--shot") {
    Diagnostics.runShotTest()
}

if let index = arguments.firstIndex(of: "--ui-preview") {
    let output = arguments.indices.contains(index + 1)
        ? arguments[index + 1] : "/tmp/grabi-ui-preview.png"
    Diagnostics.runUIPreview(to: output)
}

// 离屏渲染自检：不需要屏幕录制权限、也不需要亮着的显示器，
// 把界面组件真的画成 PNG 来看。
if let index = arguments.firstIndex(of: "--ui-render") {
    let output = arguments.indices.contains(index + 1)
        ? arguments[index + 1] : "/tmp/grabi-ui"
    UIRenderSelfTest.run(to: output)
}

if arguments.contains("--ocr-selftest") {
    Diagnostics.runOCRSelfTest()
}

// 纯逻辑自检：坐标换算、裁剪、窗口位置、文件名模板。同样不需要权限和显示器。
if arguments.contains("--logic-selftest") {
    Diagnostics.runLogicSelfTest()
}

if arguments.contains("--ocr-quality") {
    Diagnostics.runOCRQuality()
}

if arguments.contains("--ocr-bench") {
    Diagnostics.runOCRBench()
}

// 出厂默认快捷键（不是当前设置）：分发用的「使用说明」要的是"新机器上按什么"，
// 拿当前设置去填会把开发机改过的键位发给别人。
if arguments.contains("--default-hotkeys") {
    print(HotKeySpec.defaultCapture.displayString)
    exit(0)
}

if arguments.contains("--livetext-selftest") {
    Diagnostics.runLiveTextSelfTest()
}

if let index = arguments.firstIndex(of: "--agent") {
    let action = arguments.indices.contains(index + 1) ? arguments[index + 1] : "status"
    Diagnostics.runAgentCommand(action)
}

if arguments.contains("--diagnose") {
    Diagnostics.runDiagnose()
}

if arguments.contains("--help") || arguments.contains("-h") {
    print(usageText())
    exit(0)
}

// 走到这里说明带了 `--xxx`，但上面没有一条命中 —— 那就是参数不存在
// （十有八九是打错或还没实现的自检名）。以前的行为是**照样把菜单栏 app 启动起来**，
// 于是终端看起来像"命令卡住了"，而真相是"你写的参数没有这个"。
// 自检命令就该对参数严格：报错要报得像个错误。
if let unknown = arguments.first(where: { $0.hasPrefix("--") && !CLI.knownFlags.contains($0) }) {
    print("未知参数：\(unknown)\n")
    print(usageText())
    exit(2)
}

// MARK: - 正常启动（菜单栏应用）

// 先拿进程级单实例锁，再初始化 NSApplication。后台 agent 是直接执行二进制的，
// 不会经过 LaunchServices 的单实例去重；这一步保证“点开第二个”只会唤醒已有实例，
// 不会多出一个菜单栏图标。重复实例以 0 退出，避免被保活 agent 当成崩溃重启。
guard SingleInstance.shared.acquire() else {
    SingleInstance.shared.requestReopen()
    exit(0)
}
defer { SingleInstance.shared.release() }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 无 Dock 图标
app.delegate = Bootstrap.controller
// 标准主菜单：⌘C/⌘V/⌘A/⌘W/⌘Q 这些系统快捷键靠主菜单派发，缺了它
// 输入框就粘贴不进去，app 激活时顶部也只剩一排空菜单（见 MainMenu.swift）。
MainMenu.install()
app.run()

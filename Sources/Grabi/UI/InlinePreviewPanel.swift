import AppKit
import CoreGraphics

/// 调整选区时的全屏覆盖层：**和「区域截图」一模一样**。
///
/// 整屏压暗 + 选区挖空，挖空处露出**截图那一刻的整屏原图**，边缘八个手柄。
/// 拖动时看到的是"在同一张原图上重新框一块"，既不是拉伸已截好的图，
/// 也不是实时屏幕——后者会让改大改小后的画面和原图不是同一帧。
///
/// 选区被限制在**一块屏幕**内（和区域截图一致），不做跨屏拼接。
final class SelectionAdjustOverlay {

    private var windows: [AdjustWindow] = []
    private var masks: [DimOverlayView] = []
    private var handlesView: ResizeHandlesView?
    private weak var targetScreen: NSScreen?
    /// 原图的像素倍率，只用于选区角标那句「宽 × 高」和裁切保持一致。
    private var sourceScaleX: CGFloat?
    private var sourceScaleY: CGFloat?

    private var currentRect: CGRect = .zero

    /// 调整结束（松手或 Esc）时回调，参数是最终选区。拆窗口由覆盖层自己做。
    /// 外部只管"拿到结果之后怎么办"。
    var onFinish: ((CGRect?) -> Void)?

    /// 开始调整。`rect` 是当前选区（屏幕坐标，原点左下）。
    /// `source` 是整屏原图；nil 时挖空处会露出实时屏幕（旧观感兜底）。
    ///
    /// ⚠️ 覆盖层的窗口一律 `ignoresMouseEvents = true`——它只负责"看"，
    /// 不负责"接"。鼠标事件全程留在**预览面板**的手柄上，由外部用
    /// `apply(handle:delta:)` / `commit()` 驱动。
    ///
    /// 之前是让覆盖层接管：按下发生在预览窗口，拖动要跨到覆盖层窗口"接力"。
    /// 那个交接不可靠——实测表现为"光标已经变成方向箭头，但拖不动"，
    /// 因为跨窗口后 AppKit 未必把 mouseDragged 送到新窗口的手柄上。
    /// 让覆盖层穿透之后，整趟拖动只有一个窗口参与，问题从根上消失。
    /// （窗口仍然 `makeKey`，Esc 取消照常可用——`ignoresMouseEvents`
    ///   只挡鼠标，不挡键盘。）
    func begin(screen: NSScreen, rect: CGRect, source: ScreenCapture?) {
        dismissWindows()

        self.targetScreen = screen
        self.currentRect = rect
        self.sourceScaleX = source?.scaleX
        self.sourceScaleY = source?.scaleY

        for target in NSScreen.screens {
            // 用调用方传进来的屏幕对象认目标，而不是用 rect 中心点猜：
            // 多屏时中心点可能落在两屏之间的空档，猜出来会铺错屏幕。
            let isTarget = target === screen
            let window = AdjustWindow(contentRect: target.frame,
                                      styleMask: .borderless,
                                      backing: .buffered,
                                      defer: false,
                                      screen: target)
            window.setFrame(target.frame, display: false)
            window.animationBehavior = .none
            window.level = ShotLevels.overlay    // 必须在预览面板之上
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.ignoresMouseEvents = true      // 纯视觉，鼠标穿透到下面的预览面板
            window.acceptsMouseMovedEvents = true
            window.onCancel = { [weak self] in self?.abort() }

            let mask = DimOverlayView(frame: NSRect(origin: .zero, size: target.frame.size))
            if isTarget { mask.sourceImage = source?.image }
            window.contentView = mask
            window.orderFrontRegardless()

            windows.append(window)
            masks.append(mask)

            // 手柄只挂在选区所在的那块屏上，纯绘制用
            if isTarget {
                let handles = ResizeHandlesView(frame: .zero)
                handles.isInteractionEnabled = false      // 不接管，只画
                mask.addSubview(handles)
                handlesView = handles
            }
        }

        layout(currentRect)
        // ⚠️ 这里**不能**调 `NSApp.activate(ignoringOtherApps:)`：
        // 本函数是在 `mouseDown` 里调用的，中途激活 app 会打断这一次拖动，
        // 表现就是"第一次按下去没反应，得再点一下"。
        // 只把覆盖层设为 key，Esc 取消照样能用（`ignoresMouseEvents` 不挡键盘）。
        windows.first(where: { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) })?.makeKey()
    }

    /// 拖动中：按增量调整选区。
    func apply(handle: ResizeHandlesView.Handle, delta: CGSize) {
        var rect = currentRect
        switch handle {
        case .left:        rect = CGRect(x: rect.minX + delta.width, y: rect.minY,
                                         width: rect.width - delta.width, height: rect.height)
        case .right:       rect = CGRect(x: rect.minX, y: rect.minY,
                                         width: rect.width + delta.width, height: rect.height)
        case .bottom:      rect = CGRect(x: rect.minX, y: rect.minY + delta.height,
                                         width: rect.width, height: rect.height - delta.height)
        case .top:         rect = CGRect(x: rect.minX, y: rect.minY,
                                         width: rect.width, height: rect.height + delta.height)
        case .bottomLeft:  rect = CGRect(x: rect.minX + delta.width, y: rect.minY + delta.height,
                                         width: rect.width - delta.width, height: rect.height - delta.height)
        case .bottomRight: rect = CGRect(x: rect.minX, y: rect.minY + delta.height,
                                         width: rect.width + delta.width, height: rect.height - delta.height)
        case .topLeft:     rect = CGRect(x: rect.minX + delta.width, y: rect.minY,
                                         width: rect.width - delta.width, height: rect.height + delta.height)
        case .topRight:    rect = CGRect(x: rect.minX, y: rect.minY,
                                         width: rect.width + delta.width, height: rect.height + delta.height)
        }

        layout(clamp(rect))
    }

    /// 松手：把当前选区交给外部裁切，**再**拆覆盖层。
    ///
    /// 顺序不能反：外部会趁覆盖层还在的时候把新预览和新压暗层铺到它下面，
    /// 等覆盖层一撤，用户直接看到新图。先拆的话，覆盖层和预览之间会露出一帧
    /// 实时桌面——就是「松手闪一下」。
    func commit() {
        let result = currentRect
        let callback = onFinish
        onFinish = nil
        callback?(result)
        dismissWindows()
    }

    /// Esc / ⌘W：这次调整作废，回到原选区（不提交半途的尺寸）。
    /// 传 nil 给外部 = "白拖一次"，外部按原 `currentRect` 把预览铺回去。
    func abort() {
        let callback = onFinish
        onFinish = nil
        callback?(nil)
        dismissWindows()
    }

    /// 强行拆掉，不通知任何人（预览面板被关掉时用）。
    func cancel() {
        dismissWindows()
        onFinish = nil
    }

    private func clamp(_ rect: CGRect) -> CGRect {
        guard let screen = targetScreen else { return rect }
        var result = rect.intersection(screen.frame)
        guard !result.isNull else { return result }
        // 补足最小尺寸后必须重新贴回屏幕内，不能只改宽高把右边/上边顶出屏。
        let minSize: CGFloat = 48
        if result.width < minSize {
            result.origin.x = min(max(result.minX, screen.frame.minX),
                                  screen.frame.maxX - minSize)
            result.size.width = minSize
        }
        if result.height < minSize {
            result.origin.y = min(max(result.minY, screen.frame.minY),
                                  screen.frame.maxY - minSize)
            result.size.height = minSize
        }
        return result
    }

    /// 把选区铺到各块屏的覆盖层上：压暗层挖空 + 手柄移到新位置。
    private func layout(_ rect: CGRect) {
        currentRect = rect

        for (window, mask) in zip(windows, masks) {
            let frame = window.frame
            // 屏幕坐标（原点主屏左下）→ 该屏内容视图坐标
            let local = CGRect(x: rect.minX - frame.minX,
                               y: rect.minY - frame.minY,
                               width: rect.width,
                               height: rect.height)
            let visible = local.intersection(mask.bounds)
            mask.holeRect = visible.isNull ? nil : visible
            mask.badgeText = Self.badge(for: rect,
                                        scaleX: sourceScaleX,
                                        scaleY: sourceScaleY)
        }

        handlesView?.frame = CGRect(x: rect.minX - (targetScreen?.frame.minX ?? 0),
                                    y: rect.minY - (targetScreen?.frame.minY ?? 0),
                                    width: rect.width,
                                    height: rect.height)
        handlesView?.needsDisplay = true
    }

    private static func badge(for rect: CGRect,
                              scaleX: CGFloat?,
                              scaleY: CGFloat?) -> String {
        // 倍率跟写盘同源：有原图时直接用抓图那一刻的像素倍率，
        // 和文件里实际落的 DPI 是同一个数，不然「显示 2880×1620，插进文档却是 2 倍大」。
        // 没有原图才退回按当前屏幕算。
        let fallback = ScreenGeometry.scale(of: rect)
        let x = scaleX ?? fallback
        let y = scaleY ?? fallback
        return "\(Int((rect.width * x).rounded())) × \(Int((rect.height * y).rounded()))"
    }

    private func dismissWindows() {
        for window in windows {
            window.alphaValue = 0
            window.orderOut(nil)
        }
        windows.removeAll()
        masks.removeAll()
        handlesView = nil
    }
}

/// 调整选区用的覆盖窗口：能接 Esc。
final class AdjustWindow: NSWindow {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// 同 ⌘W 的处理：让「关闭」等同于按 Esc 取消调整，
    /// 别让无边框窗口被菜单直接拆掉、留下没人收尾的拖拽状态。
    override func performClose(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        super.keyDown(with: event)
    }
}

/// 超时标记。只是一个"时间到了"的信号，用来把界面从等待中解放出来。
private struct Timeout: Error {}

/// 截图完成后的**就地预览**。
///
/// 三个窗口协同：
///
/// | 窗口 | 作用 |
/// |---|---|
/// | `dimPanels`    | 每块屏一层压暗、选区挖空 —— 和截图时的观感一致，焦点始终落在截图上 |
/// | `previewPanel` | 图片预览，尺寸/位置 = 选区，**可以拖动** |
/// | `toolbarPanel` | 浮动工具栏，截图后可见，拖动预览后自动隐藏 |
///
/// 识别文字后再叠一层**隐形文字层**。做法参考成熟实现
/// （fffoivos/image-text-selector 的 "invisible text layer"、Umi-OCR 的高亮展示）：
/// 文字层平时把文字和背景都设成透明，原图上的字保持清晰；
/// 只有拖选时才由系统画出「每行一条连续高亮带」。这样既不遮挡原图，
/// 又能像正常文本一样选中复制。
///
/// 识别完成的反馈走工具栏和角标；文字层本身始终透明，
/// 只有划选时才画琥珀色提示带，避免在浅色截图上盖住正文。
///
/// **这块面板就是"这张图去哪儿"的那个决定点。** 截图本身既不落盘、也不自动进剪贴板 ——
/// 文件要按「保留」才有，剪贴板要按「复制图片」才进（`url` 在此之前一直是 nil）。
/// 复制成功后提示并保留面板；失败则留在原地重试。自动进剪贴板那一版，会在用户还没决定
/// 要不要留的时候，就把他刚复制的东西顶掉。
///
/// | 出口 | 结果 |
/// |---|---|
/// | 「保留」/ ⏎ | 写出文件后收面板，并提示已保存 |
/// | 「复制图片」/ ⌘C | 进剪贴板后保留面板，不自动保存 |
/// | OCR「复制选中 / 复制全文」 | 进剪贴板后保留面板 |
/// | Esc / ⌘W / 点面板以外 | 收走面板，不写盘，剪贴板一个字节都不动 |
/// | 「丢弃」 | 没保留过：关掉面板，不写文件、也不动剪贴板；已保留过：把那份文件挪进废纸篓 |
///
/// 所以「丢弃」的 tooltip 必须跟着状态换一句 —— 它删的可能是磁盘上那一份，
/// 也可能只是关掉面板，写成一句就有一半是假的。
final class InlinePreviewController: NSObject {

    /// 面板关闭的原因。
    ///
    /// 外层只该在「保存成功」时弹文件角标；复制、点外部、换下一张都会走到关闭，
    /// 用一条布尔“suppress”表达所有情况会把这些路径混在一起。
    enum DismissReason {
        case saved
        case copied
        case cancelled
        case replaced
    }

    /// 「保留」时把这张图交出去落盘。返回 nil = 没写成（原因由协调者说），
    /// 面板**不关** —— 这张图还在面板上，用户还可以换个保存位置再按一次。
    /// 第三个参数是已经识别出来的整段文字：勾了「识别结果存成同名 .txt」时它得跟着
    /// 图一起落盘，而"同名"在图还不存在的时候根本没有名可对。
    var onSave: ((CGImage, CGRect, String?) -> URL?)?
    /// 已经落盘之后按「丢弃」：把那份文件挪进废纸篓。返回 `false` = 没挪成，
    /// 面板保持打开（见 `discard()`）。没落盘时压根不调它 —— 那时没东西可删。
    var onDiscard: ((URL) -> Bool)?
    /// `suppressFileToast` = 这次关闭是复制成功触发的。复制刚给过回执，
    /// 关闭时再弹「已保留」会把它顶掉；文件该覆盖的仍然会覆盖。
    var onClosed: ((DismissReason) -> Void)?

    /// 压暗层。每块屏一张面板 —— 截图时的遮罩本来就是全屏铺满的，
    /// 预览阶段只压暗选区所在那块屏的话，多屏下会出现"一半亮一半暗"的割裂感。
    private var dimPanels: [NSPanel] = []
    /// 就地预览面板。类型是 `PreviewPanel`（能接键盘），但它**不能**让系统按
    /// 屏幕可见范围去"放"这些无边框窗口 —— 见 `buildPreviewPanel` 里那两行的说明。
    private var previewPanel: PreviewPanel?
    private var toolbarPanel: NSPanel?
    private var previewView: ImagePreviewView?
    private var handlesView: ResizeHandlesView?
    /// 右上角那颗「×」。钉住那一刻如果鼠标已经在图上，它必须当场出现，
    /// 不能等用户把鼠标移出去再移回来（见 `pinIfNeeded`）。
    private var closeButton: NSButton?
    /// 鼠标此刻是否在预览图上。`onHoverChanged` 只在进出时回调，
    /// 拖动过程中指针一直没离开，钉住时得问这个状态才知道「×」该不该出来。
    private var isHoveringPreview = false

    /// 当前显示的图。OCR 用的也是它。
    private var image: CGImage?
    /// 截图那一刻的整屏原图。拖边框改选区时只从它重新裁一块——
    /// 不再回头抓屏，所以画面永远停在按下快门的那一帧。
    private var source: ScreenCapture?
    /// 已经落盘的那一份。nil = 这张图目前只在剪贴板里，按「保留」才会有文件。
    private var url: URL?

    /// 预览面板（也就是选区）当前占据的屏幕矩形。拖手柄改的就是它，
    /// 松手后按它在**整屏原图**上重新裁一块。
    private var currentRect: CGRect = .zero
    private var currentScreen: NSScreen?

    /// 工具栏形态。切换时带动画，别让按钮"跳变"。
    ///
    /// 刻意不设为 private：离屏渲染自检（`UIRenderSelfTest`）要逐种形态画一遍，
    /// 复制一份按钮定义就会验成"看着像但其实不是"的赝品。
    ///
    /// 这里只管"这一排在讲什么"，不管那张图存没存过 —— 后者是 `saved` 那一个轴，
    /// 四种形态共用（见 `keepDiscardButtons(saved:)`）。
    enum ToolbarMode {
        /// 刚截完图：识别文字 / 保留 / 丢弃
        case normal
        /// 识别进行中：只留一个转圈（模型冷启动可能几十秒，必须让用户知道在跑）
        case busy
        /// OCR 模式：复制选中 / 复制全文 / 复制图片 / 回到图片 / 保存或丢弃
        case ocr
        /// 出错 / 超时：一个警告图标 + 一行短说明，几秒后自动回到正常态
        case failure(String)
    }

    /// 识别失败/超时的提示文案。非空时工具栏显示它，几秒后自动清掉。
    private var failureText: String?
    private var failureResetTimer: Timer?

    private var isOCRMode = false
    /// 预览显示倍率。只影响"看多大"，不改截图内容、选区或保存像素。
    private var previewZoom: CGFloat = 1
    private var zoomHintShown = false
    /// 识别出的文字行（带位置）。高亮层靠它画框。
    private var ocrLines: [OCRRecognizer.Line] = []
    private let recognizer = OCRRecognizer()
    private var isRecognizing = false

    /// 识别任务的代际。每次换图（show / dismiss / 改选区重裁）都递增：
    /// Vision 没法真正取消，旧任务回来时必须靠这个数认出"我已经不代表当前这张图"，
    /// 否则截图 A 的结果会装到截图 B 的预览和高亮层上。
    private var ocrGeneration = 0
    /// 在途的识别任务。换图 / 关面板时取消，并且和 `ocrGeneration` 双重把关。
    private var ocrTask: Task<Void, Never>?

    /// 面板一浮出就**抢跑**的那一趟识别。
    ///
    /// 思路来自 TextGrabber2：它监听剪贴板，图片一变就静默识别并缓存，
    /// 等用户打开菜单时结果早就在手上了——**不是预热，是抢跑**。
    /// 对我们就是：预览面板出来的那一刻就开跑，用户点「识别文字」时
    /// 大概率只是"取回已算好的结果"；用户不点，代价也就是一次后台识别。
    private var prefetchTask: Task<[OCRRecognizer.Line], Error>?

    /// 工具栏那条浮条的高度。离屏自检也按这个数开画布 —— 自己抄一个 42 就是第二份真相。
    /// 42 → 46：按钮从 `.small` 放大一档之后要放得下 30pt 的命中区和悬停底，
    /// 42 会把上下各压掉 2pt，悬停底贴着浮条边缘。
    static let toolbarHeight: CGFloat = 46
    /// 整排的宽度上限（pt）。放不下时 `toolbarOrigin` 有夹取兜底，但"靠兜底"不是设计：
    /// 这个数的作用是把"又往这一排塞了一颗按钮"变成一次红线，而不是一次默默变宽。
    ///
    /// 旧上限 660 是按 `.small` 按钮量出来的；按钮放大一档、留出 30pt 命中区之后
    /// OCR 那一档更宽。上限跟着放到 780（仍留余量），再加一颗按钮照样撞红。
    static let toolbarWidthCeiling: CGFloat = 780
    private let toolbarHeight: CGFloat = InlinePreviewController.toolbarHeight
    private let toolbarGap: CGFloat = 10

    /// 预览面板四周留出的透明边距，专门用来容纳投影。
    ///
    /// 窗口的 `hasShadow` 在 borderless + 透明背景的窗口上常常画不出阴影，
    /// 所以改成给 contentView 的 layer 加 shadow。而 layer shadow 会被窗口
    /// 边界裁掉，必须先把窗口撑大一圈、图片内缩绘制。
    ///
    /// 做成静态常量是为了让 `previewFrame(for:zoom:)` 那份纯几何有个唯一出处 ——
    /// 自检要拿它直接量"拖多远 = 屏幕上走多远"，再抄一个 18 就是第二份真相。
    static let shadowPadding: CGFloat = 18

    private var shadowPadding: CGFloat { Self.shadowPadding }

    /// 拖动过就不再压暗（拖走说明用户想看别处，继续压暗反而碍事）。
    private var didMovePreview = false

    /// 用户有没有明确把这张"钉"到屏幕上（拖走 / 缩放之后）。
    ///
    /// 刚截完还没动过时，预览是**有主的浮层**：点一下就收走，符合"截完立刻去粘贴"。
    /// 一旦用户把它拖到别处、或调过观看倍率，它就从"刚截的那一瞬"变成了"我正在看的
    /// 东西"——这时点什么都不该把它消掉，只能按 Esc、角落那颗「×」、或明说的关闭。
    private var isPinned = false
    /// 点击预览/工具栏以外即收走面板的全局监听。拖动 / 缩放之后由 `isPinned` 挡住。
    private var clickAwayMonitor: Any?

    /// 刚浮出来的预览算不算"钉住"。给自检对账用：这里恒为 false，
    /// 是"点一下别处收走"那条路的准入条件（见 `closesOnClickAway`）。
    static let startsPinned = false

    /// 点别处要不要收走面板。**只有还没钉住的时候才收** ——
    /// 拖走 / 缩放过之后，这张就是用户在盯着看的东西，点任何地方都不该让它消失。
    static func closesOnClickAway(isPinned: Bool) -> Bool { !isPinned }

    /// 边框手柄只服务“还没拖走的原始预览”。固定态只允许滚轮缩放。
    static func allowsSelectionResize(isPinned: Bool) -> Bool { !isPinned }

    /// 有原图、且选区整块落在原图覆盖的屏幕内，才谈得上"在原图上改尺寸"。
    /// 窗口跨屏被裁到一块屏内之后正常；真遇到覆盖不全的情况宁可不给手柄，
    /// 也不让用户拖着拖着换到另一张图上。
    static func canResizeSelection(source: ScreenCapture?, selectionRect: CGRect) -> Bool {
        guard let source else { return false }
        return source.screenFrame.contains(selectionRect)
    }

    var isVisible: Bool { previewPanel != nil }

    /// 覆盖层撤掉后把键盘焦点交回预览（Esc / 回车 / ⌘C 才有主）。
    func focus() { previewPanel?.makeKey() }

    // MARK: - 显示

    /// 浮出预览。
    ///
    /// 参数里**没有 url**：这一刻还没有文件，图也还没进剪贴板。
    /// 文件要等用户按「保留」，剪贴板要等用户按「复制」才存在。
    ///
    /// - Parameters:
    ///   - selectionRect: 选区在屏幕坐标系（原点主屏左下）中的矩形。
    ///   - screen: 选区所在屏幕，用于铺压暗层和摆放工具栏。
    ///   - source: 截图那一刻的整屏原图；拖手柄改选区时从它重新裁。
    ///     nil = 没有可裁的原图（理论上不该发生），手柄会停用。
    func show(image: CGImage,
              selectionRect: CGRect,
              screen: NSScreen?,
              source: ScreenCapture?) {
        dismissIfVisible()

        self.image = image
        self.source = source
        self.url = nil
        self.isOCRMode = false
        self.previewZoom = 1
        self.zoomHintShown = false
        self.ocrLines = []
        self.didMovePreview = false
        self.isPinned = false
        self.isHoveringPreview = false
        self.closeButton = nil
        self.setResizeHandlesEnabled(Self.canResizeSelection(source: source,
                                                             selectionRect: selectionRect))
        self.prefetchTask?.cancel()
        self.prefetchTask = nil
        // 上一张图的 OCR 可能还在跑（Vision 不响应取消），换图时必须换代：
        // 旧任务回来时不能把上一张的字装到这一张上，也不能让新图的
        // 「识别文字」被旧的 `isRecognizing` 一直挡着。
        self.ocrGeneration += 1
        self.ocrTask?.cancel()
        self.ocrTask = nil
        self.isRecognizing = false
        self.failureResetTimer?.invalidate()
        self.failureResetTimer = nil
        self.failureText = nil
        // 每一张新截图从干净开始：上一张的圈画指的是上一张的像素，
        // 跟着挪过来只会变成盖在新内容上的旧痕迹。
        self.inkTool = nil
        // 笔色 / 线宽 / 上次用的形状**跟着人走，不跟着这张图走**：下一张截图还是想
        // 用同一支红笔，而不是每张都从默认档重挑一遍。收掉的只是画上去的那些笔。
        self.currentRect = selectionRect
        self.currentScreen = screen ?? Self.screenUnderMouse()

        buildDimPanel(for: selectionRect)
        buildPreviewPanel(for: selectionRect)
        buildToolbarPanel()

        // 图片本身直接到最终状态：压暗层的挖空是透明的，图片 alpha 从 0 升上来的
        // 这零点几秒里，挖空里露的是实时屏幕——就是"闪一下"。
        // 进场动效落在**不暴露桌面**的两处：阴影从无到有地长出来，工具栏从下方浮上来。
        previewPanel?.alphaValue = 1
        toolbarPanel?.alphaValue = 1
        playPreviewEntrance()

        // 键盘通路：截图时 overlay 已经把本 app 激活了，这里让预览面板接管 key，
        // Esc / 回车 / ⌘C 才能被它接住（否则面板永远收不到键盘事件）。
        // ⏎ = 保留（写文件）；Esc / ⌘W = 收走面板，不写文件、也不动剪贴板。
        previewPanel?.onEscape = { [weak self] in self?.pressEscape() }
        previewPanel?.onKeep = { [weak self] in
            guard let self,
                  !Self.blocksKeepWhileSelectingText(isOCRMode: self.isOCRMode,
                                                     hasSelection: self.hasSelectedText) else {
                return
            }
            self.keep()
        }
        previewPanel?.onCopy = { [weak self] in self?.copyCurrent() }
        // 主菜单「视图」里的三条 zoom 动作 target 留 nil，靠响应链找到 key window。
        // `InlinePreviewController` 是普通 NSObject，不在响应链里；必须由 `PreviewPanel`
        // 转发回来，否则这三条菜单项永远是灰的（快捷键 ⌘= / ⌘- / ⌘1 也一起失效）。
        previewPanel?.onZoomIn = { [weak self] in self?.zoomIn(nil) }
        previewPanel?.onZoomOut = { [weak self] in self?.zoomOut(nil) }
        previewPanel?.onZoomReset = { [weak self] in self?.resetZoom(nil) }
        previewPanel?.onInkAction = { [weak self] action in
            switch action {
            case .undo: self?.undoInk()
            case .pen: self?.togglePen()
            case .shape: self?.setInkTool(.shape(self?.lastShape ?? .rectangle))
            }
        }
        setResizeHandlesEnabled(Self.canResizeSelection(source: source,
                                                         selectionRect: selectionRect))
        previewPanel?.makeKey()
        // 画完一笔要立刻重画工具栏：那颗「撤销」从灰变亮，是唯一说明
        // "这一笔收下了"的反馈（图上已经画了，但按钮不动的话人不敢信）。
        previewView?.inkLayer.onChange = { [weak self] in self?.rebuildToolbar(animated: false) }
        previewView?.inkLayer.color = inkColor
        previewView?.inkLayer.screenWidth = inkWidth

        installClickAwayMonitor()
        startPrefetchingOCR()
    }

    /// 点预览 / 工具栏以外的任意处收走面板 —— **但只在还没把这张钉住的时候**。
    ///
    /// 刚截完那一瞬，点一下就收走最顺手（用户多半是要立刻去粘贴）。
    /// 一旦拖走或缩放过，这张就变成了"我正在看的东西"：再点别处把它消掉，
    /// 等于用户一动鼠标图就没了。所以那条路要用 `isPinned` 挡住。
    ///
    /// 用**全局**鼠标监听：它只在事件被送往「别的 app」时触发，所以点我们自己的
    /// 按钮不受影响；而压暗层是鼠标穿透的，点它等于点到下面的 app，照样能触发关闭。
    /// 鼠标全局监听不需要辅助功能权限（键盘全局监听才需要），成本为零。
    private func installClickAwayMonitor() {
        guard clickAwayMonitor == nil else { return }
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self, Self.closesOnClickAway(isPinned: self.isPinned) else { return }
            self.dismiss(reason: .cancelled)
        }
    }

    private func removeClickAwayMonitor() {
        if let clickAwayMonitor { NSEvent.removeMonitor(clickAwayMonitor) }
        clickAwayMonitor = nil
    }

    /// ⌘C：OCR 模式下复制选中文字（无选中则全部），否则复制整张图片。
    private func copyCurrent() {
        // 两条路都走工具栏那颗按钮同一个函数，不是"再复制一遍"的第二份写法：
        // 分开写的话，一条回读了剪贴板、一条没回读，⌘C 就成了那个不说谎也没说真话的。
        guard isOCRMode else { return copyImageToClipboard() }
        // 键盘 ⌘C 保留"没划选就直接复制全部"的顺手路径（文档和工具栏 tooltip
        // 都是这么承诺的）；工具栏那颗「复制选中」才严格照划选走、没划选时提示。
        if hasSelectedText {
            copySelectedText()
        } else {
            copyAllText()
        }
    }

    /// 文字层上此刻有没有划选。
    private var hasSelectedText: Bool {
        !(previewView?.highlightView.selectedText ?? "").isEmpty
    }

    /// 划着字时回车不该保存并关闭面板：这一下属于文本选择，不属于“完成截图”。
    static func blocksKeepWhileSelectingText(isOCRMode: Bool, hasSelection: Bool) -> Bool {
        isOCRMode && hasSelection
    }

    static func allowsPanelDragging(isOCRMode: Bool) -> Bool {
        !isOCRMode
    }

    // MARK: 右键菜单

    /// 预览图上的右键菜单。
    ///
    /// 存在的理由：工具栏按需求做得很极简，于是"去访达里找它"这类常用出口
    /// 在界面上就没有了落脚点。上下文菜单是不占屏幕空间的正确位置 ——
    /// 而"在访达中显示"这件事早就有实现（`SystemOpen.reveal`），只差一个入口。
    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        for entry in Self.contextMenuItems(isOCRMode: isOCRMode, saved: url != nil) {
            // 分隔线按"这一组在讲什么"插：文字一组、图片一组、去留一组。
            // 它不进那份清单 —— 清单要和工具栏对账，而分隔线不是一个动作。
            //
            // 前面一条都没有时**不插**：已保存那一档「复制图片」就是第一条，
            // 不加这个判断菜单顶上会悬着一条没有上文的线。
            if !menu.items.isEmpty,
               entry.action == #selector(copyImageToClipboard)
                   || entry.action == #selector(keep) {
                menu.addItem(.separator())
            }
            menu.addItem(menuItem(entry.title, entry.symbol, entry.action))
        }
        return menu
    }

    /// 右键菜单里的那几项（标题 / 图标 / 动作），**菜单和自检读同一份**。
    ///
    /// 摊成数据而不是只留一个 `NSMenu`：动作名要和工具栏对账（同一个动作不许有
    /// 两个名字 —— 「全部」和「复制全部文字」就是两个名字，光看按钮不知道是
    /// 复制全部还是全选文字），而"没落盘就不摆文件动作""target 绑给谁"这些
    /// 和名字对账无关，不该把对账绑在活的预览面板上。
    ///
    /// `saved` 是**这张图有没有变成文件**。没文件时文件类动作按下去只会指向一个
    /// 不存在的路径，所以那一组整组长、整组消。
    ///
    /// 菜单刻意按状态只留**最少**的那几条：这张菜单是"工具栏之外顺手补的那一下"，
    /// 不是工具栏的副本。已保存那档只剩「复制图片 / 在访达中显示」两条 ——
    /// 「打开」「复制路径」和双击文件、拖走文件重复，删掉它们，右键才有意义。
    static func contextMenuItems(isOCRMode: Bool, saved: Bool)
        -> [(title: String, symbol: String, action: Selector)] {
        var items: [(String, String, Selector)] = []
        // OCR 模式下"要复制的是文字"才是当下的意图，所以文字那两条排在图片前面。
        // 「复制选中」严格照划选走，对应需求里“选完字右键一下就能进剪贴板”那一下；
        // 没划选时它和「复制全文」是**两件事**，由各自的动作区分。
        if isOCRMode {
            items.append(("复制选中", "character.cursor.ibeam",
                          #selector(InlinePreviewController.copySelectedText)))
            items.append(("复制全文", "character.textbox",
                          #selector(InlinePreviewController.copyAllText)))
        }
        // 无论存没存过，图都在手里 —— 这一条永远有用。
        // 已经落盘时 `copyImageToClipboard` 会顺带把文件 URL 一起写进剪贴板
        // （见 `ShotCoordinator.copyImageToPasteboard`），所以"复制这一份文件"
        // 不需要再单独占一条。
        items.append(("复制图片", "doc.on.doc",
                      #selector(InlinePreviewController.copyImageToClipboard)))
        if saved {
            items.append(("在访达中显示", "folder", #selector(InlinePreviewController.revealInFinder)))
        } else {
            items.append(("保存", "checkmark", #selector(InlinePreviewController.keep)))
            items.append(("丢弃", "trash", #selector(InlinePreviewController.discard)))
        }
        return items
    }

    private func menuItem(_ title: String, _ symbol: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    @objc private func revealInFinder() {
        guard let url else { return }
        if SystemOpen.reveal(url) {
            dismiss(reason: .cancelled)
        }
    }

    /// 把「要交出去的那一张」放进剪贴板，并且**回读一次再报**。
    ///
    /// 复制的是带标注的那一张：屏幕上圈了红框、粘出去却是干净的，
    /// 等于让用户自己再画一遍。
    /// 以前这里不管剪贴板收没收下都说一句「已复制图片」：那句话是假的，
    /// 而用户正是按这句话决定去别处按 ⌘V 的。
    /// 「复制图片」：把这一张放进剪贴板，并报一句带尺寸的回执。
    ///
    /// 截图本身不再自动进剪贴板（那是"截完还在犹豫要不要留"时最容易被顶掉的
    /// 一步），所以进剪贴板必须是用户明确按的一下。成功后保留面板：
    /// 用户可能要接着复制另一种结果或继续标注，不能复制完就把面板收走。
    @objc private func copyImageToClipboard() {
        guard let outputImage else { return }
        let ok = ShotCoordinator.copyImageToPasteboard(outputImage, fileURL: url)
        reportCopy(ok, dimensions: "\(outputImage.width) × \(outputImage.height) px")
    }

    /// 复制之后那两行字。成功也报尺寸，是因为"复制的是刚圈过、刚裁过的这一张"
    /// 这件事只有数字能证明。
    private func reportCopy(_ ok: Bool, dimensions: String) {
        ToastHUDController.shared.show(title: ok ? "已复制图片" : PasteboardWrite.textFailureTitle,
                                       detail: ok ? "\(dimensions)　·　已在剪贴板里"
                                                  : PasteboardWrite.imageFailureDetail(
                                                    dimensions: dimensions),
                                       thumbnail: ok ? outputImage : nil,
                                       screen: currentScreen,
                                       duration: ok ? 3.2 : 4.8)
    }

    /// 工具栏的「复制选中」：**严格复制此刻划选的那一段**。
    ///
    /// 这里以前在没有划选时静默退化成"复制全部"，于是它和旁边那颗「复制全文」
    /// 表现完全一样 —— 用户点了两颗得到同一个结果，自然会问"这两个按钮有什么区别"。
    /// 现在没划选就明说"先在图上划一段"，不再替用户猜。要复制全部就用右边那颗。
    @objc private func copySelectedText() {
        let selected = previewView?.highlightView.selectedText ?? ""
        guard !selected.isEmpty else {
            ToastHUDController.shared.show(title: "先在图上划一段文字",
                                           detail: "要整页文字请按「复制全文」",
                                           screen: currentScreen,
                                           duration: 3.6)
            return
        }
        copyTextSelection(selected, title: "已复制选中文字")
    }

    // MARK: 压暗层

    /// 每块屏铺一层压暗 + 选区挖空。它们都不接收鼠标事件，点击会穿透到下面的 app。
    private func buildDimPanel(for selectionRect: CGRect) {
        dimPanels = []

        for screen in NSScreen.screens {
            let frame = screen.frame
            let panel = PreviewPanel(contentRect: frame,
                                     styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered,
                                     defer: false)
            panel.isFloatingPanel = true
            panel.animationBehavior = .none
            panel.level = ShotLevels.dim
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true          // 只负责变暗，不挡操作

            let view = DimOverlayView(frame: NSRect(origin: .zero, size: frame.size))
            let local = holeRect(for: selectionRect, on: screen)
            let visible = local.intersection(view.bounds)
            view.holeRect = visible.isNull ? nil : visible
            panel.contentView = view
            panel.setFrame(frame, display: false)
            panel.orderFrontRegardless()

            dimPanels.append(panel)
        }
    }

    private func holeRect(for selectionRect: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(x: selectionRect.minX - screen.frame.minX,
               y: selectionRect.minY - screen.frame.minY,
               width: selectionRect.width,
               height: selectionRect.height)
    }

    // MARK: 预览面板

    private func buildPreviewPanel(for selectionRect: CGRect) {
        // 窗口比图片大一圈，多出来的部分是留给投影的透明边距
        let padded = selectionRect.insetBy(dx: -shadowPadding, dy: -shadowPadding)
        let panel = PreviewPanel(contentRect: padded,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered,
                                 defer: false)
        panel.isFloatingPanel = true
        panel.animationBehavior = .none
        panel.level = ShotLevels.preview
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // 用 layer 阴影代替，见 shadowPadding 的说明
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        // 文字层靠 mouseMoved 做悬停提示，而 mouseMoved 只在窗口开启
        // acceptsMouseMovedEvents 时才会派发——不开的话悬停高亮永远不出现。
        panel.acceptsMouseMovedEvents = true
        panel.setFrame(padded, display: false)

        // 外层：只负责投影，不裁剪。用子类是为了拿到 hover 进出事件 ——
        // 角落那颗「×」只在鼠标进到图上时出现，移开就收起来。
        let container = PreviewHoverContainer(frame: NSRect(origin: .zero, size: padded.size))
        container.wantsLayer = true
        container.layer?.masksToBounds = false
        // 阴影分两层：一层贴边的淡角（把图片从底图上"抠"出来），一层更大更虚的
        // 落影（给出高度感）。单层要么太糊要么太硬 —— 用户说的"优化阴影"就是这一处。
        // 半径和偏移都收在透明边距之内，阴影末端才不会撞到窗口边界、切出一条硬边。
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.30
        container.layer?.shadowRadius = 6
        container.layer?.shadowOffset = CGSize(width: 0, height: -2)
        // 第二层：更虚的落影。用第二个 layer 而不是同一层的参数，是因为一层阴影
        // 没法同时"贴边清晰"又"外围发虚"。
        let ambient = CALayer()
        ambient.masksToBounds = false
        ambient.shadowColor = NSColor.black.cgColor
        // 半径 + 偏移必须留在 `shadowPadding` 之内：阴影是被**窗口边界**裁的，
        // 超出那 18pt 的部分整块没掉，看起来就是"阴影只有上边有、下边被切平"。
        ambient.shadowOpacity = 0.18
        ambient.shadowRadius = 12
        ambient.shadowOffset = CGSize(width: 0, height: -4)
        container.layer?.addSublayer(ambient)
        container.ambientShadow = ambient

        // 内层：真正的图片区域，圆角裁剪。
        //
        // 用约束而不是 autoresizingMask：调边框会改变窗口尺寸，
        // autoresizingMask 只能等比跟随、保不住四周 18pt 的投影边距。
        let view = ImagePreviewView(frame: container.bounds.insetBy(dx: shadowPadding,
                                                                   dy: shadowPadding))
        view.image = image
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        // 不做强调色描边：那样看着像输入框。靠阴影分层才是系统观感，
        // 边框只需要一圈极淡的高光把图片和暗背景分开。
        view.layer?.borderWidth = 0.5
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        view.layer?.cornerRadius = Design.Radius.card
        view.layer?.masksToBounds = true
        // 空白处按住即可拖动整个预览（文字块自己会吃掉事件，不冲突）
        view.onDrag = { [weak self] delta in
            self?.movePreview(by: delta)
        }
        // 右键菜单：常用出口收进上下文菜单，工具栏才能保持极简
        view.contextMenuProvider = { [weak self] in self?.makeContextMenu() }
        // 鼠标进到图上 → 角落浮出「×」；移开 → 收起来。
        let closeButton = makePreviewCloseButton()
        self.closeButton = closeButton
        // 起手是藏着的，而且**不只是"鼠标没在上面"**：刚截完那一档压根不该有「×」，
        // 见 `setCloseButton` 的说明。`mouseEntered` 只负责"钉住之后"那一次的显隐。
        closeButton.alphaValue = 0
        closeButton.isHidden = true
        container.onHoverChanged = { [weak self, weak closeButton] hovering in
            self?.isHoveringPreview = hovering
            guard let closeButton else { return }
            self?.setCloseButton(closeButton, visible: hovering)
        }
        // 右键落在某个字块上：保留用户已经划好的选区；没有选区时才把范围
        // 定在鼠标下这一处。否则"选一段字再右键复制"会退化成只复制一个字。
        view.onHighlightRightClick = { [weak self] unit in
            guard let highlight = self?.previewView?.highlightView else { return }
            // 右键落在已经选中的文字上时保留整段选区；落在别处时才把范围收到
            // 鼠标下这一处。旧实现无条件收缩，正是“选一段后右键只剩一个字”的来源。
            if !highlight.isSelected(unit: unit) {
                highlight.selectUnit(at: unit)
            }
        }
        container.addSubview(view)
        container.addSubview(closeButton)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: shadowPadding),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -shadowPadding),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: shadowPadding),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -shadowPadding),
            // 「×」贴近图片边界，只留 4pt 呼吸位。它在钉住之后才出现，
            // 而手柄只在鼠标落到边缘命中区时才接管，两者不需要用一大段空白隔开。
            closeButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            closeButton.widthAnchor.constraint(equalToConstant: 26),
            closeButton.heightAnchor.constraint(equalToConstant: 26)
        ])

        // 环境落影那一层要跟着图片走：直接把它的路径撑成内层图片的圆角矩形，
        // 阴影才会从图片边缘长出来，而不是从窗口外框（含 18pt 透明边）长出来。
        container.layoutSubtreeIfNeeded()
        container.updateAmbientShadowPath(imageFrame: view.frame)

        // 可调节边框：刚截完时显示八个手柄，拖动它们会在整屏原图上重新框选（不重新截屏）。
        // 一旦预览被拖走进入固定态，这一层会整体停用；之后只能滚轮缩放。
        let handles = ResizeHandlesView(frame: view.bounds)
        handles.translatesAutoresizingMaskIntoConstraints = false
        handles.showsKnobs = true
        handles.textLayer = view.highlightView          // 文字上 I-beam，空白处手掌
        handles.onAdjustBegan = { [weak self] in
            self?.beginAdjustingSelection()
        }
        handles.onAdjust = { [weak self] handle, delta in
            guard let self else { return }
            guard Self.allowsSelectionResize(isPinned: self.isPinned) else { return }
            self.updateAdjustingSelection(handle: handle, delta: delta)
        }
        handles.onAdjustEnded = { [weak self] in
            guard let self else { return }
            guard Self.allowsSelectionResize(isPinned: self.isPinned) else { return }
            self.adjustOverlay.commit()
        }
        view.addSubview(handles)
        NSLayoutConstraint.activate([
            handles.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            handles.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            handles.topAnchor.constraint(equalTo: view.topAnchor),
            handles.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        panel.contentView = container
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        // 不显示状态提示：用户要求界面保持极简，选中/复制结果直接走系统剪贴板。
        view.highlightView.onSelectionChanged = { _ in }
        view.onScroll = { [weak self] event in
            self?.handleZoomScroll(event)
        }

        previewPanel = panel
        previewView = view
        handlesView = handles
    }

    /// 截图变成预览的那一下：图片已经在最终位置，先让它的阴影柔和地落下来，
    /// 再让工具栏从下方 8pt 浮上来。两层错开 40ms，读起来是"图片先稳住、
    /// 操作再跟上"，而不是一块黑条和一张图同时砸在屏幕上。
    private func playPreviewEntrance() {
        animatePreviewShadowIn()

        guard let toolbar = toolbarPanel else { return }
        let target = toolbar.frame.origin
        guard !Motion.isReduced else {
            toolbar.alphaValue = 1
            toolbar.ignoresMouseEvents = false
            return
        }

        toolbar.alphaValue = 0
        toolbar.ignoresMouseEvents = true
        toolbar.setFrameOrigin(NSPoint(x: target.x, y: target.y - 8))
        let delay = Motion.duration(0.04)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.toolbarPanel === toolbar else { return }
            Motion.run(duration: Design.Timing.settle, curve: Motion.Curve.enter) {
                toolbar.animator().alphaValue = 1
                toolbar.animator().setFrameOrigin(target)
            } completion: {
                // 用户可能在 280ms 内就把预览拖走（钉住）。那之后工具栏已经
                // 透明且不该再接鼠标，这里的收尾不能把它重新打开。
                guard self.toolbarPanel === toolbar, !self.isPinned else { return }
                toolbar.ignoresMouseEvents = false
            }
        }
    }

    /// 预览的阴影是"这张图离开桌面、浮起来"的唯一空间信号。
    /// 图片不能缩放（会露出选区外的实时桌面），但阴影可以先短后长、先淡后浓。
    private func animatePreviewShadowIn() {
        guard let container = previewPanel?.contentView as? PreviewHoverContainer,
              let layer = container.layer else { return }
        layer.shadowOpacity = 0.30
        layer.shadowRadius = 6
        container.ambientShadow?.shadowOpacity = 0.18
        container.ambientShadow?.shadowRadius = 12

        guard !Motion.isReduced else { return }
        Motion.animate(layer, keyPath: "shadowOpacity", from: 0, to: 0.30,
                       duration: Design.Timing.settle, curve: Motion.Curve.enter)
        Motion.animate(layer, keyPath: "shadowRadius", from: 1, to: 6,
                       duration: Design.Timing.settle, curve: Motion.Curve.enter)
        if let ambient = container.ambientShadow {
            Motion.animate(ambient, keyPath: "shadowOpacity", from: 0, to: 0.18,
                           duration: Design.Timing.settle, curve: Motion.Curve.enter)
            Motion.animate(ambient, keyPath: "shadowRadius", from: 4, to: 12,
                           duration: Design.Timing.settle, curve: Motion.Curve.enter)
        }
    }

    /// 拖动预览。第一次拖动时撤掉压暗，之后只移动面板本身。
    ///
    /// 拖动即视为"我在看别处 / 我要摆位置"，工具栏自动收起——它挡在图片下方，
    /// 拖来拖去的时候最碍事。点一下收起后的小按钮就能展开回来。
    private func movePreview(by delta: CGSize) {
        // 夹取用的是**鼠标现在在哪块屏**，而不是最初那块：钉住之后这张可以拖到副屏去，
        // 还按老屏的可见区夹的话，一拖到边界就会被拽回来，跨屏根本走不过去。
        let underMouse = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        let screen = underMouse ?? currentScreen
        guard let screen else { return }
        if underMouse != nil, screen !== currentScreen { currentScreen = screen }

        if !didMovePreview {
            didMovePreview = true
            // 拖走 = 用户明确要把这张留在眼前。手柄从此停用，避免面板 frame
            // 和图片内容脱节；需要调整观看大小时只用滚轮。
            pinIfNeeded()
        }

        // 鼠标位移是屏幕点，`currentRect` 也是屏幕点 —— 两者**一比一**，不需要任何
        // 倍率换算。窗口是绕着 `currentRect` 的中心摆放的（见 `previewFrame(for:zoom:)`），
        // 选区挪一个点，窗口原点就跟着挪一个点，和缩放倍率无关。
        //
        // 以前这里写过 `delta / previewZoom`，理由是"缩放过之后两者差一个倍率"。
        // 那个前提不成立：倍率只改窗口的**大小**，坐标原点是同一个屏幕坐标系。
        // 后果正好是用户报的"拖走再缩放之后，越拖越偏"——放大到 4× 时鼠标走 40pt、
        // 面板只走 10pt，看着就是拖不动；缩到 0.25× 时鼠标走 40pt、面板窜出 160pt。
        let logicalDelta = delta
        var moved = currentRect
        moved.origin.x += logicalDelta.width
        moved.origin.y += logicalDelta.height

        // 夹取按"屏幕上实际看到的框"算。窗口空间的修正量同样一比一映射回 `currentRect`：
        // 窗口原点要往右拖 12pt，选区中心就往右挪 12pt。
        let displayed = Self.previewFrame(for: moved, zoom: previewZoom)
        let displayedOrigin = displayed.origin
        let clamped = clamp(displayedOrigin,
                            frameSize: displayed.size,
                            into: screen.visibleFrame)
        moved.origin.x += clamped.x - displayedOrigin.x
        moved.origin.y += clamped.y - displayedOrigin.y
        currentRect = moved
        layoutPreview(at: currentRect, zoom: previewZoom)
        // 工具栏的退场由 `pinIfNeeded()` 统一负责；这里再置一次 0 会把
        // 刚开始的淡出切成硬切。
    }

    /// 滚轮缩放。**只有拖走之后才生效** —— 刚截完还没动过时滚轮不改变任何东西，
    /// 免得"想滚一下页面"顺手把预览放大了。拖走时会给一次提示说明现在能调。
    private func handleZoomScroll(_ event: NSEvent) {
        guard isPinned else { return }
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }
        let factor = exp(delta * 0.025)
        setPreviewZoom(previewZoom * factor)
    }

    private func setPreviewZoom(_ value: CGFloat) {
        let next = min(max(value, 0.25), 4)
        guard abs(next - previewZoom) > 0.001 else { return }
        previewZoom = next
        layoutPreview(at: currentRect, zoom: next)
    }

    /// 主菜单「视图」里的缩放动作。和滚轮走同一个入口，不另存一份倍率。
    /// 菜单里按了缩放也算"把这张钉住"——和滚轮是同一条意图。
    @objc func zoomIn(_ sender: Any?) { pinIfNeeded(); setPreviewZoom(previewZoom * 1.25) }
    @objc func zoomOut(_ sender: Any?) { pinIfNeeded(); setPreviewZoom(previewZoom / 1.25) }
    @objc func resetZoom(_ sender: Any?) { pinIfNeeded(); setPreviewZoom(1) }

    /// 把预览"钉"到屏幕上：撤掉压暗和工具栏，之后点别处不再收走它。
    ///
    /// 只在第一次钉的时候动手（撤压暗、撤工具栏、给一次提示），后面拖 / 缩放
    /// 都只是移动或改大小，不再重复这些副作用。
    private func pinIfNeeded() {
        guard !isPinned else { return }
        isPinned = true
        setResizeHandlesEnabled(false)
        // 提到"钉住的预览"那一层：拖走之后这张要盖过别的 app 的普通窗口，
        // 不能被谁顶到后面去。仍然在全屏覆盖层（截图选区）之下 —— 下一次截图
        // 开始时会先把这张收掉。
        previewPanel?.level = ShotLevels.pinnedPreview
        fadeOutDimPanel()
        // 从"刚截完的浮条"切成"贴在屏幕上的一张图"：工具栏会挡住要看的内容，
        // 而这一刻起操作入口是图上右键和角落那颗「×」。让它退场，不是凭空消失。
        if let toolbar = toolbarPanel {
            toolbar.ignoresMouseEvents = true
            Motion.run(duration: Design.Timing.fade, curve: Motion.Curve.exit) {
                toolbar.animator().alphaValue = 0
            }
        }
        // 拖动进入钉住态时鼠标通常还在图上，`onHoverChanged` 不会重新触发；
        // 这里按当前 hover 状态立刻把「×」补出来，否则用户得先移出去再移回来。
        if let closeButton { setCloseButton(closeButton, visible: isHoveringPreview) }
        ToastHUDController.shared.show(title: "已固定在屏幕上",
                                       detail: "滚轮调整大小　·　右上角「×」关闭　·　点别处不会收走",
                                       screen: currentScreen,
                                       duration: 4.0)
    }

    /// 手柄只属于“还没拖走的原始选区”这一阶段。固定之后停用，
    /// 只保留滚轮缩放，避免拉动手柄改变窗口尺寸时露出黑边。
    private func setResizeHandlesEnabled(_ enabled: Bool) {
        handlesView?.isEnabled = enabled
        handlesView?.isInteractionEnabled = enabled
        handlesView?.showsKnobs = enabled
        handlesView?.fallbackCursor = enabled ? .openHand : .arrow
        if let handlesView {
            handlesView.window?.invalidateCursorRects(for: handlesView)
        }
        if let previewView {
            previewView.window?.invalidateCursorRects(for: previewView)
        }
    }

    // MARK: 可调节边框

    /// 调整选区用的全屏覆盖层。拖动手柄时接管，行为和「区域截图」一致。
    private let adjustOverlay = SelectionAdjustOverlay()

    /// 按下手柄的瞬间切到"选取"模式：藏起预览，铺一层整屏压暗 + 挖空的覆盖层。
    ///
    /// 挖空处露出的是**整屏原图**，不是实时屏幕：改大改小都只在原图上换裁剪矩形，
    /// 不会重新抓屏。底下的窗口、网页在这之后变了也影响不到这张图。
    ///
    /// 覆盖层的窗口 `ignoresMouseEvents = true`：鼠标全程留在预览面板的手柄上，
    /// 松手通过 `finishAdjustingSelection()` 收尾。整趟拖动只涉及一个窗口，
    /// 不会出现"光标变了但拖不动"的接力失败。
    private func beginAdjustingSelection() {
        guard let screen = currentScreen else { return }
        guard let source,
              Self.canResizeSelection(source: source, selectionRect: currentRect)
        else { return }
        guard Self.allowsSelectionResize(isPinned: isPinned) else { return }

        // 先把覆盖层（原图 + 压暗）铺上来，再撤旧预览。反过来的话，
        // 旧压暗撤掉和覆盖层出现之间会漏一帧实时桌面——按下手柄那一下也会闪。
        adjustOverlay.onFinish = { [weak self] rect in
            self?.finishAdjustingSelection(finalRect: rect)
        }
        adjustOverlay.begin(screen: screen, rect: currentRect, source: source)

        // 压暗层必须**立刻**撤掉（不能淡出，拖动时它还在就来不及了）：
        // ① 覆盖层自带压暗，两层叠一起会让选区挖空处也是黑的；
        // ② 它的挖空还是旧选区，会盖在新选区上。
        hideDimPanel()

        // 覆盖层在 `ShotLevels.overlay`，会盖住预览；但预览仍会漏出影子，先藏掉。
        // 工具栏那个窗口层级更高（`ShotLevels.toolbar`），必须一起藏，而且要临时
        // 让它不接鼠标——否则它挡在预览前面，拖动会被它吃掉。钉住之后工具栏本来就
        // 收起来了，这里只处理还没钉的那一档。
        previewPanel?.alphaValue = 0
        if !isPinned {
            toolbarPanel?.alphaValue = 0
            toolbarPanel?.ignoresMouseEvents = true
        }
    }

    /// 拖动中：把增量交给覆盖层。
    private func updateAdjustingSelection(handle: ResizeHandlesView.Handle, delta: CGSize) {
        guard !didMovePreview else { return }
        adjustOverlay.apply(handle: handle, delta: delta)
    }

    /// 松手（Esc 也是这里）：按新选区从**整屏原图**上重新裁一块。
    /// `finalRect` 是覆盖层给出的最终选区；nil 或与原选区相同都算"白拖一次"。
    private func finishAdjustingSelection(finalRect: CGRect?) {
        toolbarPanel?.ignoresMouseEvents = false

        guard let rect = finalRect, rect != currentRect else {
            layoutPreview(at: currentRect)
            if isPinned { fadeOutDimPanel() } else { restoreDimPanel(for: currentRect) }
            showPreview(animated: false)
            return
        }

        // 先裁、裁成功再动窗口：裁失败时如果先把窗口摆到新尺寸，图上还是旧图，
        // 会被拉伸成新宽高，后面保存/复制都拿到一个对不上的选区。
        guard let source, let cropped = source.crop(to: rect) else {
            layoutPreview(at: currentRect)
            if isPinned { fadeOutDimPanel() } else { restoreDimPanel(for: currentRect) }
            showPreview(animated: false)
            showFailure("重新框选失败，保留原来的范围")
            return
        }

        // 压暗层要在松手当帧立刻铺回来：覆盖层撤掉的那一刻如果压暗层不在，
        // 整个屏幕是亮的，等下一帧才暗回去——看起来就是"调节完成后闪一下"。
        // 钉住之后不重新铺压暗：那时用户已经在"看这张图"，压暗反而挡着他要对照的内容。
        if isPinned { hideDimPanel() } else { restoreDimPanel(for: rect) }
        layoutPreview(at: rect)          // 只挪窗口，预览仍是隐藏的
        applySelectionCrop(cropped)      // 换图并 showPreview()
    }

    /// 显示预览与工具栏。
    ///
    /// `animated: false` 用在调整选区收尾：这时覆盖层还盖在上面，
    /// 直接铺到最终状态，等覆盖层撤掉就是一帧接上，不会先亮一下实时桌面。
    private func showPreview(animated: Bool = true) {
        // 钉住之后工具栏保持收起：那一刻起入口是图上右键和角落那颗「×」。
        let panels = isPinned ? [previewPanel] : [previewPanel, toolbarPanel]
        for panel in panels {
            guard let panel, panel.alphaValue < 1 else { continue }
            if animated {
                panel.alphaValue = 0
                Motion.run(duration: Design.Timing.fade, curve: Motion.Curve.enter) {
                    panel.animator().alphaValue = 1
                }
            } else {
                panel.alphaValue = 1
            }
        }
        // 调整选区时 key 曾交给覆盖层窗口，这里拿回来，Esc / ⌘C 才继续有效
        previewPanel?.makeKey()
    }

    /// 预览面板 + 工具栏摆到某个屏幕矩形上。
    private func layoutPreview(at rect: CGRect) {
        layoutPreview(at: rect, zoom: previewZoom)
    }

    /// 某个选区矩形 + 某个倍率 → 预览窗口在屏幕上的 frame。
    ///
    /// **窗口绕着选区的中心摆放，倍率只改大小。** 这一条是拖动换算的前提：
    /// 选区中心挪一个点，窗口原点就跟着挪一个点，和倍率无关（见 `movePreview`）。
    ///
    /// 抽成静态纯函数是为了让自检能直接量这条不变式，而不是复刻一遍算式 ——
    /// 之前拖动除以倍率的那个 bug，就是因为换算和摆放各写了一份、谁也没测。
    static func previewFrame(for rect: CGRect, zoom: CGFloat) -> NSRect {
        // 投影边距是**窗口边到图片边**的固定 18pt，不参与倍率：图片视图的
        // 约束就是 `container ± shadowPadding`。以前把整块 padded 矩形一起乘
        // zoom，于是图片实际大小是 `rect*zoom + 36*(zoom-1)` —— 放大后多出
        // 几十 pt 且横纵比例跟着变，截图内容被非等比拉糊。
        let size = NSSize(width: rect.width * zoom + shadowPadding * 2,
                          height: rect.height * zoom + shadowPadding * 2)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSRect(x: center.x - size.width / 2,
                      y: center.y - size.height / 2,
                      width: size.width,
                      height: size.height)
    }

    /// 把预览面板摆到某个屏幕矩形上；`zoom` 只改显示窗口大小，不改 `currentRect`
    /// 之外的保存选区语义。
    private func layoutPreview(at rect: CGRect, zoom: CGFloat) {
        currentRect = rect
        previewPanel?.setFrame(Self.previewFrame(for: rect, zoom: zoom), display: true)
        positionToolbar()
    }

    /// 立刻撤掉压暗层，不做淡出。
    ///
    /// 淡出那 0.18 秒里它还挂在屏幕上：调整开始时覆盖层自带压暗，
    /// 两层叠一起会让挖空处发黑；它的挖空也还对不上新选区。索性直接收。
    private func hideDimPanel() {
        let panels = dimPanels
        dimPanels = []
        for panel in panels {
            panel.alphaValue = 0
            panel.orderOut(nil)
            panel.contentView = nil
        }
    }

    /// 调整完选区后把压暗层重新铺上，挖空对准**新的**选区。
    ///
    /// 调整开始时把它收掉了（见 `beginAdjustingSelection`）。
    /// 这里刻意**不做淡入**：调用时机是覆盖层刚撤掉的同一帧，直接以满
    /// 透明度出现才能和覆盖层的压暗无缝衔接——淡入那 0.2 秒里背景会
    /// 先亮一下再暗回去，看起来就是"闪一下"。
    private func restoreDimPanel(for rect: CGRect) {
        hideDimPanel()
        buildDimPanel(for: rect)
    }

    /// 按新选区从**整屏原图**上重新裁一块，换上真像素。
    ///
    /// 这里刻意不再抓屏：原图在截图那一刻就留下来了，改大小只是换一个裁剪矩形。
    /// 所以整趟拖动没有异步等待——松手当帧就能换图，也不会出现"新范围里
    /// 拍到了刚切过去的另一个窗口"这种前后两帧拼在一起的结果。
    private func applySelectionCrop(_ cropped: CGImage) {
        // 图换了：在途的旧 OCR 任务立刻作废。Vision 可能还会跑很久，等它回来
        // 时 generation 已经变了，不会把旧图的文字装到新裁出来的这张上。
        ocrGeneration += 1
        ocrTask?.cancel()
        ocrTask = nil
        isRecognizing = false
        failureResetTimer?.invalidate()
        failureResetTimer = nil
        failureText = nil
        image = cropped
        previewView?.image = cropped
        // 先把新图真的画进 backing store 再让它露脸：`showPreview(animated: false)`
        // 是直接置 alpha=1，若不先同步绘制，撤掉覆盖层的第一帧可能看到预览底色。
        previewView?.layoutSubtreeIfNeeded()
        previewView?.displayIfNeeded()
        previewPanel?.displayIfNeeded()
        // 标注跟着旧那张一起作废：留着的话画在旧位置的红圈会盖到新内容上，
        // 而它指的那个东西已经不在这儿了。清空比留着诚实。
        previewView?.inkLayer.clearAll()
        overwriteStoredFile(cropped)
        // 图变了，之前的识别结果 / 高亮 / OCR 工具栏都作废，重新抢跑。
        // 先退 OCR 模式再 `showPreview`，否则新图会带着旧图的「复制选中」工具栏闪现一帧。
        if isOCRMode { leaveOCRMode() }
        rebuildToolbar()
        showPreview(animated: false)
        prefetchTask?.cancel()
        prefetchTask = nil
        startPrefetchingOCR()
    }

    /// 改完选区、重新裁过之后，把**磁盘上那一份**换成新的。
    ///
    /// 只有"已经保存过"才覆盖 —— 没保存过就没有文件，那种时候去写一个不存在的
    /// 路径等于凭空造出一个半成品。
    private func overwriteStoredFile(_ fresh: CGImage) {
        guard let url else { return }
        do {
            try ImageWriter.overwrite(fresh, at: url)
        } catch {
            Log.capture.error("覆盖保存失败: \(error.localizedDescription)")
            // 只写日志等于没说：磁盘上那份还是旧的，用户以为刚改小的范围已经存上了。
            showFailure("没能写回文件　· 文件还是旧的那张")
        }
    }

    /// 保证图片区域至少有一部分留在屏幕内，别被拖到找不回来。
    private func clamp(_ origin: CGPoint, frameSize: CGSize, into visible: CGRect) -> CGPoint {
        let keepVisible: CGFloat = 80
        var result = origin

        let imageMinX = origin.x + shadowPadding
        let imageMaxX = imageMinX + frameSize.width - shadowPadding * 2
        let imageMinY = origin.y + shadowPadding
        let imageMaxY = imageMinY + frameSize.height - shadowPadding * 2

        if imageMaxX < visible.minX + keepVisible {
            result.x += (visible.minX + keepVisible) - imageMaxX
        }
        if imageMinX > visible.maxX - keepVisible {
            result.x -= imageMinX - (visible.maxX - keepVisible)
        }
        if imageMaxY < visible.minY + keepVisible {
            result.y += (visible.minY + keepVisible) - imageMaxY
        }
        if imageMinY > visible.maxY - keepVisible {
            result.y -= imageMinY - (visible.maxY - keepVisible)
        }
        return result
    }

    /// 淡出并移除压暗层。
    private func fadeOutDimPanel() {
        let panels = dimPanels
        dimPanels = []
        guard !panels.isEmpty else { return }

        Motion.run(duration: 0.18, curve: Motion.Curve.exit) {
            for panel in panels { panel.animator().alphaValue = 0 }
        } completion: {
            for panel in panels {
                panel.orderOut(nil)
                panel.contentView = nil
            }
        }
    }

    // MARK: 工具栏

    private func buildToolbarPanel() {
        let panel = PreviewPanel(contentRect: NSRect(origin: .zero,
                                                     size: NSSize(width: 260,
                                                                  height: toolbarHeight)),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered,
                                 defer: false)
        panel.isFloatingPanel = true
        panel.animationBehavior = .none
        panel.level = ShotLevels.toolbar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        // 手绘深色底。刻意不用毛玻璃：它会把底下的亮色内容透上来，白字看不清。
        let bar = ToolbarBackgroundView()
        panel.contentView = bar

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        toolbarPanel = panel
        rebuildToolbar(animated: false)
    }

    /// 当前应该显示哪一套按钮。
    private var toolbarMode: ToolbarMode {
        if let failureText { return .failure(failureText) }
        if isRecognizing { return .busy }
        return isOCRMode ? .ocr : .normal
    }

    /// 重建工具栏按钮。**带动画**：内容和宽度一起过渡，按钮不会"跳变"。
    private func rebuildToolbar(animated: Bool = true) {
        guard let bar = toolbarPanel?.contentView as? ToolbarBackgroundView else { return }
        let stack = toolbarStack(for: toolbarMode, saved: url != nil)
        bar.install(stack, animated: animated)
        resizeAndPositionToolbar(stackSize: stack.fittingSize, animated: animated)
    }

    /// 把标注那一组摆进工具栏最左边。
    private func addInkGroup(to stack: NSStackView) {
        for view in inkButtons() { stack.addArrangedSubview(view) }
        stack.addArrangedSubview(makeSeparator())
    }

    /// 某个形态下工具栏里的那一排按钮。
    ///
    /// 单独拆出来是给离屏渲染自检用的（`UIRenderSelfTest` 逐种形态真画一遍）——
    /// 另外复制一份按钮定义去"验证"，验的是赝品。
    ///
    /// - Parameter saved: 这张图**有没有已经存成文件**。它只影响「保留 / 丢弃」
    ///   那一对，但四种形态都要跟着它变，所以做成参数而不是再开一个 `ToolbarMode`
    ///   case（否则 busy × saved 会要六个 case 才铺得满）。
    func toolbarStack(for mode: ToolbarMode, saved: Bool = false) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        switch mode {
        case .busy:
            addInkGroup(to: stack)
            // 冷启动那一趟可能几十秒。必须让用户看到"在跑"，否则就是"点了没反应"。
            //
            // 但只有**一个转圈**是不够的，两件事都缺：
            // 1. 没说在跑什么 —— 转圈只说"有别的东西在动"，不说明白"这张图的文字正在被读"；
            // 2. 「保留 / 丢弃」跟着整排按钮一起消失，等于识别期间没法处置这张图。
            //    失败那一档早就为同样的事改过（提示必须带着主操作一起出现），
            //    这里以前照抄了失败的样子，却没照抄这条。
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.startAnimation(nil)
            stack.addArrangedSubview(spinner)

            let running = NSTextField(labelWithString: "正在识别文字…")
            running.font = Design.Fonts.caption
            running.textColor = Design.TextInk.secondary
            running.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(running)

            stack.addArrangedSubview(makeSeparator())
            for view in keepDiscardButtons(saved: saved) { stack.addArrangedSubview(view) }

        case .failure(let text):
            addInkGroup(to: stack)
            // 只在"真的出问题"时才出字：平时保持极简，但失败不能一声不吭。
            //
            // ⚠️ 提示条**必须把主操作一起带着**：这里原本只有图标 + 一行字，
            // 于是"识别超时，再点一次试试"把「识别文字」按钮本身变没了，
            // 保留 / 丢弃 也一起消失 —— 让用户照着提示去点一个已经不在的按钮，
            // 比不提示更糟。失败态 = 提示 + 重试 + 保留 + 丢弃。
            let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                                  accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = Self.barInk(.systemOrange)
            icon.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(icon)

            let label = NSTextField(labelWithString: text)
            label.font = Design.Fonts.caption
            label.textColor = Design.TextInk.secondary
            label.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(label)

            stack.addArrangedSubview(makeGap())
            stack.addArrangedSubview(makeButton("再试一次", symbol: "text.viewfinder",
                                                action: #selector(runOCR), prominent: true,
                                                tooltip: "重新识别画面里的文字"))
            stack.addArrangedSubview(makeSeparator())
            for view in keepDiscardButtons(saved: saved) { stack.addArrangedSubview(view) }

        case .ocr:
            addInkGroup(to: stack)
            stack.addArrangedSubview(makeButton("复制选中", symbol: "doc.on.doc",
                                                action: #selector(copySelectedText),
                                                prominent: true,
                                                tooltip: "复制划选的文字（⌘C）；没划选会提示先划一段"))
            stack.addArrangedSubview(makeButton("复制全文", symbol: "doc.on.clipboard",
                                                action: #selector(copyAllText),
                                                tooltip: "复制识别出的全部文字（不用先划选）"))
            stack.addArrangedSubview(makeButton("复制图片", symbol: "photo.on.rectangle",
                                                action: #selector(copyImageToClipboard),
                                                tooltip: "把这张图复制进剪贴板"))
            stack.addArrangedSubview(makeButton("回到图片", symbol: "photo",
                                                action: #selector(leaveOCRMode),
                                                tooltip: "退出文字选择，回到截图"))
            stack.addArrangedSubview(makeSeparator())
            for view in keepDiscardButtons(saved: saved) { stack.addArrangedSubview(view) }

        case .normal:
            addInkGroup(to: stack)
            stack.addArrangedSubview(makeButton("识别文字", symbol: "text.viewfinder",
                                                action: #selector(runOCR), prominent: true,
                                                tooltip: "识别画面里的文字，识别后可直接划选复制"))
            stack.addArrangedSubview(makeSeparator())
            // 这一组是"这张图去哪儿"：进剪贴板（复制）或进磁盘（保存）。
            // 截图本身不再自动进剪贴板，所以这两条必须都摆在明面上 ——
            // 少了任一条，用户就得靠猜（或靠右键菜单）才知道这图能去哪。
            stack.addArrangedSubview(makeButton("复制图片", symbol: "doc.on.doc",
                                                action: #selector(copyImageToClipboard),
                                                tooltip: "把这张图复制进剪贴板（⌘C），复制后预览保持打开"))
            for view in keepDiscardButtons(saved: saved) { stack.addArrangedSubview(view) }
        }

        return stack
    }

    /// 「保留 / 丢弃」那一对，四种工具栏形态共用**一个出处**。
    ///
    /// 为什么要分两句话：`saved` 决定的是"丢弃删掉的是什么"。没落盘时磁盘上
    /// 压根没动过，落盘之后删的是磁盘上那一份。
    /// tooltip 写死成一句，另一种状态就成了谎报 —— 而用户是按这句话决定点不点的。
    ///
    /// 标题也跟着换：落盘之后那颗按下去真的会**动磁盘上的文件**，
    /// 光写「丢弃」看不出它删的是什么，写成「移到废纸篓」才是它干的事
    /// （而且是可恢复的那一种，不是永久删除）。
    static func keepDiscardTitles(saved: Bool)
        -> (keep: String, keepTip: String, discard: String, discardTip: String) {
        saved
            ? ("已保存", "这张图已经存成文件了　·　右键可以「在访达中显示」",
               "移到废纸篓", "把刚存的那份文件移到废纸篓（不是永久删除，可以找回）")
            : ("保存", "保存到截图文件夹（⏎）　·　磁盘上到这一刻才出现文件",
               "丢弃", "关掉面板，这张图不写文件　·　剪贴板不会被改动")
    }

    private func keepDiscardButtons(saved: Bool) -> [NSView] {
        let t = Self.keepDiscardTitles(saved: saved)
        let keepButton = makeButton(t.keep, symbol: "folder.badge.plus",
                                    action: #selector(keep), tooltip: t.keepTip)
        // 已经保留过就不许再按一次：那会在同一秒里写出第二个同名文件
        // （`ImageWriter` 自动加 -2 后缀，用户看到的却是"我明明只点了一次"）。
        keepButton.isEnabled = !saved
        return [keepButton,
                makeButton(t.discard, symbol: "trash", action: #selector(discard),
                           tint: .systemRed, tooltip: t.discardTip)]
    }

    /// 改尺寸 + 重新贴图，一帧内完成；`animated` 时用窗口动画过渡。
    private func resizeAndPositionToolbar(stackSize: NSSize, animated: Bool) {
        guard let toolbarPanel else { return }
        let width = max(stackSize.width + 24, 54)
        let size = NSSize(width: width, height: toolbarHeight)
        let origin = toolbarOrigin(for: size)

        guard animated else {
            toolbarPanel.setFrame(NSRect(origin: origin, size: size), display: true)
            return
        }

        Motion.run(duration: Design.Timing.rise, curve: Motion.Curve.move) {
            toolbarPanel.animator().setFrame(NSRect(origin: origin, size: size), display: true)
        }
    }

    /// 贴在预览下方；下方不够放上方；都不够就贴进预览内侧底边。
    ///
    /// 写成纯函数（吃什么吐什么，不读实例状态）是为了让自检能直接调它：
    /// "工具栏永远落在屏幕可见区内"这件事，靠真机截图去验太不划算。
    static func toolbarOrigin(current: NSRect, size: NSSize,
                              visible: NSRect, gap: CGFloat) -> CGPoint {
        var origin = CGPoint(x: current.midX - size.width / 2,
                             y: current.minY - gap - size.height)

        if origin.y < visible.minY {
            origin.y = min(current.maxY + gap, visible.maxY - size.height)
        }
        if origin.y + size.height > visible.maxY {
            origin.y = current.minY + 12
        }
        // 工具栏比可见区还高时上面两条都会把落点推到屏外，最后兜一下底边。
        if origin.y < visible.minY { origin.y = visible.minY + 8 }

        origin.x = min(max(origin.x, visible.minX + 8),
                       visible.maxX - size.width - 8)
        // 窄屏（副屏 / Sidecar）上工具栏可能比可见区还宽，上面那条夹取会把左端
        // 推到屏外 —— 落点变成负数，整条栏跑到屏幕左边外面，用户只剩 ⌘ 键可用。
        // 那种情况贴着左边放，至少最靠左的主操作还在屏上。
        if visible.maxX - size.width - 8 < visible.minX + 8 {
            origin.x = visible.minX + 8
        }

        return origin
    }

    private func toolbarOrigin(for size: NSSize) -> CGPoint {
        let visible = currentScreen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? currentRect
        return Self.toolbarOrigin(current: currentRect, size: size,
                                  visible: visible, gap: toolbarGap)
    }

    private func positionToolbar() {
        guard let toolbarPanel else { return }
        toolbarPanel.setFrameOrigin(toolbarOrigin(for: toolbarPanel.frame.size))
    }

    /// 一小段空白。失败态提示和主操作之间留一点呼吸。
    private func makeGap(_ width: CGFloat = 6) -> NSView {
        let gap = NSView()
        gap.translatesAutoresizingMaskIntoConstraints = false
        gap.widthAnchor.constraint(equalToConstant: width).isActive = true
        return gap
    }

    /// 图片右上角那颗「×」：鼠标 hover 到图上时浮出来，点一下收走面板。
    ///
    /// 用自绘的圆形按钮（而不是无边框 SF Symbol）：它要压在任何亮度的截图上，
    /// 必须有不透明深底 + 白叉，否则在白色内容上等于隐身。
    private func makePreviewCloseButton() -> NSButton {
        let button = HoverCloseButton(title: "", target: self,
                                      action: #selector(closeFromHoverButton))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: "xmark",
                               accessibilityDescription: "关闭预览")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        button.contentTintColor = .white
        button.toolTip = "关闭预览（不保存，剪贴板不动）"
        button.setAccessibilityLabel("关闭预览")
        return button
    }

    /// 收放角落那颗「×」。
    ///
    /// **只有当这张已经钉住时才给**：刚截完那一档，界面上一颗悬浮关闭按钮是多余的
    /// （该不该留这一张，用工具栏的保存 / 丢弃决定）。钉住之后工具栏收起来了，
    /// 「×」才是那个说得清的出口，这时鼠标 hover 到图上它才浮出来。
    ///
    /// 隐藏态必须连事件一起摘掉，不然它会一直躺在右上角吃鼠标。
    private func setCloseButton(_ button: NSButton, visible: Bool) {
        let shouldShow = visible && isPinned
        if shouldShow {
            button.isHidden = false
            Motion.reveal(button, offset: CGSize(width: 0, height: -3),
                          duration: Design.Timing.fade)
        } else {
            Motion.run(duration: 0.12, curve: Motion.Curve.exit) {
                button.animator().alphaValue = 0
            }
            // 等淡出走完再摘事件，动画中间还能看见那一小块在褪。
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.duration(0.12)) {
                guard button.alphaValue < 0.01 else { return }
                button.isHidden = true
            }
        }
    }

    @objc private func closeFromHoverButton() {
        dismiss(reason: .cancelled)
    }

    /// 一条竖分隔线。工具栏里有语义组（动作 / 去留决定），靠它分组。
    private func makeSeparator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        // 这条工具栏是**固定深色**的 HUD 条（黑 0.8 + 白 0.16 描边，压在任意截图上），
        // 所以分隔线也跟着用白色半透明；用 `separatorColor` 在这块底上几乎看不见，
        // 分不出组就等于没分。
        box.fillColor = NSColor.white.withAlphaComponent(0.26)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return box
    }

    /// 浮条上的颜色：这条工具栏永远是深色底，所以动态色一律按**深色外观**解算，
    /// 不跟着系统外观走。浅色模式下 `controlAccentColor` / `systemRed` 会解成
    /// 更深的一档，压在黑底上实测只有 3.3:1（`--ui-render` 的逐面对比会红）。
    static func barInk(_ color: NSColor) -> NSColor {
        guard let dark = NSAppearance(named: .darkAqua) else { return color }
        var resolved = color
        dark.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        // 再统一提亮一档：强调色按深色外观解出来也只有 4.4:1（浮条实测底 (24,24,24)），
        // 差的那一点不是选错色，而是"深底 + 中亮度色"本来就到不了 4.5。
        return resolved.blended(withFraction: 0.22, of: .white) ?? resolved
    }

    private func makeButton(_ title: String,
                            symbol: String,
                            image: NSImage? = nil,
                            action: Selector,
                            tint: NSColor? = nil,
                            prominent: Bool = false,
                            selected: Bool = false,
                            tooltip: String? = nil) -> NSButton {
        let button = ToolbarButton(title: title.isEmpty ? "" : " " + title,
                                   target: self,
                                   action: action)
        button.isBordered = false
        button.bezelStyle = .recessed
        // 图标那一排以前是 `.small`（符号 ~11pt）+ 紧密的内边距，压在图片上又小又难点 ——
        // 用户抱怨的"左边几个图标有点小"就是这两个数叠出来的。整排跟着放大一档，
        // 顺带把命中面积撑到 30pt（Apple HIG 的触控下限）。
        button.controlSize = .regular
        button.font = prominent ? Design.Fonts.title : Design.Fonts.body
        // 主操作（识别文字）用强调色，其余为白色 —— 和系统工具栏的层级处理一致
        button.contentTintColor = tint.map(Self.barInk)
            ?? ((prominent || selected) ? Self.barInk(.controlAccentColor)
                                        : Design.TextInk.primary)
        // 自绘的那几张（色块）不进 SF Symbol 配置；符号图统一放大一档，
        // 不然 `.regular` 也只把按钮框撑大、图形本身还是小。
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let icon = image
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
                .withSymbolConfiguration(symbolConfig)
        if let icon {
            button.image = icon
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
        // 命中的下限：整颗按钮至少 30pt 高，纯图标按钮再补一条等宽 ——
        // 不然"图标小"换成"命中区也小"，还是点不中。
        button.translatesAutoresizingMaskIntoConstraints = false
        var hitConstraints = [button.heightAnchor.constraint(greaterThanOrEqualToConstant: 30)]
        if title.isEmpty {
            hitConstraints.append(button.widthAnchor.constraint(greaterThanOrEqualToConstant: 30))
        }
        NSLayoutConstraint.activate(hitConstraints)
        if let tooltip { button.toolTip = tooltip }
        if selected { button.setSelectionChip(Self.barInk(.controlAccentColor)) }
        button.setAccessibilityLabel(title.isEmpty ? tooltip : title)
        return button
    }

    // MARK: - OCR

    /// 面板浮出后立刻在后台开跑一次识别，结果留给 `runOCR()` 直接取用。
    ///
    /// 刻意**不给任何界面反馈**：它只是抢跑，用户并不知道有这么一趟
    /// （参照 PaddleOCR 那边的做法——预热只更新状态栏，不碰结果区）。
    private func startPrefetchingOCR() {
        guard let image, prefetchTask == nil else { return }
        prefetchTask = Task { @MainActor in
            try await recognizer.recognizeLines(image, languages: SettingsStore.shared.ocrLanguages)
        }
    }

    /// 识别文字，并把每个文字块画成可点击的高亮框。
    ///
    /// 这里刻意不用 VisionKit 的 Live Text：它在纯命令行/部分环境下表现不稳
    /// （同样的代码时而空结果、时而挂住），而且需要完整的 GUI 上下文。
    /// 改成"识别 + 自绘高亮块"，行为完全可控。
    @objc private func runOCR() {
        guard let image, let previewView else { return }
        guard !isRecognizing else { return }      // 防重入：连点会并发跑多份 Vision
        isRecognizing = true
        // 立刻切成转圈。冷启动那趟要几十秒，没有这个就是"点了没反应"。
        failureText = nil
        failureResetTimer?.invalidate()
        failureResetTimer = nil
        rebuildToolbar()

        // 这张图这一趟的身份。Vision 不响应取消，await 回来时可能已经换了图，
        // 只有 generation + previewView 双重一致才允许把结果写到界面上。
        let generation = ocrGeneration
        Log.ocr.info("开始识别，isWarm=\(OCRRecognizer.isWarm)")

        ocrTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // 无论成功失败都要把转圈换回按钮；但如果这张图已经被换掉 / 面板已经
            // 关掉（generation 变了），新图那边有自己的状态，这里一个像素都别碰。
            defer {
                if self.ocrGeneration == generation {
                    self.isRecognizing = false
                    self.ocrTask = nil
                    self.rebuildToolbar()
                }
            }
            do {
                let start = Date()
                // 超时兜底：宁可提示"超时请重试"，也不要让用户盯着一个转圈干等
                let lines = try await Self.withTimeout(seconds: Self.ocrTimeout) {
                    try await self.fetchLines(for: image)
                }
                let elapsed = Date().timeIntervalSince(start) * 1000

                // 这一趟可能跑几十秒，期间用户不必干等转圈（busy 那一档现在也放着
                // 「保留 / 丢弃」）。面板已经没了还往下走的话：往一个不存在的预览层上
                // 画高亮，再弹一句「已识别 N 行文字」—— 那句说的是他刚丢掉或刚留下的旧图。
                guard !Task.isCancelled,
                      self.ocrGeneration == generation,
                      self.previewPanel != nil,
                      self.previewView === previewView else {
                    Log.ui.info("识别跑完时预览已换图 / 关闭，丢掉这批结果（\(Int(elapsed))ms）")
                    return
                }

                guard !lines.isEmpty else {
                    self.showFailure("没有识别到文字")
                    return
                }

                self.ocrLines = lines
                self.releaseInkForOCR()
                self.isOCRMode = true
                previewView.installOCRHighlights(lines: lines)
                self.setPanelDragging(enabled: false)

                // 「识别结果同时存成同名 .txt」：图已经落盘就当场写；还没落盘
                // （默认就是还没）只能**预告** —— 那个"同名"此刻还不存在。
                // 真正写出去的那一下在「保留」里，见 `ShotCoordinator.saveOnKeep`。
                var textNote: String?
                if SettingsStore.shared.saveOCRText {
                    let fullText = lines.map(\.text).joined(separator: "\n")
                    if let url = self.url, !fullText.isEmpty {
                        textNote = ShotCoordinator.writeSidecarIfNeeded(ocrText: fullText,
                                                                        alongside: url)
                    } else {
                        textNote = ImageWriter.ocrTextPendingStatus
                    }
                }

                self.rebuildToolbar()

                // 认出了多少行、现在能干什么 —— 划选这个能力看不见摸不着，
                // 不提示等于没有。
                ToastHUDController.shared.show(title: "已识别 \(lines.count) 行文字",
                                               detail: textNote ?? "在原图上按住拖动即可划选",
                                               screen: self.currentScreen,
                                               duration: 4.4)

                Log.ocr.info("识别到 \(lines.count) 行，耗时 \(Int(elapsed)) ms")

                if SettingsStore.shared.autoCopyOCRText {
                    self.copyAllText()
                }
            } catch is Timeout {
                guard !Task.isCancelled,
                      self.ocrGeneration == generation,
                      self.previewPanel != nil else { return }
                // Vision 卡住时不能无限等：提示 + 按钮回到可点状态，让用户能立刻重试
                Log.ocr.error("识别超时（\(Int(Self.ocrTimeout)) 秒）")
                self.showFailure("识别超时，再点一次试试")
            } catch {
                guard !Task.isCancelled,
                      self.ocrGeneration == generation,
                      self.previewPanel != nil else { return }
                let nsError = error as NSError
                Log.ocr.error("识别失败 [\(nsError.domain, privacy: .public) \(nsError.code)]: \(nsError.localizedDescription, privacy: .public)")
                self.showFailure(self.shortFailureText(nsError))
            }
        }
    }

    /// 识别的超时上限（秒）。
    ///
    /// 这台机器冷启动（首次加载语言纠正模型）实测 2–60 秒，偶尔还会进入"中毒"状态，
    /// 之后每次调用都要几十秒。所以超时不能定太短——太短会误伤冷启动；
    /// 但也不能没有，否则真卡住时界面会永远停在一个转圈上。
    /// 60 秒是兼顾两者的值，热态通常 <200 ms，根本不会触发。
    private static let ocrTimeout: Double = 60

    /// 把 Vision 的原始错误压成一句人话。
    private func shortFailureText(_ error: NSError) -> String {
        if error.domain.contains("CRImageReader") {
            return "识别引擎未就绪，再点一次试试"
        }
        return "识别失败（\(error.code)）"
    }

    /// 显示一条失败提示，几秒后自动恢复成正常工具栏。
    private func showFailure(_ text: String) {
        failureText = text
        failureResetTimer?.invalidate()
        failureResetTimer = nil
        rebuildToolbar()

        failureResetTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.failureText = nil
            self.failureResetTimer = nil
            self.rebuildToolbar()
        }
    }

    /// 给一段异步操作加超时。
    ///
    /// 到点就返回，剩下的活儿在后台继续（Vision 没法真正取消），
    /// 但界面已经能提示并允许重试了。
    private static func withTimeout<T>(seconds: Double,
                                       _ body: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Timeout()
            }
            guard let result = try await group.next() else { throw Timeout() }
            group.cancelAll()
            return result
        }
    }

    /// 取识别结果。
    ///
    /// - 有抢跑结果且已经好了，直接取。
    /// - 抢跑还在冷启动（通常 >0.1s 没返回），立刻取消它，改由点击触发的这一趟来跑，
    ///   并带上超时。这样用户能看到"正在识别"的转圈；否则就是干等抢跑完成，
    ///   和"点了没反应"一个观感。
    /// - 抢跑/现场跑失败，再重试一次（Vision 偶尔第一次报错，第二次就好）。
    private func fetchLines(for image: CGImage) async throws -> [OCRRecognizer.Line] {
        let languages = SettingsStore.shared.ocrLanguages

        guard let prefetch = prefetchTask else {
            return try await Self.withTimeout(seconds: Self.ocrTimeout) { [self] in
                try await self.recognizer.recognizeLines(image, languages: languages)
            }
        }

        do {
            // 等抢跑最多 0.1 秒：热态 50 ms 左右就能拿到，冷态等也没用
            return try await Self.withTimeout(seconds: 0.1) { try await prefetch.value }
        } catch is Timeout {
            prefetch.cancel()
            prefetchTask = nil
            Log.ocr.notice("抢跑仍在冷启动中，改由点击触发识别")
            return try await Self.withTimeout(seconds: Self.ocrTimeout) { [self] in
                try await self.recognizer.recognizeLines(image, languages: languages)
            }
        } catch {
            Log.ocr.notice("抢跑的识别失败，改为现场识别：\(error.localizedDescription)")
            return try await Self.withTimeout(seconds: Self.ocrTimeout) { [self] in
                try await self.recognizer.recognizeLines(image, languages: languages)
            }
        }
    }

    @objc private func leaveOCRMode() {
        isOCRMode = false
        ocrLines = []
        previewView?.removeOCRHighlights()
        setPanelDragging(enabled: true)
        rebuildToolbar()
    }

    /// OCR 模式下空白处不再拖动面板，避免划选和移动抢同一块鼠标区域。
    private func setPanelDragging(enabled: Bool) {
        previewView?.allowsPanelDrag = enabled
        handlesView?.fallbackCursor = enabled ? .openHand : .arrow
        if let previewView {
            previewView.window?.invalidateCursorRects(for: previewView)
        }
        if let handlesView {
            handlesView.window?.invalidateCursorRects(for: handlesView)
            handlesView.needsDisplay = true
        }
    }

    /// 复制整张图的文字。选中态不再画高亮框，所以这里也不需要"全选标记框"的视觉反馈。
    @objc private func copyAllText() {
        guard let highlight = previewView?.highlightView else { return }
        highlight.selectAll()

        let text = highlight.allText
        guard !text.isEmpty else {
            ToastHUDController.shared.show(title: "这张图上没有可复制的文字")
            return
        }
        copyTextSelection(text)
    }

    /// 复制文字成功后保留面板；失败时角标给出重试办法。
    private func copyTextSelection(_ text: String, title: String? = nil) {
        _ = writeTextToPasteboard(text, title: title)
    }

    @discardableResult
    private func writeTextToPasteboard(_ text: String, title: String? = nil) -> Bool {
        // 复制成功的反馈走角标：面板本身保持极简（用户明确要求过），
        // 但一声不吭地写剪贴板会让人怀疑"到底复制没复制上"。写失败更要说话 ——
        // 不然用户 ⌘V 粘出上一份内容，还以为是自己看错了。
        let copied = PasteboardWrite.write(text: text)
        ToastHUDController.shared.show(title: copied ? (title ?? "已复制 \(text.count) 个字符")
                                                     : PasteboardWrite.textFailureTitle,
                                       detail: copied ? nil
                                                       : PasteboardWrite.textFailureDetail(characters: text.count),
                                       screen: currentScreen,
                                       duration: copied ? 3.2 : 4.8)
        return copied
    }

    // MARK: - 标注（画笔 / 形状）

    /// 标注那支笔可选的颜色。**这一张表就是候选色的全部** ——
    /// 颜色那一栏的菜单、按钮上那颗色块、自检摆的那张表都从它读，抄第二份就会分家。
    static let inkColors: [(name: String, color: NSColor)] = [
        ("红", .systemRed), ("黄", .systemYellow), ("蓝", .systemBlue),
        ("绿", .systemGreen), ("黑", .black), ("白", .white)
    ]

    /// 当前选中的标注工具。nil 是常态：那时鼠标归"划选文字"和"拖动面板"。
    private var inkTool: Ink.Tool?

    /// 自检用：当前选中的标注工具。
    ///
    /// 自检**不直接设它** —— 点按钮走的是 `NSButton.performClick`，
    /// 那才是用户那一下走的同一条路（直接设值就只能证明赋值会工作）。
    var inkToolForSelfTest: Ink.Tool? { inkTool }

    /// 当前笔色 / 线宽（自检对账菜单上那个勾和按钮上的名字用）。
    var inkColorForSelfTest: NSColor { inkColor }
    var inkWidthForSelfTest: CGFloat { inkWidth }

    /// 自检用：离屏只画工具栏那一排时没有面板，也就没有标注层，
    /// 「撤销 / 清空」那颗只能按"没东西可撤"画。接一层进来才看得到它们亮着的样子。
    private var selfTestInkLayer: InkLayer?
    func attachInkLayerForSelfTest(_ layer: InkLayer) { selfTestInkLayer = layer }

    /// 上一次用的形状：⇧⌘S 那一下要"选中之前的那个"，而不是悄悄换一种。
    private var lastShape: Ink.Shape = .rectangle
    /// 当前笔色。名字单独存着：从调色盘挑的颜色不在 `inkColors` 那六档里，
    /// 但 tooltip 得说得出"现在是什么色"。
    private var inkColor: NSColor = .systemRed
    private var inkColorName = "红"
    private var inkWidth: CGFloat = Ink.onScreenWidth

    /// 颜色那颗：一个带白边的实心圆点。
    ///
    /// 不能用 `circle.fill` + `contentTintColor` 了事：黑色那一档压在近黑的浮条上
    /// 会整个看不见，而用户正是按这颗点决定笔色的 —— 看不见就是假把手。
    /// 白边让六档颜色在任何底上都至少留一圈轮廓。
    static func colorSwatch(_ color: NSColor, diameter: CGFloat = 13) -> NSImage {
        NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let body = rect.insetBy(dx: 1.5, dy: 1.5)
            color.setFill()
            NSBezierPath(ovalIn: body).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
            return true
        }
    }

    /// 工具栏上标注那一组：**画笔 + 四种形状各一颗 + 颜色 + 撤销 + 清空**。
    ///
    /// 以前是「画笔 / 形状 / 颜色 / 撤销」四颗，形状和颜色都靠反复点循环切。
    /// 两处都不对：
    /// * 形状那颗第一下点的是"换到下一种"，不是"开始画"—— 用户以为自己在选工具，
    ///   其实先把工具换成了眼睛没看到的那一种；想画第四种得点三下。
    /// * 颜色那颗同理，换到第六色要点五下，切过头还得绕回来。
    /// 现在**点哪颗就是哪颗**，一颗一步。代价是这一组宽了四颗按钮，
    /// 工具栏那条浮条本来就跟着内容长，窄屏那一档有夹取兜底。
    ///
    /// 五种工具栏形态**都带着它**。只放在 normal 那一档的话，识别期间或失败条上
    /// 就"没有画笔"了，而用户可能刚圈了一半 —— 这个坑在「保留 / 丢弃」上踩过一次，
    /// 规矩是同一句：一条提示不许把主操作变没。
    private func inkButtons() -> [NSView] {
        var views: [NSView] = [
            makeButton("", symbol: "pencil.line", action: #selector(togglePen),
                       selected: inkTool == .pen,
                       tooltip: inkTool == .pen ? "画笔已选中　·　再点一下收起" + InkAction.pen.keyHint
                                                : "画笔：按住直接在图上圈" + InkAction.pen.keyHint)
        ]
        // 四种形状各一颗，顺序就是 `Ink.Shape.allCases` 的顺序 —— 按钮的 tag
        // 用下标，`pickShape` 再按下标取回形状，两边同一个出处。
        for (index, shape) in Ink.Shape.allCases.enumerated() {
            let on = inkTool == .shape(shape)
            let button = makeButton("", symbol: shape.symbol, action: #selector(pickShape(_:)),
                                    selected: on,
                                    tooltip: on ? "\(shape.name)已选中　·　再点一下收起"
                                                : "\(shape.name)：按住拖出\(shape.name)（⇧ 锁正方形 / 45°）")
            button.tag = index
            views.append(button)
        }
        views.append(makeButton("", symbol: "circle.fill",
                                image: Self.colorSwatch(inkColor),
                                action: #selector(showInkColorMenu(_:)),
                                tooltip: "颜色：\(inkColorName)　·　线宽：\(widthName(inkWidth))"
                                       + "　·　点开选色和调色盘"))
        views.append(makeButton("", symbol: "arrow.uturn.backward", action: #selector(undoInk),
                                tooltip: "撤销一笔" + InkAction.undo.keyHint))
        // 「清空」也在这组里：一笔一笔撤到第十笔不是"撤销"，是体力活。
        views.append(makeButton("", symbol: "trash.slash", action: #selector(clearInk),
                                tooltip: "清空：撤掉这张图上所有标注（撤销会把整批还回来）"))
        // 「撤销」「清空」没有内容可撤 / 可清时必须是**灰的**，不是"按下去叮一声"：
        // 这一排里只有这两颗的状态取决于历史，所以单独判。
        let layer = previewView?.inkLayer ?? selfTestInkLayer
        (views[views.count - 2] as? NSButton)?.isEnabled = layer?.canUndo ?? false
        (views.last as? NSButton)?.isEnabled = layer?.canClear ?? false
        return views
    }

    private func setInkTool(_ tool: Ink.Tool?) {
        inkTool = tool
        if case .shape(let shape) = tool { lastShape = shape }
        previewView?.inkLayer.tool = tool
        rebuildToolbar()
    }

    /// 点画笔：已经在画笔上就是收起，否则切到画笔。形状那颗同理（见 `pickShape`）。
    @objc private func togglePen() { setInkTool(inkTool == .pen ? nil : .pen) }

    /// 点某个形状：**第一下就是选中它**；再点同一颗才是收起。
    ///
    /// 这里刻意不做"选中之后再点一下换下一种"那种顺路设计 —— 那颗按钮的图标
    /// 画的就是它自己，点它当然得到它，换形状是旁边那颗按钮的事。
    @objc private func pickShape(_ sender: NSButton) {
        let all = Ink.Shape.allCases
        guard all.indices.contains(sender.tag) else { return }
        let shape = all[sender.tag]
        setInkTool(inkTool == .shape(shape) ? nil : .shape(shape))
    }

    /// 线宽那三档的名字。菜单上、tooltip 上都从 `Ink.widthChoices` 查，
    /// 不各自拼一份。
    static func widthName(_ points: CGFloat) -> String {
        Ink.widthChoices.first { $0.points == points }?.name ?? "\(Int(points))pt"
    }
    private func widthName(_ points: CGFloat) -> String { Self.widthName(points) }

    @objc private func undoInk() {
        previewView?.inkLayer.undo()
    }

    @objc private func clearInk() {
        previewView?.inkLayer.clearAll()
    }

    /// 颜色那一栏：候选色 + 线宽 + 系统调色盘，**一次点开设完**。
    ///
    /// 用菜单而不是弹层：这块面板是 `.hudWindow` 那条深色浮条上的无边框窗口，
    /// `NSPopover` 挂上去要自己管外观和层级，而菜单天生跟着系统走、
    /// 在浅深两套里都不用额外接线 —— 而且自检能直接把这棵菜单读出来数条目。
    func inkColorMenuForSelfTest() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, entry) in Self.inkColors.enumerated() {
            let item = NSMenuItem(title: entry.name, action: #selector(pickInkColor(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = Self.colorSwatch(entry.color, diameter: 14)
            item.state = Self.isSameColor(entry.color, inkColor) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for entry in Ink.widthChoices {
            let item = NSMenuItem(title: "线宽：\(entry.name)", action: #selector(pickInkWidth(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = Int(entry.points)
            item.state = entry.points == inkWidth ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let custom = NSMenuItem(title: "自定义调色盘…", action: #selector(openColorPalette),
                                keyEquivalent: "")
        custom.target = self
        custom.toolTip = "打开系统的颜色面板，任何颜色都能当笔色"
        menu.addItem(custom)
        return menu
    }

    /// 两笔颜色"算不算同一个"：都换算到 sRGB 再比，误差 0.005 以内。
    ///
    /// 不能直接 `==`：`NSColor` 是带色彩空间的，系统调色盘交回来的 sRGB 红
    /// 和 `.systemRed` 不是同一个对象、甚至不是同一个空间，比引用或比 rawValue
    /// 都会让菜单上那一勾永远打不上（或者六个全打上）。
    static func isSameColor(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
        let parts: (NSColor) -> [CGFloat] = { [$0.redComponent, $0.greenComponent,
                                               $0.blueComponent, $0.alphaComponent] }
        return zip(parts(x), parts(y)).allSatisfy { abs($0 - $1) < 0.005 }
    }

    /// 点开颜色那一栏。**锚点就是发事件的那颗按钮**（action 的 sender），
    /// 不去工具栏的视图树里按 tooltip 找它 —— 那种找法一改 tooltip 就静默失效。
    @objc private func showInkColorMenu(_ sender: NSButton) {
        let menu = inkColorMenuForSelfTest()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
    }

    @objc private func pickInkColor(_ sender: NSMenuItem) {
        guard Self.inkColors.indices.contains(sender.tag) else { return }
        setInkColor(Self.inkColors[sender.tag].color, name: Self.inkColors[sender.tag].name)
    }

    @objc private func pickInkWidth(_ sender: NSMenuItem) {
        inkWidth = CGFloat(sender.tag)
        previewView?.inkLayer.screenWidth = inkWidth
        // 不额外弹提示条：这一栏的提示条是留给**失败**的（`showFailure` 会换掉主按钮、
        // 顶一颗橙色的感叹号上去），拿它报"线宽改成中了"等于把警告用成了通知。
        // 改动本身的反馈是菜单里那个勾 + 下一笔的粗细，都在眼睛正在看的地方。
        rebuildToolbar()
    }

    private func setInkColor(_ color: NSColor, name: String) {
        inkColor = color
        inkColorName = name
        previewView?.inkLayer.color = color
        rebuildToolbar()
    }

    /// 系统调色盘：开面板、把当前笔色放进去、之后每次改动都跟着走。
    ///
    /// `NSColorPanel` 是共享的，target/action 也是共享的 —— 所以每次开都要重新
    /// 挂到自己身上，否则上一个面板使用者（识别结果那边将来也可能用色）会把改动
    /// 送到别处去。
    @objc private func openColorPalette() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSColorPanel.shared
        panel.color = inkColor
        // `NSColorPanel` 上没有 `target` / `action` 两个属性，只有这一对 setter。
        panel.setTarget(self)
        panel.setAction(#selector(paletteChanged(_:)))
        panel.isContinuous = true
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func paletteChanged(_ sender: NSColorPanel) {
        setInkColor(sender.color, name: "自定义")
    }

    /// 进 OCR 模式时收掉标注工具：两层都要接鼠标，留着画笔的话划选文字
    /// 会一笔一笔地变成圈画。
    private func releaseInkForOCR() {
        guard inkTool != nil else { return }
        setInkTool(nil)
    }

    /// Esc 分两段：**先停笔，再收面板**。
    ///
    /// 系统里"先取消当前选择、再退出"的约定。选中画笔之后按 Esc 直接关面板，
    /// 等于把刚圈的那几笔一起扔掉，而按这一下的人十有八九只是想"别画了"。
    /// 停笔那一下不需要额外说话 —— 工具栏上那颗高亮当场灭掉，
    /// 反馈就在眼睛正在看的地方。
    func pressEscape() {
        guard inkTool == nil else {
            setInkTool(nil)
            return
        }
        dismiss(reason: .cancelled)
    }

    /// 此刻"这张图"到底是哪一张：有标注就是合成过的那一份。
    ///
    /// 剪贴板、存盘、缩略图三个去处都读它 —— 三处各算一次的话，
    /// 就会出现"粘出去的和存进文件的不是一张"。
    private var outputImage: CGImage? {
        guard let image else { return nil }
        guard let previewView, let composited = previewView.composited(base: image) else {
            // 合成失败不能装作没事：那样存出去的是没标注的那张，
            // 而屏幕上明明画着圈。说清楚，让用户自己决定要不要先撤掉标注。
            showFailure("标注没能并进这张图　·　现在存的是没标注的那张")
            return image
        }
        return composited
    }

    // MARK: - 保留 / 丢弃

    /// 「保留」：这张图**到这里才变成文件**。
    ///
    /// 保存成功就收面板并给一条「已保存」提示：这条流程的完成动作是"文件已经在
    /// 截图文件夹里"，继续把面板挂着只会挡回用户刚要回去的那个 app。
    /// 不是 private：离屏自检要按选择器把这一对按钮从菜单清单里挑出来比对
    /// （`UIRenderSelfTest.printActionNamingCheck`）。藏起来就只能靠标题字符串认，
    /// 而标题正是这一组要验的东西 —— 拿被验的东西当尺子，量出来必然是直的。
    @objc func keep() {
        guard let outputImage, url == nil else { return }
        let text = ocrLines.isEmpty ? nil : ocrLines.map(\.text).joined(separator: "\n")
        // 没写成就不改状态、不重画工具栏：按钮留在「保留」上，用户可以换个位置再按一次。
        guard let written = onSave?(outputImage, currentRect, text) else { return }
        url = written
        dismiss(reason: .saved)
    }

    @objc func discard() {
        // 已经落盘的那一份才需要挪进废纸篓；没落盘时磁盘上什么都没写过。
        if let url, !(onDiscard?(url) ?? true) { return }
        dismiss(reason: .cancelled)
    }

    // MARK: - 关闭

    func dismiss(reason: DismissReason) {
        // 点击外部关闭的监听随面板一起撤掉
        removeClickAwayMonitor()
        // 上一张图的抢跑 / 识别别再往界面上写结果了：图已经换（或面板已经关）。
        // 先换代再 cancel；Vision 不响应取消时，await 回来的旧任务会看到 generation 不符。
        ocrGeneration += 1
        ocrTask?.cancel()
        ocrTask = nil
        isRecognizing = false
        failureResetTimer?.invalidate()
        failureResetTimer = nil
        failureText = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        // 调整选区的覆盖层也一并拆掉，别让它留在屏幕上
        adjustOverlay.cancel()

        guard previewPanel != nil || !dimPanels.isEmpty else { return }
        let preview = previewPanel
        let toolbar = toolbarPanel
        let dims = dimPanels

        previewPanel = nil
        toolbarPanel = nil
        dimPanels = []
        previewView = nil
        handlesView = nil
        closeButton = nil
        isHoveringPreview = false
        image = nil
        source = nil
        url = nil
        isOCRMode = false
        ocrLines = []
        // 复位"钉住"相关的状态：下一张截图必须还是"刚浮出来、点别处能收走"
        // 的那一档，不能继承上一张拖走后的钉住态。
        isPinned = false
        zoomHintShown = false
        Motion.run(duration: 0.14, curve: Motion.Curve.exit) {
            preview?.animator().alphaValue = 0
            toolbar?.animator().alphaValue = 0
            for dim in dims { dim.animator().alphaValue = 0 }
        } completion: {
            for panel in [preview, toolbar].compactMap({ $0 }) + dims {
                panel.orderOut(nil)
                panel.contentView = nil
            }
        }

        onClosed?(reason)
    }

    func dismissIfVisible() {
        if isVisible { dismiss(reason: .replaced) }
    }

    static func screenUnderMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }
}

// MARK: - 压暗层

/// 全屏半透明黑 + 选区挖空，复刻截图时「周围压暗」的观感。
final class DimOverlayView: NSView {

    /// 要挖空的矩形（本视图坐标）。
    var holeRect: CGRect? {
        didSet { needsDisplay = true }
    }

    /// 选区尺寸标签（画在选区下方）。nil = 不画。
    var badgeText: String? {
        didSet { needsDisplay = true }
    }

    /// 选区里要显示的**整屏原图**。nil = 挖空露出实时屏幕（预览阶段的压暗层）。
    /// 调整截图尺寸时传进来：只把原图铺在挖空里，外面的屏幕保持实时 + 压暗，
    /// 用户既能看到原图像素，又不会被整屏冻结帧"震"一下。
    var sourceImage: CGImage? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.setFillColor(Design.Ink.dimFocus.cgColor)
        context.fill(bounds)

        guard let hole = holeRect, hole.width > 1, hole.height > 1 else { return }

        if let sourceImage {
            // 调整尺寸：挖空里铺原图（整屏图按本视图坐标铺满），外面保持实时画面。
            context.saveGState()
            context.clip(to: hole)
            context.draw(sourceImage, in: bounds)
            context.restoreGState()
        } else {
            // 预览阶段：用 .clear 擦掉暗色，直接看到底下真实画面。
            //
            // 给"擦除"挂一层阴影，阴影的模糊会在选区边缘形成由深到浅的过渡，
            // 遮罩就不会和背景硬碰硬。模糊别给太大——太大选区看着像发虚，
            // 10pt 足够化掉那条 1px 硬边，又不影响"这里就是选区"的判断。
            let feather: CGFloat = 10
            context.saveGState()
            context.setBlendMode(.clear)
            context.setShadow(offset: .zero, blur: feather, color: NSColor.black.cgColor)
            context.fill(hole.insetBy(dx: feather, dy: feather))
            context.restoreGState()
        }

        // 边缘只留一圈极淡的高光，别再画硬线——软边已经够把选区勾出来了
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        context.setLineWidth(Design.hairline)
        context.stroke(hole.insetBy(dx: -0.75, dy: -0.75))

        drawBadge(for: hole, context: context)
    }

    /// 选区尺寸标签。和覆盖层那条角标是**同一个渲染函数** —— 以前这里另写了一份，
    /// 内边距 9×5 而那边 9×6，同一个 app 里两种角标。
    private func drawBadge(for hole: NSRect, context: CGContext) {
        guard let text = badgeText, !text.isEmpty else { return }
        HUDBadge.draw([HUDBadge.Row(text: text)], below: hole, in: bounds, context: context)
    }
}

// MARK: - 工具栏底板

/// 工具栏底板：实心深色 + 细描边。
///
/// 不用毛玻璃。试过 `.hudWindow` 配 `darkAqua`（系统 HUD 的正统做法），
/// 但工具栏浮在什么内容之上是不确定的——白底文档、暗色终端、彩色照片都可能，
/// 半透明材质在亮色内容上会让白字发虚。实心深色是唯一在任何背景下都稳的方案。
final class ToolbarBackgroundView: NSView {

    private var stack: NSStackView?

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // 0.92 而不是 0.8：这条浮条底下是刚截下来的图，什么亮度都有。
        // 0.8 的黑压在白图上只剩 (51,51,51)，强调色的字实测 3.3:1 ——
        // 控件的可读性不该取决于它后面那几张像素。
        layer?.backgroundColor = Design.Ink.hud.cgColor
        layer?.cornerRadius = Design.Radius.hud
        layer?.borderWidth = 1
        layer?.borderColor = Design.Ink.hudEdge.cgColor
    }

    /// 换一套按钮。`animated` 时新旧两组交叠淡入淡出，而不是硬切。
    func install(_ newStack: NSStackView, animated: Bool) {
        let old = stack

        newStack.wantsLayer = true
        addSubview(newStack)
        NSLayoutConstraint.activate([
            newStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            newStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        stack = newStack

        guard animated, let old else {
            old?.removeFromSuperview()
            return
        }

        old.wantsLayer = true
        old.alphaValue = 1
        Motion.run(duration: 0.18, curve: Motion.Curve.exit) {
            old.animator().alphaValue = 0
        }
        // 新一组从右边 5pt 滑进来，方向感说明"换档了"；旧一组原地退场，
        // 两组不做交叉位移，避免整条浮条像在左右抖。
        Motion.reveal(newStack, offset: CGSize(width: 5, height: 0), scale: 1,
                      duration: 0.18) {
            old.removeFromSuperview()
        }
    }
}

/// 工具栏按钮：无边框图标 + 悬停时淡入一层圆角底。
///
/// 之前是 `draw(_:)` 里直接填一块 `white 0.16` 的圆角矩形——又方又亮，
/// 在深色底上像贴了块补丁。改成独立的 `CALayer`：
/// 透明度用 `CABasicAnimation` 过渡，观感和系统工具栏的悬停一致。
final class ToolbarButton: NSButton {

    /// 悬停底。单独一层是为了能单独动它的透明度，不牵连文字和图标。
    private let hoverLayer = CALayer()
    /// 选中底：单独一层，因为它**常亮**，而悬停底跟着鼠标进出。
    private let selectLayer = CALayer()
    private var isHovering = false

    /// 工具栏和预览面板是两个窗口，key 在谁那边不一定；不接 first mouse
    /// 的话，用户遇到"第一下点按钮没反应"。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        selectLayer.cornerRadius = Design.Radius.chip
        selectLayer.opacity = 0
        layer?.addSublayer(selectLayer)
        hoverLayer.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        hoverLayer.cornerRadius = Design.Radius.chip
        hoverLayer.opacity = 0
        layer?.addSublayer(hoverLayer)
    }

    required init?(coder: NSCoder) { fatalError("不支持归档加载") }

    /// 给这颗按钮挂上"正被选中"的底。
    ///
    /// 为什么是加底而不是把图标放大一档：放大那颗会改整排的宽度，用户刚点完，
    /// 旁边几颗就从鼠标底下溜走了 —— 而标注是"点一颗、拖一笔、再点下一颗"的活，
    /// 每选一次工具布局抖一下，比看不出选中更烦。
    /// 颜色由调用方按浮条那套解好传进来：这里再解一次动态色就是第二个出处。
    func setSelectionChip(_ color: NSColor) {
        selectLayer.backgroundColor = color.withAlphaComponent(0.30).cgColor
        selectLayer.opacity = 1
    }

    override func layout() {
        super.layout()
        // 只留 1pt 呼吸位：悬停底必须完整包住按钮，否则鼠标已经落在按钮边缘，
        // 高亮却从边缘缩进去一截，看起来像两个错位的层。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer.frame = bounds.insetBy(dx: 1, dy: 1)
        selectLayer.frame = bounds.insetBy(dx: 1, dy: 1)
        CATransaction.commit()
    }

    /// 悬停的观感：底面淡入之外，图标再提亮一点（`contentTintColor` 一挡一挡地调，
    /// 跟着 `Motion` 走）。系统工具栏的悬停就是这个手感 —— 光有一层底，
    /// 在深色浮条上偏暗的图标 hover 前后几乎分不出来。
    private var baseInk: NSColor?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if baseInk == nil { baseInk = contentTintColor }
    }

    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering

        if let baseInk {
            let target = hovering
                ? (baseInk.blended(withFraction: 0.35, of: .white) ?? baseInk)
                : baseInk
            Motion.run(duration: Design.Timing.fade, curve: Motion.Curve.move) {
                animator().contentTintColor = target
            }
        }

        // 走统一入口：系统开着「减弱动态效果」时它直接到位。
        // 这一处以前是裸的 0.12 —— 绕开了统一入口，等于这个控件不遵守系统的开关。
        Motion.animate(hoverLayer, keyPath: "opacity",
                       from: hoverLayer.presentation()?.opacity ?? hoverLayer.opacity,
                       to: hovering ? 1 : 0,
                       duration: Design.Timing.fade,
                       curve: Motion.Curve.move,
                       key: "toolbar.hover")
        hoverLayer.opacity = hovering ? 1 : 0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    /// 鼠标按下时短暂压暗并轻微内收，松开恢复——给"这一下已经收下了"一个手感。
    /// 位移只落在 layer 上，不会让这一排按钮重新排版，旁边的按钮不会从鼠标下溜走。
    private var isPressed = false

    private func setPressed(_ pressed: Bool) {
        guard isPressed != pressed else { return }
        isPressed = pressed
        hoverLayer.backgroundColor = NSColor.white
            .withAlphaComponent(pressed ? 0.22 : 0.12).cgColor

        // 压暗是反馈，缩放是空间动效；开了「减弱动态效果」就只保留前者。
        guard !Motion.isReduced, let layer else { return }
        let target = pressed
            ? CATransform3DMakeScale(0.94, 0.94, 1)
            : CATransform3DIdentity
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: layer.transform)
        animation.toValue = NSValue(caTransform3D: target)
        animation.duration = Motion.duration(pressed ? Design.Timing.micro : 0.20)
        animation.timingFunction = pressed ? Motion.Curve.exit : Motion.Curve.enter
        layer.transform = target
        layer.add(animation, forKey: "toolbar.press")
    }

    override func mouseDown(with event: NSEvent) {
        setPressed(true)
        // `NSButton` 在 `super.mouseDown` 里完成按住、跟踪、松手与发动作；
        // 这里不要再补一遍 `mouseUp`，否则同一次点击可能被算两次。
        super.mouseDown(with: event)
        setPressed(false)
    }
}

// MARK: - 图片预览视图（含隐形文字层）

/// 铺满显示截图，支持拖动移动面板，并可叠加文字层与可调节边框。
final class ImagePreviewView: NSView {

    /// 图片用 `NSImageView` 承载，方便按视图尺寸缩放显示。
    ///
    /// 必须是"穿透"的：`NSImageView` 默认会命中自己，把落在空白处的点击吃掉，
    /// 父视图的「按住拖动面板」就永远收不到事件——表现就是拖不动预览。
    private let imageView = PassthroughImageView()

    /// 识别结果高亮层（常驻；`lines` 为空时不画任何东西）。
    /// 声明成父类型：子类只是给右键补一条转发，外部读到的能力仍是文字层那一套。
    let highlightView: OCRHighlightView = HighlightMenuView()

    /// 标注层。常驻，但只有选中工具时才接管鼠标（见 `InkLayer.hitTest`）。
    let inkLayer = InkLayer()

    /// 把标注合成进这张图，返回**像素尺寸不变**的那一张。
    ///
    /// 归一化坐标在这里第二次值钱：同一个 `strokePaths(in:)` 换一个大一号的矩形就是
    /// 像素版的那一份，线宽按图宽缩放，所以屏幕上 3pt 的那支笔和存出去那 6px 的笔
    /// 是同一支。
    ///
    /// 失败返回 nil 而不是灰不吭声地退回原图 —— 调用方必须能说出"存的是没标注的那张"。
    func composited(base: CGImage) -> CGImage? {
        guard !inkLayer.strokes.isEmpty else { return base }
        let rect = NSRect(x: 0, y: 0, width: base.width, height: base.height)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: base.width,
                                         pixelsHigh: base.height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.draw(base, in: rect)
        for (color, path) in inkLayer.strokePaths(in: rect) {
            color.setStroke()
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    var image: CGImage? {
        didSet {
            imageView.image = image.map {
                NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
            }
        }
    }

    /// 空白处按住拖动时回调（参数是位移增量）。
    var onDrag: ((CGSize) -> Void)?
    /// OCR 模式关掉整张预览的拖动，鼠标只在文字选择 / 边框调整上工作。
    var allowsPanelDrag = true
    /// 滚轮回调。预览面板用它调整观看倍率，不改截图内容。
    var onScroll: ((NSEvent) -> Void)?

    /// 右键菜单由外部提供 —— 菜单项要动的状态（是否 OCR 模式、文件 URL）都在控制器手里。
    var contextMenuProvider: (() -> NSMenu?)?

    /// 右键落在某个字块上时回调（参数是那一处的 unit 序号）。
    /// 控制器据此把"要复制的范围"定在用户点的那一处，而不是上一次拖选留下的范围。
    var onHighlightRightClick: ((Int) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?() ?? super.menu(for: event)
    }

    /// 识别出的文字块也要能右键。
    ///
    /// 这一层铺在预览之上，`hitTest` 只在自己身上接走"落在字块上"的事件 ——
    /// 于是右键落在字块里时，`menu(for:)` 问的是这一层，而它不给菜单的话
    /// 右键在那儿就没反应。转发给父视图那份菜单，并回填右键落在哪个 unit 上，
    /// 「复制文字」才能照用户点的那一处走。
    private final class HighlightMenuView: OCRHighlightView {
        override func menu(for event: NSEvent) -> NSMenu? {
            if let preview = superview as? ImagePreviewView,
               let unit = unitIndex(at: convert(event.locationInWindow, from: nil)) {
                preview.onHighlightRightClick?(unit)
            }
            return superview?.menu(for: event) ?? super.menu(for: event)
        }
    }

    private var dragAnchor: NSPoint?

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        // 预览面板的尺寸就等于截图尺寸，直接铺满即可
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        addSubview(imageView)

        highlightView.frame = bounds
        highlightView.autoresizingMask = [.width, .height]
        addSubview(highlightView)

        // 标注层在文字层**之上**：圈画盖在内容上，而划选文字要的是底下的像素。
        // 它只在选中工具时接管鼠标（见 `InkLayer.hitTest`），平时一律放行。
        inkLayer.frame = bounds
        inkLayer.autoresizingMask = [.width, .height]
        addSubview(inkLayer)

        setAccessibilityLabel("截图预览")
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("不支持归档加载") }

    override func draw(_ dirtyRect: NSRect) {
        // 图片由 imageView 绘制，这里只铺底色
        NSColor.black.setFill()
        dirtyRect.fill()
    }

    // MARK: 拖动

    override func mouseDown(with event: NSEvent) {
        guard allowsPanelDrag else { return }
        dragAnchor = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard allowsPanelDrag else {
            dragAnchor = nil
            return
        }
        guard let anchor = dragAnchor else { return }
        let now = NSEvent.mouseLocation
        let delta = CGSize(width: now.x - anchor.x, height: now.y - anchor.y)
        guard abs(delta.width) > 1 || abs(delta.height) > 1 else { return }
        dragAnchor = now
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchor = nil
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: allowsPanelDrag ? .openHand : .arrow)
    }

    /// 面板浮出来时不是 key window，第一下点击/拖动不该被系统当成"激活窗口"丢掉。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 识别结果高亮层

    /// 铺上识别结果。每个文字块会画一个可点击的高亮框。
    func installOCRHighlights(lines: [OCRRecognizer.Line]) {
        highlightView.frame = bounds
        highlightView.lines = lines
    }

    /// 清掉高亮层。
    func removeOCRHighlights() {
        highlightView.lines = []
    }
}

/// 无边框面板。
///
/// 必须重写 `canBecomeKey`：否则面板拿不到键盘焦点，
/// 后果是工具栏按钮点不动、文字层里选中的文字也没法 ⌘C 复制。
/// 预览面板自己接的那三条标注键。
enum InkAction: Equatable {
    case undo, pen, shape

    /// 键 → 动作这张表**只有一个出处**：`keyDown` 按它分派，工具栏 tooltip 上那句
    /// 「（⇧⌘P）」也从它取。说明里写一个按不动的键比不写更糟 —— 这个坑在菜单
    /// 快捷键上栽过一次，那一组断言现在还在守着。
    ///
    /// 画笔和形状占 ⇧⌘ + 单键：⌘P 会被系统当成"打印"、⌘S 是"保存"，抢不得。
    static let shortcuts: [(key: String, shift: Bool, action: InkAction)] = [
        ("z", false, .undo), ("p", true, .pen), ("s", true, .shape)
    ]

    static func action(for key: String, shift: Bool) -> InkAction? {
        shortcuts.first { $0.key == key && $0.shift == shift }?.action
    }

    /// tooltip 后缀那种写法，按 Apple 的修饰键顺序 ⇧⌘。
    var keyHint: String {
        guard let row = Self.shortcuts.first(where: { $0.action == self }) else { return "" }
        return "（" + (row.shift ? "⇧⌘" : "⌘") + row.key.uppercased() + "）"
    }
}

final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 无边框浮层**不许系统按屏幕去放**。
    ///
    /// 这条是"截完比较大的图之后预览会移位"的根因：`NSWindow` 默认会把窗口
    /// 夹进 `screen.visibleFrame`（避开菜单栏 / Dock）。截图比可见区还高时，
    /// AppKit 就在 `setFrame` 之后偷偷把窗口上移，于是预览和它标定的选区
    /// 对不上 —— 用户看到的就是"松手那一下图自己跳了一下"。
    /// 我们是自己算坐标、层级也自己定的 HUD，不需要系统来放它。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// ⌘Z / ⇧⌘P / ⇧⌘S。三条键走**一个**回调而不是挂三个闭包：
    /// 键和动作的对应关系只在这个 switch 里说一次，tooltip 才有唯一可对账的出处。
    var onInkAction: ((InkAction) -> Void)?

    /// Esc / 点外部：收走面板，不写盘。剪贴板里有没有那张图，取决于用户按没按过
    /// 「复制图片」—— 这里一概不去碰它。
    var onEscape: (() -> Void)?
    /// 回车：等同「保留」，也就是此刻才写出文件。
    var onKeep: (() -> Void)?
    /// ⌘C：复制（OCR 文字或整图）。
    var onCopy: (() -> Void)?

    /// 主菜单「视图」的放大 / 缩小 / 实际大小。三条 selector 的 target 留 nil，
    /// 由这条转发链接到真正的 `InlinePreviewController`。
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomReset: (() -> Void)?

    @objc func zoomIn(_ sender: Any?) { onZoomIn?() }
    @objc func zoomOut(_ sender: Any?) { onZoomOut?() }
    @objc func resetZoom(_ sender: Any?) { onZoomReset?() }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// ⌘W 走的是主菜单的「关闭」，而事件在 key equivalent 阶段就被菜单接走，
    /// 到不了 `keyDown`。这里把它并到 Esc 的同一条收尾路径上：
    /// 直接 `super.performClose` 会把面板从 `dismiss()` 的清理流程里摘出去，
    /// 压暗层和点击外部监听就永久留在屏幕上。
    override func performClose(_ sender: Any?) { onEscape?() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:                 // Esc
            onEscape?(); return
        case 36, 76:             // Return / Enter
            onKeep?(); return
        default: break
        }
        if event.modifierFlags.contains(.command),
           let key = event.charactersIgnoringModifiers?.lowercased() {
            if key == "c" { onCopy?(); return }
            if let action = InkAction.action(for: key,
                                             shift: event.modifierFlags.contains(.shift)) {
                onInkAction?(action); return
            }
        }
        super.keyDown(with: event)
    }
}

/// 只画图、不接事件的 `NSImageView`。见 `ImagePreviewView.imageView` 的说明。
private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - 可调节边框

/// 截图完成后的**可调节边角**：按住四角 / 四边拖动即改变尺寸。
///
/// 就地预览在**拖走之前**画出八个把手，让用户看得出当前可以重新框选；
/// 一旦拖走固定，整层手柄会停止交互，只留下滚轮缩放。
///
/// `showsKnobs = true` 那一档留给全屏调整覆盖层（截图时正在重新框选，
/// 那一刻用户**需要**看见八个把手）。两档共用同一套命中几何。
///
/// **形状分两种**：四角是方块（拖它改两条边），四边中点是躺在那条边上的短棒
/// （拖它只改这一条边）。见 `knobRect(for:center:size:)`。
///
/// 这一层平时是"透明"的：`hitTest` 只在手柄附近返回自己，
/// 其余位置一律放行，压在上面的文字层才能正常划选。
final class ResizeHandlesView: NSView {

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var isCorner: Bool {
            switch self {
            case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
            case .top, .bottom, .left, .right: return false
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("重新框选：拖动手柄可调整保留范围")
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("不支持归档加载") }

    /// 拖动开始的瞬间回调（早于 `onAdjust`）。
    ///
    /// 存在的意义：拖动一开始就要换成"选取"模式的覆盖层，
    /// 而覆盖层是**另一个窗口**——按下那一下已经被本视图吃掉了，
    /// 覆盖层里的手柄是从 `mouseDragged` 中途接手的。
    var onAdjustBegan: (() -> Void)?
    /// 拖动中，参数是**增量**（点）。
    var onAdjust: ((Handle, CGSize) -> Void)?
    /// 松手。
    var onAdjustEnded: (() -> Void)?

    /// 面板被拖动移动过之后就**不能再改尺寸**了：位置已经不是原选区，
    /// 再改尺寸没法对应回屏幕上的矩形。由外部在拖动时置 false。
    var isEnabled: Bool = true {
        didSet {
            if !isEnabled { hovered = nil; active = nil }
            needsDisplay = true
        }
    }

    /// 只画不接管。给全屏调整覆盖层里的那一份手柄用——
    /// 它只是"影子"，真正收鼠标的是预览面板里那份。
    var isInteractionEnabled: Bool = true

    /// 画不画那八个把手。默认 true（全屏调整覆盖层要看见）；
    /// 就地预览那档设成 false —— 界面里一颗点都不要。
    var showsKnobs: Bool = true {
        didSet { needsDisplay = true }
    }

    private var active: Handle?
    private var hovered: Handle?
    private var lastScreenPoint: NSPoint?
    private var monitor: Any?

    /// 手柄的命中范围。比画出来的圆点大一圈，不然太难点中。
    private let hitSize: CGFloat = 26

    /// 手柄往内缩多少。这一层被父视图（8pt 圆角 + `masksToBounds`）裁着，
    /// 所以内缩必须按**最大那一号**算，不是按静止时那一号：
    /// 悬停/拖动时手柄放大到 16pt 那一号（短棒更长），再加 3.5pt 的投影，
    /// 原来内缩 6pt 只够放下静止状态那一款 —— 于是**恰恰在最该显眼的那一下**，
    /// 强调色手柄被边界削成平的。自检里 8 个手柄的悬停态全部报探出边界。
    private let handleInset: CGFloat = 11
    private let knobSize: CGFloat = 10
    private let hoveredKnobSize: CGFloat = 16

    override var isFlipped: Bool { false }

    /// 浮出的预览面板不是 key window，不接 first mouse 的话第一下会被系统吞掉。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 手柄中心（本视图坐标，原点左下）。内缩量见 `handleInset`。
    private func knobPoint(for handle: Handle) -> NSPoint {
        let inset = handleInset
        switch handle {
        case .topLeft:     return NSPoint(x: bounds.minX + inset, y: bounds.maxY - inset)
        case .top:         return NSPoint(x: bounds.midX, y: bounds.maxY - inset)
        case .topRight:    return NSPoint(x: bounds.maxX - inset, y: bounds.maxY - inset)
        case .right:       return NSPoint(x: bounds.maxX - inset, y: bounds.midY)
        case .bottomRight: return NSPoint(x: bounds.maxX - inset, y: bounds.minY + inset)
        case .bottom:      return NSPoint(x: bounds.midX, y: bounds.minY + inset)
        case .bottomLeft:  return NSPoint(x: bounds.minX + inset, y: bounds.minY + inset)
        case .left:        return NSPoint(x: bounds.minX + inset, y: bounds.midY)
        }
    }

    /// 悬停的那个手柄画大一号 + 填强调色，让人一眼看出"抓到的是这一个"。
    private func knobSize(for handle: Handle) -> CGFloat {
        (handle == hovered || handle == active) ? hoveredKnobSize : knobSize
    }

    /// 手柄的形状：**四角是方块**（拖它改两条边），**四边中点是躺在那条边上的短棒**
    /// （拖它只改这一条边）。
    ///
    /// 以前八个画的是同一个圆点，而这八个之间唯一的区别恰恰是"动一个轴还是两个轴" ——
    /// 形状不区分，就只能靠挨个试。摆成和它所管的那条边同向，还顺带解决另一件事：
    /// 圆点压在浅色截图上时靠一圈深色描边撑着，短棒有 26pt 长，不至于整个看不清。
    static func knobRect(for handle: Handle, center: NSPoint, size: CGFloat) -> NSRect {
        if handle.isCorner {
            return NSRect(x: center.x - size / 2, y: center.y - size / 2,
                          width: size, height: size)
        }
        let long = size * 2.0
        let short = size * 0.55
        let horizontal = handle == .top || handle == .bottom
        let width = horizontal ? long : short
        let height = horizontal ? short : long
        return NSRect(x: center.x - width / 2, y: center.y - height / 2,
                      width: width, height: height)
    }

    private func knobRect(for handle: Handle) -> NSRect {
        Self.knobRect(for: handle, center: knobPoint(for: handle), size: knobSize(for: handle))
    }

    /// 圆角跟着短边收，方块就是"略带圆角的方块"，短棒就是一颗胶囊。
    private func knobPath(for handle: Handle) -> CGPath {
        let rect = knobRect(for: handle)
        let radius = min(3.5, min(rect.width, rect.height) / 2)
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                      transform: nil)
    }

    /// 自检用：每个手柄在「常态」和「悬停放大的那一号」两种尺寸下，
    /// 绘制矩形有没有探出本视图边界 —— 这一层被父视图 `masksToBounds` 裁着，
    /// 探出去的部分会被直接削平，圆角手柄就变成半圆。
    func knobOverflowForSelfTest() -> [String] {
        var out: [String] = []
        let restore = hovered
        for handle in Handle.allCases {
            let normal = knobRect(for: handle)
            hovered = handle
            let grown = knobRect(for: handle)
            for (label, rect) in [("常态", normal), ("悬停", grown)] {
                let inside = rect.minX >= bounds.minX - 0.01
                    && rect.minY >= bounds.minY - 0.01
                    && rect.maxX <= bounds.maxX + 0.01
                    && rect.maxY <= bounds.maxY + 0.01
                if !inside { out.append("\(label) \(handle)") }
            }
        }
        hovered = restore
        return out
    }

    private func hitRect(for handle: Handle) -> NSRect {
        let point = knobPoint(for: handle)
        return NSRect(x: point.x - hitSize / 2, y: point.y - hitSize / 2,
                      width: hitSize, height: hitSize)
    }

    private func handle(at point: NSPoint) -> Handle? {
        guard isEnabled else { return nil }
        return Handle.allCases.first { hitRect(for: $0).contains(point) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 只在手柄附近接管事件；其余位置一律放行，
        // 否则会挡住下面文字层的划选和"按住拖动面板"。
        guard let superview, isEnabled, isInteractionEnabled else { return nil }
        let local = convert(point, from: superview)
        return handle(at: local) != nil ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard isEnabled, bounds.width > 4, bounds.height > 4 else { return }

        // 预览面板不画手柄、不画描边：这一层只保留命中测试和调整光标。
        // 全屏调整覆盖层仍然用 showsKnobs = true 的那条原路。
        guard showsKnobs else { return }

        // 内外双描边，任何背景上都能看清：外圈深色在浅色截图上勾出轮廓，
        // 内圈白色在深色截图上勾出轮廓。
        //
        // 两条线都必须画在**边界以内**：这一层所在的视图被父视图的
        // `masksToBounds` 裁着，描边一旦压到边界外就会被整条削掉 ——
        // 之前白色那条正是这么没的，离屏渲染自检里才看出来。
        context.setStrokeColor(Design.Ink.halo.cgColor)
        context.setLineWidth(Design.hairline)
        context.stroke(bounds.insetBy(dx: 0.75, dy: 0.75))

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        context.setLineWidth(Design.hairline)
        context.stroke(bounds.insetBy(dx: 2.25, dy: 2.25))

        for handle in Handle.allCases {
            let isActive = (handle == hovered || handle == active)
            let path = knobPath(for: handle)

            if isActive {
                // 悬停 / 拖动的那个：整个填强调色，再加一圈白边——在深浅背景上都显眼
                context.saveGState()
                context.setShadow(offset: .zero, blur: 3.5,
                                  color: NSColor.black.withAlphaComponent(0.6).cgColor)
                context.setFillColor(NSColor.controlAccentColor.cgColor)
                context.addPath(path)
                context.fillPath()
                context.restoreGState()

                context.setStrokeColor(NSColor.white.cgColor)
                context.setLineWidth(1.2)
                context.addPath(path)
                context.strokePath()
            } else {
                // 普通状态：白底 + 深色描边 + 阴影，保证浅色截图上也能看清
                context.saveGState()
                context.setShadow(offset: .zero, blur: 3.5,
                                  color: NSColor.black.withAlphaComponent(0.6).cgColor)
                context.setFillColor(NSColor.white.cgColor)
                context.addPath(path)
                context.fillPath()
                context.restoreGState()

                context.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
                context.setLineWidth(Design.hairline)
                context.addPath(path)
                context.strokePath()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let handle = handle(at: point) else { return }
        onAdjustBegan?()
        beginDrag(on: handle)
    }

    override func mouseDragged(with event: NSEvent) {
        // 中途接手：按下发生在**另一个窗口**（预览里的手柄），
        // 那一刻本视图还没出现在鼠标下面，所以这里要自己补一次"开始拖动"。
        if active == nil {
            let point = convert(event.locationInWindow, from: nil)
            guard let handle = handle(at: point) else { return }
            beginDrag(on: handle)
        }
        guard let handle = active, let last = lastScreenPoint else { return }
        let now = NSEvent.mouseLocation
        let delta = CGSize(width: now.x - last.x, height: now.y - last.y)
        guard abs(delta.width) > 0.5 || abs(delta.height) > 0.5 else { return }
        lastScreenPoint = now
        onAdjust?(handle, delta)
    }

    private func beginDrag(on handle: Handle) {
        active = handle
        lastScreenPoint = NSEvent.mouseLocation
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard active != nil else { return }
        active = nil
        lastScreenPoint = nil
        needsDisplay = true
        onAdjustEnded?()
    }

    // MARK: 悬停与光标

    /// `mouseMoved` 是设光标的**正确时机**——它在窗口自己的光标矩形解析**之后**
    /// 才被调用，所以设的值不会被覆盖。
    ///
    /// 之前只在本地监听里设光标，而本地 monitor 跑在事件派发之前，
    /// 设完又被窗口的光标处理冲掉：表现就是"刚截完图时箭头不出现，
    /// 点一下之后才生效"。两条路都留着，`mouseMoved` 为主、监听兜底。
    override func mouseMoved(with event: NSEvent) {
        updateHover(with: event)
    }

    /// 一块 `.activeAlways` 的 tracking area，专门补 `mouseMoved` 的盲区。
    ///
    /// 用户报的"手柄有时候没有 hover 效果"有两个来源，这一块是主因：
    ///
    /// 1. `hitTest` 只在手柄附近返回自己，鼠标从手柄滑到图中间时事件落到下层视图，
    ///    本视图收不到 `mouseExited`，悬停就一直卡着（下面那个本地监听补的是这条）。
    /// 2. **这张预览被钉在屏幕上之后，用户往往切去别的 app 对照内容**，那时鼠标
    ///    还在我们的窗口上滑，但事件不再送进我们的进程 —— 本地监听和 `mouseMoved`
    ///    一起失灵。`.activeAlways` 的 tracking area 是 AppKit 里唯一会在
    ///    "app 不是前台"时照常把 mouseMoved 交给 owner 的机制。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved,
                                                 .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard hovered != nil else { return }
        hovered = nil
        needsDisplay = true
        fallbackCursor.set()
    }

    /// 本地事件监听，作为 `mouseMoved` 的兜底。
    ///
    /// `mouseMoved` 只在 `hitTest` 命中自己时才派发，而手柄以外我们是故意放行的，
    /// 于是"从手柄移到图中间"这件事收不到事件，悬停状态会卡住不消失。
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard newWindow != nil else { return }
        installMonitor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // `viewWillMove` 未必会传到这个子视图（整棵子树是随 contentView 一起
        // 挂到窗口上的），所以再补一次，带去重。
        if window != nil { installMonitor() }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            // 延到本次事件派发**之后**再设光标：本地 monitor 跑在窗口之前，
            // 直接 `set()` 会被窗口自己的光标矩形解析覆盖掉（表现就是第一次
            // 悬停没反应、点一下之后才生效）。
            DispatchQueue.main.async { self?.updateHover(with: event) }
            return event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func updateHover(with event: NSEvent) {
        guard isEnabled, isInteractionEnabled, let window else { return }
        // `mouseMoved` 的 event.window 在"窗口还没成为 key"时会是 nil —— 截图刚
        // 浮出来的那一下正好是这种状态，于是第一个手柄永远等不到悬停。窗口是
        // 已知的，位置改成从**屏幕坐标**推，就不依赖事件自报的门牌号。
        let windowPoint: NSPoint
        if event.window == window {
            windowPoint = event.locationInWindow
        } else if event.window == nil {
            windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        } else {
            return
        }
        let local = convert(windowPoint, from: nil)
        let hit = handle(at: local)

        if hit != hovered {
            hovered = hit
            needsDisplay = true
        }
        // 光标**主动**设，不指望 `addCursorRect`：光标矩形的仲裁依赖
        // `NSWindow.updateCursor` 的时序，实测要等下一次命中测试才生效——
        // 表现就是"得先点一下才会变成方向箭头"。这里自己算，顺带保证
        // 移出手柄后能正确回到 I-beam / 手掌。
        let cursor: NSCursor
        if let hit {
            cursor = Self.resizeCursor(angle: hit.arrowAngle)
        } else if let textLayer, textLayer.hitTest(local) != nil {
            cursor = .iBeam                       // 划选文字
        } else {
            cursor = fallbackCursor               // 空白处：手掌（预览里）/ 箭头（覆盖层里）
        }
        cursor.set()
    }

    /// 下方可划选文字的视图（`OCRHighlightView`）。用于判断该显示 I-beam。
    weak var textLayer: NSView?

    /// 不在手柄、也不在文字上时的光标。
    var fallbackCursor: NSCursor = .openHand

    /// 方向对应的调整光标。
    ///
    /// 系统其实有 `NSCursor.frameResizeCursor(from:in:)`（macOS 15+），但它标了
    /// `NS_REFINED_FOR_SWIFT`，Swift 侧根本取不到这个名字；而且部署目标是 macOS 14。
    /// 所以自己画：双向箭头按方向旋转，白线 + 深色描边，任何背景上都看得清。
    private func cursor(for handle: Handle) -> NSCursor {
        Self.resizeCursor(angle: handle.arrowAngle)
    }

    private static var cursorCache: [CGFloat: NSCursor] = [:]

    private static func resizeCursor(angle: CGFloat) -> NSCursor {
        if let cached = cursorCache[angle] { return cached }

        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            context.saveGState()
            context.translateBy(x: side / 2, y: side / 2)
            context.rotate(by: angle * .pi / 180)

            // 一条线 + 两端箭头（沿 ±x 轴画，靠上面的 rotate 转到对应方向）
            let half: CGFloat = 5.5
            let head: CGFloat = 3.4
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -half, y: 0))
            path.addLine(to: CGPoint(x: half, y: 0))
            for (tip, direction) in [(half, CGFloat(1)), (-half, CGFloat(-1))] {
                path.move(to: CGPoint(x: tip, y: 0))
                path.addLine(to: CGPoint(x: tip - direction * head, y: head * 0.85))
                path.move(to: CGPoint(x: tip, y: 0))
                path.addLine(to: CGPoint(x: tip - direction * head, y: -head * 0.85))
            }

            context.setLineCap(.round)
            context.setLineJoin(.round)
            // 先描一圈深色（浅色截图上靠它显形），再压一条白线（深色截图上靠它显形）
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.85).cgColor)
            context.setLineWidth(3)
            context.addPath(path)
            context.strokePath()

            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1.4)
            context.addPath(path)
            context.strokePath()

            context.restoreGState()
            return true
        }

        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
        cursorCache[angle] = cursor
        return cursor
    }

    override func resetCursorRects() {
        for handle in Handle.allCases {
            addCursorRect(hitRect(for: handle), cursor: cursor(for: handle))
        }
    }
}

private extension ResizeHandlesView.Handle {

    /// 双向箭头要旋转的角度（度）。0 = 左右，90 = 上下，
    /// +45 = 右上↔左下那条对角线，-45 = 左上↔右下那条。
    var arrowAngle: CGFloat {
        switch self {
        case .left, .right:            return 0
        case .top, .bottom:            return 90
        case .topRight, .bottomLeft:   return 45
        case .topLeft, .bottomRight:   return -45
        }
    }
}

// MARK: - 悬停容器与角落「×」

/// 预览面板的外层容器。它自己不该接鼠标（图片那一层才是事件入口），
/// 只借 `mouseEntered/Exited` 知道"鼠标在不在图上"，用来收放角落那颗「×」。
///
/// 不用 `NSTrackingArea` 铺在图片视图上：图片视图上还压着文字层和手柄层，
/// 三层各自的 tracking 会互相打断，移进移出时「×」会闪。挂在容器上只有一份进出事件。
final class PreviewHoverContainer: NSView {

    /// 鼠标进出这块预览时回调（进 = true）。
    var onHoverChanged: ((Bool) -> Void)?

    /// 环境落影那一层。`layout()` 时把它的路径撑成图片的圆角矩形。
    weak var ambientShadow: CALayer?

    private var hovering = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        guard !hovering else { return }
        hovering = true
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard hovering else { return }
        hovering = false
        onHoverChanged?(false)
    }

    /// 图片区域（含圆角）的阴影路径。阴影必须从图片边缘长出来，而不是从
    /// 那个含 18pt 透明边的窗口外框长出来，否则看着像有一圈看不见的框在投影。
    func updateAmbientShadowPath(imageFrame: NSRect) {
        guard let ambientShadow else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ambientShadow.frame = bounds
        let radius = Design.Radius.card
        ambientShadow.shadowPath = CGPath(roundedRect: imageFrame.insetBy(dx: 1, dy: 1),
                                          cornerWidth: radius, cornerHeight: radius,
                                          transform: nil)
        ambientShadow.shadowColor = NSColor.black.cgColor
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        // 窗口尺寸 / 缩放变了，阴影路径要跟着重算，否则放大后阴影还停在旧边界。
        if let imageView = subviews.first(where: { $0 is ImagePreviewView }) {
            updateAmbientShadowPath(imageFrame: imageView.frame)
        }
    }
}

/// 角落那颗「×」。自绘圆形底：无边框 `NSButton` 在浅色截图上会整个看不见。
final class HoverCloseButton: NSButton {

    private let backdrop = CALayer()
    private var hovered = false

    /// 预览面板不是 key window 时，第一下点击会被系统当成"激活窗口"吞掉 ——
    /// 用户就得点两次「×」才关得掉。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        backdrop.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        backdrop.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        backdrop.borderWidth = 1
        layer?.addSublayer(backdrop)
    }

    required init?(coder: NSCoder) { fatalError("不支持归档加载") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        backdrop.cornerRadius = bounds.height / 2
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        setBackdropHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        setBackdropHovering(false)
    }

    private func setBackdropHovering(_ hovering: Bool) {
        let target = hovering
            ? NSColor.systemRed.withAlphaComponent(0.85)
            : NSColor.black.withAlphaComponent(0.55)
        let edge = hovering
            ? NSColor.white.withAlphaComponent(0.42)
            : NSColor.white.withAlphaComponent(0.28)
        Motion.animate(backdrop, keyPath: "backgroundColor",
                       from: backdrop.presentation()?.backgroundColor,
                       to: target.cgColor,
                       duration: Design.Timing.fade,
                       curve: Motion.Curve.move,
                       key: "close.hover.background")
        Motion.animate(backdrop, keyPath: "borderColor",
                       from: backdrop.presentation()?.borderColor,
                       to: edge.cgColor,
                       duration: Design.Timing.fade,
                       curve: Motion.Curve.move,
                       key: "close.hover.edge")
        backdrop.backgroundColor = target.cgColor
        backdrop.borderColor = edge.cgColor
    }
}

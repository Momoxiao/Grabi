import AppKit
import Darwin
import Foundation

/// 进程级单实例锁。
///
/// `LSUIElement` 菜单栏应用没有 Dock 图标，用户点“打开”时既可能由 LaunchServices
/// 激活已有进程，也可能因为项目目录里还有一份构建产物而直接启动第二个进程；后台
/// `SMAppService` agent 又可能同时用 `RunAtLoad` 拉起同一份二进制。仅靠
/// `NSRunningApplication` 去重有时会输给这组竞态，所以这里用文件锁把“只能有一个”
/// 变成进程启动阶段就成立的事实：
///
/// - 第一个进程拿到 `flock`，正常进入 `NSApplication.run()`；
/// - 后到的进程拿不到锁，通知已有进程把菜单栏图标找回来，然后 `exit(0)`；
/// - 以 0 退出，不会触发保活 agent 的“崩溃后重启”。
final class SingleInstance {

    static let shared = SingleInstance()

    /// 复制实例请求已有实例回到前台 / 恢复菜单栏时要用的跨进程通知名。
    static let reopenNotification = Notification.Name("com.momoxiao.grabi.reopen")

    private var lockFileDescriptor: Int32 = -1

    private init() {}

    /// 尝试成为唯一实例。成功返回 true；失败说明另一个实例已经持有锁。
    ///
    /// 锁文件创建失败时选择失败开放（返回 true）：不能让一个目录权限问题把用户
    /// 挡在软件之外。正常 macOS 用户目录下这个分支不会发生。
    func acquire() -> Bool {
        guard lockFileDescriptor < 0 else { return true }

        let url = lockFileURL
        let descriptor = url.path.withCString { path in
            open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            Log.app.error("单实例锁文件无法创建，继续启动（\(url.path, privacy: .public)）")
            return true
        }

        var lockResult: Int32
        repeat {
            lockResult = flock(descriptor, LOCK_EX | LOCK_NB)
        } while lockResult != 0 && errno == EINTR

        guard lockResult == 0 else {
            close(descriptor)
            return false
        }

        lockFileDescriptor = descriptor
        writeProcessIdentifier()
        return true
    }

    /// 释放锁。正常退出、`applicationWillTerminate` 或进程结束都会走到这里；
    /// 即使没有显式调用，内核也会在进程退出时释放 `flock`。
    func release() {
        guard lockFileDescriptor >= 0 else { return }
        _ = flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        lockFileDescriptor = -1
    }

    /// 后到实例调用：唤醒已有进程，并请求它把菜单栏图标 / 设置窗带回来。
    func requestReopen() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.momoxiao.grabi"
        let currentPID = getpid()
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != currentPID }) {
            _ = running.activate(options: [])
        }
        DistributedNotificationCenter.default().post(name: Self.reopenNotification,
                                                     object: nil,
                                                     userInfo: nil)
        // 给通知中心一点投递时间。这个进程马上以 0 退出，不会变成第二个菜单栏图标。
        Thread.sleep(forTimeInterval: 0.15)
    }

    // MARK: - 私有

    private var lockFileURL: URL {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory,
                                       in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = support.appendingPathComponent("Grabi", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("instance.lock")
    }

    private func writeProcessIdentifier() {
        guard lockFileDescriptor >= 0 else { return }
        let text = "\(getpid())\n"
        _ = ftruncate(lockFileDescriptor, 0)
        _ = text.withCString { pointer in
            write(lockFileDescriptor, pointer, strlen(pointer))
        }
    }
}

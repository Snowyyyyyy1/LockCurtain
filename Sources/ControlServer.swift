// ControlServer.swift —— 本机控制接口：Unix 域套接字 + 命令行
//
// 套接字：~/Library/Application Support/LockCurtain/control.sock，权限 0600，
// 并用 getpeereid 校验对方 uid，只接受当前用户的连接。App 不监听任何网络端口；
// 远程控制（SSH、快捷指令「通过 SSH 运行脚本」）都在外面调命令行。
//
// 协议：一行命令进，一行 JSON 出。
//   away     进入离开模式
//   preview  显示预览遮罩
//   hide     撤遮罩；离开模式下先锁屏再撤 —— 任何命令都不会露出已解锁的桌面
//   status   查询状态
//   settings 打开设置窗口（菜单栏和 Dock 图标都隐藏时的另一个入口）
//
// 命令行：LockCurtain --send <命令>。away / preview / settings 在 App 没运行时会先拉起它。

import AppKit

enum ControlSocket {
    static var path: String { AppPaths.file("control.sock").path }

    static func address() -> sockaddr_un? {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }

    static func withSockaddr<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// 对端关闭后再写不触发 SIGPIPE。实测单靠它挡不住（进程仍以 141 退出），
    /// 进程级的 signal(SIGPIPE, SIG_IGN) 在 main.swift 里，这里留作第二道
    static func noSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// 连上返回 fd，没有实例在监听返回 nil
    static func connect() -> Int32? {
        guard var addr = address() else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        noSigPipe(fd)
        if withSockaddr(&addr, { Darwin.connect(fd, $0, $1) }) != 0 { close(fd); return nil }
        return fd
    }

    static func readLine(_ fd: Int32, timeout: Int) -> String {
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 256)
        while data.count < 4096, !data.contains(10) {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data += buf[0..<n]
        }
        let s = String(decoding: data, as: UTF8.self)
        return String(s.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    static func writeAll(_ fd: Int32, _ s: String) {
        let bytes = Array(s.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress! + off, $0.count - off) }
            if n <= 0 { return }
            off += n
        }
    }

    static func json(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
            return #"{"ok":false,"error":"encode failed"}"#
        }
        return String(decoding: d, as: UTF8.self)
    }
}

@MainActor
final class ControlServer {
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let handle: (String) async -> [String: Any]

    init(handle: @escaping (String) async -> [String: Any]) { self.handle = handle }

    func start() {
        // 用文件锁决定谁提供服务：拿不到锁说明已有实例（比如 open -n 又起了一个），不抢。
        // 先连一下再 unlink + bind 的做法在两个实例同时启动时会互相删掉对方的套接字。
        // 锁随进程退出自动释放，fd 不关
        let lockFD = open(AppPaths.file("control.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD) }
            NSLog("ControlServer: 已有实例在提供服务，跳过")
            return
        }
        guard var addr = ControlSocket.address() else {
            NSLog("ControlServer: 套接字路径过长 %@", ControlSocket.path)
            return
        }
        unlink(ControlSocket.path)      // 上次异常退出留下的旧文件
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        guard ControlSocket.withSockaddr(&addr, { bind(fd, $0, $1) }) == 0,
              chmod(ControlSocket.path, 0o600) == 0,
              listen(fd, 8) == 0 else {
            NSLog("ControlServer: 启动失败 errno=%d", errno)
            close(fd)
            return
        }
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptOne() } }
        src.resume()
        source = src
        NSLog("ControlServer listening at %@", ControlSocket.path)
    }

    private func acceptOne() {
        let c = accept(listenFD, nil, nil)
        guard c >= 0 else { return }
        ControlSocket.noSigPipe(c)
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else {
            NSLog("ControlServer: 拒绝 uid=%d 的连接", uid)
            close(c)
            return
        }
        let handle = self.handle
        // 读请求放后台，慢客户端不卡主线程；处理回主线程，回复很短直接写
        DispatchQueue.global().async {
            let cmd = ControlSocket.readLine(c, timeout: 2)
            guard !cmd.isEmpty else { close(c); return }    // 只连不发（探测、超时），不回复
            Task { @MainActor in
                NSLog("ControlServer: 命令 %@", cmd)
                ControlSocket.writeAll(c, ControlSocket.json(await handle(cmd)) + "\n")
                close(c)
            }
        }
    }
}

enum ControlClient {
    /// 返回进程退出码：回复 ok 为 0，否则 1
    static func send(_ cmd: String) -> Int32 {
        var fd = ControlSocket.connect()
        if fd == nil {
            guard ["away", "preview", "settings"].contains(cmd) else {
                // 没在运行：status / hide 不用拉起
                print(ControlSocket.json(["ok": true, "running": false]))
                return 0
            }
            // 拉起 App（-g 不抢前台），等套接字就绪，最多 5 秒
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-g", Bundle.main.bundlePath]
            try? p.run()
            p.waitUntilExit()
            var waited = 0
            while fd == nil, waited < 50 {
                usleep(100_000)
                waited += 1
                fd = ControlSocket.connect()
            }
        }
        guard let fd else {
            print(ControlSocket.json(["ok": false, "error": "LockCurtain 没在运行，也没能拉起"]))
            return 1
        }
        ControlSocket.writeAll(fd, cmd + "\n")
        let reply = ControlSocket.readLine(fd, timeout: 10)     // hide 可能要等锁屏界面出来，最多约 6.5 秒
        close(fd)
        print(reply.isEmpty ? ControlSocket.json(["ok": false, "error": "没有收到回复"]) : reply)
        let ok = (try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])?["ok"] as? Bool
        return ok == true ? 0 : 1
    }
}

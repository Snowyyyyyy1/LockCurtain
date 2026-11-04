// CurtainLinkHub.swift —— 这个进程里的那一个 BLECurtainLink
//
// 手机是蓝牙外设：整个进程只能有一个 CBPeripheralManager 在广播这个服务。App 界面（AppModel）和快捷指令
// （IntentCurtainRunner）必须用同一个连接，所以谁先到谁来建，后到的拿现成的：
//   * App 被划掉后系统为快捷指令拉起进程（没有界面）：快捷指令先建，之后用户打开 App，AppModel 拿到的还是它。
//   * App 开着：AppModel 建的，快捷指令拿它的。
// AppModel 每次采用一个蓝牙连接（含演示里暂存的那个）都登记在这里；连接本身的行为一点没变。

import Foundation

@MainActor
enum CurtainLinkHub {
    private(set) static var current: BLECurtainLink?

    /// 有现成的就用，没有就按钥匙串里的配对情况建一个并登记
    static func obtain(paired: Bool, macName: String?) -> BLECurtainLink {
        if let current { return current }
        let link = BLECurtainLink(paired: paired, macName: macName)
        current = link
        return link
    }

    static func register(_ link: BLECurtainLink) {
        current = link
    }
}

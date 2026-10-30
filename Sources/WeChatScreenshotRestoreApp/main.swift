import AppKit
import SwiftUI
import WeChatScreenshotRestoreInstaller

@main
struct WeChatScreenshotRestoreApp: App {
    @StateObject private var model = InstallerViewModel()

    var body: some Scene {
        WindowGroup {
            InstallerView(model: model)
                .frame(minWidth: 590, minHeight: 490)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
private final class InstallerViewModel: ObservableObject {
    @Published private(set) var report: WeChatAppPreflightReport?
    @Published private(set) var backupRecord: WeChatInstallationRecord?
    @Published private(set) var working = false
    @Published private(set) var message = "正在检查此 Mac 上的微信版本…"
    @Published private(set) var errorMessage: String?

    var state: InstallerState {
        guard let report else { return .checking }
        if report.runtimeAlreadyInstalled,
           report.signatureValid,
           let backupRecord,
           report.version == backupRecord.version,
           report.build == backupRecord.build {
            return .installed
        }
        if report.canInstall { return .ready }
        return .blocked
    }

    var isWeChatRunning: Bool { !(report?.runningProcessIDs.isEmpty ?? true) }
    var hasQuarantine: Bool { !(report?.quarantinePaths.isEmpty ?? true) }
    var quarantineInspectionFailed: Bool { !(report?.quarantineInspectionFailures.isEmpty ?? true) }

    func refresh() {
        guard !working else { return }
        working = true
        errorMessage = nil
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    (try WeChatScreenshotRestorePreflight.inspect(), try WeChatScreenshotRestoreInstaller.latestRecord())
                }.value
                report = data.0
                backupRecord = data.1
                if state == .installed {
                    let recheckNote = "本机实测提示，截图限制可能是临时性的。建议几天后恢复原版，检查限制是否解除；仍受限时可重新修复。"
                    let permissionNote = isWeChatRunning
                        ? "恢复组件已加载。若微信自带截图提示无权限，请先完全退出微信，再在系统设置中重新授权当前微信。"
                        : "恢复组件已安装。请重新打开微信测试；若微信自带截图提示无权限，在系统设置中重新授权当前微信并完全退出、重开。"
                    message = "\(recheckNote)\n\(permissionNote)"
                } else if state == .ready {
                    let securityNote = hasQuarantine
                        ? "安装会保留隔离标记；修复后的微信首次打开可能需要你通过 macOS 安全提示。"
                        : "安装前会先保存完整原版。"
                    message = "\(validationMessage(for: data.0)) \(securityNote)"
                } else {
                    message = reportSummary(data.0)
                }
            } catch {
                report = nil
                backupRecord = nil
                errorMessage = error.localizedDescription
                message = "无法检查微信。"
            }
            working = false
        }
    }

    func install() {
        guard state == .ready, !working else { return }
        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = "先备份，再修复微信截图？"
        let validationNote: String
        if let report,
           let validatedBuild = WeChatScreenshotRestorePreflight.runtimeValidatedBuild(
               version: report.version,
               build: report.build
           ) {
            validationNote = "当前 \(validatedBuild.displayName) 已完成本机运行验证。"
        } else if let report {
            let testedVersions = WeChatScreenshotRestorePreflight.runtimeValidatedBuilds
                .map { $0.displayName }
                .joined(separator: "、")
            validationNote = "当前 WeChat \(report.version ?? "未知版本")（\(report.build ?? "未知 build")）没有实测记录；已验证版本：\(testedVersions)。实现按 AppKit 的 setSharingType: 方法定位，不依赖 WeChat 固定机器码偏移；其他版本仍可能无效果、启动失败或异常退出。"
        } else {
            validationNote = "当前微信版本尚未通过预检。"
        }
        confirmation.informativeText = "\(validationNote) 程序会先在 \(WeChatScreenshotRestoreInstaller.supportURL.path) 保存并校验一份完整原版，再只修改 /Applications/WeChat.app。为加载恢复组件，腾讯签名会改为本机 ad-hoc 签名，并为微信主程序增加库加载例外；这可能影响登录、钥匙串、应用组身份或官方更新。macOS 的屏幕录制授权按签名身份匹配；改签后，微信自带截图可能需要在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”删除旧授权并重新添加当前微信，然后完全退出、重开。隔离标记会保留，系统安全设置不会改变。\(hasQuarantine ? "首次打开时，macOS 可能要求你在“隐私与安全性”中手动批准此应用；如果系统没有提供批准选项或微信无法启动，请立即用本程序恢复原版。" : "") 程序不会启动微信，也不会读取或改动聊天、登录或容器数据。请确认微信已正常退出。"
        confirmation.addButton(withTitle: "备份并修复")
        confirmation.addButton(withTitle: "取消")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        let runtimeURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libWindowSharingRuntime.dylib")
        working = true
        errorMessage = nil
        message = "正在准备完整备份…"
        let progress: (String) -> Void = { [weak self] line in
            Task { @MainActor [weak self] in self?.message = line }
        }
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try WeChatScreenshotRestoreInstaller.install(runtimeURL: runtimeURL, progress: progress)
                }.value
                backupRecord = result.record
                message = hasQuarantine
                    ? "修复已安装。原版备份保存在 \(URL(fileURLWithPath: result.record.backupAppPath).deletingLastPathComponent().path)。首次打开可能需要你手动批准；请用空白或非敏感窗口验证截图。若微信自带截图提示无权限，请按授权提示在系统设置重绑微信权限。"
                    : "修复已安装。原版备份保存在 \(URL(fileURLWithPath: result.record.backupAppPath).deletingLastPathComponent().path)。请重新打开微信后测试；若微信自带截图提示无权限，请在系统设置重绑微信权限。"
                refreshAfterOperation()
            } catch {
                errorMessage = error.localizedDescription
                message = "安装未完成。原版微信和已建立的完整备份均保留。"
                refreshAfterOperation()
            }
        }
    }

    func rollback() {
        guard state == .installed, !isWeChatRunning, !working else { return }
        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = "恢复腾讯原版微信？"
        confirmation.informativeText = "这会用安装前保存的腾讯原版替换当前修复版，截图恢复将停止。系统屏幕录制授权按签名身份匹配；恢复原版后，微信自带截图可能需要在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”重新添加当前微信，然后完全退出、重开。原版备份仍会保留。请确认微信已正常退出。"
        confirmation.addButton(withTitle: "恢复原版")
        confirmation.addButton(withTitle: "取消")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        working = true
        errorMessage = nil
        message = "正在核对原版备份…"
        let progress: (String) -> Void = { [weak self] line in
            Task { @MainActor [weak self] in self?.message = line }
        }
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try WeChatScreenshotRestoreInstaller.rollback(progress: progress)
                }.value
                message = "原版微信已恢复。若微信自带截图提示无权限，请在系统设置中重新授权当前微信，再完全退出并重开。备份仍保留在 \(WeChatScreenshotRestoreInstaller.supportURL.path)。"
                refreshAfterOperation()
            } catch {
                errorMessage = error.localizedDescription
                message = "未能恢复原版。"
                refreshAfterOperation()
            }
        }
    }

    func openBackupFolder() {
        NSWorkspace.shared.open(WeChatScreenshotRestoreInstaller.supportURL)
    }

    private func refreshAfterOperation() {
        working = false
        refresh()
    }

    private func reportSummary(_ report: WeChatAppPreflightReport) -> String {
        if !report.quarantineInspectionFailures.isEmpty {
            return "无法读取微信的 macOS 隔离状态；为避免改变系统安全行为，安装已停止。"
        }
        if !report.issues.isEmpty {
            return report.issues.joined(separator: "\n")
        }
        if !report.quarantinePaths.isEmpty {
            return "\(validationMessage(for: report)) 安装会保留隔离标记；修复后的微信首次打开可能需要你通过 macOS 安全提示。"
        }
        return "请先检查微信状态。"
    }

    private func validationMessage(for report: WeChatAppPreflightReport) -> String {
        if let validatedBuild = WeChatScreenshotRestorePreflight.runtimeValidatedBuild(
            version: report.version,
            build: report.build
        ) {
            return "\(validatedBuild.displayName)已通过本机运行验证。"
        }
        let testedVersions = WeChatScreenshotRestorePreflight.runtimeValidatedBuilds
            .map { $0.displayName }
            .joined(separator: "、")
        return "当前 WeChat \(report.version ?? "未知版本")（\(report.build ?? "未知 build")）未实测；已验证版本：\(testedVersions)。结构检查通过后仍可继续安装。"
    }
}

private enum InstallerState: Equatable {
    case checking
    case ready
    case installed
    case blocked
}

private struct InstallerView: View {
    @ObservedObject var model: InstallerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                brandIcon
                    .resizable()
                    .scaledToFit()
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 15))

                VStack(alignment: .leading, spacing: 4) {
                    Text("微信截图恢复")
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                    Text("为官方 WeChat 恢复 macOS 窗口截图")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: model.refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
                .disabled(model.working)
                .help("重新检查微信版本与运行状态")
            }

            statusPanel
                .padding(.top, 28)

            VStack(alignment: .leading, spacing: 13) {
                Label("只修改微信 App 本体；不读取或改动聊天、登录与容器数据", systemImage: "lock.shield")
                Label("安装前创建完整备份；出问题可恢复腾讯原版", systemImage: "arrow.uturn.backward.circle")
                Label(
                    model.quarantineInspectionFailed
                        ? "无法确认隔离状态；微信安装包保持不变"
                        : (model.hasQuarantine
                            ? "保留隔离标记；修复后的微信首次打开可能需 macOS 安全批准"
                            : (model.state == .installed && model.isWeChatRunning
                                ? "请用 macOS 自带截图测试；本工具不读取或保存屏幕画面"
                                : "不强退、不自动启动微信；需由你正常退出与重新打开")),
                    systemImage: "hand.raised"
                )
                Label("本机重签会替换腾讯签名，可能影响登录、钥匙串、应用组或更新", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.primary.opacity(0.86))
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .padding(.top, 18)

            Spacer(minLength: 18)

            HStack(spacing: 12) {
                Button(action: model.install) {
                    Label("备份并修复截图", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.state != .ready || model.working)

                Button(action: model.rollback) {
                    Label("恢复原版", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.state != .installed || model.isWeChatRunning || model.working)
            }

            HStack {
                Text("备份位置：~/Library/Application Support/WeChatScreenshotRestore")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("在 Finder 中显示") { model.openBackupFolder() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.top, 16)
        }
        .padding(28)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.refresh() }
        .alert("微信截图恢复", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.dismissError() } }
        )) {
            Button("好") { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var statusPanel: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(statusColor.opacity(0.12)).frame(width: 44, height: 44)
                if model.working || model.state == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle)
                    .font(.system(size: 15, weight: .semibold))
                Text(model.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusColor.opacity(0.075), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(statusColor.opacity(0.18), lineWidth: 1))
    }

    private var statusTitle: String {
        switch model.state {
        case .checking: return "正在检查"
        case .ready:
            guard let report = model.report else { return "正在检查" }
            if report.isRuntimeValidatedBuild {
                return model.hasQuarantine ? "已验证版本；微信首次启动可能需手动批准" : "已验证版本，可以备份后修复"
            }
            return model.hasQuarantine ? "此版本未经实测；微信首次启动可能需手动批准" : "此版本未经实测，继续前请确认风险"
        case .installed: return model.isWeChatRunning ? "恢复组件已安装，微信正在运行" : "截图恢复组件已安装"
        case .blocked:
            if model.report == nil { return "无法检查微信" }
            else if model.quarantineInspectionFailed { return "无法读取 macOS 隔离状态" }
            else { return "当前状态不支持自动修复" }
        }
    }

    private var statusSymbol: String {
        switch model.state {
        case .checking: "hourglass"
        case .ready: "checkmark.circle.fill"
        case .installed: "checkmark.shield.fill"
        case .blocked: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .checking: .blue
        case .ready: (model.hasQuarantine || model.report?.isRuntimeValidatedBuild == false) ? .orange : .green
        case .installed: .green
        case .blocked: .orange
        }
    }

    private var brandIcon: Image {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else {
            return Image(systemName: "rectangle.on.rectangle.angled")
        }
        return Image(nsImage: icon)
    }
}

private extension InstallerViewModel {
    func dismissError() { errorMessage = nil }
}

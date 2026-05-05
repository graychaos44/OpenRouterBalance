import SwiftUI
import AppKit
import Combine

struct BalanceInfo {
    let limit: Double
    let limitRemaining: Double
    let usage: Double
    let usageDaily: Double
    let usageWeekly: Double
    let usageMonthly: Double
    let isFreeTier: Bool
    let limitReset: String
}

let refreshIntervals: [(String, TimeInterval)] = [
    ("1 min", 60),
    ("3 min", 180),
    ("5 min", 300),
    ("10 min", 600),
    ("30 min", 1800),
    ("1 hour", 3600),
]

class BalanceVM: ObservableObject {
    @Published var info: BalanceInfo?
    @Published var isLoading = false
    @Published var errorMsg: String?
    @Published var accountBalance: Double = 10.0
    @Published var refreshIntervalIndex: Int = 2 { // default: 5 min
        didSet { saveRefreshInterval(); restartTimer() }
    }
    private let totalCredit: Double = 10.0
    @Published var apiKeyInput: String = ""
    private var refreshTimer: Timer?
    private var _apiKey: String = ""
    private let defaults = UserDefaults.standard
    private let refreshKey = "refreshIntervalIndex"
    private let apiKeyKey = "openrouter_api_key"

    init() {
        refreshIntervalIndex = loadRefreshInterval()
        _apiKey = loadApiKey()
        apiKeyInput = _apiKey
    }

    var currentApiKey: String {
        return _apiKey
    }

    func fetch() {
        guard !isLoading else { return }
        isLoading = true
        errorMsg = nil
        guard let url = URL(string: "https://openrouter.ai/api/v1/auth/key") else {
            errorMsg = "Invalid URL"
            isLoading = false
            return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(_apiKey)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false
                if let error = error {
                    self?.errorMsg = "Network: \(error.localizedDescription)"
                    return
                }
                guard let data = data else {
                    self?.errorMsg = "No data"
                    return
                }
                do {
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let d = json["data"] as? [String: Any] else {
                        self?.errorMsg = "Parse: no data key"
                        return
                    }
                    let info = BalanceInfo(
                        limit: d["limit"] as? Double ?? 0,
                        limitRemaining: d["limit_remaining"] as? Double ?? 0,
                        usage: d["usage"] as? Double ?? 0,
                        usageDaily: d["usage_daily"] as? Double ?? 0,
                        usageWeekly: d["usage_weekly"] as? Double ?? 0,
                        usageMonthly: d["usage_monthly"] as? Double ?? 0,
                        isFreeTier: d["is_free_tier"] as? Bool ?? false,
                        limitReset: d["limit_reset"] as? String ?? "unknown"
                    )
                    self?.info = info
                    self?.accountBalance = self?.totalCredit ?? 10.0 - info.usage
                } catch {
                    self?.errorMsg = "Parse: \(error.localizedDescription)"
                }
            }
        }.resume()
    }

    func startAutoRefresh() {
        let interval = refreshIntervals[refreshIntervalIndex].1
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    func restartTimer() {
        stopAutoRefresh()
        startAutoRefresh()
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    var refreshIntervalLabel: String {
        refreshIntervals[refreshIntervalIndex].0
    }

    func saveApiKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        _apiKey = key
        defaults.set(key, forKey: apiKeyKey)
        fetch()
    }

    private func saveRefreshInterval() {
        defaults.set(refreshIntervalIndex, forKey: refreshKey)
    }

    private func loadRefreshInterval() -> Int {
        let saved = defaults.integer(forKey: refreshKey)
        return (saved >= 0 && saved < refreshIntervals.count) ? saved : 2
    }

    private func loadApiKey() -> String {
        // 1. UserDefaults
        if let saved = defaults.string(forKey: apiKeyKey), !saved.isEmpty {
            return saved
        }
        // 2. File
        let keyFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openrouter_api_key")
        if let key = try? String(contentsOf: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        // 3. Env var
        return ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? ""
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var vm = BalanceVM()
    var popover: NSPopover!
    var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 280, height: 580)
        popover.contentViewController = NSHostingController(rootView: PopoverView(vm: vm))
        self.popover = popover

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "💳⏳"
        let button = statusItem.button!
        button.action = #selector(statusBarButtonClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        vm.fetch()
        vm.startAutoRefresh()

        vm.$info.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateTitle()
        }.store(in: &cancellables)
        vm.$accountBalance.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateTitle()
        }.store(in: &cancellables)
    }

    func updateTitle() {
        if let info = vm.info {
            let weeklyRem = String(format: "%.2f", info.limitRemaining)
            let acct = String(format: "%.2f", vm.accountBalance)
            statusItem.button?.title = "💳\(acct) | \(weeklyRem)"
        }
    }

    @objc func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!
        if event.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Refresh Now", action: #selector(forceRefresh), keyEquivalent: "r"))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
            NSMenu.popUpContextMenu(menu, with: event, for: sender)
        } else {
            togglePopover()
        }
    }

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc func forceRefresh() {
        vm.fetch()
    }

    @objc func quitApp() {
        vm.stopAutoRefresh()
        NSApp.terminate(nil)
    }
}

struct PopoverView: View {
    @ObservedObject var vm: BalanceVM

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let info = vm.info {
                    // 어카운트
                    HStack {
                        Image(systemName: "dollarsign.circle.fill")
                            .foregroundColor(.green)
                            .font(.title3)
                        Text("Account")
                            .fontWeight(.bold)
                            .font(.title3)
                    }

                    Text("$\(String(format: "%.2f", vm.accountBalance))")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                    Text("(of $10.00 credit)")
                        .font(.callout)
                        .foregroundColor(.gray)

                    HStack {
                        Text("Credit: $\(String(format: "%.2f", info.limit))\(info.limit < 10 ? " (Weekly)" : "")").font(.callout).foregroundColor(.gray)
                        Spacer()
                        Text("Used: $\(String(format: "%.4f", info.usage))").font(.callout).foregroundColor(.gray)
                    }

                    ProgressView(value: info.limit > 0 ? max(0, vm.accountBalance / info.limit) : 0)
                        .tint(.green)

                    Divider()

                    // Weekly limit
                    HStack {
                        Image(systemName: "creditcard")
                            .foregroundColor(.blue)
                        Text("Weekly Limit")
                            .fontWeight(.semibold)
                            .font(.callout)
                    }

                    Text("$\(String(format: "%.2f", info.limitRemaining)) / $\(String(format: "%.2f", info.limit))")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))

                    ProgressView(value: info.limit > 0 ? info.limitRemaining / info.limit : 0)
                        .tint(.blue)

                    Text("Reset: \(info.limitReset)")
                        .font(.callout)
                        .foregroundColor(.gray)

                    Divider()

                    // Usage
                    HStack {
                        Image(systemName: "chart.bar")
                            .foregroundColor(.orange)
                        Text("Usage")
                            .fontWeight(.semibold)
                            .font(.callout)
                    }

                    HStack { Text("Today").font(.callout).foregroundColor(.secondary); Spacer(); Text("$\(String(format: "%.4f", info.usageDaily))").monospacedDigit().font(.callout) }
                    HStack { Text("Week").font(.callout).foregroundColor(.secondary); Spacer(); Text("$\(String(format: "%.4f", info.usageWeekly))").monospacedDigit().font(.callout) }
                    HStack { Text("Month").font(.callout).foregroundColor(.secondary); Spacer(); Text("$\(String(format: "%.4f", info.usageMonthly))").monospacedDigit().font(.callout) }

                    Divider()

                    // Free requests
                    HStack {
                        Image(systemName: "gift")
                            .foregroundColor(.purple)
                        Text("Daily Requests")
                            .fontWeight(.semibold)
                            .font(.callout)
                    }

                    Text("1000 / day")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundColor(.purple)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Free: gemma-3-27b:free, gemma-4-31b:free")
                            .font(.callout).foregroundColor(.secondary)
                        Text("Best paid: deepseek-v4-flash ($0.14/1M)")
                            .font(.callout).foregroundColor(.secondary)
                    }

                    Divider()

                    // Refresh interval setting
                    HStack {
                        Image(systemName: "clock")
                            .foregroundColor(.secondary)
                        Text("Auto-refresh")
                            .fontWeight(.semibold)
                            .font(.callout)
                    }

                    Picker("", selection: $vm.refreshIntervalIndex) {
                        ForEach(0..<refreshIntervals.count, id: \.self) { i in
                            Text(refreshIntervals[i].0).tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.callout)

                    Divider()

                    // API Key setting
                    HStack {
                        Image(systemName: "key")
                            .foregroundColor(.secondary)
                        Text("API Key")
                            .fontWeight(.semibold)
                            .font(.callout)
                    }

                    HStack {
                        SecureField("sk-or-v1-...", text: $vm.apiKeyInput)
                            .font(.callout)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { vm.saveApiKey() }
                        Button("Save") { vm.saveApiKey() }
                            .font(.callout)
                            .buttonStyle(.borderless)
                    }

                    } else if vm.isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else {
                    if let err = vm.errorMsg {
                        Text("Error: \(err)")
                            .foregroundColor(.red)
                            .font(.body)
                    }
                    Text("No data")
                        .foregroundColor(.secondary)
                }

                Button { vm.fetch() } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh")
                    }
                }
                .buttonStyle(.borderless)
            }
            .padding()
        }
        .frame(width: 260)
        .background(Color.white)
    }
}

@main
struct OpenRouterBalanceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}
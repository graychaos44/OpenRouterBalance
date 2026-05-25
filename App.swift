import SwiftUI
import AppKit
import Combine

struct KeyBalance {
    let index: Int
    let label: String
    let limit: Double
    let limitRemaining: Double
    let usage: Double
    let usageMonthly: Double
    let limitReset: String
}

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
    @Published var keyBalances: [KeyBalance] = []
    @Published var isLoading = false
    @Published var errorMsg: String?
    @Published var accountBalance: Double = 0.0
    @Published var totalLimit: Double = 0.0
    @Published var totalUsage: Double = 0.0
    @Published var refreshIntervalIndex: Int = 2 {
        didSet { saveRefreshInterval(); restartTimer() }
    }
    @Published var apiKeyInput: String = ""
    
    @Published var apiKeys: [String] = []
    @Published var activeKeyIndex: Int = 0
    
    @Published var manualCredits: String = ""
    @Published var manualOffset: String = ""
    
    private var refreshTimer: Timer?
    private var _apiKey: String = ""
    private let defaults = UserDefaults.standard
    private let refreshKey = "refreshIntervalIndex"
    private let apiKeyKey = "openrouter_api_key"
    private let apiKeysKey = "openrouter_api_keys"
    private let activeKeyKey = "openrouter_active_key_index"
    private let manualCreditsKey = "openrouter_manual_credits"
    private let manualOffsetKey = "openrouter_manual_offset"

    init() {
        refreshIntervalIndex = loadRefreshInterval()
        loadAllKeys()
    }

    var currentApiKey: String { _apiKey }

    private func loadAllKeys() {
        if let keys = defaults.array(forKey: apiKeysKey) as? [String], !keys.isEmpty {
            apiKeys = keys
        } else {
            let singleKey = loadSingleKey()
            if !singleKey.isEmpty {
                apiKeys = [singleKey]
                defaults.set(apiKeys, forKey: apiKeysKey)
            }
        }
        
        activeKeyIndex = defaults.integer(forKey: activeKeyKey)
        if activeKeyIndex >= apiKeys.count { activeKeyIndex = 0 }
        
        if !apiKeys.isEmpty {
            _apiKey = apiKeys[activeKeyIndex]
            apiKeyInput = _apiKey
        }
        
        manualCredits = defaults.string(forKey: manualCreditsKey) ?? ""
        manualOffset = defaults.string(forKey: manualOffsetKey) ?? ""
    }
    
    private func loadSingleKey() -> String {
        if let saved = defaults.string(forKey: apiKeyKey), !saved.isEmpty {
            return saved
        }
        let keyFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openrouter_api_key")
        if let key = try? String(contentsOf: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        return ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? ""
    }
    
    func addKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !apiKeys.contains(trimmed) else { return }
        apiKeys.append(trimmed)
        defaults.set(apiKeys, forKey: apiKeysKey)
        if apiKeys.count == 1 {
            _apiKey = trimmed
            apiKeyInput = trimmed
            activeKeyIndex = 0
            defaults.set(0, forKey: activeKeyKey)
            fetchAll()
        }
    }
    
    func removeKey(at index: Int) {
        guard index < apiKeys.count else { return }
        apiKeys.remove(at: index)
        defaults.set(apiKeys, forKey: apiKeysKey)
        if apiKeys.isEmpty {
            _apiKey = ""
            apiKeyInput = ""
            activeKeyIndex = 0
            keyBalances = []
            info = nil
        } else {
            if activeKeyIndex >= apiKeys.count { activeKeyIndex = 0 }
            _apiKey = apiKeys[activeKeyIndex]
            apiKeyInput = _apiKey
        }
        defaults.set(activeKeyIndex, forKey: activeKeyKey)
        fetchAll()
    }
    
    func selectKey(at index: Int) {
        guard index < apiKeys.count else { return }
        activeKeyIndex = index
        _apiKey = apiKeys[index]
        apiKeyInput = _apiKey
        defaults.set(index, forKey: activeKeyKey)
        fetchAll()
    }
    
    func saveManualBalance() {
        let credits = Double(manualCredits) ?? 0
        let offset = Double(manualOffset) ?? 0
        defaults.set(manualCredits, forKey: manualCreditsKey)
        defaults.set(manualOffset, forKey: manualOffsetKey)
        
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/openrouter")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data: [String: Any] = ["total_credits": credits, "manual_offset": offset, "last_updated": ISO8601DateFormatter().string(from: Date())]
        if let jsonData = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted) {
            try? jsonData.write(to: dir.appendingPathComponent("manual_balance.json"))
        }
        
        if credits > 0, let info = self.info {
            accountBalance = credits - info.usage + offset
        }
    }

    // MARK: - Fetch (All Keys)
    
    func fetchAll() {
        isLoading = true
        errorMsg = nil
        keyBalances = []
        totalLimit = 0
        totalUsage = 0
        
        let group = DispatchGroup()
        var results: [(Int, KeyBalance)] = []
        
        for (i, key) in apiKeys.enumerated() {
            group.enter()
            fetchKeyBalance(index: i, key: key) { result in
                if let r = result { results.append((i, r)) }
                group.leave()
            }
        }
        
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.isLoading = false
            results.sort { $0.0 < $1.0 }
            self.keyBalances = results.map { $0.1 }
            self.totalLimit = self.keyBalances.reduce(0) { $0 + $1.limit }
            self.totalUsage = self.keyBalances.reduce(0) { $0 + $1.usage }
            
            // 첫 번째 키로 전체 정보 설정
            if let first = self.keyBalances.first {
                self.info = BalanceInfo(
                    limit: self.totalLimit,
                    limitRemaining: self.keyBalances.reduce(0) { $0 + $1.limitRemaining },
                    usage: self.totalUsage,
                    usageDaily: 0,
                    usageWeekly: 0,
                    usageMonthly: self.keyBalances.reduce(0) { $0 + $1.usageMonthly },
                    isFreeTier: false,
                    limitReset: first.limitReset
                )
            }
            self.fetchCreditsBalance()
        }
        
        if apiKeys.isEmpty {
            isLoading = false
            errorMsg = "No API keys"
        }
    }
    
    func fetch() { fetchAll() }
    
    private func fetchKeyBalance(index: Int, key: String, completion: @escaping (KeyBalance?) -> Void) {
        guard let url = URL(string: "https://openrouter.ai/api/v1/auth/key") else {
            completion(nil); return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let d = json["data"] as? [String: Any] else {
                completion(nil); return
            }
            let kb = KeyBalance(
                index: index,
                label: "...\(key.suffix(6))",
                limit: d["limit"] as? Double ?? 0,
                limitRemaining: d["limit_remaining"] as? Double ?? 0,
                usage: d["usage"] as? Double ?? 0,
                usageMonthly: d["usage_monthly"] as? Double ?? 0,
                limitReset: d["limit_reset"] as? String ?? "unknown"
            )
            completion(kb)
        }.resume()
    }

    func fetchCreditsBalance() {
        guard !apiKeys.isEmpty, let url = URL(string: "https://openrouter.ai/api/v1/credits") else { return }
        let key = apiKeys[activeKeyIndex]
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let d = json["data"] as? [String: Any] {
                    let credits = d["total_credits"] as? Double ?? 0
                    let usage = d["total_usage"] as? Double ?? 0
                    if credits > 0 {
                        self?.accountBalance = credits - usage
                    } else {
                        self?.loadManualBalance()
                    }
                } else {
                    self?.loadManualBalance()
                }
            }
        }.resume()
    }
    
    func loadManualBalance() {
        let credits = Double(manualCredits) ?? 0
        let offset = Double(manualOffset) ?? 0
        if credits > 0, let info = self.info {
            accountBalance = credits - info.usage + offset
        } else {
            let file = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/openrouter/manual_balance.json")
            if let data = try? Data(contentsOf: file),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let fileCredits = json["total_credits"] as? Double ?? 0
                let fileOffset = json["manual_offset"] as? Double ?? 0
                if fileCredits > 0, let info = self.info {
                    accountBalance = fileCredits - info.usage + fileOffset
                }
            }
        }
    }

    func startAutoRefresh() {
        let interval = refreshIntervals[refreshIntervalIndex].1
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.fetchAll()
        }
    }

    func restartTimer() { stopAutoRefresh(); startAutoRefresh() }
    func stopAutoRefresh() { refreshTimer?.invalidate(); refreshTimer = nil }

    var refreshIntervalLabel: String { refreshIntervals[refreshIntervalIndex].0 }

    func saveApiKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        _apiKey = key
        defaults.set(key, forKey: apiKeyKey)
        if !apiKeys.contains(key) {
            apiKeys.append(key)
            defaults.set(apiKeys, forKey: apiKeysKey)
        }
        fetchAll()
    }

    private func saveRefreshInterval() { defaults.set(refreshIntervalIndex, forKey: refreshKey) }
    private func loadRefreshInterval() -> Int {
        let saved = defaults.integer(forKey: refreshKey)
        return (saved >= 0 && saved < refreshIntervals.count) ? saved : 2
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var vm = BalanceVM()
    var popover: NSPopover!
    var cancellables = Set<AnyCancellable>()
    var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 300, height: 700)
        popover.contentViewController = NSHostingController(rootView: PopoverView(vm: vm))
        self.popover = popover

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "💳⏳"
        let button = statusItem.button!
        button.action = #selector(statusBarButtonClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        vm.fetchAll()
        vm.startAutoRefresh()

        vm.$info.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateTitle() }.store(in: &cancellables)
        vm.$accountBalance.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateTitle() }.store(in: &cancellables)
    }

    func updateTitle() {
        let acct = String(format: "%.2f", vm.accountBalance)
        statusItem.button?.title = "💳\(acct)"
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
            removeEventMonitor()
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            addEventMonitor()
        }
    }
    
    func addEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self = self, self.popover.isShown {
                self.popover.performClose(nil)
                self.removeEventMonitor()
            }
        }
    }
    
    func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    @objc func forceRefresh() { vm.fetchAll() }
    @objc func quitApp() { vm.stopAutoRefresh(); NSApp.terminate(nil) }
}

// MARK: - Popover View

struct PopoverView: View {
    @ObservedObject var vm: BalanceVM
    @State private var newKeyInput: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if vm.isLoading && vm.info == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let err = vm.errorMsg, vm.info == nil {
                    Text("Error: \(err)").foregroundColor(.red).font(.body)
                    Text("Add an API key below").foregroundColor(.secondary)
                } else if vm.info != nil {
                    // Account balance
                    HStack {
                        Image(systemName: "dollarsign.circle.fill").foregroundColor(.green).font(.title3)
                        Text("Account").fontWeight(.bold).font(.title3)
                    }
                    Text("$\(String(format: "%.2f", vm.accountBalance))")
                        .font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundColor(.green)
                    Text("(Account Balance)").font(.callout).foregroundColor(.gray)

                    HStack {
                        Text("Total Limit: $\(String(format: "%.2f", vm.totalLimit))").font(.callout).foregroundColor(.gray)
                        Spacer()
                        Text("Total Used: $\(String(format: "%.4f", vm.totalUsage))").font(.callout).foregroundColor(.gray)
                    }
                    ProgressView(value: vm.totalLimit > 0 ? max(0, vm.accountBalance / vm.totalLimit) : 0).tint(.green)

                    Divider()

                    // Per-key limits
                    HStack {
                        Image(systemName: "key.fill").foregroundColor(.blue)
                        Text("API Keys (\(vm.apiKeys.count))").fontWeight(.semibold).font(.callout)
                    }

                    ForEach(vm.keyBalances, id: \.index) { kb in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: kb.index == vm.activeKeyIndex ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(kb.index == vm.activeKeyIndex ? .green : .gray).font(.caption)
                                Text("Key \(kb.index + 1): \(kb.label)").font(.system(.caption, design: .monospaced))
                                Spacer()
                                Button(action: { vm.selectKey(at: kb.index) }) {
                                    Image(systemName: "arrow.right.circle").font(.caption)
                                }.buttonStyle(.borderless)
                                Button(action: { vm.removeKey(at: kb.index) }) {
                                    Image(systemName: "trash").font(.caption).foregroundColor(.red)
                                }.buttonStyle(.borderless)
                            }
                            HStack {
                                Text("$\(String(format: "%.2f", kb.limitRemaining)) / $\(String(format: "%.2f", kb.limit))").font(.caption2).foregroundColor(.secondary)
                                Spacer()
                                Text("Used: $\(String(format: "%.4f", kb.usage))").font(.caption2).foregroundColor(.secondary)
                            }
                            ProgressView(value: kb.limit > 0 ? kb.limitRemaining / kb.limit : 0).tint(.blue).scaleEffect(y: 0.7)
                        }
                        .padding(.vertical, 2)
                    }

                    // Add key
                    HStack {
                        SecureField("Add API Key...", text: $newKeyInput)
                            .font(.callout).textFieldStyle(.roundedBorder)
                            .onSubmit {
                                let key = newKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !key.isEmpty { vm.addKey(key); newKeyInput = "" }
                            }
                        Button("Add") {
                            let key = newKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !key.isEmpty { vm.addKey(key); newKeyInput = "" }
                        }.font(.callout).buttonStyle(.borderless)
                    }

                    Divider()

                    // Manual balance override
                    HStack {
                        Image(systemName: "pencil.circle").foregroundColor(.orange)
                        Text("Manual Override").fontWeight(.semibold).font(.callout)
                    }
                    HStack {
                        Text("Credits:").font(.callout)
                        TextField("15.00", text: $vm.manualCredits).font(.callout).textFieldStyle(.roundedBorder).frame(width: 80)
                    }
                    HStack {
                        Text("Offset:").font(.callout)
                        TextField("0.00", text: $vm.manualOffset).font(.callout).textFieldStyle(.roundedBorder).frame(width: 80)
                        Button("Apply") { vm.saveManualBalance() }.font(.callout).buttonStyle(.borderless)
                    }

                    Divider()

                    // Usage
                    if let info = vm.info {
                        HStack {
                            Image(systemName: "chart.bar").foregroundColor(.orange)
                            Text("Usage").fontWeight(.semibold).font(.callout)
                        }
                        HStack { Text("Monthly").font(.callout).foregroundColor(.secondary); Spacer(); Text("$\(String(format: "%.4f", info.usageMonthly))").monospacedDigit().font(.callout) }
                        Text("Reset: \(info.limitReset)").font(.callout).foregroundColor(.gray)
                    }

                    Divider()

                    // Refresh interval
                    HStack {
                        Image(systemName: "clock").foregroundColor(.secondary)
                        Text("Auto-refresh").fontWeight(.semibold).font(.callout)
                    }
                    Picker("", selection: $vm.refreshIntervalIndex) {
                        ForEach(0..<refreshIntervals.count, id: \.self) { i in
                            Text(refreshIntervals[i].0).tag(i)
                        }
                    }.pickerStyle(.menu).font(.callout)
                }

                Button { vm.fetchAll() } label: {
                    HStack { Image(systemName: "arrow.clockwise"); Text("Refresh") }
                }.buttonStyle(.borderless).padding(.vertical, 4)
            }
            .padding()
        }
        .frame(width: 280)
    }
}

@main
struct OpenRouterBalanceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}
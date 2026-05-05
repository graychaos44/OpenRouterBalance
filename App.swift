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

class BalanceVM: ObservableObject {
    @Published var info: BalanceInfo?
    @Published var isLoading = false
    @Published var errorMsg: String?
    @Published var accountBalance: Double = 10.0
    private let totalCredit: Double = 10.0
    private var refreshTimer: Timer?
    private let apiKey: String = OpenRouterBalanceApp.loadApiKey()

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
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
                // Manual JSON parsing to avoid Codable issues
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
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }
    
    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
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
        popover.contentSize = NSSize(width: 280, height: 500)
        popover.contentViewController = NSHostingController(rootView: PopoverView(vm: vm))
        self.popover = popover

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "💳⏳"
        let button = statusItem.button!
        button.action = #selector(togglePopover)
        button.target = self

        // Right-click menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Refresh Now", action: #selector(forceRefresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        // Use right-click menu via button menu, not statusItem.menu
        button.menu = menu
        button.sendAction(on: .leftMouseUp)

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

                Text("Auto-refresh: 5min")
                        .font(.callout)
                        .foregroundColor(.secondary)
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
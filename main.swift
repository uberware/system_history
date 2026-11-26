import Cocoa
import IOKit

// MARK: - Sampling

final class Sampler {
    private var prevTicks: (UInt32, UInt32, UInt32, UInt32)?

    /// Returns (user, system) as fractions 0...1 of total CPU since the previous call.
    func cpu() -> (user: Double, system: Double) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        let t = info.cpu_ticks // USER, SYSTEM, IDLE, NICE
        defer { prevTicks = t }
        guard let p = prevTicks else { return (0, 0) }
        let user = Double(t.0 &- p.0) + Double(t.3 &- p.3)
        let sys = Double(t.1 &- p.1)
        let idle = Double(t.2 &- p.2)
        let total = user + sys + idle
        guard total > 0 else { return (0, 0) }
        return (user / total, sys / total)
    }

    /// GPU "Device Utilization %" from the IOAccelerator registry entry, as 0...1.
    func gpu() -> Double {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iter) }
        var best = 0.0
        while true {
            let entry = IOIteratorNext(iter)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            guard let prop = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let stats = prop as? [String: Any],
                  let util = stats["Device Utilization %"] as? NSNumber else { continue }
            best = max(best, util.doubleValue)
        }
        return min(best, 100) / 100
    }

    let totalMemory = Double(ProcessInfo.processInfo.physicalMemory)

    /// Memory in bytes: app memory, wired, compressed (Activity Monitor's "Memory Used" = sum).
    func memory() -> (app: Double, wired: Double, compressed: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0, 0) }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = Double(pageSize)
        let app = max(0, Double(stats.internal_page_count) - Double(stats.purgeable_count)) * page
        let wired = Double(stats.wire_count) * page
        let compressed = Double(stats.compressor_page_count) * page
        return (app, wired, compressed)
    }
}

// MARK: - Graph

final class GraphView: NSView {
    let title: String
    let colors: [NSColor]
    let capacity: Int
    private var samples: [[Double]] = []   // each sample: stacked layers, fractions 0...1
    private var valueText = ""

    init(title: String, colors: [NSColor], capacity: Int) {
        self.title = title
        self.colors = colors
        self.capacity = capacity
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { true }

    func push(_ layers: [Double], text: String) {
        samples.append(layers)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        valueText = text
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.04, alpha: 1).setFill()
        bounds.fill()

        // Grid
        let grid = NSBezierPath()
        for i in 1..<4 {
            let y = (bounds.height * CGFloat(i) / 4).rounded() + 0.5
            grid.move(to: NSPoint(x: 0, y: y)); grid.line(to: NSPoint(x: bounds.width, y: y))
        }
        NSColor(white: 1, alpha: 0.08).setStroke()
        grid.lineWidth = 1
        grid.stroke()

        // Bars, newest at the right edge
        let colW = bounds.width / CGFloat(capacity)
        let start = capacity - samples.count
        for (i, layers) in samples.enumerated() {
            let x0 = (CGFloat(start + i) * colW).rounded(.down)
            let x1 = (CGFloat(start + i + 1) * colW).rounded(.down)
            var y: CGFloat = 0
            for (j, v) in layers.enumerated() {
                let h = CGFloat(max(0, min(1, v))) * bounds.height
                colors[j % colors.count].setFill()
                NSRect(x: x0, y: y, width: max(1, x1 - x0), height: h).fill()
                y += h
            }
        }

        // Label
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(white: 0.75, alpha: 1),
            .shadow: shadow,
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
            .shadow: shadow,
        ]
        let label = NSMutableAttributedString(string: title + "  ", attributes: titleAttrs)
        label.append(NSAttributedString(string: valueText, attributes: valueAttrs))
        label.draw(at: NSPoint(x: 6, y: bounds.height - 17))
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let sampler = Sampler()
    let historySeconds = 180

    var panel: NSPanel!
    var statusItem: NSStatusItem!
    var cpuGraph: GraphView!
    var gpuGraph: GraphView!
    var memGraph: GraphView!
    var timer: Timer?

    let defaults = UserDefaults.standard
    var keepOnTop: Bool {
        get { defaults.object(forKey: "keepOnTop") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keepOnTop"); applyLevel() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        cpuGraph = GraphView(title: "CPU", colors: [.systemGreen, .systemRed], capacity: historySeconds)
        gpuGraph = GraphView(title: "GPU", colors: [.systemCyan], capacity: historySeconds)
        memGraph = GraphView(title: "Memory", colors: [.systemBlue, .systemOrange, .systemYellow], capacity: historySeconds)

        let stack = NSStackView(views: [cpuGraph, gpuGraph, memGraph])
        stack.orientation = .vertical
        stack.distribution = .fillEqually
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.title = "System History"
        panel.contentView = container
        panel.contentMinSize = NSSize(width: 180, height: 150)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if !panel.setFrameUsingName("SystemHistoryPanel") {
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: f.maxX - 380, y: f.minY + 20))
            }
        }
        panel.setFrameAutosaveName("SystemHistoryPanel")
        applyLevel()
        panel.orderFrontRegardless()

        setupStatusItem()

        _ = sampler.cpu() // prime the CPU delta
        tick()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func applyLevel() {
        panel?.level = keepOnTop ? .floating : .normal
    }

    func tick() {
        let c = sampler.cpu()
        cpuGraph.push([c.user, c.system], text: String(format: "%.0f%%", (c.user + c.system) * 100))

        let g = sampler.gpu()
        gpuGraph.push([g], text: String(format: "%.0f%%", g * 100))

        let m = sampler.memory()
        let total = sampler.totalMemory
        let used = m.app + m.wired + m.compressed
        let gb = 1024.0 * 1024 * 1024
        memGraph.push([m.app / total, m.wired / total, m.compressed / total],
                      text: String(format: "%.1f / %.0f GB", used / gb, total / gb))
    }

    // MARK: Menu bar

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: "System History")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let toggle = NSMenuItem(title: panel.isVisible ? "Hide Graphs" : "Show Graphs", action: #selector(toggleWindow), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let onTop = NSMenuItem(title: "Keep on Top", action: #selector(toggleOnTop), keyEquivalent: "")
        onTop.target = self
        onTop.state = keepOnTop ? .on : .off
        menu.addItem(onTop)

        menu.addItem(.separator())
        menu.addItem(legendItem("CPU: green = user, red = system"))
        menu.addItem(legendItem("Memory: blue = app, orange = wired, yellow = compressed"))
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit System History", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func legendItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc func toggleWindow() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    @objc func toggleOnTop() {
        keepOnTop.toggle()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

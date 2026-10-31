import Cocoa
import FlutterMacOS
import Carbon

@main
class AppDelegate: FlutterAppDelegate {
  private var statusItem: NSStatusItem?
  private var menuBarChannel: FlutterMethodChannel?
  private var deepLinkChannel: FlutterMethodChannel?
  private var pendingDeepLink: String?
  private var hotKeyRef: EventHotKeyRef?
  private var currentDisplayMode: String = "full"

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    let controller = mainFlutterWindow?.contentViewController as? FlutterViewController
    if let messenger = controller?.engine.binaryMessenger {
      setupMethodChannels(messenger: messenger)
    }

    setupStatusItem()
    setupGlobalHotKey()

    super.applicationDidFinishLaunching(notification)
  }

  private func setupMethodChannels(messenger: FlutterBinaryMessenger) {
    let menuChannel = FlutterMethodChannel(name: "com.tempo.tracker/menubar", binaryMessenger: messenger)
    menuChannel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "updateStatusItem":
        if let args = call.arguments as? [String: Any],
           let title = args["title"] as? String {
          let isTracking = args["isTracking"] as? Bool ?? false
          self.updateStatusItem(title: title, isTracking: isTracking)
          result(nil)
        } else {
          result(FlutterError(code: "INVALID_ARGUMENTS", message: "title is required", details: nil))
        }
      case "setStatusDisplayMode":
        if let args = call.arguments as? [String: Any],
           let mode = args["mode"] as? String {
          self.currentDisplayMode = mode.lowercased()
          result(nil)
        } else {
          result(FlutterError(code: "INVALID_ARGUMENTS", message: "mode is required", details: nil))
        }
      case "toggleWindow":
        self.toggleWindow()
        result(nil)
      case "closeWindow":
        self.closeWindow()
        result(nil)
      case "openFullWindow":
        self.openFullWindow()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.menuBarChannel = menuChannel

    let linkChannel = FlutterMethodChannel(name: "com.tempo.tracker/deeplink", binaryMessenger: messenger)
    linkChannel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "getInitialDeepLink":
        let link = self.pendingDeepLink
        self.pendingDeepLink = nil
        result(link)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.deepLinkChannel = linkChannel

    if let pending = pendingDeepLink {
      linkChannel.invokeMethod("onDeepLinkReceived", arguments: ["url": pending])
      pendingDeepLink = nil
    }
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      let urlString = url.absoluteString
      if let channel = deepLinkChannel {
        channel.invokeMethod("onDeepLinkReceived", arguments: ["url": urlString])
      } else {
        pendingDeepLink = urlString
      }
    }
  }

  private func setupStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = statusItem?.button {
      button.title = "⏱️"
      button.target = self
      button.action = #selector(statusItemClicked(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
  }

  private func updateStatusItem(title: String, isTracking: Bool) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, let button = self.statusItem?.button else { return }
      button.title = title
    }
  }

  @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
    let event = NSApp.currentEvent
    if event?.type == .rightMouseUp {
      showContextMenu()
    } else {
      toggleWindow()
    }
  }

  private func showContextMenu() {
    let menu = NSMenu()
    let toggleItem = NSMenuItem(title: "Toggle Timer", action: #selector(menuToggleTimer), keyEquivalent: "t")
    toggleItem.target = self
    menu.addItem(toggleItem)

    let openItem = NSMenuItem(title: "Open Full Window", action: #selector(menuOpenFullWindow), keyEquivalent: "o")
    openItem.target = self
    menu.addItem(openItem)

    menu.addItem(NSMenuItem.separator())

    let quitItem = NSMenuItem(title: "Quit Tempo", action: #selector(menuQuit), keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)

    statusItem?.popUpMenu(menu)
  }

  @objc private func menuToggleTimer() {
    menuBarChannel?.invokeMethod("onQuickMenuAction", arguments: ["action": "toggle"])
  }

  @objc private func menuOpenFullWindow() {
    openFullWindow()
    menuBarChannel?.invokeMethod("onQuickMenuAction", arguments: ["action": "openFullWindow"])
  }

  @objc private func menuQuit() {
    NSApp.terminate(nil)
  }

  func toggleWindow() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, let window = self.mainFlutterWindow else { return }
      if window.isVisible && window.isKeyWindow {
        window.orderOut(nil)
      } else {
        self.positionWindowUnderStatusItem()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
      }
    }
  }

  func closeWindow() {
    DispatchQueue.main.async { [weak self] in
      self?.mainFlutterWindow?.orderOut(nil)
    }
  }

  func openFullWindow() {
    DispatchQueue.main.async { [weak self] in
      guard let window = self?.mainFlutterWindow else { return }
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  private func positionWindowUnderStatusItem() {
    guard let window = mainFlutterWindow,
          let button = statusItem?.button,
          let buttonWindow = button.window else { return }

    let buttonRectOnScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    let windowSize = window.frame.size
    var x = buttonRectOnScreen.midX - (windowSize.width / 2.0)
    let y = buttonRectOnScreen.minY - windowSize.height - 4.0

    let screen = buttonWindow.screen ?? NSScreen.main
    if let screenFrame = screen?.visibleFrame {
      if x < screenFrame.minX {
        x = screenFrame.minX
      } else if x + windowSize.width > screenFrame.maxX {
        x = screenFrame.maxX - windowSize.width
      }
    }

    window.setFrameOrigin(NSPoint(x: x, y: y))
  }

  private func setupGlobalHotKey() {
    var hotKeyID = EventHotKeyID()
    hotKeyID.signature = OSType(0x544D504F) // 'TMPO'
    hotKeyID.id = 1

    var eventType = EventTypeSpec()
    eventType.eventClass = OSType(kEventClassKeyboard)
    eventType.eventKind = OSType(kEventHotKeyPressed)

    InstallEventHandler(GetApplicationEventTarget(), { (_, _, _) -> OSStatus in
      DispatchQueue.main.async {
        if let delegate = NSApp.delegate as? AppDelegate {
          delegate.toggleWindow()
        }
      }
      return noErr
    }, 1, &eventType, nil, nil)

    let modifiers = UInt32(optionKey | shiftKey)
    // kVK_ANSI_T is key code 17 (0x11)
    RegisterEventHotKey(UInt32(kVK_ANSI_T), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
  }
}

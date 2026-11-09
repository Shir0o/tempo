import Cocoa
import FlutterMacOS
import Carbon
import Security

@main
class AppDelegate: FlutterAppDelegate {
  private var statusItem: NSStatusItem?
  private var menuBarChannel: FlutterMethodChannel?
  private var deepLinkChannel: FlutterMethodChannel?
  private var backupDestinationChannel: FlutterMethodChannel?
  private var pairingSecretsChannel: FlutterMethodChannel?
  private var pendingDeepLink: String?
  private var hotKeyRef: EventHotKeyRef?
  private var currentDisplayMode: String = "full"

  /// The Keychain service every pairing secret is written under. Secrets are
  /// never in `tempo.db`, so a snapshot never carries a credential. There is
  /// no access group: the app's own Keychain is the boundary.
  private static let pairingService = "com.tempos.tracker.pairing"

  /// Security-scoped URLs the app is allowed to write to, keyed by the base64
  /// bookmark that granted access. A sandboxed app loses access on relaunch, so
  /// the bookmark in the backup destination setting is what restores it.
  private var scopedURLs: [String: URL] = [:]

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
    let menuChannel = FlutterMethodChannel(name: "com.tempos.tracker/menubar", binaryMessenger: messenger)
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

    let linkChannel = FlutterMethodChannel(name: "com.tempos.tracker/deeplink", binaryMessenger: messenger)
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

    // Backup destination picking and security-scoped bookmark resolution. The
    // phone scans the pairing code in Flutter; nothing is handled here.
    let backupChannel = FlutterMethodChannel(
      name: "com.tempos.tracker/backup_destination",
      binaryMessenger: messenger
    )
    backupChannel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "pickDirectory":
        self.pickBackupDirectory(result: result)
      case "resolveBookmark":
        if let args = call.arguments as? [String: Any],
           let bookmark = args["bookmark"] as? String {
          if let path = self.resolveBookmark(bookmark) {
            result(["path": path])
          } else {
            result(nil)
          }
        } else {
          result(FlutterError(code: "INVALID_ARGUMENTS", message: "bookmark is required", details: nil))
        }
      case "releaseBookmark":
        if let args = call.arguments as? [String: Any],
           let bookmark = args["bookmark"] as? String {
          self.scopedURLs.removeValue(forKey: bookmark)?.stopAccessingSecurityScopedResource()
          result(nil)
        } else {
          result(FlutterError(code: "INVALID_ARGUMENTS", message: "bookmark is required", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.backupDestinationChannel = backupChannel

    // Pairing secrets: 256-bit secrets in the login Keychain, keyed by the
    // peer or invite key the Dart side chooses.
    let pairingChannel = FlutterMethodChannel(
      name: "tempo/pairing_secrets",
      binaryMessenger: messenger
    )
    pairingChannel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "read":
        if let key = AppDelegate.pairingKey(call) {
          result(self.readPairingSecret(key))
        } else {
          result(FlutterError(code: "INVALID_ARGUMENTS", message: "key is required", details: nil))
        }
      case "write":
        if let key = AppDelegate.pairingKey(call),
           let value = (call.arguments as? [String: Any])?["value"] as? String {
          if let error = self.writePairingSecret(key, value: value) {
            result(error)
          } else {
            result(nil)
          }
        } else {
          result(FlutterError(code: "INVALID_ARGUMENTS", message: "key and value are required", details: nil))
        }
      case "delete":
        if let key = AppDelegate.pairingKey(call) {
          if let error = self.deletePairingSecret(key) {
            result(error)
          } else {
            result(nil)
          }
        } else {
          result(FlutterError(code: "INVALID_ARGUMENTS", message: "key is required", details: nil))
        }
      case "deleteAll":
        if let error = self.deleteAllPairingSecrets() {
          result(error)
        } else {
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.pairingSecretsChannel = pairingChannel

    if let pending = pendingDeepLink {
      linkChannel.invokeMethod("onDeepLinkReceived", arguments: ["url": pending])
      pendingDeepLink = nil
    }
  }

  /// Shows the folder picker and returns `{path, bookmark}` so the destination
  /// survives a relaunch. Returns nil when the user cancels.
  private func pickBackupDirectory(result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose"
    panel.message = "Choose the folder Tempo keeps verified backups in."

    let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard response == .OK, let url = panel.url else {
        result(nil)
        return
      }
      _ = url.startAccessingSecurityScopedResource()
      var bookmark: Any = NSNull()
      do {
        let data = try url.bookmarkData(
          options: .withSecurityScope,
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        )
        let encoded = data.base64EncodedString()
        self?.scopedURLs[encoded] = url
        bookmark = encoded
      } catch {
        // Without a bookmark the folder is usable for this session only; the
        // Dart side shows the destination as unreachable after a relaunch.
        NSLog("Tempo: could not create a security-scoped bookmark: \(error)")
      }
      result(["path": url.path, "bookmark": bookmark])
    }

    if let window = mainFlutterWindow {
      panel.beginSheetModal(for: window, completionHandler: complete)
    } else {
      complete(panel.runModal())
    }
  }

  /// Resolves a persisted bookmark and starts security-scoped access. Returns
  /// the folder path, or nil when the bookmark is stale or access is refused.
  private func resolveBookmark(_ encoded: String) -> String? {
    if let url = scopedURLs[encoded] {
      return url.path
    }
    guard let data = Data(base64Encoded: encoded) else { return nil }
    var isStale = false
    do {
      let url = try URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      guard url.startAccessingSecurityScopedResource() else { return nil }
      scopedURLs[encoded] = url
      return url.path
    } catch {
      NSLog("Tempo: could not resolve the backup destination bookmark: \(error)")
      return nil
    }
  }

  // MARK: - Pairing secrets (Keychain)

  /// The pairing key a call names, or nil when it is missing or empty.
  private static func pairingKey(_ call: FlutterMethodCall) -> String? {
    guard let key = (call.arguments as? [String: Any])?["key"] as? String,
          !key.isEmpty else { return nil }
    return key
  }

  /// The `kSecClassGenericPassword` query for one account, or for the whole
  /// service when [account] is nil.
  private func pairingQuery(account: String?) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: AppDelegate.pairingService,
    ]
    if let account = account {
      query[kSecAttrAccount as String] = account
    }
    return query
  }

  private func readPairingSecret(_ key: String) -> String? {
    var query = pairingQuery(account: key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private func writePairingSecret(_ key: String, value: String) -> FlutterError? {
    guard let data = value.data(using: .utf8) else {
      return FlutterError(code: "INVALID_ARGUMENTS", message: "value is not UTF-8", details: nil)
    }
    // One item per key: a rewrite replaces the secret rather than adding a
    // second candidate a lookup could return.
    _ = SecItemDelete(pairingQuery(account: key) as CFDictionary)
    var query = pairingQuery(account: key)
    query[kSecValueData as String] = data
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      return FlutterError(
        code: "KEYCHAIN_WRITE_FAILED",
        message: "the Keychain refused the write (\(status))",
        details: nil
      )
    }
    return nil
  }

  private func deletePairingSecret(_ key: String) -> FlutterError? {
    let status = SecItemDelete(pairingQuery(account: key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      return FlutterError(
        code: "KEYCHAIN_DELETE_FAILED",
        message: "the Keychain refused the delete (\(status))",
        details: nil
      )
    }
    return nil
  }

  /// "Revoke all paired devices": every secret under the service goes.
  private func deleteAllPairingSecrets() -> FlutterError? {
    let status = SecItemDelete(pairingQuery(account: nil) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      return FlutterError(
        code: "KEYCHAIN_DELETE_FAILED",
        message: "the Keychain refused the delete (\(status))",
        details: nil
      )
    }
    return nil
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
    let labelSameAsLastItem = NSMenuItem(title: "Label Same as Last", action: #selector(menuLabelSameAsLast), keyEquivalent: "t")
    labelSameAsLastItem.target = self
    menu.addItem(labelSameAsLastItem)

    let openItem = NSMenuItem(title: "Open Full Window", action: #selector(menuOpenFullWindow), keyEquivalent: "o")
    openItem.target = self
    menu.addItem(openItem)

    menu.addItem(NSMenuItem.separator())

    let quitItem = NSMenuItem(title: "Quit Tempo", action: #selector(menuQuit), keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)

    statusItem?.popUpMenu(menu)
  }

  @objc private func menuLabelSameAsLast() {
    menuBarChannel?.invokeMethod("onQuickMenuAction", arguments: ["action": "labelSameAsLast"])
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

import Cocoa
import FlutterMacOS
import AVFoundation
import SystemConfiguration

class MainFlutterWindow: NSWindow {
  private var hostChannel: FlutterMethodChannel?
  private var microphoneChannel: FlutterMethodChannel?
  private var deviceNameChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let channel = FlutterMethodChannel(
      name: "host.hoshino.fogshot/microphone",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "request" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.requestMicrophonePermission(result: result)
    }
    microphoneChannel = channel

    let deviceNameChannel = FlutterMethodChannel(
      name: "host.hoshino.fogshot/device_name",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    deviceNameChannel.setMethodCallHandler { call, result in
      guard call.method == "currentDeviceName" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(self.currentComputerName())
    }
    self.deviceNameChannel = deviceNameChannel

    let hostChannel = FlutterMethodChannel(
      name: "host.hoshino.fogshot/streamer",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    hostChannel.setMethodCallHandler { call, result in
      guard call.method == "launch" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let arguments = call.arguments as? [String: Any],
            let port = arguments["port"] as? Int, (1...65535).contains(port),
            let nonce = arguments["nonce"] as? String,
            nonce.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
        result(FlutterError(code: "invalid_ipc", message: nil, details: nil))
        return
      }
      let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/FogShot Host.app")
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.arguments = ["--fogshot-ipc", String(port)]
      configuration.environment = ["FOGSHOT_HOST_NONCE": nonce]
      configuration.activates = false
      configuration.addsToRecentItems = false
      configuration.createsNewApplicationInstance = true
      NSWorkspace.shared.openApplication(at: helper, configuration: configuration) { _, error in
        DispatchQueue.main.async {
          if let error = error {
            result(FlutterError(code: "launch_failed", message: error.localizedDescription, details: nil))
          } else {
            result(nil)
          }
        }
      }
    }
    self.hostChannel = hostChannel

    super.awakeFromNib()
  }

  private func currentComputerName() -> String {
    if let computerName = SCDynamicStoreCopyComputerName(nil, nil) {
      return computerName as String
    }
    return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
  }

  private func requestMicrophonePermission(result: @escaping FlutterResult) {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      result(true)
    case .denied, .restricted:
      result(false)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async {
          result(granted)
        }
      }
    @unknown default:
      result(false)
    }
  }
}

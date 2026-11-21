import Cocoa
import FlutterMacOS
import AVFoundation
import SystemConfiguration

class MainFlutterWindow: NSWindow {
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

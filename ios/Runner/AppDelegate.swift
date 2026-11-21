import Flutter
import UIKit
import AVFAudio

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var microphoneChannel: FlutterMethodChannel?
  private var deviceNameChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "host.hoshino.fogshot/microphone",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
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
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    deviceNameChannel.setMethodCallHandler { call, result in
      guard call.method == "currentDeviceName" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(UIDevice.current.name)
    }
    self.deviceNameChannel = deviceNameChannel
  }

  private func requestMicrophonePermission(result: @escaping FlutterResult) {
    let session = AVAudioSession.sharedInstance()
    switch session.recordPermission {
    case .granted:
      result(true)
    case .denied:
      result(false)
    case .undetermined:
      session.requestRecordPermission { granted in
        DispatchQueue.main.async {
          result(granted)
        }
      }
    @unknown default:
      result(false)
    }
  }
}

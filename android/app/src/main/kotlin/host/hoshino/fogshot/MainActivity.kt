package host.hoshino.fogshot

import android.Manifest
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var microphoneResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, microphoneChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != requestMethod) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                requestMicrophone(result)
            }
    }

    private fun requestMicrophone(result: MethodChannel.Result) {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        if (microphoneResult != null) {
            result.error("request_in_progress", "A microphone permission request is already active.", null)
            return
        }
        microphoneResult = result
        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), microphoneRequestCode)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != microphoneRequestCode) return
        microphoneResult?.success(
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED,
        )
        microphoneResult = null
    }

    companion object {
        private const val microphoneChannel = "host.hoshino.fogshot/microphone"
        private const val requestMethod = "request"
        private const val microphoneRequestCode = 0x4D49
    }
}

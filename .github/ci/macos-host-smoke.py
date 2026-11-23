import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys


LAUNCHER = r'''
import AppKit

let helper = URL(fileURLWithPath: CommandLine.arguments[1])
let configuration = NSWorkspace.OpenConfiguration()
configuration.arguments = ["--fogshot-ipc", CommandLine.arguments[2]]
configuration.environment = ["FOGSHOT_HOST_NONCE": ProcessInfo.processInfo.environment["FOGSHOT_HOST_NONCE"]!]
configuration.activates = false
configuration.addsToRecentItems = false
configuration.createsNewApplicationInstance = true
NSWorkspace.shared.openApplication(at: helper, configuration: configuration) { _, error in
    if let error = error {
        print(error.localizedDescription)
        exit(1)
    }
    exit(0)
}
RunLoop.main.run()
'''


def read_event(pipe):
    while True:
        line = pipe.readline(256 * 1024)
        if not line:
            return None
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            continue


def check_host_bundle(helper):
    nonce = secrets.token_hex(32)
    with socket.create_server(('127.0.0.1', 0), backlog=1) as listener:
        listener.settimeout(15)
        port = listener.getsockname()[1]
        environment = {**os.environ, 'FOGSHOT_HOST_NONCE': nonce}
        subprocess.run(['swift', '-e', LAUNCHER, str(helper), str(port)],
                       env=environment, check=True, timeout=50)
        connection, _ = listener.accept()
        with connection, connection.makefile('rwb') as pipe:
            connection.settimeout(20)
            hello = read_event(pipe)
            if hello != {'type': 'hello', 'nonce': nonce}:
                raise RuntimeError('The bundled helper failed the IPC handshake')
            for _ in range(20):
                event = read_event(pipe)
                if event and event.get('type') == 'state':
                    break
                if not event or event.get('type') == 'error':
                    raise RuntimeError('The bundled helper could not start')
            else:
                raise RuntimeError('The bundled helper did not report its state')
            if not event['system']['port']:
                raise RuntimeError('The bundled helper did not bind its stream socket')
            if not event['settings']['requireApproval'] or event['cloud']['allowRemote']:
                raise RuntimeError('The bundled helper did not start with private sharing defaults')
            pipe.write(b'{"type":"stop"}\n')
            pipe.flush()
            while read_event(pipe) is not None:
                pass
    print('FogShot Host started through Launch Services and closed on request.')


if __name__ == '__main__':
    check_host_bundle(Path(sys.argv[1]).resolve())

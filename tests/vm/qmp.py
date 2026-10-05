#!/usr/bin/env python3
"""Send one QMP command to a running QEMU and print the reply as JSON.

  qmp.py SOCKET COMMAND [JSON-ARGUMENTS]
  qmp.py run/qmp.sock screendump '{"filename": "/tmp/shot.png", "format": "png"}'
"""
import json
import socket
import sys

sock = socket.socket(socket.AF_UNIX)
sock.connect(sys.argv[1])
stream = sock.makefile("rw")
stream.readline()  # greeting


def call(command, arguments=None):
    message = {"execute": command}
    if arguments:
        message["arguments"] = arguments
    stream.write(json.dumps(message) + "\n")
    stream.flush()
    while True:
        reply = json.loads(stream.readline())
        if "event" not in reply:
            return reply


call("qmp_capabilities")
reply = call(sys.argv[2], json.loads(sys.argv[3]) if len(sys.argv) > 3 else None)
print(json.dumps(reply))
sys.exit(1 if "error" in reply else 0)

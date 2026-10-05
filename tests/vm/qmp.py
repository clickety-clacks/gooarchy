#!/usr/bin/env python3
"""Send one QMP command to a running QEMU and print the reply as JSON.

  qmp.py SOCKET COMMAND [JSON-ARGUMENTS]
  qmp.py run/qmp.sock screendump '{"filename": "/tmp/shot.png", "format": "png"}'

Gives up (exit 2) if QEMU doesn't answer within QMP_TIMEOUT seconds (default 20).
"""
import json
import os
import socket
import sys

sock = socket.socket(socket.AF_UNIX)
sock.settimeout(float(os.environ.get("QMP_TIMEOUT", "20")))
try:
    sock.connect(sys.argv[1])
    stream = sock.makefile("rw")

    def line():
        text = stream.readline()
        if not text:
            raise EOFError("QEMU closed the QMP connection")
        return json.loads(text)

    def call(command, arguments=None):
        message = {"execute": command}
        if arguments:
            message["arguments"] = arguments
        stream.write(json.dumps(message) + "\n")
        stream.flush()
        while True:
            reply = line()
            if "event" not in reply:
                return reply

    line()  # greeting
    call("qmp_capabilities")
    reply = call(sys.argv[2], json.loads(sys.argv[3]) if len(sys.argv) > 3 else None)
except (OSError, EOFError, ValueError) as error:
    print(json.dumps({"error": {"class": type(error).__name__, "desc": str(error)}}))
    sys.exit(2)
print(json.dumps(reply))
sys.exit(1 if "error" in reply else 0)

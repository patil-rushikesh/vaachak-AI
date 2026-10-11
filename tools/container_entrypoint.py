#!/usr/bin/env python3
"""Make a fresh mounted data directory writable, then drop container privileges."""

import os
from pathlib import Path
import pwd
import sys


def main():
    if os.getuid() == 0:
        user = pwd.getpwnam("vaachak")
        data = Path(os.environ.get("VAACHAK_DATA", "/data")).resolve()
        if data == Path("/") or data == Path("/app"):
            raise ValueError("VAACHAK_DATA must be a dedicated persistent data directory")
        data.mkdir(parents=True, exist_ok=True)
        # A new host disk may hide the directory ownership baked into the image.
        # Existing files are never recursively rewritten during deployment.
        os.chown(data, user.pw_uid, user.pw_gid)
        os.initgroups(user.pw_name, user.pw_gid)
        os.setgid(user.pw_gid)
        os.setuid(user.pw_uid)
    os.execvp(sys.argv[1], sys.argv[1:])


if __name__ == "__main__":
    main()

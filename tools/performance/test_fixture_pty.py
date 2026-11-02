import errno
import json
import os
from pathlib import Path
import pty
import select
import subprocess
import sys
import tempfile
import time
import unittest

import fixture


@unittest.skipUnless(sys.platform == "darwin", "Нужен macOS PTY")
class FixturePTYTests(unittest.TestCase):
    def test_output_echo_and_visual_frame_use_real_terminal(self):
        with tempfile.TemporaryDirectory(prefix="tavern-fixture-") as folder:
            control = Path(folder) / "control.json"

            def change(value):
                temporary = control.with_suffix(".tmp")
                temporary.write_text(json.dumps(value))
                temporary.replace(control)

            change({"epoch": 0, "rate": 0})
            master, slave = pty.openpty()
            process = subprocess.Popen([sys.executable, str(Path(fixture.__file__)), "--index", "7", "--control", str(control)],
                                       stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
            os.close(slave)
            data = bytearray()

            def await_bytes(wanted):
                deadline = time.monotonic() + 6
                while wanted not in data and time.monotonic() < deadline:
                    ready, _, _ = select.select([master], [], [], .05)
                    if ready:
                        try:
                            chunk = os.read(master, 8192)
                        except OSError as error:
                            if error.errno == errno.EIO:
                                break
                            raise
                        if not chunk:
                            break
                        data.extend(chunk)
                self.assertIn(wanted, data)

            try:
                await_bytes((fixture.marker(7) + " 000000:159").encode())
                os.write(master, "Проверка echo\r".encode())
                await_bytes((fixture.marker(7) + " ECHO:Проверка echo").encode())
                change({"epoch": 1, "rate": 4})
                await_bytes((fixture.marker(7) + " 000001:00").encode())
                change({"epoch": 2, "rate": 0, "control_frame": True})
                await_bytes((fixture.marker(7) + " CONTROL-FRAME").encode())
                self.assertIsNone(process.poll())
            finally:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
                os.close(master)
            self.assertEqual(process.returncode, 0)


if __name__ == "__main__":
    unittest.main()

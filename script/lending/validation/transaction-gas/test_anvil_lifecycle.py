"""Real socket/process regressions; separate from financial no-mock acceptance."""
import errno
import importlib.util
import pathlib
import socket
import subprocess
import sys
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location("lending_gas_runner", pathlib.Path(__file__).with_name("runner.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class AnvilLifecycleTest(unittest.TestCase):
    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux TIME_WAIT regression")
    def test_closed_owned_endpoint_is_available_despite_time_wait(self):
        with socket.socket() as listener:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
            listener.listen(1)
            with socket.create_connection(("127.0.0.1", port)) as client:
                accepted, _ = listener.accept()
                accepted.shutdown(socket.SHUT_WR)
                accepted.close()
                self.assertEqual(client.recv(1), b"")
        time.sleep(0.05)
        # Establish the original failure against actual kernel state.
        with socket.socket() as old_probe:
            with self.assertRaises(OSError) as error:
                old_probe.bind(("127.0.0.1", port))
            self.assertEqual(error.exception.errno, errno.EADDRINUSE)
        runner._require_port_available(port)

    def test_foreign_listener_is_rejected_and_remains_alive(self):
        with socket.socket() as foreign:
            if sys.platform != "win32":
                foreign.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            foreign.bind(("127.0.0.1", 0))
            foreign.listen(1)
            port = foreign.getsockname()[1]
            with self.assertRaises(OSError):
                runner._require_port_available(port)
            with socket.create_connection(("127.0.0.1", port)):
                accepted, _ = foreign.accept()
                accepted.close()

    @unittest.skipIf(sys.platform == "win32", "POSIX SIGTERM/kill regression")
    def test_force_killed_owned_child_is_reaped_before_handle_is_cleared(self):
        self.assertIsNone(runner._anvil_proc)
        child = subprocess.Popen(
            [sys.executable, "-c", "import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);print('ready',flush=True);time.sleep(60)"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, text=True,
        )
        log = tempfile.TemporaryFile()
        try:
            self.assertEqual(child.stdout.readline().strip(), "ready")
            runner._anvil_proc = child
            runner._anvil_log = log
            runner._kill_anvil()
            self.assertIsNotNone(child.poll())
            self.assertIsNone(runner._anvil_proc)
            self.assertTrue(log.closed)
        finally:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=8)
            child.stdout.close()
            log.close()
            runner._anvil_proc = None
            runner._anvil_log = None


if __name__ == "__main__":
    unittest.main()

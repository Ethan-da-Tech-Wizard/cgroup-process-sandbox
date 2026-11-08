import os, subprocess, sys, unittest
from pathlib import Path

RUNNER = Path(__file__).resolve().parent / "ethan_capped_run.sh"
SETUP = Path(__file__).resolve().parent / "ethan_memory_safety_setup.sh"


def capped(*command, cap="300M"):
    return subprocess.run([str(RUNNER), *command], capture_output=True, text=True, timeout=60,
                          env={**os.environ, "ETHAN_CAP": cap})


@unittest.skipIf(os.environ.get("ETHAN_CAPPED_INNER"), "these tests start the wrapper themselves, which cannot nest inside the wrapper's own namespace sandbox; "
                 "run them directly: cd scripts && python3 -B -m unittest test_ethan_capped_run")
@unittest.skipUnless(sys.platform.startswith("linux"), "Linux namespace/cgroup contract; Mac has test_ethan_mac_capped_run")
class CappedRunTests(unittest.TestCase):
    def test_runaway_is_killed_at_the_cap_and_nothing_else(self):
        result = capped(sys.executable, "-c", "x=[]\nwhile True: x.append(bytearray(50_000_000))")
        self.assertIn(result.returncode, (137, -9))  # SIGKILL, as a shell or as Python reports it

    def test_normal_command_runs_with_a_raised_oom_score_and_keeps_its_exit_code(self):
        ok = capped(sys.executable, "-c", "print(open('/proc/self/oom_score_adj').read().strip())")
        self.assertEqual((ok.returncode, ok.stdout.strip()), (0, "500"))
        self.assertEqual(capped(sys.executable, "-c", "raise SystemExit(7)").returncode, 7)

    def test_command_runs_in_its_own_pid_namespace_under_a_reaping_pid_one_by_default(self):
        # PID 1 of the namespace is the wrapper shell (it reaps orphans so no <defunct> storm builds up); the command is its child.
        result = capped(sys.executable, "-c", "import os; print(os.getpid(), os.getppid())")
        self.assertEqual(result.returncode, 0, result.stderr)
        pid, ppid = result.stdout.split()[:2]
        # pid is 2 + (helpers the wrapper ran first, e.g. `ip link set lo up` for loopback); what matters is parent == PID 1.
        self.assertEqual(ppid, "1")
        self.assertGreater(int(pid), 1)

    def test_orphaned_grandchildren_are_reaped_not_left_defunct(self):
        code = ("import subprocess,time\n"
                "for i in range(30): subprocess.Popen(['bash','-c','(sleep 0.05 &); exit 0']).wait()\n"
                "time.sleep(1)\n"
                "print(subprocess.run(\"ps -eo stat | grep -c '^Z'\", shell=True, capture_output=True, text=True).stdout.strip())")
        result = capped(sys.executable, "-c", code)
        self.assertEqual(result.stdout.strip(), "0", result.stderr)

    def test_broadcast_signal_cannot_reach_real_processes(self):
        # kill(-1, 0) is an existence probe of the broadcast target set; in the sandbox it has no host processes to find.
        code = "import os\ntry:\n    os.killpg(1, 0); print('reached')\nexcept ProcessLookupError:\n    print('none')"
        result = capped(sys.executable, "-c", code)
        self.assertEqual(result.stdout.strip(), "none", result.stderr)

    def test_host_mode_is_explicit_and_announced(self):
        result = subprocess.run([str(RUNNER), sys.executable, "-c", "import os; print(os.getpid() > 1)"], capture_output=True,
                                text=True, timeout=60, env={**os.environ, "ETHAN_HOST": "1", "ETHAN_CAP": "300M"})
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "True"))
        self.assertIn("ETHAN_HOST=1", result.stderr)

    def test_sandbox_home_is_not_the_real_home(self):
        result = capped(sys.executable, "-c", "import os; print(os.environ['HOME'])")
        self.assertTrue(result.stdout.strip().startswith("/tmp/ethan-sandbox-home."), result.stdout)

    def test_only_the_configured_number_of_runs_execute_at_once(self):
        import tempfile, time
        slots = tempfile.mkdtemp()
        env = {**os.environ, "ETHAN_SLOTS": "1", "ETHAN_SLOT_WAIT": "60", "ETHAN_SLOT_DIR": slots}
        first = subprocess.Popen([str(RUNNER), "sleep", "6"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(2)
        t0 = time.time()
        second = subprocess.run([str(RUNNER), sys.executable, "-c", "print('ran')"], env=env, capture_output=True, text=True, timeout=60)
        waited = time.time() - t0
        first.wait()
        self.assertEqual((second.returncode, second.stdout.strip()), (0, "ran"), second.stderr)
        self.assertGreaterEqual(waited, 3, "the second run must wait for the first slot to free")

    def test_slots_can_be_switched_off(self):
        env = {"ETHAN_SLOTS": "0"}
        result = subprocess.run([str(RUNNER), sys.executable, "-c", "print('ok')"], capture_output=True, text=True, timeout=60,
                                env={**os.environ, **env})
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "ok"), result.stderr)

    def test_unwritable_slot_dir_falls_back_to_tmp_instead_of_hanging(self):
        env = {**os.environ, "ETHAN_SLOT_DIR": "/proc/nonexistent-slot-dir", "ETHAN_SLOT_WAIT": "10"}
        result = subprocess.run([str(RUNNER), sys.executable, "-c", "print('fallback-ok')"], capture_output=True, text=True, timeout=15, env=env)
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "fallback-ok"), result.stderr)
        self.assertNotIn("all 2 run slots busy", result.stderr)

    def test_stderr_of_the_command_is_not_swallowed(self):
        result = capped(sys.executable, "-c", "import sys; sys.stderr.write('boom-on-stderr')")
        self.assertIn("boom-on-stderr", result.stderr)

    def test_runner_requires_a_command(self):
        self.assertEqual(subprocess.run([str(RUNNER)], capture_output=True).returncode, 2)

    def test_setup_script_is_valid_and_its_preview_changes_nothing(self):
        self.assertEqual(subprocess.run(["bash", "-n", str(SETUP)]).returncode, 0)
        before = Path("/etc/fstab").read_bytes()
        preview = subprocess.run(["bash", str(SETUP), "--check"], capture_output=True, text=True, timeout=60)
        self.assertEqual(preview.returncode, 0)
        self.assertIn("would", preview.stdout)
        self.assertEqual(Path("/etc/fstab").read_bytes(), before)

    def test_setup_script_refuses_to_change_anything_without_root(self):
        if os.getuid() == 0:
            self.skipTest("running as root")
        result = subprocess.run(["bash", str(SETUP)], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 1)
        self.assertIn("sudo", result.stdout)


if __name__ == "__main__":
    unittest.main()

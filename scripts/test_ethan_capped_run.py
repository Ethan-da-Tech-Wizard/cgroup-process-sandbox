"""
Program: Linux cgroup v2 Resource Governance & Namespace Sandbox
Programmer: Ethan Kilmer
Last Modified: 11/08/2026
Purpose: Execute commands inside hard memory caps and isolated Linux namespaces to prevent desktop freezes.
"""

# ==============================================================================
# Automated Test Suite for Linux cgroup v2 & Namespace Sandbox
# ==============================================================================
# Validates core resource governance and security isolation contracts:
#   1. cgroup v2 memory cap enforcement (OOM termination via SIGKILL).
#   2. /proc/self/oom_score_adj priority adjustment to 500.
#   3. PID 1 namespace isolation and automatic orphaned grandchild zombie reaping.
#   4. Process signal isolation (blocking killpg/kill(-1) signal leakage).
#   5. Host mode escape hatch (ETHAN_HOST=1).
#   6. Ephemeral $HOME directory sandboxing.
#   7. Concurrency slot limiting and flock timeout behavior.
#   8. Memory safety host setup script validation and dry-run preview contract.
# ==============================================================================

import os
import subprocess
import sys
import unittest
from pathlib import Path

# Absolute path to the sandbox runner executable script
RUNNER = Path(__file__).resolve().parent / "ethan_capped_run.sh"

# Absolute path to the host memory safety setup script
SETUP = Path(__file__).resolve().parent / "ethan_memory_safety_setup.sh"


def capped(*command, cap="300M"):
    """
    Helper function to invoke a command inside ethan_capped_run.sh with a specified memory cap.

    Args:
        *command: Variable argument list containing the executable and arguments to run.
        cap: Memory cap limit passed via the ETHAN_CAP environment variable (default: 300M).

    Returns:
        subprocess.CompletedProcess containing returncode, stdout, and stderr.
    """
    # Execute the command via subprocess.run, capturing stdout/stderr with a 60-second timeout
    return subprocess.run(
        [str(RUNNER), *command],
        capture_output=True,
        text=True,
        timeout=60,
        env={**os.environ, "ETHAN_CAP": cap},
    )


# Skip the test suite if already running inside an inner sandbox instance to prevent recursive nesting
@unittest.skipIf(
    os.environ.get("ETHAN_CAPPED_INNER"),
    "these tests start the wrapper themselves, which cannot nest inside the wrapper's own namespace sandbox; "
    "run them directly: cd scripts && python3 -B -m unittest test_ethan_capped_run",
)
# Skip if not running on Linux (cgroup v2 and namespaces are Linux-specific kernel features)
@unittest.skipUnless(
    sys.platform.startswith("linux"),
    "Linux namespace/cgroup contract; Mac has test_ethan_mac_capped_run",
)
class CappedRunTests(unittest.TestCase):
    """
    Test cases asserting the behavioral guarantees of the sandbox runner and setup script.
    """

    def test_runaway_is_killed_at_the_cap_and_nothing_else(self):
        """
        Verify that a process allocating memory indefinitely is killed when reaching ETHAN_CAP.
        cgroup v2 OOM killer sends SIGKILL (exit code 137 or negative signal -9).
        """
        # Execute an unbounded bytearray allocation loop inside a 300MB cap
        result = capped(
            sys.executable,
            "-c",
            "x=[]\nwhile True: x.append(bytearray(50_000_000))",
        )
        # Verify the process terminated via SIGKILL (exit code 137 in bash or -9 in Python)
        self.assertIn(result.returncode, (137, -9))

    def test_normal_command_runs_with_a_raised_oom_score_and_keeps_its_exit_code(self):
        """
        Verify that a normal command runs with /proc/self/oom_score_adj set to 500
        and preserves arbitrary exit codes upon termination.
        """
        # Query oom_score_adj inside the sandbox
        ok = capped(
            sys.executable,
            "-c",
            "print(open('/proc/self/oom_score_adj').read().strip())",
        )
        # Exit code must be 0 and stdout must be exactly "500"
        self.assertEqual((ok.returncode, ok.stdout.strip()), (0, "500"))

        # Verify custom non-zero exit codes are propagated transparently
        self.assertEqual(
            capped(sys.executable, "-c", "raise SystemExit(7)").returncode,
            7,
        )

    def test_command_runs_in_its_own_pid_namespace_under_a_reaping_pid_one_by_default(self):
        """
        Verify that the user command executes inside a private PID namespace where its
        parent process (ppid) is PID 1 (the bash wrapper that handles zombie reaping).
        """
        # Inspect PID and PPID inside the sandbox
        result = capped(
            sys.executable,
            "-c",
            "import os; print(os.getpid(), os.getppid())",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        # Parse reported PID and PPID from stdout
        pid, ppid = result.stdout.split()[:2]

        # The parent process must be PID 1 (bash subshell acting as namespace init)
        self.assertEqual(ppid, "1")

        # The command's own PID must be greater than 1
        self.assertGreater(int(pid), 1)

    def test_orphaned_grandchildren_are_reaped_not_left_defunct(self):
        """
        Verify that orphaned grandchild background processes are reaped by PID 1
        rather than accumulating as zombie processes (<defunct>) in the process table.
        """
        # Spawn 30 short-lived background child processes that exit immediately, creating orphans
        code = (
            "import subprocess,time\n"
            "for i in range(30): subprocess.Popen(['bash','-c','(sleep 0.05 &); exit 0']).wait()\n"
            "time.sleep(1)\n"
            "print(subprocess.run(\"ps -eo stat | grep -c '^Z'\", shell=True, capture_output=True, text=True).stdout.strip())"
        )
        result = capped(sys.executable, "-c", code)
        # Zombie count in ps output must be exactly 0
        self.assertEqual(result.stdout.strip(), "0", result.stderr)

    def test_broadcast_signal_cannot_reach_real_processes(self):
        """
        Verify that broadcast process signaling (such as killpg(1, 0)) cannot see or
        signal real host processes outside the namespace sandbox.
        """
        # Probe process group 1 inside the sandbox; must raise ProcessLookupError
        code = (
            "import os\n"
            "try:\n"
            "    os.killpg(1, 0); print('reached')\n"
            "except ProcessLookupError:\n"
            "    print('none')"
        )
        result = capped(sys.executable, "-c", code)
        self.assertEqual(result.stdout.strip(), "none", result.stderr)

    def test_host_mode_is_explicit_and_announced(self):
        """
        Verify that setting ETHAN_HOST=1 bypasses namespace isolation while announcing
        host mode execution on stderr.
        """
        # Run command with ETHAN_HOST=1 in the environment
        result = subprocess.run(
            [str(RUNNER), sys.executable, "-c", "import os; print(os.getpid() > 1)"],
            capture_output=True,
            text=True,
            timeout=60,
            env={**os.environ, "ETHAN_HOST": "1", "ETHAN_CAP": "300M"},
        )
        # Verify process ran directly on the host (PID > 1) with exit code 0
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "True"))
        # Verify announcement was emitted to stderr
        self.assertIn("ETHAN_HOST=1", result.stderr)

    def test_sandbox_home_is_not_the_real_home(self):
        """
        Verify that the sandbox isolates HOME by generating an ephemeral directory
        under /tmp/ethan-sandbox-home.XXXXXX.
        """
        # Query HOME environment variable inside the sandbox
        result = capped(sys.executable, "-c", "import os; print(os.environ['HOME'])")
        # Ensure HOME starts with the temporary sandbox prefix
        self.assertTrue(
            result.stdout.strip().startswith("/tmp/ethan-sandbox-home."),
            result.stdout,
        )

    def test_only_the_configured_number_of_runs_execute_at_once(self):
        """
        Verify that flock concurrency limiting restricts parallel executions to ETHAN_SLOTS.
        """
        import tempfile
        import time

        # Create temporary directory for slot lock files
        slots = tempfile.mkdtemp()
        env = {
            **os.environ,
            "ETHAN_SLOTS": "1",
            "ETHAN_SLOT_WAIT": "60",
            "ETHAN_SLOT_DIR": slots,
        }

        # Launch first process holding the sole slot for 6 seconds
        first = subprocess.Popen(
            [str(RUNNER), "sleep", "6"],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        # Give first process time to start and acquire the lock
        time.sleep(2)

        # Launch second process and measure wait duration
        t0 = time.time()
        second = subprocess.run(
            [str(RUNNER), sys.executable, "-c", "print('ran')"],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )
        waited = time.time() - t0

        # Wait for first process to cleanly complete
        first.wait()

        # Verify second process waited for first process to release the slot
        self.assertEqual((second.returncode, second.stdout.strip()), (0, "ran"), second.stderr)
        self.assertGreaterEqual(waited, 3, "the second run must wait for the first slot to free")

    def test_slots_can_be_switched_off(self):
        """
        Verify that setting ETHAN_SLOTS=0 disables concurrency slot checks entirely.
        """
        env = {"ETHAN_SLOTS": "0"}
        result = subprocess.run(
            [str(RUNNER), sys.executable, "-c", "print('ok')"],
            capture_output=True,
            text=True,
            timeout=60,
            env={**os.environ, **env},
        )
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "ok"), result.stderr)

    def test_unwritable_slot_dir_falls_back_to_tmp_instead_of_hanging(self):
        """
        Verify that an unwritable slot directory automatically falls back to /tmp
        without deadlocking or hanging.
        """
        env = {
            **os.environ,
            "ETHAN_SLOT_DIR": "/proc/nonexistent-slot-dir",
            "ETHAN_SLOT_WAIT": "10",
        }
        result = subprocess.run(
            [str(RUNNER), sys.executable, "-c", "print('fallback-ok')"],
            capture_output=True,
            text=True,
            timeout=15,
            env=env,
        )
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "fallback-ok"), result.stderr)
        self.assertNotIn("all 2 run slots busy", result.stderr)

    def test_stderr_of_the_command_is_not_swallowed(self):
        """
        Verify that stderr output from the target command is preserved and forwarded.
        """
        result = capped(
            sys.executable,
            "-c",
            "import sys; sys.stderr.write('boom-on-stderr')",
        )
        self.assertIn("boom-on-stderr", result.stderr)

    def test_runner_requires_a_command(self):
        """
        Verify that invoking the runner without arguments terminates with exit code 2.
        """
        self.assertEqual(
            subprocess.run([str(RUNNER)], capture_output=True).returncode,
            2,
        )

    def test_setup_script_is_valid_and_its_preview_changes_nothing(self):
        """
        Verify that ethan_memory_safety_setup.sh passes bash syntax validation
        and that --check mode makes zero modifications to system files.
        """
        # Validate bash script syntax with bash -n
        self.assertEqual(
            subprocess.run(["bash", "-n", str(SETUP)]).returncode,
            0,
        )

        # Snapshot current /etc/fstab state
        before = Path("/etc/fstab").read_bytes()

        # Run preview mode (--check)
        preview = subprocess.run(
            ["bash", str(SETUP), "--check"],
            capture_output=True,
            text=True,
            timeout=60,
        )

        # Verify successful exit code and presence of "would" in output
        self.assertEqual(preview.returncode, 0)
        self.assertIn("would", preview.stdout)

        # Assert /etc/fstab was not modified
        self.assertEqual(Path("/etc/fstab").read_bytes(), before)

    def test_setup_script_refuses_to_change_anything_without_root(self):
        """
        Verify that ethan_memory_safety_setup.sh in apply mode exits with code 1
        when executed by an unprivileged user without root/sudo.
        """
        if os.getuid() == 0:
            self.skipTest("running as root")
        result = subprocess.run(
            ["bash", str(SETUP)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("sudo", result.stdout)


if __name__ == "__main__":
    unittest.main()

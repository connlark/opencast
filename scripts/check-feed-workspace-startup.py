#!/usr/bin/env python3
"""Prove cold startup never waits for a different process's workspace lock.

Run outside the workspace sandbox, like other Swift checks. The real workspace
source is compiled in isolation; only its temporary root is redirected so this
test cannot touch another app or test process's live jobs.
"""
import fcntl
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
source = repo / "Packages/OpenCastCore/Sources/OpenCastCore/FeedWorkspace.swift"
with tempfile.TemporaryDirectory(prefix="opencast-workspace-startup-", dir="/private/tmp") as temporary:
    root = Path(temporary)
    text = source.read_text()
    assert text.count("FileManager.default.temporaryDirectory") == 1
    (root / "FeedWorkspace.swift").write_text(text.replace(
        "FileManager.default.temporaryDirectory",
        'URL(fileURLWithPath: ProcessInfo.processInfo.environment["OPENCAST_WORKSPACE_PROBE_ROOT"]!, isDirectory: true)'))
    (root / "Probe.swift").write_text('''
import Darwin
import Foundation
@main struct Probe {
    @MainActor static func main() async {
        let started = ContinuousClock.now
        FeedWorkspace.cleanAbandonedJobs()
        let elapsed = started.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print(seconds)
        fflush(nil)
        await FeedWorkspace.waitForCleanup()
        print("cleanup finished")
    }
}
''')
    executable = root / "probe"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-O", "-parse-as-library",
                    str(root / "FeedWorkspace.swift"), str(root / "Probe.swift"),
                    "-o", str(executable)], check=True)
    jobs = root / "OpenCastFeedJobs"
    jobs.mkdir()
    with (jobs / ".registry.lock").open("w") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        process = subprocess.Popen([str(executable)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, env=dict(os.environ, OPENCAST_WORKSPACE_PROBE_ROOT=str(root)))
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        try:
            ready_before_unlock = bool(selector.select(timeout=2))
            startup_seconds = float(process.stdout.readline()) if ready_before_unlock else None
        finally:
            selector.close()
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        output, error = process.communicate(timeout=10)
        assert process.returncode == 0, error
        assert ready_before_unlock, "Startup blocked on the cross-process registry lock"
        assert startup_seconds < 0.250, startup_seconds
        assert "cleanup finished" in output, output
        print(json.dumps({"passed": True, "startup_seconds": startup_seconds,
                          "returned_while_registry_locked": True, "eventual_cleanup": True}))

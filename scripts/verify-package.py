#!/usr/bin/env python3
"""Check a distributable without installing it or touching the user's running service."""
import os
import pathlib
import subprocess
import sys
import tempfile
import zipfile

archive = pathlib.Path(sys.argv[1]).resolve()
private = {"registry.json", "connection.json", "token", "agent-config.json", ".DS_Store"}
home = str(pathlib.Path.home()).encode()
with zipfile.ZipFile(archive) as bundle:
    for item in bundle.infolist():
        name = pathlib.PurePosixPath(item.filename)
        assert not name.is_absolute() and ".." not in name.parts, item.filename
        assert name.name not in private, f"Private runtime file: {name}"
        assert "screenshots" not in name.parts, f"Demo screenshot in archive: {name}"
        assert ".port-backup-" not in str(name), f"Agent backup in archive: {name}"
        if not item.is_dir() and not str(name).startswith("__MACOSX/"):
            assert home not in bundle.read(item), f"Build-machine home path embedded in {name}"
with tempfile.TemporaryDirectory(prefix="poko-verify-") as temp:
    subprocess.run(["ditto", "-x", "-k", str(archive), temp], check=True)
    installer = pathlib.Path(temp) / "Poko Installer.app"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(installer)], check=True)
    payload = installer / "Contents/Resources/payload"
    for app, executable in [("Poko", "Poko"), ("Poko Server", "PortServer")]:
        assert (payload / f"{app}.app/Contents/MacOS/{executable}").is_file()
    runtime = payload / "runtime"
    node = runtime / "bin/node"
    subprocess.run([str(node), "--version"], check=True)
    subprocess.run([str(node), "--input-type=module", "-e", "await import('./node_modules/@modelcontextprotocol/sdk/dist/esm/server/mcp.js'); await import('./node_modules/zod/index.js'); await import('./node_modules/ws/wrapper.mjs'); console.log('Bundled dependencies load')"], cwd=runtime, check=True)
    # Run the real MCP contract against this archive's bridge and Node, with an isolated mock API.
    env = {**os.environ, "POKO_TEST_BRIDGE": str(runtime / "server/mcp.mjs")}
    subprocess.run([str(node), "--test", "test/mcp.test.mjs"], env=env, check=True)
print("Package verified: signatures, private-data exclusions, portable Node and all MCP operations")

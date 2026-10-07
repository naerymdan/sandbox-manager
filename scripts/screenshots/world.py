#!/usr/bin/env python3
"""Build an INVENTED msb-manager setup for the screenshots: three sandboxes, one
git identity, one throwaway ssh key and a versions cache, all under the
directory given (it becomes $HOME). Nothing here is real: the names, the repos,
the person and the versions are made up, the "tokens" are the literal string
below, and bin/msb answers for sandboxes that do not exist.

    world.py DIR        # prints the HOME it built
"""
import json
import os
import subprocess
import sys

root = os.path.abspath(sys.argv[1])
home = os.path.join(root, "home")
cfg = os.path.join(home, ".config", "msb")
state = os.path.join(home, ".local", "state", "msb")
PLACEHOLDER = "placeholder-for-screenshots"


def write(path, text, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(path, mode)


write(os.path.join(cfg, "config.toml"), """\
[defaults]
identity = "work"

[identities.work]
name = "Robin Fairweather"
email = "robin@example.com"
""")
# Already welcomed, and logged in, so no first-run walk-through or warning
# lands in a screenshot.
write(os.path.join(state, "welcome-done"), "")
write(os.path.join(cfg, "secrets", "global.env"), f"CLAUDE_CODE_OAUTH_TOKEN={PLACEHOLDER}\n", 0o600)
os.makedirs(os.path.join(state, "agent"), exist_ok=True)

key = os.path.join(home, ".ssh", "id_ed25519")
os.makedirs(os.path.dirname(key), mode=0o700, exist_ok=True)
subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "robin@laptop", "-f", key],
               check=True)
fp = subprocess.run(["ssh-keygen", "-lf", key + ".pub"], capture_output=True, text=True,
                    check=True).stdout.split()[1]

# bin/msb holds the matching running/stopped states and guest usage.
BOXES = {
    "webshop": dict(groups='["github", "npm", "claude"]', cpus=4, mem="8G",
                    caches='[bootstrap.caches]\nnpm = "8G"\n', autostart="true"),
    "ml-notebooks": dict(groups='["github", "python", "claude"]', cpus=8, mem="16G",
                         caches='[bootstrap.caches]\npython = "16G"\n', autostart="true"),
    "infra": dict(groups='["github", "go", "claude"]', cpus=2, mem="4G",
                  caches="", autostart="false"),
}
for name, b in BOXES.items():
    proj = os.path.join(home, "workspaces", name)
    write(os.path.join(proj, ".msb", "dev.yaml"),
          "image: mcr.microsoft.com/devcontainers/base:ubuntu\n"
          f"cpus: {b['cpus']}\nmemory: \"{b['mem']}\"\nworkdir: /work\n")
    write(os.path.join(proj, ".msb", "sandbox.toml"),
          f"rule_groups = {b['groups']}\nallow_private_dns = false\nextra_rules = []\n"
          f"cpus = {b['cpus']}\nmemory = \"{b['mem']}\"\n\n"
          f"[bootstrap]\npackages = []\nclaude = true\n{b['caches']}\n[secrets]\ngithub = true\n")
    write(os.path.join(cfg, "sandboxes", f"{name}.toml"),
          f'name = "{name}"\nproject = "{proj}"\nrepo = "acme/{name}"\nidentity = "work"\n'
          f'autostart = {b["autostart"]}\nssh_keys = ["{fp}"]\n\n[versions]\n')
    write(os.path.join(cfg, "secrets", f"{name}.env"), f"GH_TOKEN={PLACEHOLDER}\n", 0o600)

write(os.path.join(state, "versions.json"), json.dumps({
    "webshop": {"claude": {"installed": "2.4.1", "available": "2.4.3"},
                "gh": {"installed": "2.81.0", "available": "2.81.0"},
                "node": {"installed": "24.9.0", "available": "24.10.0"},
                "image": {"installed": "ubuntu-24.04", "available": "ubuntu-24.04"},
                "checked": "2026-10-07 09:12"},
    "ml-notebooks": {"claude": {"installed": "2.4.3", "available": "2.4.3"},
                     "gh": {"installed": "2.81.0", "available": "2.81.0"},
                     "checked": "2026-10-07 09:12"},
    "infra": {"claude": {"installed": "2.3.9", "available": "2.4.3"},
              "gh": {"installed": "2.79.1", "available": "2.81.0"},
              "checked": "2026-10-06 18:40"},
}, indent=1))
print(home)

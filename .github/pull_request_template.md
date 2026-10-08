## What and why

<!-- One or two sentences. What changes for someone running msbctl? -->

## Checklist

- [ ] `scripts/check.sh` passes locally
- [ ] If behaviour changed: a one-line entry under **Unreleased** in `CHANGELOG.md`
- [ ] If behaviour changed: comments in `defaults.toml` / `templates/` and `AGENTS.md` still say what is true
- [ ] New or widened egress rule: it comes from an observed denial (host, port, what failed), not a guess
- [ ] Touches `install.sh` or `scripts/package.sh`: `PAYLOAD` is still the same in both
- [ ] No secrets, tokens or machine-local paths in the diff

## Needs a rebuild?

<!-- Egress rules, mounts, disks and the image are fixed at create time, so
     changing them means existing sandboxes need `msbctl rebuild`. Say so here
     if this is such a change; otherwise delete this section. -->

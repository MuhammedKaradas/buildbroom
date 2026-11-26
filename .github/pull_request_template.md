## What changed?

## Why?

Closes #

## Checklist

- [ ] `tests/safety.ps1` (Windows) / `tests/safety.sh` (macOS) passes
- [ ] New cache/artifact rules are dry-run tested on a real machine, and the safety test covers new safety logic
- [ ] Nothing is deleted without `-Apply` / `--apply`, and no new path is deleted outside the documented rules
- [ ] README.md and README.tr.md updated if behavior changed
- [ ] No secrets, personal paths or real user data in code, tests or screenshots

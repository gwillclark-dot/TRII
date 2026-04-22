# Project Status

**Status:** smoke-test
**Last updated:** 2026-04-21

## Summary
This isn't a real project. It exists so a fresh `git clone` of TRII can run `bash trii-run.sh` and prove the full orchestrator → agent → messaging loop works before you wire up anything real.

## Once it works
Delete `examples/hello-world/`, remove `"hello-world"` from the `PROJECTS` array in `trii-run.sh`, and add your real projects.

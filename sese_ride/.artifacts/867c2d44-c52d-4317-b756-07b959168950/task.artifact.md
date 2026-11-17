# Implementation Task Checklist - Global `guardedOnCall` Refactoring

- [/] Define `guardedOnCall` and `bypassAppCheckOnCall` in `functions/src/accountGuard.ts`
- [ ] Migrate `onCall` handlers to `guardedOnCall` across all 16 module files in `functions/src/`
- [ ] Run static analysis audit confirming 100% `guardedOnCall` coverage
- [ ] Build & run backend test suite (`npm test`)
- [ ] Execute mandatory build, test & Firebase deployment pipeline
- [ ] Create `walkthrough.artifact.md`

# Implementation Task Checklist - Error Handling & Observability Refactoring

- [/] Structured Cloud Logging (`severity: "CRITICAL"`) in `requireAccountActive` (`functions/src/accountGuard.ts`)
- [ ] Refactor `goOffline` in `driverStatus.ts` to fail closed on active trip read failure
- [ ] Refactor `goOnline` in `driverStatus.ts` to log and wrap non-HttpsError read failures into `HttpsError('unavailable')`
- [ ] Run backend unit test suite (`npm test`)
- [ ] Execute mandatory build, test & Firebase deployment pipeline
- [ ] Create `walkthrough.artifact.md`

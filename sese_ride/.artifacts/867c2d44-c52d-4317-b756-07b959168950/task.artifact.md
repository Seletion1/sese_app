# Implementation Task Checklist - Secrets Hygiene Overhaul & Key Rotation

- [/] Rotate `FARE_SIGNING_SECRET` in `functions/.env` with fresh 256-bit random hex string
- [/] Create `SECURITY.md` with formal 90-day secret rotation policy and Secret Manager guidelines
- [/] Update `AGENTS.md` with secrets hygiene and key rotation decision log
- [ ] Run backend build & unit tests (`npm test`)
- [ ] Execute mandatory build, test & Firebase deployment pipeline
- [ ] Create `walkthrough.artifact.md`

# Implementation Task Checklist - Secrets Hygiene Overhaul & Key Rotation

- [x] Rotate `FARE_SIGNING_SECRET` in `functions/.env` with fresh 256-bit random hex string
- [x] Create `SECURITY.md` with formal 90-day secret rotation policy and Secret Manager guidelines
- [x] Update `AGENTS.md` with secrets hygiene and key rotation decision log
- [x] Run backend build & unit tests (`npm test`)
- [x] Execute mandatory build, test & Firebase deployment pipeline
- [x] Create `walkthrough.artifact.md`

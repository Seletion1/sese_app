# Create GitHub Actions CI/CD Pipeline (`.github/workflows/ci.yml`)

Implement a comprehensive GitHub Actions CI workflow that automatically runs static analysis, unit/widget tests, and build validation across all 3 Flutter packages (`sese_core`, `sese_ride`, `sese_hub`) and the Cloud Functions Node.js backend on every push and pull request to `main` and `master`.

## User Review Required

> [!IMPORTANT]
> - **Monorepo Workflow Coverage**:
>   - **Flutter Job (`flutter-ci`)**: Runs `flutter pub get`, `flutter analyze`, and `flutter test` across `sese_core`, `sese_ride`, and `sese_hub`.
>   - **Backend Job (`backend-ci`)**: Sets up Node.js 22, runs `npm install`, `npm run build` (validating `tsc` compilation and `functions.yaml` manifest generation), and executes all 142 backend unit tests (`npm test`) in `functions/`.
> - **Triggers**: Executes automatically on `push` and `pull_request` events targeting `main` or `master`.

## Proposed Changes

### GitHub Workflows

#### [NEW] [ci.yml](file:///Users/micheal/sese_app/.github/workflows/ci.yml)
- Create `.github/workflows/ci.yml` with jobs for Flutter static analysis/tests (`sese_core`, `sese_ride`, `sese_hub`) and Node.js 22 backend build & unit tests (`functions/`).

---

## Verification Plan

### Local & Remote Verification
- Run `flutter analyze` across `sese_core`, `sese_hub`, `sese_ride`.
- Run `npm test` in `functions/`.
- Commit `.github/workflows/ci.yml` and push to GitHub remote (`https://github.com/Seletion1/sese_app.git`) on branch `main`.

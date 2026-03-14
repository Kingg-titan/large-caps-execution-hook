# Contributing

## Setup

1. Run `make bootstrap`.
2. Run `make build`.
3. Run `make test`.

## Standards

- Keep dependency versions deterministic.
- Add tests for each behavior change.
- Prefer small, reviewable commits.
- Maintain root layout (`src/`, `test/`, `script/`, `lib/`, `frontend/`, `shared/`).

## Pull Request Checklist

- [ ] Build passes.
- [ ] Tests pass.
- [ ] Coverage run completed.
- [ ] Docs updated (`README`, `spec`, `/docs`).
- [ ] ABI export refreshed (`make export-shared`).

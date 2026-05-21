# Repository Guidelines

## Project Structure & Module Organization

- `lib/`: main application code under `lib/auth2api_ex/` (server, handlers, upstream translators, admin UI, auth flows).
- `test/`: ExUnit tests mirroring `lib/` (including integration/e2e-style tests). Shared test helpers live in `test/support/`.
- `config/`: runtime config files. Local runtime settings are typically in `config.yaml` (see `config.example.yaml`).
- `scripts/`: deployment and helper scripts (see `scripts/deploy.example.toml` referenced in `README.md`).

## Build, Test, and Development Commands

From repo root:

```bash
mix deps.get          # fetch dependencies
mix run --no-halt     # run the proxy locally (default http://127.0.0.1:8318)
mix test --no-start   # run tests without starting the application supervision tree
mix format            # format Elixir sources (see .formatter.exs)
```

This project targets Elixir `~> 1.17` (see `mix.exs`).

## Coding Style & Naming Conventions

- Formatting: use `mix format` (inputs configured in `.formatter.exs` for `config/`, `lib/`, and `test/`).
- Naming: standard Elixir conventions apply (`snake_case.ex`, modules like `Auth2ApiEx.Upstream.*`).
- Keep public APIs small and documented via module/function names; prefer pure transforms in `lib/auth2api_ex/upstream/` where possible.

## Testing Guidelines

- Test framework: ExUnit; mocking uses `:mox` (test-only dependency).
- File naming: `*_test.exs` under `test/`, scoped by feature (e.g. `test/auth2api_ex/upstream/*_test.exs`).
- Add/extend tests when changing request/response translation, streaming behavior, auth, or admin endpoints.

## Commit & Pull Request Guidelines

- Git history currently contains only an “Initial commit”; follow an imperative, scoped subject (e.g. `admin: fix cookie auth validation`).
- PRs should include: a short problem statement, what changed, how you verified (`mix test --no-start`), and any config changes (never commit secrets).

## Security & Configuration Tips

- Do not commit `config.yaml` or credentials. Use `config.example.yaml` as the public template and keep `auth-dir` pointing to a writable, local-only path.

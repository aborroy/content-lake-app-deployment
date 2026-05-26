# Contributing

This project is part of the **Content Lake** PoC ecosystem. Contributions are welcome.

## Before You Start

- Read the [README](README.md) to understand the deployment profiles and stack layout.
- Check the open issues before starting new work.
- For significant changes, open an issue first to discuss the approach.

## Making Changes

1. Fork the repository and create a branch from `main`.
2. Make your changes. Keep commits focused -- one logical change per commit.
3. Validate by running `make config` (dry-run, renders compose configuration) and then starting
   the affected profile with `make up-alfresco` or `make up-nuxeo`.
4. Run the smoke tests if you have a running stack:
   ```bash
   ./test/smoke-test.sh
   ```
5. Open a pull request. Describe what changed and why.

## Inline Dockerfiles

When adding a new Maven module to `content-lake-app`, also update
`compose.content-lake.yaml`. Each service has an inline Dockerfile with two sections that
enumerate modules explicitly -- see the README for details.

## Commit Messages

Use the format: `type: short description`

Types: `feat`, `fix`, `docs`, `chore`

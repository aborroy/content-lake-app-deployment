# Security Policy

## Reporting a Vulnerability

This is a Proof of Concept project intended for local development and evaluation. It is **not
designed for production use** and has not undergone a security audit.

If you discover a security vulnerability, please report it privately by opening a GitHub issue
marked **[security]** or by contacting the repository maintainer directly.

Do not open a public issue for active security vulnerabilities -- wait for acknowledgement before
public disclosure.

## Supported Versions

Only the current `main` branch is supported. No backported security patches are provided.

## Known Limitations

- Default credentials are used throughout (`admin`/`admin`, `Administrator`/`Administrator`) for
  local convenience. Never expose this stack on a public network without changing them.
- The nginx reverse proxy does not enforce TLS in the default configuration. See
  [docs/DEPLOY_EC2.md](docs/DEPLOY_EC2.md) for HTTPS setup guidance.
- Build secrets (`MAVEN_PASSWORD`, `NEXUS_PASSWORD`, `HXPR_GIT_AUTH_TOKEN`) are passed via
  Docker BuildKit secrets -- they are not baked into the resulting images, but must be protected
  in the local environment.

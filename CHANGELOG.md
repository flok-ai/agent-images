# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [0.2.0] - 2026-11-20

Relicensed for the move to [flok](https://github.com/flok-ai).

### Changed

- License changed from MIT to the GNU Affero General Public License v3.0 only (AGPL-3.0-only). Copies, modified versions and network deployments must keep the attribution in `NOTICE`. Versions up to and including 0.1.0 remain MIT.

### Added

- `NOTICE` with the attribution term, `REUSE.toml` and `CONTRIBUTING.md`.

## [0.1.0] - 2026-11-20

Initial release: the shared `agent-base` image used by every agent step in the cluster.

### Added

- `agent-base` image: goose on Debian with Python, Node and the GitHub CLI, running as a non-root user ([#3](https://github.com/julie-ng/ai-native-sdlc-agent-images/pull/3)).
- CI publishing to the container registry through GitHub OIDC, after an offline entrypoint check.
- Runtime entrypoint: loads mounted secrets, sets the Git identity and imports the commit-signing key into a fresh private GPG home ([#8](https://github.com/julie-ng/ai-native-sdlc-agent-images/pull/8)).
- GitHub token from the token broker: the entrypoint exchanges the pod's projected ServiceAccount token for a short-lived, role-scoped GitHub token, failing fast without printing secrets ([#11](https://github.com/julie-ng/ai-native-sdlc-agent-images/pull/11)).
- Decision records: GitHub CLI over MCP, and goose as a light harness over provider SDKs ([#4](https://github.com/julie-ng/ai-native-sdlc-agent-images/pull/4)).

### Removed

- Mounted shared GitHub token (PAT) support: GitHub access now comes only from the token broker ([#13](https://github.com/julie-ng/ai-native-sdlc-agent-images/pull/13)).

[0.2.0]: https://github.com/julie-ng/ai-native-sdlc-agent-images/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/julie-ng/ai-native-sdlc-agent-images/releases/tag/v0.1.0

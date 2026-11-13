# Docker MCC Host Implementation Plan

> Execute inline with executing-plans. The primary agent owns implementation, integration and code review; do not delegate review.

**Goal:** Let an external MCC CLI control the existing Docker Firefox desktop through the existing WSS Host.

**Architecture:** CLI → published WSS port → existing Host → daemon → Service → Linux helper → X11/XTEST. Add Host to the desktop supervisor when explicitly enabled; reuse TLS/token provisioning, owner reservation, journal and the existing config volume.

**Tech Stack:** Ubuntu 22.04, Compose, Bash supervisor, existing Rust Host, Python live smoke.

**Spec:** [Remote Host contract](../../REMOTE-HOST.md), [Docker design](../specs/2026-11-13-mcc-docker-design.md).

## Constraints

- Keep the default six-process desktop; Host is an opt-in seventh process.
- Container listens on 0.0.0.0:8765; published Host defaults to 127.0.0.1:8765.
- Explicitly initialize credentials in the existing private config volume. Never regenerate credentials or recover a dirty journal at startup.
- Stop Host before daemon so in-flight input can be paused and released.
- Health checks inspect the listener without making unauthenticated TLS connections.
- Preserve current profiles and default desktop during isolated tests. No commits or push in this task.

## Task 1: Supervise and publish Host

Files: `compose.host.yaml`, `docker/desktop-entrypoint.sh`, `docker/healthcheck.sh`, `Dockerfile`, `tests/docker_host_smoke.py`.

- [x] Add a host-side smoke using the built local CLI and a dedicated container. Serve a fixture from the host; verify remote auth, status, Firefox start, JPEG download, click, Unicode input, Actions, and disconnect.
- [x] Run against the current image with a published port and MCC_HOST_ENABLED=1; confirm external status fails because the old supervisor does not start Host.
- [x] Validate the enable flag and required credential files; register the existing `mcc host start` with the process supervisor. Give Host a bounded graceful stop before stopping daemon.
- [x] Extend health checks to count the optional seventh process and verify its owned listening socket via procfs. Add opt-in Compose override and exposed-port metadata.
- [x] Build the runtime and run the host-side smoke, clean restart, missing-credential failure, child-exit supervision and default desktop regression. Check both architectures where the existing build cache permits.

## Task 2: Document and activate

Files: `docs/MCC-DOCKER.md`, `docs/MCC-DOCKER-VALIDATION.md`, `docs/superpowers/specs/2026-11-13-mcc-docker-design.md`.

- [x] Document provisioning, private client files, external CLI use, LAN bind/SAN, graceful disconnect and explicit recovery after unclean stop.
- [x] Review the changes as primary agent; run shell/Compose/Python checks and verify documented commands.
- [x] Initialize credentials for the default desktop, preserve its named volumes, switch it to Host-enabled startup and prove host-side access with an actual Firefox observation.
- [x] Record exact validation results and provide a usable local command with private credential paths.

Validation evidence, two intermittent failures and local port selection are recorded in [the validation report](../../MCC-DOCKER-VALIDATION.md#docker-host-增补验收). No Rust implementation changes were needed for the Host packaging task.

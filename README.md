# Nidavellir

*The Forge - Platform & Tooling*

> "The dark fields where the dwarves forge the most powerful treasures of the gods."

**Nidavellir** is the **Platform Layer**. It is the workspace where we forge applications, hosting the CI/CD pipelines (Jenkins), Dashboards (Backstage), and Identity Systems (Keycloak) needed to build everything else.

## Tech Stack

* **Dashboard**: Backstage
* **Identity**: Keycloak
* **Kanban**: Wekan
* **CI/CD**: Jenkins
* etc
* Vegvísir: Ingress Control via Traefik, custom operator for Gateway API
* OpenBAO: Secrets Storage

## Documentation

Operational and design documentation lives in [`docs/`](docs/README.md) — TLS and certificates, Traefik version pins, Cloud IAM and DNS, testing, and the platform Gitea day-2 plan.

## For contributors / agents

This component is part of the [SiliconSaga](https://github.com/SiliconSaga) ecosystem managed via the [yggdrasil workspace](https://github.com/SiliconSaga/yggdrasil). Workspace-level conventions, the `ws` CLI, and the Guardian Driven Development methodology are documented in [`yggdrasil/AGENTS.md`](https://github.com/SiliconSaga/yggdrasil/blob/main/AGENTS.md) and [`yggdrasil/docs/ecosystem-architecture.md`](https://siliconsaga.github.io/yggdrasil/ecosystem-architecture/).

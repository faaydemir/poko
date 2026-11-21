# Port development

Two apps: the Node daemon (`server/`) and native Swift menu bar UI (`Sources/PortUI/`). `scripts/build.sh` packages both macOS apps; `scripts/install.sh` installs a per-user runtime. Keep the control API authenticated and loopback-only. Never kill unrelated listeners to claim ports.

When starting local development services, request a port from the Port MCP server with the app name and absolute project folder, accept it before starting, then use its assigned port and URL. Use the same group for related services. If MCP is unavailable, report it instead of silently claiming a shared default port.

Run `npm test` for backend changes and `npm run build` for Swift/helper changes. Tests must use isolated data directories. No external accounts or network dependencies at runtime. Do not put local registry data, tokens or agent configuration backups in this repository.

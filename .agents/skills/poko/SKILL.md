---
name: poko
description: Use Poko when configuring web application ports, checking available ports, resolving port conflicts, or managing dev servers.
---

# Poko (Port Control)

Manage local web development services, check port availability, and eliminate port conflicts using Poko.

## When to Use

- **Use Poko when configuring a web application port, checking available ports, resolving port conflicts, or starting any local dev server.**
- Always use Poko before starting any local web application, API, frontend, or backend server.
- All operations available in the Poko UI (adding apps, editing configuration, mapping running listeners, starting, stopping, and releasing) can be performed directly by AI agents through MCP tools with identical parameters.

## Core MCP Tools & UI Operations

| UI Action | MCP Tool | Parameters | Description |
| :--- | :--- | :--- | :--- |
| **Check Available / Active Ports** | `inspect_ports` | `{}` | Scans system TCP listeners, PIDs, and project folders to find free ports and detect conflicts. |
| **List Apps & Status** | `list_apps` | `{}` | Reads all registered apps, assigned ports, direct/proxy URLs, health status, and live PIDs. |
| **Add / Reserve App** | `request_port` | `name`, `projectPath?`, `group?`, `port?` | Allocates an available port for a named app (optionally pins a specific free port). Groups get adjacent port blocks (e.g. 4100–4119). |
| **Accept & Activate Route** | `accept_port` | `id` | Activates reverse proxy route (`http://<name>.localhost`) before starting the dev server. |
| **Edit / Configure Settings** | `configure_app` | `id`, `url?`, `healthUrl?`, `iconUrl?`, `startScript?`, `projectPath?` | Edits identical configuration fields as the UI: custom URL, health endpoint, start script, working folder. |
| **Map / Import Running Listener**| `map_app` | `name`, `port`, `pid`, `group?`, `startScript?`, `healthUrl?`, `projectPath?` | Imports an already-running listener into the Poko registry without changing its port. |
| **Run / Start Server** | `start_app` | `id`, `startScript?`, `projectPath?` | Executes the app's start script in its project folder with `$PORT` injected. Optional params test a draft script. |
| **Shut Down / Stop Process** | `shutdown_app` | `pid`, `port` | Gracefully sends SIGTERM to the process listening on the port. |
| **Release / Remove App** | `release_port` | `id` | Deletes the mapping and proxy route without terminating the process. |
| **Configure Health Check** | `set_health_endpoint` | `id?`, `port?`, `healthPath` | Sets custom health check path (e.g. `/health`). |

## Recommended Workflow

1. **Check Available Ports & Conflicts**:
   Call `inspect_ports` to find active TCP listeners, verify which ports are free, and avoid collisions.

2. **Reserve & Accept the Port**:
   - Call `request_port` with `name`, `projectPath`, and optional `group`.
   - Call `accept_port` with the returned reservation `id`.

3. **Start the Dev Server**:
   Pass the allocated port to your server using the `$PORT` environment variable or CLI argument:
   ```bash
   PORT=<allocated_port> npm run dev
   # or
   npm run dev -- --port <allocated_port>
   ```
   Or call `start_app` to let Poko launch the configured script in the project directory.

4. **Verify & Access**:
   Access the service at `http://localhost:<port>` or `http://<name>.localhost`. Call `list_apps` to verify health.

5. **Edit Settings or Stop**:
   - Use `configure_app` to edit start script, health URL, or custom URL.
   - Use `shutdown_app` (or `release_port`) when work is finished.

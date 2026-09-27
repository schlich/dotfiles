# MCP Server Configuration

This directory contains a centralized MCP (Model Context Protocol) server setup that can be used across multiple MCP clients.

## Agent shell results

The configured Nushell MCP server exposes the `agent-shell` command. Use it
when an agent needs to run a terminal command and receive a stable structured
result instead of parsing terminal text:

```nu
agent-shell "jj status"
agent-shell "nix fmt -- --check" --max-output 4000
```

It returns a `nushell.ai/v1` record containing `ok`, `kind`, `command`, `cwd`,
`exit_code`, separate `stdout` and `stderr`, truncation flags, and a summary.
The command runs in a clean child Nushell with startup configuration and
history disabled. The MCP server keeps the record structured for the agent;
the same command is also available in an interactive Nushell session.

Atuin output capture is enabled for interactive sessions: its daemon keeps
recent output in memory and its Nushell `pty-proxy` associates that output with
the Atuin history ID. The `atuin` MCP server is configured for the AI clients,
so a triage agent can call `atuin_history` and `atuin_output` to inspect the
failed command's actual terminal output.

## Recursive language model commands

`rlm.nu` adds the Recursive Language Model pattern to the same persistent
REPL. Long context stays in Nushell variables instead of the agent's prompt,
and slices go to headless `claude -p` sub-calls:

```nu
let ctx = rlm load src/**/*.rs
$ctx | rlm info
let hits = ($ctx | rlm find 'unsafe')
let answers = ($ctx | rlm chunk | rlm map "List unsafe blocks and why they are needed.")
$answers | to json | rlm query "Summarize the unsafe usage across the crate."
rlm usage
```

The native `nushell` MCP server provides this REPL to Codex Desktop. It does
not require a separate Nu Pair plugin; installing that plugin exposes a second
copy of the evaluator with a misleading tool label.

`rlm query --recursive` gives the sub-model its own Nushell MCP REPL with these
commands, bounded by `RLM_MAX_DEPTH` (default 1). Sub-calls default to
`RLM_MODEL` (`haiku`), run `RLM_THREADS` (4) at a time in `rlm map`, and append
cost and token usage to `RLM_LEDGER`; set `RLM_MAX_COST_USD` to stop new calls
once the ledger reaches that spend. The `rlm` skill describes the workflow.

## Interactive terminal events

The Nushell configuration also publishes interactive command lifecycle events
to cross.stream. Atuin remains the source of truth for command history,
duration, working directory, session, and exit status; XS stores the event
workflow and correlates events using Atuin's `ATUIN_HISTORY_ID`.

The user service starts the local store at
`~/.local/share/cross.stream/store` and registers a `terminal-triage` actor.
Failed commands produce a `terminal.command.failed` event. If `ai-run` is
available, the actor sends a read-only triage request to it and records the
response. If it is unavailable, the actor records a
`terminal.agent.unconfigured` warning instead.

Intelli-shell remains in the normal Nushell input path. Commands it generates
or fixes are therefore recorded by Atuin and observed by XS without a second
execution path.

## Directory Structure

```
~/.mcp/
├── mcp.json              # Main configuration file
├── setup.nu              # Nushell setup script
├── mcp-utils.nu          # Nushell utilities for managing servers
├── NUSHELL.md            # Nushell guide
├── configs/              # Client-specific configurations
│   ├── claude-desktop.json
│   └── cline.json
├── servers/              # Custom MCP servers
│   └── custom-example.py
└── logs/                 # Server logs (optional)
```

## Setup Instructions

### Quick Setup (Interactive)

```nu
nu ~/.mcp/setup.nu
```

The interactive menu provides options for:

1. Linking config to current directory (Claude Code CLI)
1. Setting up Claude Desktop
1. Viewing Cline/VSCode instructions
1. Testing custom servers
1. Viewing configuration

## Configuration Management

### Using Nushell Utilities

The `mcp-utils.nu` script provides convenient commands for managing servers:

```nu
# List all servers
nu ~/.mcp/mcp-utils.nu list

# Show server status
nu ~/.mcp/mcp-utils.nu status

# Enable/disable servers
nu ~/.mcp/mcp-utils.nu enable github
nu ~/.mcp/mcp-utils.nu disable puppeteer

# Test a server
nu ~/.mcp/mcp-utils.nu test filesystem

# Add a new server
nu ~/.mcp/mcp-utils.nu add my-server python3 /path/to/server.py --description "My custom server"

# Remove a server
nu ~/.mcp/mcp-utils.nu remove my-server

# Export config for specific clients
nu ~/.mcp/mcp-utils.nu export claude-desktop
nu ~/.mcp/mcp-utils.nu export cline

# Edit main config
nu ~/.mcp/mcp-utils.nu edit

# View logs
nu ~/.mcp/mcp-utils.nu logs
```

### Manual Configuration

Edit `~/.mcp/mcp.json` and change the `enabled` field:

```json
{
  "mcpServers": {
    "github": {
      "enabled": true,
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "your-token-here"
      }
    }
  }
}
```

### Add Environment Variables

For servers requiring API keys:

```json
{
  "mcpServers": {
    "github": {
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_your_token_here"
      }
    }
  }
}
```

**Security Note**: Never commit API keys to git. Consider using environment variables:

```json
{
  "env": {
    "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}"
  }
}
```

Then export in your shell:

```nu
$env.GITHUB_TOKEN = "ghp_your_token_here"
```

## Custom MCP Servers

### Python Example

See `~/.mcp/servers/custom-example.py` for a basic Python MCP server.

To add to your configuration:

```json
{
  "mcpServers": {
    "custom": {
      "command": "python3",
      "args": ["/home/nixos/.mcp/servers/custom-example.py"],
      "enabled": true
    }
  }
}
```

## Testing Servers

```nu
nu ~/.mcp/mcp-utils.nu test filesystem
nu ~/.mcp/mcp-utils.nu test git
```

## Quick Start Commands

```nu
# Interactive setup
nu ~/.mcp/setup.nu

# Link config to current project
ln -s ~/.mcp/mcp.json .

# List and manage servers
nu ~/.mcp/mcp-utils.nu list
nu ~/.mcp/mcp-utils.nu status
nu ~/.mcp/mcp-utils.nu enable github

# Test if servers work
npx -y @modelcontextprotocol/server-filesystem $env.HOME

# View available official servers
npm search @modelcontextprotocol/server

# Install server globally (optional)
npm install -g @modelcontextprotocol/server-filesystem
```

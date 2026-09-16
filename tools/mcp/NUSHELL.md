# MCP Server Management with Nushell

This guide covers using Nushell to manage your MCP server setup. All scripts are written in Nushell for consistency and power.

## Quick Start

### Interactive Setup

```nu
nu ~/.mcp/setup.nu
```

This launches an interactive menu where you can:
1. Link config to current directory (for Claude Code CLI)
2. Setup for Claude Desktop
3. Show Cline/VSCode setup instructions
4. Test custom Python server
5. View configuration

## MCP Utilities

The `mcp-utils.nu` script provides a comprehensive CLI for managing MCP servers.

### Basic Commands

#### List All Servers

```nu
nu ~/.mcp/mcp-utils.nu list
```

Shows all configured servers with their status and descriptions.

#### Check Server Status

```nu
nu ~/.mcp/mcp-utils.nu status
```

Displays a quick status overview:
- 🟢 Enabled servers
- ⚫ Disabled servers
- 🔑 Servers requiring API keys

#### Enable/Disable Servers

```nu
# Enable a server
nu ~/.mcp/mcp-utils.nu enable github

# Disable a server
nu ~/.mcp/mcp-utils.nu disable puppeteer
```

#### Test a Server

```nu
nu ~/.mcp/mcp-utils.nu test filesystem
```

Tests if a server's command is accessible and runs correctly.

### Advanced Management

#### Add a New Server

```nu
# Basic syntax
nu ~/.mcp/mcp-utils.nu add <name> <command> [...args]

# Examples
nu ~/.mcp/mcp-utils.nu add my-tool python3 /path/to/tool.py

# With description
nu ~/.mcp/mcp-utils.nu add my-tool python3 /path/to/tool.py \
  --description "My custom tool"

# Add disabled initially
nu ~/.mcp/mcp-utils.nu add my-tool python3 /path/to/tool.py \
  --enabled false
```

#### Remove a Server

```nu
nu ~/.mcp/mcp-utils.nu remove my-tool
```

You'll be prompted to confirm before removal.

#### Export Configuration

Generate client-specific config files:

```nu
# Export for Claude Desktop
nu ~/.mcp/mcp-utils.nu export claude-desktop

# Export for Cline
nu ~/.mcp/mcp-utils.nu export cline
```

This creates/updates the appropriate config file with only enabled servers.

#### Edit Configuration

```nu
nu ~/.mcp/mcp-utils.nu edit
```

Opens the main `mcp.json` in your `$env.EDITOR` (defaults to nano).

#### View Logs

```nu
nu ~/.mcp/mcp-utils.nu logs
```

Lists available log files in `~/.mcp/logs/`.

## Integration with Nushell

### Create Aliases

Add these to your `env.nu` or `config.nu`:

```nu
# Aliases for MCP management
alias mcp = nu ~/.mcp/mcp-utils.nu
alias mcp-setup = nu ~/.mcp/setup.nu

# Usage examples:
# mcp list
# mcp status
# mcp enable github
```

### Environment Setup

For servers requiring environment variables, add to your `env.nu`:

```nu
# MCP Server Environment Variables
$env.GITHUB_TOKEN = "ghp_your_token_here"
$env.BRAVE_API_KEY = "your_brave_key"
$env.SLACK_BOT_TOKEN = "xoxb-your-token"
```

Or load from a separate file:

```nu
# In your env.nu
if ("~/.mcp/.env" | path exists) {
    # Load .env file (you'll need a parser or use a module)
    # Or export them manually as shown above
}
```

### Custom Functions

Create custom Nushell functions for your workflow:

```nu
# Quick link MCP config to current project
def mcp-link [] {
    ln -sf ~/.mcp/mcp.json ./mcp.json
    print "✓ Linked MCP config to current directory"
}

# Enable multiple servers at once
def mcp-enable-all [...servers: string] {
    for server in $servers {
        nu ~/.mcp/mcp-utils.nu enable $server
    }
}

# Usage:
# mcp-enable-all github slack brave-search
```

## Examples

### Setting Up a New Project

```nu
# Navigate to project
cd ~/my-project

# Link MCP config
ln -sf ~/.mcp/mcp.json ./mcp.json

# Enable needed servers
nu ~/.mcp/mcp-utils.nu enable github
nu ~/.mcp/mcp-utils.nu enable sqlite

# Check status
nu ~/.mcp/mcp-utils.nu status

# Start working
claude
```

### Managing API Keys

```nu
# Edit config to add GitHub token
nu ~/.mcp/mcp-utils.nu edit

# Or update via Nushell directly
let config = open ~/.mcp/mcp.json
let updated = $config | update mcpServers.github.env.GITHUB_PERSONAL_ACCESS_TOKEN $env.GITHUB_TOKEN
$updated | save -f ~/.mcp/mcp.json

# Enable the server
nu ~/.mcp/mcp-utils.nu enable github

# Test it works
nu ~/.mcp/mcp-utils.nu test github
```

### Creating a Custom Server

```nu
# Create server script
mkdir ~/.mcp/servers
$"#!/usr/bin/env python3
# Your MCP server code here
" | save ~/.mcp/servers/my-server.py

chmod +x ~/.mcp/servers/my-server.py

# Add to config
nu ~/.mcp/mcp-utils.nu add my-server python3 ~/.mcp/servers/my-server.py \
  --description "My custom MCP server"

# Test it
nu ~/.mcp/mcp-utils.nu test my-server

# Enable it
nu ~/.mcp/mcp-utils.nu enable my-server
```

### Batch Operations

```nu
# Get all disabled servers
let config = open ~/.mcp/mcp.json
let disabled = $config.mcpServers | transpose name details | where {|s|
    not ($s.details | get -i enabled | default true)
} | get name

print $"Disabled servers: ($disabled | str join ', ')"

# Enable all servers that don't require API keys
let config = open ~/.mcp/mcp.json
$config.mcpServers | transpose name details | where {|s|
    ($s.details | get -i env | default {} | is-empty)
} | each {|s|
    nu ~/.mcp/mcp-utils.nu enable $s.name
}
```

## Tips and Tricks

### 1. Tab Completion

If you've aliased `mcp`, Nushell will provide tab completion for subcommands.

### 2. Piping Configuration

```nu
# View server names only
open ~/.mcp/mcp.json | get mcpServers | columns

# Count enabled servers
open ~/.mcp/mcp.json | get mcpServers | transpose name details | where {|s|
    $s.details | get -i enabled | default true
} | length
```

### 3. Quick Status Check

```nu
# One-liner to see which servers are enabled
open ~/.mcp/mcp.json | get mcpServers | transpose name details |
  select name | insert enabled {|s|
    $s.details | get -i enabled | default true
  } | where enabled
```

### 4. Backup Configuration

```nu
# Backup before making changes
cp ~/.mcp/mcp.json $"~/.mcp/mcp.json.backup.(date now | format date '%Y%m%d_%H%M%S')"
```

### 5. Server Health Check

```nu
# Test all enabled servers
open ~/.mcp/mcp.json | get mcpServers | transpose name details | where {|s|
    $s.details | get -i enabled | default true
} | each {|s|
    print $"Testing ($s.name)..."
    nu ~/.mcp/mcp-utils.nu test $s.name
}
```

## Troubleshooting

### Script Not Found

Make sure scripts are executable:

```nu
chmod +x ~/.mcp/setup.nu
chmod +x ~/.mcp/mcp-utils.nu
```

### Permission Errors

If you get permission errors when modifying config:

```nu
# Check file permissions
ls -la ~/.mcp/mcp.json

# Fix if needed
chmod 644 ~/.mcp/mcp.json
```

### Nushell Not Found

Ensure Nushell is in your PATH:

```nu
which nu
```

On NixOS, you may need to install it:

```nu
nix-shell -p nushell
```

## Additional Resources

- [Nushell Documentation](https://www.nushell.sh/book/)
- [MCP Documentation](https://modelcontextprotocol.io)
- Main README: `~/.mcp/README.md`

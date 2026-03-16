# MCP Server Configuration

This directory contains a centralized MCP (Model Context Protocol) server setup that can be used across multiple MCP clients.

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
2. Setting up Claude Desktop
3. Viewing Cline/VSCode instructions
4. Testing custom servers
5. Viewing configuration

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
      "enabled": true,  // Change this
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
      "args": ["/home/schlich/.mcp/servers/custom-example.py"],
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

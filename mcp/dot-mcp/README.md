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

## Available MCP Servers

### Enabled by Default

1. **filesystem** - File system operations
   - Browse and manipulate files in your home directory
   
2. **git** - Git repository operations
   - Commit, diff, log, and other git commands
   
3. **fetch** - HTTP requests and web content
   - Fetch web pages and APIs
   
4. **memory** - Persistent knowledge graph
   - Store and retrieve information across sessions

### Available (Disabled)

5. **github** - GitHub API integration
   - Requires: `GITHUB_PERSONAL_ACCESS_TOKEN`
   
6. **sqlite** - SQLite database operations
   - Configure database path in mcp.json
   
7. **brave-search** - Web search via Brave API
   - Requires: `BRAVE_API_KEY`
   
8. **postgres** - PostgreSQL database operations
   - Configure connection string in mcp.json
   
9. **puppeteer** - Browser automation
   - Web scraping and testing
   
10. **slack** - Slack integration
    - Requires: `SLACK_BOT_TOKEN` and `SLACK_TEAM_ID`

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

### For Claude Code CLI

The `mcp.json` file in this directory can be linked or copied to your project:

```nu
# Option 1: Link for project
ln -s ~/.mcp/mcp.json /path/to/your/project/mcp.json

# Option 2: Copy for project
cp ~/.mcp/mcp.json /path/to/your/project/mcp.json
```

Or use the `/mcp` command in Claude Code CLI to manage servers.

### For Claude Desktop

Copy the configuration to Claude Desktop's config location:

```nu
# macOS
mkdir ~/Library/Application\ Support/Claude/
cp ~/.mcp/configs/claude-desktop.json ~/Library/Application\ Support/Claude/claude_desktop_config.json

# Linux
mkdir ~/.config/Claude/
cp ~/.mcp/configs/claude-desktop.json ~/.config/Claude/claude_desktop_config.json

# Windows
# Copy to: %APPDATA%\Claude\claude_desktop_config.json
```

Or use the setup script:
```nu
nu ~/.mcp/setup.nu
# Select option 2
```

Then restart Claude Desktop.

### For Cline (VSCode Extension)

1. Open VSCode Settings (Ctrl+,)
2. Search for "Cline MCP"
3. Edit `cline.mcpServers` in settings.json:

```json
{
  "cline.mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/schlich"]
    },
    "git": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-git"]
    }
  }
}
```

Or use the reference config: `~/.mcp/configs/cline.json`

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

### Node.js/TypeScript Servers

Create servers using the official SDK:

```nu
npm install @modelcontextprotocol/sdk
```

Place them in `~/.mcp/servers/` and reference in config.

## Testing Servers

### Test with Claude Code CLI

```nu
cd /tmp
ln -s ~/.mcp/mcp.json .
claude
# Use /mcp to see available servers
```

### Test Individual Server

```nu
npx -y @modelcontextprotocol/server-filesystem /home/schlich
```

### Test with Nushell Utilities

```nu
nu ~/.mcp/mcp-utils.nu test filesystem
nu ~/.mcp/mcp-utils.nu test git
```

## Troubleshooting

### Server won't start

1. Check Node.js/npm is available: `npx --version`
2. Check logs in `~/.mcp/logs/`
3. Test server manually from command line
4. Verify environment variables are set

### npx not found

You need Node.js installed. On NixOS:

```nu
nix-shell -p nodejs
# Or add to your configuration.nix
```

### Permissions issues

Ensure scripts are executable:

```nu
chmod +x ~/.mcp/servers/*.py
chmod +x ~/.mcp/*.nu
```

### API keys not working

- Check environment variables are exported
- Verify token permissions/scopes
- Check token hasn't expired

## Resources

- [MCP Documentation](https://modelcontextprotocol.io)
- [Official MCP Servers](https://github.com/modelcontextprotocol/servers)
- [MCP SDK](https://github.com/modelcontextprotocol/sdk)
- [Create Custom Servers](https://modelcontextprotocol.io/docs/tools/building)
- [Nushell Guide](~/.mcp/NUSHELL.md) - Comprehensive Nushell usage guide

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

## Maintenance

Update your MCP servers regularly:

```nu
# npx always fetches latest with -y flag
# Or update globally installed servers
npm update -g @modelcontextprotocol/server-*
```

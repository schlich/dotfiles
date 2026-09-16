#!/usr/bin/env nu

export def main [] {
    print "MCP Server Utilities"
    print "===================="
    print ""
    print "Available commands:"
    print "  mcp list              - List all configured servers"
    print "  mcp enable <name>     - Enable a server"
    print "  mcp disable <name>    - Disable a server"
    print "  mcp status            - Show server status"
    print "  mcp test <name>       - Test a specific server"
    print "  mcp logs              - View server logs"
    print "  mcp edit              - Edit main config"
    print ""
}

export def "main list" [] {
    let mcp_dir = $"($env.HOME)/.mcp"
    let config = open $"($mcp_dir)/mcp.json" | get mcpServers

    print "Configured MCP Servers:"
    print "======================="
    print ""

    $config | transpose name details | each {|server|
        let status = if ($server.details | get -i enabled | default true) { "✓ enabled" } else { "✗ disabled" }
        let desc = $server.details | get -i description | default "No description"
        print $"($server.name) - ($status)"
        print $"  ($desc)"
        print ""
    }
}

export def "main status" [] {
    let mcp_dir = $"($env.HOME)/.mcp"
    let config = open $"($mcp_dir)/mcp.json" | get mcpServers

    print "MCP Server Status:"
    print "=================="
    print ""

    $config | transpose name details | each {|server|
        let enabled = $server.details | get -i enabled | default true
        let has_env = ($server.details | get -i env | default {} | is-not-empty)

        let status_icon = if $enabled { "🟢" } else { "⚫" }
        let env_icon = if $has_env { "🔑" } else { "  " }

        print $"($status_icon) ($env_icon) ($server.name)"
    }

    print ""
    print "Legend: 🟢 enabled | ⚫ disabled | 🔑 requires API keys"
}

export def "main enable" [name: string] {
    let mcp_dir = $"($env.HOME)/.mcp"
    let config_file = $"($mcp_dir)/mcp.json"
    let config = open $config_file

    if ($name not-in ($config | get mcpServers | columns)) {
        print $"Error: Server '($name)' not found"
        exit 1
    }

    let updated = $config | update mcpServers.$name.enabled true
    $updated | save -f $config_file

    print $"✓ Enabled ($name)"
}

export def "main disable" [name: string] {
    let mcp_dir = $"($env.HOME)/.mcp"
    let config_file = $"($mcp_dir)/mcp.json"
    let config = open $config_file

    if ($name not-in ($config | get mcpServers | columns)) {
        print $"Error: Server '($name)' not found"
        exit 1
    }

    let updated = $config | update mcpServers.$name.enabled false
    $updated | save -f $config_file

    print $"✓ Disabled ($name)"
}

export def "main test" [name: string] {
    let mcp_dir = $"($env.HOME)/.mcp"
    let config = open $"($mcp_dir)/mcp.json" | get mcpServers

    if ($name not-in ($config | columns)) {
        print $"Error: Server '($name)' not found"
        exit 1
    }

    let server = $config | get $name
    let cmd = $server | get command
    let args = $server | get args

    print $"Testing ($name)..."
    print $"Command: ($cmd) ($args | str join ' ')"
    print ""

    try {
        run-external $cmd ...$args --help | complete
        print $"✓ ($name) is accessible"
    } catch {
        print $"✗ Failed to run ($name)"
        print "Check if dependencies are installed"
    }
}

export def "main logs" [] {
    let mcp_dir = $"($env.HOME)/.mcp"
    let log_dir = $"($mcp_dir)/logs"

    if not ($log_dir | path exists) {
        print "No logs directory found"
        exit 0
    }

    let logs = ls $log_dir | where type == file

    if ($logs | is-empty) {
        print "No log files found"
    } else {
        print "Available logs:"
        $logs | each {|log|
            print $"  ($log.name)"
        }
    }
}

export def "main edit" [] {
    let mcp_dir = $"($env.HOME)/.mcp"
    let config_file = $"($mcp_dir)/mcp.json"
    let editor = $env.EDITOR? | default "nano"

    run-external $editor $config_file
}

export def "main add" [
    name: string
    command: string
    ...args: string
    --description(-d): string = ""
    --enabled(-e): bool = true
] {
    let mcp_dir = $"($env.HOME)/.mcp"
    let config_file = $"($mcp_dir)/mcp.json"
    let config = open $config_file

    if ($name in ($config | get mcpServers | columns)) {
        print $"Error: Server '($name)' already exists"
        exit 1
    }

    let new_server = {
        command: $command
        args: $args
        description: $description
        enabled: $enabled
    }

    let updated = $config | update mcpServers {|c|
        $c.mcpServers | insert $name $new_server
    }

    $updated | save -f $config_file
    print $"✓ Added server '($name)'"
}

export def "main remove" [name: string] {
    let mcp_dir = $"($env.HOME)/.mcp"
    let config_file = $"($mcp_dir)/mcp.json"
    let config = open $config_file

    if ($name not-in ($config | get mcpServers | columns)) {
        print $"Error: Server '($name)' not found"
        exit 1
    }

    print $"Remove server '($name)'?"
    let confirm = input "Type 'yes' to confirm: "

    if $confirm != "yes" {
        print "Cancelled"
        exit 0
    }

    let updated = $config | update mcpServers {|c|
        $c.mcpServers | reject $name
    }

    $updated | save -f $config_file
    print $"✓ Removed server '($name)'"
}

export def "main export" [client: string] {
    let mcp_dir = $"($env.HOME)/.mcp"
    let config = open $"($mcp_dir)/mcp.json" | get mcpServers

    let enabled_servers = $config | transpose name details | where {|s|
        $s.details | get -i enabled | default true
    } | reduce -f {} {|server, acc|
        $acc | insert $server.name ($server.details | reject enabled? description?)
    }

    let output = { mcpServers: $enabled_servers }

    match $client {
        "claude-desktop" => {
            $output | save -f $"($mcp_dir)/configs/claude-desktop.json"
            print $"✓ Exported to ($mcp_dir)/configs/claude-desktop.json"
        }
        "cline" => {
            let cline_format = $enabled_servers | transpose name details | reduce -f {} {|s, acc|
                $acc | insert $s.name ($s.details | insert disabled false)
            }
            { mcpServers: $cline_format } | save -f $"($mcp_dir)/configs/cline.json"
            print $"✓ Exported to ($mcp_dir)/configs/cline.json"
        }
        _ => {
            print $"Unknown client: ($client)"
            print "Supported: claude-desktop, cline"
            exit 1
        }
    }
}

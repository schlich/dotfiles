#!/usr/bin/env nu

def main [] {
    print "🚀 MCP Server Setup Script"
    print "=========================="
    print ""

    let mcp_dir = $"($env.HOME)/.mcp"

    print "Checking dependencies..."
    check_command "python3" "Install Python to use Python-based MCP servers"
    check_command "npx" "Install Node.js/npm to use official MCP servers (recommended)"
    print ""

    if (which npx | is-not-empty) {
        print "Testing MCP servers..."

        print -n "  Testing filesystem server... "
        try {
            npx -y @modelcontextprotocol/server-filesystem --help | complete | ignore
            print "✓"
        } catch {
            print "✓ (installed)"
        }

        print -n "  Testing git server... "
        try {
            npx -y @modelcontextprotocol/server-git --help | complete | ignore
            print "✓"
        } catch {
            print "✓ (installed)"
        }

        print ""
    }

    print "Setup options:"
    print ""
    print "1. Link config to current directory (for Claude Code CLI)"
    print "2. Setup for Claude Desktop"
    print "3. Show Cline/VSCode setup instructions"
    print "4. Test custom Python server"
    print "5. View configuration"
    print "0. Exit"
    print ""

    let choice = (input "Select option: ")

    match $choice {
        "1" => { link_config $mcp_dir }
        "2" => { setup_claude_desktop $mcp_dir }
        "3" => { show_cline_instructions $mcp_dir }
        "4" => { test_python_server $mcp_dir }
        "5" => { view_config $mcp_dir }
        "0" => {
            print "Goodbye!"
            exit 0
        }
        _ => {
            print "Invalid option"
            exit 1
        }
    }

    print ""
    print "Setup complete! 🎉"
    print ""
    print "Next steps:"
    print $"  - Read the guide: cat ($mcp_dir)/README.md"
    print $"  - Edit config: ($mcp_dir)/mcp.json"
    print "  - Add API keys for GitHub, Brave Search, etc."
    print ""
}

def check_command [cmd: string, msg: string] {
    if (which $cmd | is-not-empty) {
        print $"✓ ($cmd) found"
    } else {
        print $"✗ ($cmd) not found"
        print $"  ($msg)"
    }
}

def link_config [mcp_dir: string] {
    if ("mcp.json" | path exists) {
        print "mcp.json already exists in current directory"
        let confirm = (input "Overwrite? (y/N): ")
        if $confirm != "y" {
            print "Cancelled"
            exit 0
        }
    }

    ln -sf $"($mcp_dir)/mcp.json" ./mcp.json
    print $"✓ Linked ($mcp_dir)/mcp.json to ./mcp.json"
    print ""
    print "You can now use: claude"
}

def setup_claude_desktop [mcp_dir: string] {
    let os = (sys host | get name)

    let config_info = if $os == "Darwin" {
        {
            dir: $"($env.HOME)/Library/Application Support/Claude"
            file: $"($env.HOME)/Library/Application Support/Claude/claude_desktop_config.json"
        }
    } else {
        {
            dir: $"($env.HOME)/.config/Claude"
            file: $"($env.HOME)/.config/Claude/claude_desktop_config.json"
        }
    }

    mkdir $config_info.dir

    if ($config_info.file | path exists) {
        print "Claude Desktop config already exists"
        let confirm = (input "Backup and overwrite? (y/N): ")
        if $confirm == "y" {
            cp $config_info.file $"($config_info.file).backup"
            print $"✓ Backed up to ($config_info.file).backup"
        } else {
            print "Cancelled"
            exit 0
        }
    }

    cp $"($mcp_dir)/configs/claude-desktop.json" $config_info.file
    print $"✓ Installed config to ($config_info.file)"
    print ""
    print "Please restart Claude Desktop"
}

def show_cline_instructions [mcp_dir: string] {
    print ""
    print "Cline/VSCode Setup:"
    print "==================="
    print ""
    print "1. Open VSCode Settings (Ctrl+,)"
    print "2. Search for 'Cline MCP'"
    print "3. Click 'Edit in settings.json'"
    print "4. Add this configuration:"
    print ""
    open $"($mcp_dir)/configs/cline.json"
    print ""
    print $"Or copy from: ($mcp_dir)/configs/cline.json"
}

def test_python_server [mcp_dir: string] {
    if (which python3 | is-empty) {
        print "Python3 is required"
        exit 1
    }

    print ""
    print "Testing custom Python MCP server..."
    print "Enter 'quit' to exit"
    print ""

    python3 $"($mcp_dir)/servers/custom-example.py"
}

def view_config [mcp_dir: string] {
    print ""
    print "Main configuration:"
    open $"($mcp_dir)/mcp.json"
    print ""
}

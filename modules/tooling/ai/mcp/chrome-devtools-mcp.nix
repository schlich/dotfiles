# Chrome DevTools MCP server, for the clients that have no browser of their
# own. It is not in the shared `programs.mcp.servers`: each agent session
# starts its own copy, about 265 MB with its `npm exec` parent, and Claude
# Code already has the desktop app's browser and Claude in Chrome.
{
  command = "npx";
  args = [
    "-y"
    "chrome-devtools-mcp@latest"
  ];
}

"""A redacted teaching trace and its D2 sequence-diagram projection.

The trace follows MCP protocol revision 2026-07-28, the stateless revision
often called "MCP 2.0": no initialize handshake or session, per-request
_meta, cacheable list results, subscriptions/listen, and multi round-trip
requests (MRTR) in place of server-initiated requests.
"""

import subprocess


PROTOCOL_VERSION = "2026-07-28"

# Deliberately synthetic: never send real MCP payloads to the headset.
EVENTS = [
    {
        "id": "discover",
        "direction": "request",
        "method": "server/discover",
        "server": "Files",
        "requestId": 1,
        "summary": "Pick a protocol version up front",
        "detail": "There is no initialize handshake and no session. Discovery is optional; "
        "every request states its own version in _meta.",
    },
    {
        "id": "discover-result",
        "direction": "response",
        "method": "server/discover",
        "server": "Files",
        "requestId": 1,
        "summary": f"Supports {PROTOCOL_VERSION}; tools with listChanged",
        "detail": "resultType is complete and _meta carries serverInfo. "
        "This capability list is fabricated.",
    },
    {
        "id": "list",
        "direction": "request",
        "method": "tools/list",
        "server": "Files",
        "requestId": 2,
        "summary": "List available tools",
        "detail": "_meta carries io.modelcontextprotocol/protocolVersion, clientInfo, and "
        "clientCapabilities (elicitation). Over Streamable HTTP, the Mcp-Method "
        "header lets proxies route without parsing the body.",
    },
    {
        "id": "list-result",
        "direction": "response",
        "method": "tools/list",
        "server": "Files",
        "requestId": 2,
        "summary": "read_file, write_file · ttlMs 300000, cacheScope private",
        "detail": "A cacheable result: the client may reuse it for five minutes, and "
        "shared intermediaries must not cache it. Tools arrive in a deterministic order.",
    },
    {
        "id": "listen",
        "direction": "request",
        "method": "subscriptions/listen",
        "server": "Files",
        "requestId": 3,
        "summary": "Opt in to toolsListChanged",
        "detail": "A long-lived request replaces the old GET stream. It stays open, and "
        "its JSON-RPC ID becomes the subscription ID.",
    },
    {
        "id": "listen-ack",
        "direction": "notification",
        "method": "notifications/subscriptions/acknowledged",
        "server": "Files",
        "requestId": None,
        "subscriptionId": 3,
        "summary": "Server agrees to toolsListChanged",
        "detail": "The acknowledgment must be the first message on the stream and "
        "lists the notification types the server will honor.",
    },
    {
        "id": "call-files",
        "direction": "request",
        "method": "tools/call · read_file",
        "server": "Files",
        "requestId": 4,
        "summary": "Read a sample document",
        "detail": "Arguments are omitted from this redacted demonstration.",
    },
    {
        "id": "call-search",
        "direction": "request",
        "method": "tools/call · search",
        "server": "Search",
        "requestId": 5,
        "summary": "Search while the file call is pending",
        "detail": "No discovery step or handshake: the request carries its version in "
        "_meta, and the Search server accepts it on its own.",
    },
    {
        "id": "search-result",
        "direction": "response",
        "method": "tools/call · search",
        "server": "Search",
        "requestId": 5,
        "summary": "3 matches returned",
        "detail": "Request 5 completes before request 4; request IDs correlate the replies.",
    },
    {
        "id": "file-result",
        "direction": "response",
        "method": "tools/call · read_file",
        "server": "Files",
        "requestId": 4,
        "summary": "Document returned (content hidden)",
        "detail": "This is the response to request 4; contents are not included.",
    },
    {
        "id": "call-write",
        "direction": "request",
        "method": "tools/call · write_file",
        "server": "Files",
        "requestId": 6,
        "summary": "Save a summary over an existing file",
        "detail": "Arguments are omitted from this redacted demonstration.",
    },
    {
        "id": "input-required",
        "direction": "response",
        "method": "tools/call · write_file",
        "server": "Files",
        "requestId": 6,
        "resultType": "input_required",
        "summary": "input_required: confirm the overwrite",
        "detail": "Multi round-trip request: instead of sending its own elicitation/create "
        "request, the server returns it in inputRequests with an opaque requestState. "
        "Request 6 is now finished.",
    },
    {
        "id": "retry-write",
        "direction": "request",
        "method": "tools/call · write_file",
        "server": "Files",
        "requestId": 7,
        "summary": "Retry with inputResponses and requestState",
        "detail": "The retry uses a new JSON-RPC ID and echoes requestState unchanged. "
        "It carries everything the server needs, so any server instance can handle it.",
    },
    {
        "id": "write-result",
        "direction": "response",
        "method": "tools/call · write_file",
        "server": "Files",
        "requestId": 7,
        "summary": "Summary saved",
        "detail": "resultType is complete. The response answers the retry, request 7.",
    },
    {
        "id": "changed",
        "direction": "notification",
        "method": "notifications/tools/list_changed",
        "server": "Files",
        "requestId": None,
        "subscriptionId": 3,
        "summary": "Tool list changed",
        "detail": "The notification arrives on the subscriptions/listen stream tagged with "
        "subscriptionId 3. The client lists tools again instead of trusting its cache.",
    },
    {
        "id": "call-error",
        "direction": "request",
        "method": "tools/call · missing_tool",
        "server": "Files",
        "requestId": 8,
        "summary": "Call an unknown tool",
        "detail": "A deliberately invalid call to demonstrate failures.",
    },
    {
        "id": "error",
        "direction": "error",
        "method": "tools/call · missing_tool",
        "server": "Files",
        "requestId": 8,
        "errorCode": -32602,
        "summary": "Error -32602: unknown tool",
        "detail": "A protocol error for request 8 only. A tool that ran and failed would "
        "instead return a result with isError: true.",
    },
]


def diagram(step):
    """Render a bounded prefix of the fixture; no untrusted D2 is accepted."""
    if not 0 <= step < len(EVENTS):
        raise ValueError("Trace step is out of range")
    lines = [
        "shape: sequence_diagram",
        f'client: "MCP client · {PROTOCOL_VERSION}"',
        "files: Files server",
        "search: Search server",
    ]
    for event in EVENTS[: step + 1]:
        actor = "files" if event["server"] == "Files" else "search"
        direction = event["direction"]
        label = event["method"]
        if direction == "error":
            label = f"ERROR {event['errorCode']}"
        elif event.get("resultType"):
            label += " → " + event["resultType"]
        if event["requestId"] is not None:
            label += " #" + str(event["requestId"])
        if event.get("subscriptionId") is not None:
            label += f" (sub {event['subscriptionId']})"
        # Quote labels so D2 does not read "#" as the start of a comment.
        label = '"' + label.replace('"', '\\"') + '"'
        if direction == "request":
            lines.append(f"client -> {actor}: {label}")
        else:
            lines.append(f"{actor} -> client: {label}")
    try:
        result = subprocess.run(
            ["d2", "--theme=200", "-", "-"],
            input="\n".join(lines),
            capture_output=True,
            text=True,
            timeout=8,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise ValueError("D2 could not render the trace") from error
    return result.stdout.encode("utf-8")

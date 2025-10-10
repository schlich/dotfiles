#!/usr/bin/env python3
"""
Example custom MCP server in Python
This demonstrates how to create your own MCP server
"""
import asyncio
import json
from typing import Any

async def main():
    while True:
        try:
            line = input()
            if not line:
                continue
            
            request = json.loads(line)
            
            if request.get("method") == "tools/list":
                response = {
                    "jsonrpc": "2.0",
                    "id": request["id"],
                    "result": {
                        "tools": [
                            {
                                "name": "hello",
                                "description": "Says hello",
                                "inputSchema": {
                                    "type": "object",
                                    "properties": {
                                        "name": {
                                            "type": "string",
                                            "description": "Name to greet"
                                        }
                                    },
                                    "required": ["name"]
                                }
                            }
                        ]
                    }
                }
                print(json.dumps(response), flush=True)
            elif request.get("method") == "tools/call":
                tool_name = request["params"]["name"]
                if tool_name == "hello":
                    name = request["params"]["arguments"]["name"]
                    response = {
                        "jsonrpc": "2.0",
                        "id": request["id"],
                        "result": {
                            "content": [
                                {
                                    "type": "text",
                                    "text": f"Hello, {name}!"
                                }
                            ]
                        }
                    }
                    print(json.dumps(response), flush=True)
        except EOFError:
            break
        except Exception as e:
            print(f"Error: {e}", flush=True)

if __name__ == "__main__":
    asyncio.run(main())

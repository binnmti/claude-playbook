"""MCP server that wraps Codex CLI for cross-AI review."""

import os
import shutil
import subprocess
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("codex-review")


@mcp.tool()
def ask_codex(prompt: str, model: str = "gpt-5.4") -> str:
    """Send a prompt to Codex CLI and return the response.

    Args:
        prompt: The prompt to send to Codex.
        model: The model to use (default: gpt-5.4).
    """
    codex_cmd = shutil.which("codex")
    if not codex_cmd:
        return "[error] codex CLI not found in PATH"
    env = {**os.environ, "PYTHONUTF8": "1", "PYTHONIOENCODING": "utf-8"}
    try:
        result = subprocess.run(
            [codex_cmd, "exec", "-m", model, "-"],
            input=prompt,
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=env,
            timeout=300,
        )
        output = result.stdout.strip()
        if result.returncode != 0:
            err = result.stderr.strip()
            prefix = f"[error] codex exited with code {result.returncode}"
            if err:
                prefix += f"\n[stderr] {err}"
            return f"{prefix}\n{output}" if output else prefix
        return output if output else "[no output from codex]"
    except subprocess.TimeoutExpired:
        return "[error] codex timed out after 300 seconds"


if __name__ == "__main__":
    mcp.run()

#!/usr/bin/env nu

# Helper invoked from Helix to forward the current selection to an external AI CLI.
export def main [
  --tool(-t): string            # Override the tool to use for this invocation.
  --list-tools(-l)              # Print the configured tool names and exit.
  --dry-run(-n)                 # Show the command that would run without invoking it.
  --no-header                   # Suppress the header/prompt preview output.
] {
  let default_config = {
    default: "aider"
    ensure_trailing_newline: true
    show_header: true
    prompt_preview_lines: 3
    tools: {
      aider: {
        command: "aider"
        args: ["--message"]
        send: "arg"
        description: "Aider CLI (default)"
      }
      gemini: {
        command: "gemini"
        args: ["--output-format", "text", "--prompt"]
        send: "arg"
        description: "Google Gemini CLI"
      }
      claude: {
        command: "claude"
        args: ["--message"]
        send: "arg"
        description: "Anthropic Claude Code CLI (adjust flags as needed)"
      }
      codex: {
        command: "codex"
        args: ["chat", "--stdin"]
        send: "stdin"
        description: "OpenAI Codex CLI wrapper"
      }
      copilot: {
        command: "github-copilot-cli"
        args: ["chat", "--prompt"]
        send: "arg"
        description: "GitHub Copilot CLI"
      }
      aichat: {
        command: "aichat"
        args: ["--input", "-"]
        send: "stdin"
        description: "aichat CLI"
      }
      opencode: {
        command: "opencode"
        args: ["ask", "--stdin"]
        send: "stdin"
        description: "OpenCode CLI client"
      }
    }
  }

  let config_path = (
    try { $env.HOME } catch { "." }
    | path join ".config" "helix" "llm-tools.yaml"
  )

  let user_config = (try { open $config_path } catch { {} })
  let config = ($default_config | merge deep $user_config)

  if $list_tools {
    return ($config.tools | columns)
  }

  mut prompt = (
    try {
      open --raw /dev/stdin | into string
    } catch {
      ""
    }
  )

  if ($prompt | str length) == 0 {
    print "hx-llm: no selection provided"
    exit 0
  }

  $prompt = ($prompt | str replace --all "\r\n" "\n")

  if ($config.ensure_trailing_newline? | default false) and (($prompt | str ends-with "\n") == false) {
    $prompt = $"($prompt)\n"
  }
  let prompt_text = $prompt

  let env_tool = (try { $env.HX_LLM_TOOL } catch { "" })
  let resolved_tool = if (($tool | default "" | str length) > 0) {
    $tool
  } else if (($env_tool | str trim | is-empty) == false) {
    $env_tool
  } else {
    $config.default
  }

  if ($resolved_tool | str length) == 0 {
    error make { msg: "hx-llm: no tool configured; update llm-tools.yaml or pass --tool" }
  }

  let tools = ($config.tools? | default {})
  if ($tools | is-empty) {
    error make { msg: "hx-llm: no tools defined in configuration" }
  }

  let available_tools = ($tools | columns)
  let tool_known = ($available_tools | any {|name| $name == $resolved_tool })
  if not $tool_known {
    let known = ($available_tools | str join ", ")
    error make { msg: $"hx-llm: tool '($resolved_tool)' not found. Known tools: ($known)" }
  }

  let tool_cfg = ($tools | get $resolved_tool)
  let command = ($tool_cfg.command? | default "")
  if ($command | str length) == 0 {
    error make { msg: $"hx-llm: tool '($resolved_tool)' is missing a command" }
  }

  let send_mode = ($tool_cfg.send? | default "arg")
  let base_args = ($tool_cfg.args? | default [])

  let arg_state = (
    $base_args
    | reduce --fold {args: [], prompt_placeholder: false, file_placeholder: false} {|arg, acc|
        if $arg == "{prompt}" {
          {
            args: ($acc.args | append $prompt_text)
            prompt_placeholder: true
            file_placeholder: $acc.file_placeholder
          }
        } else if $arg == "{prompt-file}" {
          {
            args: ($acc.args | append "{prompt-file}")
            prompt_placeholder: $acc.prompt_placeholder
            file_placeholder: true
          }
        } else {
          {
            args: ($acc.args | append $arg)
            prompt_placeholder: $acc.prompt_placeholder
            file_placeholder: $acc.file_placeholder
          }
        }
      }
  )

  mut args = $arg_state.args
  let has_prompt_placeholder = $arg_state.prompt_placeholder
  let has_prompt_file_placeholder = $arg_state.file_placeholder

  mut tmp_prompt_file = ""
  if $send_mode == "file" {
    let template = ($tool_cfg.prompt_file_template? | default "hx-llm-XXXXXX")
    let suffix = ($tool_cfg.prompt_file_suffix? | default ".txt")
    let prompt_path = (mktemp --tmpdir --suffix $suffix $template)

    $prompt_text | save --force $prompt_path
    $tmp_prompt_file = $prompt_path

    if $has_prompt_file_placeholder {
      $args = (
        $args
        | each {|item| if $item == "{prompt-file}" { $prompt_path } else { $item } }
      )
    } else {
      $args = ($args | append $prompt_path)
    }
  } else if $has_prompt_file_placeholder {
    error make { msg: $"hx-llm: tool '($resolved_tool)' references {{prompt-file}} but send mode is '($send_mode)'" }
  }

  if ($send_mode == "arg") and (not $has_prompt_placeholder) {
    $args = ($args | append $prompt_text)
  }

  let env_overrides = ($tool_cfg.env? | default {})
  let header_enabled = if $no_header { false } else { $config.show_header? | default true }

  if $header_enabled {
    let preview_lines = ($config.prompt_preview_lines? | default 3)
    let prompt_lines = ($prompt_text | lines)
    let total_lines = ($prompt_lines | length)
    print $"# hx-llm => ($resolved_tool) :: ($command)"

    if $preview_lines > 0 and $total_lines > 0 {
      $prompt_lines
      | take $preview_lines
      | each {|line| print $"# > ($line)" }
      | null

      if $total_lines > $preview_lines {
        let remaining = $total_lines - $preview_lines
        print $"# ... and ($remaining) more lines"
      }
    }
  }

  if $dry_run {
    let cmd_preview = ([ $command ] | append $args | str join " ")
    print $"# dry-run: ($cmd_preview)"
    if (($tmp_prompt_file | str length) > 0) {
      print $"# prompt file: ($tmp_prompt_file)"
      try { rm $tmp_prompt_file } catch { null }
    }
    exit 0
  }

  let final_args = $args
  let run_command = {||
    if $send_mode == "stdin" {
      $prompt_text | run-external $command ...$final_args | complete
    } else if $send_mode == "file" {
      run-external $command ...$final_args | complete
    } else if $send_mode == "arg" {
      run-external $command ...$final_args | complete
    } else {
      error make { msg: $"hx-llm: unsupported send mode '($send_mode)'" }
    }
  }

  let result = if ($env_overrides | is-empty) {
    do $run_command
  } else {
    with-env $env_overrides { do $run_command }
  }

  if (($tmp_prompt_file | str length) > 0) {
    try { rm $tmp_prompt_file } catch { null }
  }

  if (($result.stdout | is-empty) == false) {
    print $result.stdout
  }

  if (($result.stderr | is-empty) == false) {
    print --stderr $result.stderr
  }

  if not $result.success {
    exit $result.exit_code
  }
}

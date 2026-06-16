def render-template [template_path: path, vars: record] {
  mut text = (open --raw $template_path)

  for item in ($vars | transpose key value) {
    let replacement = ($item.value | into string)
    $text = ($text | str replace --all $"<<($item.key)>>" $replacement)
  }

  $text
}

def maybe [value: any, default_value: any] {
  if $value == null { $default_value } else { $value }
}

def normalize-scope [value: string] {
  let scope = ($value | str downcase)

  if $scope in ["project" "user"] {
    $scope
  } else {
    error make {
      msg: $"Unsupported customizationScope '($value)'. Use 'project' or 'user'."
    }
  }
}

def is-nonempty-record [value: any] {
  (($value | describe | str starts-with "record") and (($value | columns | length) > 0))
}

def hook-summary [plugin_hooks: any, repo_hooks: any, repo_hook_file_name: string] {
  let has_plugin_hooks = (is-nonempty-record $plugin_hooks)
  let has_repo_hooks = (is-nonempty-record $repo_hooks)

  if $has_plugin_hooks and $has_repo_hooks {
    $"plugin hooks at hooks.json and repo hooks at .github/hooks/($repo_hook_file_name)"
  } else if $has_plugin_hooks {
    "plugin hooks at hooks.json"
  } else if $has_repo_hooks {
    $".github/hooks/($repo_hook_file_name)"
  } else {
    "none"
  }
}

def canonicalize [target_path: path] {
  $target_path | path expand
}

def path-is-within [parent: path, child: path] {
  let normalized_parent = (canonicalize $parent)
  let normalized_child = (canonicalize $child)

  ($normalized_child == $normalized_parent) or ($normalized_child | str starts-with $"($normalized_parent)/")
}

def looks-like-dotfiles-root [dir: path] {
  let root = (canonicalize $dir)

  (
    (($root | path join "home.nix") | path exists)
    and (($root | path join "copilot" "plugins" "project-plugin-factory") | path exists)
    and (($root | path join ".github" "plugin" "marketplace.json") | path exists)
  )
}

def resolve-dotfiles-repo-dir [spec: record] {
  if ($spec.dotfilesRepoDir? | default null) != null {
    return (canonicalize $spec.dotfilesRepoDir)
  }

  if ($env.PROJECT_PLUGIN_FACTORY_DOTFILES_REPO? | default null) != null {
    return (canonicalize $env.PROJECT_PLUGIN_FACTORY_DOTFILES_REPO)
  }

  let current_dir = (pwd)
  if (looks-like-dotfiles-root $current_dir) {
    return (canonicalize $current_dir)
  }

  error make {
    msg: "Unable to infer the dotfiles repo for a user-specific plugin. Set dotfilesRepoDir in the spec or PROJECT_PLUGIN_FACTORY_DOTFILES_REPO in the environment."
  }
}

def selected-host-root [spec: record, customization_scope: string] {
  if $customization_scope == "user" {
    resolve-dotfiles-repo-dir $spec
  } else {
    canonicalize (maybe ($spec.projectRepoDir?) (pwd))
  }
}

def ensure-parent [file_path: path] {
  let parent = ($file_path | path dirname)
  mkdir $parent
}

def write-template [template_path: path, destination: path, vars: record] {
  ensure-parent $destination
  render-template $template_path $vars | save --force $destination
}

def main [spec_path: path] {
  let spec = (open $spec_path)
  let base = ($env.FILE_PWD | path dirname | path dirname | path dirname)
  let plugin_root = ($base | path join "templates" "generated-plugin")
  let repo_root = ($base | path join "templates" "generated-repo")

  let customization_scope = (normalize-scope (maybe ($spec.customizationScope?) "project"))
  let project_name = ($spec.projectName)
  let plugin_name = ($spec.pluginName)
  let description = ($spec.description)
  let author_name = ($spec.authorName)
  let repository_url = (maybe ($spec.repositoryUrl?) "")
  let license = (maybe ($spec.license?) "MIT")
  let language = (maybe ($spec.language?) "project language")
  let workspace_root = (maybe ($spec.workspaceRoot?) ".")
  let build_command = (maybe ($spec.buildCommand?) "fill in build command")
  let test_command = (maybe ($spec.testCommand?) "fill in test command")
  let lint_command = (maybe ($spec.lintCommand?) "fill in lint command")
  let agent_name = (maybe ($spec.agentName?) $"($project_name) Specialist")
  let agent_description = (maybe ($spec.agentDescription?) $"Project specialist for ($project_name)")
  let skill_name = (maybe ($spec.skillName?) "project-workflow")
  let skill_description = (maybe ($spec.skillDescription?) $"Primary workflow for ($project_name)")
  let instructions_apply_to = (maybe ($spec.instructionsApplyTo?) "**")
  let prompt_description = (maybe ($spec.promptDescription?) "Use the generated Copilot workflow")
  let prompt_file_name = (maybe ($spec.promptFileName?) $"use-($plugin_name).prompt.md")
  let instructions_file_name = (maybe ($spec.instructionsFileName?) $"($plugin_name).instructions.md")
  let repo_hook_file_name = (maybe ($spec.repoHooksFileName?) $"($plugin_name).json")
  let notes = (maybe ($spec.notes?) "")
  let plugin_hooks = ($spec.pluginHooks? | default {})
  let repo_hooks = ($spec.repoHooks? | default {})

  let host_repo_root = (selected-host-root $spec $customization_scope)
  let scope_label = (if $customization_scope == "user" { "user-specific" } else { "project-specific" })
  let host_repo_label = (if $customization_scope == "user" { $"dotfiles repo at ($host_repo_root)" } else { $"project repo at ($host_repo_root)" })
  let hooks_summary = (hook-summary $plugin_hooks $repo_hooks $repo_hook_file_name)

  let plugin_output = (
    if ($spec.pluginOutputDir? | default null) != null {
      canonicalize $spec.pluginOutputDir
    } else {
      $host_repo_root | path join "copilot" "plugins" $plugin_name
    }
  )
  let overlay_output = (
    if ($spec.repoOverlayDir? | default null) != null {
      canonicalize $spec.repoOverlayDir
    } else {
      $host_repo_root
    }
  )

  if not (path-is-within $host_repo_root $plugin_output) {
    error make {
      msg: $"pluginOutputDir must stay inside the selected host repository. Host repo: ($host_repo_root). Plugin output: ($plugin_output)."
    }
  }

  if not (path-is-within $host_repo_root $overlay_output) {
    error make {
      msg: $"repoOverlayDir must stay inside the selected host repository. Host repo: ($host_repo_root). Overlay output: ($overlay_output)."
    }
  }

  mkdir $plugin_output
  mkdir $overlay_output
  mkdir ($plugin_output | path join "agents")
  mkdir ($plugin_output | path join "skills" $skill_name)
  mkdir ($overlay_output | path join ".github" "prompts")
  mkdir ($overlay_output | path join ".github" "instructions")
  mkdir ($overlay_output | path join ".github" "hooks")

  let keywords = (maybe ($spec.keywords?) ["github-copilot" $plugin_name])
  mut manifest = {
    name: $plugin_name
    description: $description
    version: "0.1.0"
    author: {
      name: $author_name
    }
    license: $license
    keywords: $keywords
    agents: ["./agents"]
    skills: [$"./skills/($skill_name)"]
  }

  if $repository_url != "" {
    $manifest = ($manifest | upsert repository $repository_url)
  }

  $manifest | to json --indent 2 | save --force ($plugin_output | path join "plugin.json")

  let vars = {
    PROJECT_NAME: $project_name
    PLUGIN_NAME: $plugin_name
    DESCRIPTION: $description
    LANGUAGE: $language
    AUTHOR_NAME: $author_name
    REPOSITORY_URL: $repository_url
    WORKSPACE_ROOT: $workspace_root
    BUILD_COMMAND: $build_command
    TEST_COMMAND: $test_command
    LINT_COMMAND: $lint_command
    AGENT_NAME: $agent_name
    AGENT_DESCRIPTION: $agent_description
    SKILL_NAME: $skill_name
    SKILL_DESCRIPTION: $skill_description
    CUSTOMIZATION_SCOPE_LABEL: $scope_label
    HOST_REPO_LABEL: $host_repo_label
    INSTRUCTIONS_APPLY_TO: $instructions_apply_to
    PROMPT_DESCRIPTION: $prompt_description
    PROMPT_FILE_NAME: $prompt_file_name
    INSTRUCTIONS_FILE_NAME: $instructions_file_name
    HOOKS_SUMMARY: $hooks_summary
    NOTES: $notes
  }

  write-template (
    $plugin_root | path join "agents" "project-specialist.agent.md.tmpl"
  ) (
    $plugin_output | path join "agents" "project-specialist.agent.md"
  ) $vars

  write-template (
    $plugin_root | path join "skills" "SKILL.md.tmpl"
  ) (
    $plugin_output | path join "skills" $skill_name "SKILL.md"
  ) $vars

  write-template (
    $repo_root | path join ".github" "prompts" "use-project-plugin.prompt.md.tmpl"
  ) (
    $overlay_output | path join ".github" "prompts" $prompt_file_name
  ) $vars

  write-template (
    $repo_root | path join ".github" "instructions" "copilot-customization.instructions.md.tmpl"
  ) (
    $overlay_output | path join ".github" "instructions" $instructions_file_name
  ) $vars

  if (is-nonempty-record ($spec.mcpServers? | default {})) {
    { mcpServers: $spec.mcpServers } | to json --indent 2 | save --force ($plugin_output | path join ".mcp.json")
  }

  if (is-nonempty-record ($spec.lspServers? | default {})) {
    { lspServers: $spec.lspServers } | to json --indent 2 | save --force ($plugin_output | path join "lsp.json")
  }

  if (is-nonempty-record $plugin_hooks) {
    $plugin_hooks | to json --indent 2 | save --force ($plugin_output | path join "hooks.json")
  }

  if (is-nonempty-record $repo_hooks) {
    $repo_hooks | to json --indent 2 | save --force ($overlay_output | path join ".github" "hooks" $repo_hook_file_name)
  }

  mut generated_files = [
    ($plugin_output | path join "plugin.json")
    ($plugin_output | path join "agents" "project-specialist.agent.md")
    ($plugin_output | path join "skills" $skill_name "SKILL.md")
    ($overlay_output | path join ".github" "prompts" $prompt_file_name)
    ($overlay_output | path join ".github" "instructions" $instructions_file_name)
  ]

  if (is-nonempty-record $plugin_hooks) {
    $generated_files = ($generated_files | append ($plugin_output | path join "hooks.json"))
  }

  if (is-nonempty-record $repo_hooks) {
    $generated_files = ($generated_files | append ($overlay_output | path join ".github" "hooks" $repo_hook_file_name))
  }

  {
    customization_scope: $customization_scope
    host_repo_root: $host_repo_root
    plugin_dir: $plugin_output
    overlay_dir: $overlay_output
    generated_files: $generated_files
  }
}

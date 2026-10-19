//! Gherkin features as skeleton input: each feature becomes a spec change,
//! and each of its scenarios a change that needs the spec and the components
//! its `@needs:<node>` tags name (`spec/Skeleton.qnt`).

use std::collections::BTreeSet;

use anyhow::{Context, Result, bail};
use gherkin::{Feature, GherkinEnv, Scenario, Step, Table};

/// The tag a scenario, rule, or feature names a component with.
pub const NEEDS_TAG: &str = "needs:";

/// One feature file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FeatureSpec {
    /// The file's path in the workspace, which its spec change adds.
    pub path: String,
    /// The file's stem, used in titles: `spec(<slug>)`, `feat(<slug>)`.
    pub slug: String,
    pub name: String,
    pub description: Option<String>,
    pub scenarios: Vec<ScenarioSpec>,
}

/// One scenario (or scenario outline).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScenarioSpec {
    pub name: String,
    pub description: Option<String>,
    /// Components it needs: its own `@needs:` tags, its rule's, and its
    /// feature's.
    pub needs: BTreeSet<String>,
    /// Its steps, background first, as written.
    pub steps: Vec<String>,
}

fn needs_of(tags: &[String]) -> impl Iterator<Item = String> + '_ {
    tags.iter()
        .filter_map(|t| t.strip_prefix(NEEDS_TAG))
        .map(str::to_owned)
}

fn table_lines(t: &Table, indent: &str) -> Vec<String> {
    t.rows
        .iter()
        .map(|row| format!("{indent}| {} |", row.join(" | ")))
        .collect()
}

fn step_lines(s: &Step) -> Vec<String> {
    let mut out = vec![format!("{}{}", s.keyword, s.value).trim_end().to_owned()];
    if let Some(doc) = &s.docstring {
        out.push("  \"\"\"".into());
        out.extend(doc.lines().map(|l| format!("  {l}")));
        out.push("  \"\"\"".into());
    }
    if let Some(t) = &s.table {
        out.extend(table_lines(t, "  "));
    }
    out
}

fn scenario(s: &Scenario, background: &[Step], outer: &[String]) -> ScenarioSpec {
    let mut steps: Vec<String> = background.iter().flat_map(step_lines).collect();
    steps.extend(s.steps.iter().flat_map(step_lines));
    for ex in &s.examples {
        steps.push(format!("{}:", ex.keyword.trim()));
        if let Some(t) = &ex.table {
            steps.extend(table_lines(t, "  "));
        }
    }
    ScenarioSpec {
        name: s.name.trim().to_owned(),
        description: s
            .description
            .as_ref()
            .map(|d| d.trim().to_owned())
            .filter(|d| !d.is_empty()),
        needs: needs_of(&s.tags).chain(needs_of(outer)).collect(),
        steps,
    }
}

/// Read a feature file. `path` is its path in the workspace.
pub fn read_feature(path: &str, text: &str) -> Result<FeatureSpec> {
    let feature = Feature::parse(text, GherkinEnv::default())
        .map_err(|e| anyhow::anyhow!("{path}: not a Gherkin feature: {e}"))?;
    let slug = std::path::Path::new(path)
        .file_stem()
        .and_then(|s| s.to_str())
        .context("a feature file needs a name")?
        .to_owned();
    let background: Vec<Step> = feature
        .background
        .iter()
        .flat_map(|b| b.steps.clone())
        .collect();
    let mut scenarios: Vec<ScenarioSpec> = feature
        .scenarios
        .iter()
        .map(|s| scenario(s, &background, &feature.tags))
        .collect();
    for rule in &feature.rules {
        let mut steps = background.clone();
        steps.extend(rule.background.iter().flat_map(|b| b.steps.clone()));
        let tags: Vec<String> = feature.tags.iter().chain(&rule.tags).cloned().collect();
        scenarios.extend(rule.scenarios.iter().map(|s| scenario(s, &steps, &tags)));
    }
    let mut seen = BTreeSet::new();
    for s in &scenarios {
        if s.name.is_empty() {
            bail!("{path}: a scenario has no name");
        }
        if !seen.insert(&s.name) {
            bail!(
                "{path}: two scenarios are named {:?}; a rerun could not tell them apart",
                s.name
            );
        }
    }
    let name = if feature.name.trim().is_empty() {
        slug.clone()
    } else {
        feature.name.trim().to_owned()
    };
    Ok(FeatureSpec {
        path: path.to_owned(),
        slug,
        name,
        description: feature
            .description
            .map(|d| d.trim().to_owned())
            .filter(|d| !d.is_empty()),
        scenarios,
    })
}

impl FeatureSpec {
    /// The spec change's description.
    pub fn spec_description(&self) -> String {
        let mut out = format!("spec({}): {}\n", self.slug, self.name);
        if let Some(d) = &self.description {
            out.push_str(&format!("\n{d}\n"));
        }
        out.push_str("\nScenarios:\n");
        for s in &self.scenarios {
            out.push_str(&format!("- {}\n", s.name));
        }
        out
    }

    /// A scenario's change's description.
    pub fn scenario_description(&self, s: &ScenarioSpec) -> String {
        let mut out = format!("feat({}): {}\n", self.slug, s.name);
        if let Some(d) = &s.description {
            out.push_str(&format!("\n{d}\n"));
        }
        if !s.steps.is_empty() {
            out.push('\n');
            for line in &s.steps {
                out.push_str(line);
                out.push('\n');
            }
        }
        out
    }
}

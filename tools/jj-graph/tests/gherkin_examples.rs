//! Reading Gherkin features into skeleton input, and planning a skeleton
//! from a diagram and features.

use std::collections::BTreeSet;

use jj_graph::dot;
use jj_graph::gherkin::read_feature;
use jj_graph::skeleton::{Kind, plan, scenario_node, spec_node};

const LOGIN: &str = r#"# The login flow, end to end.
@needs:engine
Feature: Login
  Users sign in with a password.

  Background:
    Given a user "ada" with password "lovelace"

  @needs:cli
  Scenario: Signing in
    When ada signs in with "lovelace"
    Then she sees her dashboard

  Scenario Outline: Wrong passwords
    When ada signs in with "<password>"
    Then she sees "<message>"

    Examples:
      | password | message        |
      | x        | wrong password |

  @needs:db_adapter
  Rule: Locking
    Background:
      Given ada failed to sign in 3 times

    Scenario: Locked out
      When ada signs in with "lovelace"
      Then she sees:
        """
        Your account is locked.
        """
"#;

fn set(items: &[&str]) -> BTreeSet<String> {
    items.iter().map(|s| s.to_string()).collect()
}

#[test]
fn a_feature_reads_into_scenarios_with_their_needs_and_steps() {
    let f = read_feature("features/login.feature", LOGIN).unwrap();
    assert_eq!(f.slug, "login");
    assert_eq!(f.name, "Login");
    assert_eq!(
        f.description.as_deref(),
        Some("Users sign in with a password.")
    );
    let names: Vec<&str> = f.scenarios.iter().map(|s| s.name.as_str()).collect();
    assert_eq!(names, ["Signing in", "Wrong passwords", "Locked out"]);
    assert_eq!(f.scenarios[0].needs, set(&["engine", "cli"]));
    assert_eq!(f.scenarios[1].needs, set(&["engine"]));
    assert_eq!(f.scenarios[2].needs, set(&["engine", "db_adapter"]));
    assert_eq!(
        f.scenarios[0].steps,
        [
            "Given a user \"ada\" with password \"lovelace\"",
            "When ada signs in with \"lovelace\"",
            "Then she sees her dashboard",
        ]
    );
    assert!(
        f.scenarios[1]
            .steps
            .contains(&"  | x | wrong password |".to_owned()),
        "{:?}",
        f.scenarios[1].steps
    );
    assert_eq!(
        f.scenarios[2].steps[1],
        "Given ada failed to sign in 3 times"
    );
    assert!(
        f.scenarios[2]
            .steps
            .contains(&"  Your account is locked.".to_owned()),
        "{:?}",
        f.scenarios[2].steps
    );
}

#[test]
fn descriptions_carry_the_scenarios_and_their_steps() {
    let f = read_feature("features/login.feature", LOGIN).unwrap();
    let spec = f.spec_description();
    assert!(spec.starts_with("spec(login): Login\n"));
    assert!(spec.contains("- Signing in\n- Wrong passwords\n- Locked out\n"));
    let first = f.scenario_description(&f.scenarios[0]);
    assert!(first.starts_with("feat(login): Signing in\n\nGiven a user"));
}

#[test]
fn duplicate_scenarios_and_unknown_needs_are_refused() {
    let twice = "Feature: F\n  Scenario: A\n    Given x\n  Scenario: A\n    Given y\n";
    assert!(read_feature("f.feature", twice).is_err());
    let f = read_feature("features/login.feature", LOGIN).unwrap();
    let diagram = dot::parse("digraph { engine -> cli }").unwrap();
    let err = plan(&diagram, &[f]).unwrap_err();
    assert!(format!("{err}").contains("db_adapter"), "{err}");
}

#[test]
fn scenarios_land_on_their_spec_and_what_they_need() {
    let diagram = dot::parse(
        "digraph { types -> db_adapter; types -> engine; db_adapter -> engine; engine -> cli }",
    )
    .unwrap();
    let f = read_feature("features/login.feature", LOGIN).unwrap();
    let s = plan(&diagram, std::slice::from_ref(&f)).unwrap();
    let spec = spec_node(&f);
    assert_eq!(
        s.kinds[&spec],
        Kind::Spec {
            path: "features/login.feature".into()
        }
    );
    assert!(s.parents[&spec].is_empty(), "a spec is a root");
    // engine and cli: cli already builds on engine.
    assert_eq!(
        s.parents[&scenario_node(&f, 0)],
        set(&["spec:login", "cli"])
    );
    assert_eq!(
        s.parents[&scenario_node(&f, 1)],
        set(&["spec:login", "engine"])
    );
    // engine and db_adapter: engine already builds on db_adapter.
    assert_eq!(
        s.parents[&scenario_node(&f, 2)],
        set(&["spec:login", "engine"])
    );
}

#[test]
fn spec_and_scenario_nodes_never_share_a_name() {
    let diagram = dot::parse("digraph { core }").unwrap();
    let spec = read_feature(
        "spec.feature",
        "Feature: Spec\n  Scenario: First\n    When x\n",
    )
    .unwrap();
    let zero = read_feature(
        "0.feature",
        "Feature: Zero\n  Scenario: Other\n    When y\n",
    )
    .unwrap();
    let s = plan(&diagram, &[spec.clone(), zero.clone()]).unwrap();
    let nodes: BTreeSet<String> = [
        spec_node(&spec),
        scenario_node(&spec, 0),
        spec_node(&zero),
        scenario_node(&zero, 0),
    ]
    .into();
    assert_eq!(nodes.len(), 4);
    assert!(
        nodes.iter().all(|n| s.kinds.contains_key(n)),
        "{:?}",
        s.kinds.keys()
    );
}

#[test]
fn a_scenario_that_names_nothing_needs_the_surface_layer() {
    let diagram = dot::parse("digraph { core -> {api cli} }").unwrap();
    let f = read_feature(
        "search.feature",
        "Feature: Search\n  Scenario: Find\n    When I search\n",
    )
    .unwrap();
    let s = plan(&diagram, std::slice::from_ref(&f)).unwrap();
    assert_eq!(
        s.parents[&scenario_node(&f, 0)],
        set(&["spec:search", "api", "cli"])
    );
}

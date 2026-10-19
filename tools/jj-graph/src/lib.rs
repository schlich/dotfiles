//! jj-graph: plan, check, and normalize Jujutsu change graphs against the
//! code's dependency graph.
//!
//! `graph` and `plan` are the pure core that `spec/Normalize.qnt` specifies.
//! `diff` and `extract` read what each change defines and references, `jj`
//! and `load` read a repository into a graph, and `apply` rewrites it as one
//! operation (`spec/Apply.qnt`). `hoist` is the diff editor that splits
//! changes, `dot`, `gherkin`, and `skeleton` build ghost graphs from Graphviz
//! diagrams and Gherkin features (`spec/Skeleton.qnt`), and `shapes` and
//! `checks` act on boundary shapes.

pub mod apply;
pub mod checks;
pub mod diff;
pub mod dot;
pub mod extract;
pub mod gherkin;
pub mod graph;
pub mod hoist;
pub mod jj;
pub mod load;
pub mod plan;
pub mod shapes;
pub mod skeleton;

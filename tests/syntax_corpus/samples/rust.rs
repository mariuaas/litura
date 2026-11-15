//! Rust: raw strings, nested comments, lifetimes, macros, generics. Ünïcode ✓
use std::collections::HashMap;
use std::fmt;

/* outer /* nested */ comment */
#[derive(Debug, Clone, PartialEq)]
pub enum Shape<'a> {
    Circle { radius: f64 },
    Named(&'a str),
    Unit,
}

impl<'a> fmt::Display for Shape<'a> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Shape::Circle { radius } if *radius > 0.0 => write!(f, "circle {radius}"),
            Shape::Circle { .. } => write!(f, "empty"),
            Shape::Named(name) => write!(f, "{}", name),
            Shape::Unit => f.write_str("unit"),
        }
    }
}

macro_rules! square {
    ($x:expr) => {
        $x * $x
    };
}

pub fn count<'s, I>(items: I) -> HashMap<&'s str, usize>
where
    I: IntoIterator<Item = &'s str>,
{
    let mut counts = HashMap::new();
    for item in items {
        *counts.entry(item).or_insert(0) += 1;
    }
    counts
}

fn main() {
    let raw = r#"a "raw" string — ünïcode"#;
    let bytes = b"bytes\n";
    let ch = '\u{1F600}';
    let shapes = vec![Shape::Circle { radius: 1.5 }, Shape::Named("x"), Shape::Unit];
    let total: f64 = shapes.iter().filter_map(|s| match s {
        Shape::Circle { radius } => Some(square!(*radius)),
        _ => None,
    }).sum();
    println!("{raw} {:?} {ch} {total:.2} {}", bytes, count(["a", "b", "a"]).len());
    'outer: loop {
        break 'outer;
    }
}

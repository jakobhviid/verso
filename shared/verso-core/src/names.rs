//! The order of names. It is the person's language's, which only the platform knows, so the arrangements that sort by
//! name (`places`, `albums`) take it as a function: the Mac and the iPhone hand over each name's place in Finder's
//! order through `verso-bridge`, and Linux's window orders by lower-case letters.

use std::cmp::Ordering;

/// Names in the order of their lower-case letters, as Linux's window orders them.
pub fn caseless(first: &str, second: &str) -> Ordering {
    first.to_lowercase().cmp(&second.to_lowercase())
}

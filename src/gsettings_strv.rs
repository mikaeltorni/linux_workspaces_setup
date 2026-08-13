//! GSettings string-array helpers (`wss-tools append|remove <value>`).

use std::collections::HashSet;
use std::env;

use crate::logging;

/// Parse `gsettings get` string-array output into normalized values.
///
/// Unparseable input yields an empty list, matching the former Python helper.
///
/// # Parameters
/// - `raw`: Optional `gsettings get` output (`@as [...]` or `[...]`).
pub fn parse_strv(raw: Option<&str>) -> Vec<String> {
    let mut value = raw.unwrap_or("").trim().to_string();
    if let Some(rest) = value.strip_prefix("@as ") {
        value = rest.trim().to_string();
    }
    if value.is_empty() {
        return Vec::new();
    }
    match pythonish_list(&value) {
        Some(items) => items,
        None => {
            logging::warn("Unparsable GSettings string-array value; using []");
            Vec::new()
        }
    }
}

fn pythonish_list(value: &str) -> Option<Vec<String>> {
    let value = value.trim();
    if !value.starts_with('[') || !value.ends_with(']') {
        return None;
    }
    let inner = value[1..value.len() - 1].trim();
    if inner.is_empty() {
        return Some(Vec::new());
    }

    let mut items = Vec::new();
    let mut chars = inner.chars().peekable();
    while let Some(&ch) = chars.peek() {
        if ch.is_whitespace() || ch == ',' {
            chars.next();
            continue;
        }
        let quote = chars.next()?;
        if quote != '\'' && quote != '"' {
            return None;
        }
        let mut out = String::new();
        let mut closed = false;
        while let Some(c) = chars.next() {
            if c == '\\' {
                let escaped = chars.next()?;
                out.push(escaped);
                continue;
            }
            if c == quote {
                closed = true;
                break;
            }
            out.push(c);
        }
        if !closed {
            return None;
        }
        items.push(out);
    }
    Some(items)
}

/// De-duplicate while preserving first appearance.
pub fn unique_values(values: Vec<String>) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for v in values {
        if seen.insert(v.clone()) {
            out.push(v);
        }
    }
    out
}

/// Append `value` when non-empty and not already present.
pub fn append_strv(raw: Option<&str>, value: &str) -> Vec<String> {
    let mut current = unique_values(parse_strv(raw));
    if !value.is_empty() && !current.iter().any(|item| item == value) {
        current.push(value.to_string());
    }
    current
}

/// Remove every occurrence of `value`.
pub fn remove_strv(raw: Option<&str>, value: &str) -> Vec<String> {
    parse_strv(raw)
        .into_iter()
        .filter(|item| item != value)
        .collect()
}

/// Serialize values for `gsettings set` (Python `repr` style single quotes).
pub fn format_strv(values: &[String]) -> String {
    let parts: Vec<String> = values
        .iter()
        .map(|item| format!("'{}'", item.replace('\\', "\\\\").replace('\'', "\\'")))
        .collect();
    format!("[{}]", parts.join(", "))
}

/// CLI entry: `append|remove <value>` reading `CURRENT` from the environment.
///
/// # Returns
/// `0` after printing the serialized array. `2` on usage errors.
pub fn run_cli() -> i32 {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.len() != 2 || (args[0] != "append" && args[0] != "remove") {
        logging::error("Usage: wss-tools append|remove <value>");
        eprintln!("Usage: wss-tools append|remove <value>");
        return 2;
    }
    let action = &args[0];
    let value = &args[1];
    let current = env::var("CURRENT").unwrap_or_default();
    logging::info(format!("wss-tools {action} value={value}"));
    let result = if action == "append" {
        append_strv(Some(&current), value)
    } else {
        remove_strv(Some(&current), value)
    };
    println!("{}", format_strv(&result));
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn append_dedupes_and_preserves_order() {
        assert_eq!(append_strv(Some("['a']"), "a"), vec!["a".to_string()]);
        assert_eq!(
            append_strv(Some("@as ['one']"), "two"),
            vec!["one".to_string(), "two".to_string()]
        );
    }

    #[test]
    fn remove_drops_all_matches() {
        assert_eq!(
            remove_strv(
                Some("['a', 'linux-workspaces-setup@local']"),
                "linux-workspaces-setup@local"
            ),
            vec!["a".to_string()]
        );
    }

    #[test]
    fn invalid_existing_values_become_empty() {
        assert_eq!(
            append_strv(Some("not an array"), "linux-workspaces-setup@local"),
            vec!["linux-workspaces-setup@local".to_string()]
        );
    }

    #[test]
    fn format_matches_gsettings_literal() {
        assert_eq!(format_strv(&["a".into(), "b".into()]), "['a', 'b']");
    }
}

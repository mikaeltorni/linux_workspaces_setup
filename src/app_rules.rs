//! Native serializer for independent sticky and monitor app-rule dimensions.
use serde_json::{json, Map, Value};
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

type Group = Vec<String>;
type Assignments = Vec<(Group, Value)>;

enum Operation {
    Write {
        sticky: Vec<Group>,
        monitors: Assignments,
        layout: Map<String, Value>,
        managed_sticky: bool,
        managed_monitors: bool,
    },
    ListSticky,
    ListMonitors(Assignments),
    Help,
}

struct Parsed {
    file: PathBuf,
    operation: Operation,
}

struct Document {
    rules: Vec<Map<String, Value>>,
    managed: BTreeSet<String>,
}

/// Split nonempty desktop candidates without trimming their application IDs.
/// Parameters: raw - semicolon groups containing pipe-separated desktop candidates.
/// Returns: ordered nonempty groups.
fn parse_groups(raw: &str) -> Vec<Group> {
    raw.split(';')
        .map(|group| {
            group
                .split('|')
                .filter(|id| !id.is_empty())
                .map(str::to_string)
                .collect::<Group>()
        })
        .filter(|group| !group.is_empty())
        .collect()
}

/// Parse Python-style signed decimal integer operands, including valid underscores.
/// Parameters: raw - numeric assignment or layout cell.
/// Returns: exact JSON integer or none for malformed text.
fn parse_integer(raw: &str) -> Option<Value> {
    let raw = raw.trim();
    let negative = raw.starts_with('-');
    let digits = raw.strip_prefix(['-', '+']).unwrap_or(raw);
    if digits.is_empty() {
        return None;
    }
    let chars: Vec<char> = digits.chars().collect();
    for (index, ch) in chars.iter().enumerate() {
        if ch.is_ascii_digit() {
            continue;
        }
        if *ch != '_'
            || index == 0
            || index + 1 == chars.len()
            || !chars[index - 1].is_ascii_digit()
            || !chars[index + 1].is_ascii_digit()
        {
            return None;
        }
    }
    let digits = digits.replace('_', "");
    let digits = digits.trim_start_matches('0');
    let digits = if digits.is_empty() { "0" } else { digits };
    let normalized = if negative && digits != "0" {
        format!("-{digits}")
    } else {
        digits.to_string()
    };
    serde_json::from_str(&normalized).ok()
}

/// Parse valid positive monitor assignments while skipping malformed entries.
/// Parameters: raw - semicolon-separated group=monitor operands.
/// Returns: ordered positive assignments.
fn parse_assignments(raw: &str) -> Assignments {
    raw.split(';')
        .filter_map(|entry| {
            let (group, value) = entry.rsplit_once('=')?;
            let group: Group = group
                .split('|')
                .filter(|id| !id.is_empty())
                .map(str::to_string)
                .collect();
            let monitor = parse_integer(value)?;
            let number = monitor.to_string();
            if group.is_empty() || number.starts_with('-') || number == "0" {
                None
            } else {
                Some((group, monitor))
            }
        })
        .collect()
}

/// Parse valid display rows with exact connector and geometry metadata.
/// Parameters: raw - numbered monitor TSV from the shared display owner.
/// Returns: monitor-number keys and connector/geometry objects.
fn parse_layout(raw: &str) -> Map<String, Value> {
    let mut layout = Map::new();
    for line in raw.lines() {
        let fields: Vec<&str> = line.split('\t').collect();
        if fields.len() < 8 {
            continue;
        }
        let Some(number) = parse_integer(fields[0]) else {
            continue;
        };
        let geometry: Option<Vec<Value>> = fields[4..8]
            .iter()
            .map(|cell| parse_integer(cell))
            .collect();
        let Some(geometry) = geometry else {
            continue;
        };
        layout.insert(number.to_string(), json!({"connector":fields[1],"geometry":{"x":geometry[0],"y":geometry[1],"width":geometry[2],"height":geometry[3]}}));
    }
    layout
}

/// Consume one string operand without swallowing the next command flag.
/// Parameters: args - command tokens; index - option index to advance; inline - optional equals operand.
/// Returns: operand or argument-shape diagnostic.
fn operand(args: &[String], index: &mut usize, inline: Option<&str>) -> Result<String, String> {
    if let Some(value) = inline {
        return Ok(value.to_string());
    }
    *index += 1;
    let value = args
        .get(*index)
        .ok_or_else(|| "missing option operand".to_string())?;
    if value.starts_with("--") || value == "-h" {
        return Err("missing option operand".into());
    }
    Ok(value.clone())
}

/// Parse every app-rule command and its operands before dispatch or file writes.
/// Parameters: args - raw CLI argument tokens.
/// Returns: typed operation and file path or command-shape diagnostic.
fn parse(args: &[String]) -> Result<Parsed, String> {
    let mut index = 0;
    let mut file = None;
    while index < args.len() {
        let (flag, inline) = args[index]
            .split_once('=')
            .map(|(flag, value)| (flag, Some(value)))
            .unwrap_or((&args[index], None));
        match flag {
            "--file" => file = Some(PathBuf::from(operand(args, &mut index, inline)?)),
            "-h" | "--help" => {
                return Ok(Parsed {
                    file: PathBuf::new(),
                    operation: Operation::Help,
                })
            }
            _ => break,
        }
        index += 1;
    }
    let file = file.ok_or_else(|| "--file is required".to_string())?;
    let command = args
        .get(index)
        .ok_or_else(|| "an operation is required".to_string())?;
    if !["write", "list-sticky", "list-monitors"].contains(&command.as_str()) {
        return Err(format!("unknown operation {command}"));
    }
    index += 1;
    let mut sticky = String::new();
    let mut monitors = String::new();
    let mut layout = String::new();
    let mut legacy = String::new();
    let mut managed_sticky = false;
    let mut managed_monitors = false;
    while index < args.len() {
        let (flag, inline) = args[index]
            .split_once('=')
            .map(|(flag, value)| (flag, Some(value)))
            .unwrap_or((&args[index], None));
        match (command.as_str(), flag) {
            (_, "-h" | "--help") => {
                return Ok(Parsed {
                    file,
                    operation: Operation::Help,
                })
            }
            ("write", "--sticky") => sticky = operand(args, &mut index, inline)?,
            ("write", "--monitors") => monitors = operand(args, &mut index, inline)?,
            ("write", "--monitor-layout") => layout = operand(args, &mut index, inline)?,
            ("write", "--managed-sticky") if inline.is_none() => managed_sticky = true,
            ("write", "--managed-monitors") if inline.is_none() => managed_monitors = true,
            ("list-monitors", "--legacy-defaults") => legacy = operand(args, &mut index, inline)?,
            _ => return Err(format!("unexpected operand {}", args[index])),
        }
        index += 1;
    }
    let operation = match command.as_str() {
        "write" => Operation::Write {
            sticky: parse_groups(&sticky),
            monitors: parse_assignments(&monitors),
            layout: parse_layout(&layout),
            managed_sticky,
            managed_monitors,
        },
        "list-sticky" => Operation::ListSticky,
        _ => Operation::ListMonitors(parse_assignments(&legacy)),
    };
    Ok(Parsed { file, operation })
}

/// Read valid stored rule objects and explicit management markers leniently.
/// Parameters: path - installer-owned user-rules JSON file.
/// Returns: valid rule objects/markers, empty when missing or malformed.
fn read_document(path: &Path) -> Document {
    let value: Value = fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or(Value::Null);
    let rules = value
        .get("rules")
        .and_then(Value::as_array)
        .map(|rules| {
            rules
                .iter()
                .filter_map(|rule| {
                    let object = rule.as_object()?;
                    object.get("appIds")?.as_array()?;
                    Some(object.clone())
                })
                .collect()
        })
        .unwrap_or_default();
    let managed = ["sticky", "monitors"]
        .into_iter()
        .filter(|name| {
            value.get("managed").and_then(|value| value.get(*name)) == Some(&Value::Bool(true))
        })
        .map(str::to_string)
        .collect();
    Document { rules, managed }
}

/// Apply the original truth test to stored JSON dimension values.
/// Parameters: value - optional dimension value.
/// Returns: whether the stored dimension is active.
fn truthy(value: Option<&Value>) -> bool {
    match value {
        None | Some(Value::Null) | Some(Value::Bool(false)) => false,
        Some(Value::Bool(true)) => true,
        Some(Value::Number(number)) => number.as_f64() != Some(0.0),
        Some(Value::String(text)) => !text.is_empty(),
        Some(Value::Array(values)) => !values.is_empty(),
        Some(Value::Object(values)) => !values.is_empty(),
    }
}

/// Validate application group text needed for identity and monitor output.
/// Parameters: rule - stored rule with an appIds array.
/// Returns: desktop ID strings or malformed-group failure.
fn app_ids(rule: &Map<String, Value>) -> Result<Group, String> {
    rule["appIds"]
        .as_array()
        .unwrap()
        .iter()
        .map(|id| {
            id.as_str()
                .map(str::to_string)
                .ok_or_else(|| "application IDs must be strings".to_string())
        })
        .collect()
}

/// Identify one application independently of candidate order and capitalization.
/// Parameters: ids - desktop candidates.
/// Returns: case-insensitive sorted group identity.
fn group_key(ids: &[String]) -> String {
    let mut ids: Vec<String> = ids.iter().map(|id| id.to_lowercase()).collect();
    ids.sort();
    ids.join("|")
}

/// Find or create the ordered merge slot for an application group.
/// Parameters: slots - ordered accumulated rules; ids - desktop group candidates.
/// Returns: mutable rule object for this group.
fn slot<'a>(slots: &'a mut Map<String, Value>, ids: &[String]) -> &'a mut Map<String, Value> {
    slots
        .entry(group_key(ids))
        .or_insert_with(|| json!({"appIds":ids}))
        .as_object_mut()
        .unwrap()
}

/// Merge only the dimensions this write explicitly manages.
/// Parameters: existing - prior rule objects; sticky - selected sticky groups; monitors - selected monitor assignments; layout - parsed monitor metadata; managed_sticky - whether sticky is replaced; managed_monitors - whether monitors are replaced.
/// Returns: ordered nonempty rules or malformed stored-group failure.
fn merge(
    existing: &[Map<String, Value>],
    sticky: &[Group],
    monitors: &Assignments,
    layout: &Map<String, Value>,
    managed_sticky: bool,
    managed_monitors: bool,
) -> Result<Vec<Value>, String> {
    let mut slots = Map::new();
    for rule in existing {
        let ids = app_ids(rule)?;
        let entry = slot(&mut slots, &ids);
        if !managed_sticky && truthy(rule.get("sticky")) {
            entry.insert("sticky".into(), Value::Bool(true));
        }
        if !managed_monitors && truthy(rule.get("monitor")) {
            entry.insert("monitor".into(), rule["monitor"].clone());
            if truthy(rule.get("monitorConnector")) {
                entry.insert("monitorConnector".into(), rule["monitorConnector"].clone());
            }
            if rule
                .get("monitorGeometry")
                .and_then(Value::as_object)
                .is_some()
            {
                entry.insert("monitorGeometry".into(), rule["monitorGeometry"].clone());
            }
        }
    }
    if managed_sticky {
        for ids in sticky {
            slot(&mut slots, ids).insert("sticky".into(), Value::Bool(true));
        }
    }
    if managed_monitors {
        for (ids, monitor) in monitors {
            let entry = slot(&mut slots, ids);
            entry.insert("monitor".into(), monitor.clone());
            if let Some(details) = layout.get(&monitor.to_string()) {
                entry.insert("monitorConnector".into(), details["connector"].clone());
                entry.insert("monitorGeometry".into(), details["geometry"].clone());
            }
        }
    }
    Ok(slots
        .into_iter()
        .map(|(_, rule)| rule)
        .filter(|rule| rule.as_object().unwrap().len() > 1)
        .collect())
}

/// Write the original ASCII JSON representation via an atomic sibling replacement.
/// Parameters: path - destination; document - ordered rules/markers object.
/// Returns: success or filesystem/serialization error.
fn write_document(path: &Path, document: &Value) -> Result<(), String> {
    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let text = serde_json::to_string_pretty(document).map_err(|error| error.to_string())?;
    let mut ascii = String::new();
    for ch in text.chars() {
        if ch <= '\u{7e}' {
            ascii.push(ch);
        } else {
            for code in ch.encode_utf16(&mut [0; 2]) {
                ascii.push_str(&format!("\\u{code:04x}"));
            }
        }
    }
    ascii.push('\n');
    let temporary = path.with_extension("json.tmp");
    fs::write(&temporary, ascii).map_err(|error| error.to_string())?;
    fs::rename(temporary, path).map_err(|error| error.to_string())
}

/// Merge requested rule dimensions, retain markers and print the original summary.
/// Parameters: path - destination; sticky - selected groups; monitors - assignments; layout - display metadata; managed_sticky - whether sticky is replaced; managed_monitors - whether monitor rules are replaced.
/// Returns: success or stored-rule/write failure.
fn write(
    path: &Path,
    sticky: &[Group],
    monitors: &Assignments,
    layout: &Map<String, Value>,
    managed_sticky: bool,
    managed_monitors: bool,
) -> Result<(), String> {
    let mut old = read_document(path);
    if managed_sticky {
        old.managed.insert("sticky".into());
    }
    if managed_monitors {
        old.managed.insert("monitors".into());
    }
    let rules = merge(
        &old.rules,
        sticky,
        monitors,
        layout,
        managed_sticky,
        managed_monitors,
    )?;
    let mut markers = Map::new();
    for name in ["sticky", "monitors"] {
        if old.managed.contains(name) {
            markers.insert(name.into(), Value::Bool(true));
        }
    }
    let sticky_count = rules
        .iter()
        .filter(|rule| truthy(rule.get("sticky")))
        .count();
    let monitor_count = rules
        .iter()
        .filter(|rule| truthy(rule.get("monitor")))
        .count();
    write_document(path, &json!({"managed":markers,"rules":rules}))?;
    println!(
        "{} rule(s): {sticky_count} sticky, {monitor_count} monitor",
        rules.len()
    );
    Ok(())
}

/// Print sticky application IDs without changing stored rules.
/// Parameters: path - rules JSON file.
/// Returns: success.
fn list_sticky(path: &Path) -> Result<(), String> {
    for rule in read_document(path).rules {
        if truthy(rule.get("sticky")) {
            for id in rule["appIds"].as_array().unwrap() {
                println!(
                    "{}",
                    id.as_str()
                        .map(str::to_string)
                        .unwrap_or_else(|| id.to_string())
                );
            }
        }
    }
    Ok(())
}

/// List monitor choices with legacy defaults only before the managed marker exists.
/// Parameters: path - rules JSON file; legacy - parsed defaults to overlay for old documents.
/// Returns: success or malformed stored-group failure.
fn list_monitors(path: &Path, legacy: &Assignments) -> Result<(), String> {
    let document = read_document(path);
    let mut choices = Map::new();
    if !document.managed.contains("monitors") {
        for (ids, monitor) in legacy {
            choices.insert(group_key(ids), json!([ids, monitor]));
        }
    }
    for rule in document.rules {
        if truthy(rule.get("monitor")) {
            let ids = app_ids(&rule)?;
            choices.insert(group_key(&ids), json!([ids, rule["monitor"]]));
        }
    }
    for (_, choice) in choices {
        let ids: Vec<&str> = choice[0]
            .as_array()
            .unwrap()
            .iter()
            .map(|id| id.as_str().unwrap())
            .collect();
        let monitor = &choice[1];
        let text = monitor
            .as_str()
            .map(str::to_string)
            .unwrap_or_else(|| monitor.to_string());
        println!("{}\t{text}", ids.join("|"));
    }
    Ok(())
}

/// Dispatch typed app-rule commands and preserve success/usage/failure status.
/// Parameters: args - raw CLI argument tokens.
/// Returns: zero on success, two for usage, one for operation failure.
pub fn run(args: &[String]) -> i32 {
    let parsed = match parse(args) {
        Ok(parsed) => parsed,
        Err(error) => {
            eprintln!("ERROR: {error}");
            return 2;
        }
    };
    let result = match parsed.operation {
        Operation::Write {
            sticky,
            monitors,
            layout,
            managed_sticky,
            managed_monitors,
        } => write(
            &parsed.file,
            &sticky,
            &monitors,
            &layout,
            managed_sticky,
            managed_monitors,
        ),
        Operation::ListSticky => list_sticky(&parsed.file),
        Operation::ListMonitors(legacy) => list_monitors(&parsed.file, &legacy),
        Operation::Help => {
            println!(
                "Usage: app-rules-rules --file PATH write|list-sticky|list-monitors [OPTIONS]"
            );
            Ok(())
        }
    };
    match result {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("ERROR: {error}");
            1
        }
    }
}

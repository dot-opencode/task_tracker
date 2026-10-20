//! Slim preset → task session model (preset_model_ref / resolve_task_model of lib/core.sh).

use crate::core::{config_get, read_file, slim_config_file};
use serde_json::{Map, Value};

/// `{providerID, id[, variant]}` from `provider/id`: split on the first "/".
fn split_ref(raw: &str) -> Map<String, Value> {
    let mut parts = raw.split('/');
    let provider = parts.next().unwrap_or("").to_string();
    let rest: Vec<&str> = parts.collect();
    let mut m = Map::new();
    m.insert("providerID".into(), Value::String(provider));
    m.insert("id".into(), Value::String(rest.join("/")));
    m
}

/// Pure part of `preset_model_ref`: the model ref of `preset` for `agent` in the slim config text.
pub fn preset_ref_from(text: &str, preset: &str, agent: &str) -> Option<Value> {
    let v: Value = serde_json::from_str(text).ok()?;
    let presets = match &v {
        Value::Object(o) => o.get("presets"),
        Value::Null => None,
        _ => return None,
    };
    let m = match presets {
        None | Some(Value::Null) => None,
        Some(Value::Object(p)) => match p.get(preset) {
            None | Some(Value::Null) => None,
            Some(Value::Object(po)) => match po.get(agent) {
                None | Some(Value::Null) => None,
                Some(Value::Object(ao)) => ao.get("model"),
                Some(_) => return None,
            },
            Some(_) => return None,
        },
        Some(_) => return None,
    };
    let e = match m {
        Some(Value::Array(a)) => a.first(),
        other => other,
    };
    let (raw, variant) = match e {
        Some(Value::String(s)) => (s.clone(), None),
        Some(Value::Object(o)) => match o.get("id") {
            Some(Value::String(id)) => (id.clone(), o.get("variant").cloned()),
            _ => return None,
        },
        _ => return None,
    };
    // ^[^/]+/.+
    let slash = raw.find('/')?;
    if slash == 0 || slash + 1 >= raw.len() {
        return None;
    }
    let mut out = split_ref(&raw);
    if let Some(Value::String(var)) = variant {
        if !var.is_empty() {
            out.insert("variant".into(), Value::String(var));
        }
    }
    Some(Value::Object(out))
}

/// Model of a slim preset for the configured agent (default orchestrator).
pub fn preset_model_ref(preset: &str) -> Option<Value> {
    let mut agent = config_get("agent", "");
    if agent.is_empty() {
        agent = "orchestrator".into();
    }
    let text = read_file(&slim_config_file())?;
    preset_ref_from(&text, preset, &agent)
}

/// Effective model for task sessions: (model ref, label). The ref is None for
/// the OpenCode default. Err when a configured preset does not resolve.
pub fn resolve_task_model() -> Result<(Option<Value>, String), ()> {
    let model = config_get("model", "");
    let preset = config_get("preset", "");
    if !model.is_empty() {
        let r = Value::Object(split_ref(&model));
        return Ok((Some(r), format!("{model} (from config model)")));
    }
    if preset.is_empty() {
        return Ok((None, "OpenCode default".into()));
    }
    let r = preset_model_ref(&preset).ok_or(())?;
    let mut label = format!(
        "{}/{}",
        r["providerID"].as_str().unwrap_or(""),
        r["id"].as_str().unwrap_or("")
    );
    if let Some(v) = r.get("variant").and_then(|v| v.as_str()) {
        label.push_str(&format!(" ({v})"));
    }
    label.push_str(&format!(" from preset {preset}"));
    Ok((Some(r), label))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forms() {
        let t = r#"{"presets":{"c":{"orchestrator":{"model":[{"id":"cpa-gui/claude-opus-5-5","variant":"high"},{"id":"x/y"}]}}}}"#;
        assert_eq!(
            preset_ref_from(t, "c", "orchestrator").unwrap().to_string(),
            r#"{"providerID":"cpa-gui","id":"claude-opus-5-5","variant":"high"}"#
        );
        let t = r#"{"presets":{"c":{"orchestrator":{"model":{"id":"a/b/c","variant":"low"}}}}}"#;
        assert_eq!(
            preset_ref_from(t, "c", "orchestrator").unwrap().to_string(),
            r#"{"providerID":"a","id":"b/c","variant":"low"}"#
        );
        let t = r#"{"presets":{"c":{"orchestrator":{"model":"a/b"}}}}"#;
        assert_eq!(
            preset_ref_from(t, "c", "orchestrator").unwrap().to_string(),
            r#"{"providerID":"a","id":"b"}"#
        );
        assert!(preset_ref_from(t, "zz", "orchestrator").is_none());
        assert!(preset_ref_from(t, "c", "build").is_none());
        assert!(preset_ref_from("nope", "c", "orchestrator").is_none());
        let t = r#"{"presets":{"c":{"orchestrator":{"model":"/b"}}}}"#;
        assert!(preset_ref_from(t, "c", "orchestrator").is_none());
    }
}

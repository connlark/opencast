//! A JSON Schema (draft 2020-12) validator for the subset of keywords the
//! analysis policy schema uses. Any other keyword is an error, never silently
//! ignored, so the schema cannot claim a constraint this checker skips.

use serde_json::{Map, Value};

const ANNOTATIONS: &[&str] = &[
    "$schema",
    "$id",
    "$comment",
    "title",
    "description",
    "format",
];
const KEYWORDS: &[&str] = &[
    "$defs",
    "$ref",
    "type",
    "properties",
    "required",
    "additionalProperties",
    "minProperties",
    "maxProperties",
    "items",
    "minItems",
    "maxItems",
    "enum",
    "const",
    "minimum",
    "maximum",
    "exclusiveMinimum",
    "exclusiveMaximum",
    "minLength",
    "maxLength",
];

/// Validates `instance` against `schema`, collecting every violation as a
/// `path: problem` line.
///
/// # Errors
///
/// Returns the violations, or the schema's own defect when it uses an
/// unsupported keyword or an unresolvable `$ref`.
pub fn validate(schema: &Value, instance: &Value) -> Result<(), Vec<String>> {
    let mut errors = Vec::new();
    lint(schema, "#", &mut errors);
    if !errors.is_empty() {
        return Err(errors);
    }
    Validator { root: schema }.check(schema, instance, "$", &mut errors);
    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors)
    }
}

/// Walks the whole schema, not only the branches an instance reaches, so an
/// unsupported keyword anywhere is caught.
fn lint(schema: &Value, path: &str, errors: &mut Vec<String>) {
    let Some(schema) = schema.as_object() else {
        if !schema.is_boolean() {
            errors.push(format!("{path}: schema is not an object or boolean"));
        }
        return;
    };
    for (keyword, value) in schema {
        if !KEYWORDS.contains(&keyword.as_str()) && !ANNOTATIONS.contains(&keyword.as_str()) {
            errors.push(format!("{path}: unsupported schema keyword {keyword}"));
        }
        match keyword.as_str() {
            "$defs" | "properties" => {
                for (name, child) in value.as_object().into_iter().flatten() {
                    lint(child, &format!("{path}/{keyword}/{name}"), errors);
                }
            }
            "additionalProperties" | "items" => lint(value, &format!("{path}/{keyword}"), errors),
            _ => {}
        }
    }
}

struct Validator<'a> {
    root: &'a Value,
}

impl Validator<'_> {
    fn check(&self, schema: &Value, instance: &Value, path: &str, errors: &mut Vec<String>) {
        let Some(schema) = schema.as_object() else {
            if schema.as_bool() == Some(false) {
                errors.push(format!("{path}: not allowed"));
            } else if schema.as_bool() != Some(true) {
                errors.push(format!("{path}: schema is not an object or boolean"));
            }
            return;
        };
        if let Some(reference) = schema.get("$ref") {
            match reference.as_str().and_then(|r| self.resolve(r)) {
                Some(target) => self.check(target, instance, path, errors),
                None => errors.push(format!("{path}: unresolvable $ref {reference}")),
            }
        }
        if let Some(expected) = schema.get("type") {
            check_type(expected, instance, path, errors);
        }
        if let Some(constant) = schema.get("const") {
            if !json_equal(constant, instance) {
                errors.push(format!("{path}: must equal {constant}"));
            }
        }
        if let Some(Value::Array(options)) = schema.get("enum") {
            if !options.iter().any(|option| json_equal(option, instance)) {
                errors.push(format!("{path}: not one of the allowed values"));
            }
        }
        if let Some(number) = instance.as_f64() {
            check_number(schema, number, path, errors);
        }
        if let Some(text) = instance.as_str() {
            let length = text.chars().count() as u64;
            if bound(schema, "minLength").is_some_and(|min| length < min) {
                errors.push(format!("{path}: shorter than minLength"));
            }
            if bound(schema, "maxLength").is_some_and(|max| length > max) {
                errors.push(format!("{path}: longer than maxLength"));
            }
        }
        if let Some(items) = instance.as_array() {
            let count = items.len() as u64;
            if bound(schema, "minItems").is_some_and(|min| count < min) {
                errors.push(format!("{path}: fewer than minItems"));
            }
            if bound(schema, "maxItems").is_some_and(|max| count > max) {
                errors.push(format!("{path}: more than maxItems"));
            }
            if let Some(item_schema) = schema.get("items") {
                for (index, item) in items.iter().enumerate() {
                    self.check(item_schema, item, &format!("{path}[{index}]"), errors);
                }
            }
        }
        if let Some(object) = instance.as_object() {
            self.check_object(schema, object, path, errors);
        }
    }

    fn check_object(
        &self,
        schema: &Map<String, Value>,
        object: &Map<String, Value>,
        path: &str,
        errors: &mut Vec<String>,
    ) {
        let count = object.len() as u64;
        if bound(schema, "minProperties").is_some_and(|min| count < min) {
            errors.push(format!("{path}: fewer than minProperties"));
        }
        if bound(schema, "maxProperties").is_some_and(|max| count > max) {
            errors.push(format!("{path}: more than maxProperties"));
        }
        if let Some(Value::Array(required)) = schema.get("required") {
            for name in required.iter().filter_map(Value::as_str) {
                if !object.contains_key(name) {
                    errors.push(format!("{path}: missing required {name}"));
                }
            }
        }
        let properties = schema.get("properties").and_then(Value::as_object);
        for (name, value) in object {
            let child = format!("{path}.{name}");
            match properties.and_then(|properties| properties.get(name)) {
                Some(property_schema) => self.check(property_schema, value, &child, errors),
                None => {
                    if let Some(additional) = schema.get("additionalProperties") {
                        self.check(additional, value, &child, errors);
                    }
                }
            }
        }
    }

    fn resolve(&self, reference: &str) -> Option<&Value> {
        let pointer = reference.strip_prefix('#')?;
        self.root.pointer(pointer)
    }
}

fn check_type(expected: &Value, instance: &Value, path: &str, errors: &mut Vec<String>) {
    let names: Vec<&str> = match expected {
        Value::String(name) => vec![name.as_str()],
        Value::Array(names) => names.iter().filter_map(Value::as_str).collect(),
        _ => {
            errors.push(format!("{path}: malformed type keyword"));
            return;
        }
    };
    if !names.iter().any(|name| type_matches(name, instance)) {
        errors.push(format!("{path}: expected {}", names.join(" or ")));
    }
}

fn type_matches(name: &str, instance: &Value) -> bool {
    match name {
        "null" => instance.is_null(),
        "boolean" => instance.is_boolean(),
        "object" => instance.is_object(),
        "array" => instance.is_array(),
        "string" => instance.is_string(),
        "number" => instance.is_number(),
        "integer" => {
            instance.is_i64()
                || instance.is_u64()
                || instance.as_f64().is_some_and(|value| value.fract() == 0.0)
        }
        _ => false,
    }
}

fn check_number(schema: &Map<String, Value>, number: f64, path: &str, errors: &mut Vec<String>) {
    let limit = |keyword: &str| schema.get(keyword).and_then(Value::as_f64);
    if limit("minimum").is_some_and(|min| number < min) {
        errors.push(format!("{path}: below minimum"));
    }
    if limit("maximum").is_some_and(|max| number > max) {
        errors.push(format!("{path}: above maximum"));
    }
    if limit("exclusiveMinimum").is_some_and(|min| number <= min) {
        errors.push(format!("{path}: not above exclusiveMinimum"));
    }
    if limit("exclusiveMaximum").is_some_and(|max| number >= max) {
        errors.push(format!("{path}: not below exclusiveMaximum"));
    }
}

fn bound(schema: &Map<String, Value>, keyword: &str) -> Option<u64> {
    schema.get(keyword).and_then(Value::as_u64)
}

/// JSON equality with numbers compared by value, so `1` equals `1.0`.
fn json_equal(lhs: &Value, rhs: &Value) -> bool {
    match (lhs, rhs) {
        (Value::Number(lhs), Value::Number(rhs)) => lhs.as_f64() == rhs.as_f64(),
        (Value::Array(lhs), Value::Array(rhs)) => {
            lhs.len() == rhs.len() && lhs.iter().zip(rhs).all(|(l, r)| json_equal(l, r))
        }
        (Value::Object(lhs), Value::Object(rhs)) => {
            lhs.len() == rhs.len()
                && lhs
                    .iter()
                    .all(|(key, value)| rhs.get(key).is_some_and(|other| json_equal(value, other)))
        }
        _ => lhs == rhs,
    }
}

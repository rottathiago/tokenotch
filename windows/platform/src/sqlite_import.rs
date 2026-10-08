use crate::storage::Result;
use rusqlite::{
    hooks::{AuthAction, AuthContext, Authorization},
    limits::Limit,
    types::ValueRef,
    Connection,
};
use serde_json::{Map, Value};
use std::{
    collections::BTreeSet,
    time::{Duration, Instant},
};

const LIMIT: usize = 64 * 1_048_576;
fn invalid(_: rusqlite::Error) -> String {
    "The selected SQLite export is unsupported, inconsistent or exceeds its limits.".into()
}
fn word(bytes: &[u8], at: usize, little: bool) -> u32 {
    let mut value = [0; 4];
    value.copy_from_slice(&bytes[at..at + 4]);
    if little {
        u32::from_le_bytes(value)
    } else {
        u32::from_be_bytes(value)
    }
}
fn checksum(
    bytes: &[u8],
    start: usize,
    end: usize,
    little: bool,
    mut sum: (u32, u32),
) -> (u32, u32) {
    for at in (start..end).step_by(8) {
        sum.0 = sum
            .0
            .wrapping_add(word(bytes, at, little))
            .wrapping_add(sum.1);
        sum.1 = sum
            .1
            .wrapping_add(word(bytes, at + 4, little))
            .wrapping_add(sum.0);
    }
    sum
}

pub fn image(mut main: Vec<u8>, wal: Option<&[u8]>, shm: Option<&[u8]>) -> Result<Vec<u8>> {
    if main.len() < 100 || &main[..16] != b"SQLite format 3\0" {
        return Err("Invalid SQLite export header.".into());
    }
    let size = u16::from_be_bytes([main[16], main[17]]) as usize;
    let size = if size == 1 { 65_536 } else { size };
    if !(512..=65_536).contains(&size)
        || !size.is_power_of_two()
        || !main.len().is_multiple_of(size)
        || main[18] != main[19]
        || ![1, 2].contains(&main[18])
    {
        return Err("Unsupported SQLite page layout.".into());
    }
    if main[18] == 2 {
        let (wal, shm) = wal
            .zip(shm)
            .ok_or("A WAL-mode export requires both matching -wal and -shm companions.")?;
        replay(&mut main, wal, shm, size)?;
    } else if wal.is_some() || shm.is_some() {
        return Err("Unexpected SQLite sidecars; select a consistent export.".into());
    }
    if main.len() < 100 || word(&main, 28, false) as usize * size != main.len() {
        return Err("Inconsistent SQLite database size.".into());
    }
    main[18] = 1;
    main[19] = 1;
    Ok(main)
}

fn replay(main: &mut Vec<u8>, wal: &[u8], shm: &[u8], size: usize) -> Result<()> {
    let changed = "SQLite WAL snapshot is inconsistent. Export it again with both companions.";
    if shm.len() < 32768
        || !shm.len().is_multiple_of(32768)
        || shm[..48] != shm[48..96]
        || shm[12] != 1
    {
        return Err(changed.into());
    }
    let little = word(shm, 0, true) == 3_007_000;
    if word(shm, 0, little) != 3_007_000
        || checksum(shm, 0, 40, little, (0, 0)) != (word(shm, 40, little), word(shm, 44, little))
    {
        return Err(changed.into());
    }
    let frames = word(shm, 16, little) as usize;
    let encoded = if little {
        u16::from_le_bytes([shm[14], shm[15]])
    } else {
        u16::from_be_bytes([shm[14], shm[15]])
    } as usize;
    if !(encoded == size || encoded == 1 && size == 65_536)
        || word(shm, 96, little) as usize > frames
        || word(shm, 128, little) as usize > frames
    {
        return Err(changed.into());
    }
    if wal.is_empty() {
        return if frames == 0 {
            Ok(())
        } else {
            Err(changed.into())
        };
    }
    if wal.len() < 32
        || ![0x377f0682, 0x377f0683].contains(&word(wal, 0, false))
        || word(wal, 4, false) != 3_007_000
        || word(wal, 8, false) as usize != size
        || wal[16..24] != shm[32..40]
        || shm[13] != (word(wal, 0, false) & 1) as u8
        || frames > (LIMIT - 32) / (size + 24)
        || wal.len() != 32 + frames * (size + 24)
    {
        return Err(changed.into());
    }
    let wal_little = word(wal, 0, false) == 0x377f0682;
    let mut sum = checksum(wal, 0, 24, wal_little, (0, 0));
    if sum != (word(wal, 24, false), word(wal, 28, false)) {
        return Err(changed.into());
    }
    let pages = word(shm, 20, little) as usize;
    if pages == 0 || pages > LIMIT / size {
        return Err(changed.into());
    }
    let original = main.len() / size;
    main.resize(pages * size, 0);
    let mut supplied = BTreeSet::new();
    for index in 0..frames {
        let at = 32 + index * (size + 24);
        let page = word(wal, at, false) as usize;
        if page == 0 || page > LIMIT / size || wal[at + 8..at + 16] != wal[16..24] {
            return Err(changed.into());
        }
        sum = checksum(wal, at, at + 8, wal_little, sum);
        sum = checksum(wal, at + 24, at + 24 + size, wal_little, sum);
        if sum != (word(wal, at + 16, false), word(wal, at + 20, false)) {
            return Err(changed.into());
        }
        if index == frames - 1
            && (word(wal, at + 4, false) as usize != pages
                || sum != (word(shm, 24, little), word(shm, 28, little)))
        {
            return Err(changed.into());
        }
        if page <= pages {
            main[(page - 1) * size..page * size].copy_from_slice(&wal[at + 24..at + 24 + size]);
            supplied.insert(page);
        }
    }
    if (original + 1..=pages).any(|page| !supplied.contains(&page)) {
        return Err(changed.into());
    }
    Ok(())
}

const COLUMNS: &[(&str, &str)] = &[
    ("operation_name", "gen_ai.operation.name"),
    ("provider_name", "gen_ai.provider.name"),
    ("agent_name", "gen_ai.agent.name"),
    ("conversation_id", "gen_ai.conversation.id"),
    ("request_model", "gen_ai.request.model"),
    ("response_model", "gen_ai.response.model"),
    ("input_tokens", "gen_ai.usage.input_tokens"),
    ("output_tokens", "gen_ai.usage.output_tokens"),
    ("cached_tokens", "gen_ai.usage.cache_read.input_tokens"),
    ("ttft_ms", "copilot_chat.time_to_first_token"),
];

pub fn records(image: &[u8], mut accept: impl FnMut(Value) -> Result<()>) -> Result<()> {
    let mut db = Connection::open_in_memory().map_err(invalid)?;
    db.deserialize_read_exact("main", image, image.len(), true)
        .map_err(invalid)?;
    db.set_limit(Limit::SQLITE_LIMIT_LENGTH, 4 * 1_048_576)
        .map_err(invalid)?;
    db.set_limit(Limit::SQLITE_LIMIT_SQL_LENGTH, 16_384)
        .map_err(invalid)?;
    db.set_limit(Limit::SQLITE_LIMIT_COLUMN, 128)
        .map_err(invalid)?;
    db.execute_batch("PRAGMA trusted_schema=OFF; PRAGMA query_only=ON; PRAGMA temp_store=MEMORY;")
        .map_err(invalid)?;
    let started = Instant::now();
    db.progress_handler(
        1000,
        Some(move || started.elapsed() > Duration::from_secs(15)),
    )
    .map_err(invalid)?;
    db.authorizer(Some(|context: AuthContext<'_>| match context.action {
        AuthAction::Read { .. } | AuthAction::Select | AuthAction::Pragma { .. } => {
            Authorization::Allow
        }
        _ => Authorization::Deny,
    }))
    .map_err(invalid)?;
    verify_schema(&db)?;
    let mut columns = vec!["span_id", "trace_id", "start_time_ms", "end_time_ms"];
    columns.extend(COLUMNS.iter().map(|(column, _)| *column));
    let mut statement = db
        .prepare(&format!("SELECT {} FROM spans", columns.join(",")))
        .map_err(invalid)?;
    let mut rows = statement.query([]).map_err(invalid)?;
    let mut attr_query=db.prepare("SELECT key,value FROM span_attributes WHERE span_id=?1 AND key IN (
        'service.name','service.namespace','gen_ai.operation.name','gen_ai.provider.name','gen_ai.agent.name',
        'gen_ai.conversation.id','gen_ai.request.model','gen_ai.response.model','gen_ai.usage.input_tokens',
        'gen_ai.usage.output_tokens','gen_ai.usage.cache_read.input_tokens','gen_ai.usage.cache_creation.input_tokens',
        'copilot_chat.time_to_first_token')").map_err(invalid)?;
    let mut count = 0;
    while let Some(row) = rows.next().map_err(invalid)? {
        count += 1;
        if count > 100_000 {
            return Err("SQLite export exceeds 100,000 spans.".into());
        }
        let id: String = row.get(0).map_err(invalid)?;
        let trace: String = row.get(1).map_err(invalid)?;
        let mut attrs = Map::new();
        for (index, (_, key)) in COLUMNS.iter().enumerate() {
            let value = sql_value(row.get_ref(index + 4).map_err(invalid)?)?;
            if !value.is_null() {
                attrs.insert((*key).into(), value);
            }
        }
        let mut attributes = attr_query.query([&id]).map_err(invalid)?;
        let mut attr_count = 0;
        while let Some(attr) = attributes.next().map_err(invalid)? {
            attr_count += 1;
            if attr_count > 32 {
                return Err("Duplicate or excessive SQLite attributes.".into());
            }
            let key: String = attr.get(0).map_err(invalid)?;
            let text: String = attr.get(1).map_err(invalid)?;
            let value =
                if key.starts_with("gen_ai.usage.") || key == "copilot_chat.time_to_first_token" {
                    let number = text
                        .parse::<f64>()
                        .ok()
                        .filter(|v| v.is_finite())
                        .ok_or("Invalid SQLite numeric attribute.")?;
                    serde_json::json!(number)
                } else {
                    Value::String(text)
                };
            if let Some(old) = attrs.get(&key) {
                if old != &value
                    && !(old.is_number() && value.is_number() && old.as_f64() == value.as_f64())
                {
                    return Err("Conflicting SQLite span attributes.".into());
                }
            } else {
                attrs.insert(key, value);
            }
        }
        accept(serde_json::json!({"traceId":trace,"spanId":id,
            "startTime":sql_value(row.get_ref(2).map_err(invalid)?)?,
            "endTime":sql_value(row.get_ref(3).map_err(invalid)?)?,
            "name":"completed","events":[],"status":{"code":0},"attributes":attrs}))?;
    }
    Ok(())
}
fn sql_value(value: ValueRef<'_>) -> Result<Value> {
    Ok(match value {
        ValueRef::Null => Value::Null,
        ValueRef::Integer(value) => value.into(),
        ValueRef::Real(value) if value.is_finite() => serde_json::json!(value),
        ValueRef::Text(bytes) => std::str::from_utf8(bytes)
            .map_err(|_| "Invalid SQLite text.")?
            .into(),
        _ => return Err("Unsupported SQLite field type.".into()),
    })
}
fn verify_schema(db: &Connection) -> Result<()> {
    let tables=[
        ("schema_version","version:INTEGER",vec!["version"]),
        ("spans","span_id:TEXT trace_id:TEXT parent_span_id:TEXT name:TEXT start_time_ms:INTEGER end_time_ms:INTEGER status_code:INTEGER status_message:TEXT operation_name:TEXT provider_name:TEXT agent_name:TEXT conversation_id:TEXT request_model:TEXT response_model:TEXT input_tokens:INTEGER output_tokens:INTEGER cached_tokens:INTEGER reasoning_tokens:INTEGER tool_name:TEXT tool_call_id:TEXT tool_type:TEXT chat_session_id:TEXT turn_index:INTEGER ttft_ms:REAL",vec!["span_id"]),
        ("span_attributes","span_id:TEXT key:TEXT value:TEXT",vec!["span_id","key"]),
        ("span_events","id:INTEGER span_id:TEXT name:TEXT timestamp_ms:INTEGER attributes:TEXT",vec!["id"]),
    ];
    for (table, columns, primary) in tables {
        let (kind, sql): (String, String) = db
            .query_row(
                "SELECT type,sql FROM sqlite_schema WHERE name=?1",
                [table],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .map_err(invalid)?;
        if kind != "table" || !sql.to_uppercase().starts_with("CREATE TABLE ") {
            return Err("Unsupported SQLite export schema.".into());
        }
        let mut statement = db
            .prepare(&format!("PRAGMA table_xinfo('{table}')"))
            .map_err(invalid)?;
        let mut rows = statement.query([]).map_err(invalid)?;
        let mut found = BTreeSet::new();
        while let Some(row) = rows.next().map_err(invalid)? {
            let name: String = row.get(1).map_err(invalid)?;
            let kind: String = row.get(2).map_err(invalid)?;
            let pk: u32 = row.get(5).map_err(invalid)?;
            let hidden: u32 = row.get(6).map_err(invalid)?;
            if hidden != 0
                || pk as usize != primary.iter().position(|v| *v == name).map_or(0, |v| v + 1)
            {
                return Err("Unsupported SQLite export columns.".into());
            }
            found.insert(format!("{name}:{}", kind.to_uppercase()));
        }
        if found != columns.split(' ').map(str::to_owned).collect() {
            return Err("Unsupported SQLite export columns.".into());
        }
    }
    let mut statement = db
        .prepare("SELECT version FROM schema_version")
        .map_err(invalid)?;
    let versions = statement
        .query_map([], |r| r.get::<_, i64>(0))
        .map_err(invalid)?
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(invalid)?;
    if versions != [1] {
        return Err("Unsupported SQLite export version.".into());
    }
    Ok(())
}

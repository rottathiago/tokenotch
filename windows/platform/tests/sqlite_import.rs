use rusqlite::Connection;
use tokenotch_platform::{
    import::preview,
    storage::{random_id, Store},
};

const SCHEMA:&str="CREATE TABLE schema_version(version INTEGER PRIMARY KEY);
INSERT INTO schema_version VALUES(1);
CREATE TABLE spans(span_id TEXT PRIMARY KEY,trace_id TEXT,parent_span_id TEXT,name TEXT,start_time_ms INTEGER,end_time_ms INTEGER,
status_code INTEGER,status_message TEXT,operation_name TEXT,provider_name TEXT,agent_name TEXT,conversation_id TEXT,
request_model TEXT,response_model TEXT,input_tokens INTEGER,output_tokens INTEGER,cached_tokens INTEGER,reasoning_tokens INTEGER,
tool_name TEXT,tool_call_id TEXT,tool_type TEXT,chat_session_id TEXT,turn_index INTEGER,ttft_ms REAL);
CREATE TABLE span_attributes(span_id TEXT,key TEXT,value TEXT,PRIMARY KEY(span_id,key));
CREATE TABLE span_events(id INTEGER PRIMARY KEY,span_id TEXT,name TEXT,timestamp_ms INTEGER,attributes TEXT);
INSERT INTO spans(span_id,trace_id,start_time_ms,end_time_ms,operation_name,provider_name,response_model,input_tokens,output_tokens,cached_tokens)
VALUES('2222222222222222','11111111111111111111111111111111',1700000000000,1700000001000,'chat','github','synthetic-model',100,20,30);";

#[test]
fn readonly_sqlite_import_requires_schema_and_producer_without_persisting_raw_copy() {
    let root =
        std::env::temp_dir().join(format!("tokenotch-sqlite-import-{}", random_id().unwrap()));
    let store = Store::open(root.clone()).unwrap();
    let file = store.path("export.sqlite").unwrap();
    let db = Connection::open(&file).unwrap();
    db.execute_batch(SCHEMA).unwrap();
    assert!(
        preview(file.clone()).is_err(),
        "resource-less Local SQLite must not infer provenance"
    );
    db.execute(
        "INSERT INTO span_attributes VALUES ('2222222222222222','service.name','github-copilot')",
        [],
    )
    .unwrap();
    assert!(
        preview(file.clone()).is_err(),
        "Terminal exports are not Agent Host telemetry"
    );
    db.execute(
        "INSERT INTO span_attributes VALUES ('2222222222222222','service.namespace','copilot.cli')",
        [],
    )
    .unwrap();
    assert!(
        preview(file.clone()).is_err(),
        "An unrelated namespace is not Agent Host provenance"
    );
    db.execute(
        "UPDATE span_attributes SET value='vscode.agent-host' WHERE key='service.namespace'",
        [],
    )
    .unwrap();
    drop(db);
    let original = std::fs::read(&file).unwrap();
    let export = preview(file.clone()).unwrap();
    assert_eq!(export.events.len(), 1);
    assert_eq!(
        export.events[0].usage_source(),
        tokenotch_core::hook::UsageSource::VscodeCopilot
    );
    assert_eq!(export.events[0].tokens.as_ref().unwrap().input, 70);
    assert_eq!(export.events[0].tokens.as_ref().unwrap().cache_input, 30);
    export.verify().unwrap();
    assert_eq!(std::fs::read(&file).unwrap(), original);
    assert_eq!(std::fs::read_dir(&root).unwrap().count(), 1);
    let db = Connection::open(&file).unwrap();
    db.execute("UPDATE schema_version SET version=2", [])
        .unwrap();
    drop(db);
    assert!(preview(file).is_err());
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn wal_snapshot_is_verified_in_memory_and_missing_companions_are_rejected() {
    let root = std::env::temp_dir().join(format!("tokenotch-wal-import-{}", random_id().unwrap()));
    let store = Store::open(root.clone()).unwrap();
    let file = store.path("export.sqlite").unwrap();
    let db = Connection::open(&file).unwrap();
    db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        .unwrap();
    db.execute_batch(SCHEMA).unwrap();
    db.execute(
        "INSERT INTO span_attributes VALUES ('2222222222222222','service.name','github-copilot')",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO span_attributes VALUES ('2222222222222222','service.namespace','vscode.agent-host')",
        [],
    )
    .unwrap();
    let preview = preview(file.clone()).unwrap();
    assert_eq!(preview.events.len(), 1);
    preview.verify().unwrap();
    let copied = store.path("missing-sidecars.sqlite").unwrap();
    std::fs::copy(&file, &copied).unwrap();
    assert!(tokenotch_platform::import::preview(copied).is_err());
    drop(db);
    assert!(
        preview.verify().is_err(),
        "checkpointing/removing the WAL changes the approved fingerprint"
    );
    std::fs::remove_dir_all(root).unwrap();
}

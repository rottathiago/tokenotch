use std::{
    io::{Read, Write},
    process::ExitCode,
    time::Duration,
};
use tokenotch_core::{
    hook::{self, Source},
    product,
};
use tokenotch_platform::{
    storage::{home, Result, Store},
    transport::{self, Envelope},
};

fn input() -> Result<Vec<u8>> {
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = std::io::stdin()
            .take(hook::INPUT_LIMIT as u64 + 1)
            .read_to_end(&mut bytes)
            .map(|_| bytes)
            .map_err(|_| "Hook input could not be read.".to_owned());
        let _ = sender.send(result);
    });
    let bytes = receiver
        .recv_timeout(Duration::from_millis(700))
        .map_err(|_| "Hook input timed out.")??;
    if bytes.len() > hook::INPUT_LIMIT {
        return Err("Hook input exceeds its size limit.".into());
    }
    Ok(bytes)
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

async fn run() -> Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args == ["--self-test"] {
        println!(
            "{}",
            serde_json::json!({
                "name": "TokenotchHook", "version": product::VERSION, "channel": product::CHANNEL,
                "runtime": tokenotch_platform::runtime()?, "connectionsEnabled": true
            })
        );
        return Ok(());
    }
    if args == ["--store"] {
        let store = Store::open(home()?.join(".tokenotch"))?;
        let response = tokenotch_platform::broker::execute(&store, &input()?)?;
        std::io::stdout()
            .write_all(
                &serde_json::to_vec(&response).map_err(|_| "Store response encoding failed.")?,
            )
            .map_err(|_| "Store response could not be written.")?;
        return Ok(());
    }
    if args.len() != 2 {
        return Err("Expected a supported Tokenotch client and hook name.".into());
    }
    let source = match args[0].as_str() {
        "cli" => Source::Cli,
        "vscode" => Source::Vscode,
        _ => return Err("Unsupported Tokenotch client.".into()),
    };
    let valid = match source {
        Source::Cli => [
            "sessionStart",
            "userPromptSubmitted",
            "agentStop",
            "sessionEnd",
            "notification",
            "errorOccurred",
            "usage",
            "activity",
            "context",
            "contextInvalidated",
            "compaction",
        ]
        .contains(&args[1].as_str()),
        Source::Vscode => ["SessionStart", "UserPromptSubmit", "Stop"].contains(&args[1].as_str()),
    };
    if !valid {
        return Err("Unsupported Tokenotch hook.".into());
    }
    let store = Store::open(home()?.join(".tokenotch"))?;
    let registration = store
        .read(transport::registration_name(source), 128)?
        .ok_or("Collection is disabled for this client.")?;
    let Some(event) = hook::normalize(&input()?, source, &args[1], transport::now_ms())
        .map_err(|error| error.to_string())?
    else {
        return Ok(());
    };
    transport::send(&Envelope {
        registration: String::from_utf8(registration)
            .map_err(|_| "Invalid client registration.")?,
        event,
    })
    .await
}

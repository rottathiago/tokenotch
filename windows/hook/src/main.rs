use std::process::ExitCode;
use tokenotch_core::product;

fn main() -> ExitCode {
    if std::env::args().skip(1).collect::<Vec<_>>() != ["--self-test"] {
        eprintln!("Tokenotch Windows connections are not enabled in this development build.");
        return ExitCode::FAILURE;
    }
    match tokenotch_platform::runtime() {
        Ok(runtime) => {
            println!(
                "{}",
                serde_json::json!({
                    "name": "TokenotchHook",
                    "version": product::VERSION,
                    "channel": product::CHANNEL,
                    "runtime": runtime,
                    "connectionsEnabled": false
                })
            );
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

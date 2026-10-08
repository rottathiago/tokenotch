use crate::storage::Result;
use serde::{Deserialize, Serialize};
use tokenotch_core::hook::{Observation, Source};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub const FRAME_LIMIT: usize = 16_384;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Envelope {
    pub registration: String,
    pub event: Observation,
}

pub fn now_ms() -> f64 {
    chrono::Utc::now().timestamp_millis() as f64
}

pub async fn read_frame<R: AsyncRead + Unpin>(stream: &mut R) -> Result<Vec<u8>> {
    let length = stream
        .read_u32_le()
        .await
        .map_err(|_| "Local connection closed before its frame.")? as usize;
    if length == 0 || length > FRAME_LIMIT {
        return Err("Local event exceeds its supported size.".into());
    }
    let mut bytes = vec![0; length];
    stream
        .read_exact(&mut bytes)
        .await
        .map_err(|_| "Local event was incomplete.")?;
    Ok(bytes)
}

pub async fn write_frame<W: AsyncWrite + Unpin>(stream: &mut W, bytes: &[u8]) -> Result<()> {
    if bytes.is_empty() || bytes.len() > FRAME_LIMIT {
        return Err("Local event exceeds its supported size.".into());
    }
    stream
        .write_u32_le(bytes.len() as u32)
        .await
        .map_err(|_| "Local event could not be sent.")?;
    stream
        .write_all(bytes)
        .await
        .map_err(|_| "Local event could not be sent.".into())
}

pub fn registration_name(source: Source) -> &'static str {
    match source {
        Source::Cli => "cli.registration",
        Source::Vscode => "vscode.registration",
    }
}

#[cfg(windows)]
pub fn pipe_name() -> Result<String> {
    Ok(format!(
        r"\\.\pipe\Tokenotch-{}",
        tokenotch_core::hook::digest(&format!(
            "{}:{}",
            crate::security::user_sid()?,
            crate::storage::home()?.to_string_lossy().to_lowercase()
        ))
    ))
}

#[cfg(windows)]
pub fn server(first: bool) -> Result<tokio::net::windows::named_pipe::NamedPipeServer> {
    use tokio::net::windows::named_pipe::ServerOptions;
    let descriptor = crate::security::Descriptor::private()?;
    let mut attributes = descriptor.attributes();
    unsafe {
        ServerOptions::new()
            .first_pipe_instance(first)
            .reject_remote_clients(true)
            .create_with_security_attributes_raw(
                pipe_name()?,
                (&mut attributes as *mut windows::Win32::Security::SECURITY_ATTRIBUTES).cast(),
            )
    }
    .map_err(|_| {
        "The private event pipe could not be opened; another Tokenotch instance may be running."
            .into()
    })
}

#[cfg(windows)]
pub async fn send(envelope: &Envelope) -> Result<()> {
    send_to(&pipe_name()?, envelope, &crate::security::user_sid()?).await
}

#[cfg(windows)]
async fn send_to(name: &str, envelope: &Envelope, expected_sid: &str) -> Result<()> {
    use tokio::{
        net::windows::named_pipe::ClientOptions,
        time::{timeout, Duration},
    };
    let bytes = serde_json::to_vec(envelope).map_err(|_| "Local event could not be encoded.")?;
    timeout(Duration::from_millis(900), async {
        let mut pipe =
            loop {
                match ClientOptions::new().open(name) {
                    Ok(pipe) => break pipe,
                    Err(error) if error.raw_os_error() == Some(231) => {
                        tokio::time::sleep(Duration::from_millis(10)).await
                    }
                    Err(_) => return Err(
                        "Tokenotch is not receiving events. Open Tokenotch and check Connections."
                            .into(),
                    ),
                }
            };
        crate::security::check_pipe_server(&pipe, expected_sid)?;
        write_frame(&mut pipe, &bytes).await?;
        let response = pipe
            .read_u8()
            .await
            .map_err(|_| "Tokenotch did not acknowledge the event.")?;
        if response != 1 {
            return Err("Tokenotch rejected the event. Check Connections.".into());
        }
        Ok(())
    })
    .await
    .map_err(|_| "Tokenotch event delivery timed out.")?
}

#[cfg(not(windows))]
pub async fn send(_: &Envelope) -> Result<()> {
    Err("Named-pipe delivery requires Windows.".into())
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;
    use tokio::net::windows::named_pipe::{NamedPipeServer, ServerOptions};

    fn fixture() -> (String, NamedPipeServer, Envelope) {
        let name = format!(
            r"\\.\pipe\Tokenotch-test-{}",
            crate::storage::random_id().unwrap()
        );
        let descriptor = crate::security::Descriptor::private().unwrap();
        let mut attributes = descriptor.attributes();
        let server = unsafe {
            ServerOptions::new()
                .first_pipe_instance(true)
                .reject_remote_clients(true)
                .create_with_security_attributes_raw(
                    &name,
                    (&mut attributes as *mut windows::Win32::Security::SECURITY_ATTRIBUTES).cast(),
                )
        }
        .unwrap();
        let now = now_ms();
        let event = tokenotch_core::hook::normalize(
            &serde_json::to_vec(&serde_json::json!({
                "sessionId": "pipe-test", "timestamp": now
            }))
            .unwrap(),
            Source::Cli,
            "sessionStart",
            now,
        )
        .unwrap()
        .unwrap();
        (
            name,
            server,
            Envelope {
                registration: "private-registration".into(),
                event,
            },
        )
    }

    #[tokio::test]
    async fn same_user_pipe_receives_and_acknowledges_event() {
        let (name, mut server, envelope) = fixture();
        let receiver = tokio::spawn(async move {
            server.connect().await.unwrap();
            let bytes = read_frame(&mut server).await.unwrap();
            let envelope: Envelope = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(envelope.registration, "private-registration");
            server.write_u8(1).await.unwrap();
        });
        send_to(&name, &envelope, &crate::security::user_sid().unwrap())
            .await
            .unwrap();
        receiver.await.unwrap();
    }

    #[tokio::test]
    async fn mismatched_server_identity_receives_no_bytes() {
        let (name, mut server, envelope) = fixture();
        let receiver = tokio::spawn(async move {
            server.connect().await.unwrap();
            let mut byte = [0];
            match server.read(&mut byte).await {
                Ok(0) => {}
                Err(error) if error.kind() == std::io::ErrorKind::BrokenPipe => {}
                result => panic!("Untrusted server received event data: {result:?}"),
            }
        });
        tokio::task::yield_now().await;
        let error = send_to(&name, &envelope, "S-1-0-0").await.unwrap_err();
        assert!(error.contains("another Windows user"), "{error}");
        receiver.await.unwrap();
    }

    #[test]
    fn unverifiable_pipe_server_is_rejected() {
        let file = std::fs::File::open(std::env::current_exe().unwrap()).unwrap();
        assert!(
            crate::security::check_pipe_server(&file, &crate::security::user_sid().unwrap())
                .is_err()
        );
    }
}

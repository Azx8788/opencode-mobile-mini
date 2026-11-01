//! OpenCode 2 phone driver and protocol-neutral input validation.
pub use crate::opencode2::OpenCode2Client as OpenCodeClient;
use std::{collections::BTreeSet, fmt};

const MAX_STATUS_DIRECTORIES: usize = 64;

/// Contains a static, credential-safe code only. Never wraps a server body/error.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ProtocolError(pub(crate) &'static str);

impl ProtocolError {
    pub fn code(&self) -> &'static str {
        self.0
    }
}
impl fmt::Display for ProtocolError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.0)
    }
}
impl std::error::Error for ProtocolError {}

/// Metadata only; never includes raw event bodies, retry messages, or errors.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GlobalStatusObservation {
    Status {
        directory: String,
        session_id: String,
        busy: bool,
    },
    Other,
}

pub(crate) fn validate_directory(directory: &str) -> Result<(), ProtocolError> {
    if !directory.starts_with('/') || directory.contains('\0') || directory.len() > 4096 {
        return Err(ProtocolError("person_directory_unknown"));
    }
    Ok(())
}

pub(crate) fn known_directories(directories: &[String]) -> Result<Vec<&str>, ProtocolError> {
    if directories.is_empty() || directories.len() > MAX_STATUS_DIRECTORIES {
        return Err(ProtocolError("person_directory_unknown"));
    }
    let mut known = BTreeSet::new();
    for directory in directories {
        validate_directory(directory)?;
        known.insert(directory.as_str());
    }
    Ok(known.into_iter().collect())
}

pub(crate) fn validate_team_ids(ids: &[String]) -> Result<(), ProtocolError> {
    for id in ids {
        validate_session_id(id)?;
    }
    Ok(())
}

pub(crate) fn validate_session_id(id: &str) -> Result<(), ProtocolError> {
    if !id.starts_with("ses")
        || id.len() > 128
        || id.len() < 4
        || !id.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_')
    {
        return Err(ProtocolError("invalid_session"));
    }
    Ok(())
}

/// Empty selection requests the server default; explicit models stay validated.
pub fn validate_model(model: &str) -> Result<(), ProtocolError> {
    model_selection(model).map(|_| ())
}

pub(crate) fn model_selection(model: &str) -> Result<Option<(&str, &str)>, ProtocolError> {
    if model.is_empty() {
        return Ok(None);
    }
    let (provider, model) = model
        .split_once('/')
        .ok_or(ProtocolError("invalid_model"))?;
    if provider.is_empty()
        || model.is_empty()
        || provider.chars().any(char::is_whitespace)
        || model.chars().any(char::is_whitespace)
    {
        return Err(ProtocolError("invalid_model"));
    }
    Ok(Some((provider, model)))
}

pub(crate) fn validate_prompt(
    role: &str,
    model: &str,
    instructions: &str,
    text: &str,
    readonly: bool,
) -> Result<(), ProtocolError> {
    if !matches!(role, "planner" | "worker" | "checker")
        || (matches!(role, "planner" | "checker") && !readonly)
        || instructions.is_empty()
        || text.is_empty()
    {
        return Err(ProtocolError("invalid_role"));
    }
    validate_model(model)
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{extract::Request, response::IntoResponse, Router};

    #[test]
    fn server_access_stays_loopback_only_with_explicit_credentials() {
        for url in ["http://127.0.0.1:4097", "http://[::1]:4097"] {
            assert!(OpenCodeClient::new(url, "opencode", "fixture-only").is_ok());
        }
        for url in [
            "https://127.0.0.1:4097",
            "http://example.com",
            "http://localhost",
            "http://127.0.0.1/path",
            "http://127.0.0.1?token=secret",
            "http://user:secret@127.0.0.1",
            "http://127.0.0.1/#fragment",
        ] {
            assert!(matches!(
                OpenCodeClient::new(url, "opencode", "fixture-only"),
                Err(ProtocolError("invalid_server"))
            ));
        }
        assert!(OpenCodeClient::new("http://127.0.0.1", "other", "fixture-only").is_err());
        assert!(OpenCodeClient::new("http://127.0.0.1", "opencode", "").is_err());
    }

    #[tokio::test]
    async fn unsupported_servers_never_receive_legacy_requests() {
        use std::sync::{Arc, Mutex};
        for (status, body, expected) in [
            (
                reqwest::StatusCode::UNAUTHORIZED,
                serde_json::json!({}),
                "authentication_failed",
            ),
            (
                reqwest::StatusCode::OK,
                serde_json::json!({"version":"1.19.0"}),
                "unsupported_server_version",
            ),
            (
                reqwest::StatusCode::NOT_FOUND,
                serde_json::json!({}),
                "protocol_unavailable",
            ),
        ] {
            let calls = Arc::new(Mutex::new(Vec::<String>::new()));
            let seen = calls.clone();
            let router = Router::new().fallback(move |request: Request| {
                let seen = seen.clone();
                let body = body.clone();
                async move {
                    seen.lock().unwrap().push(request.uri().path().to_owned());
                    (status, axum::Json(body)).into_response()
                }
            });
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let addr = listener.local_addr().unwrap();
            let task = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
            let client =
                OpenCodeClient::new(&format!("http://{addr}"), "opencode", "fixture-only").unwrap();
            assert_eq!(client.verify().await.unwrap_err().code(), expected);
            assert_eq!(*calls.lock().unwrap(), vec!["/api/info"]);
            task.abort();
        }
    }
    #[tokio::test]
    async fn local_preflight_never_requires_network_or_protocol_detection() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        drop(listener);
        let client =
            OpenCodeClient::new(&format!("http://{addr}"), "opencode", "fixture-only").unwrap();
        assert_eq!(
            client
                .resolve_model("/repo", "provider/model")
                .await
                .unwrap(),
            "provider/model"
        );
        assert_eq!(
            client
                .resolve_model("/repo", "invalid")
                .await
                .unwrap_err()
                .code(),
            "invalid_model"
        );
        assert_eq!(
            client.observe("/repo", "invalid").await.unwrap_err().code(),
            "invalid_session"
        );
        assert_eq!(
            client.abort("/repo", "invalid").await.unwrap_err().code(),
            "invalid_session"
        );
        assert_eq!(
            client
                .prompt(
                    "/repo",
                    "invalid",
                    "planner",
                    "provider/model",
                    "instructions",
                    "text",
                    true
                )
                .await
                .unwrap_err()
                .code(),
            "invalid_session"
        );
        assert_eq!(
            client
                .prompt(
                    "/repo",
                    "ses_test",
                    "planner",
                    "provider/model",
                    "instructions",
                    "text",
                    false
                )
                .await
                .unwrap_err()
                .code(),
            "invalid_role"
        );
        assert_eq!(
            client
                .person_directory_status(&[], &[])
                .await
                .unwrap_err()
                .code(),
            "person_directory_unknown"
        );
    }
}

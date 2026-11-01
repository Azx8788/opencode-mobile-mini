//! Local HTTP fixtures only; root runs these under the shared machine lock.
use axum::{
    http::{header, StatusCode},
    response::IntoResponse,
    routing::get,
    Json, Router,
};
use oc_phone_engine::opencode::{GlobalStatusObservation, OpenCodeClient};
use serde_json::{json, Value};

async fn server(
    fixtures: Value,
    events: &'static str,
) -> (OpenCodeClient, tokio::task::JoinHandle<()>) {
    let app = Router::new()
        .route(
            "/api/info",
            get(|| async {
                Json(json!({"version":"2.0.29","pid":1,"urls":[],"paths":{"tmp":"/tmp"}}))
            }),
        )
        .route(
            "/openapi.json",
            get(|| async {
                Json(
                    serde_json::from_str::<Value>(include_str!(
                        "fixtures/oc2-2.0.29-driver-openapi.json"
                    ))
                    .unwrap(),
                )
            }),
        )
        .route(
            "/api/session/active",
            get(move || {
                let fixtures = fixtures.clone();
                async move { Json(fixtures) }
            }),
        )
        .route(
            "/api/event",
            get(move || async move {
                (
                    StatusCode::OK,
                    [(header::CONTENT_TYPE, "text/event-stream")],
                    events,
                )
                    .into_response()
            }),
        );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let task = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    let client = OpenCodeClient::new(
        &format!("http://{address}"),
        "opencode",
        "fixture-only-password",
    )
    .unwrap();
    (client, task)
}

#[tokio::test]
async fn process_wide_active_sessions_block_every_directory_except_team_sessions() {
    let (client, task) = server(json!({"data":{"ses_person":{"type":"running"}}}), "").await;
    for directory in ["/person/first", "/person/second", "/unseen"] {
        assert!(!client
            .person_directory_status(&[directory.into()], &[])
            .await
            .unwrap());
        assert!(client
            .person_directory_status(&[directory.into()], &["ses_person".into()])
            .await
            .unwrap());
    }
    assert!(client.person_directory_status(&[], &[]).await.is_err());
    assert!(client
        .person_directory_status(&["unknown".into()], &[])
        .await
        .is_err());
    task.abort();
}

#[tokio::test]
async fn malformed_active_snapshot_never_grants_idle() {
    let (client, task) = server(json!({"data":{"ses_person":{"type":"unknown"}}}), "").await;
    assert_eq!(
        client
            .person_directory_status(&["/first".into()], &[])
            .await
            .unwrap_err()
            .code(),
        "invalid_status"
    );
    task.abort();
}

#[tokio::test]
async fn unknown_directory_busy_blocks_until_exact_idle_and_eof_never_grants_idle() {
    const EVENTS: &str = concat!(
        "data: {\"type\":\"server.connected\",\"data\":{}}\n\n",
        "data: {\"location\":{\"directory\":\"/unknown-client\"},\"type\":\"session.status\",\"data\":{\"sessionID\":\"ses_person\",\"status\":{\"type\":\"busy\"}}}\n\n",
        "data: {\"location\":{\"directory\":\"/known\"},\"type\":\"session.status\",\"data\":{\"sessionID\":\"ses_person\",\"status\":{\"type\":\"idle\"}}}\n\n",
        "data: {\"location\":{\"directory\":\"/unknown-client\"},\"type\":\"session.idle\",\"data\":{\"sessionID\":\"ses_person\"}}\n\n"
    );
    let (client, server) = server(json!({}), EVENTS).await;
    let mut observer = client.global_status_observer().await.unwrap();
    assert_eq!(
        observer.next().await.unwrap(),
        GlobalStatusObservation::Other
    );
    assert!(matches!(
        observer.next().await.unwrap(),
        GlobalStatusObservation::Status { busy: true, .. }
    ));
    assert!(observer.observed_non_team_busy(&[]).unwrap());
    assert!(!observer
        .observed_non_team_busy(&["ses_person".into()])
        .unwrap());
    assert!(matches!(
        observer.next().await.unwrap(),
        GlobalStatusObservation::Status { busy: false, .. }
    ));
    assert!(observer.observed_non_team_busy(&[]).unwrap());
    assert!(matches!(
        observer.next().await.unwrap(),
        GlobalStatusObservation::Status { busy: false, .. }
    ));
    assert!(!observer.observed_non_team_busy(&[]).unwrap()); // Evidence set only; never admission.
    assert_eq!(
        observer.next().await.unwrap_err().code(),
        "global_status_disconnected"
    );
    assert!(!observer.connected());
    assert!(observer.observed_non_team_busy(&[]).is_err());
    // A new connection is still incomplete history, with no global idle proof.
    let mut reconnected = client.global_status_observer().await.unwrap();
    assert_eq!(
        reconnected.next().await.unwrap(),
        GlobalStatusObservation::Other
    );
    assert!(matches!(
        reconnected.next().await.unwrap(),
        GlobalStatusObservation::Status { busy: true, .. }
    ));
    assert!(reconnected.observed_non_team_busy(&[]).unwrap());
    server.abort();
}

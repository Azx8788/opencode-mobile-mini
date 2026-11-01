use oc_phone_engine::scheduler::{evaluate, Admission, AdmissionContext};
use serde_json::{json, Value};

fn input() -> (Value, Value, AdmissionContext) {
    let p = json!({"id":"p","status":"running","spendDay":"2026-09-30","settings":{"mode":"single","maxLanes":4,"chargingOnly":false,"budget":{"chosen":true,"unlimited":true}}});
    let j = json!({"id":"j","kind":"task","projectId":"p","taskId":"t","serverId":"phone","stage":"queued","dependsOn":[]});
    let c = AdmissionContext {
        now_ms: 10000,
        chat_idle: Some(true),
        chat_observed_ms: Some(9999),
        server_online: true,
        lane_cap: 2,
        ..Default::default()
    };
    (p, j, c)
}
#[test]
fn fresh_idle_evidence_is_required_and_future_observations_fail_closed() {
    let (p, j, mut c) = input();
    assert_eq!(evaluate(&p, &j, &[], &c), Admission::Admit);
    c.chat_idle = None;
    assert_eq!(
        evaluate(&p, &j, &[], &c),
        Admission::Pause("chatStateUnknown")
    );
    c.chat_idle = Some(true);
    c.chat_observed_ms = Some(1);
    assert_eq!(
        evaluate(&p, &j, &[], &c),
        Admission::Pause("chatStateUnknown")
    );
    c.chat_observed_ms = Some(10001);
    assert_eq!(
        evaluate(&p, &j, &[], &c),
        Admission::Pause("chatStateUnknown")
    );
    c.chat_observed_ms = Some(9999);
    c.chat_idle = Some(false);
    assert_eq!(evaluate(&p, &j, &[], &c), Admission::Wait("chatBusy"));
}
#[test]
fn single_cap_is_project_wide_and_parallel_cap_is_server_wide() {
    let (mut p, j, c) = input();
    let other = json!({"projectId":"p","serverId":"other","stage":"starting"});
    assert_eq!(evaluate(&p, &j, &[other], &c), Admission::Wait("laneCap"));
    p["settings"]["mode"] = json!("parallel");
    let other = json!({"projectId":"other","serverId":"phone","stage":"running"});
    assert_eq!(evaluate(&p, &j, &[other.clone()], &c), Admission::Admit);
    assert_eq!(
        evaluate(&p, &j, &[other.clone(), other], &c),
        Admission::Wait("laneCap")
    );
}
#[test]
fn dependencies_require_durable_completion() {
    let (p, mut j, c) = input();
    j["dependsOn"] = json!(["before"]);
    assert_eq!(
        evaluate(&p, &j, &[], &c),
        Admission::Pause("missingDependency")
    );
    let mut dep = json!({"projectId":"p","taskId":"before","stage":"interrupted"});
    assert_eq!(
        evaluate(&p, &j, &[dep.clone()], &c),
        Admission::Wait("dependencyPending")
    );
    dep["stage"] = json!("completed");
    assert_eq!(evaluate(&p, &j, &[dep], &c), Admission::Admit);
}
#[test]
fn charging_only_does_not_invent_power_state() {
    let (mut p, j, mut c) = input();
    p["settings"]["chargingOnly"] = json!(true);
    assert_eq!(
        evaluate(&p, &j, &[], &c),
        Admission::Pause("chargingUnknown")
    );
    c.charging = Some(false);
    assert_eq!(
        evaluate(&p, &j, &[], &c),
        Admission::Wait("chargingRequired")
    );
    c.charging = Some(true);
    assert_eq!(evaluate(&p, &j, &[], &c), Admission::Admit);
}
#[test]
fn ceilings_require_real_usage_and_pause_at_exact_limit() {
    let (mut p, j, mut c) = input();
    p["settings"]["budget"] = json!({"chosen":true,"unlimited":false,"total":1.0,"daily":null});
    assert_eq!(
        evaluate(&p, &j, &[], &c),
        Admission::Pause("totalUsageUnknown")
    );
    c.observed_total_cost = Some(0.5);
    assert_eq!(evaluate(&p, &j, &[], &c), Admission::Admit);
    c.observed_total_cost = Some(1.0);
    assert_eq!(evaluate(&p, &j, &[], &c), Admission::Pause("budgetReached"));
    c.observed_total_cost = Some(f64::NAN);
    assert_eq!(
        evaluate(&p, &j, &[], &c),
        Admission::Pause("totalUsageUnknown")
    );
}
#[test]
fn daily_evidence_and_task_token_evidence_do_not_cross_days_or_tasks() {
    let (mut p, j, mut c) = input();
    p["settings"]["budget"] = json!({"chosen":true,"unlimited":false,"daily":1.0,"taskTokens":100});
    c.observed_daily_cost = Some(0.2);
    c.utc_day = "2026-10-01".into();
    assert_eq!(
        evaluate(&p, &j, &[], &c),
        Admission::Pause("dailyUsageUnknown")
    );
    c.utc_day = "2026-09-30".into();
    assert_eq!(
        evaluate(&p, &j, &[], &c),
        Admission::Pause("tokenUsageUnknown")
    );
    c.observed_task_tokens = Some(100);
    assert_eq!(
        evaluate(&p, &j, &[], &c),
        Admission::Pause("taskTokenBudgetReached")
    );
    c.observed_task_tokens = Some(1);
    assert_eq!(evaluate(&p, &j, &[], &c), Admission::Admit);
}
#[test]
fn recoverable_interrupted_job_cannot_be_admitted_as_new_submission() {
    let (p, mut j, c) = input();
    j["stage"] = json!("interrupted");
    assert_eq!(evaluate(&p, &j, &[], &c), Admission::Wait("jobNotQueued"));
}

//! Pure admission decisions; the caller persists Pause/Wait before external work.
use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Admission {
    Admit,
    Wait(&'static str),
    Pause(&'static str),
}

#[derive(Debug, Clone)]
pub struct AdmissionContext {
    pub now_ms: u64,
    pub chat_idle: Option<bool>,
    pub chat_observed_ms: Option<u64>,
    pub chat_max_age_ms: u64,
    pub charging: Option<bool>,
    pub server_online: bool,
    pub lane_cap: usize,
    pub utc_day: String,
    pub observed_total_cost: Option<f64>,
    pub observed_daily_cost: Option<f64>,
    pub observed_task_tokens: Option<u64>,
}

impl Default for AdmissionContext {
    fn default() -> Self {
        Self {
            now_ms: 0,
            chat_idle: None,
            chat_observed_ms: None,
            chat_max_age_ms: 5_000,
            charging: None,
            server_online: false,
            lane_cap: 0,
            utc_day: String::new(),
            observed_total_cost: None,
            observed_daily_cost: None,
            observed_task_tokens: None,
        }
    }
}

pub fn active_stage(stage: &str) -> bool {
    matches!(
        stage,
        "starting"
            | "resuming"
            | "planning"
            | "preparing"
            | "submitting"
            | "working"
            | "checking"
            | "collecting"
            | "merging"
            | "promoting"
            | "running"
    )
}

pub fn evaluate(project: &Value, job: &Value, jobs: &[Value], c: &AdmissionContext) -> Admission {
    if job["stage"] != "queued" {
        return Admission::Wait("jobNotQueued");
    }
    let planner = job["kind"] == "planner";
    if project["status"] != "running" && !(planner && project["status"] == "planning") {
        return Admission::Wait("projectNotRunning");
    }
    if !c.server_online {
        return Admission::Wait("serverOffline");
    }
    match (c.chat_idle, c.chat_observed_ms) {
        (Some(true), Some(at)) if at <= c.now_ms && c.now_ms - at <= c.chat_max_age_ms => {}
        (Some(false), Some(at)) if at <= c.now_ms && c.now_ms - at <= c.chat_max_age_ms => {
            return Admission::Wait("chatBusy")
        }
        _ => return Admission::Pause("chatStateUnknown"),
    }
    let s = &project["settings"];
    if s["chargingOnly"] == true {
        match c.charging {
            Some(true) => {}
            Some(false) => return Admission::Wait("chargingRequired"),
            None => return Admission::Pause("chargingUnknown"),
        }
    }
    let cap = match s["mode"].as_str() {
        Some("single") => 1,
        Some("parallel") => match s["maxLanes"].as_u64() {
            Some(n @ 1..=32) => n as usize,
            _ => return Admission::Pause("chooseExecutionMode"),
        },
        _ => return Admission::Pause("chooseExecutionMode"),
    };
    if c.lane_cap == 0 {
        return Admission::Pause("serverCapUnknown");
    }
    let active = jobs
        .iter()
        .filter(|j| active_stage(j["stage"].as_str().unwrap_or("")));
    let project_active = active
        .clone()
        .filter(|j| j["projectId"] == job["projectId"])
        .count();
    let server_active = active.filter(|j| j["serverId"] == job["serverId"]).count();
    if project_active >= cap || server_active >= c.lane_cap {
        return Admission::Wait("laneCap");
    }
    let Some(deps) = job["dependsOn"].as_array() else {
        return Admission::Pause("invalidDependencies");
    };
    for dep in deps {
        let found = jobs
            .iter()
            .find(|j| j["projectId"] == job["projectId"] && j["taskId"] == *dep);
        match found {
            Some(j) if j["stage"] == "merged" || j["stage"] == "completed" => {}
            Some(_) => return Admission::Wait("dependencyPending"),
            None => return Admission::Pause("missingDependency"),
        }
    }
    let b = &s["budget"];
    if b["chosen"] != true {
        return Admission::Pause("chooseBudget");
    }
    if b["unlimited"] != true {
        if b["total"].is_null() && b["daily"].is_null() {
            return Admission::Pause("chooseBudget");
        }
        for (limit, observed, unknown) in [
            (&b["total"], c.observed_total_cost, "totalUsageUnknown"),
            (&b["daily"], c.observed_daily_cost, "dailyUsageUnknown"),
        ] {
            if limit.is_null() {
                continue;
            }
            let Some(limit) = limit.as_f64().filter(|v| v.is_finite() && *v > 0.0) else {
                return Admission::Pause("invalidBudget");
            };
            let Some(actual) = observed.filter(|v| v.is_finite() && *v >= 0.0) else {
                return Admission::Pause(unknown);
            };
            if unknown == "dailyUsageUnknown"
                && (c.utc_day.is_empty()
                    || project["spendDay"].as_str() != Some(c.utc_day.as_str()))
            {
                return Admission::Pause("dailyUsageUnknown");
            }
            if actual >= limit {
                return Admission::Pause("budgetReached");
            }
        }
    }
    if !b["taskTokens"].is_null() {
        let Some(limit) = b["taskTokens"].as_u64().filter(|v| *v > 0) else {
            return Admission::Pause("invalidBudget");
        };
        let Some(actual) = c.observed_task_tokens else {
            return Admission::Pause("tokenUsageUnknown");
        };
        if actual >= limit {
            return Admission::Pause("taskTokenBudgetReached");
        }
    }
    Admission::Admit
}

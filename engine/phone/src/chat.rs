//! App-authoritative admission lease. Expiry is unknown, never idle.
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet, HashSet};

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ChatHeartbeat {
    pub until: u64,
    pub session_ids: Vec<String>,
    pub directories: Vec<String>,
    pub known: bool,
    pub app_instance: String,
    pub sequence: u64,
}

#[derive(Debug, PartialEq, Eq)]
pub enum ChatAdmission {
    Idle,
    Busy,
    Unknown,
    PollKnownDirectories,
}

#[derive(Clone, Default)]
pub struct ChatLedger {
    current: Option<ChatHeartbeat>,
    received_at: u64,
    retired: HashSet<String>,
    directories: BTreeMap<String, u64>,
    directory_clock: u64,
    worker_root: Option<String>,
    snapshot_busy: bool,
    observed_busy: BTreeSet<(String, String)>,
    observation_revision: u64,
    observation_unknown: bool,
}

impl ChatLedger {
    pub fn accept(&mut self, mut heartbeat: ChatHeartbeat, now: u64) -> Result<(), &'static str> {
        heartbeat
            .directories
            .retain(|dir| !self.is_worker_directory(dir));
        if heartbeat.until <= now
            || heartbeat.until > now.saturating_add(30_000)
            || heartbeat.session_ids.len() > 1000
            || heartbeat.directories.len() > 256
            || !crate::config::valid_id(&heartbeat.app_instance)
            || heartbeat
                .session_ids
                .iter()
                .any(|id| id.is_empty() || id.len() > 256 || id.chars().any(char::is_whitespace))
            || heartbeat
                .directories
                .iter()
                .any(|path| !valid_directory(path))
        {
            return Err("heartbeatInvalid");
        }
        if self.retired.contains(&heartbeat.app_instance) {
            return Err("heartbeatStale");
        }
        if let Some(previous) = &self.current {
            if previous.app_instance == heartbeat.app_instance {
                if heartbeat.sequence <= previous.sequence {
                    return Err("heartbeatStale");
                }
            } else {
                if self.retired.len() >= 128 {
                    return Err("heartbeatGenerationLimit");
                }
            }
        }
        // Build capacity changes transactionally. The incoming heartbeat protects
        // its own complete directory set, not stale directories from an old lease.
        let mut proposed = self.clone();
        for directory in &heartbeat.directories {
            proposed.learn_directory_protected(directory, &heartbeat.directories)?;
        }
        if let Some(previous) = &self.current {
            if previous.app_instance != heartbeat.app_instance {
                self.retired.insert(previous.app_instance.clone());
            }
        }
        self.directories = proposed.directories;
        self.directory_clock = proposed.directory_clock;
        self.observation_revision = proposed.observation_revision;
        self.received_at = now;
        self.current = Some(heartbeat);
        Ok(())
    }

    pub fn admission(&self, now: u64, app_alive: Option<bool>, team: &[String]) -> ChatAdmission {
        // Any observed busy non-team session blocks, including another device.
        // SSE silence/reconnect is not an authoritative idle checkpoint.
        if self.observation_unknown {
            return ChatAdmission::Unknown;
        }
        if self.snapshot_busy || self.observed_busy.iter().any(|(_, id)| !team.contains(id)) {
            return ChatAdmission::Busy;
        }
        match app_alive {
            Some(true) => match &self.current {
                Some(value) if now >= self.received_at && now < value.until && value.known => {
                    if value.session_ids.iter().any(|id| !team.contains(id)) {
                        ChatAdmission::Busy
                    } else {
                        ChatAdmission::Idle
                    }
                }
                _ => ChatAdmission::Unknown,
            },
            Some(false) if !self.directories.is_empty() => ChatAdmission::PollKnownDirectories,
            _ => ChatAdmission::Unknown,
        }
    }

    pub fn with_worker_root(root: &str) -> Self {
        Self {
            worker_root: Some(root.trim_end_matches('/').to_owned()),
            ..Self::default()
        }
    }

    pub fn is_worker_directory(&self, directory: &str) -> bool {
        self.worker_root.as_ref().is_some_and(|root| {
            directory == root
                || directory
                    .strip_prefix(root)
                    .is_some_and(|suffix| suffix.starts_with('/'))
        })
    }

    pub fn learn_directory(&mut self, directory: &str) -> Result<(), &'static str> {
        let protected = self
            .current
            .as_ref()
            .map(|h| h.directories.clone())
            .unwrap_or_default();
        self.learn_directory_protected(directory, &protected)
    }

    fn learn_directory_protected(
        &mut self,
        directory: &str,
        protected: &[String],
    ) -> Result<(), &'static str> {
        if self.is_worker_directory(directory) {
            return Ok(());
        }
        if !valid_directory(directory) {
            return Err("directoryUnknown");
        }
        if !self.directories.contains_key(directory) && self.directories.len() >= 256 {
            if self.snapshot_busy {
                return Err("directoryLimit");
            }
            // Never drop a busy scope or one still covered by the current lease.
            let victim = self
                .directories
                .iter()
                .filter(|(path, _)| {
                    !protected.contains(path)
                        && !self
                            .observed_busy
                            .iter()
                            .any(|(busy_path, _)| busy_path == *path)
                })
                .min_by_key(|(_, used)| **used)
                .map(|(path, _)| path.clone())
                .ok_or("directoryLimit")?;
            self.directories.remove(&victim);
        }
        if !self.directories.contains_key(directory) {
            self.observation_revision = self.observation_revision.saturating_add(1);
        }
        self.directory_clock = self.directory_clock.saturating_add(1);
        self.directories
            .insert(directory.to_owned(), self.directory_clock);
        Ok(())
    }

    pub fn observe(
        &mut self,
        directory: &str,
        session: &str,
        busy: bool,
    ) -> Result<(), &'static str> {
        // The namespace fence applies before the session ID enters the durable
        // job ledger: session creation may emit status before that ID is known.
        if self.is_worker_directory(directory) {
            return Ok(());
        }
        self.observation_revision = self.observation_revision.saturating_add(1);
        if !valid_directory(directory) {
            return Err("directoryUnknown");
        }
        if session.is_empty() || session.len() > 256 {
            return Err("sessionUnknown");
        }
        let key = (directory.to_owned(), session.to_owned());
        if busy {
            if self.observed_busy.len() >= 1000 && !self.observed_busy.contains(&key) {
                return Err("sessionLimit");
            }
            // Preserve busy evidence even if every bounded directory slot is
            // busy. A partial snapshot must never forget this rejected scope.
            self.observed_busy.insert(key);
        } else {
            self.observed_busy.remove(&key);
        }
        self.learn_directory(directory)?;
        Ok(())
    }

    pub fn observation_revision(&self) -> u64 {
        self.observation_revision
    }
    pub fn reconcile_snapshot(
        &mut self,
        revision: u64,
        connected: bool,
        result: Result<bool, ()>,
    ) -> bool {
        if !connected || self.observation_revision != revision {
            return false;
        }
        let Ok(idle) = result else {
            return false;
        };
        self.observation_unknown = false;
        self.snapshot_busy = !idle;
        if idle {
            self.observed_busy.clear();
        }
        true
    }
    pub fn observation_unknown(&mut self) {
        // Also fence polls started before a malformed frame or disconnection.
        self.observation_revision = self.observation_revision.saturating_add(1);
        self.observation_unknown = true;
    }
    pub fn needs_reconciliation(&self) -> bool {
        self.observation_unknown || self.snapshot_busy || !self.observed_busy.is_empty()
    }

    pub fn persisted_directories(&self) -> Vec<String> {
        self.directories.keys().cloned().collect()
    }

    pub fn directories(&self) -> Vec<String> {
        // Overflow busy scopes are included: if this exceeds the poll bound,
        // admission remains paused until authoritative idle events drain them.
        self.directories
            .keys()
            .cloned()
            .chain(self.observed_busy.iter().map(|(path, _)| path.clone()))
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect()
    }
}

fn valid_directory(path: &str) -> bool {
    path.starts_with('/')
        && path.len() <= 4096
        && !path.contains('\0')
        && !path.split('/').any(|part| part == "." || part == "..")
}

#[cfg(test)]
mod tests {
    use super::*;
    fn heartbeat(seq: u64, ids: &[&str]) -> ChatHeartbeat {
        ChatHeartbeat {
            until: 31_000,
            session_ids: ids.iter().map(|s| s.to_string()).collect(),
            directories: vec!["/root/projects/person".into()],
            known: true,
            app_instance: "instance".into(),
            sequence: seq,
        }
    }
    #[test]
    fn worker_birth_races_never_fill_person_ledger() {
        let root = "/root/aiteam/work/profile";
        let mut ledger = ChatLedger::with_worker_root(root);
        ledger.accept(heartbeat(1, &[]), 1000).unwrap();
        for task in 0..600 {
            let directory = format!("{root}/repo/task-{task}");
            let session = format!("unknown-until-job-ledger-{task}");
            ledger.observe(&directory, &session, true).unwrap();
            let mut value = heartbeat(task + 2, &[]);
            value.directories.push(directory.clone());
            ledger.accept(value, 1000).unwrap();
            ledger.observe(&directory, &session, false).unwrap();
        }
        assert_eq!(ledger.directories(), vec!["/root/projects/person"]);
        assert_eq!(ledger.admission(2000, Some(true), &[]), ChatAdmission::Idle);
        // A similar path outside the namespace must remain a real person scope.
        ledger
            .observe("/root/aiteam/work/profile-other", "person", true)
            .unwrap();
        assert_eq!(ledger.admission(2000, Some(true), &[]), ChatAdmission::Busy);
    }

    #[test]
    fn directory_lru_only_evicts_idle_unprotected_scopes() {
        let mut ledger = ChatLedger::default();
        ledger.accept(heartbeat(1, &[]), 1000).unwrap();
        ledger.observe("/root/old-busy", "person", true).unwrap();
        for index in 0..600 {
            ledger
                .observe(&format!("/root/idle-{index}"), "idle", false)
                .unwrap();
        }
        let dirs = ledger.directories();
        assert_eq!(dirs.len(), 256);
        assert!(dirs.contains(&"/root/old-busy".to_owned()));
        assert!(dirs.contains(&"/root/projects/person".to_owned()));
        assert!(!dirs.contains(&"/root/idle-0".to_owned()));
        assert_eq!(ledger.admission(2000, Some(true), &[]), ChatAdmission::Busy);
    }

    #[test]
    fn full_busy_capacity_keeps_overflow_evidence_and_fails_closed() {
        let mut ledger = ChatLedger::default();
        for index in 0..256 {
            ledger
                .observe(&format!("/root/busy-{index}"), "person", true)
                .unwrap();
        }
        assert_eq!(
            ledger.observe("/root/overflow", "person", true),
            Err("directoryLimit")
        );
        ledger.observation_unknown();
        assert_eq!(ledger.directories().len(), 257);
        assert_eq!(
            ledger.admission(2000, Some(true), &[]),
            ChatAdmission::Unknown
        );
        // A known idle event creates room; all other busy evidence survives.
        ledger.observe("/root/busy-0", "person", false).unwrap();
        ledger.learn_directory("/root/overflow").unwrap();
        let revision = ledger.observation_revision();
        assert!(ledger.reconcile_snapshot(revision, true, Ok(false)));
        assert_eq!(ledger.admission(2000, Some(true), &[]), ChatAdmission::Busy);
    }

    #[test]
    fn malformed_observation_recovers_only_from_complete_fresh_connected_snapshot() {
        let mut ledger = ChatLedger::default();
        ledger.accept(heartbeat(1, &[]), 1000).unwrap();
        ledger.observation_unknown(); // malformed frame or stream loss
        ledger.accept(heartbeat(2, &[]), 1000).unwrap();
        let revision = ledger.observation_revision();
        assert!(!ledger.reconcile_snapshot(revision, true, Err(())));
        assert!(!ledger.reconcile_snapshot(revision, false, Ok(true)));
        assert_eq!(
            ledger.admission(2000, Some(true), &[]),
            ChatAdmission::Unknown
        );
        ledger.observation_unknown(); // disconnect/reconnect during the poll
        assert!(!ledger.reconcile_snapshot(revision, true, Ok(true)));
        assert_eq!(
            ledger.admission(2000, Some(true), &[]),
            ChatAdmission::Unknown
        );
        let revision = ledger.observation_revision();
        assert!(ledger.reconcile_snapshot(revision, true, Ok(false)));
        assert_eq!(ledger.admission(2000, Some(true), &[]), ChatAdmission::Busy);
        assert!(ledger.reconcile_snapshot(revision, true, Ok(true)));
        assert_eq!(ledger.admission(2000, Some(true), &[]), ChatAdmission::Idle);
    }

    #[test]
    fn heartbeat_teaching_a_new_directory_fences_inflight_snapshot() {
        let mut ledger = ChatLedger::default();
        ledger.accept(heartbeat(1, &[]), 1000).unwrap();
        ledger.observation_unknown();
        let revision = ledger.observation_revision();
        let mut value = heartbeat(2, &[]);
        value.directories.push("/root/new-person-directory".into());
        ledger.accept(value, 1000).unwrap();
        assert!(!ledger.reconcile_snapshot(revision, true, Ok(true)));
        assert_eq!(
            ledger.admission(2000, Some(true), &[]),
            ChatAdmission::Unknown
        );
    }

    #[test]
    fn strict_idle_poll_does_not_erase_a_newer_busy_observation() {
        let mut ledger = ChatLedger::default();
        ledger.accept(heartbeat(1, &[]), 1000).unwrap();
        ledger.observe("/root/other", "one", true).unwrap();
        let polling_revision = ledger.observation_revision();
        ledger.observe("/root/other", "two", true).unwrap();
        ledger.reconcile_snapshot(polling_revision, true, Ok(true));
        assert_eq!(ledger.admission(2000, Some(true), &[]), ChatAdmission::Busy);
        ledger.reconcile_snapshot(ledger.observation_revision(), true, Ok(true));
        assert_eq!(ledger.admission(2000, Some(true), &[]), ChatAdmission::Idle);
        ledger.observation_unknown();
        assert_eq!(
            ledger.admission(2000, Some(true), &[]),
            ChatAdmission::Unknown
        );
    }
    #[test]
    fn missing_expired_unknown_and_reversed_clock_never_mean_idle() {
        let mut ledger = ChatLedger::default();
        assert_eq!(
            ledger.admission(1000, Some(true), &[]),
            ChatAdmission::Unknown
        );
        ledger.accept(heartbeat(1, &[]), 1000).unwrap();
        assert_eq!(ledger.admission(2000, Some(true), &[]), ChatAdmission::Idle);
        assert_eq!(
            ledger.admission(31_000, Some(true), &[]),
            ChatAdmission::Unknown
        );
        assert_eq!(
            ledger.admission(999, Some(true), &[]),
            ChatAdmission::Unknown
        );
        assert_eq!(ledger.admission(2000, None, &[]), ChatAdmission::Unknown);
        let mut unknown = heartbeat(2, &[]);
        unknown.known = false;
        ledger.accept(unknown, 2000).unwrap();
        assert_eq!(
            ledger.admission(3000, Some(true), &[]),
            ChatAdmission::Unknown
        );
    }
    #[test]
    fn person_busy_blocks_and_team_ids_do_not_impersonate_a_person() {
        let mut ledger = ChatLedger::default();
        ledger
            .accept(heartbeat(1, &["person", "team"]), 1000)
            .unwrap();
        assert_eq!(
            ledger.admission(2000, Some(true), &["team".into()]),
            ChatAdmission::Busy
        );
        ledger.accept(heartbeat(2, &["team"]), 2000).unwrap();
        assert_eq!(
            ledger.admission(3000, Some(true), &["team".into()]),
            ChatAdmission::Idle
        );
        ledger.observe("/root/other-device", "other", true).unwrap();
        assert_eq!(ledger.admission(3000, Some(true), &[]), ChatAdmission::Busy);
        ledger
            .observe("/root/other-device", "other", false)
            .unwrap();
        assert_eq!(
            ledger.admission(40_000, Some(true), &[]),
            ChatAdmission::Unknown
        );
    }
    #[test]
    fn alive_process_cannot_fall_back_and_old_inflight_heartbeats_cannot_replace_busy() {
        let mut ledger = ChatLedger::default();
        ledger.accept(heartbeat(2, &["person"]), 1000).unwrap();
        assert_eq!(
            ledger.accept(heartbeat(1, &[]), 1000),
            Err("heartbeatStale")
        );
        assert_eq!(
            ledger.admission(32_000, Some(true), &[]),
            ChatAdmission::Unknown
        );
        assert_eq!(
            ledger.admission(32_000, Some(false), &[]),
            ChatAdmission::PollKnownDirectories
        );
        let mut new = heartbeat(1, &[]);
        new.app_instance = "new-instance".into();
        ledger.accept(new, 2000).unwrap();
        assert_eq!(
            ledger.accept(heartbeat(3, &[]), 2000),
            Err("heartbeatStale")
        );
    }
}

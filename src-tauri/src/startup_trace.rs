//! Opt-in, bounded startup diagnostics. No paths, credentials or response bodies.
use serde::Serialize;
use std::path::PathBuf;
use std::time::Instant;

#[derive(Serialize)]
struct Event {
    phase: &'static str,
    elapsed_ms: f64,
    duration_ms: f64,
}

pub struct Trace {
    started: Instant,
    destination: Option<PathBuf>,
    events: Vec<Event>,
}

impl Trace {
    pub fn from_env() -> Self {
        Self::new(
            std::env::var_os("MUSICSERVER_STARTUP_TRACE")
                .filter(|p| !p.is_empty())
                .map(PathBuf::from),
        )
    }

    fn new(destination: Option<PathBuf>) -> Self {
        Self {
            started: Instant::now(),
            destination,
            events: Vec::new(),
        }
    }

    pub fn record(&mut self, phase: &'static str, since: Instant) {
        if self.destination.is_some() && self.events.len() < 64 {
            self.events.push(Event {
                phase,
                elapsed_ms: self.started.elapsed().as_secs_f64() * 1000.0,
                duration_ms: since.elapsed().as_secs_f64() * 1000.0,
            });
        }
    }

    // Diagnostics must neither overwrite an existing file nor prevent startup.
    // The caller creates the parent directory and uses a unique path per launch.
    pub fn finish(&self, build_id: &str, outcome: &str) -> std::io::Result<()> {
        if let Some(path) = &self.destination {
            let file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(path)?;
            serde_json::to_writer(
                file,
                &serde_json::json!({
                    "schema": 1, "build_id": build_id, "pid": std::process::id(),
                    "outcome": outcome, "total_ms": self.started.elapsed().as_secs_f64() * 1000.0,
                    "scope": "desktop setup through navigation request; not rendered UI readiness",
                    "events": self.events
                }),
            )?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trace_is_bounded_and_never_overwrites_existing_output() {
        let path = std::env::temp_dir().join(format!(
            "musicserver-trace-{}-{}.json",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let mut trace = Trace::new(Some(path.clone()));
        for _ in 0..100 {
            trace.record("probe", Instant::now());
        }
        trace.finish("test-build", "failed").unwrap();
        let bytes = std::fs::read(&path).unwrap();
        let report: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(report["events"].as_array().unwrap().len(), 64);
        assert_eq!(report["outcome"], "failed");
        assert!(report["total_ms"].as_f64().unwrap() >= 0.0);
        assert!(trace.finish("other", "ready").is_err());
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn disabled_trace_collects_nothing() {
        let mut trace = Trace::new(None);
        trace.record("probe", Instant::now());
        assert!(trace.events.is_empty());
        trace.finish("test", "ready").unwrap();
    }
}

use tokio::sync::broadcast;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UploaderLog {
    pub level: String,
    pub message: String,
}

impl UploaderLog {
    pub fn new(level: impl ToString, message: impl Into<String>) -> Self {
        Self {
            level: level.to_string().trim().to_ascii_lowercase(),
            message: message.into(),
        }
    }

    pub fn info(message: impl Into<String>) -> Self {
        Self::new("info", message)
    }
}

pub fn init(uploader_log_tx: broadcast::Sender<UploaderLog>) {
    let logger = UploaderLogger::new(
        env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).build(),
        uploader_log_tx,
    );
    let max_level = logger.max_level();

    log::set_boxed_logger(Box::new(logger)).expect("logger should only be initialized once");
    log::set_max_level(max_level);
}

struct UploaderLogger {
    inner: env_logger::Logger,
    uploader_log_tx: broadcast::Sender<UploaderLog>,
}

impl UploaderLogger {
    fn new(inner: env_logger::Logger, uploader_log_tx: broadcast::Sender<UploaderLog>) -> Self {
        Self {
            inner,
            uploader_log_tx,
        }
    }

    fn max_level(&self) -> log::LevelFilter {
        self.inner.filter()
    }
}

impl log::Log for UploaderLogger {
    fn enabled(&self, metadata: &log::Metadata<'_>) -> bool {
        self.inner.enabled(metadata)
    }

    fn log(&self, record: &log::Record<'_>) {
        if !self.enabled(record.metadata()) {
            return;
        }

        self.inner.log(record);
        let _ = self
            .uploader_log_tx
            .send(UploaderLog::new(record.level(), record.args().to_string()));
    }

    fn flush(&self) {
        self.inner.flush();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use log::{Level, Log, Record};

    fn test_logger() -> (UploaderLogger, broadcast::Receiver<UploaderLog>) {
        let (uploader_log_tx, uploader_log_rx) = broadcast::channel(8);
        let inner = env_logger::Builder::new()
            .filter_level(log::LevelFilter::Info)
            .is_test(true)
            .build();

        (UploaderLogger::new(inner, uploader_log_tx), uploader_log_rx)
    }

    #[test]
    fn forwards_enabled_log_records_to_uploader_log_channel() {
        let (logger, mut uploader_log_rx) = test_logger();
        let args = format_args!("connected to {}", "radar:config");
        let record = Record::builder()
            .level(Level::Info)
            .target("uploader")
            .args(args)
            .build();

        logger.log(&record);

        assert_eq!(
            uploader_log_rx.try_recv().unwrap(),
            UploaderLog {
                level: "info".to_string(),
                message: "connected to radar:config".to_string(),
            }
        );
    }

    #[test]
    fn ignores_disabled_log_records() {
        let (logger, mut uploader_log_rx) = test_logger();
        let args = format_args!("too detailed");
        let record = Record::builder()
            .level(Level::Debug)
            .target("uploader")
            .args(args)
            .build();

        logger.log(&record);

        assert!(matches!(
            uploader_log_rx.try_recv(),
            Err(broadcast::error::TryRecvError::Empty)
        ));
    }
}

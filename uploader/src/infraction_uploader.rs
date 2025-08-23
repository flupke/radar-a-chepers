use camino::Utf8PathBuf;
use tokio::sync::mpsc;

use crate::actor::{Actor, ActorPort};

pub(crate) struct InfractionUploader {
    port: ActorPort<InfractionUploaderCommand>,
}

impl InfractionUploader {
    fn new(infractions_dir: Utf8PathBuf) -> Self {
        Self {
            port: InfractionUploaderInner::new(infractions_dir).start(),
        }
    }
}

enum InfractionUploaderCommand {
    NotifyInfraction,
}

struct InfractionUploaderInner {
    infractions_dir: Utf8PathBuf,
}

impl InfractionUploaderInner {
    fn new(infractions_dir: Utf8PathBuf) -> Self {
        Self { infractions_dir }
    }
}

impl Actor for InfractionUploaderInner {
    type Command = InfractionUploaderCommand;

    fn event_loop(
        self,
        port: ActorPort<Self::Command>,
        _command_receiver: mpsc::UnboundedReceiver<Self::Command>,
    ) {
        while let Some(command) = _command_receiver.recv() {
            match command {
                InfractionUploaderCommand::NotifyInfraction => {
                    self.upload_infractions();
                }
            }
        }
    }
}

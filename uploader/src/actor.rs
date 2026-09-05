use std::rc::Rc;

use tokio::sync::mpsc::error::SendError;
use tokio::sync::{mpsc, watch};
use tokio::task::AbortHandle;
use tracing::Instrument;

/// A local task with a command channel. Its last port owns cancellation.
pub trait Actor: Sized + 'static {
    type Command: 'static;

    fn event_loop(
        self,
        command_receiver: mpsc::UnboundedReceiver<Self::Command>,
    ) -> impl std::future::Future<Output = ()>;

    fn start(self) -> ActorPort<Self::Command> {
        let (command_sender, command_receiver) = mpsc::unbounded_channel();
        let (finished_tx, finished_rx) = watch::channel(());
        let task = tokio::task::spawn_local(
            async move {
                self.event_loop(command_receiver).await;
                // Dropping the sender also wakes joiners on panic or cancellation.
                drop(finished_tx);
            }
            .instrument(tracing::Span::current()),
        );
        ActorPort {
            command_sender,
            task: Rc::new(ActorTask {
                abort_handle: task.abort_handle(),
                finished: finished_rx,
            }),
        }
    }
}

#[derive(Debug)]
struct ActorTask {
    abort_handle: AbortHandle,
    finished: watch::Receiver<()>,
}

impl Drop for ActorTask {
    fn drop(&mut self) {
        self.abort_handle.abort();
    }
}

#[derive(Debug)]
pub struct ActorPort<Command> {
    command_sender: mpsc::UnboundedSender<Command>,
    task: Rc<ActorTask>,
}

impl<Command> ActorPort<Command> {
    pub fn send(&self, command: Command) -> Result<(), SendError<Command>> {
        self.command_sender.send(command)
    }

    /// Wait for completion, including a task that has already stopped.
    pub async fn join(&self) {
        let _ = self.task.finished.clone().changed().await;
    }
}

impl<Command> Clone for ActorPort<Command> {
    fn clone(&self) -> Self {
        Self {
            command_sender: self.command_sender.clone(),
            task: self.task.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::oneshot;
    use tokio::task::LocalSet;
    use tokio::time::{Duration, timeout};

    enum Command {
        Reply(oneshot::Sender<()>),
        Wait(oneshot::Sender<()>),
        Stop,
        Panic,
    }

    struct Worker(oneshot::Sender<()>);

    impl Actor for Worker {
        type Command = Command;

        async fn event_loop(self, mut commands: mpsc::UnboundedReceiver<Command>) {
            let _lifetime = self.0;
            while let Some(command) = commands.recv().await {
                match command {
                    Command::Reply(reply) => {
                        let _ = reply.send(());
                    }
                    Command::Wait(started) => {
                        let _ = started.send(());
                        std::future::pending::<()>().await;
                    }
                    Command::Stop => break,
                    Command::Panic => panic!("worker failed"),
                }
            }
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn clones_keep_task_alive_until_last_port_is_dropped() {
        LocalSet::new()
            .run_until(async {
                let (lifetime_tx, mut lifetime_rx) = oneshot::channel();
                let port = Worker(lifetime_tx).start();
                let clone = port.clone();
                drop(port);
                let (reply_tx, reply_rx) = oneshot::channel();
                clone.send(Command::Reply(reply_tx)).unwrap();
                timeout(Duration::from_secs(1), reply_rx)
                    .await
                    .unwrap()
                    .unwrap();
                assert!(matches!(
                    lifetime_rx.try_recv(),
                    Err(oneshot::error::TryRecvError::Empty)
                ));
                // A task ignoring its channel must still be cancelled.
                let (started_tx, started_rx) = oneshot::channel();
                clone.send(Command::Wait(started_tx)).unwrap();
                timeout(Duration::from_secs(1), started_rx)
                    .await
                    .unwrap()
                    .unwrap();
                drop(clone);
                assert!(
                    timeout(Duration::from_secs(1), lifetime_rx)
                        .await
                        .unwrap()
                        .is_err()
                );
            })
            .await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn join_handles_normal_exit_panic_and_repeated_waiters() {
        LocalSet::new()
            .run_until(async {
                for command in [Command::Stop, Command::Panic] {
                    let (lifetime_tx, _) = oneshot::channel();
                    let port = Worker(lifetime_tx).start();
                    port.send(command).unwrap();
                    let clone = port.clone();
                    timeout(Duration::from_secs(1), async {
                        tokio::join!(port.join(), clone.join());
                        port.join().await;
                    })
                    .await
                    .unwrap();
                    assert!(port.send(Command::Stop).is_err());
                }
            })
            .await;
    }
}

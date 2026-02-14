use std::collections::HashMap;
use std::rc::Rc;
use std::sync::Mutex;
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;

use tokio::sync::mpsc;
use tokio::sync::mpsc::error::SendError;
use tokio::sync::oneshot;
use tokio::task::AbortHandle;
use tracing::Instrument;

type Monitor = Box<dyn FnOnce() + 'static>;
type MonitorSender = mpsc::UnboundedSender<MonitorCommand>;
type MonitorReceiver = mpsc::UnboundedReceiver<MonitorCommand>;
type MonitorStore = Rc<Mutex<HashMap<MonitorId, Monitor>>>;

/// An [Actor] runs in a tokio task and interacts with the outside world
/// through commands.
pub trait Actor: Sized + 'static {
    /// The type of commands this actor can receive.
    ///
    /// This associated type defines the message protocol for communicating
    /// with the actor. Commands are sent through the actor's port and
    /// processed in the event loop.
    type Command: 'static;

    /// The main event loop where the actor processes incoming commands.
    ///
    /// This method is called by [`outer_event_loop`](Self::outer_event_loop)
    /// after the monitoring infrastructure is set up. Implementers should:
    ///
    /// - Process commands from `command_receiver` until the channel closes
    /// - Use `port` to access actor capabilities like monitoring other actors
    /// - Perform any necessary cleanup before returning
    ///
    /// # Parameters
    ///
    /// * `port` - The actor's own port, useful for self-referential operations
    ///   like monitoring other actors
    /// * `command_receiver` - Channel for receiving commands sent to this actor
    ///
    /// # Example
    ///
    /// ```ignore
    /// async fn event_loop(
    ///     mut self,
    ///     port: ActorPort<Self::Command>,
    ///     mut receiver: mpsc::UnboundedReceiver<Self::Command>,
    /// ) {
    ///     while let Some(command) = receiver.recv().await {
    ///         // Process command
    ///     }
    /// }
    /// ```
    fn event_loop(
        self,
        port: ActorPort<Self::Command>,
        command_receiver: mpsc::UnboundedReceiver<Self::Command>,
    ) -> impl std::future::Future<Output = ()>;

    /// Wraps the event loop with monitoring infrastructure.
    ///
    /// This method sets up the monitoring system before calling the actor's
    /// [`event_loop`](Self::event_loop). It creates a [`MonitorGuard`] that
    /// ensures registered monitors are notified when the actor terminates.
    ///
    /// This method is called by [`start`](Self::start) and should not be
    /// overridden unless you need custom monitoring behavior.
    ///
    /// # Parameters
    ///
    /// * `command_receiver` - Channel for receiving commands
    /// * `monitor_receiver` - Channel for receiving monitor registrations
    /// * `port_receiver` - One-shot channel to receive the actor's port
    fn outer_event_loop(
        self,
        command_receiver: mpsc::UnboundedReceiver<Self::Command>,
        monitor_receiver: MonitorReceiver,
        port_receiver: oneshot::Receiver<ActorPort<Self::Command>>,
    ) -> impl std::future::Future<Output = ()> {
        async move {
            let _guard = MonitorGuard::new(monitor_receiver);
            let port = port_receiver.await.unwrap();
            self.event_loop(port, command_receiver).await;
        }
    }

    /// Starts the actor in a new tokio task and returns its port.
    ///
    /// This method:
    /// 1. Creates communication channels for commands and monitoring
    /// 2. Spawns the actor's event loop in a local tokio task
    /// 3. Returns an [`ActorPort`] for communicating with the actor
    ///
    /// The spawned task will run until:
    /// - The last [`ActorPort`] clone is dropped (automatic cancellation)
    /// - The actor's event loop returns
    /// - The task is explicitly aborted via [`ActorPort::abort`]
    ///
    /// # Panics
    ///
    /// Panics if the port cannot be sent to the actor task, which should
    /// never happen in normal operation.
    ///
    /// # Example
    ///
    /// ```ignore
    /// let actor = MyActor::new();
    /// let port = actor.start();
    ///
    /// // Send commands to the actor
    /// port.send(MyCommand::DoSomething)?;
    ///
    /// // Actor stops when port is dropped
    /// drop(port);
    /// ```
    fn start(self) -> ActorPort<Self::Command> {
        self.start_in_span(tracing::Span::current())
    }

    /// A variant of [`Actor::start`] that allows you to specify a span for the
    /// actor.
    fn start_in_span(self, span: tracing::Span) -> ActorPort<Self::Command> {
        let (command_sender, command_receiver) = mpsc::unbounded_channel();
        let (monitor_sender, monitor_receiver) = mpsc::unbounded_channel();
        let (port_sender, port_receiver) = oneshot::channel();
        let join_handle = tokio::task::spawn_local(
            self.outer_event_loop(command_receiver, monitor_receiver, port_receiver)
                .instrument(span),
        );
        let port = ActorPort {
            abort_handle: join_handle.abort_handle(),
            command_sender,
            monitor_sender,
        };
        if port_sender.send(port.clone()).is_err() {
            panic!("could not send port to self");
        }
        port
    }
}

pub enum MonitorCommand {
    Monitor {
        monitor_id: MonitorId,
        response_sender: Option<oneshot::Sender<()>>,
        monitor: Monitor,
    },
    Demonitor(MonitorId),
}

struct MonitorGuard {
    monitors: MonitorStore,
    abort_handle: AbortHandle,
}

impl MonitorGuard {
    fn new(mut receiver: MonitorReceiver) -> Self {
        let monitors = Rc::new(Mutex::new(HashMap::new()));
        let monitors_clone = monitors.clone();
        let join_handle = tokio::task::spawn_local(async move {
            while let Some(command) = receiver.recv().await {
                match command {
                    MonitorCommand::Monitor {
                        monitor_id,
                        response_sender,
                        monitor,
                    } => {
                        monitors_clone.lock().unwrap().insert(monitor_id, monitor);
                        if let Some(response_sender) = response_sender {
                            let _ = response_sender.send(());
                        }
                    }
                    MonitorCommand::Demonitor(monitor_id) => {
                        monitors_clone.lock().unwrap().remove(&monitor_id);
                    }
                }
            }
        });
        Self {
            monitors,
            abort_handle: join_handle.abort_handle(),
        }
    }
}

impl Drop for MonitorGuard {
    fn drop(&mut self) {
        let mut monitors = self.monitors.lock().unwrap();
        self.abort_handle.abort();
        for (_, monitor) in monitors.drain() {
            monitor();
        }
    }
}

static MONITOR_ID_COUNTER: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct MonitorId(u64);

impl MonitorId {
    fn new() -> Self {
        Self(MONITOR_ID_COUNTER.fetch_add(1, Ordering::SeqCst))
    }
}

/// An [ActorPort] is used to communicate with an [Actor].
///
/// The actor task is aborted when the last clone of its [ActorPort] is dropped.
#[derive(Debug)]
pub struct ActorPort<CommandKind: 'static> {
    abort_handle: AbortHandle,
    command_sender: mpsc::UnboundedSender<CommandKind>,
    monitor_sender: MonitorSender,
}

impl<CommandKind: 'static> ActorPort<CommandKind> {
    /// Send a message to the actor.
    pub fn send(&self, command: CommandKind) -> Result<(), mpsc::error::SendError<CommandKind>> {
        self.command_sender.send(command)
    }

    /// Receive `command` when the async task tied to `port` stops.
    ///
    /// If the monitored actor is already dead, `command` is sent right away.
    ///
    /// This methods blocks until the monitor has been registered.
    ///
    /// Returns a [MonitorId] that can be used to cancel the monitor. Note
    /// that the [ActorPort::demonitor] method must be called on the other
    /// port to remove the monitor.
    pub async fn monitor<OtherCommandKind: 'static>(
        &self,
        other_port: &ActorPort<OtherCommandKind>,
        command: CommandKind,
    ) -> MonitorHandle<OtherCommandKind> {
        let port_clone = self.clone();
        let monitor = Box::new(move || {
            let _ = port_clone.send(command);
        });
        let (response_sender, response_receiver) = oneshot::channel();
        let monitor_id = MonitorId::new();
        match other_port.monitor_sender.send(MonitorCommand::Monitor {
            monitor_id,
            response_sender: Some(response_sender),
            monitor,
        }) {
            Ok(_) => {
                let _ = response_receiver.await;
            }
            Err(SendError(MonitorCommand::Monitor { monitor, .. })) => {
                monitor();
            }
            Err(SendError(MonitorCommand::Demonitor(_))) => unreachable!(),
        }
        MonitorHandle {
            monitor_id,
            monitored_port: other_port.clone(),
        }
    }

    fn demonitor(&self, monitor_id: MonitorId) {
        let _ = self
            .monitor_sender
            .send(MonitorCommand::Demonitor(monitor_id));
    }

    /// Wait for the actor to terminate.
    pub async fn join(&self) {
        let (tx, rx) = oneshot::channel();
        let monitor = Box::new(move || {
            let _ = tx.send(());
        });
        if self
            .monitor_sender
            .send(MonitorCommand::Monitor {
                monitor_id: MonitorId::new(),
                response_sender: None,
                monitor,
            })
            .is_ok()
        {
            let _ = rx.await;
        }
    }

    /// Abort the actor's event loop.
    pub fn abort(&mut self) {
        self.abort_handle.abort();
    }
}

pub struct MonitorHandle<CommandKind: 'static> {
    monitor_id: MonitorId,
    monitored_port: ActorPort<CommandKind>,
}

impl<CommandKind: 'static> MonitorHandle<CommandKind> {
    pub fn cancel(self) {
        self.monitored_port.demonitor(self.monitor_id)
    }
}

impl<CommandKind: 'static> Clone for ActorPort<CommandKind> {
    fn clone(&self) -> Self {
        Self {
            abort_handle: self.abort_handle.clone(),
            command_sender: self.command_sender.clone(),
            monitor_sender: self.monitor_sender.clone(),
        }
    }
}

impl<CommandKind: 'static> Drop for ActorPort<CommandKind> {
    fn drop(&mut self) {
        let ref_count = self.command_sender.strong_count();
        // We check for ref_count == 2 (not 1) because the command_sender always has
        // two references in normal operation:
        //
        // 1. One reference in this ActorPort (the one being dropped)
        // 2. One reference held by the actor task itself (cloned in start())
        //
        // When ref_count == 2, we know this is the last external ActorPort, so we
        // should abort the actor task.
        //
        // When ref_count > 2, other external ActorPorts still exist.
        if ref_count == 2 {
            self.abort()
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tokio::sync::oneshot;
    use tokio::time::sleep;

    use super::*;

    enum Message {
        AddString(String),
        GetStrings(oneshot::Sender<Vec<String>>),
    }

    #[derive(Default)]
    struct StringsHolder {
        strings: Vec<String>,
    }

    impl Actor for StringsHolder {
        type Command = Message;

        async fn event_loop(
            mut self,
            _port: ActorPort<Message>,
            mut receiver: mpsc::UnboundedReceiver<Message>,
        ) {
            while let Some(message) = receiver.recv().await {
                match message {
                    Message::AddString(value) => {
                        self.strings.push(value);
                    }
                    Message::GetStrings(reply_sender) => {
                        reply_sender.send(self.strings.clone()).unwrap();
                    }
                }
            }
        }
    }

    #[derive(Debug)]
    enum StoppableMessage {
        Stop(oneshot::Sender<()>),
        Panic,
    }

    struct StoppableActor;

    impl Actor for StoppableActor {
        type Command = StoppableMessage;

        async fn event_loop(
            self,
            _port: ActorPort<StoppableMessage>,
            mut command_receiver: mpsc::UnboundedReceiver<StoppableMessage>,
        ) {
            match command_receiver.recv().await {
                Some(StoppableMessage::Stop(sender)) => {
                    sender.send(()).unwrap();
                }
                Some(StoppableMessage::Panic) => panic!("panic"),
                None => {}
            }
        }
    }

    async fn get_strings(port: &ActorPort<Message>) -> Vec<String> {
        let (sender, receiver) = oneshot::channel();
        let message = Message::GetStrings(sender);
        port.send(message).unwrap();
        receiver.await.unwrap()
    }

    #[tokio::test(flavor = "current_thread")]
    async fn test_notify() {
        let local = tokio::task::LocalSet::new();
        local
            .run_until(async {
                let port = StringsHolder::default().start();
                let _ = port.send(Message::AddString("hello".to_string()));
                let _ = port.send(Message::AddString("world".to_string()));
                let strings = get_strings(&port).await;
                assert_eq!(strings, vec!["hello".to_string(), "world".to_string()]);
            })
            .await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn test_monitoring_with_clean_stop() {
        let local = tokio::task::LocalSet::new();
        local
            .run_until(async {
                let strings = StringsHolder::default().start();
                let stoppable = StoppableActor.start();
                strings
                    .monitor(&stoppable, Message::AddString("it stopped".to_string()))
                    .await;

                let (sender, receiver) = oneshot::channel();
                stoppable.send(StoppableMessage::Stop(sender)).unwrap();
                receiver.await.ok();

                assert_eq!(get_strings(&strings).await, vec!["it stopped".to_string()]);
            })
            .await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn test_demonitoring() {
        let local = tokio::task::LocalSet::new();
        local
            .run_until(async {
                let strings = StringsHolder::default().start();
                let stoppable = StoppableActor.start();
                let monitor = strings
                    .monitor(&stoppable, Message::AddString("it stopped".to_string()))
                    .await;
                monitor.cancel();

                let (sender, receiver) = oneshot::channel();
                stoppable.send(StoppableMessage::Stop(sender)).unwrap();
                receiver.await.ok();

                assert_eq!(get_strings(&strings).await, Vec::<String>::new());
            })
            .await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn test_monitoring_with_manual_abort() {
        let local = tokio::task::LocalSet::new();
        local
            .run_until(async {
                let strings = StringsHolder::default().start();
                let mut stoppable = StoppableActor.start();
                strings
                    .monitor(&stoppable, Message::AddString("it stopped".to_string()))
                    .await;

                stoppable.abort();
                sleep(Duration::from_millis(0)).await;

                assert_eq!(get_strings(&strings).await, vec!["it stopped".to_string()]);
            })
            .await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn test_monitoring_with_drop() {
        let local = tokio::task::LocalSet::new();
        local
            .run_until(async {
                let strings = StringsHolder::default().start();
                let stoppable = StoppableActor.start();
                strings
                    .monitor(&stoppable, Message::AddString("it stopped".to_string()))
                    .await;

                drop(stoppable);
                sleep(Duration::from_millis(0)).await;

                assert_eq!(get_strings(&strings).await, vec!["it stopped".to_string()]);
            })
            .await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn test_monitoring_with_panic() {
        let local = tokio::task::LocalSet::new();
        local
            .run_until(async {
                let strings = StringsHolder::default().start();
                let stoppable = StoppableActor.start();
                strings
                    .monitor(&stoppable, Message::AddString("it stopped".to_string()))
                    .await;

                stoppable.send(StoppableMessage::Panic).unwrap();
                sleep(Duration::from_millis(0)).await;

                assert_eq!(get_strings(&strings).await, vec!["it stopped".to_string()]);
            })
            .await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn test_join() {
        let local = tokio::task::LocalSet::new();
        local
            .run_until(async {
                let port = StoppableActor.start();

                // Send stop command
                let (sender, receiver) = oneshot::channel();
                port.send(StoppableMessage::Stop(sender)).unwrap();

                // Join should complete after the actor stops
                port.join().await;

                // Verify the actor processed the stop command
                receiver.await.unwrap();
            })
            .await;
    }
}

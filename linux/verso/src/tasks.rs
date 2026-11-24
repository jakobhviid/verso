//! Network and disk work runs on a tokio runtime; GTK owns the main thread and awaits the results on its loop.

use std::future::Future;
use std::sync::OnceLock;

use gtk::glib;

pub fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| tokio::runtime::Builder::new_multi_thread().worker_threads(4).enable_all().build().expect("the async runtime starts"))
}

/// Run `work` on the runtime, then `then` with its result on the main loop.
pub fn run<Output, Work>(work: Work, then: impl FnOnce(Output) + 'static)
where
    Work: Future<Output = Output> + Send + 'static,
    Output: Send + 'static,
{
    let handle = runtime().spawn(work);
    glib::spawn_future_local(async move {
        if let Ok(output) = handle.await {
            then(output);
        }
    });
}

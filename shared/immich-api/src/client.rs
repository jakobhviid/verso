//! The HTTP client: the server URL, the credential, and the request plumbing every endpoint module uses.
//!
//! Adapted from immich-rs (`client.rs`, `core/execute.rs`), without its Tower stack: one `reqwest::Client`
//! (rustls with the system's verification, and the certificate trusted for the server where the system does not
//! trust it, `crate::certificate`; one shared connection pool), a credential header, and a retry loop
//! ([`crate::retry`]). Cloning a [`Client`] is cheap and shares the pool.
//!
//! Rules every call follows:
//! - the credential goes in a header, never in the URL (`?apiKey=` also authenticates, but leaks into logs)
//! - path segments are percent-encoded one by one, and the generic calls refuse an empty, `.` or `..` segment, so an
//!   id can never change which endpoint is called
//! - a call is resent after a lost answer only when that is harmless ([`crate::retry`])
//! - ordinary calls have a 60 s request timeout; uploads and the sync stream have none, and their callers bound
//!   them (ARCHITECTURE.md, "Never hang")

use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use reqwest::header::{HeaderName, HeaderValue, AUTHORIZATION, CONTENT_RANGE, CONTENT_TYPE, ETAG, IF_NONE_MATCH};
use reqwest::{Method, Request, RequestBuilder, Response, StatusCode};
use serde::de::DeserializeOwned;
use serde::Serialize;
use url::Url;

use crate::certificate::CertificatePin;
use crate::error::{classify, from_transport, ApiError, ErrorResponse, RequestShape};
use crate::retry::{parse_retry_after, Resend, RetryPolicy};

/// How long an ordinary call may take, end to end.
pub(crate) const REQUEST_TIMEOUT: Duration = Duration::from_secs(60);

/// How long establishing a connection may take.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// How often a connection with requests waiting is asked whether it still answers (an HTTP/2 ping), and how long
/// it may take to: a connection the network dropped without a word fails its requests in seconds, not at their
/// timeout.
const KEEP_ALIVE: Duration = Duration::from_secs(10);

/// How long an idle connection is kept for the next request: less than the 5 s Immich's server (Node) keeps one, so a
/// request is not sent on a connection the server is closing ("connection closed before message completed"). Behind
/// a proxy that keeps them longer, a request after a pause opens a new one.
const POOL_IDLE: Duration = Duration::from_secs(4);

/// What a request says that was not sent, or gave up waiting, because the server is taken as unreachable.
const NOT_REACHABLE: &str = "the server is not reachable now";

/// What the client authenticates with.
#[derive(Clone, PartialEq, Eq)]
pub enum Credential {
    /// An API key, sent as the `x-api-key` header.
    ApiKey(String),
    /// A session token from password or browser sign-in, sent as `Authorization: Bearer <token>`.
    Session(String),
}

impl std::fmt::Debug for Credential {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Credential::ApiKey(_) => formatter.write_str("ApiKey(<redacted>)"),
            Credential::Session(_) => formatter.write_str("Session(<redacted>)"),
        }
    }
}

impl Credential {
    fn header(&self) -> Result<(HeaderName, HeaderValue), ApiError> {
        let (name, secret, value) = match self {
            Credential::ApiKey(key) => (HeaderName::from_static("x-api-key"), key, key.trim().to_owned()),
            Credential::Session(token) => (AUTHORIZATION, token, format!("Bearer {}", token.trim())),
        };
        if secret.trim().is_empty() {
            return Err(ApiError::Protocol("the credential is empty".to_owned()));
        }
        let mut value = HeaderValue::from_str(&value).map_err(|_| {
            ApiError::Protocol("the credential contains characters that cannot be sent in an HTTP header".to_owned())
        })?;
        value.set_sensitive(true);
        Ok((name, value))
    }
}

/// The answer to a conditional GET (`If-None-Match`).
#[derive(Debug, Clone, PartialEq)]
pub enum Fetched<T> {
    /// 304: nothing changed since the ETag that was sent.
    NotModified,
    /// The current value, and its ETag for the next poll.
    Changed { value: T, etag: Option<String> },
}

/// A file the server made (a face crop, a profile picture), with its content type.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Media {
    pub bytes: Bytes,
    /// As the server sent it (`image/jpeg`); `application/octet-stream` when it sent none.
    pub content_type: String,
}

/// An async client for one Immich server and one credential.
#[derive(Clone)]
pub struct Client {
    inner: Arc<Inner>,
}

struct Inner {
    http: reqwest::Client,
    api_url: Url,
    credential: Option<Credential>,
    auth_header: Option<(HeaderName, HeaderValue)>,
    /// The certificate trusted for the server besides the system's (`crate::certificate`).
    trusted: Option<CertificatePin>,
    retry: RetryPolicy,
    reach: Arc<Reach>,
}

/// The TLS configuration a client is built over; nothing without TLS.
#[cfg(feature = "tls")]
pub(crate) type TlsConfig = rustls::ClientConfig;
#[cfg(not(feature = "tls"))]
pub(crate) type TlsConfig = ();

/// Whether the server can be reached, as the app watching it last found ([`Client::set_reachable`]), and the
/// requests waiting for an answer. Shared by every client made from one, as their connection pool is.
#[derive(Debug)]
struct Reach {
    /// `false` while the server cannot be reached: requests fail at once, and those waiting give up.
    reachable: tokio::sync::watch::Sender<bool>,
    /// When each request waiting for its answer was sent, by a number of its own.
    waiting: std::sync::Mutex<std::collections::HashMap<u64, std::time::Instant>>,
    next: std::sync::atomic::AtomicU64,
}

impl Reach {
    fn new() -> Reach {
        Reach { reachable: tokio::sync::watch::Sender::new(true), waiting: Default::default(), next: Default::default() }
    }

    /// Note a request as waiting, until the returned guard is dropped.
    fn wait(&self) -> Waiting<'_> {
        let id = self.next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        self.waiting.lock().expect("waiting lock").insert(id, std::time::Instant::now());
        Waiting { reach: self, id }
    }
}

/// A request waiting for its answer ([`Reach::wait`]).
struct Waiting<'a> {
    reach: &'a Reach,
    id: u64,
}

impl Drop for Waiting<'_> {
    fn drop(&mut self) {
        self.reach.waiting.lock().expect("waiting lock").remove(&self.id);
    }
}

/// Wait until the server is taken as unreachable; never, while it is not.
async fn until_unreachable(mut reachable: tokio::sync::watch::Receiver<bool>) {
    if reachable.wait_for(|reachable| !*reachable).await.is_err() {
        std::future::pending::<()>().await;
    }
}

impl std::fmt::Debug for Client {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Client")
            .field("api_url", &self.inner.api_url.as_str())
            .field("credential", &self.inner.credential)
            .field("retry", &self.inner.retry)
            .finish()
    }
}

/// Redirects are followed only within the server's own origin (scheme, host and port). reqwest strips
/// `Authorization` on a redirect to another host, but not our `x-api-key`, so a proxy or a moved domain answering
/// with a redirect elsewhere would otherwise receive the key. A redirect elsewhere comes back as its 3xx answer.
fn same_origin_only(attempt: reqwest::redirect::Attempt<'_>) -> reqwest::redirect::Action {
    let leaves_origin = attempt.previous().first().is_some_and(|first| first.origin() != attempt.url().origin());
    if leaves_origin || attempt.previous().len() >= 10 {
        attempt.stop()
    } else {
        attempt.follow()
    }
}

impl Client {
    /// A client for the server at `server_url`, which may or may not end in `/api`, trusting the certificates the
    /// system trusts.
    ///
    /// The URL is normalised: whitespace and trailing slashes are trimmed, and `/api` is added once. No request is
    /// made. `user_agent` is sent with every request (`verso-service/<version>`).
    pub fn new(server_url: &str, credential: Option<Credential>, user_agent: &str) -> Result<Client, ApiError> {
        Client::trusting(server_url, credential, user_agent, None)
    }

    /// [`Client::new`], also trusting the certificate `trusted` names for this server when the system does not trust
    /// it (`crate::certificate`): the one a person chose to trust, kept with the server's address.
    pub fn trusting(server_url: &str, credential: Option<Credential>, user_agent: &str, trusted: Option<CertificatePin>) -> Result<Client, ApiError> {
        #[cfg(feature = "tls")]
        let tls = Some(crate::certificate::tls_config(trusted)?);
        #[cfg(not(feature = "tls"))]
        let tls = None;
        Client::with_tls(server_url, credential, user_agent, trusted, tls)
    }

    /// A client over a TLS configuration of its own, `None` without TLS.
    pub(crate) fn with_tls(
        server_url: &str,
        credential: Option<Credential>,
        user_agent: &str,
        trusted: Option<CertificatePin>,
        #[cfg_attr(not(feature = "tls"), allow(unused_variables))] tls: Option<TlsConfig>,
    ) -> Result<Client, ApiError> {
        let api_url = normalise_server_url(server_url)?;
        let builder = reqwest::Client::builder()
            .user_agent(user_agent)
            .connect_timeout(CONNECT_TIMEOUT)
            .pool_idle_timeout(POOL_IDLE)
            .http2_keep_alive_interval(KEEP_ALIVE)
            .http2_keep_alive_timeout(KEEP_ALIVE)
            .redirect(reqwest::redirect::Policy::custom(same_origin_only));
        #[cfg(feature = "tls")]
        let builder = match tls {
            Some(config) => builder.use_preconfigured_tls(config),
            None => builder,
        };
        let http = builder
            .build()
            .map_err(|error| ApiError::Protocol(format!("cannot set up the HTTP client: {}", crate::error::describe(&error))))?;
        let auth_header = credential.as_ref().map(Credential::header).transpose()?;
        Ok(Client {
            inner: Arc::new(Inner {
                http,
                api_url,
                credential,
                auth_header,
                trusted,
                retry: RetryPolicy::default(),
                reach: Arc::new(Reach::new()),
            }),
        })
    }

    /// The certificate trusted for this server besides those the system trusts ([`Client::trusting`]).
    pub fn trusted_certificate(&self) -> Option<CertificatePin> {
        self.inner.trusted
    }

    /// The same server and connection pool with another credential, for example the session a sign-in returned.
    pub fn with_credential(&self, credential: Option<Credential>) -> Result<Client, ApiError> {
        let auth_header = credential.as_ref().map(Credential::header).transpose()?;
        Ok(Client {
            inner: Arc::new(Inner {
                http: self.inner.http.clone(),
                api_url: self.inner.api_url.clone(),
                credential,
                auth_header,
                trusted: self.inner.trusted,
                retry: self.inner.retry,
                reach: self.inner.reach.clone(),
            }),
        })
    }

    /// The same client with another retry policy.
    pub fn with_retry_policy(&self, retry: RetryPolicy) -> Client {
        Client {
            inner: Arc::new(Inner {
                http: self.inner.http.clone(),
                api_url: self.inner.api_url.clone(),
                credential: self.inner.credential.clone(),
                auth_header: self.inner.auth_header.clone(),
                trusted: self.inner.trusted,
                retry,
                reach: self.inner.reach.clone(),
            }),
        }
    }

    /// Tell the client whether the server can be reached. While it cannot, every request fails at once with
    /// [`ApiError::Offline`] and those waiting for an answer give up, so none waits out its timeout; [`Client::ping`]
    /// still asks, to find out when it can be reached again. Every client made from this one shares it.
    pub fn set_reachable(&self, reachable: bool) {
        self.inner.reach.reachable.send_replace(reachable);
    }

    /// Whether the server is taken as reachable ([`Client::set_reachable`]); it is until said otherwise.
    pub fn is_reachable(&self) -> bool {
        *self.inner.reach.reachable.borrow()
    }

    /// How long the longest-waiting request has waited for its answer; `None` while none waits. A connection the
    /// network dropped without a word makes requests wait out their timeout, so an app asks the server (with
    /// [`Client::ping`]) once this grows long.
    pub fn longest_wait(&self) -> Option<Duration> {
        self.inner.reach.waiting.lock().expect("waiting lock").values().map(|sent| sent.elapsed()).max()
    }

    /// Send a request once: no retries, and sent even while the server is taken as unreachable ([`Client::ping`]).
    pub(crate) async fn execute_once(&self, builder: RequestBuilder) -> Result<Response, ApiError> {
        let request = builder.build().map_err(|error| from_transport(&error))?;
        let _waiting = self.inner.reach.wait();
        self.inner.http.execute(request).await.map_err(|error| from_transport(&error))
    }

    /// The normalised API base URL, ending in `/api`.
    pub fn api_url(&self) -> &Url {
        &self.inner.api_url
    }

    /// The credential this client sends, if any.
    pub fn credential(&self) -> Option<&Credential> {
        self.inner.credential.as_ref()
    }

    /// The URL of an endpoint below `/api`, one percent-encoded segment per element.
    pub(crate) fn endpoint(&self, segments: &[&str]) -> Url {
        let mut url = self.inner.api_url.clone();
        // `normalise_server_url` only accepts http(s) URLs, which always have path segments.
        if let Ok(mut path) = url.path_segments_mut() {
            path.pop_if_empty().extend(segments);
        }
        url
    }

    /// A request to an endpoint, with the credential attached.
    pub(crate) fn request(&self, method: Method, segments: &[&str]) -> RequestBuilder {
        let builder = self.inner.http.request(method, self.endpoint(segments));
        self.authenticate(builder)
    }

    /// Attach the credential header, if there is one.
    pub(crate) fn authenticate(&self, builder: RequestBuilder) -> RequestBuilder {
        match &self.inner.auth_header {
            Some((name, value)) => builder.header(name.clone(), value.clone()),
            None => builder,
        }
    }

    /// Send a request with retries. Returns the final response whatever its status; see [`check`].
    pub(crate) async fn execute(&self, builder: RequestBuilder) -> Result<Response, ApiError> {
        self.execute_resending(builder, Resend::Freely).await
    }

    /// [`Client::execute`], resending only as `resend` allows.
    pub(crate) async fn execute_resending(&self, builder: RequestBuilder, resend: Resend) -> Result<Response, ApiError> {
        let request = builder.build().map_err(|error| from_transport(&error))?;
        self.execute_with_resending(resend, || {
            let attempt = request.try_clone();
            async move {
                attempt.ok_or_else(|| ApiError::Protocol("internal: a request body could not be replayed".to_owned()))
            }
        })
        .await
    }

    /// Send a request built afresh for every attempt, with the retry policy.
    ///
    /// Retryable statuses are retried while attempts remain and the wait fits in [`RetryPolicy::max_wait`]; the
    /// last response is returned as is, so the caller maps it (to `Transient`, usually) with [`check`].
    pub(crate) async fn execute_with<MakeRequest, Pending>(&self, make_request: MakeRequest) -> Result<Response, ApiError>
    where
        MakeRequest: FnMut() -> Pending,
        Pending: Future<Output = Result<Request, ApiError>>,
    {
        self.execute_with_resending(Resend::Freely, make_request).await
    }

    /// [`Client::execute_with`], resending only as `resend` allows.
    pub(crate) async fn execute_with_resending<MakeRequest, Pending>(
        &self,
        resend: Resend,
        mut make_request: MakeRequest,
    ) -> Result<Response, ApiError>
    where
        MakeRequest: FnMut() -> Pending,
        Pending: Future<Output = Result<Request, ApiError>>,
    {
        let policy = self.inner.retry;
        let mut retries_done = 0;
        let reachable = self.inner.reach.reachable.subscribe();
        loop {
            // Neither sent nor sent again while the server is taken as unreachable.
            if !*reachable.borrow() {
                return Err(ApiError::Offline(NOT_REACHABLE.to_owned()));
            }
            let request = make_request().await?;
            let method = request.method().clone();
            let may_retry = retries_done < policy.max_retries;
            let sent = {
                let _waiting = self.inner.reach.wait();
                tokio::select! {
                    sent = self.inner.http.execute(request) => sent,
                    () = until_unreachable(reachable.clone()) => return Err(ApiError::Offline(NOT_REACHABLE.to_owned())),
                }
            };
            match sent {
                Ok(response) => {
                    if may_retry && resend.retries_status(response.status(), &method) {
                        let wait = parse_retry_after(response.headers())
                            .unwrap_or_else(|| policy.backoff(retries_done + 1));
                        if wait <= policy.max_wait {
                            retries_done += 1;
                            tokio::time::sleep(wait).await;
                            continue;
                        }
                    }
                    return Ok(response);
                }
                Err(error) => {
                    if may_retry && resend.retries_transport(&error) {
                        retries_done += 1;
                        tokio::time::sleep(policy.backoff(retries_done)).await;
                        continue;
                    }
                    return Err(from_transport(&error));
                }
            }
        }
    }

    /// GET an endpoint and decode its JSON answer.
    pub(crate) async fn get_json<T: DeserializeOwned>(
        &self,
        segments: &[&str],
        query: &[(&str, &str)],
    ) -> Result<T, ApiError> {
        let builder = self
            .request(Method::GET, segments)
            .query(query)
            .timeout(REQUEST_TIMEOUT);
        let response = check(self.execute(builder).await?, RequestShape::Plain).await?;
        read_json(response, &segments.join("/")).await
    }

    /// GET an endpoint unless its ETag still matches.
    pub(crate) async fn get_json_if_changed<T: DeserializeOwned>(
        &self,
        segments: &[&str],
        query: &[(&str, &str)],
        etag: Option<&str>,
    ) -> Result<Fetched<T>, ApiError> {
        let mut builder = self
            .request(Method::GET, segments)
            .query(query)
            .timeout(REQUEST_TIMEOUT);
        if let Some(etag) = etag {
            builder = builder.header(IF_NONE_MATCH, etag);
        }
        let response = self.execute(builder).await?;
        if response.status() == StatusCode::NOT_MODIFIED {
            return Ok(Fetched::NotModified);
        }
        let response = check(response, RequestShape::Plain).await?;
        let etag = header_text(&response, ETAG);
        let value = read_json(response, &segments.join("/")).await?;
        Ok(Fetched::Changed { value, etag })
    }

    /// POST a JSON body and decode the JSON answer.
    pub(crate) async fn post_json<Body: Serialize + ?Sized, T: DeserializeOwned>(
        &self,
        segments: &[&str],
        body: &Body,
    ) -> Result<T, ApiError> {
        let builder = self
            .request(Method::POST, segments)
            .json(body)
            .timeout(REQUEST_TIMEOUT);
        let response = check(self.execute(builder).await?, RequestShape::Plain).await?;
        read_json(response, &segments.join("/")).await
    }

    /// POST a JSON body (or none) and ignore the answer's body.
    pub(crate) async fn post_without_answer<Body: Serialize + ?Sized>(
        &self,
        segments: &[&str],
        body: Option<&Body>,
    ) -> Result<(), ApiError> {
        let mut builder = self.request(Method::POST, segments).timeout(REQUEST_TIMEOUT);
        if let Some(body) = body {
            builder = builder.json(body);
        }
        check(self.execute(builder).await?, RequestShape::Plain).await?;
        Ok(())
    }
}

impl Client {
    /// A request to an endpoint, refusing an empty, `.` or `..` path segment: an id that decoded empty (or a caller's
    /// `..`) must never turn `/sessions/{id}` into `/sessions`, which is another endpoint. No timeout is set; the
    /// caller sets one.
    pub(crate) fn checked_request(&self, method: Method, segments: &[&str]) -> Result<RequestBuilder, ApiError> {
        // `url` drops `.` and `..` segments, so they would change the endpoint just as an empty one does.
        let unusable = |segment: &&str| segment.trim().is_empty() || matches!(*segment, "." | "..");
        if let Some(position) = segments.iter().position(unusable) {
            return Err(ApiError::Protocol(format!(
                "internal: an unusable path segment {position} for {}",
                segments.join("/")
            )));
        }
        Ok(self.request(method, segments))
    }

    /// Call an endpoint without a body and decode its JSON answer.
    pub(crate) async fn call<T: DeserializeOwned>(
        &self,
        method: Method,
        segments: &[&str],
        query: &[(&str, &str)],
    ) -> Result<T, ApiError> {
        let resend = Resend::by_method(&method);
        let builder = self.checked_request(method, segments)?.timeout(REQUEST_TIMEOUT).query(query);
        let response = check(self.execute_resending(builder, resend).await?, RequestShape::Plain).await?;
        read_json(response, &segments.join("/")).await
    }

    /// Call an endpoint with a JSON body and decode its JSON answer.
    pub(crate) async fn call_with<Body: Serialize + ?Sized, T: DeserializeOwned>(
        &self,
        method: Method,
        segments: &[&str],
        query: &[(&str, &str)],
        body: &Body,
    ) -> Result<T, ApiError> {
        let resend = Resend::by_method(&method);
        let builder = self.checked_request(method, segments)?.timeout(REQUEST_TIMEOUT).query(query).json(body);
        let response = check(self.execute_resending(builder, resend).await?, RequestShape::Plain).await?;
        read_json(response, &segments.join("/")).await
    }

    /// Call an endpoint without a body and ignore the answer's body.
    pub(crate) async fn call_unit(&self, method: Method, segments: &[&str], query: &[(&str, &str)]) -> Result<(), ApiError> {
        let resend = Resend::by_method(&method);
        let builder = self.checked_request(method, segments)?.timeout(REQUEST_TIMEOUT).query(query);
        check(self.execute_resending(builder, resend).await?, RequestShape::Plain).await?;
        Ok(())
    }

    /// GET an endpoint whose answer is a file, and read it whole with its content type.
    pub(crate) async fn get_media(&self, segments: &[&str], query: &[(&str, &str)]) -> Result<Media, ApiError> {
        let builder = self.checked_request(Method::GET, segments)?.timeout(REQUEST_TIMEOUT).query(query);
        let response = check(self.execute(builder).await?, RequestShape::Plain).await?;
        let content_type = header_text(&response, CONTENT_TYPE).unwrap_or_else(|| "application/octet-stream".to_owned());
        let bytes = response.bytes().await.map_err(|error| from_transport(&error))?;
        Ok(Media { bytes, content_type })
    }

    /// Call an endpoint with a JSON body and ignore the answer's body.
    pub(crate) async fn call_unit_with<Body: Serialize + ?Sized>(
        &self,
        method: Method,
        segments: &[&str],
        query: &[(&str, &str)],
        body: &Body,
    ) -> Result<(), ApiError> {
        let resend = Resend::by_method(&method);
        self.call_unit_with_resending(method, segments, query, body, resend).await
    }

    /// [`Client::call_unit_with`] for a PUT or DELETE that must not be sent twice (a PIN code change, a relative
    /// date shift): resent only when the first attempt cannot have taken effect.
    pub(crate) async fn call_unit_with_once<Body: Serialize + ?Sized>(
        &self,
        method: Method,
        segments: &[&str],
        query: &[(&str, &str)],
        body: &Body,
    ) -> Result<(), ApiError> {
        self.call_unit_with_resending(method, segments, query, body, Resend::OnlyUnsent).await
    }

    /// [`Client::call_with`] for a PUT that must not be sent twice: resent only when the first attempt cannot have
    /// taken effect.
    pub(crate) async fn call_with_once<Body: Serialize + ?Sized, T: DeserializeOwned>(
        &self,
        method: Method,
        segments: &[&str],
        query: &[(&str, &str)],
        body: &Body,
    ) -> Result<T, ApiError> {
        let builder = self.checked_request(method, segments)?.timeout(REQUEST_TIMEOUT).query(query).json(body);
        let response = check(self.execute_resending(builder, Resend::OnlyUnsent).await?, RequestShape::Plain).await?;
        read_json(response, &segments.join("/")).await
    }

    async fn call_unit_with_resending<Body: Serialize + ?Sized>(
        &self,
        method: Method,
        segments: &[&str],
        query: &[(&str, &str)],
        body: &Body,
        resend: Resend,
    ) -> Result<(), ApiError> {
        let builder = self.checked_request(method, segments)?.timeout(REQUEST_TIMEOUT).query(query).json(body);
        check(self.execute_resending(builder, resend).await?, RequestShape::Plain).await?;
        Ok(())
    }
}

/// Turn a non-success response into its [`ApiError`]; pass a success through.
pub(crate) async fn check(response: Response, shape: RequestShape) -> Result<Response, ApiError> {
    let status = response.status();
    if status.is_success() {
        return Ok(response);
    }
    let retry_after = parse_retry_after(response.headers());
    let has_content_range = response.headers().contains_key(CONTENT_RANGE);
    let body = response.text().await.unwrap_or_default();
    Err(classify(
        &ErrorResponse {
            status,
            retry_after,
            has_content_range,
            body: &body,
        },
        shape,
    ))
}

/// Read and decode a JSON body, naming the endpoint in the error.
pub(crate) async fn read_json<T: DeserializeOwned>(response: Response, endpoint: &str) -> Result<T, ApiError> {
    let body = response.bytes().await.map_err(|error| from_transport(&error))?;
    decode_json(&body, endpoint)
}

/// Decode a JSON answer leniently: `null` members count as missing ([`crate::wire::strip_nulls`]).
pub(crate) fn decode_json<T: DeserializeOwned>(body: &[u8], endpoint: &str) -> Result<T, ApiError> {
    let protocol = |error: serde_json::Error| ApiError::Protocol(format!("decoding the answer of {endpoint}: {error}"));
    let mut value: serde_json::Value = serde_json::from_slice(body).map_err(protocol)?;
    crate::wire::strip_nulls(&mut value);
    serde_json::from_value(value).map_err(protocol)
}

/// A response header as text, if present and readable.
pub(crate) fn header_text(response: &Response, name: HeaderName) -> Option<String> {
    response
        .headers()
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned)
}

/// Normalise what a user typed into the API base URL: trim, drop trailing slashes, add `/api` once.
pub(crate) fn normalise_server_url(server_url: &str) -> Result<Url, ApiError> {
    let trimmed = server_url.trim();
    let mut url = Url::parse(trimmed)
        .map_err(|error| ApiError::Protocol(format!("invalid server URL `{trimmed}`: {error}")))?;
    if url.scheme() != "http" && url.scheme() != "https" {
        return Err(ApiError::Protocol(format!(
            "invalid server URL `{trimmed}`: it must start with http:// or https://"
        )));
    }
    if url.query().is_some() || url.fragment().is_some() {
        return Err(ApiError::Protocol(format!(
            "invalid server URL `{trimmed}`: it must not have a query or fragment"
        )));
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err(ApiError::Protocol(format!(
            "invalid server URL `{trimmed}`: it must not contain a user name or password"
        )));
    }
    let path = url.path().trim_end_matches('/');
    let api_path = if path.ends_with("/api") {
        path.to_owned()
    } else {
        format!("{path}/api")
    };
    url.set_path(&api_path);
    Ok(url)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_server::{CannedResponse, FakeServer};

    #[test]
    fn server_url_gets_api_once() {
        let cases = [
            ("https://photos.example.com", "https://photos.example.com/api"),
            ("https://photos.example.com/", "https://photos.example.com/api"),
            ("https://photos.example.com///", "https://photos.example.com/api"),
            ("https://photos.example.com/api", "https://photos.example.com/api"),
            ("https://photos.example.com/api/", "https://photos.example.com/api"),
            ("  http://192.168.1.5:2283  ", "http://192.168.1.5:2283/api"),
            ("https://example.com/immich/", "https://example.com/immich/api"),
        ];
        for (typed, expected) in cases {
            assert_eq!(normalise_server_url(typed).unwrap().as_str(), expected, "for {typed}");
        }
    }

    #[test]
    fn server_url_must_be_http() {
        for typed in ["photos.example.com", "ftp://example.com", "", "https://user:secret@example.com", "https://example.com/?x=1"] {
            assert!(
                matches!(normalise_server_url(typed), Err(ApiError::Protocol(_))),
                "accepted {typed}"
            );
        }
    }

    #[test]
    fn endpoint_segments_are_encoded() {
        let client = Client::new("https://example.com", None, "test").unwrap();
        assert_eq!(
            client.endpoint(&["assets", "../albums", "original"]).as_str(),
            "https://example.com/api/assets/..%2Falbums/original"
        );
    }

    #[test]
    fn credentials_are_redacted_in_debug_output() {
        let client = Client::new("https://example.com", Some(Credential::ApiKey("secret-key".into())), "test").unwrap();
        let printed = format!("{client:?}");
        assert!(!printed.contains("secret-key"), "{printed}");
        assert!(printed.contains("ApiKey(<redacted>)"));
    }

    #[test]
    fn empty_credentials_are_refused() {
        let refused = Client::new("https://example.com", Some(Credential::Session("  ".into())), "test");
        assert!(matches!(refused, Err(ApiError::Protocol(_))));
    }

    #[test]
    fn client_and_its_futures_are_send() {
        fn assert_send_sync<T: Send + Sync>() {}
        fn assert_send<T: Send>(_: &T) {}
        assert_send_sync::<Client>();
        let client = Client::new("https://example.com", None, "test").unwrap();
        assert_send(&client.server_version());
        assert_send(&client.original_range("id", 0, 1));
    }

    #[tokio::test]
    async fn api_key_goes_in_the_x_api_key_header() {
        let server = FakeServer::start(vec![CannedResponse::json(200, r#"{"permissions":["all"]}"#)]).await;
        let client = Client::new(&server.url, Some(Credential::ApiKey("key-1".into())), "Verso/test").unwrap();
        client.api_key_permissions().await.unwrap();
        let request = &server.requests()[0];
        assert_eq!(request.target, "/api/api-keys/me");
        assert_eq!(request.header("x-api-key").as_deref(), Some("key-1"));
        assert_eq!(request.header("authorization"), None);
        assert_eq!(request.header("user-agent").as_deref(), Some("Verso/test"));
    }

    #[tokio::test]
    async fn session_goes_in_a_bearer_header() {
        let server = FakeServer::start(vec![CannedResponse::json(200, r#"{"permissions":[]}"#)]).await;
        let client = Client::new(&server.url, Some(Credential::Session("token-1".into())), "test").unwrap();
        client.api_key_permissions().await.unwrap();
        assert_eq!(server.requests()[0].header("authorization").as_deref(), Some("Bearer token-1"));
    }

    #[tokio::test]
    async fn busy_server_is_retried_then_succeeds() {
        let server = FakeServer::start(vec![
            CannedResponse::json(503, r#"{"message":"busy"}"#),
            CannedResponse::json(502, "").with_header("retry-after", "0"),
            CannedResponse::json(200, r#"{"major":3,"minor":3,"patch":5}"#),
        ])
        .await;
        let client = Client::new(&server.url, None, "test").unwrap();
        let version = client.server_version().await.unwrap();
        assert_eq!(version.to_string(), "v3.3.5");
        assert_eq!(server.requests().len(), 3);
    }

    #[tokio::test]
    async fn long_retry_after_is_returned_not_slept_on() {
        let server = FakeServer::start(vec![CannedResponse::json(429, "").with_header("retry-after", "600")]).await;
        let client = Client::new(&server.url, None, "test").unwrap();
        let error = client.server_version().await.unwrap_err();
        assert_eq!(
            error,
            ApiError::Transient {
                retry_after: Some(Duration::from_secs(600))
            }
        );
        assert_eq!(server.requests().len(), 1);
    }

    #[tokio::test]
    async fn retries_are_bounded() {
        let busy = || CannedResponse::json(503, "").with_header("retry-after", "0");
        let server = FakeServer::start(vec![busy(), busy(), busy(), busy(), busy()]).await;
        let client = Client::new(&server.url, None, "test").unwrap();
        let error = client.server_version().await.unwrap_err();
        assert_eq!(error, ApiError::Transient { retry_after: Some(Duration::ZERO) });
        assert_eq!(server.requests().len(), 4, "one attempt and three retries");
    }

    #[tokio::test]
    async fn a_500_on_post_is_not_retried() {
        let server = FakeServer::start(vec![CannedResponse::json(500, r#"{"message":"boom"}"#)]).await;
        let client = Client::new(&server.url, None, "test").unwrap();
        let error = client.sync_ack(&["ack".to_owned()]).await.unwrap_err();
        assert_eq!(error, ApiError::Transient { retry_after: None });
        assert_eq!(server.requests().len(), 1);
    }

    #[tokio::test]
    async fn an_unreachable_server_is_not_asked_until_it_is_reachable_again() {
        let server = FakeServer::start(vec![CannedResponse::json(200, r#"{"res":"pong"}"#), CannedResponse::json(200, r#"{"res":"pong"}"#)]).await;
        let client = Client::new(&server.url, None, "test").unwrap();
        let shared = client.with_retry_policy(RetryPolicy::default());
        client.set_reachable(false);
        assert!(!shared.is_reachable(), "every client made from one shares it");
        let error = shared.server_version().await.unwrap_err();
        assert!(matches!(error, ApiError::Offline(_)), "{error:?}");
        assert!(server.requests().is_empty(), "not sent");
        client.ping().await.unwrap();
        assert_eq!(server.requests().len(), 1, "the ping is how it is found again");
        client.set_reachable(true);
        client.ping().await.unwrap();
        assert_eq!(server.requests().len(), 2);
    }

    #[tokio::test]
    async fn a_request_waiting_gives_up_when_the_server_is_taken_as_unreachable() {
        // A server that takes the connection and never answers, as one behind a dropped network does.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let mut held = Vec::new();
            while let Ok((stream, _)) = listener.accept().await {
                held.push(stream);
            }
        });
        let client = Client::new(&format!("http://{address}"), None, "test").unwrap();
        let waiting = tokio::spawn({
            let client = client.clone();
            async move { client.server_version().await }
        });
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert!(client.longest_wait().is_some_and(|waited| waited >= Duration::from_millis(200)), "it waits");
        client.set_reachable(false);
        let outcome = tokio::time::timeout(Duration::from_secs(2), waiting).await.expect("gave up at once").unwrap();
        assert!(matches!(outcome, Err(ApiError::Offline(_))), "{outcome:?}");
        assert_eq!(client.longest_wait(), None, "none waits now");
    }

    #[tokio::test]
    async fn read_resent_after_the_server_hangs_up() {
        // The server closes the connection once the request is read, as Node does to an idle one it is letting go.
        let server = FakeServer::start(vec![
            CannedResponse::hang_up(),
            CannedResponse::json(200, r#"{"major":2,"minor":3,"patch":1}"#),
        ])
        .await;
        let client = Client::new(&server.url, None, "test").unwrap().with_retry_policy(RetryPolicy {
            base_delay: Duration::from_millis(1),
            ..RetryPolicy::default()
        });
        client.server_version().await.unwrap();
        assert_eq!(server.requests().len(), 2, "sent again on a new connection");
    }

    #[tokio::test]
    async fn refused_connection_is_offline() {
        // Bind and drop a listener, so the port is very likely closed.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        drop(listener);
        let client = Client::new(&format!("http://{address}"), None, "test")
            .unwrap()
            .with_retry_policy(RetryPolicy {
                max_retries: 0,
                ..RetryPolicy::default()
            });
        let error = client.server_version().await.unwrap_err();
        assert!(matches!(error, ApiError::Offline(_)), "{error:?}");
    }

    #[tokio::test]
    async fn conditional_get_reports_not_modified() {
        let server = FakeServer::start(vec![
            CannedResponse::json(200, "[]").with_header("etag", "W/\"abc\""),
            CannedResponse::json(304, ""),
        ])
        .await;
        let client = Client::new(&server.url, None, "test").unwrap();
        let first = client.albums_if_changed(None).await.unwrap();
        assert_eq!(
            first,
            Fetched::Changed {
                value: Vec::new(),
                etag: Some("W/\"abc\"".to_owned())
            }
        );
        let second = client.albums_if_changed(Some("W/\"abc\"")).await.unwrap();
        assert_eq!(second, Fetched::NotModified);
        assert_eq!(server.requests()[1].header("if-none-match").as_deref(), Some("W/\"abc\""));
    }
}

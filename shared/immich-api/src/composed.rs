//! Requests an app composes itself and sends through this client: Verso's Mac edition writes its endpoint calls in
//! Swift against Immich's JSON, and sends them here (ARCHITECTURE.md, "Verso on the Mac"). The client adds what it
//! adds to its own calls (the credential, the user agent, retries as the method allows, the reachability gate) and
//! answers with the response as it came, whatever its status, for the caller to read.

use bytes::Bytes;
use reqwest::header::{HeaderName, HeaderValue};
use reqwest::Method;

use crate::client::{Client, REQUEST_TIMEOUT};
use crate::error::{from_transport, ApiError};
use crate::retry::Resend;

/// Headers the client sets itself, which a composed request leaves out: its credential, user agent and framing.
const OWN_HEADERS: [&str; 6] = ["authorization", "x-api-key", "cookie", "user-agent", "content-length", "host"];

/// A request as the app composed it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ComposedRequest {
    /// The HTTP method, as `GET` or `PUT`.
    pub method: String,
    /// The endpoint below the API's base, its segments separated by `/` and not percent-encoded, as
    /// `assets/{id}/thumbnail`; each segment is encoded as it is sent.
    pub path: String,
    pub query: Vec<(String, String)>,
    /// Further headers, as `Content-Type`; the client's own are left out ([`OWN_HEADERS`]).
    pub headers: Vec<(String, String)>,
    pub body: Option<Vec<u8>>,
}

/// The server's answer, as it came.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Answer {
    pub status: u16,
    /// Every header of the response, names in lower case.
    pub headers: Vec<(String, String)>,
    pub body: Bytes,
}

impl Client {
    /// Send a request the app composed. Errors are only what kept an answer from coming: the server unreachable, or
    /// a request that cannot be made; any status the server answers with is an [`Answer`].
    pub async fn send_composed(&self, request: ComposedRequest) -> Result<Answer, ApiError> {
        let method = Method::from_bytes(request.method.as_bytes())
            .map_err(|_| ApiError::Protocol(format!("`{}` is not an HTTP method", request.method)))?;
        let segments: Vec<&str> = request.path.split('/').filter(|segment| !segment.is_empty()).collect();
        let mut builder = self.request(method.clone(), &segments).query(&request.query).timeout(REQUEST_TIMEOUT);
        for (name, value) in &request.headers {
            if OWN_HEADERS.iter().any(|own| own.eq_ignore_ascii_case(name)) {
                continue;
            }
            let name = HeaderName::from_bytes(name.as_bytes())
                .map_err(|_| ApiError::Protocol(format!("`{name}` is not a header name")))?;
            let value = HeaderValue::from_str(value)
                .map_err(|_| ApiError::Protocol(format!("the header `{name}` has a value that cannot be sent")))?;
            builder = builder.header(name, value);
        }
        if let Some(body) = request.body {
            builder = builder.body(body);
        }
        let response = self.execute_resending(builder, Resend::by_method(&method)).await?;
        let status = response.status().as_u16();
        let headers = response
            .headers()
            .iter()
            .filter_map(|(name, value)| Some((name.as_str().to_owned(), value.to_str().ok()?.to_owned())))
            .collect();
        let body = response.bytes().await.map_err(|error| from_transport(&error))?;
        Ok(Answer { status, headers, body })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::client::Credential;
    use crate::retry::RetryPolicy;
    use crate::test_server::{CannedResponse, FakeServer};

    fn albums_request() -> ComposedRequest {
        ComposedRequest {
            method: "GET".to_owned(),
            path: "albums".to_owned(),
            query: vec![("shared".to_owned(), "true".to_owned())],
            ..ComposedRequest::default()
        }
    }

    #[tokio::test]
    async fn sends_the_request_with_the_clients_credential() {
        let server = FakeServer::start(vec![CannedResponse::json(200, r#"[{"id":"a"}]"#)]).await;
        let client = Client::new(&server.url, Some(Credential::ApiKey("key".to_owned())), "test").unwrap();
        let answer = client.send_composed(albums_request()).await.unwrap();
        assert_eq!(answer.status, 200);
        assert_eq!(answer.body, Bytes::from_static(br#"[{"id":"a"}]"#));
        assert!(answer.headers.iter().any(|(name, value)| name == "content-type" && value.starts_with("application/json")));
        let sent = &server.requests()[0];
        assert_eq!((sent.method.as_str(), sent.target.as_str()), ("GET", "/api/albums?shared=true"));
        assert_eq!(sent.header("x-api-key").as_deref(), Some("key"));
        assert_eq!(sent.header("user-agent").as_deref(), Some("test"));
    }

    #[tokio::test]
    async fn sends_the_body_and_its_headers_but_never_another_credential() {
        let server = FakeServer::start(vec![CannedResponse::json(201, "{}")]).await;
        let client = Client::new(&server.url, Some(Credential::ApiKey("key".to_owned())), "test").unwrap();
        let request = ComposedRequest {
            method: "PUT".to_owned(),
            path: "albums/an album/assets".to_owned(),
            headers: vec![
                ("Content-Type".to_owned(), "application/json".to_owned()),
                ("x-api-key".to_owned(), "someone else's".to_owned()),
                ("Authorization".to_owned(), "Bearer someone else's".to_owned()),
            ],
            body: Some(br#"{"ids":["a"]}"#.to_vec()),
            ..ComposedRequest::default()
        };
        assert_eq!(client.send_composed(request).await.unwrap().status, 201);
        let sent = &server.requests()[0];
        assert_eq!(sent.target, "/api/albums/an%20album/assets");
        assert_eq!(sent.header("content-type").as_deref(), Some("application/json"));
        assert_eq!(sent.header("x-api-key").as_deref(), Some("key"));
        assert_eq!(sent.header("authorization"), None);
        assert_eq!(sent.body_text(), r#"{"ids":["a"]}"#);
    }

    #[tokio::test]
    async fn an_error_status_is_an_answer() {
        let body = r#"{"message":"Invalid user token","statusCode":401}"#;
        let server = FakeServer::start(vec![CannedResponse::json(401, body)]).await;
        let client = Client::new(&server.url, None, "test").unwrap();
        let answer = client.send_composed(albums_request()).await.unwrap();
        assert_eq!((answer.status, answer.body), (401, Bytes::from(body)));
    }

    #[tokio::test]
    async fn a_server_that_cannot_be_reached_is_an_error() {
        let no_retries = RetryPolicy { max_retries: 0, ..RetryPolicy::default() };
        let client = Client::new("http://127.0.0.1:9", None, "test").unwrap().with_retry_policy(no_retries);
        assert!(matches!(client.send_composed(albums_request()).await, Err(ApiError::Offline(_))));
    }

    #[tokio::test]
    async fn a_method_that_is_not_one_is_refused_unsent() {
        let client = Client::new("http://127.0.0.1:9", None, "test").unwrap();
        let request = ComposedRequest { method: "NOT A METHOD".to_owned(), ..albums_request() };
        assert!(matches!(client.send_composed(request).await, Err(ApiError::Protocol(_))));
    }
}

//! A server's own certificate: what Verso trusts when the system does not, and what a person sees to decide
//! (ARCHITECTURE.md, "A certificate of the server's own").
//!
//! Home servers often present a certificate of their own, self-signed or from a private authority the system does not
//! know. The system's own verification runs first, for every server and every connection; only when it refuses such a
//! certificate, and the person trusted exactly that certificate for this server (its pin: the SHA-256 of its DER), is
//! it accepted, and the handshake's signatures are still checked with the certificate's key. A pin trusts one
//! certificate for one server: never a whole authority, never every certificate, never by itself. A refused
//! certificate comes back as [`ApiError::UntrustedCertificate`], or [`ApiError::CertificateChanged`] when another one
//! was trusted for the server, with what the person needs to decide ([`CertificateRefusal`]).

use chrono::{DateTime, NaiveDate, Utc};
use sha2::{Digest, Sha256};

#[cfg(feature = "tls")]
use crate::error::ApiError;

/// A certificate's SHA-256 fingerprint, over its DER: what a person compares with the server's own, and the pin that
/// trusts that certificate. Written in pairs of hexadecimal digits separated by colons, as `openssl x509 -fingerprint
/// -sha256` prints it.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct CertificatePin([u8; 32]);

impl CertificatePin {
    /// The fingerprint of a certificate, from its DER.
    pub fn of(der: &[u8]) -> CertificatePin {
        CertificatePin(Sha256::digest(der).into())
    }

    /// A fingerprint as people write it: 64 hexadecimal digits in either case, in pairs separated by colons or spaces
    /// or not, with what `openssl x509 -fingerprint -sha256` prints before it (`sha256 Fingerprint=`) or without.
    pub fn parse(text: &str) -> Option<CertificatePin> {
        let digits = text.rsplit_once('=').map_or(text, |(_, after)| after);
        let mut bytes = [0u8; 32];
        let mut count = 0;
        for character in digits.trim().chars().filter(|character| !matches!(character, ':' | ' ')) {
            let value = character.to_digit(16)? as u8;
            let byte = bytes.get_mut(count / 2)?;
            *byte = (*byte << 4) | value;
            count += 1;
        }
        (count == 64).then_some(CertificatePin(bytes))
    }

    pub fn bytes(&self) -> [u8; 32] {
        self.0
    }
}

impl std::fmt::Display for CertificatePin {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let pairs: Vec<String> = self.0.iter().map(|byte| format!("{byte:02X}")).collect();
        formatter.write_str(&pairs.join(":"))
    }
}

impl std::fmt::Debug for CertificatePin {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "CertificatePin({self})")
    }
}

impl std::str::FromStr for CertificatePin {
    type Err = String;

    fn from_str(text: &str) -> Result<CertificatePin, String> {
        CertificatePin::parse(text).ok_or_else(|| format!("`{text}` is not a SHA-256 fingerprint: 64 hexadecimal digits, in pairs separated by colons or not"))
    }
}

/// What a certificate says about itself, for the person deciding whether to trust it. Read from its DER for showing
/// only: trusting it rests on its fingerprint alone, so a field that cannot be read stays empty.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CertificateDetails {
    pub sha256: CertificatePin,
    /// Who it was issued to: its subject's common name, else its organisation, else the names it is valid for.
    pub subject: String,
    /// Who issued it, as `subject` reads, from the issuer's name.
    pub issuer: String,
    pub valid_from: Option<DateTime<Utc>>,
    pub valid_until: Option<DateTime<Utc>>,
    /// Issued by itself (its issuer is its subject), as a self-signed certificate is.
    pub self_signed: bool,
}

impl CertificateDetails {
    pub fn from_der(der: &[u8]) -> CertificateDetails {
        let sha256 = CertificatePin::of(der);
        match parse_certificate(der) {
            Some(parsed) => CertificateDetails {
                sha256,
                subject: readable_name(parsed.subject).or_else(|| (!parsed.names.is_empty()).then(|| parsed.names.join(", "))).unwrap_or_default(),
                issuer: readable_name(parsed.issuer).unwrap_or_default(),
                valid_from: parsed.valid_from,
                valid_until: parsed.valid_until,
                self_signed: parsed.issuer == parsed.subject,
            },
            None => CertificateDetails { sha256, subject: String::new(), issuer: String::new(), valid_from: None, valid_until: None, self_signed: false },
        }
    }
}

/// Why the system refused a certificate a person may still trust.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RefusalReason {
    /// Issued by an authority the system does not trust: by itself, or by a private authority.
    UnknownIssuer,
    /// Not made for the server's name.
    NotValidForName,
    /// Past the end of its validity.
    Expired,
    /// Before the start of its validity.
    NotYetValid,
    /// Another reason, in the system's words.
    Other(String),
}

impl std::fmt::Display for RefusalReason {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RefusalReason::UnknownIssuer => formatter.write_str("issued by an authority it does not trust"),
            RefusalReason::NotValidForName => formatter.write_str("made for another name"),
            RefusalReason::Expired => formatter.write_str("expired"),
            RefusalReason::NotYetValid => formatter.write_str("not valid yet"),
            RefusalReason::Other(words) => formatter.write_str(words),
        }
    }
}

/// A certificate the system refused, which a person may decide to trust for the server: what it is, why it was
/// refused, and the certificate trusted for the server before, when the server presented another.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CertificateRefusal {
    pub certificate: CertificateDetails,
    pub reason: RefusalReason,
    /// The certificate trusted for this server, when the server presented another one: it changed.
    pub trusted: Option<CertificatePin>,
}

impl CertificateRefusal {
    /// Whether the server presented another certificate than the one trusted for it.
    pub fn changed(&self) -> bool {
        self.trusted.is_some()
    }

    /// Why it was refused, in words for people: "self-signed" for a self-signed certificate whose issuer the system
    /// does not know, which webpki also says of one marked as an authority ("CaUsedAsEndEntity").
    pub fn why(&self) -> String {
        match &self.reason {
            RefusalReason::UnknownIssuer | RefusalReason::Other(_) if self.certificate.self_signed => "self-signed".to_owned(),
            reason => reason.to_string(),
        }
    }
}

// --- Reading a certificate's DER, for showing it ---

const SEQUENCE: u8 = 0x30;
const SET: u8 = 0x31;
const OID_COMMON_NAME: &[u8] = &[0x55, 0x04, 0x03];
const OID_ORGANISATION: &[u8] = &[0x55, 0x04, 0x0a];
const OID_SUBJECT_ALT_NAME: &[u8] = &[0x55, 0x1d, 0x11];

/// The parts of a certificate the details show; the names as their DER, compared whole for a self-signed one.
struct Parsed<'a> {
    issuer: &'a [u8],
    subject: &'a [u8],
    valid_from: Option<DateTime<Utc>>,
    valid_until: Option<DateTime<Utc>>,
    /// The host names and addresses of its subject alternative names.
    names: Vec<String>,
}

/// One DER element: its tag, its contents and what follows it. Only the short tags a certificate's outer structure
/// uses; anything malformed is `None`.
fn element(input: &[u8]) -> Option<(u8, &[u8], &[u8])> {
    let (&tag, rest) = input.split_first()?;
    if tag & 0x1f == 0x1f {
        return None;
    }
    let (&first, rest) = rest.split_first()?;
    let (length, rest) = if first < 0x80 {
        (usize::from(first), rest)
    } else {
        let count = usize::from(first & 0x7f);
        if count == 0 || count > 4 || rest.len() < count {
            return None;
        }
        let length = rest[..count].iter().fold(0usize, |length, byte| (length << 8) | usize::from(*byte));
        (length, &rest[count..])
    };
    (rest.len() >= length).then(|| (tag, &rest[..length], &rest[length..]))
}

/// The next element, which must have `tag`.
fn expect(input: &[u8], tag: u8) -> Option<(&[u8], &[u8])> {
    let (found, contents, rest) = element(input)?;
    (found == tag).then_some((contents, rest))
}

/// The elements of a SEQUENCE's or a SET's contents, one by one.
fn elements(mut input: &[u8]) -> impl Iterator<Item = (u8, &[u8])> {
    std::iter::from_fn(move || {
        let (tag, contents, rest) = element(input)?;
        input = rest;
        Some((tag, contents))
    })
}

fn parse_certificate(der: &[u8]) -> Option<Parsed<'_>> {
    let (certificate, _) = expect(der, SEQUENCE)?;
    let (tbs, _) = expect(certificate, SEQUENCE)?;
    let mut rest = tbs;
    // version [0] EXPLICIT, optional
    if let Some((0xa0, _, after)) = element(rest) {
        rest = after;
    }
    let (_serial, rest) = expect(rest, 0x02)?;
    let (_algorithm, rest) = expect(rest, SEQUENCE)?;
    let (issuer, rest) = expect(rest, SEQUENCE)?;
    let (validity, rest) = expect(rest, SEQUENCE)?;
    let (subject, rest) = expect(rest, SEQUENCE)?;
    let (_key, rest) = expect(rest, SEQUENCE)?;
    let mut times = elements(validity).map(|(tag, contents)| time(tag, contents));
    let (valid_from, valid_until) = (times.next().flatten(), times.next().flatten());
    // issuerUniqueID [1], subjectUniqueID [2], then extensions [3] EXPLICIT
    let names = elements(rest).find(|(tag, _)| *tag == 0xa3).and_then(|(_, extensions)| alternative_names(extensions)).unwrap_or_default();
    Some(Parsed { issuer, subject, valid_from, valid_until, names })
}

/// UTCTime (`YYMMDDHHMMSSZ`, 1950 to 2049) or GeneralizedTime (`YYYYMMDDHHMMSSZ`).
fn time(tag: u8, contents: &[u8]) -> Option<DateTime<Utc>> {
    let text = std::str::from_utf8(contents).ok()?.strip_suffix('Z')?;
    let (year, rest) = match tag {
        0x17 => {
            let short: i32 = text.get(..2)?.parse().ok()?;
            (if short >= 50 { 1900 + short } else { 2000 + short }, text.get(2..)?)
        }
        0x18 => (text.get(..4)?.parse().ok()?, text.get(4..)?),
        _ => return None,
    };
    if rest.len() != 10 || !rest.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let field = |at: usize| rest[at..at + 2].parse::<u32>().ok();
    let moment = NaiveDate::from_ymd_opt(year, field(0)?, field(2)?)?.and_hms_opt(field(4)?, field(6)?, field(8)?)?;
    Some(moment.and_utc())
}

/// A name's common name, else its organisation; `None` when it has neither.
fn readable_name(name: &[u8]) -> Option<String> {
    let mut common_name = None;
    let mut organisation = None;
    for (_, set) in elements(name).filter(|(tag, _)| *tag == SET) {
        for (_, attribute) in elements(set).filter(|(tag, _)| *tag == SEQUENCE) {
            let Some((oid, rest)) = expect(attribute, 0x06) else { continue };
            let Some((tag, value, _)) = element(rest) else { continue };
            let text = string(tag, value);
            if oid == OID_COMMON_NAME && common_name.is_none() {
                common_name = text;
            } else if oid == OID_ORGANISATION && organisation.is_none() {
                organisation = text;
            }
        }
    }
    common_name.or(organisation).filter(|text| !text.trim().is_empty())
}

/// A directory string as text: UTF-8, printable, IA5, T.61 (read as Latin-1) or BMP (UTF-16).
fn string(tag: u8, value: &[u8]) -> Option<String> {
    match tag {
        0x0c | 0x13 | 0x16 => Some(String::from_utf8_lossy(value).into_owned()),
        0x14 => Some(value.iter().map(|byte| char::from(*byte)).collect()),
        0x1e => {
            let units: Vec<u16> = value.as_chunks::<2>().0.iter().map(|pair| u16::from_be_bytes(*pair)).collect();
            Some(String::from_utf16_lossy(&units))
        }
        _ => None,
    }
}

/// The host names and addresses of the subject alternative names extension, from the extensions' `[3]` contents.
fn alternative_names(extensions: &[u8]) -> Option<Vec<String>> {
    let (list, _) = expect(extensions, SEQUENCE)?;
    for (_, extension) in elements(list).filter(|(tag, _)| *tag == SEQUENCE) {
        let Some((oid, mut rest)) = expect(extension, 0x06) else { continue };
        if oid != OID_SUBJECT_ALT_NAME {
            continue;
        }
        // critical BOOLEAN DEFAULT FALSE
        if let Some((0x01, _, after)) = element(rest) {
            rest = after;
        }
        let (value, _) = expect(rest, 0x04)?;
        let (general_names, _) = expect(value, SEQUENCE)?;
        let names = elements(general_names)
            .filter_map(|(tag, name)| match (tag, name.len()) {
                (0x82, _) => Some(String::from_utf8_lossy(name).into_owned()),
                (0x87, 4) => Some(std::net::Ipv4Addr::new(name[0], name[1], name[2], name[3]).to_string()),
                (0x87, 16) => <[u8; 16]>::try_from(name).ok().map(|octets| std::net::Ipv6Addr::from(octets).to_string()),
                _ => None,
            })
            .collect();
        return Some(names);
    }
    None
}

// --- Verifying a server's certificate ---

#[cfg(feature = "tls")]
pub use verifier::set_system_verifier;
#[cfg(feature = "tls")]
pub(crate) use verifier::{is_certificate_failure, refusal_in, tls_config};
#[cfg(all(feature = "tls", test))]
pub(crate) use verifier::tls_config_over;

/// Without TLS (the portability check's build) there is no certificate to refuse.
#[cfg(not(feature = "tls"))]
pub(crate) fn refusal_in(_error: &(dyn std::error::Error + 'static)) -> Option<CertificateRefusal> {
    None
}

/// Without TLS no failure is a certificate's.
#[cfg(not(feature = "tls"))]
pub(crate) fn is_certificate_failure(_error: &(dyn std::error::Error + 'static)) -> bool {
    false
}

#[cfg(feature = "tls")]
mod verifier {
    use std::sync::{Arc, OnceLock};

    use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
    use rustls::client::WebPkiServerVerifier;
    use rustls::crypto::{CryptoProvider, WebPkiSupportedAlgorithms};
    use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
    use rustls::{CertificateError, DigitallySignedStruct, DistinguishedName, OtherError, RootCertStore, SignatureScheme};

    use super::{ApiError, CertificateDetails, CertificatePin, CertificateRefusal, RefusalReason};

    /// The platform's own verifier, when the platform hands one over ([`set_system_verifier`]).
    static SYSTEM_VERIFIER: OnceLock<Arc<dyn ServerCertVerifier>> = OnceLock::new();

    /// Hand every client made after this the platform's own judgement of certificates, which the pinned certificate
    /// is checked after: the Apple bridge gives the system's verifier (`rustls-platform-verifier`), since iOS lets no
    /// program list its trusted roots. Without one, the roots `rustls-native-certs` lists. Only the first call counts.
    pub fn set_system_verifier(verifier: Arc<dyn ServerCertVerifier>) {
        let _ = SYSTEM_VERIFIER.set(verifier);
    }

    /// The system's verifier: the platform's, else one over the roots the system lists now, read afresh for each
    /// client so an authority installed while Verso runs counts at the next sign-in.
    fn system_verifier(provider: &Arc<CryptoProvider>) -> Arc<dyn ServerCertVerifier> {
        if let Some(verifier) = SYSTEM_VERIFIER.get() {
            return verifier.clone();
        }
        let mut roots = RootCertStore::empty();
        roots.add_parsable_certificates(rustls_native_certs::load_native_certs().certs);
        match WebPkiServerVerifier::builder_with_provider(Arc::new(roots), provider.clone()).build() {
            Ok(verifier) => verifier,
            // A system that lists no authority trusts no certificate; a person may still trust their server's.
            Err(_) => Arc::new(NoAuthority(provider.signature_verification_algorithms)),
        }
    }

    /// The TLS configuration of a client: the system's verification, then the certificate trusted for the server.
    pub(crate) fn tls_config(trusted: Option<CertificatePin>) -> Result<rustls::ClientConfig, ApiError> {
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        tls_config_over(system_verifier(&provider), trusted)
    }

    /// [`tls_config`] over a given system verifier.
    pub(crate) fn tls_config_over(system: Arc<dyn ServerCertVerifier>, trusted: Option<CertificatePin>) -> Result<rustls::ClientConfig, ApiError> {
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let verifier = PinnedVerifier { system, trusted, algorithms: provider.signature_verification_algorithms };
        let mut config = rustls::ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .map_err(|error| ApiError::Protocol(format!("cannot set up TLS: {error}")))?
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(verifier))
            .with_no_client_auth();
        // reqwest offers HTTP/2 and HTTP/1.1 on a configuration it builds itself; one handed over says so.
        config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
        Ok(config)
    }

    /// The system's verification first; then, for a certificate it refused for a reason a self-signed or private
    /// authority's certificate gives, the certificate trusted for this server, compared by its fingerprint. A refused
    /// certificate's details ride in the error, so the client can say what was presented.
    #[derive(Debug)]
    struct PinnedVerifier {
        system: Arc<dyn ServerCertVerifier>,
        trusted: Option<CertificatePin>,
        algorithms: WebPkiSupportedAlgorithms,
    }

    impl ServerCertVerifier for PinnedVerifier {
        fn verify_server_cert(
            &self,
            end_entity: &CertificateDer<'_>,
            intermediates: &[CertificateDer<'_>],
            server_name: &ServerName<'_>,
            ocsp_response: &[u8],
            now: UnixTime,
        ) -> Result<ServerCertVerified, rustls::Error> {
            let refused = match self.system.verify_server_cert(end_entity, intermediates, server_name, ocsp_response, now) {
                Ok(verified) => return Ok(verified),
                Err(refused) => refused,
            };
            let Some(reason) = reason_a_person_may_overrule(&refused) else { return Err(refused) };
            if self.trusted == Some(CertificatePin::of(end_entity.as_ref())) {
                return Ok(ServerCertVerified::assertion());
            }
            let refusal = CertificateRefusal { certificate: CertificateDetails::from_der(end_entity.as_ref()), reason, trusted: self.trusted };
            Err(rustls::Error::InvalidCertificate(CertificateError::Other(OtherError(Arc::new(Refused(refusal))))))
        }

        // The handshake proves the server holds the key of the certificate it presented, a pinned one as any other.
        fn verify_tls12_signature(&self, message: &[u8], certificate: &CertificateDer<'_>, signed: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
            rustls::crypto::verify_tls12_signature(message, certificate, signed, &self.algorithms)
        }

        fn verify_tls13_signature(&self, message: &[u8], certificate: &CertificateDer<'_>, signed: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
            rustls::crypto::verify_tls13_signature(message, certificate, signed, &self.algorithms)
        }

        fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
            self.algorithms.supported_schemes()
        }

        fn root_hint_subjects(&self) -> Option<&[DistinguishedName]> {
            self.system.root_hint_subjects()
        }
    }

    /// A verifier for a system that lists no authority: every certificate's issuer is unknown.
    #[derive(Debug)]
    struct NoAuthority(WebPkiSupportedAlgorithms);

    impl ServerCertVerifier for NoAuthority {
        fn verify_server_cert(&self, _: &CertificateDer<'_>, _: &[CertificateDer<'_>], _: &ServerName<'_>, _: &[u8], _: UnixTime) -> Result<ServerCertVerified, rustls::Error> {
            Err(rustls::Error::InvalidCertificate(CertificateError::UnknownIssuer))
        }

        fn verify_tls12_signature(&self, message: &[u8], certificate: &CertificateDer<'_>, signed: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
            rustls::crypto::verify_tls12_signature(message, certificate, signed, &self.0)
        }

        fn verify_tls13_signature(&self, message: &[u8], certificate: &CertificateDer<'_>, signed: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
            rustls::crypto::verify_tls13_signature(message, certificate, signed, &self.0)
        }

        fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
            self.0.supported_schemes()
        }
    }

    /// Why the system refused a certificate, when it is a reason a certificate of the server's own gives: not issued by
    /// an authority the system trusts, not made for the name, outside its dates, or the platform's own words for those
    /// (webpki says a self-signed certificate marked as an authority is "CaUsedAsEndEntity"; Apple's verifier says
    /// "not trusted"). `None` for what no person's word overrules: a certificate that cannot be read, one its authority
    /// revoked, and failures that are not about the certificate.
    fn reason_a_person_may_overrule(refused: &rustls::Error) -> Option<RefusalReason> {
        let rustls::Error::InvalidCertificate(error) = refused else { return None };
        Some(match error {
            CertificateError::UnknownIssuer => RefusalReason::UnknownIssuer,
            CertificateError::NotValidForName | CertificateError::NotValidForNameContext { .. } => RefusalReason::NotValidForName,
            CertificateError::Expired | CertificateError::ExpiredContext { .. } => RefusalReason::Expired,
            CertificateError::NotValidYet | CertificateError::NotValidYetContext { .. } => RefusalReason::NotYetValid,
            CertificateError::BadEncoding
            | CertificateError::Revoked
            | CertificateError::UnknownRevocationStatus
            | CertificateError::ExpiredRevocationList
            | CertificateError::ExpiredRevocationListContext { .. }
            | CertificateError::InvalidOcspResponse
            | CertificateError::ApplicationVerificationFailure => return None,
            CertificateError::Other(other) => RefusalReason::Other(other.to_string()),
            other => RefusalReason::Other(format!("{other:?}")),
        })
    }

    /// A refusal, carried through rustls' error to the client's.
    #[derive(Debug)]
    struct Refused(CertificateRefusal);

    impl std::fmt::Display for Refused {
        fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            write!(formatter, "the certificate {} is not trusted: {}", self.0.certificate.sha256, self.0.reason)
        }
    }

    impl std::error::Error for Refused {}

    /// rustls' error in a transport failure's chain. An `io::Error` hides the error it wraps from `source()`, so it
    /// is looked into as well.
    fn rustls_error_in<'a>(error: &'a (dyn std::error::Error + 'static)) -> Option<&'a rustls::Error> {
        let mut current = Some(error);
        while let Some(error) = current {
            if let Some(found) = error.downcast_ref::<rustls::Error>() {
                return Some(found);
            }
            if let Some(inner) = error.downcast_ref::<std::io::Error>().and_then(std::io::Error::get_ref) {
                if let Some(found) = rustls_error_in(inner) {
                    return Some(found);
                }
            }
            current = error.source();
        }
        None
    }

    /// The refusal a transport failure carries, when the server's certificate was refused with one.
    pub(crate) fn refusal_in(error: &(dyn std::error::Error + 'static)) -> Option<CertificateRefusal> {
        match rustls_error_in(error)? {
            rustls::Error::InvalidCertificate(CertificateError::Other(other)) => other.0.downcast_ref::<Refused>().map(|refused| refused.0.clone()),
            _ => None,
        }
    }

    /// Whether a transport failure is a refused certificate, which no retry changes.
    pub(crate) fn is_certificate_failure(error: &(dyn std::error::Error + 'static)) -> bool {
        matches!(rustls_error_in(error), Some(rustls::Error::InvalidCertificate(_)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_fingerprint_reads_as_people_write_it_and_prints_as_openssl_does() {
        let der = b"a certificate";
        let pin = CertificatePin::of(der);
        let printed = pin.to_string();
        assert_eq!(printed.len(), 32 * 3 - 1);
        assert!(printed.chars().all(|character| character == ':' || character.is_ascii_hexdigit() && !character.is_ascii_lowercase()), "{printed}");
        assert_eq!(CertificatePin::parse(&printed), Some(pin));
        assert_eq!(CertificatePin::parse(&printed.replace(':', "").to_lowercase()), Some(pin));
        assert_eq!(CertificatePin::parse(&format!("sha256 Fingerprint={printed}\n")), Some(pin));
        assert_eq!(CertificatePin::parse(&printed.replace(':', " ")), Some(pin));
        assert_eq!(CertificatePin::parse(&printed[..printed.len() - 3]), None, "too short");
        assert_eq!(CertificatePin::parse(&format!("{printed}:00")), None, "too long");
        assert_eq!(CertificatePin::parse(&format!("G{}", &printed[1..])), None, "not hexadecimal");
        assert_eq!(CertificatePin::parse(""), None);
    }

    #[test]
    fn a_certificate_says_who_it_is_for_who_issued_it_and_when_it_is_valid() {
        let mut params = rcgen::CertificateParams::new(vec!["photos.home.arpa".to_owned(), "192.168.1.5".to_owned()]).unwrap();
        params.distinguished_name.push(rcgen::DnType::CommonName, "Photos at home");
        params.distinguished_name.push(rcgen::DnType::OrganizationName, "Holm");
        params.not_before = rcgen::date_time_ymd(2025, 3, 1);
        params.not_after = rcgen::date_time_ymd(2035, 2, 28);
        let key = rcgen::KeyPair::generate().unwrap();
        let certificate = params.self_signed(&key).unwrap();
        let details = CertificateDetails::from_der(certificate.der());
        assert_eq!(details.sha256, CertificatePin::of(certificate.der()));
        assert_eq!((details.subject.as_str(), details.issuer.as_str(), details.self_signed), ("Photos at home", "Photos at home", true));
        assert_eq!(details.valid_from.map(|date| date.to_rfc3339()).as_deref(), Some("2025-03-01T00:00:00+00:00"));
        assert_eq!(details.valid_until.map(|date| date.to_rfc3339()).as_deref(), Some("2035-02-28T00:00:00+00:00"));
    }

    #[test]
    fn a_certificate_without_a_common_name_is_named_by_its_names_and_its_authority_by_its_own() {
        let mut authority_params = rcgen::CertificateParams::new(Vec::<String>::new()).unwrap();
        authority_params.is_ca = rcgen::IsCa::Ca(rcgen::BasicConstraints::Unconstrained);
        authority_params.distinguished_name = rcgen::DistinguishedName::new();
        authority_params.distinguished_name.push(rcgen::DnType::OrganizationName, "Home Authority");
        let authority = rcgen::Issuer::new(authority_params, rcgen::KeyPair::generate().unwrap());
        let mut params = rcgen::CertificateParams::new(vec!["photos.lan".to_owned(), "10.0.0.2".to_owned()]).unwrap();
        params.distinguished_name = rcgen::DistinguishedName::new();
        let certificate = params.signed_by(&rcgen::KeyPair::generate().unwrap(), &authority).unwrap();
        let details = CertificateDetails::from_der(certificate.der());
        assert_eq!((details.subject.as_str(), details.issuer.as_str(), details.self_signed), ("photos.lan, 10.0.0.2", "Home Authority", false));
    }

    #[test]
    fn what_cannot_be_read_still_has_its_fingerprint() {
        for garbage in [&b""[..], b"\x30\x84\xff\xff\xff\xff", b"\x30\x03\x30\x01", b"not a certificate"] {
            let details = CertificateDetails::from_der(garbage);
            assert_eq!(details.sha256, CertificatePin::of(garbage));
            assert_eq!((details.subject.as_str(), details.valid_until), ("", None));
        }
    }

    #[test]
    fn both_kinds_of_time_are_read() {
        assert_eq!(time(0x17, b"491231235959Z").map(|date| date.to_rfc3339()).as_deref(), Some("2049-12-31T23:59:59+00:00"));
        assert_eq!(time(0x17, b"500101000000Z").map(|date| date.to_rfc3339()).as_deref(), Some("1950-01-01T00:00:00+00:00"));
        assert_eq!(time(0x18, b"20510615120000Z").map(|date| date.to_rfc3339()).as_deref(), Some("2051-06-15T12:00:00+00:00"));
        assert_eq!(time(0x18, b"2051061512Z"), None);
        assert_eq!(time(0x17, b"491231235959"), None, "without its zone");
    }
}

/// Connections to a TLS server of the test's own: the system's verification, the pin, and the handshake's signatures.
#[cfg(all(test, feature = "tls"))]
mod connection_tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    use rustls::client::WebPkiServerVerifier;
    use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
    use rustls::server::{ClientHello, ResolvesServerCert};
    use rustls::sign::CertifiedKey;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    use super::*;
    use crate::client::Client;
    use crate::error::ApiError;

    /// What the server presents, and the key it signs the handshake with (another than the certificate's, for the
    /// test of the handshake's signature).
    struct Presented {
        chain: Vec<CertificateDer<'static>>,
        signing_key: rcgen::KeyPair,
    }

    #[derive(Debug)]
    struct Always(Arc<CertifiedKey>);

    impl ResolvesServerCert for Always {
        fn resolve(&self, _: ClientHello<'_>) -> Option<Arc<CertifiedKey>> {
            Some(self.0.clone())
        }
    }

    /// A TLS server on localhost that answers `/api/server/version`; returns its address and how many connections it
    /// took. `tls12` keeps it to TLS 1.2, whose handshake is signed another way.
    async fn serve(presented: Presented, tls12: bool) -> (String, Arc<AtomicUsize>) {
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(presented.signing_key.serialize_der()));
        let signing_key = provider.key_provider.load_private_key(key).unwrap();
        // CertifiedKey::new, unlike the builder's with_single_cert, does not insist that the key is the certificate's.
        let certified = Arc::new(CertifiedKey::new(presented.chain, signing_key));
        let versions: &[&rustls::SupportedProtocolVersion] = if tls12 { &[&rustls::version::TLS12] } else { &[&rustls::version::TLS13, &rustls::version::TLS12] };
        let mut config = rustls::ServerConfig::builder_with_provider(provider)
            .with_protocol_versions(versions)
            .unwrap()
            .with_no_client_auth()
            .with_cert_resolver(Arc::new(Always(certified)));
        config.alpn_protocols = vec![b"http/1.1".to_vec()];
        let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = format!("https://localhost:{}", listener.local_addr().unwrap().port());
        let connections = Arc::new(AtomicUsize::new(0));
        let counted = connections.clone();
        tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                counted.fetch_add(1, Ordering::SeqCst);
                let acceptor = acceptor.clone();
                tokio::spawn(async move {
                    let Ok(mut stream) = acceptor.accept(stream).await else { return };
                    let mut request = Vec::new();
                    let mut buffer = [0u8; 1024];
                    while !request.windows(4).any(|window| window == b"\r\n\r\n") {
                        match stream.read(&mut buffer).await {
                            Ok(0) | Err(_) => return,
                            Ok(read) => request.extend_from_slice(&buffer[..read]),
                        }
                    }
                    let body = r#"{"major":3,"minor":3,"patch":5}"#;
                    let answer = format!("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}", body.len());
                    let _ = stream.write_all(answer.as_bytes()).await;
                    let _ = stream.shutdown().await;
                });
            }
        });
        (address, connections)
    }

    /// A certificate for localhost signed by itself, and its key.
    fn self_signed() -> (CertificateDer<'static>, rcgen::KeyPair) {
        let made = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()]).unwrap();
        (made.cert.der().clone(), made.signing_key)
    }

    /// An authority the test's "system" trusts, and a certificate for localhost it issued.
    fn authority_and_certificate() -> (CertificateDer<'static>, CertificateDer<'static>, rcgen::KeyPair) {
        let mut params = rcgen::CertificateParams::new(Vec::<String>::new()).unwrap();
        params.is_ca = rcgen::IsCa::Ca(rcgen::BasicConstraints::Unconstrained);
        params.distinguished_name.push(rcgen::DnType::CommonName, "Test Authority");
        let authority_key = rcgen::KeyPair::generate().unwrap();
        let authority_certificate = params.self_signed(&authority_key).unwrap();
        let issuer = rcgen::Issuer::new(params, authority_key);
        let key = rcgen::KeyPair::generate().unwrap();
        let certificate = rcgen::CertificateParams::new(vec!["localhost".to_owned()]).unwrap().signed_by(&key, &issuer).unwrap();
        (authority_certificate.der().clone(), certificate.der().clone(), key)
    }

    /// A client whose "system" trusts `authority` alone, with `trusted` pinned, and no retries.
    fn client(address: &str, authority: &CertificateDer<'static>, trusted: Option<CertificatePin>) -> Client {
        let mut roots = rustls::RootCertStore::empty();
        roots.add(authority.clone()).unwrap();
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let system = WebPkiServerVerifier::builder_with_provider(Arc::new(roots), provider).build().unwrap();
        let config = tls_config_over(system, trusted).unwrap();
        Client::with_tls(address, None, "test", trusted, Some(config))
            .unwrap()
            .with_retry_policy(crate::retry::RetryPolicy { base_delay: std::time::Duration::from_millis(1), ..Default::default() })
    }

    fn unrelated_authority() -> CertificateDer<'static> {
        authority_and_certificate().0
    }

    #[tokio::test]
    async fn a_self_signed_certificate_is_refused_once_with_what_a_person_needs() {
        let (certificate, key) = self_signed();
        let (address, connections) = serve(Presented { chain: vec![certificate.clone()], signing_key: key }, false).await;
        let error = client(&address, &unrelated_authority(), None).server_version().await.unwrap_err();
        let ApiError::UntrustedCertificate(refusal) = &error else { panic!("{error:?}") };
        assert_eq!(refusal.certificate.sha256, CertificatePin::of(certificate.as_ref()));
        assert!(refusal.certificate.self_signed);
        assert!(refusal.certificate.valid_until.is_some());
        assert_eq!(refusal.trusted, None);
        assert!(!refusal.changed());
        assert!(crate::error::is_certificate_text(&error.to_string()), "{error}");
        assert_eq!(connections.load(Ordering::SeqCst), 1, "a refused certificate is not tried again");
    }

    #[tokio::test]
    async fn a_self_signed_certificate_is_accepted_with_its_pin() {
        for tls12 in [false, true] {
            let (certificate, key) = self_signed();
            let pin = CertificatePin::of(certificate.as_ref());
            let (address, _) = serve(Presented { chain: vec![certificate], signing_key: key }, tls12).await;
            let client = client(&address, &unrelated_authority(), Some(pin));
            assert_eq!(client.trusted_certificate(), Some(pin));
            assert_eq!(client.server_version().await.unwrap().to_string(), "v3.3.5", "TLS 1.2 only: {tls12}");
        }
    }

    #[tokio::test]
    async fn another_certificate_than_the_one_trusted_is_refused_as_changed() {
        let (certificate, key) = self_signed();
        let (earlier, _) = self_signed();
        let earlier = CertificatePin::of(earlier.as_ref());
        let (address, _) = serve(Presented { chain: vec![certificate.clone()], signing_key: key }, false).await;
        let error = client(&address, &unrelated_authority(), Some(earlier)).server_version().await.unwrap_err();
        let ApiError::CertificateChanged(refusal) = &error else { panic!("{error:?}") };
        assert_eq!(refusal.certificate.sha256, CertificatePin::of(certificate.as_ref()));
        assert_eq!(refusal.trusted, Some(earlier));
        assert!(refusal.changed());
    }

    #[tokio::test]
    async fn a_certificate_the_system_trusts_needs_no_pin_and_any_pin_leaves_it_trusted() {
        let (authority, certificate, key) = authority_and_certificate();
        let (address, _) = serve(Presented { chain: vec![certificate], signing_key: key }, false).await;
        client(&address, &authority, None).server_version().await.unwrap();
        let (other, _) = self_signed();
        client(&address, &authority, Some(CertificatePin::of(other.as_ref()))).server_version().await.unwrap();
    }

    #[tokio::test]
    async fn the_handshake_is_still_checked_with_the_pinned_certificates_key() {
        for tls12 in [false, true] {
            let (certificate, _) = self_signed();
            let pin = CertificatePin::of(certificate.as_ref());
            let impostor_key = rcgen::KeyPair::generate().unwrap();
            let (address, _) = serve(Presented { chain: vec![certificate], signing_key: impostor_key }, tls12).await;
            let error = client(&address, &unrelated_authority(), Some(pin)).server_version().await.unwrap_err();
            assert!(matches!(error, ApiError::Offline(_)), "TLS 1.2 only: {tls12}: {error:?}");
            assert!(error.to_string().to_lowercase().contains("signature"), "{error}");
        }
    }

    #[tokio::test]
    async fn an_expired_certificate_is_refused_as_expired_and_trusted_by_its_pin() {
        let mut params = rcgen::CertificateParams::new(vec!["localhost".to_owned()]).unwrap();
        params.not_before = rcgen::date_time_ymd(2020, 1, 1);
        params.not_after = rcgen::date_time_ymd(2021, 1, 1);
        let key = rcgen::KeyPair::generate().unwrap();
        let certificate = params.self_signed(&key).unwrap().der().clone();
        let pin = CertificatePin::of(certificate.as_ref());
        let (address, _) = serve(Presented { chain: vec![certificate], signing_key: key }, false).await;
        let error = client(&address, &unrelated_authority(), None).server_version().await.unwrap_err();
        let ApiError::UntrustedCertificate(refusal) = &error else { panic!("{error:?}") };
        assert_eq!(refusal.reason, RefusalReason::Expired);
        client(&address, &unrelated_authority(), Some(pin)).server_version().await.unwrap();
    }
}

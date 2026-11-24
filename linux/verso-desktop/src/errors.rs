//! What a person reads when Immich did not do what the gallery asked: the server's own reason when it turned the
//! request down (a 400 or a 409 with its words, `ApiError::refusal`), rather than "unexpected answer from the Immich
//! server: HTTP 400: …"; a plain sentence for the other kinds. An unreachable server keeps its wording, which the
//! window recognises (`immich_api::is_offline_text`) to show its banner instead.

use immich_api::ApiError;
use verso_linux::i18n::tr;

/// The error as a person reads it, without a trailing full stop, so it can follow "Adding to the album failed: ".
pub fn said(error: &ApiError) -> String {
    match error {
        ApiError::Offline(_) | ApiError::LocalFile(_) | ApiError::RangeNotSatisfiable => error.to_string(),
        ApiError::Unauthorized => tr("Immich no longer accepts this sign-in").to_owned(),
        ApiError::Forbidden { missing_permission: Some(permission) } => tr("this sign-in may not do that in Immich (it needs the permission {permission})").replace("{permission}", permission),
        ApiError::Forbidden { missing_permission: None } => tr("this sign-in may not do that in Immich").to_owned(),
        ApiError::NotFound => tr("Immich no longer has it, or this sign-in cannot see it").to_owned(),
        ApiError::Transient { .. } => tr("the Immich server is busy; try again in a moment").to_owned(),
        ApiError::Protocol(detail) => match error.refusal() {
            Some((_, reason)) if !reason.trim().is_empty() => tr("Immich says: {reason}").replace("{reason}", reason.trim().trim_end_matches('.')),
            Some((status, _)) => tr("Immich turned it down (HTTP {status})").replace("{status}", &status.to_string()),
            None => tr("Immich's answer could not be read ({detail})").replace("{detail}", detail),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_refusal_says_the_servers_own_reason() {
        let refused = ApiError::Protocol("HTTP 400: Crop action must be the first edit action".to_owned());
        assert_eq!(said(&refused), "Immich says: Crop action must be the first edit action");
        let bare = ApiError::Protocol("HTTP 409: ".to_owned());
        assert_eq!(said(&bare), "Immich turned it down (HTTP 409)");
    }

    #[test]
    fn an_answer_that_cannot_be_read_says_so() {
        let garbled = ApiError::Protocol("invalid JSON at line 1".to_owned());
        assert_eq!(said(&garbled), "Immich's answer could not be read (invalid JSON at line 1)");
    }

    #[test]
    fn an_unreachable_server_keeps_the_words_the_window_recognises() {
        let offline = ApiError::Offline("connection refused".to_owned());
        assert!(immich_api::is_offline_text(&said(&offline)));
    }

    #[test]
    fn a_missing_permission_is_named() {
        let forbidden = ApiError::Forbidden { missing_permission: Some("asset.update".to_owned()) };
        assert_eq!(said(&forbidden), "this sign-in may not do that in Immich (it needs the permission asset.update)");
    }
}

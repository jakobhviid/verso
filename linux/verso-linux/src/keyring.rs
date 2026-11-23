//! The credential in the desktop keyring: the Secret Service, through `oo7` (SPEC.md, "Signing in and credentials").
//!
//! One item per server, labelled "Verso: <server>" (Immich Mount's are its own, `verso_core::product`, which Verso reads
//! only to take its account over), holding the credential in the same two-line form as the
//! headless file. A locked keyring brings up the system's unlock prompt. A dismissed prompt is an error of its own,
//! never a silent fallback to the file.

use verso_core::product::{self, Product};

use crate::credentials::{format_credential, parse_credential, Credential};

#[derive(Debug, thiserror::Error)]
pub enum KeyringError {
    #[error("no keyring is available: {0}")]
    Unavailable(String),
    #[error("the keyring stayed locked (the unlock prompt was dismissed)")]
    Dismissed,
    #[error("the keyring failed: {0}")]
    Failed(String),
}

fn classify(error: oo7::Error) -> KeyringError {
    match error {
        oo7::Error::DBus(oo7::dbus::Error::Dismissed) => KeyringError::Dismissed,
        oo7::Error::DBus(oo7::dbus::Error::ZBus(error)) => KeyringError::Unavailable(error.to_string()),
        // In a Flatpak, the keyring is the Secret portal's: one that does not answer (no keyring in the session) is
        // as good as none, and the sign-in is kept in the app's own file instead, in its sandbox's folder.
        oo7::Error::File(oo7::file::Error::Portal(error)) => KeyringError::Unavailable(error.to_string()),
        // A session whose bus has no keyring at all (a window manager's session on Ubuntu 24.04 that starts no GNOME
        // Keyring, say), where a Flatpak finds no Secret portal either and oo7 asks the bus for the Secret Service: the
        // bus answers that no such service is there, which oo7 hands on as the service's error.
        oo7::Error::DBus(oo7::dbus::Error::Service(oo7::dbus::ServiceError::ZBus(error))) if no_such_service(&error) => {
            KeyringError::Unavailable(error.to_string())
        }
        other => KeyringError::Failed(other.to_string()),
    }
}

/// The bus's answer that nothing owns the name asked for, as a method's error or as zbus's own.
fn no_such_service(error: &zbus::Error) -> bool {
    const NAMES: [&str; 2] = ["org.freedesktop.DBus.Error.ServiceUnknown", "org.freedesktop.DBus.Error.NameHasNoOwner"];
    match error {
        zbus::Error::MethodError(name, _, _) => NAMES.contains(&name.as_str()),
        zbus::Error::FDO(error) => {
            matches!(**error, zbus::fdo::Error::ServiceUnknown(_) | zbus::fdo::Error::NameHasNoOwner(_))
        }
        _ => false,
    }
}


/// The Secret Service's bus name, and the name KDE's `ksecretd` can be started by.
const SECRET_SERVICE: &str = "org.freedesktop.secrets";
const KWALLET_SECRET_SERVICE: &str = "org.kde.secretservicecompat";

/// Start KWallet's Secret Service where nothing has. `ksecretd` takes `org.freedesktop.secrets` once it runs, but D-Bus
/// can start it only by its own name; a Plasma login usually starts it through `pam_kwallet`, and without that every
/// Secret Service client finds no keyring. Elsewhere, or when a keyring already answers,
/// this does nothing.
async fn wake_kwallet() {
    let Ok(connection) = zbus::Connection::session().await else { return };
    let Ok(bus) = zbus::fdo::DBusProxy::new(&connection).await else { return };
    let (Ok(secrets), Ok(kwallet)) = (zbus::names::BusName::try_from(SECRET_SERVICE), zbus::names::BusName::try_from(KWALLET_SECRET_SERVICE)) else {
        return;
    };
    if bus.name_has_owner(secrets.clone()).await.unwrap_or(true) {
        return;
    }
    // Where a keyring can be started by the Secret Service's own name (GNOME Keyring), D-Bus starts that one on the
    // first request; KWallet must not take its place on a machine that has both.
    let activatable = bus.list_activatable_names().await.unwrap_or_default();
    if activatable.iter().any(|name| name.as_str() == SECRET_SERVICE) || !activatable.iter().any(|name| name.as_str() == KWALLET_SECRET_SERVICE) {
        return;
    }
    let zbus::names::BusName::WellKnown(kwallet) = kwallet else { return };
    if bus.start_service_by_name(kwallet, 0).await.is_err() {
        return;
    }
    for _ in 0..50 {
        if bus.name_has_owner(secrets.clone()).await.unwrap_or(false) {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
}

/// The attributes of this product's item for `server`: its `application` is the product's id.
fn attributes(server: &str) -> [(&'static str, &str); 2] {
    attributes_of(product::current(), server)
}

fn attributes_of<'a>(product: &'static Product, server: &'a str) -> [(&'static str, &'a str); 2] {
    [("application", product.id), ("server", server)]
}

/// Store the credential for `server`, replacing any earlier one. Unlocks the keyring first, with a prompt if needed.
pub async fn store(server: &str, credential: &Credential) -> Result<(), KeyringError> {
    wake_kwallet().await;
    let keyring = oo7::Keyring::new().await.map_err(classify)?;
    keyring.unlock().await.map_err(classify)?;
    keyring
        .create_item(&format!("{}: {server}", product::current().name), &attributes(server), format_credential(credential), true)
        .await
        .map_err(classify)
}

/// The items stored that match `attributes`, in the keyrings that already exist. Never the default
/// collection by alias: asking for it creates a keyring when there is none, with a prompt, which only storing a
/// credential should ever do.
async fn existing_items(attributes: &[(&str, &str)]) -> Result<Vec<oo7::dbus::Item>, KeyringError> {
    let dbus_error = |error: oo7::dbus::Error| classify(oo7::Error::DBus(error));
    wake_kwallet().await;
    let service = oo7::dbus::Service::new().await.map_err(dbus_error)?;
    let mut found = Vec::new();
    for collection in service.collections().await.map_err(dbus_error)? {
        found.extend(collection.search_items(&attributes).await.map_err(dbus_error)?);
    }
    Ok(found)
}

/// The credential stored for `server`, if any. A locked item is unlocked first, with a prompt if needed.
pub async fn load(server: &str) -> Result<Option<Credential>, KeyringError> {
    load_of(product::current(), server).await
}

/// The credential `product` stored for `server`: Verso reads Immich Mount's to take its account over.
pub async fn load_of(product: &'static Product, server: &str) -> Result<Option<Credential>, KeyringError> {
    let dbus_error = |error: oo7::dbus::Error| classify(oo7::Error::DBus(error));
    let items = existing_items(&attributes_of(product, server)).await?;
    let Some(item) = items.first() else {
        return Ok(None);
    };
    if item.is_locked().await.map_err(dbus_error)? {
        item.unlock(None).await.map_err(dbus_error)?;
    }
    let secret = item.secret().await.map_err(dbus_error)?;
    let text = String::from_utf8_lossy(secret.as_bytes());
    parse_credential(&text).map(Some).ok_or_else(|| KeyringError::Failed("the stored credential cannot be read".to_owned()))
}

/// Remove every credential Verso stored, for any server. Nothing stored is not an error, and no keyring is
/// created or unlocked unless there is something to remove.
pub async fn remove_all() -> Result<(), KeyringError> {
    for item in existing_items(&[("application", product::current().id)]).await? {
        item.delete(None).await.map_err(|error| classify(oo7::Error::DBus(error)))?;
    }
    Ok(())
}

/// Remove the credential stored for `server`. Nothing stored is not an error.
pub async fn remove(server: &str) -> Result<(), KeyringError> {
    for item in existing_items(&attributes(server)).await? {
        item.delete(None).await.map_err(|error| classify(oo7::Error::DBus(error)))?;
    }
    Ok(())
}

/// Whether a credential is stored for `server`. Looks without unlocking or creating anything, so it never brings up
/// a prompt.
pub async fn is_stored(server: &str) -> bool {
    is_stored_by(product::current(), server).await
}

/// Whether `product` has a credential stored for `server`, looked for as [`is_stored`] does.
pub async fn is_stored_by(product: &'static Product, server: &str) -> bool {
    existing_items(&attributes_of(product, server)).await.is_ok_and(|items| !items.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn service_error(error: zbus::fdo::Error) -> oo7::Error {
        oo7::Error::DBus(oo7::dbus::Error::Service(oo7::dbus::ServiceError::ZBus(zbus::Error::FDO(Box::new(error)))))
    }

    #[test]
    fn a_bus_without_a_keyring_is_no_keyring() {
        let unknown = service_error(zbus::fdo::Error::ServiceUnknown("org.freedesktop.secrets".to_owned()));
        assert!(matches!(classify(unknown), KeyringError::Unavailable(_)));
        let unowned = service_error(zbus::fdo::Error::NameHasNoOwner("org.freedesktop.secrets".to_owned()));
        assert!(matches!(classify(unowned), KeyringError::Unavailable(_)));
    }

    #[test]
    fn a_keyring_that_answers_with_an_error_has_failed() {
        let refused = service_error(zbus::fdo::Error::AccessDenied("not allowed".to_owned()));
        assert!(matches!(classify(refused), KeyringError::Failed(_)));
    }
}

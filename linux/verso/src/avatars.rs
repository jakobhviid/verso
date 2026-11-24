//! Accounts as round avatars, with their profile picture where they have one: the people an album or a link is shared
//! with, which round sets apart from a person in the photos, whose face is a rounded square as albums and places are.
//! Each account's picture is read once and kept for every avatar of it.

use std::cell::RefCell;
use std::collections::HashMap;

use adw::prelude::*;
use gtk::{gdk, glib};
use immich_api::{Client, User};

thread_local! {
    /// Pictures read, by account; `None` for an account without one, or one that could not be read.
    static PICTURES: RefCell<HashMap<String, Option<gdk::Texture>>> = RefCell::default();
    /// Avatars waiting for a picture being read, by account.
    static WAITING: RefCell<HashMap<String, Vec<glib::WeakRef<adw::Avatar>>>> = RefCell::default();
}

/// The name an account goes by: its name, else its email.
pub fn name(user: &User) -> String {
    if user.name.is_empty() { user.email.clone() } else { user.name.clone() }
}

/// An account's avatar, `size` pixels round: its initials until its picture is read, its name on hover.
pub fn avatar(client: &Client, user: &User, size: i32) -> adw::Avatar {
    let name = name(user);
    let avatar = adw::Avatar::builder().size(size).text(&name).show_initials(true).tooltip_text(&name).build();
    if !user.profile_image_path.is_empty() {
        picture(client, &user.id, &avatar);
    }
    avatar
}

fn picture(client: &Client, id: &str, avatar: &adw::Avatar) {
    if let Some(known) = PICTURES.with(|pictures| pictures.borrow().get(id).cloned()) {
        if let Some(texture) = known {
            avatar.set_custom_image(Some(&texture));
        }
        return;
    }
    let first = WAITING.with(|waiting| {
        let mut waiting = waiting.borrow_mut();
        let list = waiting.entry(id.to_owned()).or_default();
        list.push(avatar.downgrade());
        list.len() == 1
    });
    if !first {
        return;
    }
    let (client, id) = (client.clone(), id.to_owned());
    let read = id.clone();
    crate::tasks::run(async move { client.profile_image(&read).await.ok().map(|media| media.bytes.to_vec()) }, move |bytes| {
        let texture = bytes.and_then(|bytes| gdk::Texture::from_bytes(&glib::Bytes::from_owned(bytes)).ok());
        PICTURES.with(|pictures| pictures.borrow_mut().insert(id.clone(), texture.clone()));
        let waiting = WAITING.with(|waiting| waiting.borrow_mut().remove(&id)).unwrap_or_default();
        if let Some(texture) = texture {
            for avatar in waiting.iter().filter_map(glib::WeakRef::upgrade) {
                avatar.set_custom_image(Some(&texture));
            }
        }
    });
}

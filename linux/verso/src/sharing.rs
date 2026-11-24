//! Sharing an album, in one place, the Share dialog: the people on the server it is shared with and what each may do,
//! and its links, which anyone with the address opens, with its password where it has one. How far an album reaches
//! ([`Audience`], the core's, `verso_core::sharing`, as on the Mac and the iPhone) shows as one icon wherever it shows:
//! its page, its card, a link's card. Only the album's owner changes who it is shared with; anyone changes the links
//! they made.

use std::cell::RefCell;
use std::rc::Rc;

use adw::prelude::*;
use chrono::Utc;
use gtk::{gio, glib};
use immich_api::{Album, AlbumRole, NewMember, SharedLink, User};
use verso_desktop::shared_links;
use verso_linux::i18n::tr;

use crate::window::Window;

const ROLES: [(AlbumRole, &str); 2] = [(AlbumRole::Viewer, "Can View"), (AlbumRole::Editor, "Can Edit")];

pub use verso_core::sharing::Audience;

/// How an [`Audience`] shows in the window: its icon, its name and what it means.
pub trait AudienceLook {
    /// Its icon, the same wherever it shows.
    fn icon(self) -> &'static str;
    /// Its name beside the icon, for an album shared with `others` people besides its owner.
    fn label(self, others: usize) -> String;
    /// Who can see it, in a sentence.
    fn meaning(self) -> &'static str;
}

impl AudienceLook for Audience {
    fn icon(self) -> &'static str {
        match self {
            Audience::Private => "verso-private-symbolic",
            Audience::People => "verso-people-symbolic",
            Audience::Password => "verso-globe-lock-symbolic",
            Audience::Public => "verso-globe-symbolic",
        }
    }

    fn label(self, others: usize) -> String {
        match self {
            Audience::Private => tr("Private").to_owned(),
            Audience::People if others == 1 => tr("Shared with 1 person").to_owned(),
            Audience::People => tr("Shared with {count} people").replace("{count}", &others.to_string()),
            Audience::Password => tr("Shared with a password").to_owned(),
            Audience::Public => tr("Shared publicly").to_owned(),
        }
    }

    fn meaning(self) -> &'static str {
        match self {
            Audience::Private => tr("Only you can see it"),
            Audience::People => tr("The people it is shared with can see it"),
            Audience::Password => tr("Anyone with the link and its password can see it"),
            Audience::Public => tr("Anyone with the link can see it"),
        }
    }
}

/// The Share dialog's pages.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SharePage {
    People,
    Links,
}

impl SharePage {
    fn name(self) -> &'static str {
        match self {
            SharePage::People => "people",
            SharePage::Links => "links",
        }
    }
}

/// The Share dialog for an album, open on `page`: read fresh, and read again after each change, which `changed`
/// hears too (the album's page shows its new reach).
pub fn share_album(window: &Window, album_id: &str, page: SharePage, changed: Option<Rc<dyn Fn()>>) {
    let dialog = adw::PreferencesDialog::builder().title(tr("Share Album")).build();
    let people = adw::PreferencesPage::builder().name(SharePage::People.name()).title(tr("People")).icon_name(Audience::People.icon()).build();
    let links = adw::PreferencesPage::builder().name(SharePage::Links.name()).title(tr("Links")).icon_name(Audience::Public.icon()).build();
    dialog.add(&people);
    dialog.add(&links);
    dialog.set_visible_page_name(page.name());
    let share = Rc::new(Share { window: window.downgrade(), dialog: dialog.clone(), people, links, shown: RefCell::default(), album_id: album_id.to_owned(), changed });
    // The dialog keeps the share while it is open, and lets it go as it closes.
    let held = RefCell::new(Some(share.clone()));
    dialog.connect_closed(move |_| {
        held.borrow_mut().take();
    });
    share.read(true);
}

struct Share {
    window: glib::WeakRef<Window>,
    dialog: adw::PreferencesDialog,
    people: adw::PreferencesPage,
    links: adw::PreferencesPage,
    /// The groups shown, replaced where they stand after a change, so the dialog stays put.
    shown: RefCell<Vec<(adw::PreferencesPage, adw::PreferencesGroup)>>,
    album_id: String,
    changed: Option<Rc<dyn Fn()>>,
}

impl Share {
    /// Read the album, the server's people and the album's links into the dialog: the first time it opens with them.
    fn read(self: &Rc<Self>, first: bool) {
        let Some(window) = self.window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        let (client, id, weak) = (session.connection.client.clone(), self.album_id.clone(), Rc::downgrade(self));
        crate::tasks::run(
            async move {
                let album = client.album(&id).await.map_err(|error| verso_desktop::errors::said(&error))?;
                let users = client.users().await.unwrap_or_default();
                let links = client.shared_links(Some(&id)).await.unwrap_or_default();
                Ok::<_, String>((album, users, links))
            },
            move |outcome| {
                let Some(share) = weak.upgrade() else { return };
                let Some(window) = share.window.upgrade() else { return };
                match outcome {
                    Ok((album, users, links)) => {
                        share.fill(&window, album, users, links);
                        if first {
                            share.dialog.present(Some(&window));
                        }
                    }
                    Err(message) => window.toast(&message),
                }
            },
        );
    }

    /// After a change: read again, and tell whoever shows the album.
    fn again(self: &Rc<Self>) -> Rc<dyn Fn()> {
        let weak = Rc::downgrade(self);
        Rc::new(move || {
            if let Some(share) = weak.upgrade() {
                share.read(false);
                if let Some(changed) = &share.changed {
                    changed();
                }
            }
        })
    }

    fn show(&self, page: &adw::PreferencesPage, group: adw::PreferencesGroup) {
        page.add(&group);
        self.shown.borrow_mut().push((page.clone(), group));
    }

    fn fill(self: &Rc<Self>, window: &Window, album: Album, users: Vec<User>, links: Vec<SharedLink>) {
        for (page, group) in self.shown.borrow_mut().drain(..) {
            page.remove(&group);
        }
        let me = window.session().and_then(|session| session.connection.user_id().map(str::to_owned));
        let owner = album.owner().map(|owner| owner.id.clone());
        let mine = owner.is_some() && owner == me;
        let others = album.members.iter().filter(|member| member.role != AlbumRole::Owner).count();
        self.dialog.set_title(&tr("Share “{name}”").replace("{name}", &album.name));
        let refresh = self.again();
        self.fill_people(window, &album, users, mine, &me, &refresh, others);
        self.fill_links(window, &album, &links, mine, &me, &refresh);
    }

    /// The People page: who it is shared with and what each may do; adding people, for its owner. Headed by how far
    /// its people take it (its links are the other page's).
    #[allow(clippy::too_many_arguments)]
    fn fill_people(&self, window: &Window, album: &Album, users: Vec<User>, mine: bool, me: &Option<String>, refresh: &Rc<dyn Fn()>, others: usize) {
        let reach = if others > 0 { Audience::People } else { Audience::Private };
        let heading = if others > 0 { reach.label(others) } else { tr("Not Shared With People").to_owned() };
        let members = adw::PreferencesGroup::builder()
            .title(glib::markup_escape_text(&heading))
            .description(if mine { tr("People on this server who see the album. Editors also add and remove photos.") } else { tr("Only the album's owner changes who it is shared with.") })
            .build();
        members.set_header_suffix(Some(&gtk::Image::from_icon_name(reach.icon())));
        for member in &album.members {
            let row = adw::ActionRow::builder().title(glib::markup_escape_text(&member.user.name)).subtitle(glib::markup_escape_text(&member.user.email)).build();
                if let Some(session) = window.session() {
                    row.add_prefix(&crate::avatars::avatar(&session.connection.client, &member.user, 32));
                }
            if member.role == AlbumRole::Owner {
                row.add_suffix(&gtk::Label::builder().label(tr("Owner")).css_classes(["dim-label"]).build());
            } else if mine {
                let roles = gtk::DropDown::from_strings(&ROLES.iter().map(|(_, label)| tr(label)).collect::<Vec<_>>());
                roles.set_valign(gtk::Align::Center);
                roles.set_selected(ROLES.iter().position(|(role, _)| *role == member.role).unwrap_or(0) as u32);
                // The role the server has: a change it refuses puts the menu back to it.
                let saved = Rc::new(std::cell::Cell::new(roles.selected()));
                let (weak_window, album_id, user_id) = (window.downgrade(), album.id.clone(), member.user.id.clone());
                roles.connect_selected_notify(move |roles| {
                    let chosen = roles.selected();
                    if chosen == saved.get() {
                        return;
                    }
                    let Some(window) = weak_window.upgrade() else { return };
                    let Some(session) = window.session() else { return };
                    let role = ROLES[chosen as usize % ROLES.len()].0.clone();
                    let (client, album_id, user_id, shown, saved, weak_roles) = (session.connection.client.clone(), album_id.clone(), user_id.clone(), window.clone(), saved.clone(), roles.downgrade());
                    crate::tasks::run(async move { client.update_album_member(&album_id, &user_id, &role).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                        Ok(()) => saved.set(chosen),
                        Err(message) => {
                            if let Some(roles) = weak_roles.upgrade() {
                                roles.set_selected(saved.get());
                            }
                            shown.toast(&message);
                        }
                    });
                });
                let remove = gtk::Button::builder().icon_name("user-trash-symbolic").tooltip_text(tr("Stop Sharing With Them")).valign(gtk::Align::Center).css_classes(["flat"]).build();
                let (weak_window, album_id, user_id, name, again) = (window.downgrade(), album.id.clone(), member.user.id.clone(), member.user.name.clone(), refresh.clone());
                remove.connect_clicked(move |button| {
                    let (weak_window, album_id, user_id, again) = (weak_window.clone(), album_id.clone(), user_id.clone(), again.clone());
                    let heading = tr("Stop Sharing With {name}?").replace("{name}", &name);
                    crate::dialogs::confirm(button, &heading, tr("They no longer see the album or its photos."), tr("Stop Sharing"), true, move || {
                        let Some(window) = weak_window.upgrade() else { return };
                        let Some(session) = window.session() else { return };
                        let (client, album_id, user_id, shown, again) = (session.connection.client.clone(), album_id.clone(), user_id.clone(), window.clone(), again.clone());
                        crate::tasks::run(async move { client.remove_album_member(&album_id, &user_id).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                            Ok(()) => again(),
                            Err(message) => shown.toast(&message),
                        });
                    });
                });
                row.add_suffix(&roles);
                row.add_suffix(&remove);
            } else {
                let role = ROLES.iter().find(|(role, _)| *role == member.role).map_or("", |(_, label)| tr(label));
                row.add_suffix(&gtk::Label::builder().label(role).css_classes(["dim-label"]).build());
            }
            members.add(&row);
        }
        self.show(&self.people, members);
        if mine {
            let others: Vec<User> = users.into_iter().filter(|user| Some(&user.id) != me.as_ref() && !album.members.iter().any(|member| member.user.id == user.id)).collect();
            let add = adw::PreferencesGroup::builder().title(tr("Add People")).build();
            if others.is_empty() {
                add.set_description(Some(tr("Everyone on this server already sees it.")));
            }
            for user in others {
                let row = adw::ActionRow::builder().title(glib::markup_escape_text(&user.name)).subtitle(glib::markup_escape_text(&user.email)).build();
                let button = gtk::Button::builder().label(tr("Add")).valign(gtk::Align::Center).build();
                let (weak_window, album_id, user_id, again) = (window.downgrade(), album.id.clone(), user.id.clone(), refresh.clone());
                button.connect_clicked(move |_| {
                    let Some(window) = weak_window.upgrade() else { return };
                    let Some(session) = window.session() else { return };
                    let member = NewMember { user_id: user_id.clone(), role: AlbumRole::Viewer };
                    let (client, album_id, shown, again) = (session.connection.client.clone(), album_id.clone(), window.clone(), again.clone());
                    crate::tasks::run(async move { client.add_album_members(&album_id, &[member]).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                        Ok(_) => again(),
                        Err(message) => shown.toast(&message),
                    });
                });
                row.add_suffix(&button);
                add.add(&row);
            }
            self.show(&self.people, add);
        }
    }

    /// The Links page: each link still made for the album, with Copy Link, Open Link, and Edit and Delete for whoever
    /// made it; Create Link for its owner.
    fn fill_links(&self, window: &Window, album: &Album, links: &[SharedLink], mine: bool, me: &Option<String>, refresh: &Rc<dyn Fn()>) {
        let group = adw::PreferencesGroup::builder()
            .title(tr("Links"))
            .description(if links.is_empty() { tr("Not shared by link. A link lets anyone with it see the album, and only with its password where it has one.") } else { tr("Anyone with a link sees the album, and only with its password where it has one.") })
            .build();
        if mine {
            let create = gtk::Button::builder().child(&adw::ButtonContent::builder().icon_name("list-add-symbolic").label(tr("Create Link…")).build()).valign(gtk::Align::Center).css_classes(["flat"]).build();
            let (weak_window, id, again) = (window.downgrade(), album.id.clone(), refresh.clone());
            create.connect_clicked(move |_| {
                if let Some(window) = weak_window.upgrade() {
                    crate::links_page::link_editor(&window, crate::links_page::LinkTarget::Album(id.clone()), Some(again.clone()));
                }
            });
            group.set_header_suffix(Some(&create));
        }
        let Some(session) = window.session() else { return };
        let now = Utc::now();
        for link in links {
            let address = shared_links::address(&session.connection.server, link);
            let reach = Audience::of_working_link(link, now);
            let mut facts = vec![crate::links_page::expiry(link)];
            if link.password.is_some() {
                facts.push(tr("Needs its password").to_owned());
            }
            let row = adw::ActionRow::builder().title(glib::markup_escape_text(&shared_links::title(link))).subtitle(glib::markup_escape_text(&facts.join(" · "))).tooltip_text(&address).build();
            let icon = gtk::Image::from_icon_name(reach.unwrap_or(Audience::Public).icon());
            if reach.is_none() {
                row.add_css_class("dim-label");
            }
            row.add_prefix(&icon);
            let button = |icon: &str, meaning: &str| gtk::Button::builder().icon_name(icon).tooltip_text(meaning).valign(gtk::Align::Center).css_classes(["flat"]).build();
            let copy = button("edit-copy-symbolic", tr("Copy Link"));
            let (weak_window, copied) = (window.downgrade(), address.clone());
            copy.connect_clicked(move |_| {
                if let Some(window) = weak_window.upgrade() {
                    window.clipboard().set_text(&copied);
                    window.toast(tr("Link copied"));
                }
            });
            row.add_suffix(&copy);
            let open = button("adw-external-link-symbolic", tr("Open Link"));
            let (weak_window, opened) = (window.downgrade(), address.clone());
            open.connect_clicked(move |_| {
                if let Some(window) = weak_window.upgrade() {
                    gtk::UriLauncher::new(&opened).launch(Some(&window), gio::Cancellable::NONE, |_| {});
                }
            });
            row.add_suffix(&open);
            if Some(&link.user_id) == me.as_ref() {
                let edit = button("document-edit-symbolic", tr("Edit Link…"));
                let (weak_window, edited, again) = (window.downgrade(), link.clone(), refresh.clone());
                edit.connect_clicked(move |_| {
                    if let Some(window) = weak_window.upgrade() {
                        crate::links_page::link_editor(&window, crate::links_page::LinkTarget::Existing(Box::new(edited.clone())), Some(again.clone()));
                    }
                });
                row.add_suffix(&edit);
                let delete = button("user-trash-symbolic", tr("Delete Link…"));
                let (weak_window, id, again) = (window.downgrade(), link.id.clone(), refresh.clone());
                delete.connect_clicked(move |button| {
                    let (weak_window, id, again) = (weak_window.clone(), id.clone(), again.clone());
                    crate::dialogs::confirm(button, tr("Delete the Link?"), tr("Anyone with this link loses access. The photos stay in your library."), tr("Delete Link"), true, move || {
                        let Some(window) = weak_window.upgrade() else { return };
                        let Some(session) = window.session() else { return };
                        let (client, id, shown, again) = (session.connection.client.clone(), id.clone(), window.clone(), again.clone());
                        crate::tasks::run(async move { client.delete_shared_link(&id).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                            Ok(()) => again(),
                            Err(message) => shown.toast(&message),
                        });
                    });
                });
                row.add_suffix(&delete);
            }
            group.add(&row);
        }
        self.show(&self.links, group);
    }
}

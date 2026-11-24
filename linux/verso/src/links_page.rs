//! Shared Links, as the Mac gallery has them: the links as cards (`cards`), each with some of what it shares, who may
//! see it and until when, and its buttons along the foot (Copy Link, Open Link, Edit, Delete; an album's photos open
//! the album, a link's chosen photos open the link's own page, as an album's would); View Options (All, Album or
//! Individual links, Hide Expired) and Share Album. The link editor makes and changes links, from here, the Share
//! dialog and a photo's menu: description, custom URL, password, expiry, and what visitors may do.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use adw::prelude::*;
use chrono::{Datelike, Local, NaiveDate, TimeZone, Utc};
use gtk::{gio, glib};
use immich_api::{AssetQuery, NewSharedLink, Secret, SharedLink, SharedLinkChanges, SharedLinkKind};
use verso_core::shared_links::{is_expired, Arrangement, Filter};
use verso_desktop::library::{Source, Tile};
use verso_desktop::shared_links;
use verso_desktop::{settings, text};
use verso_linux::i18n::tr;

use crate::cards::{and_list, chip, fill, say, Card, Shown};
use crate::grid::WeakGrid;
use crate::pages::{self, Kind, Spec};
use crate::sharing::Audience;
use crate::utility_pages::{string_action, RowsPage};
use crate::window::{Session, Window};

/// What the link editor makes or changes.
pub enum LinkTarget {
    Album(String),
    Assets(Vec<String>),
    Existing(Box<SharedLink>),
}

pub fn shared_links_page(window: &Window) -> adw::NavigationPage {
    let rows = RowsPage::new(tr("Shared Links"), tr("No Shared Links"), "verso-share-symbolic");
    rows.page.add_css_class("verso-card-page");
    // The links as cards, two or three side by side as the window allows.
    let flow = crate::cards::flow();
    flow.set_margin_top(18);
    flow.set_margin_bottom(18);
    flow.set_margin_start(18);
    flow.set_margin_end(18);
    let cards = gtk::ScrolledWindow::builder().child(&flow).hscrollbar_policy(gtk::PolicyType::Never).vexpand(true).build();
    rows.stack.add_named(&cards, Some("cards"));
    rows.empty.set_description(Some(tr("No public links. Select photos or choose an album to make one.")));
    let show_all = gtk::Button::builder().label(tr("Show All Links")).halign(gtk::Align::Center).css_classes(["pill"]).build();
    let filtered = adw::StatusPage::builder().title(tr("No Matching Links")).description(tr("No links match the View Options.")).icon_name("funnel-symbolic").child(&show_all).build();
    rows.stack.add_named(&filtered, Some("filtered"));
    rows.header.pack_start(&gtk::Button::builder().icon_name("list-add-symbolic").tooltip_text(tr("Share Album…")).action_name("links.share-album").build());
    rows.header.pack_start(&crate::cards::zoom_buttons());
    let options = gio::Menu::new();
    let show = gio::Menu::new();
    for filter in Filter::ALL {
        let label = match filter {
            Filter::All => tr("All Links"),
            Filter::Album => tr("Album Links"),
            Filter::Individual => tr("Individual Shares"),
        };
        show.append(Some(label), Some(&format!("links.show::{}", filter.code())));
    }
    options.append_section(Some(tr("Show")), &show);
    let expired = gio::Menu::new();
    expired.append(Some(tr("Hide Expired Links")), Some("links.hide-expired"));
    options.append_section(None, &expired);
    let options_button = gtk::MenuButton::builder().icon_name("view-sort-descending-symbolic").tooltip_text(tr("View Options")).menu_model(&options).build();
    rows.header.pack_end(&options_button);
    rows.header.pack_end(&gtk::Button::builder().icon_name("view-refresh-symbolic").tooltip_text(tr("Refresh")).action_name("links.refresh").build());
    let links: Rc<RefCell<Vec<SharedLink>>> = Rc::default();
    let render: Rc<dyn Fn()> = {
        let (weak_window, rows, links, options_button, flow) = (window.downgrade(), rows.clone(), links.clone(), options_button.downgrade(), flow.clone());
        Rc::new(move || {
            let Some(window) = weak_window.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let arrangement = shared_links::load(settings::shared());
            if let Some(button) = options_button.upgrade() {
                if arrangement.is_filtered() { button.add_css_class("accent") } else { button.remove_css_class("accent") }
            }
            flow.remove_all();
            let links = links.borrow();
            let shown = arrangement.links(&links, Utc::now());
            rows.show(match (links.is_empty(), shown.is_empty()) {
                (true, _) => "empty",
                (false, true) => "filtered",
                _ => "cards",
            });
            for link in shown {
                let child = gtk::FlowBoxChild::builder().child(&link_card(&window, &session, link)).focusable(false).build();
                flow.append(&child);
            }
        })
    };
    let load: Rc<dyn Fn()> = {
        let (weak_window, rows, links, render) = (window.downgrade(), rows.clone(), links.clone(), render.clone());
        Rc::new(move || {
            let Some(window) = weak_window.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let (client, rows, links, render, shown) = (session.connection.client.clone(), rows.clone(), links.clone(), render.clone(), window.clone());
            crate::tasks::run(async move { client.shared_links(None).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                Ok(found) => {
                    links.replace(found);
                    render();
                }
                Err(message) => {
                    rows.show("empty");
                    shown.toast(&message);
                }
            });
        })
    };
    let actions = gio::SimpleActionGroup::new();
    let arrangement = shared_links::load(settings::shared());
    let show_action = gio::SimpleAction::new_stateful("show", Some(glib::VariantTy::STRING), &arrangement.filter.code().to_variant());
    let again = render.clone();
    show_action.connect_change_state(move |action, value| {
        let Some(filter) = value.and_then(|value| value.get::<String>()).and_then(|code| Filter::from_code(&code)) else { return };
        action.set_state(&filter.code().to_variant());
        let mut chosen = shared_links::load(settings::shared());
        chosen.filter = filter;
        shared_links::save(&chosen, settings::shared());
        again();
    });
    actions.add_action(&show_action);
    let hide_expired = gio::SimpleAction::new_stateful("hide-expired", None, &arrangement.hide_expired.to_variant());
    let again = render.clone();
    hide_expired.connect_change_state(move |action, value| {
        let Some(hide) = value.and_then(|value| value.get::<bool>()) else { return };
        action.set_state(&hide.to_variant());
        let mut chosen = shared_links::load(settings::shared());
        chosen.hide_expired = hide;
        shared_links::save(&chosen, settings::shared());
        again();
    });
    actions.add_action(&hide_expired);
    let (shown_action, expired_action, again) = (show_action.downgrade(), hide_expired.downgrade(), render.clone());
    show_all.connect_clicked(move |_| {
        shared_links::save(&Arrangement::default(), settings::shared());
        if let Some(action) = shown_action.upgrade() {
            action.set_state(&Filter::All.code().to_variant());
        }
        if let Some(action) = expired_action.upgrade() {
            action.set_state(&false.to_variant());
        }
        again();
    });
    let refresh = gio::SimpleAction::new("refresh", None);
    let again = load.clone();
    refresh.connect_activate(move |_, _| again());
    actions.add_action(&refresh);
    let share_album = gio::SimpleAction::new("share-album", None);
    let (weak_window, again) = (window.downgrade(), load.clone());
    share_album.connect_activate(move |_, _| {
        let Some(window) = weak_window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        let me = session.connection.user_id().map(str::to_owned);
        let mut albums: Vec<(String, String)> = window.albums().into_iter().filter(|album| album.owner().map(|owner| &owner.id) == me.as_ref()).map(|album| (album.id, album.name)).collect();
        albums.sort_by_key(|(_, name)| name.to_lowercase());
        if albums.is_empty() {
            return window.toast(tr("You have no albums of your own to share"));
        }
        let (weak, again) = (window.downgrade(), again.clone());
        crate::dialogs::choose_item(&window, tr("Share Album"), tr("Search albums"), albums, move |id, _| {
            if let Some(window) = weak.upgrade() {
                link_editor(&window, LinkTarget::Album(id), Some(again.clone()));
            }
        });
    });
    actions.add_action(&share_album);
    let (weak_window, known) = (window.downgrade(), links.clone());
    actions.add_action(&string_action("copy", move |id| {
        let (Some(window), Some(link)) = (weak_window.upgrade(), known.borrow().iter().find(|link| link.id == id).cloned()) else { return };
        let Some(session) = window.session() else { return };
        window.clipboard().set_text(&shared_links::address(&session.connection.server, &link));
        window.toast(tr("Link copied"));
    }));
    let (weak_window, known) = (window.downgrade(), links.clone());
    actions.add_action(&string_action("open", move |id| {
        let (Some(window), Some(link)) = (weak_window.upgrade(), known.borrow().iter().find(|link| link.id == id).cloned()) else { return };
        let Some(session) = window.session() else { return };
        gtk::UriLauncher::new(&shared_links::address(&session.connection.server, &link)).launch(Some(&window), gio::Cancellable::NONE, |_| {});
    }));
    let (weak_window, known, again) = (window.downgrade(), links.clone(), load.clone());
    actions.add_action(&string_action("edit", move |id| {
        let (Some(window), Some(link)) = (weak_window.upgrade(), known.borrow().iter().find(|link| link.id == id).cloned()) else { return };
        link_editor(&window, LinkTarget::Existing(Box::new(link)), Some(again.clone()));
    }));
    let (weak_window, known, again) = (window.downgrade(), links.clone(), load.clone());
    actions.add_action(&string_action("photos", move |id| {
        let (Some(window), Some(link)) = (weak_window.upgrade(), known.borrow().iter().find(|link| link.id == id).cloned()) else { return };
        window.push_page(&link_page(&window, link, again.clone()));
    }));
    let (weak_window, again) = (window.downgrade(), load.clone());
    actions.add_action(&string_action("delete", move |id| {
        let Some(window) = weak_window.upgrade() else { return };
        let (weak, again) = (window.downgrade(), again.clone());
        crate::dialogs::confirm(&window, tr("Delete the Public Link?"), tr("Anyone with this link loses access. The photos stay in your library."), tr("Delete Link"), true, move || {
            let Some(window) = weak.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let (client, id, shown, again) = (session.connection.client.clone(), id.clone(), window.clone(), again.clone());
            crate::tasks::run(async move { client.delete_shared_link(&id).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                Ok(()) => {
                    again();
                    shown.refresh_albums();
                }
                Err(message) => shown.toast(&message),
            });
        });
    }));
    rows.page.insert_action_group("links", Some(&actions));
    load();
    // Shown again, back from a link's page whose photos or settings may have changed: read the links again, and show
    // them again only if they changed.
    let (weak_window, links_known, render_again, first) = (window.downgrade(), links.clone(), render.clone(), Cell::new(true));
    rows.page.connect_shown(move |_| {
        if first.replace(false) {
            return;
        }
        let Some(session) = weak_window.upgrade().and_then(|window| window.session()) else { return };
        let (client, links, render) = (session.connection.client.clone(), links_known.clone(), render_again.clone());
        crate::tasks::run(async move { client.shared_links(None).await.ok() }, move |found| {
            if let Some(found) = found.filter(|found| *links.borrow() != *found) {
                links.replace(found);
                render();
            }
        });
    });
    rows.page.clone()
}

/// When a link stops working, as a row's subtitle says it.
pub(crate) fn expiry(link: &SharedLink) -> String {
    match link.expires_at {
        Some(_) if is_expired(link, Utc::now()) => tr("Expired").to_owned(),
        Some(expires) => {
            let local = expires.with_timezone(&Local);
            tr("Expires {date} at {time}").replace("{date}", &text::day(local.date_naive())).replace("{time}", &local.format("%H:%M").to_string())
        }
        None => tr("Never Expires").to_owned(),
    }
}

/// A link as a card: some of what it shares, its title and what it is on the photos, its expiry, password and what
/// visitors may do as chips in their corner, whom the album is shared with at their foot, and its buttons below.
fn link_card(window: &Window, session: &Session, link: &SharedLink) -> gtk::Box {
    let card = Card::new(&shared_links::title(link), false);
    let expired = is_expired(link, Utc::now());
    if expired {
        card.root.add_css_class("expired");
    }
    let album = link.album.as_ref();
    // An album's cover, then some of its photos once read; a link's chosen photos.
    let ids: Vec<String> = match album {
        Some(album) => album.thumbnail_asset_id.iter().cloned().collect(),
        None => link.assets.iter().take(3).map(|asset| asset.id.clone()).collect(),
    };
    card.set_photos(&session.textures, &ids.iter().map(|id| Shown::photo(id)).collect::<Vec<_>>());
    if let Some(opener) = &card.photos_button {
        match album {
            Some(album) => {
                opener.set_tooltip_text(Some(tr("Open the Album")));
                let (weak, id, name) = (window.downgrade(), album.id.clone(), album.name.clone());
                opener.connect_clicked(move |_| {
                    if let Some(window) = weak.upgrade() {
                        window.open_album(&id, &name);
                    }
                });
            }
            None => {
                opener.set_tooltip_text(Some(tr("Open the Link's Photos")));
                opener.set_action_name(Some("links.photos"));
                opener.set_action_target_value(Some(&link.id.to_variant()));
            }
        }
    }
    let what = match album {
        Some(album) if album.asset_count > 0 => tr("Album · {items}").replace("{items}", &text::items(album.asset_count)),
        Some(_) => tr("Album").to_owned(),
        None => text::items(link.assets.len() as u64),
    };
    let what = card.line(&what);
    card.line(if link.password.is_some() { tr("Anyone with the link and its password") } else { tr("Anyone with the link") });
    // Until when, as a chip: the days left, or Expired.
    match link.expires_at {
        Some(_) if expired => {
            let chip = chip(Some("preferences-system-time-symbolic"), Some(tr("Expired")), &expiry(link));
            chip.add_css_class("warning");
            card.chip_end(&chip);
        }
        Some(expires) => {
            let days = (expires - Utc::now()).num_days();
            let left = match days {
                0 => tr("Today").to_owned(),
                1 => tr("1 day").to_owned(),
                days => tr("{count} days").replace("{count}", &days.to_string()),
            };
            card.chip_end(&chip(Some("preferences-system-time-symbolic"), Some(&left), &expiry(link)));
        }
        None => {}
    }
    // What visitors may do: a symbol each, the whole sentence on hover.
    let mut may = Vec::new();
    let can = chip(None, None, "");
    for (allowed, icon, word) in [(link.allow_download, "folder-download-symbolic", tr("download")), (link.allow_upload, "list-add-symbolic", tr("add photos")), (link.show_metadata, "view-reveal-symbolic", tr("see the photos' details"))] {
        if allowed {
            can.append(&gtk::Image::from_icon_name(icon));
            may.push(word.to_owned());
        }
    }
    if !may.is_empty() {
        can.set_tooltip_text(Some(&tr("Visitors may {things}").replace("{things}", &and_list(&may))));
        card.chip_end(&can);
    }
    // How far it reaches, in the corner where an album's card shows it: the globe, with a padlock for a password.
    if let Some(reach) = crate::sharing::Audience::of_link(link, Utc::now()) {
        card.chip_end(&chip(Some(reach.icon()), None, reach.meaning()));
    }
    let foot = card.foot();
    let button = |icon: &str, label: &str, action: &str| {
        gtk::Button::builder()
            .child(&adw::ButtonContent::builder().icon_name(icon).label(label).build())
            .action_name(action)
            .action_target(&link.id.to_variant())
            .css_classes(["flat"])
            .build()
    };
    let copy = button("edit-copy-symbolic", tr("Copy Link"), "links.copy");
    copy.set_tooltip_text(Some(&shared_links::address(&session.connection.server, link)));
    foot.append(&copy);
    foot.append(&button("adw-external-link-symbolic", tr("Open Link"), "links.open"));
    foot.append(&button("document-edit-symbolic", tr("Edit"), "links.edit"));
    foot.append(&gtk::Box::builder().hexpand(true).build());
    foot.append(&gtk::Button::builder().icon_name("user-trash-symbolic").tooltip_text(tr("Delete Link…")).action_name("links.delete").action_target(&link.id.to_variant()).css_classes(["flat"]).build());
    complete(session, link, &card, &what, ids);
    card.root.clone()
}

/// Fill in what the list of links leaves out: Immich lists each link with its first photo only, and its album without
/// a count. An album link reads the album (its count and whom it is shared with) and a few of its photos; a link to
/// chosen photos reads itself whole.
fn complete(session: &Session, link: &SharedLink, card: &Card, what: &gtk::Label, shown: Vec<String>) {
    let (client, textures, owner) = (session.connection.client.clone(), session.textures.clone(), link.user_id.clone());
    let (photos, what, people) = (card.photos.downgrade(), what.downgrade(), card.people.downgrade());
    match &link.album {
        Some(album) => {
            let (id, query) = (album.id.clone(), AssetQuery { album_ids: Some(vec![album.id.clone()]), ..AssetQuery::default() });
            let faces = client.clone();
            crate::tasks::run(
                async move { (client.album(&id).await.ok(), client.search_assets(&query, 4, None).await.map(|page| page.assets).unwrap_or_default()) },
                move |(album, found)| {
                    if let (Some(album), Some(what), Some(people)) = (album, what.upgrade(), people.upgrade()) {
                        say(&what, &tr("Album · {items}").replace("{items}", &text::items(album.asset_count)));
                        for member in album.members.iter().filter(|member| member.user.id != owner).take(4) {
                            people.append(&crate::avatars::avatar(&faces, &member.user, 26));
                        }
                    }
                    let mut shown = shown;
                    for asset in found {
                        if shown.len() < 3 && !shown.contains(&asset.id) {
                            shown.push(asset.id);
                        }
                    }
                    if let Some(photos) = photos.upgrade() {
                        fill(&photos, &textures, &shown.iter().map(|id| Shown::photo(id)).collect::<Vec<_>>());
                    }
                },
            );
        }
        None => {
            let id = link.id.clone();
            crate::tasks::run(async move { client.shared_link(&id).await.ok() }, move |whole| {
                let (Some(whole), Some(what), Some(photos)) = (whole, what.upgrade(), photos.upgrade()) else { return };
                say(&what, &text::items(whole.assets.len() as u64));
                fill(&photos, &textures, &whole.assets.iter().take(3).map(|asset| Shown::photo(&asset.id)).collect::<Vec<_>>());
            });
        }
    }
}

/// A link to chosen photos as a page of its own, as an album is: its photos in the grid, to look at, select and take
/// out of it (Remove from Link) or Add Photos to it; above them what it is and how far it reaches, with Copy Link, Open
/// Link and Edit; Delete Link in its menu. `changed` hears each change made here (the Shared Links page reads again).
fn link_page(window: &Window, link: SharedLink, changed: Rc<dyn Fn()>) -> adw::NavigationPage {
    let id = link.id.clone();
    let menu = gio::Menu::new();
    let editing = gio::Menu::new();
    editing.append(Some(tr("Add Photos…")), Some("page.add-photos"));
    editing.append(Some(tr("Edit Link…")), Some("page.edit-link"));
    menu.append_section(None, &editing);
    let using = gio::Menu::new();
    using.append(Some(tr("Copy Link")), Some("page.copy-address"));
    using.append(Some(tr("Open Link")), Some("page.open-address"));
    menu.append_section(None, &using);
    let ending = gio::Menu::new();
    ending.append(Some(tr("Delete Link…")), Some("page.delete-link"));
    menu.append_section(None, &ending);
    // Newest first, as every other page's photos, whatever order they were added to the link in.
    let tiles = |link: &SharedLink| {
        let mut tiles: Vec<Tile> = link.assets.iter().map(Tile::from).collect();
        tiles.sort_by_key(|tile| std::cmp::Reverse(tile.taken));
        Source::Tiles { tiles, by_month: true }
    };
    let mut spec = Spec::new(&shared_links::title(&link), tiles(&link), Kind::Link { id: id.clone() }).empty(tr("No Photos in This Link"), "image-x-generic-symbolic");
    spec.menu = Some(menu);
    spec.empty_child = Some(pages::add_photos_button().upcast());
    let header = Rc::new(LinkHeader::new());
    spec.above = Some(header.root.clone().upcast());
    let known = Rc::new(RefCell::new(link));
    let shown_grid: Rc<RefCell<Option<WeakGrid>>> = Rc::default();
    // The link read again: its photos into the grid (the list of links carries only some of them, on Immich 3.3.5),
    // the rest into the header.
    let reread: Rc<dyn Fn()> = {
        let (weak_window, header, known, shown_grid, id) = (window.downgrade(), header.clone(), known.clone(), shown_grid.clone(), id.clone());
        Rc::new(move || {
            let Some(window) = weak_window.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let (client, header, known, shown_grid, weak_window) = (session.connection.client.clone(), header.clone(), known.clone(), shown_grid.clone(), window.downgrade());
            let id = id.clone();
            crate::tasks::run(async move { client.shared_link(&id).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
                let Some(window) = weak_window.upgrade() else { return };
                match outcome {
                    Ok(link) => {
                        header.fill(&link);
                        if let Some(grid) = shown_grid.borrow().as_ref().and_then(WeakGrid::upgrade) {
                            grid.set_source(tiles(&link));
                        }
                        known.replace(link);
                    }
                    Err(message) => window.toast(&message),
                }
            });
        })
    };
    let action = |name: &str, run: Box<dyn Fn(&Window)>| {
        let action = gio::SimpleAction::new(name, None);
        let weak_window = window.downgrade();
        action.connect_activate(move |_, _| {
            if let Some(window) = weak_window.upgrade() {
                run(&window);
            }
        });
        action
    };
    let (add_known, add_reread, add_changed) = (known.clone(), reread.clone(), changed.clone());
    let add_photos = action(
        "add-photos",
        Box::new(move |window| {
            let (id, reread, changed, weak_window) = (add_known.borrow().id.clone(), add_reread.clone(), add_changed.clone(), window.downgrade());
            crate::photo_picker::pick_photos(window, tr("Add Photos to the Link"), tr("Add"), move |ids| {
                let Some(window) = weak_window.upgrade() else { return };
                let Some(session) = window.session() else { return };
                let (client, id, reread, changed, shown) = (session.connection.client.clone(), id.clone(), reread.clone(), changed.clone(), window.clone());
                let count = ids.len();
                crate::tasks::run(async move { client.add_assets_to_shared_link(&id, &ids).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                    Ok(_) => {
                        shown.toast(&tr("Added {items} to the link").replace("{items}", &text::items(count as u64)));
                        reread();
                        changed();
                    }
                    Err(message) => shown.toast(&message),
                });
            });
        }),
    );
    let (edit_known, edit_reread, edit_changed) = (known.clone(), reread.clone(), changed.clone());
    let edit_link = action(
        "edit-link",
        Box::new(move |window| {
            let (reread, changed) = (edit_reread.clone(), edit_changed.clone());
            let saved: Rc<dyn Fn()> = Rc::new(move || {
                reread();
                changed();
            });
            link_editor(window, LinkTarget::Existing(Box::new(edit_known.borrow().clone())), Some(saved));
        }),
    );
    let copy_known = known.clone();
    let copy_address = action(
        "copy-address",
        Box::new(move |window| {
            let Some(session) = window.session() else { return };
            window.clipboard().set_text(&shared_links::address(&session.connection.server, &copy_known.borrow()));
            window.toast(tr("Link copied"));
        }),
    );
    let open_known = known.clone();
    let open_address = action(
        "open-address",
        Box::new(move |window| {
            let Some(session) = window.session() else { return };
            gtk::UriLauncher::new(&shared_links::address(&session.connection.server, &open_known.borrow())).launch(Some(window), gio::Cancellable::NONE, |_| {});
        }),
    );
    let page_holder: Rc<RefCell<Option<glib::WeakRef<adw::NavigationPage>>>> = Rc::default();
    let (delete_id, delete_changed, delete_page) = (id.clone(), changed.clone(), page_holder.clone());
    let delete_link = action(
        "delete-link",
        Box::new(move |window| {
            let (weak_window, id, changed, page) = (window.downgrade(), delete_id.clone(), delete_changed.clone(), delete_page.clone());
            crate::dialogs::confirm(window, tr("Delete the Link?"), tr("Anyone with this link loses access. The photos stay in your library."), tr("Delete Link"), true, move || {
                let Some(window) = weak_window.upgrade() else { return };
                let Some(session) = window.session() else { return };
                let (client, id, changed, page, shown) = (session.connection.client.clone(), id.clone(), changed.clone(), page.clone(), window.clone());
                crate::tasks::run(async move { client.delete_shared_link(&id).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                    Ok(()) => {
                        changed();
                        // Gone, so its page goes too.
                        if let Some(page) = page.borrow().as_ref().and_then(glib::WeakRef::upgrade) {
                            let _ = page.activate_action("navigation.pop", None);
                        }
                    }
                    Err(message) => shown.toast(&message),
                });
            });
        }),
    );
    spec.actions = vec![add_photos, edit_link, copy_address, open_address, delete_link];
    let (page, grid) = pages::grid_page(window, spec);
    page_holder.replace(Some(page.downgrade()));
    shown_grid.replace(grid.as_ref().map(crate::grid::Grid::downgrade));
    header.fill(&known.borrow());
    reread();
    page
}

/// The header above a link's photos, as an album's: on the left its title and what it is (until when, what visitors
/// may do); on the right its actions in two groups, using it (Copy Link, Open Link) and changing it (Add Photos, Edit),
/// where the eye already is for the link, rather than a + in the top bar; under them how far it reaches, named beside
/// its icon, which opens the link editor too.
struct LinkHeader {
    root: gtk::Box,
    title: gtk::Label,
    facts: gtk::Label,
    reach: gtk::Button,
}

impl LinkHeader {
    fn new() -> LinkHeader {
        let title = gtk::Label::builder().xalign(0.0).wrap(true).css_classes(["title-1"]).build();
        let facts = gtk::Label::builder().xalign(0.0).wrap(true).css_classes(["dim-label"]).build();
        let words = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(4).hexpand(true).build();
        words.append(&title);
        words.append(&facts);
        let button = |icon: &str, label: &str, action: &str| gtk::Button::builder().child(&adw::ButtonContent::builder().icon_name(icon).label(label).build()).action_name(action).css_classes(["flat"]).build();
        let using = gtk::Box::builder().spacing(4).build();
        using.append(&button("edit-copy-symbolic", tr("Copy Link"), "page.copy-address"));
        using.append(&button("adw-external-link-symbolic", tr("Open Link"), "page.open-address"));
        let changing = gtk::Box::builder().spacing(4).build();
        changing.append(&button("verso-add-photos-symbolic", tr("Add Photos"), "page.add-photos"));
        changing.append(&button("document-edit-symbolic", tr("Edit"), "page.edit-link"));
        let buttons = gtk::Box::builder().spacing(18).halign(gtk::Align::End).build();
        buttons.append(&using);
        buttons.append(&changing);
        let reach = gtk::Button::builder().halign(gtk::Align::End).action_name("page.edit-link").css_classes(["flat"]).build();
        let side = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(6).valign(gtk::Align::Center).build();
        side.append(&buttons);
        side.append(&reach);
        let root = gtk::Box::builder().spacing(18).margin_top(12).margin_bottom(6).margin_start(18).margin_end(18).build();
        root.append(&words);
        root.append(&side);
        LinkHeader { root, title, facts, reach }
    }

    fn fill(&self, link: &SharedLink) {
        self.title.set_label(&shared_links::title(link));
        let mut facts = vec![expiry(link)];
        let may: Vec<String> = [(link.allow_download, tr("download")), (link.allow_upload, tr("add photos")), (link.show_metadata, tr("see the photos' details"))]
            .into_iter()
            .filter(|(allowed, _)| *allowed)
            .map(|(_, word)| word.to_owned())
            .collect();
        if !may.is_empty() {
            facts.push(tr("Visitors may {things}").replace("{things}", &and_list(&may)));
        }
        self.facts.set_label(&facts.join(" · "));
        let content = match Audience::of_link(link, Utc::now()) {
            Some(reach) => {
                self.reach.set_tooltip_text(Some(reach.meaning()));
                adw::ButtonContent::builder().icon_name(reach.icon()).label(reach.label(0)).build()
            }
            None => {
                self.reach.set_tooltip_text(Some(tr("No one can open it any more")));
                adw::ButtonContent::builder().icon_name("preferences-system-time-symbolic").label(tr("Expired")).build()
            }
        };
        self.reach.set_child(Some(&content));
    }
}

/// The link editor: Create Public Link for an album or photos, or Edit Public Link. A made link is copied and shown.
pub fn link_editor(window: &Window, target: LinkTarget, saved: Option<Rc<dyn Fn()>>) {
    let existing = match &target {
        LinkTarget::Existing(link) => Some((**link).clone()),
        _ => None,
    };
    let editing = existing.clone().unwrap_or_else(|| SharedLink { allow_download: true, show_metadata: true, ..SharedLink::default() });
    let description = adw::EntryRow::builder().title(tr("Description")).text(editing.description.as_deref().unwrap_or_default()).build();
    let slug = adw::EntryRow::builder().title(tr("Custom URL Slug")).text(editing.slug.as_deref().unwrap_or_default()).build();
    let naming = adw::PreferencesGroup::new();
    naming.add(&description);
    naming.add(&slug);
    // The server only says that a link has a password; its masked value is never sent back.
    let has_password = existing.as_ref().is_some_and(|link| link.password.is_some());
    let keep_password = adw::SwitchRow::builder().title(tr("Keep the Current Password")).active(true).visible(has_password).build();
    let password = adw::PasswordEntryRow::builder().title(tr("Password (Empty for None)")).build();
    if has_password {
        keep_password.bind_property("active", &password, "visible").invert_boolean().sync_create().build();
    }
    let locking = adw::PreferencesGroup::new();
    locking.add(&keep_password);
    locking.add(&password);
    let today = Local::now().date_naive();
    let original_day = editing.expires_at.map(|expires| expires.with_timezone(&Local).date_naive());
    let day = Rc::new(Cell::new(original_day.unwrap_or(today + chrono::Days::new(7))));
    let expires = adw::SwitchRow::builder().title(tr("Expires")).active(original_day.is_some()).build();
    let day_button = gtk::MenuButton::builder().label(text::day(day.get())).valign(gtk::Align::Center).build();
    let calendar = gtk::Calendar::new();
    if let Ok(shown) = glib::DateTime::from_local(day.get().year(), day.get().month() as i32, day.get().day() as i32, 12, 0, 0.0) {
        calendar.select_day(&shown);
    }
    day_button.set_popover(Some(&gtk::Popover::builder().child(&calendar).build()));
    let day_row = adw::ActionRow::builder().title(tr("Last Day")).subtitle(tr("The link works until the end of this day.")).build();
    day_row.add_suffix(&day_button);
    expires.bind_property("active", &day_row, "visible").sync_create().build();
    let timing = adw::PreferencesGroup::new();
    timing.add(&expires);
    timing.add(&day_row);
    let metadata = adw::SwitchRow::builder().title(tr("Show Metadata")).subtitle(tr("Camera details and places")).active(editing.show_metadata).build();
    let download = adw::SwitchRow::builder().title(tr("Allow Download")).active(editing.allow_download && editing.show_metadata).build();
    let upload = adw::SwitchRow::builder().title(tr("Allow Upload")).subtitle(tr("Visitors can upload photos to your account.")).active(editing.allow_upload).build();
    metadata.bind_property("active", &download, "sensitive").sync_create().build();
    let weak_download = download.downgrade();
    metadata.connect_active_notify(move |metadata| {
        if let Some(download) = weak_download.upgrade().filter(|_| !metadata.is_active()) {
            download.set_active(false);
        }
    });
    let visitors = adw::PreferencesGroup::builder().title(tr("Visitors")).build();
    visitors.add(&metadata);
    visitors.add(&download);
    visitors.add(&upload);
    let page = adw::PreferencesPage::new();
    for group in [&naming, &locking, &timing, &visitors] {
        page.add(group);
    }
    let cancel = gtk::Button::builder().label(tr("Cancel")).build();
    let save = gtk::Button::builder().label(if existing.is_some() { tr("Save") } else { tr("Create Link") }).css_classes(["suggested-action"]).build();
    let header = adw::HeaderBar::builder().show_start_title_buttons(false).show_end_title_buttons(false).build();
    header.pack_start(&cancel);
    header.pack_end(&save);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(&page));
    let dialog = adw::Dialog::builder().title(if existing.is_some() { tr("Edit Public Link") } else { tr("Create Public Link") }).content_width(460).content_height(640).child(&toolbar).build();
    // A new last day is today or later; one already set may stay.
    let check: Rc<dyn Fn()> = {
        let (expires, day, save) = (expires.downgrade(), day.clone(), save.downgrade());
        Rc::new(move || {
            let (Some(expires), Some(save)) = (expires.upgrade(), save.upgrade()) else { return };
            save.set_sensitive(!expires.is_active() || day.get() >= today || Some(day.get()) == original_day);
        })
    };
    check();
    let (chosen, weak_button, again) = (day.clone(), day_button.downgrade(), check.clone());
    calendar.connect_day_selected(move |calendar| {
        let picked = calendar.date();
        let Some(date) = NaiveDate::from_ymd_opt(picked.year(), picked.month() as u32, picked.day_of_month() as u32) else { return };
        chosen.set(date);
        if let Some(button) = weak_button.upgrade() {
            button.set_label(&text::day(date));
            button.popdown();
        }
        again();
    });
    let again = check.clone();
    expires.connect_active_notify(move |_| again());
    let weak_dialog = dialog.downgrade();
    cancel.connect_clicked(move |_| {
        if let Some(dialog) = weak_dialog.upgrade() {
            dialog.close();
        }
    });
    let (weak_window, weak_dialog) = (window.downgrade(), dialog.downgrade());
    save.connect_clicked(move |save| {
        let Some(window) = weak_window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        let text_of = |row: &adw::EntryRow| Some(row.text().trim().to_owned()).filter(|text| !text.is_empty());
        let (new_description, new_slug, new_password) = (text_of(&description), text_of(&slug), Some(password.text().to_string()).filter(|text| !text.is_empty()));
        let last_day = expires.is_active().then(|| day.get());
        let new_expiry = match last_day {
            Some(last) if Some(last) == original_day => editing.expires_at,
            Some(last) => last.and_hms_opt(23, 59, 59).and_then(|end| Local.from_local_datetime(&end).earliest()).map(|end| end.with_timezone(&Utc)),
            None => None,
        };
        let (show_metadata, allow_download, allow_upload) = (metadata.is_active(), download.is_active() && metadata.is_active(), upload.is_active());
        let client = session.connection.client.clone();
        let (server, shown, saved, weak_dialog) = (session.connection.server.clone(), window.clone(), saved.clone(), weak_dialog.clone());
        save.set_sensitive(false);
        let weak_save = save.downgrade();
        let finish = move |outcome: Result<(SharedLink, bool), String>| match outcome {
            Ok((link, made)) => {
                if let Some(dialog) = weak_dialog.upgrade() {
                    dialog.close();
                }
                if let Some(saved) = &saved {
                    saved();
                }
                shown.refresh_albums();
                if made {
                    show_made(&shown, &shared_links::address(&server, &link));
                } else {
                    shown.toast(tr("Link saved"));
                }
            }
            Err(message) => {
                if let Some(save) = weak_save.upgrade() {
                    save.set_sensitive(true);
                }
                shown.toast(&message);
            }
        };
        match &target {
            LinkTarget::Existing(link) => {
                let changed = |new: &Option<String>, old: &Option<String>| (new.as_deref().unwrap_or_default() != old.as_deref().unwrap_or_default()).then(|| new.clone());
                let password_change = if has_password && keep_password.is_active() {
                    None
                } else {
                    match new_password {
                        Some(text) => Some(Some(Secret::new(text))),
                        None if has_password => Some(None),
                        None => None,
                    }
                };
                let changes = SharedLinkChanges {
                    description: changed(&new_description, &link.description),
                    password: password_change,
                    slug: changed(&new_slug, &link.slug),
                    expires_at: (new_expiry != link.expires_at).then_some(new_expiry),
                    allow_download: (allow_download != link.allow_download).then_some(allow_download),
                    allow_upload: (allow_upload != link.allow_upload).then_some(allow_upload),
                    show_metadata: (show_metadata != link.show_metadata).then_some(show_metadata),
                };
                let id = link.id.clone();
                crate::tasks::run(async move { client.update_shared_link(&id, &changes).await.map(|link| (link, false)).map_err(|error| verso_desktop::errors::said(&error)) }, finish);
            }
            LinkTarget::Album(_) | LinkTarget::Assets(_) => {
                let base = match &target {
                    LinkTarget::Album(id) => NewSharedLink::to_album(id),
                    LinkTarget::Assets(ids) => NewSharedLink::to_assets(ids),
                    LinkTarget::Existing(_) => unreachable!(),
                };
                let link = NewSharedLink { description: new_description, password: new_password.map(Secret::new), slug: new_slug, expires_at: new_expiry, allow_download, allow_upload, show_metadata, ..base };
                crate::tasks::run(async move { client.create_shared_link(&link).await.map(|link| (link, true)).map_err(|error| verso_desktop::errors::said(&error)) }, finish);
            }
        }
    });
    dialog.present(Some(window));
}

/// A link just made: copied, and shown with a way to open it.
pub fn show_made(window: &Window, address: &str) {
    window.clipboard().set_text(address);
    let dialog = adw::AlertDialog::new(Some(tr("Public Link Made")), Some(&tr("Anyone with this link can open it, and it is copied:\n{address}").replace("{address}", address)));
    dialog.add_responses(&[("close", tr("Close")), ("open", tr("Open Link"))]);
    dialog.set_default_response(Some("close"));
    let (weak, opened) = (window.downgrade(), address.to_owned());
    dialog.connect_response(Some("open"), move |_, _| {
        if let Some(window) = weak.upgrade() {
            gtk::UriLauncher::new(&opened).launch(Some(&window), gio::Cancellable::NONE, |_| {});
        }
    });
    dialog.present(Some(window));
}

/// Add to Public Link: the photos join a link to chosen photos.
pub fn add_to_link(window: &Window, ids: Vec<String>) {
    let Some(session) = window.session() else { return };
    let (client, shown) = (session.connection.client.clone(), window.clone());
    crate::tasks::run(async move { client.shared_links(None).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
        let links = match outcome {
            Ok(links) => links,
            Err(message) => return shown.toast(&message),
        };
        let choices: Vec<(String, String)> = links.iter().filter(|link| link.kind == SharedLinkKind::Individual).map(|link| (link.id.clone(), shared_links::title(link))).collect();
        if choices.is_empty() {
            return shown.toast(tr("No links to chosen photos yet: make one with Create Public Link…"));
        }
        let weak = shown.downgrade();
        crate::dialogs::choose_item(&shown, tr("Add to Public Link"), tr("Search links"), choices, move |id, name| {
            let Some(window) = weak.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let (client, ids, shown) = (session.connection.client.clone(), ids.clone(), window.clone());
            crate::tasks::run(async move { client.add_assets_to_shared_link(&id, &ids).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                Ok(_) => shown.toast(&tr("Added to “{link}”").replace("{link}", &name)),
                Err(message) => shown.toast(&message),
            });
        });
    });
}

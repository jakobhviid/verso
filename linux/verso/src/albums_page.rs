//! The Albums page, as Immich's web app and the Mac gallery have it: all albums, your own or the shared ones (a switch
//! in the header); as cards (`cards`: some of its photos, how many and the years they span, its description over
//! them on hover, whom it is shared with, a globe for a public link) or a list; cards grouped by year or owner, each group
//! folding away; sorted by one of six keys. The choices are remembered (`verso_desktop::albums`).

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use adw::prelude::*;
use gtk::{gio, glib};
use immich_api::{Album, AlbumRole, AssetQuery};
use verso_core::albums::{is_ascending, order_code, Arrangement, Filter, GroupBy, Header, SortBy, View};
use verso_desktop::{albums, settings, text};
use verso_linux::i18n::tr;

use crate::cards::{and_list, Card, Shown};
use crate::sharing::{Audience, AudienceLook, SharePage};
use crate::window::{sort_labels, Session, Window};


struct AlbumsPage {
    window: glib::WeakRef<Window>,
    albums: RefCell<Vec<Album>>,
    arrangement: Cell<Arrangement>,
    stack: gtk::Stack,
    covers: gtk::Box,
    list: gtk::ColumnView,
    options: gtk::MenuButton,
    empty: adw::StatusPage,
    /// Set while the list's own sorting is shown, so it is not taken for a click on a column.
    showing_sort: Cell<bool>,
}

pub fn albums_page(window: &Window) -> adw::NavigationPage {
    let header = adw::HeaderBar::new();
    let new_button = gtk::Button::builder().icon_name("list-add-symbolic").tooltip_text(tr("New Album")).action_name("win.new-album").build();
    header.pack_start(&new_button);
    header.pack_start(&crate::cards::zoom_buttons());
    let filters = adw::ToggleGroup::new();
    for (filter, label) in [(Filter::All, tr("All Albums")), (Filter::Owned, tr("My Albums")), (Filter::Shared, tr("Shared Albums"))] {
        filters.add(adw::Toggle::builder().name(filter.code()).label(label).build());
    }
    header.set_title_widget(Some(&filters));
    let options = gtk::MenuButton::builder().icon_name("view-sort-descending-symbolic").tooltip_text(tr("View Options")).build();
    header.pack_end(&options);

    let covers = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(6).margin_top(12).margin_bottom(18).margin_start(18).margin_end(18).build();
    let list = gtk::ColumnView::builder().single_click_activate(true).show_column_separators(false).css_classes(["data-table"]).build();
    let empty = adw::StatusPage::builder().icon_name("folder-pictures-symbolic").title(tr("No Albums")).build();
    let spinner = adw::Spinner::builder().halign(gtk::Align::Center).valign(gtk::Align::Center).width_request(48).height_request(48).build();
    let stack = gtk::Stack::new();
    stack.add_named(&spinner, Some("loading"));
    stack.add_named(&gtk::ScrolledWindow::builder().child(&covers).hscrollbar_policy(gtk::PolicyType::Never).vexpand(true).build(), Some("covers"));
    stack.add_named(&gtk::ScrolledWindow::builder().child(&list).vexpand(true).build(), Some("list"));
    stack.add_named(&empty, Some("empty"));
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(&stack));
    let page = adw::NavigationPage::builder().title(tr("Albums")).child(&toolbar).css_classes(["verso-card-page"]).build();

    let arrangement = albums::load(settings::shared());
    filters.set_active_name(Some(arrangement.filter.code()));
    let state = Rc::new(AlbumsPage {
        window: window.downgrade(),
        albums: RefCell::default(),
        arrangement: Cell::new(arrangement),
        stack,
        covers,
        list,
        options,
        empty,
        showing_sort: Cell::new(false),
    });
    state.build_columns();
    state.install_actions(&page);

    let weak = Rc::downgrade(&state);
    filters.connect_active_name_notify(move |filters| {
        let (Some(state), Some(name)) = (weak.upgrade(), filters.active_name()) else { return };
        if let Some(filter) = Filter::from_code(&name) {
            state.change(|arrangement| arrangement.filter = filter);
        }
    });
    let weak = Rc::downgrade(&state);
    state.list.connect_activate(move |list, position| {
        let Some(state) = weak.upgrade() else { return };
        let album = list.model().and_then(|model| model.item(position)).and_downcast::<glib::BoxedAnyObject>().map(|object| object.borrow::<Album>().clone());
        if let (Some(window), Some(album)) = (state.window.upgrade(), album) {
            window.open_album(&album.id, &album.name);
        }
    });
    // The page holds its state; it reads the albums when shown.
    let held = state.clone();
    page.connect_destroy(move |_| {
        let _ = &held;
    });

    let Some(session) = window.session() else { return page };
    let client = session.connection.client.clone();
    let weak = Rc::downgrade(&state);
    let read = client.clone();
    crate::tasks::run(async move { read.albums().await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
        let Some(state) = weak.upgrade() else { return };
        match outcome {
            Ok(albums) => {
                state.albums.replace(albums);
                state.render();
            }
            Err(message) => {
                state.stack.set_visible_child_name("empty");
                if let Some(window) = state.window.upgrade() {
                    window.toast(&message);
                }
            }
        }
    });
    // Shown again, back from an album whose name, description or photos may have changed there (or in Immich
    // meanwhile): read them again, and show them again only if they changed, where the page was.
    let (weak, first) = (Rc::downgrade(&state), Cell::new(true));
    page.connect_shown(move |_| {
        if !first.replace(false) {
            if let Some(state) = weak.upgrade() {
                state.reload();
            }
        }
    });
    page
}

impl AlbumsPage {
    /// Change the arrangement, remember it, and show the albums again.
    fn change(self: &Rc<Self>, edit: impl FnOnce(&mut Arrangement)) {
        let mut arrangement = self.arrangement.get();
        edit(&mut arrangement);
        albums::save(&arrangement, settings::shared());
        self.arrangement.set(arrangement);
        self.render();
    }

    fn user_id(&self) -> Option<String> {
        self.window.upgrade().and_then(|window| window.session()).and_then(|session| session.connection.user_id().map(str::to_owned))
    }

    /// Read the albums again, and show them again where the page was if one changed.
    fn reload(self: &Rc<Self>) {
        let Some(session) = self.window.upgrade().and_then(|window| window.session()) else { return };
        let (client, weak) = (session.connection.client.clone(), Rc::downgrade(self));
        crate::tasks::run(async move { client.albums().await.ok() }, move |albums| {
            let (Some(state), Some(albums)) = (weak.upgrade(), albums) else { return };
            if *state.albums.borrow() != albums {
                state.albums.replace(albums);
                state.render_in_place();
            }
        });
    }

    /// [`Self::render`], kept scrolled where it was.
    fn render_in_place(self: &Rc<Self>) {
        let scrolled = self.covers.ancestor(gtk::ScrolledWindow::static_type()).and_downcast::<gtk::ScrolledWindow>();
        let was = scrolled.as_ref().map(|scrolled| scrolled.vadjustment().value());
        self.render();
        // Once the albums are laid out, so the page is as tall as before.
        if let (Some(scrolled), Some(was)) = (scrolled, was) {
            glib::idle_add_local_once(move || scrolled.vadjustment().set_value(was));
        }
    }

    fn render(self: &Rc<Self>) {
        let arrangement = self.arrangement.get();
        self.options.set_menu_model(Some(&options_menu(&arrangement)));
        let groups = albums::groups(&arrangement, &self.albums.borrow(), self.user_id().as_deref());
        if groups.is_empty() {
            let filtered = arrangement.filter != Filter::All && !self.albums.borrow().is_empty();
            self.empty.set_title(if filtered { tr("No Matching Albums") } else { tr("No Albums") });
            let show_all = filtered.then(|| {
                let button = gtk::Button::builder().label(tr("Show All Albums")).halign(gtk::Align::Center).css_classes(["pill"]).build();
                let weak = Rc::downgrade(self);
                button.connect_clicked(move |_| {
                    if let Some(state) = weak.upgrade() {
                        state.change(|arrangement| arrangement.filter = Filter::All);
                    }
                });
                button
            });
            self.empty.set_child(show_all.as_ref());
            self.stack.set_visible_child_name("empty");
            return;
        }
        match arrangement.view {
            View::Covers => {
                self.fill_covers(&arrangement, groups);
                self.stack.set_visible_child_name("covers");
            }
            View::List => {
                let albums: Vec<Album> = groups.into_iter().flat_map(|group| group.albums).collect();
                self.fill_list(&arrangement, albums);
                self.stack.set_visible_child_name("list");
            }
        }
    }

    fn fill_covers(self: &Rc<Self>, arrangement: &Arrangement, groups: Vec<albums::Group>) {
        while let Some(child) = self.covers.first_child() {
            self.covers.remove(&child);
        }
        let Some(window) = self.window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        let group_by = arrangement.effective_group_by();
        let folded = albums::collapsed(group_by, settings::shared());
        for group in groups {
            let flow = crate::cards::flow();
            flow.set_margin_bottom(12);
            for album in &group.albums {
                let card = album_card(&window, &session, album);
                card.set_widget_name(&album.id);
                flow.append(&card);
            }
            let weak = Rc::downgrade(self);
            flow.connect_child_activated(move |_, child| {
                let Some(state) = weak.upgrade() else { return };
                let Some(id) = child.child().map(|card| card.widget_name().to_string()) else { return };
                let album = state.albums.borrow().iter().find(|album| album.id == id).cloned();
                if let (Some(window), Some(album)) = (state.window.upgrade(), album) {
                    window.open_album(&album.id, &album.name);
                }
            });
            if let Some(header) = &group.header {
                let title = match header {
                    Header::Year(year) => year.to_string(),
                    Header::UnknownYear => tr("Unknown Year").to_owned(),
                    Header::Mine => tr("My Albums").to_owned(),
                    Header::Owner(name) => name.clone(),
                };
                let is_folded = folded.is_collapsed(&group.id, group_by);
                let arrow = gtk::Image::from_icon_name(if is_folded { "pan-end-symbolic" } else { "pan-down-symbolic" });
                let label = gtk::Label::builder().label(&title).xalign(0.0).css_classes(["gallery-month"]).build();
                let count = gtk::Label::builder().label(if group.albums.len() == 1 { tr("1 album").to_owned() } else { tr("{count} albums").replace("{count}", &group.albums.len().to_string()) }).css_classes(["dim-label"]).build();
                let content = gtk::Box::builder().spacing(8).build();
                content.append(&arrow);
                content.append(&label);
                content.append(&count);
                let button = gtk::Button::builder().child(&content).css_classes(["flat"]).halign(gtk::Align::Start).build();
                button.update_property(&[gtk::accessible::Property::Label(&title)]);
                flow.set_visible(!is_folded);
                let (weak_flow, id) = (flow.downgrade(), group.id.clone());
                button.connect_clicked(move |_| {
                    let Some(flow) = weak_flow.upgrade() else { return };
                    let folding = flow.is_visible();
                    flow.set_visible(!folding);
                    arrow.set_icon_name(Some(if folding { "pan-end-symbolic" } else { "pan-down-symbolic" }));
                    albums::set_collapsed(group_by, &id, folding, settings::shared());
                });
                self.covers.append(&button);
            }
            self.covers.append(&flow);
        }
    }

    fn build_columns(self: &Rc<Self>) {
        type Cell = fn(&Album) -> String;
        let columns: [(SortBy, &str, Cell, bool); 6] = [
            (SortBy::Title, tr("Title"), |album| album.name.clone(), true),
            (SortBy::ItemCount, tr("Items"), |album| album.asset_count.to_string(), false),
            (SortBy::DateModified, tr("Date Modified"), |album| text::short_day(album.updated_at.date_naive()), false),
            (SortBy::DateCreated, tr("Date Created"), |album| text::short_day(album.created_at.date_naive()), false),
            (SortBy::MostRecentPhoto, tr("Most Recent Photo"), |album| album.end_date.map(|date| text::short_day(date.date_naive())).unwrap_or_default(), false),
            (SortBy::OldestPhoto, tr("Oldest Photo"), |album| album.start_date.map(|date| text::short_day(date.date_naive())).unwrap_or_default(), false),
        ];
        for (key, title, value, expand) in columns {
            let factory = gtk::SignalListItemFactory::new();
            let window = self.window.clone();
            factory.connect_setup(move |_, item| {
                if let Some(item) = item.downcast_ref::<gtk::ListItem>() {
                    let label = gtk::Label::builder().xalign(0.0).ellipsize(gtk::pango::EllipsizeMode::End).build();
                    // Files dropped on an album's row join it, as on its card: each cell is named by the album it shows.
                    if let Some(window) = window.upgrade() {
                        window.take_imports_into_named(&label);
                    }
                    item.set_child(Some(&label));
                }
            });
            factory.connect_bind(move |_, item| {
                let Some(item) = item.downcast_ref::<gtk::ListItem>() else { return };
                let (Some(label), Some(object)) = (item.child().and_downcast::<gtk::Label>(), item.item().and_downcast::<glib::BoxedAnyObject>()) else { return };
                let album = object.borrow::<Album>();
                label.set_label(&value(&album));
                label.set_widget_name(&album.id);
            });
            let column = gtk::ColumnViewColumn::builder().title(title).factory(&factory).expand(expand).resizable(true).build();
            // A sorter only so the heading can be clicked; the albums come sorted already.
            column.set_sorter(Some(&gtk::CustomSorter::new(|_, _| gtk::Ordering::Equal)));
            column.set_id(Some(key.code()));
            self.list.append_column(&column);
        }
        let weak = Rc::downgrade(self);
        if let Some(sorter) = self.list.sorter() {
            sorter.connect_changed(move |sorter, _| {
                let Some(state) = weak.upgrade() else { return };
                if state.showing_sort.get() {
                    return;
                }
                let Some(sorter) = sorter.downcast_ref::<gtk::ColumnViewSorter>() else { return };
                let Some(key) = sorter.primary_sort_column().and_then(|column| column.id()).and_then(|id| SortBy::from_code(&id)) else { return };
                let ascending = sorter.primary_sort_order() == gtk::SortType::Ascending;
                state.change(|arrangement| {
                    arrangement.sort_by = key;
                    arrangement.ascending = ascending;
                });
            });
        }
    }

    fn fill_list(&self, arrangement: &Arrangement, albums: Vec<Album>) {
        let store = gio::ListStore::new::<glib::BoxedAnyObject>();
        for album in albums {
            store.append(&glib::BoxedAnyObject::new(album));
        }
        self.list.set_model(Some(&gtk::NoSelection::new(Some(store))));
        // Show the order chosen on its column's heading.
        self.showing_sort.set(true);
        let columns = self.list.columns();
        let column = (0..columns.n_items()).filter_map(|index| columns.item(index).and_downcast::<gtk::ColumnViewColumn>()).find(|column| column.id().as_deref() == Some(arrangement.sort_by.code()));
        self.list.sort_by_column(column.as_ref(), if arrangement.ascending { gtk::SortType::Ascending } else { gtk::SortType::Descending });
        self.showing_sort.set(false);
    }

    fn install_actions(self: &Rc<Self>, page: &adw::NavigationPage) {
        let group = gio::SimpleActionGroup::new();
        let arrangement = self.arrangement.get();
        let stateful = |name: &str, value: &str| gio::SimpleAction::new_stateful(name, Some(glib::VariantTy::STRING), &value.to_variant());
        let actions = [
            stateful("view", arrangement.view.code()),
            stateful("group-by", arrangement.group_by.code()),
            stateful("group-order", order_code(arrangement.groups_ascending)),
            stateful("sort-by", arrangement.sort_by.code()),
            stateful("sort-order", order_code(arrangement.ascending)),
        ];
        for action in actions {
            let weak = Rc::downgrade(self);
            action.connect_change_state(move |action, value| {
                let (Some(state), Some(value)) = (weak.upgrade(), value) else { return };
                action.set_state(value);
                let chosen = value.get::<String>().unwrap_or_default();
                match action.name().as_str() {
                    "view" => state.change(|arrangement| arrangement.view = View::from_code(&chosen).unwrap_or_default()),
                    "group-by" => state.change(|arrangement| *arrangement = arrangement.grouped_by(GroupBy::from_code(&chosen).unwrap_or_default())),
                    "group-order" => state.change(|arrangement| arrangement.groups_ascending = is_ascending(&chosen)),
                    "sort-by" => state.change(|arrangement| *arrangement = arrangement.sorted_by(SortBy::from_code(&chosen).unwrap_or_default())),
                    _ => state.change(|arrangement| arrangement.ascending = is_ascending(&chosen)),
                }
            });
            group.add_action(&action);
        }
        // An album card's menu (`card_menu`): open it, share it, and its link.
        for name in ["open", "share", "copy-link", "open-link"] {
            let action = gio::SimpleAction::new(name, Some(glib::VariantTy::STRING));
            let weak = Rc::downgrade(self);
            action.connect_activate(move |action, value| {
                let (Some(state), Some(id)) = (weak.upgrade(), value.and_then(|value| value.get::<String>())) else { return };
                let Some(window) = state.window.upgrade() else { return };
                let Some(album) = state.albums.borrow().iter().find(|album| album.id == id).cloned() else { return };
                match action.name().as_str() {
                    "open" => window.open_album(&album.id, &album.name),
                    "share" => {
                        let again = Rc::downgrade(&state);
                        let changed: Rc<dyn Fn()> = Rc::new(move || {
                            if let Some(state) = again.upgrade() {
                                state.reload();
                            }
                        });
                        crate::sharing::share_album(&window, &album.id, SharePage::Links, Some(changed));
                    }
                    name => use_link(&window, &album.id, name == "copy-link"),
                }
            });
            group.add_action(&action);
        }
        for (name, folding) in [("expand-all", false), ("collapse-all", true)] {
            let action = gio::SimpleAction::new(name, None);
            let weak = Rc::downgrade(self);
            action.connect_activate(move |_, _| {
                let Some(state) = weak.upgrade() else { return };
                let arrangement = state.arrangement.get();
                let group_by = arrangement.effective_group_by();
                for group in albums::groups(&arrangement, &state.albums.borrow(), state.user_id().as_deref()) {
                    albums::set_collapsed(group_by, &group.id, folding, settings::shared());
                }
                state.render();
            });
            group.add_action(&action);
        }
        page.insert_action_group("albums", Some(&group));
    }
}

/// The View Options menu; Year grouping is left out while sorting by the albums' own dates, which turns it off.
/// An album as a card: its cover and two more of its photos (read as the card first shows), its name, how many and
/// the years they span on the photos, its description over them on hover; the people it is shared with at the photos' foot,
/// with their pictures; and a globe when it has a public link, its address on hover, copied with a click. Files dropped
/// on it are imported into the album.
fn album_card(window: &Window, session: &Session, album: &Album) -> gtk::Box {
    let card = Card::new(&album.name, true);
    let cover: Vec<String> = album.thumbnail_asset_id.iter().cloned().collect();
    card.set_photos(&session.textures, &cover.iter().map(|id| Shown::photo(id)).collect::<Vec<_>>());
    let span = match (album.start_date, album.end_date) {
        (Some(first), Some(last)) => crate::cards::years(chrono::Datelike::year(&first), chrono::Datelike::year(&last)),
        _ => String::new(),
    };
    card.line(&crate::cards::joined(&[text::items(album.asset_count), span]));
    if !album.description.trim().is_empty() {
        card.note(album.description.trim());
    }
    // Whom it is shared with: its owner first when it is another's, then the others, never yourself.
    let me = session.connection.user_id();
    let mut people: Vec<&immich_api::User> = Vec::new();
    if let Some(owner) = album.owner().filter(|owner| Some(owner.id.as_str()) != me) {
        people.push(owner);
    }
    people.extend(album.members.iter().filter(|member| member.role != AlbumRole::Owner && Some(member.user.id.as_str()) != me).map(|member| &member.user));
    for user in people.iter().take(4) {
        card.person(&crate::avatars::avatar(&session.connection.client, user, 26));
    }
    if people.len() > 4 {
        let more = gtk::Label::builder().label(format!("+{}", people.len() - 4)).css_classes(["verso-card-more"]).tooltip_text(and_list(&people.iter().skip(4).map(|user| crate::avatars::name(user)).collect::<Vec<_>>())).build();
        card.person(&more);
    }
    card_menu(&card.root, album);
    if album.has_shared_link {
        // How far its links reach, once read: the globe, with a padlock when every working link has a password;
        // nothing once they have all expired. The address on hover; a click copies it.
        let globe = crate::cards::chip_button(Audience::Public.icon(), Audience::Public.meaning());
        globe.set_visible(false);
        card.chip_end(&globe);
        let (client, server, id, weak_globe) = (session.connection.client.clone(), session.connection.server.clone(), album.id.clone(), globe.downgrade());
        let address: Rc<RefCell<Option<String>>> = Rc::default();
        let known = address.clone();
        crate::tasks::run(async move { client.shared_links(Some(&id)).await.unwrap_or_default() }, move |links| {
            let now = chrono::Utc::now();
            let working: Vec<_> = links.iter().filter_map(|link| Audience::of_working_link(link, now).map(|reach| (reach, link))).collect();
            let (Some(globe), Some(reach)) = (weak_globe.upgrade(), working.iter().map(|(reach, _)| *reach).max()) else { return };
            let addresses: Vec<String> = working.iter().map(|(_, link)| verso_desktop::shared_links::address(&server, link)).collect();
            globe.set_icon_name(reach.icon());
            globe.set_tooltip_text(Some(&match addresses.as_slice() {
                [one] => tr("{reach}: {address}. Click to copy the link.").replace("{reach}", &reach.label(0)).replace("{address}", one),
                _ => tr("{reach} through {count} links. Click to copy the first.").replace("{reach}", &reach.label(0)).replace("{count}", &addresses.len().to_string()),
            }));
            globe.set_visible(true);
            known.replace(addresses.into_iter().next());
        });
        let weak_window = window.downgrade();
        globe.connect_clicked(move |_| {
            let (Some(window), Some(address)) = (weak_window.upgrade(), address.borrow().clone()) else { return };
            window.clipboard().set_text(&address);
            window.toast(tr("Link copied"));
        });
    }
    // Two more of its photos, once the card shows.
    if album.asset_count > 1 {
        let (client, textures, asked, weak) = (session.connection.client.clone(), session.textures.clone(), Cell::new(false), card.photos.downgrade());
        let query = AssetQuery { album_ids: Some(vec![album.id.clone()]), ..AssetQuery::default() };
        card.root.connect_map(move |_| {
            if asked.replace(true) {
                return;
            }
            let (client, query, textures, weak, cover) = (client.clone(), query.clone(), textures.clone(), weak.clone(), cover.clone());
            crate::tasks::run(async move { client.search_assets(&query, 4, None).await.map(|page| page.assets).unwrap_or_default() }, move |found| {
                let Some(photos) = weak.upgrade() else { return };
                let mut shown = cover;
                for asset in found {
                    if shown.len() < 3 && !shown.contains(&asset.id) {
                        shown.push(asset.id);
                    }
                }
                crate::cards::fill(&photos, &textures, &shown.iter().map(|id| Shown::photo(id)).collect::<Vec<_>>());
            });
        });
    }
    window.take_imports_into(&card.root, &album.id);
    card.root.clone()
}

/// An album card's menu, on a right click: Open, Share…, and Copy Link and Open Link when it has a link.
fn card_menu(card: &gtk::Box, album: &Album) {
    let menu = gio::Menu::new();
    let item = |menu: &gio::Menu, label: &str, action: &str| {
        let entry = gio::MenuItem::new(Some(label), None);
        entry.set_action_and_target_value(Some(&format!("albums.{action}")), Some(&album.id.to_variant()));
        menu.append_item(&entry);
    };
    let opening = gio::Menu::new();
    item(&opening, tr("Open"), "open");
    menu.append_section(None, &opening);
    let sharing = gio::Menu::new();
    item(&sharing, tr("Share…"), "share");
    if album.has_shared_link {
        item(&sharing, tr("Copy Link"), "copy-link");
        item(&sharing, tr("Open Link"), "open-link");
    }
    menu.append_section(None, &sharing);
    let popover = gtk::PopoverMenu::from_model(Some(&menu));
    popover.set_parent(card);
    popover.set_has_arrow(false);
    let click = gtk::GestureClick::builder().button(gtk::gdk::BUTTON_SECONDARY).build();
    let weak = popover.downgrade();
    click.connect_pressed(move |_, _, x, y| {
        if let Some(popover) = weak.upgrade() {
            popover.set_pointing_to(Some(&gtk::gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
            popover.popup();
        }
    });
    card.add_controller(click);
}

/// An album's first link still working: copied, or opened in the browser.
fn use_link(window: &Window, album_id: &str, copy: bool) {
    let Some(session) = window.session() else { return };
    let (client, server, id, shown) = (session.connection.client.clone(), session.connection.server.clone(), album_id.to_owned(), window.clone());
    crate::tasks::run(async move { client.shared_links(Some(&id)).await.unwrap_or_default() }, move |links| {
        let now = chrono::Utc::now();
        let Some(link) = links.iter().find(|link| Audience::of_working_link(link, now).is_some()) else {
            return shown.toast(tr("None of its links works any more"));
        };
        let address = verso_desktop::shared_links::address(&server, link);
        if copy {
            shown.clipboard().set_text(&address);
            shown.toast(tr("Link copied"));
        } else {
            gtk::UriLauncher::new(&address).launch(Some(&shown), gio::Cancellable::NONE, |_| {});
        }
    });
}

fn options_menu(arrangement: &Arrangement) -> gio::Menu {
    let menu = gio::Menu::new();
    let section = |items: &[(&str, &str)], action: &str| {
        let part = gio::Menu::new();
        for (label, target) in items {
            part.append(Some(label), Some(&format!("albums.{action}::{target}")));
        }
        part
    };
    menu.append_section(Some(tr("View")), &section(&[(tr("Covers"), View::Covers.code()), (tr("List"), View::List.code())], "view"));
    if arrangement.view == View::Covers {
        let mut groupings = vec![(tr("No Grouping"), GroupBy::None.code())];
        if arrangement.allows(GroupBy::Year) {
            groupings.push((tr("Year"), GroupBy::Year.code()));
        }
        groupings.push((tr("Owner"), GroupBy::Owner.code()));
        menu.append_section(Some(tr("Group By")), &section(&groupings, "group-by"));
        if arrangement.effective_group_by() != GroupBy::None {
            menu.append_section(Some(tr("Group Order")), &section(&[(tr("Ascending"), "asc"), (tr("Descending"), "desc")], "group-order"));
            let fold = gio::Menu::new();
            fold.append(Some(tr("Expand All Groups")), Some("albums.expand-all"));
            fold.append(Some(tr("Collapse All Groups")), Some("albums.collapse-all"));
            menu.append_section(None, &fold);
        }
    }
    let keys: Vec<(&str, &str)> = sort_labels().iter().map(|(key, label)| (*label, key.code())).collect();
    menu.append_section(Some(tr("Sort By")), &section(&keys, "sort-by"));
    menu.append_section(Some(tr("Album Order")), &section(&[(tr("Ascending"), "asc"), (tr("Descending"), "desc")], "sort-order"));
    menu
}

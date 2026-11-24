//! Find Similar Photos, as the Mac gallery's sheet: look in the photos selected or a period, compare the photos taken
//! close together on this computer (`similar`), and offer each group as a stack with a suggested cover. A click on a
//! photo makes it the cover, × takes it out of the group, and Stack Groups makes the chosen groups stacks in Immich,
//! after asking. Nothing is deleted.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

use adw::prelude::*;
use chrono::{Datelike, Local, NaiveDate};
use gtk::glib;
use immich_api::search::AssetQuery;
use immich_api::AssetKind;
use verso_desktop::images::Kind as ImageKind;
use verso_desktop::similar::{self, Candidate, Features, Sensitivity, CANDIDATE_LIMIT, DEFAULT_GAP, GAPS, MIN_MEMBERS};
use verso_desktop::text;
use verso_linux::i18n::tr;

use crate::collections::SquareFrame;
use crate::window::Window;

/// Photos compared at once.
const BATCH: usize = 12;

#[derive(Clone, PartialEq)]
enum Status {
    Pending,
    Stacked(String),
    Failed(String),
}

#[derive(Clone)]
struct Group {
    members: Vec<Candidate>,
    removed: Vec<Candidate>,
    cover: String,
    suggested: String,
    included: bool,
    status: Status,
}

#[derive(Clone, Copy, PartialEq)]
enum Phase {
    Idle,
    Working,
    Ready,
}

struct Finder {
    window: glib::WeakRef<Window>,
    /// The photos selected when the sheet opened.
    selection: Vec<String>,
    phase: Cell<Phase>,
    /// Bumps with each scan and on Stop or closing, so late answers of an earlier one are dropped.
    generation: Cell<u64>,
    groups: RefCell<Vec<Group>>,
    features: RefCell<HashMap<String, Features>>,
    status: gtk::Label,
    progress: gtk::ProgressBar,
    stop: gtk::Button,
    coverage: gtk::Label,
    results: gtk::Box,
    stack_button: gtk::Button,
    find: gtk::Button,
    look_in: adw::ComboRow,
    period: adw::ComboRow,
    from: Rc<Cell<NaiveDate>>,
    to: Rc<Cell<NaiveDate>>,
    sensitivity: adw::ComboRow,
    gap: adw::ComboRow,
}

/// A day chosen with a calendar.
fn day_row(title: &str, day: NaiveDate) -> (adw::ActionRow, Rc<Cell<NaiveDate>>) {
    let chosen = Rc::new(Cell::new(day));
    let button = gtk::MenuButton::builder().label(text::day(day)).valign(gtk::Align::Center).build();
    let calendar = gtk::Calendar::new();
    if let Ok(shown) = glib::DateTime::from_local(day.year(), day.month() as i32, day.day() as i32, 12, 0, 0.0) {
        calendar.select_day(&shown);
    }
    button.set_popover(Some(&gtk::Popover::builder().child(&calendar).build()));
    let (keep, weak_button) = (chosen.clone(), button.downgrade());
    calendar.connect_day_selected(move |calendar| {
        let picked = calendar.date();
        let Some(date) = NaiveDate::from_ymd_opt(picked.year(), picked.month() as u32, picked.day_of_month() as u32) else { return };
        keep.set(date);
        if let Some(button) = weak_button.upgrade() {
            button.set_label(&text::day(date));
            button.popdown();
        }
    });
    let row = adw::ActionRow::builder().title(title).build();
    row.add_suffix(&button);
    (row, chosen)
}

fn combo(title: &str, items: &[&str], selected: u32) -> adw::ComboRow {
    let row = adw::ComboRow::builder().title(title).model(&gtk::StringList::new(items)).build();
    row.set_selected(selected);
    row
}

/// Open the sheet, with the photos selected on the page that opened it.
pub fn find_similar(window: &Window, selection: Vec<String>) {
    let today = Local::now().date_naive();
    let selected = tr("Selected Photos ({count})").replace("{count}", &selection.len().to_string());
    let look_in = combo(tr("Look In"), &[&selected, tr("Date Range")], if selection.len() >= MIN_MEMBERS { 0 } else { 1 });
    look_in.set_visible(!selection.is_empty());
    let period = combo(tr("Period"), &[tr("Last 30 Days"), tr("Last 3 Months"), tr("Last 12 Months"), tr("Custom Range")], 0);
    let (from_row, from) = day_row(tr("From"), similar::last_days(30, today).0);
    let (to_row, to) = day_row(tr("To"), today);
    let sensitivity = combo(tr("Sensitivity"), &[tr("Strict"), tr("Normal"), tr("Loose")], 1);
    let gap_labels: Vec<String> = GAPS.iter().map(|seconds| tr("{count} seconds").replace("{count}", &seconds.to_string())).collect();
    let gap_names: Vec<&str> = gap_labels.iter().map(String::as_str).collect();
    let gap = combo(tr("Time Between Shots"), &gap_names, GAPS.iter().position(|seconds| *seconds == DEFAULT_GAP).unwrap_or(1) as u32);
    let settings = adw::PreferencesGroup::builder().description(tr("Photos taken within a few seconds of each other are compared on this computer. Nothing changes until you stack the groups you choose.")).build();
    for row in [look_in.upcast_ref::<gtk::Widget>(), period.upcast_ref(), from_row.upcast_ref(), to_row.upcast_ref(), sensitivity.upcast_ref(), gap.upcast_ref()] {
        settings.add(row);
    }
    let find = gtk::Button::builder().label(tr("Find Similar Photos")).halign(gtk::Align::End).css_classes(["suggested-action"]).build();
    settings.set_header_suffix(Some(&find));
    let status = gtk::Label::builder().xalign(0.0).wrap(true).visible(false).build();
    let progress = gtk::ProgressBar::builder().hexpand(true).visible(false).build();
    let stop = gtk::Button::builder().label(tr("Stop")).visible(false).build();
    let working = gtk::Box::builder().spacing(12).build();
    working.append(&progress);
    working.append(&stop);
    let coverage = gtk::Label::builder().xalign(0.0).wrap(true).visible(false).css_classes(["dim-label"]).build();
    let results = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(12).build();
    let content = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(12).margin_top(12).margin_bottom(12).margin_start(18).margin_end(18).build();
    for widget in [settings.upcast_ref::<gtk::Widget>(), status.upcast_ref(), working.upcast_ref(), coverage.upcast_ref(), results.upcast_ref()] {
        content.append(widget);
    }
    let stack_button = gtk::Button::builder().label(tr("Stack Groups…")).sensitive(false).css_classes(["suggested-action"]).build();
    let footer = gtk::Box::builder().spacing(12).margin_top(6).margin_bottom(6).margin_start(18).margin_end(18).build();
    footer.append(&gtk::Label::builder().label(tr("Suggestions can be wrong. Click a photo to make it the cover. Nothing is deleted.")).xalign(0.0).hexpand(true).wrap(true).css_classes(["caption", "dim-label"]).build());
    footer.append(&stack_button);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    toolbar.set_content(Some(&gtk::ScrolledWindow::builder().child(&content).hscrollbar_policy(gtk::PolicyType::Never).vexpand(true).build()));
    toolbar.add_bottom_bar(&footer);
    let dialog = adw::Dialog::builder().title(tr("Find Similar Photos")).content_width(900).content_height(700).child(&toolbar).build();
    let finder = Rc::new(Finder {
        window: window.downgrade(),
        selection,
        phase: Cell::new(Phase::Idle),
        generation: Cell::new(0),
        groups: RefCell::default(),
        features: RefCell::default(),
        status,
        progress,
        stop: stop.clone(),
        coverage,
        results,
        stack_button: stack_button.clone(),
        find: find.clone(),
        look_in: look_in.clone(),
        period: period.clone(),
        from,
        to,
        sensitivity,
        gap,
    });
    // The period's rows follow what is chosen.
    let show_rows = {
        let (look_in, period, from_row, to_row) = (look_in.downgrade(), period.downgrade(), from_row.downgrade(), to_row.downgrade());
        move || {
            let (Some(look_in), Some(period), Some(from_row), Some(to_row)) = (look_in.upgrade(), period.upgrade(), from_row.upgrade(), to_row.upgrade()) else { return };
            let by_date = !look_in.is_visible() || look_in.selected() == 1;
            period.set_visible(by_date);
            from_row.set_visible(by_date && period.selected() == 3);
            to_row.set_visible(by_date && period.selected() == 3);
        }
    };
    show_rows();
    let shown = show_rows.clone();
    look_in.connect_selected_notify(move |_| shown());
    period.connect_selected_notify(move |_| show_rows());
    let weak = Rc::downgrade(&finder);
    find.connect_clicked(move |_| {
        if let Some(finder) = weak.upgrade() {
            finder.scan();
        }
    });
    let weak = Rc::downgrade(&finder);
    stop.connect_clicked(move |_| {
        if let Some(finder) = weak.upgrade() {
            finder.cancel();
        }
    });
    let weak = Rc::downgrade(&finder);
    stack_button.connect_clicked(move |_| {
        if let Some(finder) = weak.upgrade() {
            finder.confirm_stacking();
        }
    });
    // Closing stops the comparing, and any stacking not sent yet.
    let owned = finder.clone();
    dialog.connect_closed(move |_| owned.cancel());
    dialog.present(Some(window));
}

impl Finder {
    fn cancel(&self) {
        self.generation.set(self.generation.get() + 1);
        if self.phase.get() == Phase::Working {
            self.phase.set(Phase::Ready);
            self.working(None, None);
            self.status.set_visible(false);
        }
    }

    fn live(&self, generation: u64) -> bool {
        self.generation.get() == generation
    }

    /// Show what is being done, with how far it is, or nothing.
    fn working(&self, text: Option<&str>, fraction: Option<f64>) {
        let on = text.is_some();
        self.status.set_visible(on);
        self.status.set_label(text.unwrap_or_default());
        self.progress.set_visible(on);
        self.stop.set_visible(on);
        match fraction {
            Some(fraction) => self.progress.set_fraction(fraction),
            None => self.progress.pulse(),
        }
        self.find.set_sensitive(!on);
        self.refresh_stack_button();
    }

    fn scan(self: &Rc<Self>) {
        let Some(window) = self.window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        self.generation.set(self.generation.get() + 1);
        let generation = self.generation.get();
        self.phase.set(Phase::Working);
        self.groups.borrow_mut().clear();
        self.features.borrow_mut().clear();
        self.coverage.set_visible(false);
        self.render();
        self.working(Some(tr("Looking for photos…")), None);
        let client = session.connection.client.clone();
        let user_id = session.connection.user_id().unwrap_or_default().to_owned();
        let use_selection = self.look_in.is_visible() && self.look_in.selected() == 0;
        let selection = self.selection.clone();
        let today = Local::now().date_naive();
        let (start, end) = match self.period.selected() {
            0 => similar::last_days(30, today),
            1 => similar::last_days(91, today),
            2 => similar::last_days(365, today),
            _ => (self.from.get(), self.to.get()),
        };
        let weak = Rc::downgrade(self);
        crate::tasks::run(
            async move {
                // (eligible, excluded, unreadable, too many)
                if use_selection {
                    let mut set = tokio::task::JoinSet::new();
                    for id in selection.into_iter().take(CANDIDATE_LIMIT + 1) {
                        let client = client.clone();
                        set.spawn(async move { client.asset_details(&id).await });
                    }
                    let (mut eligible, mut excluded, mut unreadable) = (Vec::new(), 0, 0);
                    while let Some(answer) = set.join_next().await {
                        match answer {
                            Ok(Ok(asset)) if similar::exclusion(&asset, &user_id).is_none() => eligible.push(similar::candidate(&asset)),
                            Ok(Ok(_)) => excluded += 1,
                            _ => unreadable += 1,
                        }
                    }
                    let too_many = eligible.len() > CANDIDATE_LIMIT;
                    return Ok::<_, String>((eligible, excluded, unreadable, too_many));
                }
                let query = AssetQuery { taken: Some(similar::bounds(start, end)), kind: Some(AssetKind::Image), oldest_first: true, ..AssetQuery::default() };
                let found = client.search_all_assets(&query, 1000).await.map_err(|error| verso_desktop::errors::said(&error))?;
                let (mut eligible, mut excluded) = (Vec::new(), 0);
                for asset in &found {
                    if similar::search_exclusion(asset).is_none() {
                        eligible.push(similar::search_candidate(asset));
                    } else {
                        excluded += 1;
                    }
                }
                let too_many = eligible.len() > CANDIDATE_LIMIT;
                Ok((eligible, excluded, 0, too_many))
            },
            move |outcome| {
                let Some(finder) = weak.upgrade().filter(|finder| finder.live(generation)) else { return };
                let (eligible, excluded, unreadable, too_many) = match outcome {
                    Ok(found) => found,
                    Err(message) => {
                        finder.phase.set(Phase::Ready);
                        finder.working(None, None);
                        return finder.say(&message);
                    }
                };
                if too_many {
                    finder.phase.set(Phase::Ready);
                    finder.working(None, None);
                    return finder.say(&tr("There are more than {count} photos to check. Choose a shorter period or fewer photos so every one can be compared.").replace("{count}", &CANDIDATE_LIMIT.to_string()));
                }
                let gap = GAPS.get(finder.gap.selected() as usize).copied().unwrap_or(DEFAULT_GAP);
                let runs = similar::time_runs(&eligible, gap);
                let checked = eligible.len();
                finder.analyze(generation, runs, checked, excluded, unreadable);
            },
        );
    }

    fn say(&self, message: &str) {
        self.coverage.set_label(message);
        self.coverage.set_visible(true);
    }

    /// Compare the photos of each run, a batch at a time so the sheet shows how far it is and Stop stops it.
    fn analyze(self: &Rc<Self>, generation: u64, runs: Vec<Vec<Candidate>>, checked: usize, excluded: usize, unreadable: usize) {
        let pending: Vec<String> = runs.iter().flatten().map(|candidate| candidate.id.clone()).collect();
        let total = pending.len();
        let runs = Rc::new(runs);
        self.analyze_batch(generation, runs, Rc::new(pending), 0, total, (checked, excluded, unreadable));
    }

    fn analyze_batch(self: &Rc<Self>, generation: u64, runs: Rc<Vec<Vec<Candidate>>>, pending: Rc<Vec<String>>, done: usize, total: usize, coverage: (usize, usize, usize)) {
        if done >= total {
            return self.cluster(&runs, coverage);
        }
        self.working(Some(&tr("Comparing {done} of {total} photos…").replace("{done}", &done.to_string()).replace("{total}", &total.to_string())), Some(done as f64 / total.max(1) as f64));
        let Some(session) = self.window.upgrade().and_then(|window| window.session()) else { return };
        let cache = session.textures.cache().clone();
        let batch: Vec<String> = pending.iter().skip(done).take(BATCH).cloned().collect();
        let weak = Rc::downgrade(self);
        crate::tasks::run(
            async move {
                let mut set = tokio::task::JoinSet::new();
                for id in batch {
                    let cache = cache.clone();
                    set.spawn(async move {
                        let picture = cache.picture(ImageKind::Thumbnail, &id, None, Some(200)).await.ok();
                        let features = picture.and_then(|picture| similar::features(&picture.rgba, picture.width as usize, picture.height as usize));
                        (id, features)
                    });
                }
                let mut found = Vec::new();
                while let Some(Ok(answer)) = set.join_next().await {
                    found.push(answer);
                }
                found
            },
            move |found| {
                let Some(finder) = weak.upgrade().filter(|finder| finder.live(generation)) else { return };
                let count = found.len();
                for (id, features) in found {
                    if let Some(features) = features {
                        finder.features.borrow_mut().insert(id, features);
                    }
                }
                finder.analyze_batch(generation, runs, pending, done + count.max(1), total, coverage);
            },
        );
    }

    fn cluster(self: &Rc<Self>, runs: &[Vec<Candidate>], (checked, excluded, unreadable): (usize, usize, usize)) {
        let threshold = Sensitivity::ALL.get(self.sensitivity.selected() as usize).copied().unwrap_or_default().threshold();
        let features = self.features.borrow().clone();
        let analysed = features.len();
        let failures = runs.iter().map(Vec::len).sum::<usize>() - analysed;
        let mut groups = Vec::new();
        for run in runs {
            let distance = |a: usize, b: usize| Some(similar::distance(features.get(&run[a].id)?, features.get(&run[b].id)?));
            for indices in similar::groups(run, threshold, distance) {
                let members: Vec<Candidate> = indices.iter().map(|index| run[*index].clone()).collect();
                let suggested = similar::top_pick(&members, &features).unwrap_or_else(|| members[0].id.clone());
                groups.push(Group { members, removed: Vec::new(), cover: suggested.clone(), suggested, included: true, status: Status::Pending });
            }
        }
        self.groups.replace(groups);
        self.phase.set(Phase::Ready);
        self.working(None, None);
        let mut lines = vec![tr("Checked {count} photos and found {groups} groups.").replace("{count}", &checked.to_string()).replace("{groups}", &self.groups.borrow().len().to_string())];
        if excluded > 0 {
            lines.push(tr("Skipped {count} items: videos, other people's photos, and items in a stack, Recently Deleted or the Locked Folder.").replace("{count}", &excluded.to_string()));
        }
        if unreadable > 0 {
            lines.push(tr("{count} selected items could not be read and were not checked.").replace("{count}", &unreadable.to_string()));
        }
        if failures > 0 {
            lines.push(tr("{count} photos could not be compared and are in no group.").replace("{count}", &failures.to_string()));
        }
        if self.groups.borrow().is_empty() {
            lines.push(tr("No photos taken close together look alike enough. Try a longer period or a looser sensitivity.").to_owned());
        }
        self.say(&lines.join("\n"));
        self.render();
    }

    /// The groups that would become stacks.
    fn stackable(&self) -> Vec<usize> {
        self.groups.borrow().iter().enumerate().filter(|(_, group)| group.included && group.status == Status::Pending && group.members.len() >= MIN_MEMBERS).map(|(index, _)| index).collect()
    }

    fn refresh_stack_button(&self) {
        let count = self.stackable().len();
        self.stack_button.set_label(&tr("Stack {count} Groups…").replace("{count}", &count.to_string()));
        self.stack_button.set_sensitive(count > 0 && self.phase.get() == Phase::Ready);
    }

    fn render(self: &Rc<Self>) {
        while let Some(child) = self.results.first_child() {
            self.results.remove(&child);
        }
        let Some(session) = self.window.upgrade().and_then(|window| window.session()) else { return };
        let groups = self.groups.borrow().clone();
        for (index, group) in groups.iter().enumerate() {
            self.results.append(&self.group_card(&session.textures, index, group));
        }
        self.refresh_stack_button();
    }

    fn change(self: &Rc<Self>, index: usize, change: impl FnOnce(&mut Group)) {
        if let Some(group) = self.groups.borrow_mut().get_mut(index) {
            change(group);
        }
        self.render();
    }

    fn group_card(self: &Rc<Self>, textures: &Rc<crate::textures::Textures>, index: usize, group: &Group) -> gtk::Box {
        let editable = group.status == Status::Pending && self.phase.get() == Phase::Ready;
        let title = group.members.first().map(|first| text::taken(first.taken.with_timezone(&Local).naive_local())).unwrap_or_default();
        let include = gtk::CheckButton::builder().label(&title).active(group.included).sensitive(editable).tooltip_text(tr("Include this group when stacking")).build();
        let weak = Rc::downgrade(self);
        include.connect_toggled(move |include| {
            let on = include.is_active();
            if let Some(finder) = weak.upgrade() {
                finder.change(index, |group| group.included = on);
            }
        });
        let header = gtk::Box::builder().spacing(12).build();
        header.append(&include);
        header.append(&gtk::Label::builder().label(text::items(group.members.len() as u64)).css_classes(["dim-label"]).hexpand(true).xalign(0.0).build());
        if editable && !group.removed.is_empty() {
            let restore = gtk::Button::builder().label(tr("Restore Removed Photos")).css_classes(["flat"]).build();
            let weak = Rc::downgrade(self);
            restore.connect_clicked(move |_| {
                if let Some(finder) = weak.upgrade() {
                    finder.change(index, |group| {
                        group.members.append(&mut group.removed);
                        group.members.sort_by(|a, b| (a.taken, &a.id).cmp(&(b.taken, &b.id)));
                    });
                }
            });
            header.append(&restore);
        }
        match &group.status {
            Status::Pending => {}
            Status::Stacked(stack_id) => {
                header.append(&gtk::Label::builder().label(tr("Stacked")).css_classes(["success"]).build());
                let open = gtk::Button::builder().label(tr("Open Stack…")).css_classes(["flat"]).build();
                let (weak_window, stack_id) = (self.window.clone(), stack_id.clone());
                open.connect_clicked(move |button| {
                    if let Some(window) = weak_window.upgrade() {
                        if let Some(dialog) = button.ancestor(adw::Dialog::static_type()).and_downcast::<adw::Dialog>() {
                            dialog.close();
                        }
                        crate::stacks::show_stack(&window, &stack_id);
                    }
                });
                header.append(&open);
            }
            Status::Failed(message) => {
                header.append(&gtk::Label::builder().label(message).css_classes(["error"]).ellipsize(gtk::pango::EllipsizeMode::End).max_width_chars(40).tooltip_text(message).build());
            }
        }
        let tiles = gtk::Box::builder().spacing(8).margin_bottom(4).build();
        for member in &group.members {
            tiles.append(&self.tile(textures, index, group, member, editable));
        }
        let card = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(8).css_classes(["card"]).build();
        let inner = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(8).margin_top(12).margin_bottom(12).margin_start(12).margin_end(12).build();
        inner.append(&header);
        inner.append(&gtk::ScrolledWindow::builder().child(&tiles).vscrollbar_policy(gtk::PolicyType::Never).propagate_natural_height(true).build());
        if group.members.len() < MIN_MEMBERS {
            inner.append(&gtk::Label::builder().label(tr("A stack needs at least two photos.")).xalign(0.0).css_classes(["caption", "dim-label"]).build());
        }
        card.append(&inner);
        card.set_opacity(if group.included || !editable { 1.0 } else { 0.55 });
        card
    }

    fn tile(self: &Rc<Self>, textures: &Rc<crate::textures::Textures>, index: usize, group: &Group, member: &Candidate, editable: bool) -> gtk::Overlay {
        let picture = gtk::Picture::builder().content_fit(gtk::ContentFit::Cover).can_shrink(true).build();
        let weak_picture = picture.downgrade();
        textures.get(ImageKind::Thumbnail, &member.id, None, move |texture| {
            if let (Some(picture), Some(texture)) = (weak_picture.upgrade(), texture) {
                picture.set_paintable(Some(&texture));
            }
        });
        let frame = SquareFrame::new(128, &picture);
        frame.add_css_class("gallery-card-picture");
        let pick = gtk::Button::builder().child(&frame).css_classes(["flat"]).sensitive(editable).tooltip_text(tr("Make Cover")).build();
        let (weak, id) = (Rc::downgrade(self), member.id.clone());
        pick.connect_clicked(move |_| {
            if let Some(finder) = weak.upgrade() {
                let id = id.clone();
                finder.change(index, move |group| group.cover = id);
            }
        });
        let overlay = gtk::Overlay::builder().child(&pick).build();
        if group.cover == member.id {
            let label = if member.id == group.suggested { tr("Suggested Cover") } else { tr("Cover") };
            overlay.add_overlay(&gtk::Label::builder().label(label).halign(gtk::Align::Start).valign(gtk::Align::Start).margin_top(6).margin_start(6).css_classes(["osd", "caption-heading", "gallery-cover-badge"]).build());
        }
        if editable {
            let remove = gtk::Button::builder().icon_name("window-close-symbolic").tooltip_text(tr("Remove from Group")).halign(gtk::Align::End).valign(gtk::Align::Start).margin_top(4).margin_end(4).css_classes(["circular", "osd"]).build();
            let (weak, id) = (Rc::downgrade(self), member.id.clone());
            remove.connect_clicked(move |_| {
                let Some(finder) = weak.upgrade() else { return };
                let id = id.clone();
                finder.change(index, move |group| {
                    if let Some(position) = group.members.iter().position(|member| member.id == id) {
                        let gone = group.members.remove(position);
                        group.removed.push(gone);
                    }
                    if group.cover == id {
                        group.cover = group.members.first().map(|member| member.id.clone()).unwrap_or_default();
                    }
                });
            });
            overlay.add_overlay(&remove);
        }
        overlay
    }

    fn confirm_stacking(self: &Rc<Self>) {
        let Some(window) = self.window.upgrade() else { return };
        let count = self.stackable().len();
        let weak = Rc::downgrade(self);
        let heading = tr("Stack {count} Groups?").replace("{count}", &count.to_string());
        crate::dialogs::confirm(&window, &heading, tr("Each group becomes a stack in Immich with its cover on top. You can change the cover or unstack later. No photo is deleted."), tr("Stack Groups"), false, move || {
            if let Some(finder) = weak.upgrade() {
                finder.generation.set(finder.generation.get() + 1);
                let generation = finder.generation.get();
                finder.phase.set(Phase::Working);
                let chosen = finder.stackable();
                finder.stack_next(generation, Rc::new(chosen), 0);
            }
        });
    }

    /// Make the chosen groups stacks, one at a time, the cover first.
    fn stack_next(self: &Rc<Self>, generation: u64, chosen: Rc<Vec<usize>>, done: usize) {
        let Some(&index) = chosen.get(done) else {
            self.phase.set(Phase::Ready);
            self.working(None, None);
            self.render();
            if let Some(window) = self.window.upgrade() {
                window.reload_grids();
            }
            return;
        };
        self.working(Some(&tr("Stacking {done} of {total} groups…").replace("{done}", &done.to_string()).replace("{total}", &chosen.len().to_string())), Some(done as f64 / chosen.len().max(1) as f64));
        let Some(session) = self.window.upgrade().and_then(|window| window.session()) else { return };
        let Some(group) = self.groups.borrow().get(index).cloned() else { return };
        let mut ids = vec![group.cover.clone()];
        ids.extend(group.members.iter().map(|member| member.id.clone()).filter(|id| *id != group.cover));
        let (client, cover) = (session.connection.client.clone(), group.cover.clone());
        let weak = Rc::downgrade(self);
        crate::tasks::run(
            async move {
                let stack = client.create_stack(&ids).await.map_err(|error| verso_desktop::errors::said(&error))?;
                if stack.primary_asset_id != cover {
                    client.set_stack_primary(&stack.id, &cover).await.map_err(|error| tr("Stacked; the cover could not be set: {error}").replace("{error}", &error.to_string()))?;
                }
                Ok::<String, String>(stack.id)
            },
            move |outcome| {
                let Some(finder) = weak.upgrade() else { return };
                if let Some(group) = finder.groups.borrow_mut().get_mut(index) {
                    group.status = match outcome {
                        Ok(stack_id) => Status::Stacked(stack_id),
                        Err(message) => Status::Failed(message),
                    };
                }
                // Closing the sheet stops the stacking not sent yet.
                if finder.live(generation) {
                    finder.stack_next(generation, chosen, done + 1);
                } else {
                    finder.phase.set(Phase::Ready);
                    finder.render();
                }
            },
        );
    }
}

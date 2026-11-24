//! Cards for what has photos and a few facts to tell (Shared Links, Countries, Memories, Albums): the photos are the
//! card, edge to edge, one to three of them, labelled where a label says something (a country's cities); its title
//! and a line or two sit on a dark fade at their foot, small chips in their top corners say what else there is (New,
//! a memory's Keep, a public link's globe, a link's expiry), and the people it is shared with sit at their foot on the
//! right. Only a link's buttons go below. A card without buttons of its own opens with a click anywhere on it.
//!
//! Their size is the zoom's (the header's − and +, Ctrl and − or +): five steps of width, a card never narrower than
//! its text needs nor wider than a photo wants, and at most five on a line. Square tiles, People's faces and the
//! cities, follow the same steps: a photo filling a rounded square with its name on it (`square_tile`).

use std::cell::RefCell;
use std::rc::Rc;

use adw::prelude::*;
use gtk::glib;
use verso_desktop::images::Kind as ImageKind;
use verso_linux::i18n::tr;

use crate::collections::SquareFrame;
use crate::textures::Textures;

/// A card's least width at each zoom step; its photos are about three quarters as tall.
const WIDTHS: [i32; 5] = [220, 260, 300, 360, 440];
/// A face's side on the People page at each zoom step.
const FACES: [i32; 5] = [96, 120, 144, 176, 208];
/// The step the cards start at.
const FIRST_STEP: usize = 2;
/// Where the step is remembered.
const SIZE: &str = "cards.size";

/// The zoom step the cards are at.
fn step() -> usize {
    verso_desktop::settings::shared().get(SIZE).and_then(|step| step.parse().ok()).filter(|step| *step < WIDTHS.len()).unwrap_or(FIRST_STEP)
}

fn width() -> i32 {
    WIDTHS[step()]
}

fn photos_height(width: i32) -> i32 {
    width * 73 / 100
}

/// A face's side on the People page, at the cards' step.
pub fn face_size() -> i32 {
    FACES[step()]
}

/// What a frame on a card page is, so the zoom knows its new size.
#[derive(Clone, Copy)]
enum Shape {
    /// A card's photos: a band as wide as the card.
    Band,
    /// A face: a square.
    Face,
}

thread_local! {
    /// The frames the zoom resizes, held weakly; gone ones are dropped as it goes.
    static FRAMES: RefCell<Vec<(glib::WeakRef<SquareFrame>, Shape)>> = const { RefCell::new(Vec::new()) };
}

fn follow_zoom(frame: &SquareFrame, shape: Shape) {
    FRAMES.with(|frames| frames.borrow_mut().push((frame.downgrade(), shape)));
}

/// Bigger (`steps` above 0) or smaller cards and faces, within their steps; `false` when already at the end.
pub fn zoom(steps: i32) -> bool {
    let next = (step() as i32 + steps).clamp(0, WIDTHS.len() as i32 - 1) as usize;
    if next == step() {
        return false;
    }
    verso_desktop::settings::shared().set(SIZE, Some(&next.to_string()));
    FRAMES.with(|frames| {
        frames.borrow_mut().retain(|(frame, shape)| {
            let Some(frame) = frame.upgrade() else { return false };
            match shape {
                Shape::Band => frame.resize(WIDTHS[next], Some(photos_height(WIDTHS[next]))),
                Shape::Face => frame.resize(FACES[next], None),
            }
            true
        });
    });
    true
}

/// A square tile's frame: a square at the zoom's size, as wide as the line gives it.
pub fn face_frame(child: &impl IsA<gtk::Widget>) -> SquareFrame {
    let frame = SquareFrame::adaptive(face_size(), child);
    follow_zoom(&frame, Shape::Face);
    frame
}

/// A square tile, a person's face or a city: `picture` filling a rounded square at the zoom's size, `name` on a fade
/// at its foot and, where there is one, a dimmer line under it. The tile, and the area over the picture that a chip
/// may be added to.
pub fn square_tile(picture: &impl IsA<gtk::Widget>, name: &str, below: Option<&str>) -> (gtk::Box, gtk::Overlay) {
    let area = gtk::Overlay::builder().child(&face_frame(picture)).build();
    area.add_overlay(&gtk::Box::builder().can_target(false).css_classes(["verso-card-fade"]).build());
    let words = gtk::Box::builder().orientation(gtk::Orientation::Vertical).valign(gtk::Align::End).margin_start(10).margin_end(10).margin_bottom(8).build();
    words.append(&gtk::Label::builder().label(name).xalign(0.0).ellipsize(gtk::pango::EllipsizeMode::End).css_classes(["verso-face-name"]).build());
    if let Some(below) = below.filter(|below| !below.is_empty()) {
        words.append(&gtk::Label::builder().label(below).xalign(0.0).ellipsize(gtk::pango::EllipsizeMode::End).css_classes(["verso-face-line"]).build());
    }
    area.add_overlay(&words);
    // Upright, so the picture takes the whole width the line gives the tile, and is as tall.
    let tile = gtk::Box::builder().orientation(gtk::Orientation::Vertical).overflow(gtk::Overflow::Hidden).css_classes(["verso-face"]).build();
    tile.append(&area);
    (tile, area)
}

/// A picture of `id`'s image of `kind`, cropped to fill, from the cache or once read.
pub fn picture(textures: &Rc<Textures>, kind: ImageKind, id: &str) -> gtk::Picture {
    let picture = gtk::Picture::builder().content_fit(gtk::ContentFit::Cover).can_shrink(true).hexpand(true).vexpand(true).build();
    match textures.cached(kind, id, None) {
        Some(texture) => picture.set_paintable(Some(&texture)),
        None => {
            let weak = picture.downgrade();
            textures.get(kind, id, None, move |texture| {
                if let (Some(picture), Some(texture)) = (weak.upgrade(), texture) {
                    picture.set_paintable(Some(&texture));
                }
            });
        }
    }
    picture
}

/// The − and + of a card page's header: smaller and bigger cards (the window's zoom actions), drawn as the photo
/// grids' pair is (`pages.rs`).
pub fn zoom_buttons() -> gtk::Box {
    let buttons = gtk::Box::builder().css_classes(["linked"]).valign(gtk::Align::Center).build();
    buttons.append(&gtk::Button::builder().icon_name("list-remove-symbolic").tooltip_text(tr("Smaller")).action_name("win.zoom-out").build());
    buttons.append(&gtk::Button::builder().icon_name("list-add-symbolic").tooltip_text(tr("Bigger")).action_name("win.zoom-in").build());
    buttons
}

/// A flow box of cards: as many on a line as fit, at most five, one in a narrow window. A click activates a card.
pub fn flow() -> gtk::FlowBox {
    gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .activate_on_single_click(true)
        .homogeneous(true)
        .min_children_per_line(1)
        .max_children_per_line(5)
        .row_spacing(18)
        .column_spacing(18)
        .valign(gtk::Align::Start)
        .css_classes(["verso-cards"])
        .build()
}

/// A photo on a card, and its label, if it has one.
pub struct Shown {
    pub id: String,
    pub label: Option<String>,
}

impl Shown {
    pub fn photo(id: &str) -> Shown {
        Shown { id: id.to_owned(), label: None }
    }

    pub fn labelled(id: &str, label: &str) -> Shown {
        Shown { id: id.to_owned(), label: Some(label.to_owned()).filter(|label| !label.is_empty()) }
    }
}

pub struct Card {
    pub root: gtk::Box,
    /// The photos' grid: what a late answer fills in (`fill`), held weakly, as the card itself is not kept.
    pub photos: gtk::Grid,
    /// The photos as a button of their own, for a card that does not open as a whole.
    pub photos_button: Option<gtk::Button>,
    /// The title and its lines, on the fade at the photos' foot.
    caption: gtk::Box,
    /// The people it is shared with, at the photos' foot on the right: filled in later, held weakly, where read later.
    pub people: gtk::Box,
    /// The chips in the photos' top corners.
    start: gtk::Box,
    end: gtk::Box,
    /// A note over the photos while the pointer is on the card (an album's description), on a dimming of them.
    note: gtk::Label,
    dim: gtk::Box,
}

impl Card {
    /// A card titled `title`. `opens` makes it a whole that opens with a click; otherwise its photos are a button of
    /// their own and its buttons go along its foot.
    pub fn new(title: &str, opens: bool) -> Card {
        let root = gtk::Box::builder().orientation(gtk::Orientation::Vertical).overflow(gtk::Overflow::Hidden).css_classes(["card", "verso-card"]).build();
        if opens {
            root.add_css_class("activatable");
        }
        let photos = gtk::Grid::builder().column_homogeneous(true).row_homogeneous(true).column_spacing(2).row_spacing(2).build();
        let band = SquareFrame::band(width(), photos_height(width()), &photos);
        follow_zoom(&band, Shape::Band);
        let area = gtk::Overlay::builder().child(&band).build();
        // The fade the caption sits on, under everything else over the photos.
        area.add_overlay(&gtk::Box::builder().can_target(false).css_classes(["verso-card-fade"]).build());
        // A note's dimming and the note, shown on hover (style.css): under the title and the chips, which stay
        // clear, and never in the way of a click.
        let dim = gtk::Box::builder().can_target(false).visible(false).css_classes(["verso-card-dim"]).build();
        let note = gtk::Label::builder()
            .can_target(false)
            .visible(false)
            .wrap(true)
            .wrap_mode(gtk::pango::WrapMode::WordChar)
            .lines(4)
            .ellipsize(gtk::pango::EllipsizeMode::End)
            .max_width_chars(1)
            .xalign(0.0)
            .valign(gtk::Align::Center)
            .margin_start(14)
            .margin_end(14)
            .css_classes(["verso-card-note"])
            .build();
        area.add_overlay(&dim);
        area.add_overlay(&note);
        let caption = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(2).hexpand(true).valign(gtk::Align::End).build();
        caption.append(&gtk::Label::builder().label(title).xalign(0.0).ellipsize(gtk::pango::EllipsizeMode::End).css_classes(["verso-card-title"]).build());
        let people = gtk::Box::builder().spacing(2).valign(gtk::Align::End).css_classes(["verso-card-people"]).build();
        let foot = gtk::Box::builder().spacing(8).valign(gtk::Align::End).margin_start(12).margin_end(10).margin_bottom(10).build();
        foot.append(&caption);
        foot.append(&people);
        area.add_overlay(&foot);
        let start = gtk::Box::builder().spacing(6).halign(gtk::Align::Start).valign(gtk::Align::Start).margin_start(8).margin_top(8).build();
        let end = gtk::Box::builder().spacing(6).halign(gtk::Align::End).valign(gtk::Align::Start).margin_end(8).margin_top(8).build();
        area.add_overlay(&start);
        area.add_overlay(&end);
        let photos_button = (!opens).then(|| gtk::Button::builder().child(&area).css_classes(["flat", "verso-card-photos"]).build());
        match &photos_button {
            Some(button) => root.append(button),
            None => {
                area.add_css_class("verso-card-photos");
                root.append(&area);
            }
        }
        Card { root, photos, photos_button, caption, people, start, end, note, dim }
    }

    /// A note shown over the photos, dimmed, while the pointer is on the card or it has the keyboard's focus; read
    /// out as the card's description.
    pub fn note(&self, text: &str) {
        self.note.set_label(text);
        self.note.set_visible(true);
        self.dim.set_visible(true);
        self.root.update_property(&[gtk::accessible::Property::Description(text)]);
    }

    /// One to three photos: one across, two side by side, or one large beside two small; a symbol for none.
    pub fn set_photos(&self, textures: &Rc<Textures>, shown: &[Shown]) {
        fill(&self.photos, textures, shown);
    }

    /// A line under the title, on the photos: kept, so what it says can be filled in later (`say`).
    pub fn line(&self, said: &str) -> gtk::Label {
        let line = gtk::Label::builder().label(said).xalign(0.0).ellipsize(gtk::pango::EllipsizeMode::End).visible(!said.is_empty()).css_classes(["verso-card-line"]).build();
        self.caption.append(&line);
        line
    }

    /// A chip in the photos' top left corner.
    pub fn chip_start(&self, chip: &impl IsA<gtk::Widget>) {
        self.start.append(chip);
    }

    /// A chip in the photos' top right corner.
    pub fn chip_end(&self, chip: &impl IsA<gtk::Widget>) {
        self.end.append(chip);
    }

    /// Someone it is shared with, at the photos' foot on the right.
    pub fn person(&self, avatar: &impl IsA<gtk::Widget>) {
        self.people.append(avatar);
    }

    /// A row of buttons along the card's foot.
    pub fn foot(&self) -> gtk::Box {
        let foot = gtk::Box::builder().spacing(4).css_classes(["verso-card-foot"]).build();
        self.root.append(&foot);
        foot
    }
}

/// A chip: a symbol, a word, or both, on a dark glass over the photos; what it means on hover.
pub fn chip(icon: Option<&str>, word: Option<&str>, meaning: &str) -> gtk::Box {
    let chip = gtk::Box::builder().spacing(5).tooltip_text(meaning).css_classes(["verso-card-chip"]).build();
    if let Some(icon) = icon {
        chip.append(&gtk::Image::from_icon_name(icon));
    }
    if let Some(word) = word {
        chip.append(&gtk::Label::new(Some(word)));
    }
    chip
}

/// A chip to press: a memory's Keep, a globe.
pub fn chip_button(icon: &str, meaning: &str) -> gtk::Button {
    gtk::Button::builder().icon_name(icon).tooltip_text(meaning).css_classes(["verso-card-chip", "verso-card-chip-button"]).build()
}

/// Fill a card's photos (`Card::set_photos`), also from a late answer through the grid alone.
pub fn fill(photos: &gtk::Grid, textures: &Rc<Textures>, shown: &[Shown]) {
    while let Some(child) = photos.first_child() {
        photos.remove(&child);
    }
    let tile = |shown: &Shown| {
        let tile = gtk::Overlay::builder().child(&picture(textures, ImageKind::Thumbnail, &shown.id)).build();
        // Labels at the top, clear of the title at the foot.
        if let Some(label) = &shown.label {
            tile.add_overlay(&gtk::Label::builder().label(label).halign(gtk::Align::Start).valign(gtk::Align::Start).ellipsize(gtk::pango::EllipsizeMode::End).css_classes(["verso-card-tag"]).build());
        }
        tile
    };
    match shown {
        [] => photos.attach(&gtk::Image::builder().icon_name("image-x-generic-symbolic").pixel_size(48).css_classes(["dim-label"]).build(), 0, 0, 3, 2),
        [one] => photos.attach(&tile(one), 0, 0, 3, 2),
        [first, second] => {
            photos.attach(&tile(first), 0, 0, 2, 2);
            photos.attach(&tile(second), 2, 0, 1, 2);
        }
        [first, second, third, ..] => {
            photos.attach(&tile(first), 0, 0, 2, 2);
            photos.attach(&tile(second), 2, 0, 1, 1);
            photos.attach(&tile(third), 2, 1, 1, 1);
        }
    }
}

/// Fill in what a card's line says, and show it.
pub fn say(line: &gtk::Label, said: &str) {
    line.set_label(said);
    line.set_visible(!said.is_empty());
}

/// "Anna", "Anna and Ben", "Anna, Ben and Cleo".
pub fn and_list(names: &[String]) -> String {
    match names {
        [] => String::new(),
        [one] => one.clone(),
        [rest @ .., last] => tr("{list} and {last}").replace("{list}", &rest.join(", ")).replace("{last}", last),
    }
}

/// The years something spans: "2019", "2014 – 2023".
pub fn years(first: i32, last: i32) -> String {
    let (first, last) = (first.min(last), first.max(last));
    if first == last { first.to_string() } else { format!("{first} – {last}") }
}

/// A line of facts, those empty left out: "5 items · 2018 – 2023".
pub fn joined(facts: &[String]) -> String {
    facts.iter().filter(|fact| !fact.is_empty()).cloned().collect::<Vec<_>>().join(" · ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_and_years_read_as_text() {
        assert_eq!(and_list(&[]), "");
        assert_eq!(and_list(&["Anna".to_owned()]), "Anna");
        assert_eq!(and_list(&["Anna".to_owned(), "Ben".to_owned()]), "Anna and Ben");
        assert_eq!(and_list(&["Anna".to_owned(), "Ben".to_owned(), "Cleo".to_owned()]), "Anna, Ben and Cleo");
        assert_eq!(years(2019, 2019), "2019");
        assert_eq!(years(2023, 2014), "2014 – 2023");
        assert_eq!(joined(&["5 items".to_owned(), String::new(), "2019".to_owned()]), "5 items · 2019");
    }

    #[test]
    fn the_steps_keep_a_card_wide_enough_and_its_photos_in_proportion() {
        assert!(WIDTHS.windows(2).all(|pair| pair[0] < pair[1]) && FACES.windows(2).all(|pair| pair[0] < pair[1]));
        assert!(WIDTHS[0] >= 220, "the narrowest still fits a title and a line");
        assert_eq!(photos_height(300), 219);
    }
}

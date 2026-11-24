//! The faces on the photo shown, as the Mac gallery's: Face Names draws Immich's boxes and names over the photo, laid
//! out on the photo as it shows, so they zoom and scroll with it; Manage Faces lists them, to assign one to a person
//! (or a new one), use it as the person's face photo, or remove it.

use std::cell::RefCell;
use std::rc::Rc;

use adw::prelude::*;
use gtk::subclass::prelude::*;
use gtk::{gdk, gio, glib, graphene, gsk};
use immich_api::{Face, NewPerson, PersonChanges};
use verso_desktop::presentation::{self, Rect};
use verso_linux::i18n::tr;

use crate::utility_pages::{row_menu, string_action};
use crate::window::Window;

/// What the layer draws: each face's box on screen and its name.
pub type Boxes = Box<dyn Fn(&FaceLayer) -> Vec<(Rect, String)>>;

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct FaceLayer {
        pub boxes: RefCell<Option<Boxes>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for FaceLayer {
        const NAME: &'static str = "GalleryFaceLayer";
        type Type = super::FaceLayer;
        type ParentType = gtk::Widget;
    }

    impl ObjectImpl for FaceLayer {}

    impl WidgetImpl for FaceLayer {
        fn snapshot(&self, snapshot: &gtk::Snapshot) {
            let layer = self.obj();
            let Some(boxes) = self.boxes.borrow().as_ref().map(|boxes| boxes(&layer)) else { return };
            let white = gdk::RGBA::WHITE;
            let shade = gdk::RGBA::new(0.0, 0.0, 0.0, 0.7);
            for ((left, top, width, height), name) in boxes {
                let (left, top, width, height) = (left as f32, top as f32, width as f32, height as f32);
                let outline = gsk::RoundedRect::from_rect(graphene::Rect::new(left, top, width, height), 0.0);
                snapshot.append_border(&outline, &[2.0; 4], &[white; 4]);
                let layout = layer.create_pango_layout(Some(&name));
                let (text_width, text_height) = layout.pixel_size();
                let (text_width, text_height) = (text_width as f32, text_height as f32);
                let (text_left, text_top) = (left + (width - text_width) / 2.0, top + height + 2.0);
                snapshot.append_color(&shade, &graphene::Rect::new(text_left - 4.0, text_top - 1.0, text_width + 8.0, text_height + 2.0));
                snapshot.save();
                snapshot.translate(&graphene::Point::new(text_left, text_top));
                snapshot.append_layout(&layout, &white);
                snapshot.restore();
            }
        }
    }
}

glib::wrapper! {
    /// Boxes and names over the photo; it takes no clicks, so dragging and zooming the photo still work.
    pub struct FaceLayer(ObjectSubclass<imp::FaceLayer>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl FaceLayer {
    pub fn new() -> FaceLayer {
        glib::Object::builder().property("can-target", false).property("hexpand", true).property("vexpand", true).build()
    }

    pub fn set_boxes(&self, boxes: Boxes) {
        self.imp().boxes.replace(Some(boxes));
        self.queue_draw();
    }
}

/// The boxes of `faces` on a photo shown in `shown`, with their names.
pub fn boxes_on(faces: &[Face], shown: Rect) -> Vec<(Rect, String)> {
    faces.iter().filter_map(|face| Some((presentation::face_box(face, shown)?, presentation::face_name(face).unwrap_or(tr("Unassigned Face")).to_owned()))).collect()
}

/// Manage Faces: the photo's faces, each to assign, use as the person's face photo, or remove. `changed` runs after
/// each change, so the boxes show it.
pub fn manage_faces(window: &Window, asset_id: &str, changed: Rc<dyn Fn()>) {
    let page = adw::PreferencesPage::new();
    let header = adw::HeaderBar::new();
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(&page));
    let dialog = adw::Dialog::builder().title(tr("Faces in This Photo")).content_width(460).content_height(440).child(&toolbar).build();
    let group: Rc<RefCell<Option<adw::PreferencesGroup>>> = Rc::default();
    let faces: Rc<RefCell<Vec<Face>>> = Rc::default();
    let load: Rc<dyn Fn()> = {
        let (weak_window, page, group, faces, asset_id) = (window.downgrade(), page.clone(), group.clone(), faces.clone(), asset_id.to_owned());
        Rc::new(move || {
            let Some(window) = weak_window.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let (client, page, group, faces, shown, id) = (session.connection.client.clone(), page.clone(), group.clone(), faces.clone(), window.clone(), asset_id.clone());
            crate::tasks::run(
                async move {
                    let details = client.asset_details(&id).await.map_err(|error| verso_desktop::errors::said(&error))?;
                    let found = client.faces(&id).await.map_err(|error| verso_desktop::errors::said(&error))?;
                    Ok::<_, String>((details.is_edited, found))
                },
                move |outcome| {
                    let (edited, found) = match outcome {
                        Ok(found) => found,
                        Err(message) => return shown.toast(&message),
                    };
                    if let Some(old) = group.borrow_mut().take() {
                        page.remove(&old);
                    }
                    let rows = adw::PreferencesGroup::new();
                    let mut notes = Vec::new();
                    if found.is_empty() {
                        notes.push(tr("No faces found."));
                    }
                    if edited {
                        notes.push(tr("Face boxes are unavailable for edited photos."));
                    }
                    if !notes.is_empty() {
                        rows.set_description(Some(&notes.join(" ")));
                    }
                    for face in &found {
                        let name = presentation::face_name(face).unwrap_or(tr("Unassigned Face"));
                        let row = adw::ActionRow::builder().title(glib::markup_escape_text(name)).build();
                        row.add_prefix(&adw::Avatar::new(32, Some(name), face.person.is_some()));
                        let menu = gio::Menu::new();
                        menu.append(Some(tr("Assign…")), Some(&format!("faces.assign::{}", face.id)));
                        if face.person.is_some() {
                            menu.append(Some(tr("Use as Face Photo")), Some(&format!("faces.face-photo::{}", face.id)));
                            menu.append(Some(tr("Remove Face…")), Some(&format!("faces.remove::{}", face.id)));
                        }
                        row_menu(&row, &menu);
                        rows.add(&row);
                    }
                    page.add(&rows);
                    group.replace(Some(rows));
                    faces.replace(found);
                },
            );
        })
    };
    let done: Rc<dyn Fn()> = {
        let (load, changed) = (load.clone(), changed.clone());
        Rc::new(move || {
            load();
            changed();
        })
    };
    let actions = gio::SimpleActionGroup::new();
    let (weak_window, known, again) = (window.downgrade(), faces.clone(), done.clone());
    actions.add_action(&string_action("assign", move |face_id| {
        let Some(window) = weak_window.upgrade() else { return };
        let current = known.borrow().iter().find(|face| face.id == face_id).and_then(|face| face.person.as_ref().map(|person| person.id.clone()));
        assign(&window, face_id, current, again.clone());
    }));
    let (weak_window, known, again, photo) = (window.downgrade(), faces.clone(), done.clone(), asset_id.to_owned());
    actions.add_action(&string_action("face-photo", move |face_id| {
        let Some(window) = weak_window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        let Some(person) = known.borrow().iter().find(|face| face.id == face_id).and_then(|face| face.person.clone()) else { return };
        let changes = PersonChanges { feature_face_asset_id: Some(photo.clone()), ..PersonChanges::default() };
        let (client, shown, again) = (session.connection.client.clone(), window.clone(), again.clone());
        crate::tasks::run(async move { client.update_person(&person.id, &changes).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
            Ok(_) => {
                shown.toast(tr("Face photo changed"));
                again();
            }
            Err(message) => shown.toast(&message),
        });
    }));
    let (weak_window, again) = (window.downgrade(), done.clone());
    actions.add_action(&string_action("remove", move |face_id| {
        let Some(window) = weak_window.upgrade() else { return };
        let (weak, again) = (window.downgrade(), again.clone());
        crate::dialogs::confirm(&window, tr("Remove the Face?"), tr("The face leaves the photo; the photo stays."), tr("Remove Face"), true, move || {
            let Some(window) = weak.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let (client, id, shown, again) = (session.connection.client.clone(), face_id.clone(), window.clone(), again.clone());
            crate::tasks::run(async move { client.delete_face(&id, false).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                Ok(()) => again(),
                Err(message) => shown.toast(&message),
            });
        });
    }));
    dialog.insert_action_group("faces", Some(&actions));
    load();
    dialog.present(Some(window));
}

/// Assign Face: one of the people (not the one it has), or a new person, named here.
fn assign(window: &Window, face_id: String, current: Option<String>, done: Rc<dyn Fn()>) {
    let Some(session) = window.session() else { return };
    let (client, shown) = (session.connection.client.clone(), window.clone());
    crate::tasks::run(async move { client.people().await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
        let people = match outcome {
            Ok(people) => people,
            Err(message) => return shown.toast(&message),
        };
        // Not an id Immich gives (a UUID), and fit to name a widget.
        const NEW: &str = "new-person";
        let mut choices: Vec<(String, String)> = people.into_iter().filter(|person| !person.name.trim().is_empty() && Some(&person.id) != current.as_ref()).map(|person| (person.id, person.name)).collect();
        choices.sort_by_key(|(_, name)| name.to_lowercase());
        choices.insert(0, (NEW.to_owned(), tr("New Person…").to_owned()));
        let weak = shown.downgrade();
        crate::dialogs::choose_item(&shown, tr("Assign Face"), tr("Search people"), choices, move |person_id, _| {
            let Some(window) = weak.upgrade() else { return };
            let (face_id, done) = (face_id.clone(), done.clone());
            if person_id != NEW {
                return reassign(&window, face_id, person_id, None, done);
            }
            let weak = window.downgrade();
            crate::dialogs::ask_text(&window, tr("New Person"), tr("Name"), "", tr("Assign"), move |name| {
                if let Some(window) = weak.upgrade().filter(|_| !name.trim().is_empty()) {
                    reassign(&window, face_id.clone(), String::new(), Some(name.trim().to_owned()), done.clone());
                }
            });
        });
    });
}

/// The face goes to `person_id`, or to a new person of `new_name`.
fn reassign(window: &Window, face_id: String, person_id: String, new_name: Option<String>, done: Rc<dyn Fn()>) {
    let Some(session) = window.session() else { return };
    let (client, shown) = (session.connection.client.clone(), window.clone());
    crate::tasks::run(
        async move {
            let person_id = match new_name {
                Some(name) => client.create_person(&NewPerson { name: Some(name), ..NewPerson::default() }).await.map_err(|error| verso_desktop::errors::said(&error))?.id,
                None => person_id,
            };
            client.reassign_face(&face_id, &person_id).await.map_err(|error| verso_desktop::errors::said(&error))
        },
        move |outcome| match outcome {
            Ok(_) => done(),
            Err(message) => shown.toast(&message),
        },
    );
}

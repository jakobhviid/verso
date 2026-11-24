# Verso's rpm (ARCHITECTURE.md, "The rpm and the deb"): the files linux/packaging/verso-packages.sh built and laid out
# in Fedora 44's container, in their places under /usr; nothing is compiled here.
# rpmbuild -bb --define "pkg_version <version>" --define "payload <directory>" verso.spec
%global debug_package %{nil}
# The files go in as they were laid out and stripped: none of the steps that would change them after %install (strip,
# add-determinism rewriting the PNGs in place and leaving their folder with the time of the build, and the rest).
%global __os_install_post %{nil}
# Where this Fedora's Nautilus loads extensions from (nautilus-devel), as the payload has it.
%global nautilus_extensiondir %(pkg-config --variable=extensiondir libnautilus-extension-4)
# The Files extension is loaded by Nautilus, never linked: it provides no library to depend on.
%global __provides_exclude_from ^%{nautilus_extensiondir}/.*\\.so$
# Every file's time and the build's are the commit's (SOURCE_DATE_EPOCH), so the same tree makes the same package.
%global source_date_epoch_from_changelog 0
%global clamp_mtime_to_source_epoch 1
%global use_source_date_epoch_as_buildtime 1
%global _buildhost reproducible

Name:           verso
Version:        %{pkg_version}
Release:        1
Summary:        Browse, search and organise your Immich photos and videos, with your library as a drive in Files
License:        MIT
URL:            https://github.com/jakobhviid/verso
ExclusiveArch:  x86_64
# GNOME 49's libraries or newer (SPEC.md, "Supported versions"), which keep the package off an older system; the map's
# library from the version Verso's map needs; Verso Drive's mount.
Requires:       gtk4 >= 4.18
Requires:       libadwaita >= 1.8
Requires:       libshumate >= 1.4
Requires:       fuse3
Requires:       hicolor-icon-theme
# Its file trigger registers the desktop entry's app.immich scheme, which the browser sign-in hands back through, and
# update-desktop-database registers Verso's Immich Crosslink entries.
Recommends:     desktop-file-utils

%description
Verso is a native GNOME gallery for a self-hosted Immich server: the library,
albums, people, places, the map and search in a window, and Verso Drive, the
library as a drive in Files and in every file dialog, which downloads
originals only when something opens them and uploads what is copied into its
Upload folder.

Verso is an independent, unofficial project. It is not affiliated with,
endorsed by, or sponsored by the Immich project or FUTO. "Immich" is used only
to describe the server this software works with, and remains the mark of its
owner.

%install
mkdir -p %{buildroot}
cp -a %{payload}/usr %{buildroot}/

%files
# The launcher, which says why on a system whose libraries are too old, in front of the window.
%{_bindir}/verso
%{_libexecdir}/verso
%{_bindir}/verso-service
/usr/lib/systemd/user/verso.service
%{_datadir}/applications/dev.hviid.Verso.desktop
%{_datadir}/icons/hicolor/*/apps/dev.hviid.Verso*
# The app's own icons: the app icon's 27 other looks among them.
%{_datadir}/verso/
%{_datadir}/locale/*/LC_MESSAGES/verso.mo
%{nautilus_extensiondir}/libverso-nautilus.so
%license %{_licensedir}/%{name}/LICENSE
%license %{_licensedir}/%{name}/THIRD-PARTY-LICENSES.md

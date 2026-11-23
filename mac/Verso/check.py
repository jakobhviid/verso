#!/usr/bin/env python3
"""Compile/run offline integration regressions without starting Verso, on a Mac: `mac/Verso/check.py`.
All clients use URLProtocol fixtures; credential access uses in-memory stubs. The endpoint calls go through the
client's session here, as no check installs the shared core (`CoreTransport`).
"""
from pathlib import Path
import subprocess
import concurrent.futures

repo = Path(__file__).resolve().parent
out = repo / 'build/integration-checks'
out.mkdir(parents=True, exist_ok=True)
api = sorted(str(p.relative_to(repo)) for p in (repo / 'Verso/API').glob('*.swift'))
models = [f'Verso/API/{s}.swift' for s in ['Models', 'Models+Albums', 'Models+Assets', 'Models+People']]
app = lambda s: f'Verso/App/{s}.swift'
support = lambda s: f'Verso/Support/{s}.swift'
cases = {
    'quick-look-downloads': ['Verso/Views/MacIntegration/MacQuickLook.swift', 'Tests/QuickLookDownloadChecks.swift'],
    'password-banner': api + ['Tests/PasswordBannerChecks.swift'],
    'metadata-state': models + ['Verso/API/Models+Metadata.swift', app('MetadataState'), 'Tests/verify-metadata-state.swift'],
    'admin-refresh': models + ['Verso/API/Models+Admin.swift', 'Verso/API/ImmichClient+Admin.swift', app('AdminModel'), 'Tests/check-admin-refresh.swift'],
    'paging-and-services': api + [app(s) for s in ['AppModel', 'AlbumPreviews', 'PlaceVisits', 'AssetGridModel', 'GridArrangement', 'AlbumsActions', 'LockedFolderMedia', 'LockedFolderTouchID', 'MetadataState', 'SharingModel', 'UploadQueue', 'VersoNotifications']] + [support('ImagePipeline'), support('LiveMotions'), support('Formatters'), 'Tests/VersoDriveStub.swift', 'Tests/check-search-paging.swift'],
    'sharing': api + [app('SharingModel'), 'Tests/SharingModelCheck.swift'],
    'upload': api + [app('UploadQueue'), app('VersoNotifications'), 'Tests/verify-upload.swift'],
    'map-annotation': api + [support('ImagePipeline'), 'Verso/Views/Albums/RemoteThumbnail.swift', 'Verso/Views/Explore/ExploreMapAnnotation.swift', 'Tests/MapAnnotationChecks.swift'],
    'explore': api + [support('ImagePipeline'), app('ExploreMapFit'), app('ExploreFolders'), 'Tests/ExploreChecks.swift'],
    'people-cache': api + [support('ImagePipeline'), 'Tests/people-network.swift'],
    'search': api + ['Tests/check-search.swift'],
    'oauth': api + ['Tests/OAuthChecks.swift'],
    'locked-folder-touch-id': api + [app('LockedFolderTouchID'), 'Tests/LockedFolderTouchIDChecks.swift'],
    'tag-picker': api + ['Verso/Views/Explore/ExploreTagPicker.swift', 'Tests/ExploreTagPickerChecks.swift'],
    'grid-context-menu': ['Verso/Views/Grid/DeferredContextMenu.swift', 'Tests/GridContextMenuChecks.swift'],
    'viewer-scroll-pan': ['Verso/Views/Viewer/ViewerScrollPan.swift', 'Tests/ViewerScrollPanChecks.swift'],
    'viewer-swipe': ['Verso/Views/Viewer/ViewerSwipeNavigation.swift', 'Verso/Views/Viewer/ViewerScrollPan.swift', 'Tests/ViewerSwipeNavigationChecks.swift'],
    'sidebar-layout': [app('SidebarLayout'), 'Tests/SidebarLayoutChecks.swift'],
    'viewer-motion': [app('ViewerMotionLayout'), 'Tests/ViewerMotionChecks.swift'],
    'card-layout': [app('CardLayout'), 'Tests/CardLayoutChecks.swift'],
    'inspector-editing': models + [app('AssetInspectorState'), 'Verso/Views/InlineEditableText.swift', 'Tests/InspectorEditingChecks.swift'],
    'search-layout': ['Verso/Views/Grid/GridHeaderLayout.swift', 'Tests/SearchLayoutChecks.swift'],
    'search-landing': api + [support('ImagePipeline'), 'Verso/Views/Albums/RemoteThumbnail.swift', 'Verso/Views/Search/SearchLandingView.swift', 'Tests/SearchLandingChecks.swift'],
    'import-status': ['Verso/Views/Upload/ImportStatusRow.swift', 'Tests/ImportStatusDesign.swift'],
    'notifications-panel': ['Verso/Views/Account/NotificationsPanel.swift', 'Tests/NotificationsPanelDesign.swift'],
    'app-icon-choice': [app('AppIconDesign'), 'Verso/Views/Settings/AppIconChoice.swift', 'Tests/AppIconChoiceDesign.swift'],
    'metadata': models + ['Verso/API/Models+Metadata.swift', 'Tests/verify-metadata.swift'],
    'transfer-cache': api + ['Tests/check-mac-transfer-cache.swift'],
    'original-drag': api + ['Verso/Views/Albums/AlbumAssetTransfer.swift', 'Verso/Views/Upload/UploadDropPolicy.swift', 'Verso/Views/MacIntegration/OriginalTransfer.swift', 'Verso/Views/MacIntegration/OriginalFilePromise.swift', 'Tests/OriginalDragChecks.swift'],
    'photo-grid-layout': [app('GridTileMetrics'), app('GridZoomTransition'), 'Verso/Views/Grid/PhotoGridGeometry.swift', 'Verso/Views/Grid/PhotoGridLayout.swift', 'Tests/PhotoGridLayoutChecks.swift'],
    'album-review': api + [app('AlbumsActions'), 'Verso/Views/Albums/AlbumAssetTransfer.swift', 'Tests/verify-album-review.swift'],
    'grid-arrangement': api + [app('GridArrangement'), support('Formatters'), 'Tests/GridArrangementChecks.swift'],
    'crosslink': [app('Crosslink'), 'Tests/CrosslinkChecks.swift'],
    'crosslink-navigation': [app('Crosslink'), app('CrosslinkNavigation'), 'Tests/CrosslinkNavigationChecks.swift'],
    'similar-photos': api + [app('SimilarPhotos'), app('SimilarPhotosAnalyzer'), app('SimilarPhotosModel'), app('AssetsStackMutation'), support('ImagePipeline'), support('Formatters'), 'Tests/SimilarPhotosChecks.swift'],
    'sharing-reach': api + [support('Formatters'), 'Verso/Views/Sharing/SharingReach.swift', 'Tests/SharingReachChecks.swift'],
    'crosslink-page-navigation': [app('Crosslink'), app('CrosslinkNavigation'), 'Verso/Views/PageNavigation.swift', 'Verso/Views/PageNavigation+Crosslink.swift', 'Tests/CrosslinkPageNavigationChecks.swift'],
}

def check(item):
    name, sources = item
    if name == 'quick-look-downloads':
        # Open only access control for the offline harness; keep production download logic unchanged.
        exposed = out / 'MacQuickLook.swift'
        exposed.write_text((repo / sources[0]).read_text().replace('private ', ''))
        sources = [str(exposed), *sources[1:]]
    binary = out / name
    log = out / (name + '.log')
    with log.open('w') as stream:
        build = subprocess.run(['swiftc', '-parse-as-library', *sources, '-o', str(binary)], cwd=repo, stdout=stream, stderr=subprocess.STDOUT)
        result = build.returncode or subprocess.run([str(binary)], cwd=repo, stdout=stream, stderr=subprocess.STDOUT).returncode
    return name, result, log

with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
    results = list(pool.map(check, cases.items()))
for name, result, log in results:
    print(f'{"FAIL" if result else "PASS"} {name}: {log.relative_to(repo)}')
    if result:
        print(log.read_text())
raise SystemExit(any(result for _, result, _ in results))

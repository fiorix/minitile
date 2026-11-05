# dmgbuild settings for the release disk image. scripts/release.sh runs, from the repository root:
#
#   dmgbuild -s packaging/dmg.py -D app=build/Minitile.app -D version=VERSION "minitile VERSION" build/release/minitile.dmg
#
# The window size, icon centres, icon size and label size match dmgWindow in scripts/branding/packaging.mjs, which
# draws the background around them; keep the two in step. dmgbuild runs this file with `defines` set from -D.
import os.path

application = defines.get("app", "build/Minitile.app")  # noqa: F821
appname = os.path.basename(application)
if "version" in defines:  # noqa: F821
    volume_name = f"minitile {defines['version']}"  # noqa: F821

format = "ULFO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(application, "Contents", "Resources", "AppIcon.icns")
background = "packaging/dmg-background.tiff"

window_rect = ((200, 400), (640, 420))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
icon_size = 128
text_size = 14
icon_locations = {appname: (160, 200), "Applications": (480, 200)}

# dmgbuild settings that produce the window layout (icon positions, background,
# window size). Run from the repository root. Used once to generate Distribution/dmg/DS_Store, which
# Scripts/build-release copies into every release DMG as .DS_Store. Not run in CI.
#   python3 -m venv /tmp/dmgenv && /tmp/dmgenv/bin/pip install dmgbuild
#   /tmp/dmgenv/bin/dmgbuild -s Distribution/dmg/settings.py -D app=<NotchLing.app> NotchLing /tmp/layout.dmg
# then mount /tmp/layout.dmg and copy its .DS_Store to Distribution/dmg/DS_Store.
import os

# dmgbuild runs this with exec(), so __file__ is unset: run it from the repository root.
application = defines["app"]  # noqa: F821  (provided by dmgbuild -D)

format = "UDZO"
files = [application]
symlinks = {"Applications": "/Applications"}
background = os.path.join(os.getcwd(), "Distribution/dmg/background.png")
window_rect = ((200, 160), (660, 420))
icon_size = 128
text_size = 13
icon_locations = {"NotchLing.app": (170, 205), "Applications": (490, 205)}  # keep in sync with make-background.py
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

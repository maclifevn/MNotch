#!/usr/bin/env python3
"""Build the distribution image without Finder automation.

Install Scripts/dmg-requirements.txt in a release-only virtual environment.
Layout settings: https://dmgbuild.readthedocs.io/en/latest/settings.html
"""
from pathlib import Path
import sys
import dmgbuild

app, output, background = map(Path, sys.argv[1:])
root = Path(__file__).resolve().parent.parent
settings = {
    'format': 'UDZO', 'compression_level': 9, 'filesystem': 'HFS+',
    'size': '64M', 'files': [str(app)],
    'symlinks': {'Applications': '/Applications'},
    'icon': str(root / 'Support/AppIcon.icns'),
    'background': str(background),
    'window_rect': ((160, 140), (640, 410)),
    'default_view': 'icon-view', 'include_icon_view_settings': True,
    'show_toolbar': False, 'show_status_bar': False,
    'show_pathbar': False, 'show_sidebar': False,
    'icon_size': 104, 'text_size': 13,
    'icon_locations': {'MNotch.app': (160, 205), 'Applications': (480, 205)},
}
dmgbuild.build_dmg(str(output), 'MNotch', settings=settings)

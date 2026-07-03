# Copyright: Ankitects Pty Ltd and contributors
# License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

"""Palace tab (MCAT fork).

A thin Qt window hosting the SvelteKit `palace` page, which shows the
memory-palace loci synced from iOS as photo pins over the reference photo,
and lets the user grade the underlying cards via the real Anki backend
(render/scheduling-states/answer RPCs exposed through mediasrv's raw-RPC
passthrough). See specs/PRD1.md.

Note: window title is a plain hardcoded string (not tr.*()) — see the i18n
decision recorded in the frontend plan for this run; ftl/core strings should
be added properly in a later pass.
"""

from __future__ import annotations

from collections.abc import Callable

import aqt
import aqt.main
from aqt.qt import *
from aqt.utils import disable_help_button, restoreGeom, saveGeom
from aqt.webview import AnkiWebView, AnkiWebViewKind


class PalaceStats(QDialog):
    def __init__(self, mw: aqt.main.AnkiQt) -> None:
        QDialog.__init__(self, mw, Qt.WindowType.Window)
        self.mw = mw
        self.name = "palaceStats"
        mw.garbage_collect_on_dialog_finish(self)
        self.setMinimumSize(600, 400)
        disable_help_button(self)
        restoreGeom(self, self.name, default_size=(800, 800))

        self.web = AnkiWebView(kind=AnkiWebViewKind.PALACE_STATS)
        self.web.load_sveltekit_page("palace")
        layout = QVBoxLayout()
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(self.web)
        self.setLayout(layout)

        self.setWindowTitle("Palace")
        self.show()

    def reject(self) -> None:
        self.web.cleanup()
        self.web = None  # type: ignore
        saveGeom(self, self.name)
        aqt.dialogs.markClosed("PalaceStats")
        QDialog.reject(self)

    def closeWithCallback(self, callback: Callable[[], None]) -> None:
        self.reject()
        callback()
